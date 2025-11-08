#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
WEB_DIR="$ROOT/web/public"
COMPOSE="$ROOT/docker-compose.yml"
WEB_DOCKERFILE="$ROOT/web.Dockerfile"

echo -e "${Y}🧰 Fixing UI 403 (Nginx permission) by baking UI into image…${N}"

# 0) Ensure web/public exists and has an index.html (create minimal if missing)
mkdir -p "$WEB_DIR"
if [[ ! -f "$WEB_DIR/index.html" ]]; then
  cat > "$WEB_DIR/index.html" <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
</head><body>
  <div id="app" style="font-family:sans-serif;padding:16px">
    <h1>SMS Procurement Manager</h1>
    <p>UI baseline is up. If you don't see the full app, ensure <code>main.js</code> exists and API_BASE is set.</p>
  </div>
  <script src="env.js"></script>
  <script src="main.js"></script>
</body></html>
HTML
fi

# 1) Make sure env.js exists and points to API (can be overridden by localStorage.API_BASE)
if [[ ! -f "$WEB_DIR/env.js" ]]; then
  cat > "$WEB_DIR/env.js" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS
fi

# 2) Create web.Dockerfile to COPY UI into nginx image with correct perms
cat > "$WEB_DOCKERFILE" <<'DOCKER'
FROM nginx:stable-alpine
# Copy UI
COPY web/public /usr/share/nginx/html
# Fix permissions so nginx worker can read everything
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; && \
    find /usr/share/nginx/html -type f -exec chmod 644 {} \;
# (Optional) you can drop a custom nginx.conf here if needed
DOCKER
echo -e "${G}✔ Prepared web.Dockerfile${N}"

# 3) Write a clean, conflict-free docker-compose.yml (no container_name, no version, no bind mount)
cp -a "$COMPOSE" "$COMPOSE.bak.$(date +%s)" 2>/dev/null || true
cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:15
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
    environment:
      - DB_URL=postgresql://postgres:postgres@postgres:5432/smsdb
    depends_on: [postgres]
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    depends_on: [api]
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata:

networks:
  stack:
YAML
echo -e "${G}✔ Wrote fresh docker-compose.yml (no bind mount for web)${N}"

# 4) Stop stack and remove any lingering old-name containers
docker compose -f "$COMPOSE" down --remove-orphans || true
for c in docker-api-1 docker-postgres-1 docker-web-1; do
  docker rm -f "$c" 2>/dev/null || true
done

# 5) Build + start
echo -e "${Y}🐳 Building images…${N}"
docker compose -f "$COMPOSE" build
echo -e "${Y}🚀 Starting stack…${N}"
docker compose -f "$COMPOSE" up -d

# 6) Health checks
IP=$(hostname -I | awk '{print $1}')
API="http://${IP}:8010/openapi.json"
UI="http://${IP}:5183"

echo -e "${Y}🌐 Checking API: ${API}${N}"
if curl -s --max-time 10 "$API" | grep -q '"openapi"'; then
  echo -e "${G}✔ API reachable${N}"
else
  echo -e "${R}✖ API not reachable. Logs:${N}"
  docker compose -f "$COMPOSE" logs --no-color --tail=120 api || true
  exit 1
fi

echo -e "${Y}🌐 Checking UI: ${UI}${N}"
if curl -s --max-time 10 "$UI" | grep -qi '<!doctype html>'; then
  echo -e "${G}✔ UI reachable${N}"
else
  echo -e "${R}✖ UI not reachable. Nginx logs:${N}"
  docker compose -f "$COMPOSE" logs --no-color --tail=120 web || true
  exit 1
fi

# 7) Final hint for front-end to hit the API correctly
echo -e "${G}✅ All good. Open: ${UI}${N}"
echo "If the UI still points to the wrong API, in the browser console run:"
echo "  localStorage.setItem('API_BASE','http://${IP}:8010'); location.reload();"
