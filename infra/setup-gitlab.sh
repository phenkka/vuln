#!/bin/bash
set -euo pipefail
# trap 'echo "Ошибка на строке ${LINENO} (команда: ${BASH_COMMAND})" >&2' ERR

# Можно зпустить скрипт так - REPO_SRC=./vulnshop ./setup-gitlab.sh
# Это если скрипты не лежат в репо, а также можно дать другое имя - PROJECT_NAME=vulnshop ./setup-gitlab.sh
# И тогда скрипт будет знать, что за репо добавлять, иначе он прст добавит то репо
# Где находится скрипт
if [ -n "${REPO_SRC:-}" ]; then
    if [ -d "$REPO_SRC" ]; then
        REPO_SRC="$(cd "$REPO_SRC" && pwd)"
    elif [ -f "$REPO_SRC" ]; then
        REPO_SRC="$(cd "$(dirname "$REPO_SRC")" && pwd)/$(basename "$REPO_SRC")"
    fi
fi

# Скрипт работает относительно своей папки
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
# Если репо не указали — берём тот, в котором лежит скрипт (или пусто)
REPO_SRC="${REPO_SRC:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

PROJECT_NAME="${PROJECT_NAME:-}"
if [ -z "$PROJECT_NAME" ] && [ -n "$REPO_SRC" ]; then
    PROJECT_NAME="$(basename "${REPO_SRC%/}")"
    PROJECT_NAME="${PROJECT_NAME%.git}"
    PROJECT_NAME="${PROJECT_NAME%.bundle}"
fi
PROJECT_PATH="root/${PROJECT_NAME}"

HOST="gitlab.test"
DIND_IMAGE="docker:24-dind"
GITLAB_IMAGE="gitlab/gitlab-ce:19.2.7-ce.0"
RUNNER_IMAGE="gitlab/gitlab-runner:alpine-v19.2.0"
LOG_FILE="${DIR}/setup-gitlab.log"
RUNNER_DNS="${RUNNER_DNS-192.168.65.7}"

# 0 - ничего не сносим, а дополняем, 1 - все заново
RESET=0
if [ "${1:-}" = "--reset" ]; then RESET=1; fi

if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
    PLATFORM="linux/arm64"
else
    PLATFORM="linux/amd64"
fi

# Проверяем, что на машине есть всё нужное, до того как что-то трогать
check_prerequisites() {
    local bin
    for bin in docker openssl curl git; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
    done
    docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required" >&2; exit 1; }
    docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 1; }
}
check_prerequisites

STEP_NUM=0
TOTAL_STEPS=10
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

STATE_DIR="$(mktemp -d)"
cleanup_state() { rm -rf "$STATE_DIR"; }
trap cleanup_state EXIT

# Полный снос окружения — только по явному флагу --reset
reset_environment() {
    echo "Reset requested: removing the environment..."
    docker compose down -v 2>/dev/null || true
    rm -rf certs gitlab runner docker-compose.yml gitlab-secrets.json
    echo ""
}
if [ "$RESET" -eq 1 ]; then reset_environment; fi


# Генерируем пароль root: длина 20, гарантированно есть заглавная,
# строчная, цифра и спецсимвол (не только "в среднем" по случайности)
generate_password() {
    local length=20
    local upper='ABCDEFGHJKLMNPQRSTUVWXYZ'
    local lower='abcdefghijkmnpqrstuvwxyz'
    local digits='23456789'
    local special='!@#%^&*()-_=+'
    local all="${upper}${lower}${digits}${special}"

    random_char() {
        local charset="$1"
        local idx
        idx=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % ${#charset} ))
        printf '%s' "${charset:$idx:1}"
    }

    local chars=()
    chars+=("$(random_char "$upper")")
    chars+=("$(random_char "$lower")")
    chars+=("$(random_char "$digits")")
    chars+=("$(random_char "$special")")
    local i
    for ((i = 4; i < length; i++)); do
        chars+=("$(random_char "$all")")
    done

    local n=${#chars[@]}
    for ((i = n - 1; i > 0; i--)); do
        local j
        j=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % (i + 1) ))
        local tmp="${chars[i]}"
        chars[i]="${chars[j]}"
        chars[j]="$tmp"
    done

    printf '%s' "${chars[@]}"
}

PASS="$(generate_password)"

if [ ${#PASS} -lt 12 ]; then
    echo "Failed to generate a password of the required length." >&2
    exit 1
fi

mkdir -p certs gitlab/config/ssl runner/config

# Прописываем gitlab.test в /etc/hosts, чтобы браузер знал, куда идти
# (curl в скрипте использует --resolve, а браузеру нужна реальная запись)
# Делается вне run_step - sudo может спросить пароль в терминале
if ! grep -qE "^[^#]*[[:space:]]${HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo "Adding ${HOST} to /etc/hosts (sudo may ask for your password)..."
    SUDO="sudo"
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; fi
    echo "127.0.0.1 ${HOST}" | $SUDO tee -a /etc/hosts > /dev/null
    if [ "$(uname -s)" = "Darwin" ]; then
        $SUDO dscacheutil -flushcache || true
        $SUDO killall -HUP mDNSResponder || true
    fi
fi

echo ""
echo "Logs: ${LOG_FILE}"
echo ""

step_generate_certs() {
    # Проверяем, мб уже вес есть
    if [ -f "gitlab/config/ssl/${HOST}.crt" ] && [ -f certs/ca.crt ]; then
        echo "The certificate already exists, skipping generation."
        return 0
    fi

    # Создаем свой центр сертификации и создаем сертификат
    openssl genrsa -out certs/ca.key 2048
    openssl req -x509 -new -nodes -key certs/ca.key -sha256 -days 3650 -out certs/ca.crt -subj "/CN=Local CA"

    # Делаем секретный ключ для Gitlab и оставляем заявку CSR (Certificate Signing Request)
    openssl genrsa -out "gitlab/config/ssl/${HOST}.key" 2048
    openssl req -new -key "gitlab/config/ssl/${HOST}.key" -out "gitlab/config/ssl/${HOST}.csr" -subj "/CN=${HOST}"

    local ext_file
    ext_file=$(mktemp)
    echo "subjectAltName=DNS:${HOST},IP:127.0.0.1" > "$ext_file"

    # Подписка центром сертификата для Gitlab
    openssl x509 -req -in "gitlab/config/ssl/${HOST}.csr" -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
      -out "gitlab/config/ssl/${HOST}.crt" -days 365 -sha256 -extfile "$ext_file"
    rm -f "$ext_file"
    chmod 600 "gitlab/config/ssl/${HOST}.key"
    chmod 644 "gitlab/config/ssl/${HOST}.crt"
}
run_step "Generating TLS certificates" step_generate_certs

step_write_compose() {
cat > docker-compose.yml <<EOF
name: gitlab
services:
  gitlab:
    image: ${GITLAB_IMAGE}
    platform: ${PLATFORM}
    container_name: gitlab
    restart: unless-stopped
    hostname: ${HOST}
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${HOST}'
        registry_external_url 'https://${HOST}:5050'
        letsencrypt['enable'] = false
        gitlab_rails['gitlab_shell_ssh_port'] = 2222
        nginx['redirect_http_to_https'] = true
    ports:
      - "127.0.0.1:80:80"
      - "127.0.0.1:443:443"
      - "127.0.0.1:5050:5050"
      - "127.0.0.1:2222:22"
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-logs:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
      - ./gitlab/config/ssl:/etc/gitlab/ssl
    shm_size: '256m'
    networks:
      default:
        ipv4_address: 172.30.0.10
        aliases:
          - ${HOST}

  dind:
    image: ${DIND_IMAGE}
    platform: ${PLATFORM}
    container_name: gitlab-dind
    hostname: dind
    restart: unless-stopped
    privileged: true
    environment:
      - DOCKER_TLS_CERTDIR=/certs
      - DOCKER_TLS_SAN=DNS:dind,DNS:localhost
    volumes:
      - dind-certs:/certs
      - dind-storage:/var/lib/docker

  gitlab-runner:
    image: ${RUNNER_IMAGE}
    platform: ${PLATFORM}
    container_name: gitlab-runner
    restart: unless-stopped
    depends_on:
      gitlab:
        condition: service_started
      dind:
        condition: service_started
    environment:
      - DOCKER_HOST=tcp://dind:2376
      - DOCKER_TLS_VERIFY=1
      - DOCKER_CERT_PATH=/dind-certs/client
    volumes:
      - ./runner/config:/etc/gitlab-runner
      - dind-certs:/dind-certs:ro
      - ./certs:/gitlab-certs:ro

volumes:
  gitlab-config:
  gitlab-logs:
  gitlab-data:
  dind-certs:
  dind-storage:

networks:
  default:
    ipam:
      config:
        - subnet: 172.30.0.0/24
EOF
}
run_step "Writing a docker-compose.yml file" step_write_compose

step_compose_up() {
    docker compose up -d
}
run_step "Spinning up containers (GitLab, DinD, runner)" step_compose_up

# Ждем, пока поднимется rails консоль
step_wait_ready() {
    local max_attempts=180
    local attempt=0
    until docker exec gitlab gitlab-rails runner 'exit 0' > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "Timeout: gitlab did not become ready in time."
            docker logs --tail 50 gitlab
            return 1
        fi
        echo "Waiting for the rails console... attempt ${attempt}/${max_attempts}"
        sleep 10
    done
}
run_step "Waiting for GitLab (Rails) to come up" step_wait_ready

# Ждем, пока ответить https эндпоинт
step_wait_api() {
    local max_attempts=60
    local attempt=0
    until curl -s --fail -o /dev/null --cacert certs/ca.crt --resolve "${HOST}:443:127.0.0.1" "https://${HOST}/users/sign_in"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "Timeout: gitlab HTTPS API did not become ready in time."
            docker logs --tail 50 gitlab
            return 1
        fi
        echo "Waiting for HTTPS API... attempt ${attempt}/${max_attempts}"
        sleep 5
    done
}
run_step "Waiting for the HTTPS API to respond" step_wait_api

# Пароль root ставим, только если root ещё ни разу не входил (иначе затрём пароль,
# который сменили руками) и PAT пересоздаём каждый раз, отзывая все старые
step_password_and_token() {
    local pat out
    pat="glpat-$(openssl rand -hex 20)"
    out=$(docker exec -e NEW_PASS="${PASS}" -e NEW_PAT="${pat}" gitlab gitlab-rails runner '
      u = User.find_by(username: "root")
      if u.sign_in_count == 0
        u.password = ENV["NEW_PASS"]
        u.password_confirmation = ENV["NEW_PASS"]
        u.save!
        puts "PASSWORD_SET"
      end

      u.personal_access_tokens.active.where(name: "setup-script").each(&:revoke!)
      t = u.personal_access_tokens.create!(name: "setup-script", scopes: [:api, :write_repository, :admin_mode], expires_at: 365.days.from_now)
      t.set_token(ENV["NEW_PAT"])
      t.save!
    ')
    echo "$out"
    if echo "$out" | grep -q PASSWORD_SET; then
        touch "${STATE_DIR}/password_set"
    fi
    printf '%s' "$pat" > "${STATE_DIR}/pat"
}
run_step "Setting the root password (first run only) and creating a token" step_password_and_token
PAT="$(cat "${STATE_DIR}/pat")"

# Раннер — если уже зарегистрирован и валиден — не трогаем
# Иначе снимаем старый (и в контейнере, и в GitLab), создаём новый, регистрируем
step_setup_runner() {
    if docker exec gitlab-runner gitlab-runner verify 2>&1 | grep -q 'is valid'; then
        echo "Runner is already registered and valid, skipping."
        return 0
    fi
    # Убираем старый раннер в контейнере, если есть
    docker exec gitlab-runner gitlab-runner unregister --all-runners 2>/dev/null || true

    # Смотрим, что знает про раннеры сам GitLab
    local list_response list_status list_body
    list_response=$(curl -s -w '\n%{http_code}' --cacert certs/ca.crt --resolve "${HOST}:443:127.0.0.1" \
      -H "PRIVATE-TOKEN: ${PAT}" \
      "https://${HOST}/api/v4/runners?type=instance_type")
    list_status="${list_response##*$'\n'}"
    list_body="${list_response%$'\n'*}"

    if [ "$list_status" != "200" ]; then
        echo "Failed to list runners (HTTP ${list_status}): ${list_body}"
        return 1
    fi

    local existing_id
    existing_id=$(echo "$list_body" \
      | grep -o '"id":[0-9]*,"description":"dind-runner"' \
      | grep -oE '[0-9]+' | head -n1 || true)

    # Если старая запись есть в GitLab — сносим и её
    if [ -n "$existing_id" ]; then
        curl -s --fail --cacert certs/ca.crt --resolve "${HOST}:443:127.0.0.1" -X DELETE \
          -H "PRIVATE-TOKEN: ${PAT}" \
          "https://${HOST}/api/v4/runners/${existing_id}" > /dev/null
    fi

    # Создаём новую запись раннера в GitLab
    local create_response create_status runner_response runner_token
    create_response=$(curl -s -w '\n%{http_code}' --cacert certs/ca.crt --resolve "${HOST}:443:127.0.0.1" \
      -H "PRIVATE-TOKEN: ${PAT}" \
      -H "Content-Type: application/json" \
      -d '{"runner_type": "instance_type", "description": "dind-runner", "tag_list": ["docker"], "run_untagged": false}' \
      "https://${HOST}/api/v4/user/runners")
    create_status="${create_response##*$'\n'}"
    runner_response="${create_response%$'\n'*}"

    if [ "$create_status" != "201" ]; then
        echo "Failed to create runner (HTTP ${create_status}): ${runner_response}"
        return 1
    fi

    runner_token=$(echo "$runner_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    if [ -z "$runner_token" ]; then
        echo "Failed to create runner. Response: $runner_response"
        return 1
    fi

    # DNS передаём, только если он задан
    local dns_args=()
    if [ -n "$RUNNER_DNS" ]; then dns_args+=(--docker-dns "$RUNNER_DNS"); fi

    # Регистрируем раннер в контейнере с полученным токеном
    # pull-policy if-not-present — чтобы джобы работали офлайн из кэша образов в dind
    docker exec gitlab-runner gitlab-runner register \
      --url "https://${HOST}" \
      --token "${runner_token}" \
      --executor docker \
      --docker-image alpine:3.20 \
      --docker-host "tcp://dind:2376" \
      --docker-tlsverify=true \
      --docker-cert-path "/dind-certs/client" \
      --tls-ca-file "/gitlab-certs/ca.crt" \
      --docker-extra-hosts "${HOST}:172.30.0.10" \
      --docker-pull-policy if-not-present \
      ${dns_args[@]+"${dns_args[@]}"} \
      --non-interactive
}
run_step "Setting up the GitLab Runner" step_setup_runner

# Базовые настройки безопасности
step_apply_settings() {
    local response status body
    response=$(curl -s -w '\n%{http_code}' --cacert certs/ca.crt --resolve "${HOST}:443:127.0.0.1" \
      -X PUT \
      -H "PRIVATE-TOKEN: ${PAT}" \
      -H "Content-Type: application/json" \
      -d '{
        "signup_enabled": false,
        "default_project_visibility": "private",
        "default_group_visibility": "private",
        "default_snippet_visibility": "private",
        "require_two_factor_authentication": true,
        "two_factor_grace_period": 0,
        "admin_mode": true,
        "password_minimum_length": 12,
        "outbound_local_requests_whitelist_raw": "",
        "outbound_local_requests_whitelist": []
      }' \
      "https://${HOST}/api/v4/application/settings")
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "200" ]; then
        echo "Failed to apply application settings (HTTP ${status}): ${body}"
        return 1
    fi
}
run_step "Applying basic security settings" step_apply_settings


# Cкачиваем код во временную папку и пушим в GitLab
# Ремоуты в исходном репо не трогаем
step_import_repo() {
    if [ -z "$REPO_SRC" ]; then
        echo "REPO_SRC is not set and the script is not inside a git repository, skipping import."
        return 0
    fi

    local copy="${STATE_DIR}/repo.git"
    local url="https://root:${PAT}@${HOST}/${PROJECT_PATH}.git"

    git clone --mirror "$REPO_SRC" "$copy"

    local ca_opt="http.https://${HOST}/.sslCAInfo=${DIR}/certs/ca.crt"
    git -C "$copy" -c "$ca_opt" push --all "$url"
    git -C "$copy" -c "$ca_opt" push --tags "$url"
}
run_step "Importing the repository into GitLab" step_import_repo

step_backup_secrets() {
    docker exec gitlab cat /etc/gitlab/gitlab-secrets.json > gitlab-secrets.json
    chmod 600 gitlab-secrets.json
}
run_step "Saving gitlab-secrets.json" step_backup_secrets

echo ""
if [ -n "$REPO_SRC" ]; then
    echo "  Project:  https://${HOST}/${PROJECT_PATH}"
fi
echo "  Login:    root"
if [ -f "${STATE_DIR}/password_set" ]; then
    echo "  Password: ${PASS}"
else
    echo "  Password: (unchanged - root has already signed in)"
fi
echo "  PAT Token:    ${PAT}"
echo ""
echo "  A detailed log of every step of this launch: ${LOG_FILE}"
echo ""
