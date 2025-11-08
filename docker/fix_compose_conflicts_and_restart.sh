#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}🧹 Fixing container name conflicts + restarting stack...${N}"

# 1) If compose exists, patch out container_name and obsolete version line
if [[ -f "$COMPOSE" ]]; then
  cp -a "$COMPOSE" "$COMPOSE.bak.$(date +%s)"
  # remove 'version:' (Compose v2 ignores it and warns)
  sed -i -E '/^[[:space:]]*version:/d' "$COMPOSE"
  # remove any container_name: lines so Compose auto-names (avoids conflicts)
  sed -i -E '/^[[:space:]]*container_name:[[:space:]].*$/d' "$COMPOSE"
  echo -e "${G}✔ docker-compose.yml patched (no container_name, no version)${N}"
else
  echo -e "${R}✖ docker-compose.yml not found at $COMPOSE${N}"
  exit 1
fi

# 2) Stop current compose stack (if any)
docker compose -f "$COMPOSE" down --remove-orphans || true

# 3) Force-remove any leftover containers with the conflicting names
for c in docker-api-1 docker-postgres-1 docker-web-1; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
    echo -e "${Y}Removing leftover container: ${c}${N}"
    docker rm -f "$c" || true
  fi
done

# 4) Quick port sanity (8010 API, 5183 UI)
for port in 8010 5183; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"; then
    echo -e "${Y}⚠ Port ${port} is in use. Continuing, but startup may fail if another process binds it.${N}"
  fi
done

# 5) Build + up
echo -e "${Y}🐳 Building + starting compose...${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 6) Basic health-checks
sleep 5
IP=$(hostname -I | awk '{print $1}')
API="http://${IP}:8010/openapi.json"
UI="http://${IP}:5183"

echo -e "${Y}🌐 Checking API: ${API}${N}"
if curl -s --max-time 8 "$API" | grep -q '"openapi"'; then
  echo -e "${G}✔ API reachable${N}"
else
  echo -e "${R}✖ API not reachable. Recent logs:${N}"
  docker logs $(docker compose -f "$COMPOSE" ps -q api) | tail -n 120 || true
  exit 1
fi

echo -e "${Y}🌐 Checking UI: ${UI}${N}"
if curl -s --max-time 8 "$UI" | grep -qi '<!DOCTYPE html>'; then
  echo -e "${G}✔ UI reachable${N}"
else
  echo -e "${R}✖ UI not reachable. Nginx logs:${N}"
  docker logs $(docker compose -f "$COMPOSE" ps -q web) | tail -n 120 || true
  exit 1
fi

echo -e "${G}🚀 Done. Open UI: ${UI}${N}"
echo -e "If needed: in browser console run:"
echo -e "  localStorage.setItem('API_BASE','http://${IP}:8010'); location.reload()"
