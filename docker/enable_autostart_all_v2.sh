#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
COMPOSE="$ROOT/docker-compose.yml"
UNIT="/etc/systemd/system/sms-procurement-manager.service"

say(){ echo -e "$1"; }

say "${Y}▶ Enabling auto-start and fixing docker-compose if needed…${N}"

command -v docker >/dev/null || { say "${R}Docker not found.${N}"; exit 1; }
docker compose version >/dev/null 2>&1 || { say "${R}Docker Compose plugin missing (docker compose).${N}"; exit 1; }

# 1) Backup compose
if [[ -f "$COMPOSE" ]]; then
  cp -a "$COMPOSE" "$COMPOSE.bak.$(date +%F_%H-%M-%S)"
  say "${G}✔ Backed up docker-compose.yml${N}"
fi

# 2) If compose is missing or invalid, write a clean, known-good compose
NEED_REWRITE=0
if [[ ! -f "$COMPOSE" ]]; then
  NEED_REWRITE=1
else
  if ! docker compose -f "$COMPOSE" config >/dev/null 2>&1; then
    NEED_REWRITE=1
  fi
fi

if [[ "$NEED_REWRITE" -eq 1 ]]; then
  say "${Y}• Writing clean docker-compose.yml …${N}"
  cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: smsdb
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [stack]

  api:
    build:
      context: .
      dockerfile: api.Dockerfile
    restart: unless-stopped
    environment:
      DB_URL: postgresql://postgres:postgres@postgres:5432/smsdb
    depends_on: [postgres]
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    restart: unless-stopped
    depends_on: [api]
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata:

networks:
  stack:
YAML
  say "${G}✔ docker-compose.yml written${N}"
fi

# 3) Remove container_name lines and legacy 'version:' key if present
sed -i -E '/^[[:space:]]*container_name:[[:space:]].*$/d' "$COMPOSE" || true
sed -i -E '/^[[:space:]]*version:[[:space:]].*$/d' "$COMPOSE" || true

# Validate again
if ! docker compose -f "$COMPOSE" config >/dev/null 2>&1; then
  say "${R}✖ Compose still invalid. Showing file:${N}"
  nl -ba "$COMPOSE"
  exit 1
fi
say "${G}✔ Compose validated${N}"

# 4) Ensure Docker service enabled at boot
sudo systemctl enable docker >/dev/null || true

# 5) Install systemd unit to bring stack up on boot
say "${Y}• Installing systemd unit (sms-procurement-manager.service)…${N}"
sudo bash -c "cat > '$UNIT' <<UNIT
[Unit]
Description=Compose stack: sms-procurement-manager
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$ROOT
ExecStart=/usr/bin/docker compose -f $COMPOSE up -d
ExecStop=/usr/bin/docker compose -f $COMPOSE down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT"
sudo systemctl daemon-reload
sudo systemctl enable sms-procurement-manager.service >/dev/null

# 6) Recreate stack cleanly
say "${Y}• Rebuilding and starting stack…${N}"
docker compose -f "$COMPOSE" down --remove-orphans || true
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 7) Show status and quick health checks
IP=$(hostname -I | awk '{print $1}')
say "${Y}• Containers:${N}"
docker compose -f "$COMPOSE" ps

say "${Y}• Quick checks:${N}"
curl -sSf "http://${IP}:8010/openapi.json" >/dev/null && say "  ${G}API OK:${N} http://${IP}:8010/openapi.json" || say "  ${R}API not responding${N}"
curl -sSf "http://${IP}:5183" >/dev/null && say "  ${G}UI  OK:${N} http://${IP}:5183" || say "  ${R}UI  not responding${N}"

say "${G}✅ Done. Stack will auto-start on reboot.${N}
- Service: sudo systemctl status sms-procurement-manager
- Compose: docker compose -f \"$COMPOSE\" ps
- Reboot test recommended."
