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

RESET=0
if [ "${1:-}" = "--reset" ]; then RESET=1; fi

check_prerequisites() {
    local bin
    for bin in docker curl; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
    done
    docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required" >&2; exit 1; }
    docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 1; }
    docker exec gitlab true >/dev/null 2>&1 || { echo "GitLab container is not running (run setup-gitlab.sh first)" >&2; exit 1; }
}
check_prerequisites

STEP_NUM=0
TOTAL_STEPS=5
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

volumes:
  opensearch-data:

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
run_step "Starting OpenSearch and Dashboards (waiting for healthy)" step_compose_up

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

step_ci_variable() {
    OPENSEARCH_URL="http://${OPENSEARCH_IP}:9200" PROJECT_PATH="$PROJECT_PATH" \
    docker exec -e OPENSEARCH_URL -e PROJECT_PATH gitlab gitlab-rails runner '
        project = Project.find_by_full_path(ENV["PROJECT_PATH"])
        raise "Project #{ENV["PROJECT_PATH"]} not found" unless project

        var = project.variables.find_or_initialize_by(key: "OPENSEARCH_URL", environment_scope: "*")
        var.update!(value: ENV["OPENSEARCH_URL"], variable_type: "env_var", protected: false)
        puts "OPENSEARCH_URL: saved (#{var.value})"
    '
}
run_step "Saving CI/CD variable OPENSEARCH_URL to ${PROJECT_PATH}" step_ci_variable

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
echo "  A detailed log of every step of this launch: ${LOG_FILE}"
echo ""
