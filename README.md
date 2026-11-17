# Puter on Proxmox VE — Community-Scripts-Style Installer

**Puter** ([HeyPuter/puter](https://github.com/HeyPuter/puter)) — das Open-Source „Internet Computer": selbst-gehostete Personal Cloud mit Desktop-Umgebung im Browser, Dateiverwaltung, Apps und puter.js.

Dieses Repo enthält einen Installer, der Puter als **LXC-Container** auf Proxmox VE installiert — im Stil und Look der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

---

## Voraussetzungen

| | |
|---|---|
| **Proxmox VE** | 8.x oder 9.x (getestet: PVE 9.1) |
| **Ressourcen CT** | 2 vCPU, 4 GB RAM, 8 GB Disk (Default) |
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

> Tipp für stabile DNS-Einträge: Lege im DHCP-Server eine **Reservierung** für den CT an (z. B. FritzBox: Heimnetz → Netzwerk → „diesem Gerät immer dieselbe IP zuweisen") — dann bleibt die CT-IP dauerhaft gleich.

> **FritzBox-Hinweis:** Die FritzBox kann **keine** Wildcard-Einträge. Entweder einen separaten LAN-DNS mit Wildcard-Support betreiben (Pi-hole, AdGuard Home, dnsmasq, BIND) und Clients/DHCP darauf zeigen lassen — oder den nip.io-Fallback unten nutzen.
>
> **Ganz wichtig:** Die Clients müssen den DNS-Server auch tatsächlich **nutzen**. Standardmäßig verteilt z. B. die FritzBox sich selbst per DHCP — Einträge auf einem anderen Server greifen dann ins Leere. **Auf dem Client-PC** (nicht auf dem Proxmox-Host!) prüfen:
> ```
> nslookup puter.lan
> nslookup api.puter.lan
> ```
> Beide müssen die CT-IP antworten. Der Installer prüft das übrigens selbst (Host + CT) und warnt deutlich, wenn es nicht auflöst.

#### Fallback ohne eigenes DNS: nip.io

Öffentlicher Wildcard-DNS — `192.168.178.96.nip.io` löst (bei Internet-Zugang der Clients) automatisch auf `192.168.178.96` auf, ebenso `api.192.168.178.96.nip.io` und jede weitere Subdomain. Kein eigener DNS-Server nötig:

```bash
PUTER_DOMAIN=192.168.178.96.nip.io bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
```

(CT-IP vorher ermitteln oder DHCP-Reservierung nutzen, damit sie stabil bleibt.)
Hinweise: Nur die DNS-Auflösung läuft über einen öffentlichen Dienst — App-Daten bleiben im LAN. Router mit DNS-Rebind-Schutz (z. B. FritzBox) filtern solche Antworten ggf.; dann nip.io unter *Heimnetz → DNS-Rebind-Schutz → Ausnahmen* freigeben oder doch eigenes DNS nutzen.

#### IP-Mode: ganz ohne DNS (`PUTER_IP_MODE=1`)

> **Der Installer fragt von selbst.** Sobald die CT-IP bekannt ist, prüft er, ob `api.<domain>` schon auf diese IP zeigt. Tut es das nicht, bietet er **vor** dem mehrminütigen Install den Wechsel in den IP-Mode an (Default `Y`, mit `n` abwählbar). Grund: Ohne Wildcard-DNS lädt zwar die Desktop-Hülle, aber jeder API-Aufruf läuft ins Leere — sichtbar als weiße Seite bzw. „undefined value" statt als verständliche Fehlermeldung. In nicht-interaktiven Läufen (gepiped) wird nie still umgestellt; dort wird stattdessen der fertige IP-Mode-Befehl ausgegeben.

Für Umgebungen mit unbekanntem DNS-Server (kein Wildcard möglich, kein nip.io gewünscht): Der Installer biegt API + S3 auf reine IP-Ports um — Caddy schreibt den Host-Header serverseitig auf `api.<CT-IP>` um, sodass Puters Subdomain-Gate greift, während Browser nur die CT-IP ansprechen. Komplett lokal, kein externer Dienst:

```bash
PUTER_IP_MODE=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
```

Erreichbar danach: Desktop/GUI `http://<CT-IP>` (:80), API `http://<CT-IP>:8080`, S3 `http://<CT-IP>:8081` (Ports via `PUTER_API_PORT`/`PUTER_S3_PORT` änderbar). Verifiziert: Login, Datei-Operationen, whoami, S3, Socket.io-Realtime, Cookies.

Grenzen (technisch bedingt, kein Bug): User-Site-/App-Hosting (`<name>.site.<domain>`, dynamische Subdomains) geht ohne DNS nicht — dafür braucht es Wildcard-DNS oder nip.io. Alles andere (Desktop, Dateien, Store-Apps, Freigaben, KI-Provider) läuft.

Technisch: `docker-compose.override.yml` (Caddy-Ports, updatefest) + generierte `caddy/Caddyfile` (Host-Rewrite, Backup als `Caddyfile.stock`) + `api_base_url`/`publicEndpoint`/`domain` in `config.json`. Zurück auf DNS-Modus: Installer ohne `PUTER_IP_MODE` erneut ausführen — der Installer erkennt die IP-„Domain" in der Config, fragt ggf. nach der echten Domain und restauriert `domain` + S3-Endpoint + Caddyfile sauber.

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

Info: Creating LXC 103 (puter: 2 vCPU, 4096 MiB RAM, 8 GB disk, Debian 13, storage: local-lvm)
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
  Login   : user 'admin' + temp password: 11c5e58c6b4b0453114ab89469180767
              (the login field takes the username — no email needed, self-hosted sends no confirmation mails)
              (change the password after first login — the temp password stays valid until then)
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
| `PUTER_CORES` / `PUTER_RAM` / `PUTER_DISK` | 2 / 4096 / 8 | CT-Ressourcen (4 GB: MariaDB + DynamoDB Local (JVM) + RustFS + Node) |
| `PUTER_STORAGE` | `local-lvm` | Storage für CT-Rootfs |
| `PUTER_BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `PUTER_VERSION_TEMPLATE` | `13` | Debian-Version des LXC-Templates |
| `PUTER_UNPRIVILEGED` | `1` | `1` = unprivileged (Default), `0` = privileged (nötig bei Images mit exotischen UIDs, siehe Debugging) |
| `PUTER_IP_MODE` | `0` | `1` = No-DNS-Modus: API auf `:8080`, S3 auf `:8081`, alles per reiner CT-IP (siehe unten) |
| `PUTER_API_PORT` / `PUTER_S3_PORT` | 8080 / 8081 | Ports des IP-Modes (nur wenn `PUTER_IP_MODE=1`) |

Beispiel — kleiner CT mit anderem Storage:

```bash
PUTER_CTID=200 PUTER_RAM=2048 PUTER_STORAGE=local \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
```

## Update

Installer **erneut ausführen** (gleicher CT): erkennt bestehende Installation und fährt `docker compose pull && docker compose up -d` (Update-Modus, idempotent). Konfiguration/Secrets/Daten bleiben erhalten.

Robustheit: Die CT-ID wird gegen den **gesamten Cluster** geprüft (LXC + QEMU, via `pvesh`), Eingaben werden validiert, QEMU-IDs werden mit klarem Fehler abgelehnt, und ein existierender CT **ohne** Puter-Installation wird direkt für die Neuinstallation wiederverwendet. Eine `pct create`-Kollision („already exists") schaltet automatisch in den Update-Modus statt abzubrechen.

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

## Bekannte Upstream-Lücke: „Apps hinzufügen" → „Something went wrong"

Der Desktop-Dialog **„Apps hinzufügen"** öffnet die Einträge *„Find an app"* (App Center) und *„Create an app with AI"* (Builder) **per App-Namen** (`app-center` / `builder`). Puters Postgres-Migrationen seeden `app-center` — der **MySQL/MariaDB-Migrationspfad** (den der Self-Host-Stack nutzt) jedoch **nicht**. Ergebnis ohne Gegenmaßnahme: Klick auf diese Optionen → App-Lookup 404 → „Something went wrong".

Der Installer seedet beide Apps deshalb selbst (Step 6b3, `INSERT IGNORE` → idempotent):

| App | index_url | Hinweis |
|---|---|---|
| `app-center` | `https://app-center.puter.com` | offizielle, von Puter gehostete Store-Seite |
| `builder` | `https://builder.puter.com` | offizieller KI-App-Builder |

Beide Seiten sind externe, von puter.com gehostete Apps — der Browser braucht also Internet-Zugang (die App-Daten selbst bleiben auf deiner Instanz). Wichtig: Nach dem Installer-Re-Run die Desktop-Seite einmal neu laden (Strg+F5), damit die App-Liste neu gezogen wird.

Manuell prüfen/nachziehen (im CT):

```bash
cd /opt/puter/puter-selfhosted
docker compose exec -T mariadb sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' \
  -e "SELECT name, index_url FROM apps WHERE name IN ('app-center','builder');"
```

## Debugging

- **Vollständige Fehlerkette**: beide Scripts haben einen `ERR`-Trap, der bei jedem Fehler **Exit-Code, fehlgeschlagenen Befehl, Zeile + CT-Install-Log, docker-compose-Logs und `systemctl status`** ausgibt — nie nur die letzte Zeile.
- **`bash -x`**: Script erst herunterladen, dann tracen:
  ```bash
  wget -qO /tmp/puter.sh https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh
  bash -x /tmp/puter.sh
  ```
- **Logs im CT**: `/var/log/puter-install.log`, `journalctl -u puter`, `docker compose logs`.

### Docker: `failed to extract layer` / `lchown ... invalid argument`

Manche Images enthalten Layer mit UIDs außerhalb der 64k-idmap eines **unprivilegierten** LXCs (z. B. UID 718322462). Der Installer erkennt die Signatur, meldet `IDMAP_FAILURE_DETECTED` mit der echten Ursache und bricht sauber ab. (Der containerd-Hinweis „subuid/subgid erhöhen" gilt **nicht** im LXC.) Fix — CT privilegiert neu erstellen:

```bash
pct stop <CTID> && pct destroy <CTID> --purge
PUTER_UNPRIVILEGED=0 PUTER_CTID=<CTID> bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PuterComputerProxmox/main/install/puter.sh)"
```

## Struktur

```
install/puter.sh           # Host-Script (Einzeiler-Einstieg; CT-Erstellung + Verifikation)
install/puter-install.sh    # Container-Script (Docker + offizieller Puter-Installer + systemd)
systemd/puter.service       # systemd-Unit (reboot-sicher)
```

## Lizenz / Quellen

- Puter: AGPL-3.0 — https://github.com/HeyPuter/puter
- Installer-Style angelehnt an: https://github.com/community-scripts/ProxmoxVE (MIT)
