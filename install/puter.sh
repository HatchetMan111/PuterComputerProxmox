#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Puter LXC Installer — Proxmox VE Community Scripts style
# App:  Puter — the open-source Internet Computer (self-hosted personal cloud)
# Repo: https://github.com/HeyPuter/puter
#
# One-liner (run on the Proxmox host as root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
#
# What this does:
#   1. Creates an unprivileged LXC (Debian, nesting+keyctl for Docker),
#      onboot=1, DHCP networking — or reuses an existing CT (update mode).
#   2. Pushes puter-install.sh + puter.service into the CT.
#   3. Inside the CT: installs Docker, runs the official Puter self-host
#      installer, enables the puter systemd service.
#   4. Verifies (systemctl is-active, HTTP checks, admin password) and
#      writes the CT description like the community scripts do.
#
# Idempotent: existing CT + existing install => update (compose pull + up -d).
# All variables are overridable via environment (PUTER_CTID, PUTER_DOMAIN, …).
#
# Copyright (c) 2026 — MIT License
# Source: https://github.com/HeyPuter/puter
# -----------------------------------------------------------------------------

set -euo pipefail

# ── User-adjustable variables (env-overridable) ─────────────────────────────
APP="Puter"
PUTER_REPO_RAW="${PUTER_REPO_RAW:-https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main}"
PUTER_CTID="${PUTER_CTID:-}"
PUTER_CTHOSTNAME="${PUTER_CTHOSTNAME:-puter}"
PUTER_OS="${PUTER_OS:-debian}"
PUTER_VERSION_TEMPLATE="${PUTER_VERSION_TEMPLATE:-13}"
PUTER_CORES="${PUTER_CORES:-2}"
PUTER_RAM="${PUTER_RAM:-3072}"
PUTER_DISK="${PUTER_DISK:-8}"
PUTER_BRIDGE="${PUTER_BRIDGE:-vmbr0}"
PUTER_STORAGE="${PUTER_STORAGE:-local-lvm}"
PUTER_TAG="${PUTER_TAG:-ai;cloud;community-script}"
# Public domain Puter serves on. MUST be resolvable via wildcard DNS
# (*.PUTER_DOMAIN -> CT IP). Puter 26.x gates 95+ backend routes behind
# the api.<domain> subdomain — see README section "DNS".
PUTER_DOMAIN="${PUTER_DOMAIN:-}"
# HTTP port of the web UI (Caddy listen port inside the CT)
PUTER_PORT="${PUTER_PORT:-80}"

# ── Colors (community-scripts style) ────────────────────────────────────────
if [[ -t 1 ]] && [[ "${PUTER_NO_COLOR:-}" != "1" ]]; then
    YW=$(printf '\033[1;33m'); GN=$(printf '\033[1;32m'); RD=$(printf '\033[1;31m')
    BGN=$(printf '\033[1;94m'); BOLD=$(printf '\033[1m'); CL=$(printf '\033[0m')
else
    YW=""; GN=""; RD=""; BGN=""; BOLD=""; CL=""
fi
INFO="${YW}Info:${CL}"
ERROR="${RD}ERROR:${CL}"

# ── Central error handler: full error chain ─────────────────────────────────
on_error() {
    local exit_code=$1 line=$2 cmd=$3
    echo "" >&2
    echo -e "${RD}════════════════════════════════════════════════════════════${CL}" >&2
    echo -e "${RD}  INSTALLATION FAILED — full error chain${CL}" >&2
    echo -e "${RD}════════════════════════════════════════════════════════════${CL}" >&2
    echo -e "  ✘ Failed command : ${BOLD}${cmd}${CL}" >&2
    echo -e "  ✘ Exit code      : ${RD}${exit_code}${CL}" >&2
    echo -e "  ✘ Script line   : ${line}" >&2
    echo -e "  ✘ CT (if any)   : ${PUTER_CTID:-none}" >&2
    echo "" >&2
    echo -e "${YW}Reproduce with full trace (bash -x):${CL}" >&2
    echo -e "  wget -qO /tmp/puter.sh '${PUTER_REPO_RAW%/install/puter.sh}/install/puter.sh' && bash -x /tmp/puter.sh" >&2
    echo "" >&2
    if [[ -n "${PUTER_CTID:-}" ]] && pct status "$PUTER_CTID" &>/dev/null; then
        echo -e "${YW}── Last 40 lines: /var/log/puter-install.log (in CT) ──${CL}" >&2
        pct exec "$PUTER_CTID" -- tail -n 40 /var/log/puter-install.log >&2 2>/dev/null || true
        echo "" >&2
        echo -e "${YW}── Last 40 lines: docker compose logs (in CT) ──${CL}" >&2
        pct exec "$PUTER_CTID" -- bash -c \
            'cd /opt/puter 2>/dev/null && docker compose logs --tail=40 2>&1 | tail -n 45' >&2 2>/dev/null || true
        echo "" >&2
        echo -e "${YW}── systemctl status puter (in CT) ──${CL}" >&2
        pct exec "$PUTER_CTID" -- bash -c \
            'systemctl status puter --no-pager -l 2>&1 | tail -n 25' >&2 2>/dev/null || true
        echo "" >&2
    fi
    echo -e "${RD}════════════════════════════════════════════════════════════${CL}" >&2
}
trap 'on_error $? $LINENO "${BASH_COMMAND}"' ERR

# ── Community-scripts style helpers ─────────────────────────────────────────
header_info() {
    clear 2>/dev/null || true
    echo -e "${BOLD}"
    cat <<-'EOF'
        ____           __
       / __ \___  ____/ /__  __
      / /_/ / _ \/ __  / -_) |/ /
     / ____/  __/ /_/ /\__/|___/
    /_/    \___/\__,_/  Puter on Proxmox VE
        Community-Scripts-style LXC installer
EOF
    echo -e "${CL}"
}
msg_info()  { echo -e "${INFO} ${YW}$1${CL}"; }
msg_ok()    { echo -e "  ${GN}✔${CL} ${GN}$1${CL}"; }
msg_error() { echo -e "${ERROR} ${RD}$1${CL}" >&2; }

# ── Preflight ──────────────────────────────────────────────────────────────
header_info
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must run as root on the Proxmox host."
    exit 1
fi
for cmd in pct pvesh wget curl; do
    command -v "$cmd" >/dev/null 2>&1 \
        || { msg_error "Missing required command: '$cmd' — run this on the Proxmox host."; exit 1; }
done
if ! pvesh get /storage --output json 2>/dev/null | grep -q "\"${PUTER_STORAGE}\""; then
    msg_error "Storage '${PUTER_STORAGE}' not found on this node. Available storages:"
    pvesh get /storage --output json 2>/dev/null \
        | grep -oE '"storage":"[^"]*"' | cut -d'"' -f4 | sed 's/^/    /' >&2 || true
    exit 1
fi

# ── CT ID prompt (community-scripts behavior) ──────────────────────────────
next_free_ctid() {
    local id=100
    while pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}
if [[ -z "$PUTER_CTID" ]]; then
    DEFAULT_ID=$(next_free_ctid)
    read -r -p "$(echo -e "${YW}Enter CT ID [Press ENTER for ${DEFAULT_ID}]:${CL}") " INPUT_ID
    PUTER_CTID="${INPUT_ID:-$DEFAULT_ID}"
fi

if pct status "$PUTER_CTID" &>/dev/null; then
    msg_info "CT ${PUTER_CTID} exists — update mode (existing install is updated, not overwritten)"
    UPDATE_MODE=1
else
    UPDATE_MODE=0
fi

# ── Domain requirement (wildcard DNS needed; see README) ────────────────────
if [[ "$UPDATE_MODE" -eq 0 ]] && [[ -z "$PUTER_DOMAIN" ]]; then
    echo ""
    echo -e "${YW}Puter 26.x serves its backend API on the 'api.' subdomain${CL}"
    echo -e "${YW}of its domain (95+ routes are subdomain-gated). Plan:${CL}"
    echo -e "  ${BOLD}1)${CL} choose a domain, e.g.  ${BOLD}puter.lan${CL}"
    echo -e "  ${BOLD}2)${CL} create wildcard DNS      ${BOLD}*.puter.lan -> <CT-IP>${CL}  (on your LAN DNS)"
    echo -e "     (also: puter.lan itself; *.site.puter.lan is handled by the same wildcard)"
    echo ""
    read -r -p "$(echo -e "${YW}Domain to serve Puter on [puter.lan]:${CL}") " INPUT_DOMAIN
    PUTER_DOMAIN="${INPUT_DOMAIN:-puter.lan}"
fi
if [[ "$UPDATE_MODE" -eq 1 ]]; then
    # Show the configured domain of the existing install (update keeps it)
    CONFIGURED_DOMAIN=$(pct exec "$PUTER_CTID" -- bash -c \
        "grep -o '\"domain\": \"[^\"]*\"' /opt/puter/puter-selfhosted/puter/config/config.json 2>/dev/null | head -n1 | cut -d'\"' -f4" 2>/dev/null || true)
    if [[ -n "$CONFIGURED_DOMAIN" ]]; then
        if [[ -n "$PUTER_DOMAIN" && "$PUTER_DOMAIN" != "$CONFIGURED_DOMAIN" ]]; then
            msg_info "Note: existing install serves domain '${CONFIGURED_DOMAIN}'; keeping it (PUTER_DOMAIN='${PUTER_DOMAIN}' ignored in update mode)"
        fi
        PUTER_DOMAIN="$CONFIGURED_DOMAIN"
    fi
fi

# ── Create the container ────────────────────────────────────────────────────
if [[ "$UPDATE_MODE" -eq 0 ]]; then
    msg_info "Creating LXC ${PUTER_CTID} (${PUTER_CTHOSTNAME}: ${PUTER_CORES} vCPU, ${PUTER_RAM} MiB RAM, ${PUTER_DISK} GB disk, Debian ${PUTER_VERSION_TEMPLATE}, storage: ${PUTER_STORAGE})"

    # Ensure the Debian template exists locally; download if missing
    if ! pvesh get /storage/local/content --content vztmpl --output json 2>/dev/null \
        | grep -q "${PUTER_OS}-${PUTER_VERSION_TEMPLATE}-standard"; then
        msg_info "Downloading Debian ${PUTER_VERSION_TEMPLATE} LXC template via pveam"
        pveam update local >/dev/null 2>&1 || true
        AVAILABLE=$(pveam available -section system 2>/dev/null \
            | awk -v os="${PUTER_OS}" -v ver="${PUTER_VERSION_TEMPLATE}" \
                '$2 ~ "^"os"-"ver"-standard" {print $2; exit}')
        [[ -n "$AVAILABLE" ]] || { msg_error "No Debian ${PUTER_VERSION_TEMPLATE} template found in pveam."; exit 1; }
        pveam download local "$AVAILABLE"
        TEMPLATE="local:vztmpl/${AVAILABLE}"
    else
        TEMPLATE=$(pvesh get /storage/local/content --content vztmpl --output json 2>/dev/null \
            | grep -oE "local:vztmpl/${PUTER_OS}-${PUTER_VERSION_TEMPLATE}-standard[^\"]*" | head -n1)
    fi
    [[ -n "$TEMPLATE" ]] || { msg_error "Could not resolve a Debian template volid."; exit 1; }

    pct create "$PUTER_CTID" "$TEMPLATE" \
        --hostname "$PUTER_CTHOSTNAME" \
        --cores "$PUTER_CORES" \
        --memory "$PUTER_RAM" \
        --swap 512 \
        --rootfs "${PUTER_STORAGE}:${PUTER_DISK}" \
        --net0 "name=eth0,bridge=${PUTER_BRIDGE},ip=dhcp,type=veth" \
        --features nesting=1,keyctl=1 \
        --unprivileged 1 \
        --onboot 1 \
        --start 0 >/dev/null
    msg_ok "Created LXC ${PUTER_CTID}"

    msg_info "Starting container"
    pct start "$PUTER_CTID"
    msg_ok "Container started"
fi

# ── Wait for network (DHCP lease) ───────────────────────────────────────────
msg_info "Waiting for container IP (DHCP)"
CT_IP=""
for _ in $(seq 1 60); do
    CT_IP=$(pct exec "$PUTER_CTID" -- bash -c \
        "ip -4 addr show eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print \$2}'" 2>/dev/null || true)
    [[ -n "$CT_IP" ]] && break
    sleep 2
done
if [[ -z "$CT_IP" ]]; then
    msg_error "No container IP after 120 s — DHCP/network problem. Diagnostics:"
    pct exec "$PUTER_CTID" -- bash -c 'ip addr; ip route; cat /etc/resolv.conf' 2>&1 | tail -n 25 >&2 || true
    exit 1
fi
msg_ok "Container IP: ${CT_IP}"

# ── Fetch and push container-side installer + systemd unit (GitHub-first) ──
msg_info "Fetching puter-install.sh + puter.service from repo"
PUSH_DIR=$(mktemp -d)
cleanup_push_dir() { rm -rf "$PUSH_DIR"; }
trap 'cleanup_push_dir; on_error $? $LINENO "${BASH_COMMAND}"' ERR

wget -q -O "${PUSH_DIR}/puter-install.sh" "${PUTER_REPO_RAW}/install/puter-install.sh" \
    || { msg_error "Could not fetch ${PUTER_REPO_RAW}/install/puter-install.sh"; exit 1; }
wget -q -O "${PUSH_DIR}/puter.service" "${PUTER_REPO_RAW}/systemd/puter.service" \
    || { msg_error "Could not fetch ${PUTER_REPO_RAW}/systemd/puter.service"; exit 1; }
msg_ok "Fetched install scripts from repo"

msg_info "Pushing scripts into CT ${PUTER_CTID}"
pct push "$PUTER_CTID" "${PUSH_DIR}/puter-install.sh" /tmp/puter-install.sh
pct push "$PUTER_CTID" "${PUSH_DIR}/puter.service" /tmp/puter.service
rm -rf "$PUSH_DIR"
msg_ok "Scripts pushed into CT"

# ── Run the in-container installer ──────────────────────────────────────────
msg_info "Running in-container installer (Docker + Puter stack + systemd) — takes several minutes"
pct exec "$PUTER_CTID" -- bash -c "
set -euo pipefail
export PUTER_DOMAIN='${PUTER_DOMAIN}'
export PUTER_PORT='${PUTER_PORT}'
export PUTER_CTIP='${CT_IP}'
export UPDATE_MODE='${UPDATE_MODE}'
bash /tmp/puter-install.sh 2>&1 | tee /var/log/puter-install.log
"
msg_ok "In-container install finished (log: /var/log/puter-install.log)"

# ── Verification (requirement 7) ────────────────────────────────────────────
msg_info "Verifying service (systemctl is-active puter)"
SVC_STATE=$(pct exec "$PUTER_CTID" -- bash -c 'systemctl is-active puter' 2>/dev/null || true)
if [[ "$SVC_STATE" != "active" ]]; then
    msg_error "Service 'puter' is NOT active (state: ${SVC_STATE:-unknown}). Full status:"
    pct exec "$PUTER_CTID" -- bash -c 'systemctl status puter --no-pager -l 2>&1 | tail -n 30' >&2 || true
    exit 1
fi
msg_ok "Service puter: active"

msg_info "Verifying web UI (HTTP check inside CT on localhost:${PUTER_PORT})"
HTTP_CODE=$(pct exec "$PUTER_CTID" -- bash -c \
    "curl -fsS -m 10 -o /dev/null -w '%{http_code}' http://localhost:${PUTER_PORT}/ || echo FAIL" 2>/dev/null || true)
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "301" && "$HTTP_CODE" != "302" ]]; then
    msg_error "HTTP check inside CT failed (code: ${HTTP_CODE:-none})"
    pct exec "$PUTER_CTID" -- bash -c \
        "curl -v http://localhost:${PUTER_PORT}/ 2>&1 | tail -n 20" >&2 || true
    exit 1
fi
msg_ok "Web UI answers inside CT (HTTP ${HTTP_CODE})"

msg_info "Verifying web UI from the Proxmox host: http://${CT_IP}:${PUTER_PORT}/"
if curl -fsS -m 10 -o /dev/null "http://${CT_IP}:${PUTER_PORT}/"; then
    msg_ok "Web UI reachable from host: http://${CT_IP}:${PUTER_PORT}/"
else
    msg_error "Web UI NOT reachable from host — check bridge '${PUTER_BRIDGE}' and firewall."
    curl -v "http://${CT_IP}:${PUTER_PORT}/" 2>&1 | tail -n 20 >&2 || true
    exit 1
fi

# api-subdomain check (only meaningful once wildcard DNS is set up) —
# report, but do not fail the install on it.
msg_info "Probing api.${PUTER_DOMAIN} (needs wildcard DNS -> ${CT_IP}; informational)"
if curl -fsS -m 8 -o /dev/null -H "Host: api.${PUTER_DOMAIN}" "http://${CT_IP}:${PUTER_PORT}/whoami" 2>/dev/null; then
    msg_ok "api.${PUTER_DOMAIN} reachable via Host header (wildcard DNS will work)"
else
    echo -e "  ${YW}⚠${CL} api.${PUTER_DOMAIN} not answering yet — set wildcard DNS *.${PUTER_DOMAIN} -> ${CT_IP}, then re-check${CL}"
fi

# ── First-boot admin password (Puter prints it once on first boot) ──────────
ADMIN_PW_LINES=$(pct exec "$PUTER_CTID" -- bash -c \
    'grep -h -i "tmp_password\|admin.*password" /var/log/puter-install.log 2>/dev/null | head -n 3' 2>/dev/null || true)
if [[ -n "$ADMIN_PW_LINES" ]]; then
    echo ""
    echo -e "${GN}  First-boot admin credentials (Puter prints these ONCE):${CL}"
    echo -e "${BOLD}${ADMIN_PW_LINES}${CL}"
    echo -e "  ${YW}Log in as 'admin' and change the password immediately.${CL}"
fi

# ── CT description + tags (community-scripts style) ────────────────────────
pct set "$PUTER_CTID" \
    --description "<div align='center'>
  <a href='https://github.com/HeyPuter/puter'><img src='https://assets.puter.site/puter-logo.png' alt='Puter' style='width:60px;'/></a>
  <h2 style='font-size:18px;'>Puter LXC</h2>
  <p>Web UI: <a href='http://${CT_IP}:${PUTER_PORT}'>http://${CT_IP}:${PUTER_PORT}</a> — Domain: ${PUTER_DOMAIN}</p>
  <p style='font-size:12px;'>Community-scripts style installer · Update: re-run installer · Remove: pct destroy ${PUTER_CTID}</p>
</div>" \
    --tags "${PUTER_TAG}" >/dev/null
msg_ok "CT description + tags set"

# ── Finish ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GN}${BOLD}✔ ${APP} setup has been successfully initialized!${CL}"
echo ""
echo -e "  ${BGN}Web UI  :${CL} http://${CT_IP}:${PUTER_PORT}   (domain: ${PUTER_DOMAIN}${PUTER_PORT_SUFFIX:-})"
echo -e "  ${BGN}DNS     :${CL} *.${PUTER_DOMAIN} -> ${CT_IP}  (wildcard, required for login/API)"
echo -e "  ${BGN}Login   :${CL} user 'admin' + first-boot temp password (install log)"
echo -e "  ${BGN}Logs    :${CL} pct exec ${PUTER_CTID} -- journalctl -u puter -f"
echo -e "  ${BGN}Update  :${CL} re-run this installer (update mode) — or in CT: cd /opt/puter && docker compose pull && docker compose up -d"
echo -e "  ${BGN}Uninstall:${CL} pct stop ${PUTER_CTID} && pct destroy ${PUTER_CTID} --purge"
echo ""
exit 0
