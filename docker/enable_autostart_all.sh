#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
COMPOSE="$ROOT/docker-compose.yml"
PRJ="$(basename "$ROOT")"
UNIT="/etc/systemd/system/${PRJ}.service"

echo -e "${Y}▶ Enabling auto-start for all stack services...${N}"

# 0) Pre-flight
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${R}Docker is not installed on this host.${N}"; exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo -e "${R}Docker Compose plugin is missing (docker compose).${N}"; exit 1
fi
if [[ ! -f "$COMPOSE" ]]; then
  echo -e "${R}Missing compose file:${N} $COMPOSE"; exit 1
fi

# 1) Backup compose
cp -a "$COMPOSE" "$COMPOSE.bak.$(date +%F_%H-%M-%S)"
echo -e "${G}✔ Backed up docker-compose.yml${N}"

# 2) Patch compose: remove container_name, normalize restart: unless-stopped for all services
TMP="$(mktemp)"
# remove container_name lines anywhere
sed -E '/^[[:space:]]*container_name:[[:space:]].*$/d' "$COMPOSE" > "$TMP.1"

# remove any restart lines under services (we will re-add uniformly)
awk '
  BEGIN{in_services=0}
  /^services:[[:space:]]*$/ {in_services=1; print; next}
  in_services && /^[^[:space:]]/ {in_services=0; print; next}
  {
    if (in_services && $0 ~ /^[[:space:]]*restart:[[:space:]]/) next;
    print
  }
' "$TMP.1" > "$TMP.2"

# insert restart: unless-stopped immediately after each service header
awk '
  BEGIN{in_services=0}
  /^services:[[:space:]]*$/ {in_services=1; print; next}
  in_services && /^[^[:space:]]/ {in_services=0; print; next}
  {
    if (in_services && $0 ~ /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/) {
      print
      print "  restart: unless-stopped"
      next
    }
    print
  }
' "$TMP.2" > "$TMP.3"

mv "$TMP.3" "$COMPOSE"
rm -f "$TMP" "$TMP.1" "$TMP.2"
echo -e "${G}✔ Added restart: unless-stopped to all services${N}"

# 3) Enable Docker at boot
echo -e "${Y}• Enabling docker service at boot…${N}"
sudo systemctl enable docker >/dev/null || true

# 4) Create systemd unit to bring stack up on boot
echo -e "${Y}• Installing systemd unit ${PRJ}.service…${N}"
sudo bash -c "cat > '$UNIT' <<'UNIT'
[Unit]
Description=Compose stack: sms-procurement-manager
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/home/user/sms-procurement-manager
ExecStart=/usr/bin/docker compose -f /home/user/sms-procurement-manager/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /home/user/sms-procurement-manager/docker-compose.yml down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT"

sudo systemctl daemon-reload
sudo systemctl enable "${PRJ}.service"

# 5) Recreate stack now (to bake restart policies)
echo -e "${Y}• Rebuilding and starting stack…${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 6) Also set restart policy on any currently created containers (belt & suspenders)
echo -e "${Y}• Applying restart policy to existing containers…${N}"
docker ps -aq --filter "label=com.docker.compose.project=${PRJ}" | while read -r id; do
  [[ -n "$id" ]] && docker update --restart unless-stopped "$id" >/dev/null || true
done
echo -e "${G}✔ Restart policy applied to running containers${N}"

# 7) Show status
echo -e "${Y}• Current containers:${N}"
docker ps --filter "label=com.docker.compose.project=${PRJ}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "${G}✅ Auto-start is configured.${N}
- On boot: docker starts, containers auto-restart, and systemd runs: ${PRJ}.service
- To check after reboot:  sudo systemctl status ${PRJ}.service && docker ps
- To disable:             sudo systemctl disable ${PRJ}.service
- To start/stop now:      docker compose -f \"$COMPOSE\" up -d / down
"
