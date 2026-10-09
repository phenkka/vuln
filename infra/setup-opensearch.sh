#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

OPENSEARCH_IMAGE="opensearchproject/opensearch:3.9.0"
DASHBOARDS_IMAGE="opensearchproject/opensearch-dashboards:3.9.0"
# Постоянный адрес OpenSearch в сети GitLab: по нему в него пишут CI-джобы
OPENSEARCH_IP="${OPENSEARCH_IP:-172.30.0.20}"
# GitLab уже занимает около 4.5 ГБ, поэтому держим OpenSearch скромным
OPENSEARCH_HEAP="${OPENSEARCH_HEAP:-512m}"
VM_NAME="${VM_NAME:-staging}"
if [ -z "${PROJECT_PATH:-}" ]; then
    REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
        || { echo "Script is not inside a git repo: set PROJECT_PATH=group/project" >&2; exit 1; }
    PROJECT_PATH="root/$(basename "$REPO_ROOT")"
fi
TELEMETRY_DIR="${DIR}/telemetry"
COMPOSE_FILE="${TELEMETRY_DIR}/docker-compose.yml"
LOG_FILE="${DIR}/setup-opensearch.log"
OS_URL="http://127.0.0.1:9200"
OSD_URL="http://127.0.0.1:5601"
INDEXES="findings pipeline-events app-logs"

# DT принимает sbom из пайплайна и ищет в нем уязвимости
DT_IMAGE="dependencytrack/bundled:4.14.5"
# Постоянный адрес DT в сети GitLab: по нему к нему обращаются CI-джобы
DT_IP="${DT_IP:-172.30.0.30}"
DT_PORT="${DT_PORT:-8081}"
DT_URL="http://127.0.0.1:${DT_PORT}"
# Пароль admin генерируется на первом запуске и хранится в томе самого DT (как секреты GitLab в его томе):
# по нему скрипт входит в DT на следующих запусках. --reset удаляет том, а с ним и пароль
DT_PASSWORD_PATH="/data/.admin-password"
# Экосистемы, по которым DT скачивает базу уязвимостей OSV
OSV_ECOSYSTEMS="${OSV_ECOSYSTEMS:-PyPI;npm;Debian;Alpine}"
DT_CI_TEAM="gitlab-ci"
RESET=0
if [ "${1:-}" = "--reset" ]; then RESET=1; fi

check_prerequisites() {
    local bin
    for bin in docker curl openssl; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
    done
    docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required" >&2; exit 1; }
    docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 1; }
    docker exec gitlab true >/dev/null 2>&1 || { echo "GitLab container is not running (run setup-gitlab.sh first)" >&2; exit 1; }
}
check_prerequisites

STEP_NUM=0
TOTAL_STEPS=8
SPIN='|/-\'
IS_TTY=0
if [ -t 1 ]; then IS_TTY=1; fi

run_step() {
    local desc="$1"; shift
    STEP_NUM=$((STEP_NUM + 1))
    local prefix="[${STEP_NUM}/${TOTAL_STEPS}]"

    {
        echo ""
        echo "===== ${prefix} ${desc} ====="
    } >> "$LOG_FILE"

    ( "$@" ) >>"$LOG_FILE" 2>&1 &
    local pid=$!

    if [ "$IS_TTY" -eq 1 ]; then
        local i=0 line width
        width="$( (stty size </dev/tty) 2>/dev/null | awk '{print $2}' || true)"
        width=$(( ${width:-80} - 1 ))
        tput civis 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            i=$(( (i + 1) % ${#SPIN} ))
            line="${prefix} ${SPIN:$i:1}  ${desc}"
            printf "\r\033[K%s" "${line:0:$width}"
            sleep 0.1
        done
        tput cnorm 2>/dev/null || true
    else
        printf "%s %s\n" "$prefix" "$desc"
    fi

    local status=0
    if wait "$pid"; then status=0; else status=$?; fi

    if [ "$status" -eq 0 ]; then
        printf "\r\033[K%s ✔ %s\n" "$prefix" "$desc"
    else
        printf "\r\033[K%s ✘ %s\n" "$prefix" "$desc"
        echo "" >&2
        echo "Error: «${desc}»" >&2
        echo "Last lines of the log (${LOG_FILE}):" >&2
        echo "----------------------------------------" >&2
        tail -n 25 "$LOG_FILE" >&2
        echo "----------------------------------------" >&2
        echo "Full log of this run: ${LOG_FILE}" >&2
        exit 1
    fi
}

: > "$LOG_FILE"
mkdir -p "${TELEMETRY_DIR}/dashboards"
# Шаги идут в подпроцессах, поэтому новый API-ключ DT передаём между ними через файл
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

reset_environment() {
    echo "Reset requested: removing OpenSearch, Dashboards and their data..."
    docker compose -p telemetry down -v 2>/dev/null || true
    rm -f "$COMPOSE_FILE"
    echo ""
}
if [ "$RESET" -eq 1 ]; then reset_environment; fi

# Сеть, в которой живёт GitLab (её создал setup-gitlab.sh) 
# Подключаемся к ней, чтобы CI-джобы из dind доходили до OpenSearch по OPENSEARCH_IP
GITLAB_NETWORK="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' gitlab)"

VM_GATEWAY=""
if command -v multipass >/dev/null 2>&1 && multipass info "$VM_NAME" 2>/dev/null | grep -q '^State:.*Running'; then
    VM_GATEWAY="$(multipass exec "$VM_NAME" -- ip route show default | awk '{print $3; exit}' || true)"
fi

echo ""
echo "Logs: ${LOG_FILE}"
echo ""

step_write_compose() {
    local vm_port=""
    if [ -n "$VM_GATEWAY" ]; then vm_port="      - \"${VM_GATEWAY}:9200:9200\""; fi

cat > "$COMPOSE_FILE" <<EOF
name: telemetry

services:
  opensearch:
    image: ${OPENSEARCH_IMAGE}
    container_name: opensearch
    restart: unless-stopped
    environment:
      - discovery.type=single-node
      - OPENSEARCH_JAVA_OPTS=-Xms${OPENSEARCH_HEAP} -Xmx${OPENSEARCH_HEAP}
      - DISABLE_SECURITY_PLUGIN=true
      - DISABLE_INSTALL_DEMO_CONFIG=true
    ulimits:
      nofile: { soft: 65536, hard: 65536 }
    mem_limit: 1536m
    volumes:
      - opensearch-data:/usr/share/opensearch/data
    ports:
      - "127.0.0.1:9200:9200"
${vm_port}
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9200/_cluster/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
    networks:
      gitlab:
        ipv4_address: ${OPENSEARCH_IP}

  dashboards:
    image: ${DASHBOARDS_IMAGE}
    container_name: opensearch-dashboards
    restart: unless-stopped
    depends_on:
      opensearch:
        condition: service_healthy
    environment:
      - OPENSEARCH_HOSTS=["http://opensearch:9200"]
      - DISABLE_SECURITY_DASHBOARDS_PLUGIN=true
    mem_limit: 1g
    ports:
      - "127.0.0.1:5601:5601"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:5601/api/status || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
    networks:
      - gitlab

  dependency-track:
    image: ${DT_IMAGE}
    container_name: dependency-track
    restart: unless-stopped
    mem_limit: 3g
    volumes:
      - dtrack-data:/data
    ports:
      - "127.0.0.1:${DT_PORT}:8080"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/api/version || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
    networks:
      gitlab:
        ipv4_address: ${DT_IP}

volumes:
  opensearch-data:
  dtrack-data:

networks:
  gitlab:
    name: ${GITLAB_NETWORK}
    external: true
EOF
    cat "$COMPOSE_FILE"
}
run_step "Writing the telemetry compose file" step_write_compose

# --wait: команда вернётся, только когда оба healthcheck станут зелёными
step_compose_up() {
    docker compose -f "$COMPOSE_FILE" up -d --wait --wait-timeout 300
}
run_step "Starting OpenSearch, Dashboards and Dependency-Track (waiting for healthy)" step_compose_up

# Схема полей для будущих индексов
# Читает JSON из stdin и отправляет его в OpenSearch 
put_template() {
    local name="$1"
    curl -sS --fail-with-body -X PUT "${OS_URL}/_index_template/${name}" \
      -H 'Content-Type: application/json' --data-binary @-
    echo "  <- ${name}"
}

step_index_templates() {
    put_template findings <<'EOF'
{
  "index_patterns": ["findings*"],
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
    "mappings": {
      "dynamic_templates": [
        { "strings_as_keyword": { "match_mapping_type": "string", "mapping": { "type": "keyword", "ignore_above": 1024 } } }
      ],
      "properties": {
        "@timestamp":  { "type": "date" },
        "project":     { "type": "keyword" },
        "pipeline_id": { "type": "long" },
        "job_name":    { "type": "keyword" },
        "commit_sha":  { "type": "keyword" },
        "ref":         { "type": "keyword" },
        "tool":        { "type": "keyword" },
        "category":    { "type": "keyword" },
        "rule_id":     { "type": "keyword" },
        "title":       { "type": "text", "fields": { "raw": { "type": "keyword", "ignore_above": 512 } } },
        "severity":    { "type": "keyword" },
        "location":    { "type": "keyword" },
        "fingerprint": { "type": "keyword" }
      }
    }
  }
}
EOF

    put_template pipeline-events <<'EOF'
{
  "index_patterns": ["pipeline-events*"],
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
    "mappings": {
      "dynamic_templates": [
        { "strings_as_keyword": { "match_mapping_type": "string", "mapping": { "type": "keyword", "ignore_above": 1024 } } }
      ],
      "properties": {
        "@timestamp":     { "type": "date" },
        "project":        { "type": "keyword" },
        "pipeline_id":    { "type": "long" },
        "job_id":         { "type": "long" },
        "job_name":       { "type": "keyword" },
        "stage":          { "type": "keyword" },
        "status":         { "type": "keyword" },
        "commit_sha":     { "type": "keyword" },
        "ref":            { "type": "keyword" },
        "duration_s":     { "type": "float" },
        "queued_s":       { "type": "float" },
        "allow_failure":  { "type": "boolean" },
        "failure_reason": { "type": "keyword" }
      }
    }
  }
}
EOF

    put_template app-logs <<'EOF'
{
  "index_patterns": ["app-logs*"],
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
    "mappings": {
      "dynamic_templates": [
        { "strings_as_keyword": { "match_mapping_type": "string", "mapping": { "type": "keyword", "ignore_above": 1024 } } }
      ],
      "properties": {
        "@timestamp":     { "type": "date" },
        "host":           { "type": "keyword" },
        "container_name": { "type": "keyword" },
        "stream":         { "type": "keyword" },
        "log":            { "type": "text" },
        "client_ip":      { "type": "keyword" },
        "method":         { "type": "keyword" },
        "path":           { "type": "keyword" },
        "status":         { "type": "integer", "ignore_malformed": true }
      }
    }
  }
}
EOF
}

run_step "Applying index templates" step_index_templates

step_dashboards_objects() {
    local file name
    for name in $INDEXES; do
        curl -sS --fail-with-body -X POST "${OSD_URL}/api/saved_objects/index-pattern/${name}?overwrite=true" \
          -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
          -d "{\"attributes\":{\"title\":\"${name}*\",\"timeFieldName\":\"@timestamp\"}}"
        echo "  <- index pattern ${name}*"
    done

    for file in "${TELEMETRY_DIR}"/dashboards/*.ndjson; do
        [ -e "$file" ] || { echo "No dashboards to import yet"; break; }
        curl -sS --fail-with-body -X POST "${OSD_URL}/api/saved_objects/_import?overwrite=true" \
          -H 'osd-xsrf: true' -F "file=@${file}"
        echo "  <- $(basename "$file")"
    done
}
run_step "Creating index patterns and importing dashboards" step_dashboards_objects

# Пароль admin, сохранённый в томе DT (пусто, если его ещё нет)
dt_password() {
    docker exec dependency-track cat "$DT_PASSWORD_PATH" 2>/dev/null || true
}

# Вход в DT под admin - печатает токен для остальных запросов к API
dt_login() {
    curl -sS --fail -X POST "${DT_URL}/api/v1/user/login" \
      --data-urlencode "username=admin" --data-urlencode "password=$(dt_password)"
}

# У свежего DT логин admin/admin, и пароль обязательно сменить при первом входе.
# Генерируем пароль, сохраняем в томе DT и ставим. Если по сохранённому уже можно войти — пропускаем
step_dt_admin_password() {
    if dt_login >/dev/null 2>&1; then
        echo "Admin password is already set, skipping."
        return 0
    fi
    local password
    password="$(openssl rand -hex 16)"
    printf '%s' "$password" | docker exec -i dependency-track sh -c "umask 077; cat > ${DT_PASSWORD_PATH}"
    curl -sS --fail -X POST "${DT_URL}/api/v1/user/forceChangePassword" \
      --data-urlencode "username=admin" --data-urlencode "password=admin" \
      --data-urlencode "newPassword=${password}" --data-urlencode "confirmPassword=${password}" \
      || { echo "The default admin password was already changed by hand. Run with --reset"; return 1; }
    echo "Admin password generated and set"
}
run_step "Setting the Dependency-Track admin password (first run only)" step_dt_admin_password

step_dt_vuln_sources() {
    local jwt current eco missing="" pending since logs i
    jwt="$(dt_login)"
    current="$(curl -sS --fail "${DT_URL}/api/v1/configProperty" -H "Authorization: Bearer ${jwt}" \
      | grep -o '"propertyName":"google.osv.enabled","propertyValue":"[^"]*"' | cut -d'"' -f8 || true)"
    # DT хранит список в своём порядке, поэтому сверяем экосистемы по одной
    for eco in $(echo "$OSV_ECOSYSTEMS" | tr ';' ' '); do
        case ";${current};" in *";${eco};"*) ;; *) missing="${missing} ${eco}" ;; esac
    done

    curl -sS --fail -X POST "${DT_URL}/api/v1/configProperty/aggregate" \
      -H "Authorization: Bearer ${jwt}" -H 'Content-Type: application/json' -d "[
        {\"groupName\":\"vuln-source\",\"propertyName\":\"google.osv.enabled\",\"propertyValue\":\"${OSV_ECOSYSTEMS}\"},
        {\"groupName\":\"vuln-source\",\"propertyName\":\"nvd.enabled\",\"propertyValue\":\"false\"},
        {\"groupName\":\"scanner\",\"propertyName\":\"ossindex.enabled\",\"propertyValue\":\"false\"},
        {\"groupName\":\"scanner\",\"propertyName\":\"npmaudit.enabled\",\"propertyValue\":\"false\"}]" >/dev/null

    if [ -z "$missing" ]; then
        echo "OSV is already mirrored for: ${current}, skipping."
        return 0
    fi
    echo "Mirroring OSV for:${missing}"
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    docker restart dependency-track >/dev/null
    for i in $(seq 1 120); do
        # Логи сначала в переменную: grep -q в конвейере с pipefail даёт ложный не найдено
        logs="$(docker logs --since "$since" dependency-track 2>&1)"
        pending=""
        for eco in $missing; do
            case "$logs" in *"mirror completed for ${eco} "*) ;; *) pending="${pending} ${eco}" ;; esac
        done
        if [ -z "$pending" ]; then
            echo "OSV mirror finished"
            return 0
        fi
        echo "Waiting for the OSV mirror:${pending}"
        sleep 10
    done
    echo "OSV mirror did not finish in 20 minutes, see: docker logs dependency-track"
    return 1
}
run_step "Mirroring vulnerability data from OSV" step_dt_vuln_sources

# Команда для CI с минимальными правами: загрузить SBOM, создать проект, читать находки.
# Старую команду удаляем вместе с её ключами и создаём заново — как PAT в setup-gitlab.sh
step_dt_ci_key() {
    local jwt team_uuid perm
    jwt="$(dt_login)"
    for team_uuid in $(curl -sS --fail "${DT_URL}/api/v1/team" -H "Authorization: Bearer ${jwt}" \
        | grep -o "\"uuid\":\"[^\"]*\",\"name\":\"${DT_CI_TEAM}\"" | cut -d'"' -f4 || true); do
        curl -sS --fail -X DELETE "${DT_URL}/api/v1/team" -H "Authorization: Bearer ${jwt}" \
          -H 'Content-Type: application/json' -d "{\"uuid\":\"${team_uuid}\"}"
        echo "Old team ${team_uuid} removed together with its API keys"
    done

    team_uuid="$(curl -sS --fail -X PUT "${DT_URL}/api/v1/team" -H "Authorization: Bearer ${jwt}" \
      -H 'Content-Type: application/json' -d "{\"name\":\"${DT_CI_TEAM}\"}" \
      | grep -o '"uuid":"[^"]*"' | head -n1 | cut -d'"' -f4)"
    echo "Team ${DT_CI_TEAM} created"

    for perm in BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO VIEW_VULNERABILITY; do
        curl -sS --fail -o /dev/null -X POST "${DT_URL}/api/v1/permission/${perm}/team/${team_uuid}" \
          -H "Authorization: Bearer ${jwt}"
        echo "Permission ${perm} granted"
    done

    curl -sS --fail -X PUT "${DT_URL}/api/v1/team/${team_uuid}/key" -H "Authorization: Bearer ${jwt}" \
      | grep -o '"key":"[^"]*"' | cut -d'"' -f4 > "${STATE_DIR}/dt_api_key"
    echo "New API key created"
}
run_step "Creating the Dependency-Track CI team and API key" step_dt_ci_key

# Адреса и ключ для CI-джоб. Ключ — секрет: protected и masked, в логах джоб не виден
step_ci_variables() {
    OPENSEARCH_URL="http://${OPENSEARCH_IP}:9200" DT_CI_URL="http://${DT_IP}:8080" \
    DT_API_KEY="$(cat "${STATE_DIR}/dt_api_key")" PROJECT_PATH="$PROJECT_PATH" \
    docker exec -e OPENSEARCH_URL -e DT_CI_URL -e DT_API_KEY -e PROJECT_PATH gitlab gitlab-rails runner '
        project = Project.find_by_full_path(ENV["PROJECT_PATH"])
        raise "Project #{ENV["PROJECT_PATH"]} not found" unless project

        { "OPENSEARCH_URL" => { value: ENV["OPENSEARCH_URL"], protected: false, masked: false },
          "DT_URL"         => { value: ENV["DT_CI_URL"],      protected: false, masked: false },
          "DT_API_KEY"     => { value: ENV["DT_API_KEY"],     protected: true,  masked: true } }.each do |key, attrs|
          var = project.variables.find_or_initialize_by(key: key, environment_scope: "*")
          var.update!(variable_type: "env_var", **attrs)
          puts "#{key}: saved (protected=#{attrs[:protected]}, masked=#{attrs[:masked]})"
        end
    '
}
run_step "Saving CI/CD variables (OpenSearch, Dependency-Track) to ${PROJECT_PATH}" step_ci_variables

echo ""
echo "  Dashboards:  ${OSD_URL}"
echo "  OpenSearch:  ${OS_URL}"
echo "  From CI:     http://${OPENSEARCH_IP}:9200  (CI variable OPENSEARCH_URL)"
if [ -n "$VM_GATEWAY" ]; then
    echo "  From VM:     http://${VM_GATEWAY}:9200"
else
    echo "  From VM:     not published (VM '${VM_NAME}' is not running; start it and re-run)"
fi
echo ""
echo "  Dependency-Track:  ${DT_URL}"
echo "  Login:             admin"
echo "  Password:          $(dt_password)"
echo "  From CI:           http://${DT_IP}:8080  (CI variables DT_URL, DT_API_KEY)"
echo ""
echo "  A detailed log of every step of this launch: ${LOG_FILE}"
echo ""
