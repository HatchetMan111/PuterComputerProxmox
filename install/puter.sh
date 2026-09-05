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
# Privilege mode of the CT: 1 = unprivileged (default, fine for well-behaved
# images), 0 = privileged (needed when an image ships out-of-range UIDs that
# cannot be extracted in a 64k idmap — "failed to Lchown ... invalid argument").
PUTER_UNPRIVILEGED="${PUTER_UNPRIVILEGED:-1}"
# Public domain Puter serves on. MUST be resolvable via wildcard DNS
# (*.PUTER_DOMAIN -> CT IP). Puter 26.x gates 95+ backend routes behind
# the api.<domain> subdomain — see README section "DNS".
PUTER_DOMAIN="${PUTER_DOMAIN:-}"
# HTTP port of the web UI (Caddy listen port inside the CT)
PUTER_PORT="${PUTER_PORT:-80}"
# IP-Mode (no DNS needed): 1 = serve API+S3 on bare IP ports (Caddy rewrites
# Host to api.<CT-IP> server-side). Core features work; user site/app hosting
# still needs wildcard DNS. 0 = standard DNS mode (default).
PUTER_IP_MODE="${PUTER_IP_MODE:-0}"
PUTER_API_PORT="${PUTER_API_PORT:-8080}"
PUTER_S3_PORT="${PUTER_S3_PORT:-8081}"

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
    # Best-effort cleanup of the temp push dir (unset if we failed very early).
    # NOTE: this must happen HERE (after capturing $1/$2/$3), never as a
    # separate command inside the trap string — anything running before
    # on_error would clobber $? and the report would show exit code 0.
    if [[ -n "${PUSH_DIR:-}" && -d "$PUSH_DIR" ]]; then
        rm -rf "$PUSH_DIR" 2>/dev/null || true
    fi
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
        # Docker idmap wall? → precise remediation instead of a generic failure
        if pct exec "$PUTER_CTID" -- bash -c \
            'grep -qiE "failed to (extract layer|lchown)|lchown.*invalid argument|IDMAP_FAILURE_DETECTED" /var/log/puter-install.log 2>/dev/null'; then
            echo -e "${YW}  ── DIAGNOSIS: Docker image UIDs exceed the container idmap ──${CL}" >&2
            echo -e "  Unprivileged LXC (64k UIDs) + image with out-of-range UIDs = lchown EINVAL." >&2
            echo -e "  The 'increase subuid/subgid' hint does NOT apply inside LXC." >&2
            echo -e "  Fix: recreate the CT privileged, then re-run the installer:" >&2
            echo -e "    pct stop ${PUTER_CTID} && pct destroy ${PUTER_CTID} --purge" >&2
            echo -e "    PUTER_UNPRIVILEGED=0 PUTER_CTID=${PUTER_CTID} bash -c \"\$(wget -qLO - ${PUTER_REPO_RAW}/install/puter.sh)\"" >&2
            echo "" >&2
        fi
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
for cmd in pct pvesh qm pveam pvesm wget curl; do
    command -v "$cmd" >/dev/null 2>&1 \
        || { msg_error "Missing required command: '$cmd' — run this on the Proxmox host."; exit 1; }
done
if ! pvesh get /storage --output json 2>/dev/null | grep -q "\"${PUTER_STORAGE}\""; then
    msg_error "Storage '${PUTER_STORAGE}' not found on this node. Available storages:"
    pvesh get /storage --output json 2>/dev/null \
        | grep -oE '"storage":"[^"]*"' | cut -d'"' -f4 | sed 's/^/    /' >&2 || true
    exit 1
fi
if [[ "$PUTER_UNPRIVILEGED" != "0" && "$PUTER_UNPRIVILEGED" != "1" ]]; then
    msg_error "PUTER_UNPRIVILEGED must be 0 (privileged, for images with exotic UIDs) or 1 (unprivileged, default)."
    exit 1
fi
if [[ "$PUTER_IP_MODE" != "0" && "$PUTER_IP_MODE" != "1" ]]; then
    msg_error "PUTER_IP_MODE must be 0 (standard DNS mode, default) or 1 (no-DNS IP mode)."
    exit 1
fi

# ── Guest inventory helpers ─────────────────────────────────────────────────
# Robust against the classic traps:
#  * `pct status` fails for qemu VMIDs (wrong tool) — never use it for existence
#  * `pct list` hides qemu guests — next-free-ID must scan cluster resources
#  * pasted/typed IDs may carry whitespace/CR — always sanitize + validate
cluster_vmids() {
    pvesh get /cluster/resources --output json 2>/dev/null \
        | grep -oE '"vmid": ?[0-9]+' | grep -oE '[0-9]+' || true
}
vmid_taken() {  # exit 0 = taken (lxc OR qemu), 1 = free
    local id="$1"
    cluster_vmids | grep -qx "$id"
}
guest_type() {  # prints: lxc | qemu | none
    local id="$1"
    if pct config "$id" &>/dev/null; then echo lxc; return 0; fi
    if qm config "$id" &>/dev/null; then echo qemu; return 0; fi
    echo none
}
next_free_ctid() {
    local id=100 used
    used=$(cluster_vmids)
    while printf '%s\n' "$used" | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}
validate_ctid() {  # sanitize + validate; prints clean id, returns 1 if bad
    local raw="$1" clean
    clean=$(printf '%s' "$raw" | tr -d '[:space:]')
    if ! [[ "$clean" =~ ^[0-9]+$ ]]; then return 1; fi
    if ! (( 10#$clean >= 100 && 10#$clean <= 999999999 )); then return 1; fi
    printf '%s' "$clean"
}
ask_domain() {
    [[ -n "$PUTER_DOMAIN" ]] && return 0
    echo ""
    echo -e "${YW}Puter 26.x serves its backend API on the 'api.' subdomain${CL}"
    echo -e "${YW}of its domain (95+ routes are subdomain-gated). Plan:${CL}"
    echo -e "  ${BOLD}1)${CL} choose a domain, e.g.  ${BOLD}puter.lan${CL}"
    echo -e "  ${BOLD}2)${CL} create wildcard DNS      ${BOLD}*.puter.lan -> <CT-IP>${CL}  (on your LAN DNS)"
    echo -e "     (also: puter.lan itself; *.site.puter.lan is handled by the same wildcard)"
    echo ""
    local input=""
    read -r -p "$(echo -e "${YW}Domain to serve Puter on [puter.lan]:${CL}") " input || true
    PUTER_DOMAIN="${input:-puter.lan}"
    if [[ "$PUTER_DOMAIN" =~ ^[0-9.]+$ ]]; then
        echo -e "  ${YW}⚠ '${PUTER_DOMAIN}' is a bare IP: 'api.<ip>' can never resolve, so login/API will fail.${CL}"
        echo -e "  ${YW}  Use a real domain with wildcard DNS — or '<ct-ip-with-dashes>.nip.io' (see README).${CL}"
    fi
}
ensure_running_and_detect() {
    # For an existing LXC: start it if needed, verify pct exec works,
    # set HAS_INSTALL (1 = previous Puter install found). Fatal on failure.
    local state
    state=$(pct status "$PUTER_CTID" 2>/dev/null | awk '{print $2}' || echo unknown)
    if [[ "$state" != "running" ]]; then
        msg_info "Starting existing CT ${PUTER_CTID} (state: ${state:-unknown})"
        pct start "$PUTER_CTID"
        msg_ok "CT started"
    fi
    if ! pct exec "$PUTER_CTID" -- true 2>/dev/null; then
        msg_error "Cannot run commands in CT ${PUTER_CTID} (pct exec failed) — is it healthy?"
        exit 1
    fi
    if pct exec "$PUTER_CTID" -- test -f /opt/puter/puter-selfhosted/docker-compose.yml 2>/dev/null; then
        HAS_INSTALL=1
    else
        HAS_INSTALL=0
    fi
}

# ── DNS resolvability check (warning only — the install itself is fine) ─────
# Browsers must resolve BOTH names; a loading GUI shell means nothing.
# Sets DNS_OK=1/0. Never fails the install (DNS can be fixed afterwards).
check_dns() {
    msg_info "Checking DNS: ${PUTER_DOMAIN} + api.${PUTER_DOMAIN} must resolve (wildcard -> ${CT_IP})"
    DNS_OK=1
    local h resolved
    for h in "${PUTER_DOMAIN}" "api.${PUTER_DOMAIN}"; do
        resolved=$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | head -n1 || true)
        if [[ -z "$resolved" ]]; then
            msg_error "Does NOT resolve (Proxmox host): ${h}"
            DNS_OK=0
        elif [[ "$resolved" != "$CT_IP" ]]; then
            echo -e "  ${YW}⚠${CL} Resolves to UNEXPECTED ip (host): ${h} -> ${resolved} (expected ${CT_IP})"
            DNS_OK=0
        else
            msg_ok "Resolves (host): ${h} -> ${resolved}"
        fi
        if ! pct exec "$PUTER_CTID" -- getent hosts "$h" >/dev/null 2>&1; then
            msg_error "Does NOT resolve (inside CT): ${h}"
            DNS_OK=0
        fi
    done
    if [[ "$DNS_OK" -ne 1 ]]; then
        echo ""
        echo -e "${RD}${BOLD}  ⚠ DNS NOT READY — web UI shell loads, but login/API will fail${CL}"
        echo -e "  The browser must resolve BOTH names (checked above from host + CT):"
        echo -e "    ${BOLD}${PUTER_DOMAIN}   ->  ${CT_IP}${CL}"
        echo -e "    ${BOLD}*.${PUTER_DOMAIN}  ->  ${CT_IP}${CL}   (wildcard: api./site./app. subdomains)"
        echo -e "  Create these A-records on your LAN DNS server, then verify ON THE CLIENT PC:"
        echo -e "    nslookup ${PUTER_DOMAIN}      nslookup api.${PUTER_DOMAIN}"
        echo -e "  Both must answer ${CT_IP} — and the client must actually USE that DNS server"
        echo -e "  (check DHCP/DNS settings; e.g. FritzBox hands out itself by default)."
        echo -e "  No wildcard-capable DNS? Fallback: PUTER_DOMAIN=<ct-ip-with-dashes>.nip.io (see README)."
        echo ""
    fi
}

# ── CT ID: prompt with validation, robust existence detection ───────────────
if [[ -n "${PUTER_CTID:-}" ]]; then
    if ! PUTER_CTID=$(validate_ctid "$PUTER_CTID"); then
        msg_error "Invalid PUTER_CTID (must be numeric, 100-999999999)."
        exit 1
    fi
else
    DEFAULT_ID=$(next_free_ctid)
    PUTER_CTID=""
    for _ in 1 2 3; do
        INPUT_ID=""
        read -r -p "$(echo -e "${YW}Enter CT ID [Press ENTER for ${DEFAULT_ID}]:${CL}") " INPUT_ID || break
        INPUT_ID="${INPUT_ID:-$DEFAULT_ID}"
        if CLEAN_ID=$(validate_ctid "$INPUT_ID"); then
            PUTER_CTID="$CLEAN_ID"
            break
        fi
        msg_error "Invalid CT ID '${INPUT_ID}' — must be numeric (100-999999999). Try again."
    done
    [[ -n "${PUTER_CTID:-}" ]] || { msg_error "No valid CT ID entered."; exit 1; }
fi

# ── What lives at this VMID? (lxc / qemu / none) ────────────────────────────
case "$(guest_type "$PUTER_CTID")" in
    qemu)
        msg_error "VMID ${PUTER_CTID} is a QEMU virtual machine, not an LXC container."
        msg_error "This installer manages LXC only — pick another ID (next free: $(next_free_ctid))."
        exit 1
        ;;
    lxc)
        NEED_CREATE=0
        ensure_running_and_detect
        if [[ "$HAS_INSTALL" -eq 1 ]]; then
            msg_info "CT ${PUTER_CTID} has an existing Puter install — update mode (data + secrets kept)"
        else
            msg_info "CT ${PUTER_CTID} exists but has no Puter install — fresh install into it"
        fi
        ;;
    none)
        NEED_CREATE=1
        HAS_INSTALL=0
        ;;
esac
UPDATE_MODE=$HAS_INSTALL

# ── Domain (prompt only for fresh DNS-mode installs) ─────────────────────────
if [[ "$HAS_INSTALL" -eq 0 && "$PUTER_IP_MODE" != "1" ]]; then
    ask_domain
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

# ── Template resolution (local cache first, pveam download fallback) ───────
resolve_template() {
    # prints "store:vztmpl/file"; prefers 'local', scans any vztmpl storage
    local pat="debian-${PUTER_VERSION_TEMPLATE}-standard" store fname
    for store in local $(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}' | grep -vx local || true); do
        fname=$(pveam list "$store" 2>/dev/null | grep -oE "${pat}[^ ]*\.tar\.zst" | sort -V | tail -n1 || true)
        if [[ -n "$fname" ]]; then
            printf '%s:vztmpl/%s' "$store" "$fname"
            return 0
        fi
    done
    return 1
}
template_store() {
    # storage to download templates to: local if vztmpl-capable, else first such storage
    local stores first
    stores=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}' || true)
    if printf '%s\n' "$stores" | grep -qx local; then echo local; return 0; fi
    first=$(printf '%s\n' "$stores" | head -n1)
    [[ -n "$first" ]] || return 1
    echo "$first"
}
download_template() {
    # downloads newest matching template into $1; prints volid
    local store="$1" file
    msg_info "Updating template index (pveam update ${store})"
    pveam update "$store" >/dev/null 2>&1 || true
    file=$(pveam available --section system 2>/dev/null \
        | grep -oE "debian-${PUTER_VERSION_TEMPLATE}-standard[^ \"']*\.tar\.zst" \
        | sort -V | tail -n1 || true)
    [[ -n "$file" ]] || { msg_error "No Debian ${PUTER_VERSION_TEMPLATE} template in pveam index."; return 1; }
    msg_info "Downloading template ${file} to '${store}'"
    pveam download "$store" "$file"
    printf '%s:vztmpl/%s' "$store" "$file"
}

# ── Create the container (skipped when reusing an existing CT) ──────────────
if [[ "$NEED_CREATE" -eq 1 ]]; then
    msg_info "Resolving Debian ${PUTER_VERSION_TEMPLATE} LXC template"
    if ! TEMPLATE=$(resolve_template); then
        TS=$(template_store) || { msg_error "No storage with 'vztmpl' content found."; exit 1; }
        TEMPLATE=$(download_template "$TS") || exit 1
    fi
    msg_ok "Template: ${TEMPLATE}"

    msg_info "Creating LXC ${PUTER_CTID} (${PUTER_CTHOSTNAME}: ${PUTER_CORES} vCPU, ${PUTER_RAM} MiB RAM, ${PUTER_DISK} GB disk, storage: ${PUTER_STORAGE}, $([[ "$PUTER_UNPRIVILEGED" == "0" ]] && echo privileged || echo unprivileged))"
    if CREATE_OUT=$(pct create "$PUTER_CTID" "$TEMPLATE" \
            --hostname "$PUTER_CTHOSTNAME" \
            --cores "$PUTER_CORES" \
            --memory "$PUTER_RAM" \
            --swap 512 \
            --rootfs "${PUTER_STORAGE}:${PUTER_DISK}" \
            --net0 "name=eth0,bridge=${PUTER_BRIDGE},ip=dhcp,type=veth" \
            --features nesting=1,keyctl=1 \
            --unprivileged "$PUTER_UNPRIVILEGED" \
            --onboot 1 \
            --start 0 2>&1); then
        msg_ok "Created LXC ${PUTER_CTID}"
        msg_info "Starting container"
        pct start "$PUTER_CTID"
        msg_ok "Container started"
    elif echo "$CREATE_OUT" | grep -qi "already exists"; then
        # Race (or stale inventory): the guest appeared meanwhile — continue
        # idempotently instead of failing with the ERR trap.
        msg_info "CT ${PUTER_CTID} already exists — continuing in place (idempotent)"
        NEED_CREATE=0
        if [[ "$(guest_type "$PUTER_CTID")" != "lxc" ]]; then
            msg_error "VMID ${PUTER_CTID} is not an LXC container — aborting."
            exit 1
        fi
        ensure_running_and_detect
        UPDATE_MODE=$HAS_INSTALL
        if [[ "$HAS_INSTALL" -eq 0 && "$PUTER_IP_MODE" != "1" ]]; then
            ask_domain
        fi
    else
        echo "$CREATE_OUT" >&2
        exit 1
    fi
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

# IP-Mode: domain IS the CT IP (assigned now that the IP is known); no DNS.
if [[ "$PUTER_IP_MODE" == "1" ]]; then
    PUTER_DOMAIN="$CT_IP"
    msg_info "IP-Mode: domain = CT IP (${CT_IP}); no DNS needed (API :${PUTER_API_PORT}, S3 :${PUTER_S3_PORT})"
fi

# ── Fetch and push container-side installer + systemd unit (GitHub-first) ──
msg_info "Fetching puter-install.sh + puter.service from repo"
PUSH_DIR=$(mktemp -d)
# NOTE: PUSH_DIR cleanup happens inside on_error (trap at top of script) —
# never prepend commands to the trap string, they would clobber $?.
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
export PUTER_IP_MODE='${PUTER_IP_MODE}'
export PUTER_API_PORT='${PUTER_API_PORT}'
export PUTER_S3_PORT='${PUTER_S3_PORT}'
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

# api-subdomain routing check (standard DNS mode only; informational).
# POST /readdir without token must answer 401 (route exists, auth required) —
# a 404 here means the api subdomain does not route (wildcard DNS missing).
if [[ "$PUTER_IP_MODE" != "1" ]]; then
    msg_info "Probing api.${PUTER_DOMAIN} routing (Host header -> ${CT_IP}; informational)"
    API_PROBE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -H "Host: api.${PUTER_DOMAIN}" \
        -X POST -H 'Content-Type: application/json' -d '{"path":"/"}' \
        "http://${CT_IP}:${PUTER_PORT}/readdir" 2>/dev/null || echo 000)
    if [[ "$API_PROBE" == "401" ]]; then
        msg_ok "api.${PUTER_DOMAIN} routes to backend (HTTP 401 = auth required, routing works)"
    else
        echo -e "  ${YW}⚠${CL} api.${PUTER_DOMAIN} probe returned HTTP ${API_PROBE} (expected 401) — check wildcard DNS *.${PUTER_DOMAIN} -> ${CT_IP}${CL}"
    fi

    # Resolvability from host + CT (warning only — see check_dns)
    check_dns
else
    # IP-Mode: verify API + S3 on bare IP ports (401/403 prove routing)
    msg_info "Verifying IP-Mode API from host: http://${CT_IP}:${PUTER_API_PORT}/readdir (expect 401)"
    API_PROBE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' -d '{"path":"/"}' \
        "http://${CT_IP}:${PUTER_API_PORT}/readdir" 2>/dev/null || echo 000)
    if [[ "$API_PROBE" != "401" ]]; then
        msg_error "IP-Mode API check from host failed (HTTP ${API_PROBE}, expected 401)"
        exit 1
    fi
    msg_ok "IP-Mode API reachable from host (HTTP 401)"

    msg_info "Verifying IP-Mode S3 from host: http://${CT_IP}:${PUTER_S3_PORT}/ (expect 403)"
    S3_PROBE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
        "http://${CT_IP}:${PUTER_S3_PORT}/" 2>/dev/null || echo 000)
    if [[ "$S3_PROBE" != "403" ]]; then
        msg_error "IP-Mode S3 check from host failed (HTTP ${S3_PROBE}, expected 403)"
        exit 1
    fi
    msg_ok "IP-Mode S3 reachable from host (HTTP 403)"
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
if [[ "$PUTER_IP_MODE" == "1" ]]; then
    CT_DESC_EXTRA="IP-Mode, no DNS needed (API :${PUTER_API_PORT}, S3 :${PUTER_S3_PORT})"
else
    CT_DESC_EXTRA="Domain: ${PUTER_DOMAIN}"
fi
pct set "$PUTER_CTID" \
    --description "<div align='center'>
  <a href='https://github.com/HeyPuter/puter'><img src='https://assets.puter.site/puter-logo.png' alt='Puter' style='width:60px;'/></a>
  <h2 style='font-size:18px;'>Puter LXC</h2>
  <p>Web UI: <a href='http://${CT_IP}:${PUTER_PORT}'>http://${CT_IP}:${PUTER_PORT}</a> — ${CT_DESC_EXTRA}</p>
  <p style='font-size:12px;'>Community-scripts style installer · Update: re-run installer · Remove: pct destroy ${PUTER_CTID}</p>
</div>" \
    --tags "${PUTER_TAG}" >/dev/null
msg_ok "CT description + tags set"

# ── Finish ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GN}${BOLD}✔ ${APP} setup has been successfully initialized!${CL}"
echo ""
if [[ "$PUTER_IP_MODE" == "1" ]]; then
    echo -e "  ${BGN}Web UI  :${CL} http://${CT_IP}:${PUTER_PORT}   (IP-Mode, no DNS needed)"
    echo -e "  ${BGN}API     :${CL} http://${CT_IP}:${PUTER_API_PORT}  (desktop talks here automatically)"
    echo -e "  ${BGN}S3      :${CL} http://${CT_IP}:${PUTER_S3_PORT}  (file uploads/downloads)"
    echo -e "  ${BGN}Limits  :${CL} user site/app hosting needs wildcard DNS (see README)"
else
    echo -e "  ${BGN}Web UI  :${CL} http://${CT_IP}:${PUTER_PORT}   (domain: ${PUTER_DOMAIN})"
    if [[ "${DNS_OK:-0}" -eq 1 ]]; then
        echo -e "  ${BGN}DNS     :${CL} *.${PUTER_DOMAIN} -> ${CT_IP}  ${GN}(resolving ✓)${CL}"
    else
        echo -e "  ${BGN}DNS     :${CL} *.${PUTER_DOMAIN} -> ${CT_IP}  ${RD}(NOT resolving — fix DNS, see warning above!)${CL}"
    fi
fi
echo -e "  ${BGN}Login   :${CL} user 'admin' + first-boot temp password (install log)"
echo -e "  ${BGN}Logs    :${CL} pct exec ${PUTER_CTID} -- journalctl -u puter -f"
echo -e "  ${BGN}Update  :${CL} re-run this installer (update mode) — or in CT: cd /opt/puter && docker compose pull && docker compose up -d"
echo -e "  ${BGN}Uninstall:${CL} pct stop ${PUTER_CTID} && pct destroy ${PUTER_CTID} --purge"
echo ""
exit 0
