#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# puter-install.sh — runs INSIDE the LXC container (pushed + executed by
# install/puter.sh via pct exec). Community-scripts install/<app>-install.sh style.
#
# Steps:
#   1. apt update + upgrade, base packages
#   2. Docker Engine + compose plugin (get.docker.com)
#   3. Docker log rotation (daemon.json) — BEFORE the stack starts
#   4. Official Puter self-host installer (compose stack: puter, caddy,
#      mariadb, valkey, dynamodb-local, rustfs) with PUTER_DOMAIN/PUTER_PORT
#      — or update (compose pull + up -d) if already installed
#   5. systemd unit puter.service (reboot-safe; docker restart policies)
#   6. Self-verification: systemctl is-active, HTTP check, admin password
#
# Environment (set by the host script):
#   PUTER_DOMAIN  — domain Puter serves on (wildcard DNS -> CT IP)
#   PUTER_PORT    — HTTP port (default 80)
#   PUTER_CTIP    — container IP (informational)
#   UPDATE_MODE   — 1 = existing install, update only
#
# Debug: bash -x /tmp/puter-install.sh
# -----------------------------------------------------------------------------

set -euo pipefail

PUTER_DOMAIN="${PUTER_DOMAIN:-puter.lan}"
PUTER_PORT="${PUTER_PORT:-80}"
PUTER_CTIP="${PUTER_CTIP:-}"
UPDATE_MODE="${UPDATE_MODE:-0}"
# IP-Mode (no DNS needed): API on PUTER_API_PORT + S3 on PUTER_S3_PORT.
# Caddy rewrites Host to api.<CT-IP> server-side, so Puter's subdomain gate
# sees the api subdomain while browsers only ever talk to <CT-IP>:ports.
# Core features (desktop, login, files, apps, realtime, S3) work; user
# site/app hosting still needs wildcard DNS.
PUTER_IP_MODE="${PUTER_IP_MODE:-0}"
PUTER_API_PORT="${PUTER_API_PORT:-8080}"
PUTER_S3_PORT="${PUTER_S3_PORT:-8081}"
INSTALL_ROOT="/opt/puter"
COMPOSE_DIR="${INSTALL_ROOT}/puter-selfhosted"

# ── Colors + helpers (community-scripts style) ──────────────────────────────
if [[ -t 1 ]] && [[ "${PUTER_NO_COLOR:-}" != "1" ]]; then
    YW=$(printf '\033[1;33m'); GN=$(printf '\033[1;32m'); RD=$(printf '\033[1;31m')
    BOLD=$(printf '\033[1m'); CL=$(printf '\033[0m')
else
    YW=""; GN=""; RD=""; BOLD=""; CL=""
fi
INFO="${YW}Info:${CL}"
ERROR="${RD}ERROR:${CL}"

msg_info()  { echo -e "${INFO} ${YW}$1${CL}"; }
msg_ok()    { echo -e "  ${GN}✔${CL} ${GN}$1${CL}"; }
msg_error() { echo -e "${ERROR} ${RD}$1${CL}" >&2; }

# $STD: run quietly; on failure re-run showing the last 40 lines (debug chain)
STD() { "$@" >/dev/null 2>&1 || { "$@" 2>&1 | tail -n 40 >&2; false; }; }

on_error() {
    local exit_code=$1 line=$2 cmd=$3
    echo "" >&2
    echo -e "${RD}══════════════════════════════════════════════════════${CL}" >&2
    echo -e "${RD}  IN-CONTAINER INSTALL FAILED — full error chain${CL}" >&2
    echo -e "${RD}══════════════════════════════════════════════════════${CL}" >&2
    echo -e "  ✘ Failed command : ${BOLD}${cmd}${CL}" >&2
    echo -e "  ✘ Exit code      : ${RD}${exit_code}${CL}" >&2
    echo -e "  ✘ Script line    : ${line}" >&2
    echo "" >&2
    echo -e "${YW}── docker info (last 15 lines) ──${CL}" >&2
    { docker info 2>&1 | tail -n 15 || true; } >&2
    echo -e "${YW}── docker compose ps (in ${COMPOSE_DIR}) ──${CL}" >&2
    { cd "$COMPOSE_DIR" 2>/dev/null && docker compose ps 2>&1 || true; } >&2
    echo -e "${YW}── docker compose logs (last 40 lines) ──${CL}" >&2
    { cd "$COMPOSE_DIR" 2>/dev/null && docker compose logs --tail=40 2>&1 || true; } >&2
    echo -e "${YW}── journalctl -u puter (last 25 lines) ──${CL}" >&2
    { journalctl -u puter -n 25 --no-pager 2>&1 || true; } >&2
    echo -e "${RD}══════════════════════════════════════════════════════${CL}" >&2
    echo -e "${YW}Debug re-run: bash -x /tmp/puter-install.sh${CL}" >&2
}
trap 'on_error $? $LINENO "${BASH_COMMAND}"' ERR

# ── Docker idmap failure detection ──────────────────────────────────────────
# Some images ship layers with out-of-range UIDs (e.g. UID 718322462).
# Inside an UNPRIVILEGED LXC (64k UID idmap) extraction fails with
# "failed to Lchown ... invalid argument". The containerd "increase
# subuid/subgid" hint does NOT apply inside LXC. Detect the signature and
# fail with the real cause + fix instead of a generic error.
is_idmap_failure() {  # exit 0 if $1 contains the signature
    grep -qiE "failed to (extract layer|lchown)|lchown.*invalid argument" "$1" 2>/dev/null
}
print_idmap_diagnosis() {
    echo "IDMAP_FAILURE_DETECTED" >&2
    msg_error "Docker cannot extract an image layer: image UIDs exceed this container's idmap."
    msg_error "Root cause: unprivileged LXC maps only 64k UIDs; the image needs more (lchown EINVAL)."
    msg_error "Fix: recreate the CT privileged — on the host: PUTER_UNPRIVILEGED=0 <installer> — or use a QEMU VM."
}
# compose_q: quiet docker compose op; on failure prints tail + idmap diagnosis.
compose_q() {
    local log
    log=$(mktemp /tmp/puter-compose-XXXXXX.log)
    if docker compose "$@" >"$log" 2>&1; then
        rm -f "$log"
        return 0
    fi
    tail -n 40 "$log" >&2
    if is_idmap_failure "$log"; then
        print_idmap_diagnosis
    fi
    rm -f "$log"
    return 1
}

# ── IP-Mode (no DNS needed): Caddy + config wiring ───────────────────────────
ip_mode_ip() {
    # CT LAN IP: host passes PUTER_CTIP; fallback to local detection.
    if [[ -n "${PUTER_CTIP:-}" ]]; then printf '%s' "$PUTER_CTIP"; return 0; fi
    hostname -I 2>/dev/null | awk '{print $1}'
}
write_ipmode_caddyfile() {
    # $1 = CT IP. :80 GUI (root origin), :8080 API with Host+X-Forwarded-Host
    # rewritten to api.<IP> (Express reads subdomains from X-Forwarded-Host
    # under trust_proxy!), :8081 S3 with Host preserved for valid signatures.
    local ip="$1"
    cat <<EOF
# IP-Mode Caddyfile (no wildcard DNS needed) — generated by puter-install.sh.
{
	auto_https off
}

(puter_routes) {
	request_body {
		max_size 1024MiB
	}
	handle {
		reverse_proxy puter:4100 {
			flush_interval -1
		}
	}
}

:80 {
	import puter_routes
}

:8080 {
	request_body {
		max_size 1024MiB
	}
	handle {
		reverse_proxy puter:4100 {
			flush_interval -1
			header_up Host api.${ip}
			header_up X-Forwarded-Host api.${ip}
		}
	}
}

:8081 {
	reverse_proxy s3:9000
}
EOF
}
patch_config_ipmode() {
    # $1=ip $2=api_port $3=s3_port — point GUI/API/S3 at bare IP:ports.
    # domain is (re)set to the current CT IP so config.origin recomputes
    # correctly on every boot (guiOriginOnly gate compares browser Origin).
    local ip="$1" api_port="$2" s3_port="$3" cfg="puter/config/config.json"
    jq --arg domain "$ip" \
       --arg api "http://${ip}:${api_port}" \
       --arg s3 "http://${ip}:${s3_port}" \
        '.domain = $domain
         | .api_base_url = $api
         | .s3.s3Config.publicEndpoint = $s3' \
        "$cfg" > "${cfg}.new" \
        && mv "${cfg}.new" "$cfg"
    chmod 0666 "$cfg" 2>/dev/null || true
}
reset_config_standard() {
    # Undo ONLY our IP-Mode keys (leave user customizations alone).
    # Also restores .domain: an IP-Mode install stores the bare CT IP there,
    # which would leave Puter subdomain-gated on api.<IP> after the downgrade
    # (stock config writes "domain": "<PUTER_DOMAIN>" + s3 endpoint http://s3.<domain>).
    local cfg="puter/config/config.json" cur_api cur_s3
    cur_api=$(jq -r '.api_base_url // empty' "$cfg" 2>/dev/null || true)
    cur_s3=$(jq -r '.s3.s3Config.publicEndpoint // empty' "$cfg" 2>/dev/null || true)
    if [[ "$cur_api" =~ :${PUTER_API_PORT}$ ]] || [[ "$cur_s3" =~ :${PUTER_S3_PORT}$ ]]; then
        jq --arg domain "$PUTER_DOMAIN" \
           --arg s3 "http://s3.${PUTER_DOMAIN}" \
            'del(.api_base_url) | .domain = $domain | .s3.s3Config.publicEndpoint = $s3' \
            "$cfg" > "${cfg}.new" \
            && mv "${cfg}.new" "$cfg"
        chmod 0666 "$cfg" 2>/dev/null || true
    fi
}
apply_ip_mode() {
    local ip api_port s3_port
    ip=$(ip_mode_ip)
    api_port="${PUTER_API_PORT}"; s3_port="${PUTER_S3_PORT}"
    [[ -n "$ip" ]] || { msg_error "IP-Mode needs the CT IP (PUTER_CTIP empty, hostname -I empty)."; return 1; }
    msg_info "IP-Mode: API :${api_port} + S3 :${s3_port} on ${ip} (no DNS needed)"
    cd "$COMPOSE_DIR"
    cat > docker-compose.override.yml <<EOF
# IP-Mode (no DNS needed): expose API + S3 on extra Caddy ports.
# Auto-loaded by docker compose alongside docker-compose.yml — survives
# 'compose pull' refreshes of the base file by the official installer.
services:
  caddy:
    ports:
      - "${api_port}:8080"
      - "${s3_port}:8081"
EOF
    # Backup stock Caddyfile once (skip if current file is already ours).
    if [[ -f caddy/Caddyfile ]] && ! grep -q "IP-Mode Caddyfile" caddy/Caddyfile 2>/dev/null; then
        cp caddy/Caddyfile caddy/Caddyfile.stock
    fi
    write_ipmode_caddyfile "$ip" > caddy/Caddyfile
    patch_config_ipmode "$ip" "$api_port" "$s3_port"
    msg_ok "IP-Mode configured (override + Caddyfile + api_base_url + S3 endpoint + domain)"
}
remove_ip_mode() {
    # Clean downgrade path back to standard (DNS) mode.
    cd "$COMPOSE_DIR"
    local changed=0
    if [[ -f docker-compose.override.yml ]]; then rm -f docker-compose.override.yml; changed=1; fi
    if [[ -f caddy/Caddyfile.stock ]]; then cp caddy/Caddyfile.stock caddy/Caddyfile; changed=1; fi
    local before_api before_s3
    before_api=$(jq -r '.api_base_url // empty' puter/config/config.json 2>/dev/null || true)
    before_s3=$(jq -r '.s3.s3Config.publicEndpoint // empty' puter/config/config.json 2>/dev/null || true)
    reset_config_standard
    local after_api after_s3
    after_api=$(jq -r '.api_base_url // empty' puter/config/config.json 2>/dev/null || true)
    after_s3=$(jq -r '.s3.s3Config.publicEndpoint // empty' puter/config/config.json 2>/dev/null || true)
    [[ "$before_api" != "$after_api" || "$before_s3" != "$after_s3" ]] && changed=1
    if [[ "$changed" -eq 1 ]]; then
        msg_info "Standard (DNS) mode restored — IP-Mode artifacts removed"
    fi
    return 0
}

# ── Preflight ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { msg_error "Run as root inside the CT."; exit 1; }
msg_info "In-container install starting (domain=${PUTER_DOMAIN}, port=${PUTER_PORT}, ip=${PUTER_CTIP:-dhcp}, update-mode=${UPDATE_MODE})"
export DEBIAN_FRONTEND=noninteractive

# ── Step 1: OS + base packages ───────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    msg_info "Updating OS (apt update + upgrade)"
    STD apt-get update
    STD apt-get -y upgrade
    msg_ok "OS updated"

    msg_info "Installing base packages (curl, wget, ca-certificates, openssl, jq)"
    STD apt-get install -y curl wget ca-certificates openssl gnupg jq
    msg_ok "Base packages installed"
else
    msg_info "Docker already present — skipping OS/base package setup"
fi

# ── Step 2: Docker Engine + compose plugin ───────────────────────────────────
if ! command -v docker &>/dev/null; then
    msg_info "Installing Docker Engine + compose plugin (get.docker.com)"
    # Download to a file first: STD's on-failure re-run would otherwise read
    # an already-consumed stdin (empty) and fail with a misleading error.
    GET_DOCKER_SH=$(mktemp /tmp/get-docker-XXXXXX.sh)
    curl -fsSL https://get.docker.com -o "$GET_DOCKER_SH"
    STD sh "$GET_DOCKER_SH"
    rm -f "$GET_DOCKER_SH"
    msg_ok "Docker installed: $(docker --version)"
fi
STD systemctl enable --now docker
msg_ok "Docker service enabled + started"

docker info >/dev/null 2>&1 || { msg_error "Docker daemon not reachable."; exit 1; }
docker compose version >/dev/null 2>&1 || { msg_error "docker compose plugin missing."; exit 1; }

# jq is required for config.json / daemon.json edits — also in update-only
# runs, where Step 1 (base packages) is skipped when Docker is already present.
if ! command -v jq >/dev/null 2>&1; then
    msg_info "Installing jq (needed for config edits)"
    STD apt-get update
    STD apt-get install -y jq
    msg_ok "jq installed"
fi

# ── Step 3: docker log rotation (before the stack starts) ───────────────────
if ! grep -q "max-size" /etc/docker/daemon.json 2>/dev/null; then
    msg_info "Configuring docker log rotation (50 MB × 3 per container)"
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"3"}}' \
            /etc/docker/daemon.json > /etc/docker/daemon.json.new \
            && mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    else
        printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "50m", "max-file": "3" }\n}\n' \
            > /etc/docker/daemon.json
    fi
    STD systemctl restart docker
    sleep 3
    msg_ok "Docker log rotation configured"
else
    msg_ok "Docker log rotation already configured"
fi

# ── Step 4: Puter stack — official installer or update ──────────────────────
mkdir -p "$INSTALL_ROOT"

if [[ -f "${COMPOSE_DIR}/docker-compose.yml" && -f "${COMPOSE_DIR}/.env" ]]; then
    msg_info "Existing Puter installation found in ${COMPOSE_DIR} — updating"
    cd "$COMPOSE_DIR"
    # Re-apply the data-dir permissions the official installer sets (0777 for
    # non-root container UIDs: mysql, dynamodb uid 1000, rustfs uid 10001).
    # CRITICAL: puter/config must stay world-readable (0777 dir + 0666
    # config.json) — the puter container runs as uid 1000 (node) and falls
    # back to sqlite defaults with an EACCES crash-loop if it cannot read
    # its own config.json (e.g. after a stack copy/restore).
    chmod 0777 puter/data/valkey puter/data/mariadb puter/data/dynamo \
        puter/data/s3 puter/data/puter puter/data/caddy 2>/dev/null || true
    chmod 0777 puter/config 2>/dev/null || true
    chmod 0666 puter/config/config.json 2>/dev/null || true
    compose_q pull || exit 1
    compose_q up -d --remove-orphans || exit 1
    msg_ok "Puter stack updated (compose pull + up)"
else
    msg_info "Running official Puter self-host installer"
    msg_info "  PUTER_DIR=${COMPOSE_DIR}  PUTER_DOMAIN=${PUTER_DOMAIN}  PUTER_PORT=${PUTER_PORT}"
    # Official installer: downloads docker-compose.yml + caddy/Caddyfile,
    # generates secrets, writes .env + puter/config/config.json (idempotent:
    # keeps existing secrets), runs docker compose up -d.
    # Output is tee'd to a temp log so a Docker idmap failure can be diagnosed
    # with the real cause instead of a generic error.
    OFFICIAL_LOG=$(mktemp /tmp/puter-official-XXXXXX.log)
    if ! curl -fsSL https://raw.githubusercontent.com/HeyPuter/puter/main/install.sh \
        | env PUTER_DIR="$COMPOSE_DIR" \
              PUTER_DOMAIN="$PUTER_DOMAIN" \
              PUTER_PORT="$PUTER_PORT" \
              PUTER_ENV=prod \
              PUTER_TRUST_PROXY=1 \
              sh 2>&1 | tee "$OFFICIAL_LOG"; then
        if is_idmap_failure "$OFFICIAL_LOG"; then
            print_idmap_diagnosis
        else
            msg_error "Official Puter installer failed — full output above"
        fi
        rm -f "$OFFICIAL_LOG"
        exit 1
    fi
    rm -f "$OFFICIAL_LOG"
    msg_ok "Puter stack installed via official installer"
    # NOTE: the official installer cd's in its own subshell — our cwd is still
    # wherever pct exec started us (usually /). cd explicitly, otherwise
    # docker compose finds no config file ("no configuration file provided").
    cd "$COMPOSE_DIR"
    # Re-assert desired state through our own wrapper (idempotent no-op).
    compose_q up -d --remove-orphans || exit 1
fi

cd "$COMPOSE_DIR"
[[ -f docker-compose.yml ]] || { msg_error "docker-compose.yml missing in ${COMPOSE_DIR}."; exit 1; }

# ── IP-Mode conversion (or clean downgrade back to standard DNS mode) ───────
if [[ "$PUTER_IP_MODE" == "1" ]]; then
    apply_ip_mode
else
    remove_ip_mode
fi

# ── Step 5: systemd unit (reboot-safe, requirement 6) ───────────────────────
msg_info "Installing systemd unit puter.service"
if [[ -f /tmp/puter.service ]]; then
    cp /tmp/puter.service /etc/systemd/system/puter.service
else
    msg_error "/tmp/puter.service missing (host script did not push it)"
    exit 1
fi
# Bake the compose dir into the unit via drop-in (unit file stays generic)
mkdir -p /etc/systemd/system/puter.service.d
cat > /etc/systemd/system/puter.service.d/compose-dir.conf <<EOF
[Service]
WorkingDirectory=${COMPOSE_DIR}
EOF
systemctl daemon-reload
STD systemctl enable puter
msg_ok "systemd unit installed + enabled (After=network-online.target + docker)"

msg_info "Ensuring puter.service is started (idempotent — no restart churn on updates)"
# NOTE: start, not restart — systemd restart on this oneshot unit runs
# ExecStop (= docker compose down!) first, tearing the whole stack down and
# recreating it on every installer re-run. 'start' is a no-op when already
# active(exited) and still brings it up on fresh installs / failed units.
STD systemctl start puter
msg_ok "puter.service active"

# ── Step 6a: wait for the puter container ──────────────────────────────────
msg_info "Waiting for the 'puter' container (first boot ~60–120 s: MariaDB init + migrations)"
DEADLINE=$((SECONDS + 300))
until docker compose ps --status running --services 2>/dev/null | grep -qx 'puter'; do
    if (( SECONDS > DEADLINE )); then
        msg_error "'puter' container not running after 300 s — full state:"
        docker compose ps >&2 || true
        docker compose logs --tail=60 puter >&2 || true
        exit 1
    fi
    sleep 5
done
msg_ok "Puter container is running"

# ── Step 6b: wait for the web UI (HTTP) ──────────────────────────────────────
msg_info "Waiting for web UI on localhost:${PUTER_PORT} (up to 180 s)"
HTTP_CODE=000
DEADLINE=$((SECONDS + 180))
while (( SECONDS < DEADLINE )); do
    HTTP_CODE=$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' \
        "http://localhost:${PUTER_PORT}/" 2>/dev/null || echo 000)
    case "$HTTP_CODE" in 200|301|302) break ;; esac
    sleep 5
done
case "$HTTP_CODE" in
    200|301|302) msg_ok "Web UI answers on http://localhost:${PUTER_PORT}/ (HTTP ${HTTP_CODE})" ;;
    *)
        msg_error "Web UI did not answer within 180 s (last HTTP code: ${HTTP_CODE})"
        docker compose ps >&2 || true
        docker compose logs --tail=60 >&2 || true
        exit 1
        ;;
esac

# ── Step 6b2: IP-Mode checks (API :8080 must route, S3 :8081 must answer) ────
if [[ "$PUTER_IP_MODE" == "1" ]]; then
    msg_info "Verifying IP-Mode API on localhost:${PUTER_API_PORT} (expect HTTP 401 = route exists, auth required)"
    API_CODE=$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d '{"path":"/"}' "http://localhost:${PUTER_API_PORT}/readdir" 2>/dev/null || echo 000)
    if [[ "$API_CODE" != "401" ]]; then
        msg_error "IP-Mode API check failed (HTTP ${API_CODE}, expected 401) — subdomain rewrite broken?"
        docker compose logs --tail=40 caddy >&2 || true
        exit 1
    fi
    msg_ok "IP-Mode API answers on http://localhost:${PUTER_API_PORT}/ (HTTP 401)"

    msg_info "Verifying IP-Mode S3 on localhost:${PUTER_S3_PORT} (expect HTTP 403 = RustFS reachable)"
    S3_CODE=$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' \
        "http://localhost:${PUTER_S3_PORT}/" 2>/dev/null || echo 000)
    if [[ "$S3_CODE" != "403" ]]; then
        msg_error "IP-Mode S3 check failed (HTTP ${S3_CODE}, expected 403)"
        docker compose logs --tail=40 caddy >&2 || true
        exit 1
    fi
    msg_ok "IP-Mode S3 answers on http://localhost:${PUTER_S3_PORT}/ (HTTP 403)"
fi

# ── Step 6c: first-boot admin password (printed once by puter) ───────────────
# Emphasized output line; the host script greps it from /var/log/puter-install.log.
if [[ "$UPDATE_MODE" -eq 0 ]]; then
    sleep 5
    ADMIN_LINE=$(docker compose logs puter 2>/dev/null | grep -E "password for admin|tmp_password" | tail -n 1 || true)
    if [[ -n "$ADMIN_LINE" ]]; then
        echo "ADMIN_PASSWORD_LINE: ${ADMIN_LINE}"
        msg_ok "First-boot admin password extracted (see ADMIN_PASSWORD_LINE above)"
    else
        echo -e "  ${YW}⚠ admin password line not found yet — retrieve with:${CL}"
        echo -e "    cd ${COMPOSE_DIR} && docker compose logs puter | grep -E 'password for admin|tmp_password'"
    fi
fi

# ── Step 6d: firewall (usually inactive in LXC — documented no-op) ──────────
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    STD ufw allow "${PUTER_PORT}/tcp"
    if [[ "$PUTER_IP_MODE" == "1" ]]; then
        STD ufw allow "${PUTER_API_PORT}/tcp"
        STD ufw allow "${PUTER_S3_PORT}/tcp"
    fi
    msg_ok "ufw: web port(s) allowed"
else
    msg_ok "No active firewall (ufw) — ports are open"
fi

msg_info "In-container install completed successfully"
exit 0
