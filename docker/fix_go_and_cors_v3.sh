#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
MAIN_PY="$API_DIR/main.py"
WEB_DIR="$ROOT/web/public"
MAIN_JS="$WEB_DIR/main.js"
ENV_JS="$WEB_DIR/env.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_go_and_cors_v3_$TS"
mkdir -p "$BACK"

echo -e "${Y}• Backing up files to ${BACK}${N}"
[[ -f "$COMPOSE" ]] && cp -a "$COMPOSE" "$BACK/docker-compose.yml.bak" || true
[[ -f "$MAIN_PY" ]] && cp -a "$MAIN_PY" "$BACK/main.py.bak" || true
[[ -f "$MAIN_JS" ]] && cp -a "$MAIN_JS" "$BACK/main.js.bak" || true
[[ -f "$ENV_JS" ]]  && cp -a "$ENV_JS"  "$BACK/env.js.bak"  || true
[[ -d "$API_DIR"  ]] && tar -czf "$BACK/api_app.tgz" -C "$ROOT/api" app || true

# 1) Write a clean, valid docker-compose.yml (no 'version', no 'container_name')
echo -e "${Y}• Rewriting docker-compose.yml to a clean spec…${N}"
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
      DB_URL: postgresql+psycopg://postgres:postgres@postgres:5432/smsdb
    depends_on:
      - postgres
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    restart: unless-stopped
    depends_on:
      - api
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata: {}

networks:
  stack: {}
YAML

# 2) Patch FastAPI CORS in main.py (idempotent) using env to avoid quoting issues
echo -e "${Y}• Patching API CORS in main.py…${N}"
MAIN_PY_ENV="$MAIN_PY" python3 - <<'PY'
import os, re
from pathlib import Path

p = Path(os.environ["MAIN_PY_ENV"])
s = p.read_text(encoding="utf-8")

if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
if not m:
    raise SystemExit("FastAPI() instantiation not found in main.py")

if "app.add_middleware(CORSMiddleware" not in s:
    insert_at = m.end()
    block = """
\n# --- injected CORS ---
origins = ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,  # we use Bearer not cookies
    allow_methods=["*"],
    allow_headers=["*"],
)
# --- end injected CORS ---
"""
    s = s[:insert_at] + block + s[insert_at:]

p.write_text(s, encoding="utf-8")
print("OK")
PY

# 3) Ensure env.js exists (lets UI find API automatically unless manually overridden)
mkdir -p "$WEB_DIR"
if [[ ! -f "$ENV_JS" ]]; then
  cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS
  echo -e "${G}✔ env.js written${N}"
fi

# 4) Inject a robust UI prelude at the very top of main.js (without overwriting the rest)
echo -e "${Y}• Ensuring UI prelude (go, $, $$, authFetch, Enter-to-Login)…${N}"
if [[ ! -f "$MAIN_JS" ]]; then
  # create a minimal main.js if missing
  cat > "$MAIN_JS" <<'JS'
/* App main.js (created) */
JS
fi

PRELUDE_MARK="/* == PRELUDE START (idempotent) == */"
if ! grep -qF "$PRELUDE_MARK" "$MAIN_JS"; then
  tmp="$MAIN_JS.tmp.$$"
  cat > "$tmp" <<'JS'
/* == PRELUDE START (idempotent) == */
(function(){
  if (window.__PRELUDE__) return;
  window.__PRELUDE__ = true;

  window.$  = (s)=>document.querySelector(s);
  window.$$ = (s)=>Array.from(document.querySelectorAll(s));

  window.el = function(tag, attrs, ...kids){
    const n = document.createElement(tag);
    if (attrs) for (const [k,v] of Object.entries(attrs)) {
      if (k === 'class') n.className = v;
      else if (k.startsWith('on') && typeof v === 'function') n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    for (const k of kids) n.append(k && k.nodeType ? k : (k ?? ''));
    return n;
  };

  window.btn = function(text, color, onclick){
    const b = el('button', { class: 'btn ' + (color||'') }, text);
    if (onclick) b.addEventListener('click', onclick);
    return b;
  };

  window.go = function(fn){ Promise.resolve().then(fn).catch(e => console.error(e)); };

  window.authFetch = async function(url, opts){
    opts = opts || {};
    const headers = opts.headers ? {...opts.headers} : {};
    if (!headers['Content-Type'] && !(opts.body instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
    }
    const tok = localStorage.getItem('token');
    if (tok) headers['Authorization'] = 'Bearer ' + tok;
    const res = await fetch(url, {...opts, headers});
    if (!res.ok) {
      const txt = await res.text().catch(()=>'');
      throw new Error(res.status + ' ' + txt);
    }
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : res.text();
  };

  // Enter-to-Login convenience (tries common selectors)
  document.addEventListener('keydown', (e)=>{
    if (e.key === 'Enter') {
      const loginBtn = document.querySelector('[data-action="login"], #loginBtn, button.login');
      if (loginBtn) loginBtn.click();
    }
  });
})();
 /* == PRELUDE END == */
JS
  cat "$tmp" "$MAIN_JS" > "$MAIN_JS.new" && mv "$MAIN_JS.new" "$MAIN_JS" && rm -f "$tmp"
  echo -e "${G}✔ Prelude injected at top of main.js${N}"
else
  echo -e "${G}✔ Prelude already present${N}"
fi

# 5) Validate compose and rebuild
echo -e "${Y}• Validating compose…${N}"
docker compose -f "$COMPOSE" config >/dev/null

echo -e "${Y}• Rebuilding + restarting containers…${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 6) Health & CORS checks
sleep 2
IP=$(hostname -I | awk '{print $1}')
API="http://${IP}:8010"
UI="http://${IP}:5183"

echo -e "${Y}• Checking API /openapi.json …${N}"
if curl -fsS "$API/openapi.json" >/dev/null; then
  echo -e "${G}✔ API reachable${N}"
else
  echo -e "${R}✖ API not reachable — recent logs:${N}"
  docker logs "$(docker compose -f "$COMPOSE" ps -q api)" --tail=120 || true
fi

echo -e "${Y}• Checking CORS preflight on /health …${N}"
cors_headers=$(curl -s -D - -o /dev/null -X OPTIONS "$API/health" \
  -H "Origin: ${UI}" \
  -H "Access-Control-Request-Method: GET" || true)
echo "$cors_headers" | tr -d '\r' | grep -i '^access-control-allow-origin' || \
  echo -e "${R}(no Access-Control-Allow-Origin header found)${N}"

echo -e "${Y}• UI should be at: ${UI}${N}"
echo -e "${G}Done.${N}"
