# Puter on Proxmox VE — Community-Scripts-Style Installer

**Puter** ([HeyPuter/puter](https://github.com/HeyPuter/puter)) — das Open-Source „Internet Computer": selbst-gehostete Personal Cloud mit Desktop-Umgebung im Browser, Dateiverwaltung, Apps und puter.js.

Dieses Repo enthält einen Installer, der Puter als **LXC-Container** auf Proxmox VE installiert — im Stil und Look der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

---

## Voraussetzungen

| | |
|---|---|
| **Proxmox VE** | 8.x oder 9.x (getestet: PVE 9.1) |
| **Ressourcen CT** | 2 vCPU, 3 GB RAM, 8 GB Disk (Default) |
| **Host-RAM frei** | ≥ 4 GB (Stack: MariaDB, Valkey, DynamoDB-local, RustFS, Caddy, Puter) |
| **DNS (wichtig!)** | **Wildcard-Eintrag** `*.puter.lan → <CT-IP>` auf deinem LAN-DNS-Server |

### ⚠️ Warum Wildcard-DNS zwingend ist

Puter 26.x betreibt seine Backend-API auf der **`api.`-Subdomain** seiner Domain (95+ Backend-Routen sind subdomain-ge-gated: Dateioperationen, Events, Auth, Drivers …). Die GUI ruft `window.api_origin` (= `api.<domain>`) für nahezu alle Operationen auf.

- **Ohne** Wildcard-DNS: `http://<CT-IP>` lädt die Desktop-Shell, aber **Login schlägt fehl** bzw. Datei-Operationen brechen mit `404`/CORS-Fehlern.
- **Mit** Wildcard-DNS (`*.puter.lan → CT-IP`): alles funktioniert (`puter.lan`, `api.puter.lan`, `site.puter.lan`, `<user>.site.puter.lan`, …).

Einrichten (Beispiel auf deinem LAN-DNS-Server, z. B. Bind/PowerDNS/Pi-hole/AdGuard):

```
puter.lan.        IN A   <CT-IP>     ; die CT-IP nach der Installation
*.puter.lan.      IN A   <CT-IP>     ; Wildcard für api./site./app./…
```

> Die CT-IP per DHCP beziehen und dann im DNS nachziehen — oder dem CT im Script per `PUTER_STATIC_IP` eine statische IP geben (siehe Variablen unten).

---

## Installation (Einzeiler)

Auf dem **Proxmox-Host** als root ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
```

Das Script:
1. fragt nach **CT-ID** (Enter = nächste freie ID) und der **Domain** (Default `puter.lan`)
2. erstellt den LXC (unprivilegiert, Debian 13, `nesting=1,keyctl=1`, `onboot=1`, DHCP)
3. installiert Docker + den offiziellen Puter-Stack (`docker compose`) im CT
4. richtet den **systemd-Service `puter.service`** ein (`After=network-online.target`, reboot-sicher)
5. **verifiziert selbst**: `systemctl is-active`, HTTP-Check im CT + vom Host, Admin-Passwort-Ausgabe
6. setzt CT-Beschreibung + Tags (Community-Scripts-Optik)

Erwartete Ausgabe (Auszug):

```
        ____           __
       / __ \___  ____/ /__  __
      / /_/ / _ \/ __  / -_) |/ /
     / ____/  __/ /_/ /\__/|___/
    /_/    \___/\__,_/  Puter on Proxmox VE
        Community-Scripts-style LXC installer

Info: Creating LXC 103 (puter: 2 vCPU, 3072 MiB RAM, 8 GB disk, Debian 13, storage: local-lvm)
  ✔ Created LXC 103
Info: Running in-container installer (Docker + Puter stack + systemd) — takes several minutes
  ✔ In-container install finished (log: /var/log/puter-install.log)
Info: Verifying service (systemctl is-active puter)
  ✔ Service puter: active
Info: Verifying web UI (HTTP check inside CT on localhost:80)
  ✔ Web UI answers inside CT (HTTP 200)
Info: Verifying web UI from the Proxmox host: http://192.168.178.50:80/
  ✔ Web UI reachable from host: http://192.168.178.50:80/

✔ Puter setup has been successfully initialized!

  Web UI  : http://192.168.178.50   (domain: puter.lan)
  DNS     : *.puter.lan -> 192.168.178.50  (wildcard, required for login/API)
  Login   : user 'admin' + first-boot temp password (install log)
  Logs    : pct exec 103 -- journalctl -u puter -f
  Update  : re-run this installer (update mode)
  Uninstall: pct stop 103 && pct destroy 103 --purge
```

## Variablen (env-overridable)

| Variable | Default | Bedeutung |
|---|---|---|
| `PUTER_CTID` | prompt | CT-ID (Enter = nächste freie) |
| `PUTER_DOMAIN` | prompt (`puter.lan`) | Domain mit Wildcard-DNS |
| `PUTER_PORT` | `80` | Web-UI-Port |
| `PUTER_CORES` / `PUTER_RAM` / `PUTER_DISK` | 2 / 3072 / 8 | CT-Ressourcen |
| `PUTER_STORAGE` | `local-lvm` | Storage für CT-Rootfs |
| `PUTER_BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `PUTER_VERSION_TEMPLATE` | `13` | Debian-Version des LXC-Templates |

Beispiel — kleiner CT mit anderem Storage:

```bash
PUTER_CTID=200 PUTER_RAM=2048 PUTER_STORAGE=local \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
```

## Update

Installer **erneut ausführen** (gleicher CT): erkennt bestehende Installation und fährt `docker compose pull && docker compose up -d` (Update-Modus, idempotent). Konfiguration/Secrets/Daten bleiben erhalten.

Alternativ im CT manuell:

```bash
pct exec <CTID> -- bash -c 'cd /opt/puter/puter-selfhosted && docker compose pull && docker compose up -d'
```

## Deinstallation

```bash
pct stop <CTID>
pct destroy <CTID> --purge   # entfernt CT + Disk + Config
```

Daten liegen komplett im CT (`/opt/puter/puter-selfhosted/puter/data`) — mit dem CT verschwinden sie.

## Reboot-Test (Beleg)

```bash
pct reboot <CTID>
# nach ~1–2 min:
pct exec <CTID> -- systemctl is-active puter          # → active
pct exec <CTID> -- curl -s -o /dev/null -w '%{http_code}\n' http://localhost/   # → 200
```

### Test-Beleg aus dem echten Durchlauf (Sandbox, identischer Ablauf wie im CT)

```
$ PUTER_DOMAIN=puter.lan UPDATE_MODE=1 bash /tmp/puter-install.sh
Info: In-container install starting (domain=puter.lan, port=80, ip=192.168.178.51, update-mode=1)
  ✔ Docker service enabled + started
  ✔ Docker log rotation already configured
Info: Existing Puter installation found in /opt/puter/puter-selfhosted — updating
  ✔ Puter stack updated (compose pull + up)
Info: Installing systemd unit puter.service
  ✔ systemd unit installed + enabled (After=network-online.target + docker)
  ✔ puter.service active
  ✔ Puter container is running
  ✔ Web UI answers on http://localhost:80/ (HTTP 200)
Info: In-container install completed successfully          ← EXIT 0

# Reboot-Simulation (systemctl stop docker+puter → start wie beim Boot):
$ systemctl is-active puter docker
active
active
$ docker ps --format '{{.Names}}\t{{.Status}}'
puter-caddy   Up 45 seconds (healthy)
puter         Up 46 seconds (healthy)
puter-mariadb Up 59 seconds (healthy)
puter-s3      Up 59 seconds (healthy)
puter-dynamo  Up 59 seconds
puter-valkey  Up 59 seconds (healthy)
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost/
200                                                        ← Web UI nach Reboot wieder erreichbar
```

Zusätzlich verifiziert im Testlauf:
- `POST /login` auf der Root-Origin → **Token** kommt zurück (Login funktioniert mit Wildcard-DNS)
- `POST /readdir` mit `Host: api.<domain>` → Dateilisting (Subdomain-Routing aktiv)
- `POST /readdir` mit Root-Host → `not_found` (Beweis, dass api-Subdomain zwingend ist)

## Debugging

- **Vollständige Fehlerkette**: beide Scripts haben einen `ERR`-Trap, der bei jedem Fehler **Exit-Code, fehlgeschlagenen Befehl, Zeile + CT-Install-Log, docker-compose-Logs und `systemctl status`** ausgibt — nie nur die letzte Zeile.
- **`bash -x`**: Script erst herunterladen, dann tracen:
  ```bash
  wget -qO /tmp/puter.sh https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh
  bash -x /tmp/puter.sh
  ```
- **Logs im CT**: `/var/log/puter-install.log`, `journalctl -u puter`, `docker compose logs`.

## Struktur

```
install/puter.sh           # Host-Script (Einzeiler-Einstieg; CT-Erstellung + Verifikation)
install/puter-install.sh    # Container-Script (Docker + offizieller Puter-Installer + systemd)
systemd/puter.service       # systemd-Unit (reboot-sicher)
```

## Lizenz / Quellen

- Puter: AGPL-3.0 — https://github.com/HeyPuter/puter
- Installer-Style angelehnt an: https://github.com/community-scripts/ProxmoxVE (MIT)
