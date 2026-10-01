#!/bin/bash
set -euo pipefail

# Скрипт работает относительно своей папки
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Можно запустить так VM_NAME=test ./setup-staging-env.sh, чтобы дать конкретное имя VM
VM_NAME="${VM_NAME:-staging}"
VM_IMAGE="${VM_IMAGE:-24.04}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY="${VM_MEMORY:-2G}"
VM_DISK="${VM_DISK:-15G}"
DEPLOY_USER="deploy"
HOST="gitlab.test"
# Порты GitLab, которые джоба деплоя пробрасывает на VM туннелем:
# 5050 - registry, 443 - выдача токенов для docker pull (/jwt/auth)
TUNNEL_PORTS="5050 443"
if [ -z "${PROJECT_PATH:-}" ]; then
    REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
        || { echo "Script is not inside a git repo: set PROJECT_PATH=group/project" >&2; exit 1; }
    PROJECT_PATH="root/$(basename "$REPO_ROOT")"
fi
CA_FILE="${CA_FILE:-${DIR}/certs/ca.crt}"
STAGING_DIR="${STAGING_DIR:-${DIR}/.staging}"
KEY_FILE="${STAGING_DIR}/deploy_key"
LOG_FILE="${DIR}/setup-staging.log"
FLUENT_BIT_IMAGE="${FLUENT_BIT_IMAGE:-fluent/fluent-bit:5.1.2}"

# 0 - ничего не сносим, а дополняем, 1 - все заново
RESET=0
if [ "${1:-}" = "--reset" ]; then RESET=1; fi

# Проверяем, что на машине есть всё нужное, до того как что-то трогать
check_prerequisites() {
    local bin
    for bin in multipass ssh-keygen docker; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
    done
    multipass list >/dev/null 2>&1 || { echo "Multipass daemon is not responding" >&2; exit 1; }
    [ -f "$CA_FILE" ] || { echo "CA certificate not found: $CA_FILE (run setup-gitlab.sh first)" >&2; exit 1; }
    docker exec gitlab true >/dev/null 2>&1 || { echo "GitLab container is not running (run setup-gitlab.sh first)" >&2; exit 1; }
}
check_prerequisites

STEP_NUM=0
TOTAL_STEPS=9
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

# Полный снос VM — только по явному флагу --reset
reset_environment() {
    echo "Reset requested: removing the VM and its keys..."
    multipass delete --purge "$VM_NAME" 2>/dev/null || true
    rm -rf "$STAGING_DIR"
    echo ""
}
if [ "$RESET" -eq 1 ]; then reset_environment; fi

mkdir -p "$STAGING_DIR"
chmod 700 "$STAGING_DIR"

echo ""
echo "Logs: ${LOG_FILE}"
echo ""

# || true - без VM multipass info падает, и из-за pipefail упал бы весь шаг
vm_ip() {
    multipass info "$VM_NAME" 2>/dev/null | awk '/^IPv4:/{print $2; exit}' || true
}

# Ключ, которым CI будет заходить на VM 
# Если уже есть — не трогаем
step_ssh_key() {
    if [ -f "$KEY_FILE" ]; then
        echo "Deploy key already exists, skipping."
        return 0
    fi
    ssh-keygen -t ed25519 -N "" -C "ci-deploy@${VM_NAME}" -f "$KEY_FILE"
}
run_step "Generating the deploy SSH key" step_ssh_key

# Тут только то, что не меняется при пересоздании VM, поэтому нету ключей и тп
step_write_cloud_init() {
cat > "${STAGING_DIR}/cloud-init.yaml" <<'EOF'
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - ufw
write_files:
  - path: /etc/docker/daemon.json
    content: |
      {
        "log-driver": "json-file",
        "log-opts": { "max-size": "10m", "max-file": "3" },
        "live-restore": true
      }
runcmd:
  - systemctl enable --now docker
EOF
}
run_step "Writing the cloud-init file" step_write_cloud_init

# Нет VM — создаём, выключена — включаем, работает — не трогаем
step_vm() {
    local state
    state="$(multipass info "$VM_NAME" 2>/dev/null | awk '/^State:/{print $2; exit}' || true)"

    case "$state" in
        "")
            # timeout включает скачивание образа Ubuntu при первом запуске
            multipass launch "$VM_IMAGE" \
              --name "$VM_NAME" \
              --cpus "$VM_CPUS" \
              --memory "$VM_MEMORY" \
              --disk "$VM_DISK" \
              --cloud-init "${STAGING_DIR}/cloud-init.yaml" \
              --timeout 1800
            ;;
        Running)
            echo "VM '${VM_NAME}' is already running, skipping."
            ;;
        *)
            echo "VM '${VM_NAME}' is in state '${state}', starting it..."
            multipass start "$VM_NAME"
            ;;
    esac
}
run_step "Creating or starting the VM" step_vm

# Ждём, пока cloud-init поставит Docker
step_wait_cloud_init() {
    local rc=0
    multipass exec "$VM_NAME" -- cloud-init status --wait || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        echo "cloud-init failed (exit ${rc}). See: multipass exec ${VM_NAME} -- sudo cat /var/log/cloud-init-output.log"
        return 1
    fi
}
run_step "Waiting for cloud-init (Docker installation)" step_wait_cloud_init

# Всё, что может поменяться (ключ, CA, правила), применяем при каждом запуске
step_configure_vm() {
    local subnet
    subnet="$(vm_ip | awk -F. '{print $1"."$2"."$3".0/24"}')"

    multipass transfer "${KEY_FILE}.pub" "${VM_NAME}:/tmp/deploy_key.pub"
    multipass transfer "$CA_FILE" "${VM_NAME}:/tmp/gitlab-ca.crt"

    # Кавычки у 'EOF' — внутри ничего не подставляется на Mac, значения приходят как $1, $2...
    multipass exec "$VM_NAME" -- sudo bash -s -- "$DEPLOY_USER" "$HOST" "$subnet" $TUNNEL_PORTS <<'EOF'
set -euo pipefail
user="$1"; host="$2"; subnet="$3"; shift 3

id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$user"
usermod -aG docker "$user"
install -d -m 700 -o "$user" -g "$user" "/home/${user}/.ssh"
install -m 600 -o "$user" -g "$user" /tmp/deploy_key.pub "/home/${user}/.ssh/authorized_keys"

ca=/usr/local/share/ca-certificates/gitlab-local-ca.crt
if ! cmp -s /tmp/gitlab-ca.crt "$ca"; then
    install -m 644 /tmp/gitlab-ca.crt "$ca"
    update-ca-certificates
    systemctl restart docker
fi
rm -f /tmp/deploy_key.pub /tmp/gitlab-ca.crt

grep -q "[[:space:]]${host}\$" /etc/hosts || echo "127.0.0.1 ${host}" >> /etc/hosts

min_port="$(printf '%s\n' "$@" | sort -n | head -n1)"
echo "net.ipv4.ip_unprivileged_port_start = ${min_port}" > /etc/sysctl.d/60-tunnel-ports.conf
sysctl -q -p /etc/sysctl.d/60-tunnel-ports.conf

listen=""
for port in "$@"; do listen="${listen} 127.0.0.1:${port}"; done

cat > /etc/ssh/sshd_config.d/01-hardening.conf <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3

Match User ${user}
    AllowTcpForwarding remote
    PermitListen${listen}
CONF
sshd -t
systemctl reload-or-restart ssh

ufw default deny incoming
ufw default allow outgoing
ufw allow from "$subnet" to any port 22 proto tcp
ufw --force enable
EOF
}
run_step "Configuring the VM (deploy user, CA, SSH, firewall)" step_configure_vm


# У VM может не быть интернета, поэтому образ скачивает Mac (или берёт из своего кэша)
step_fluent_bit_image() {
    # Вывод глушим внутри VM: если заглушить его у multipass на Mac, multipass зависает
    if multipass exec "$VM_NAME" -- sudo sh -c 'docker image inspect "$1" >/dev/null 2>&1' _ "$FLUENT_BIT_IMAGE"; then
        echo "Image ${FLUENT_BIT_IMAGE} is already on the VM, skipping."
        return 0
    fi

    local arch tar
    arch="$(multipass exec "$VM_NAME" -- dpkg --print-architecture)"
    if [ "$(docker image inspect -f '{{.Architecture}}' "$FLUENT_BIT_IMAGE" 2>/dev/null || true)" != "$arch" ]; then
        docker pull --platform "linux/${arch}" "$FLUENT_BIT_IMAGE"
    fi

    tar="${STAGING_DIR}/fluent-bit-image.tar"
    docker save -o "$tar" "$FLUENT_BIT_IMAGE"
    multipass transfer "$tar" "${VM_NAME}:/tmp/fluent-bit-image.tar"
    rm -f "$tar"
    multipass exec "$VM_NAME" -- sudo docker load -i /tmp/fluent-bit-image.tar
    multipass exec "$VM_NAME" -- sudo rm -f /tmp/fluent-bit-image.tar
}
run_step "Delivering the Fluent Bit image to the VM" step_fluent_bit_image

# Fluent Bit принимает логи контейнеров приложения от Docker (log driver fluentd) и отправляет их в OpenSearch на Mac
step_fluent_bit() {
    local gateway
    gateway="$(multipass exec "$VM_NAME" -- ip route show default | awk '{print $3; exit}')"

    multipass exec "$VM_NAME" -- sudo bash -s -- "$gateway" "$VM_NAME" "$FLUENT_BIT_IMAGE" <<'EOF'
set -euo pipefail
os_host="$1"; vm="$2"; image="$3"
conf=/etc/fluent-bit
install -d -m 755 "$conf" /var/lib/fluent-bit

tmp="$(mktemp -d)"
cat > "${tmp}/parsers.conf" <<'CONF'
[PARSER]
    Name    access_log
    Format  regex
    Regex   ^(?<client_ip>[^ ]+) [^ ]+ [^ ]+ \[[^\]]*\] "[^A-Z"]*(?<method>[A-Z]+) (?<path>[^ "]+)[^"]*" (?<status>[0-9]{3})
    Types   status:integer
CONF

cat > "${tmp}/fluent-bit.conf" <<CONF
[SERVICE]
    Flush         5
    Log_Level     info
    Parsers_File  parsers.conf
    storage.path  /buffer

[INPUT]
    Name          forward
    Listen        127.0.0.1
    Port          24224
    storage.type  filesystem

[FILTER]
    Name          parser
    Match         *
    Key_Name      log
    Parser        access_log
    Reserve_Data  On
    Preserve_Key  On

[FILTER]
    Name          modify
    Match         *
    Remove        container_name
    Rename        source stream
    Add           host ${vm}

[OUTPUT]
    Name               opensearch
    Match              *
    Host               ${os_host}
    Port               9200
    Logstash_Format    On
    Logstash_Prefix    app-logs
    Suppress_Type_Name On
    Include_Tag_Key    On
    Tag_Key            container_name
    Retry_Limit        False
CONF

changed=0
for f in parsers.conf fluent-bit.conf; do
    if ! cmp -s "${tmp}/${f}" "${conf}/${f}"; then
        install -m 644 "${tmp}/${f}" "${conf}/${f}"
        changed=1
    fi
done
rm -rf "$tmp"

current="$(docker inspect -f '{{.Config.Image}}' fluent-bit 2>/dev/null || true)"
if [ "$changed" -eq 1 ] || [ "$current" != "$image" ]; then
    docker rm -f fluent-bit >/dev/null 2>&1 || true
    docker run -d --name fluent-bit --restart unless-stopped --network host \
      -v "${conf}:/fluent-bit/etc:ro" -v /var/lib/fluent-bit:/buffer "$image"
    echo "Fluent Bit (re)started."
else
    docker start fluent-bit >/dev/null
    echo "Fluent Bit config unchanged, container kept."
fi
EOF
}
run_step "Setting up Fluent Bit (app logs -> OpenSearch)" step_fluent_bit

# Отпечаток ключа VM берём изнутри VM (через multipass, а не по сети),
# чтобы джоба могла проверить, что подключается именно к нашей VM
step_known_hosts() {
    local ip hostkey
    ip="$(vm_ip)"
    hostkey="$(multipass exec "$VM_NAME" -- cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')"
    echo "${ip} ${hostkey}" > "${STAGING_DIR}/known_hosts"
    cat "${STAGING_DIR}/known_hosts"
}
run_step "Saving the VM host key (known_hosts)" step_known_hosts

step_ci_variables() {
    STAGING_HOST="$(vm_ip)" \
    STAGING_USER="$DEPLOY_USER" \
    STAGING_SSH_KEY="$(cat "$KEY_FILE")"$'\n' \
    STAGING_KNOWN_HOSTS="$(cat "${STAGING_DIR}/known_hosts")"$'\n' \
    PROJECT_PATH="$PROJECT_PATH" \
    docker exec -e STAGING_HOST -e STAGING_USER -e STAGING_SSH_KEY -e STAGING_KNOWN_HOSTS -e PROJECT_PATH \
      gitlab gitlab-rails runner '
        project = Project.find_by_full_path(ENV["PROJECT_PATH"])
        raise "Project #{ENV["PROJECT_PATH"]} not found" unless project

        { "STAGING_HOST"        => "env_var",
          "STAGING_USER"        => "env_var",
          "STAGING_SSH_KEY"     => "file",
          "STAGING_KNOWN_HOSTS" => "file" }.each do |key, type|
          var = project.variables.find_or_initialize_by(key: key, environment_scope: "*")
          var.update!(value: ENV[key], variable_type: type, protected: true)
          puts "#{key}: saved (#{type})"
        end
      '
}
run_step "Saving CI/CD variables to ${PROJECT_PATH}" step_ci_variables

echo ""
echo "  VM:       ${VM_NAME} ($(vm_ip))"
echo "  SSH:      ssh -i ${KEY_FILE} -o UserKnownHostsFile=${STAGING_DIR}/known_hosts ${DEPLOY_USER}@$(vm_ip)"
echo "  CI vars:  STAGING_HOST, STAGING_USER, STAGING_SSH_KEY, STAGING_KNOWN_HOSTS -> ${PROJECT_PATH}"
echo ""
echo "  A detailed log of every step of this launch: ${LOG_FILE}"
echo ""
