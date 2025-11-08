#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
DOCKER_DIR="$ROOT/docker"
API_MAIN="$ROOT/api/app/main.py"

# Sanity check: API source should exist
if [ ! -f "$API_MAIN" ]; then
  echo "❌ $API_MAIN not found. Your API sources must be at api/app/*"
  echo "   Make sure your FastAPI app is under api/app and try again."
  exit 1
fi

echo "🧱 Ensure root-level api.Dockerfile exists (Compose expects it due to build context '..')"
if [ ! -f "$ROOT/api.Dockerfile" ]; then
  cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim

WORKDIR /app
# copy API sources from repo layout api/app -> /app/app
COPY api/app /app/app

# system deps for psycopg
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*

# python deps (pins for passlib/bcrypt stability)
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy pydantic psycopg[binary] python-multipart \
    passlib[bcrypt]==1.7.4 bcrypt==4.0.1 python-jose[cryptography]

ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER
  echo "✅ Created $ROOT/api.Dockerfile"
else
  echo "ℹ️ $ROOT/api.Dockerfile already present"
fi

# Ensure Web Dockerfile & minimal static UI exist
WEB_DIR="$ROOT/web"
WEB_PUB="$WEB_DIR/public"
mkdir -p "$WEB_PUB"

# Only create minimal UI files if they don't exist yet
[ -f "$WEB_PUB/index.html" ] || cat > "$WEB_PUB/index.html" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8"/>
    <title>SMS Procurement Manager</title>
    <script>window.__API_BASE__="http://localhost:8010";</script>
    <style>
      body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Inter,Arial,sans-serif;margin:40px;background:#0b0f14;color:#e7edf3}
      .card{background:#121821;border:1px solid #253041;border-radius:16px;padding:16px;box-shadow:0 1px 10px rgba(0,0,0,.25)}
      .toolbar{display:flex;gap:8px;align-items:center;margin:16px 0}
      input,button{padding:10px;border-radius:10px;border:1px solid #253041;background:#0f141c;color:#e7edf3}
      button{cursor:pointer}
      .badge{background:#1a2332;border:1px solid #253041;border-radius:999px;padding:4px 10px;font-size:12px;opacity:.8}
    </style>
  </head>
  <body>
    <div id="app"></div>
    <script src="/main.js"></script>
  </body>
</html>
HTML

[ -f "$WEB_PUB/main.js" ] || cat > "$WEB_PUB/main.js" <<'JS'
(function () {
  const API = (window.__API_BASE__ || "http://localhost:8010");
  const app = document.querySelector("#app");
  let token = localStorage.getItem("spm_token");

  function h(html){ const d=document.createElement("div"); d.innerHTML=html.trim(); return d.firstChild; }
  function set(view){ app.innerHTML=""; app.appendChild(view); }

  function loginView(){
    const v = h(`
      <div class="card" style="max-width:420px;margin:auto;">
        <h2>Sign in</h2>
        <div style="display:grid;gap:8px;">
          <input id="u" placeholder="username" />
          <input id="p" placeholder="password" type="password" />
          <button id="login">Login</button>
        </div>
        <div id="err" style="margin-top:10px;color:#ff8a8a;"></div>
        <div class="badge" style="margin-top:12px;">API: ${API}</div>
      </div>
    `);
    v.querySelector("#login").addEventListener("click", async ()=>{
      const u = v.querySelector("#u").value.trim();
      const p = v.querySelector("#p").value.trim();
      const err = v.querySelector("#err");
      const btn = v.querySelector("#login");
      btn.disabled = true; btn.textContent = "Logging in...";
      err.textContent = "";
      try{
        const body = new URLSearchParams({username:u,password:p}).toString();
        const res = await fetch(`${API}/users/login`, {
          method: "POST",
          headers: {"Content-Type":"application/x-www-form-urlencoded"},
          body
        });
        if (!res.ok){
          const txt = await res.text().catch(()=>"(no body)"); 
          err.textContent = `Login failed (${res.status}): ${txt}`;
          btn.disabled = false; btn.textContent = "Login";
          return;
        }
        const data = await res.json();
        localStorage.setItem("spm_token", data.access_token);
        location.reload();
      }catch(e){
        err.textContent = "Network error. Check API/CORS/console.";
        console.error("Login error:", e);
        btn.disabled = false; btn.textContent = "Login";
      }
    });
    return v;
  }

  function authedView(){
    const v = h(`
      <div class="card" style="max-width:720px;margin:auto;">
        <div class="toolbar">
          <div class="badge">API: ${API}</div>
          <span style="flex:1"></span>
          <button id="logout">Logout</button>
        </div>
        <div id="res"></div>
      </div>
    `);
    v.querySelector("#logout").addEventListener("click", ()=>{
      localStorage.removeItem("spm_token"); location.reload();
    });
    (async ()=>{
      try{
        const t = localStorage.getItem("spm_token");
        const res = await fetch(`${API}/offers/`, { headers: {Authorization:`Bearer ${t}`} });
        const txt = await res.text().catch(()=>"(no body)");
        v.querySelector("#res").innerText = `GET /offers -> ${res.status}\n` + txt;
      }catch(e){
        v.querySelector("#res").innerText = "Network error (see console)."; console.error(e);
      }
    })();
    return v;
  }

  const t = localStorage.getItem("spm_token");
  set(t ? authedView() : loginView());
})();
JS

# Web Dockerfile (nginx static)
if [ ! -f "$WEB_DIR/Dockerfile" ]; then
cat > "$WEB_DIR/Dockerfile" <<'DOCKER'
FROM nginx:alpine
COPY public /usr/share/nginx/html
DOCKER
  echo "✅ Created $WEB_DIR/Dockerfile"
else
  echo "ℹ️ $WEB_DIR/Dockerfile already present"
fi

# Compose override to build api from root api.Dockerfile and web from /web
cat > "$DOCKER_DIR/docker-compose.override.yml" <<'YML'
services:
  api:
    build:
      context: ..
      dockerfile: api.Dockerfile
    environment:
      DB_URL: ${DB_URL:-postgresql://postgres:postgres@postgres:5432/smsdb}
      JWT_SECRET: ${JWT_SECRET:-changeme}
      CORS_ORIGINS: "http://localhost:5183,http://127.0.0.1:5183,*"
    ports:
      - "8010:8000"
    restart: unless-stopped

  web:
    build:
      context: ../web
    ports:
      - "5183:80"
    restart: unless-stopped
YML

echo "🔁 Build & start api/web…"
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

echo "⏳ Wait 3s…"; sleep 3

echo "🩺 CORS preflight:"
curl -i -s -X OPTIONS http://localhost:8010/users/login \
  -H "Origin: http://localhost:5183" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" | sed -n '1,25p'

echo "🔐 Test login via curl:"
curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | sed -e 's/.*/  &/'

echo
echo "✅ Open: http://localhost:5183  (login: admin / admin123)"
