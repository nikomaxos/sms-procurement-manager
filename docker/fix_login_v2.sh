#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api"
API_APP="$API_DIR/app"
API_MAIN="$API_APP/main.py"
WEB_DIR="$ROOT/web"
WEB_PUB="$WEB_DIR/public"
DOCKER_DIR="$ROOT/docker"

echo "🔧 Ensure FastAPI has CORS (for localhost:5183,127.0.0.1:5183,*)..."
if [ -f "$API_MAIN" ] && ! grep -q "CORSMiddleware" "$API_MAIN"; then
  awk '
    /from fastapi import FastAPI/ && !seenFastapi {print; print "from fastapi.middleware.cors import CORSMiddleware"; seenFastapi=1; next}
    /app = FastAPI/ && !seenCors {
      print;
      print "import os";
      print "origins = os.getenv(\"CORS_ORIGINS\", \"http://localhost:5183,http://127.0.0.1:5183,*\").split(\",\")";
      print "app.add_middleware(";
      print "    CORSMiddleware,";
      print "    allow_origins=origins,";
      print "    allow_credentials=True,";
      print "    allow_methods=[\"*\"],";
      print "    allow_headers=[\"*\"],";
      print ")";
      seenCors=1; next
    }
    {print}
  ' "$API_MAIN" > "$API_MAIN.tmp"
  mv "$API_MAIN.tmp" "$API_MAIN"
  echo "✅ Injected CORS into $API_MAIN"
else
  echo "ℹ️ CORS already present or API missing (skipping injection)"
fi

echo "🧱 Ensure Web build context & static files exist..."
mkdir -p "$WEB_PUB"

# Basic index.html that pins API base
cat > "$WEB_PUB/index.html" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8"/>
    <title>SMS Procurement Manager</title>
    <script>window.__API_BASE__="http://localhost:8010";</script>
    <link rel="stylesheet" href="/main.css">
    <style>
      body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Inter,Arial,sans-serif;margin:40px;background:#0b0f14;color:#e7edf3}
      .card{background:#121821;border:1px solid #253041;border-radius:16px;padding:16px;box-shadow:0 1px 10px rgba(0,0,0,.25)}
      .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px}
      .toolbar{display:flex;gap:8px;align-items:center;margin:16px 0}
      .badge{background:#1a2332;border:1px solid #253041;border-radius:999px;padding:4px 10px;font-size:12px;opacity:.8}
      input,select,button{padding:10px;border-radius:10px;border:1px solid #253041;background:#0f141c;color:#e7edf3}
      button{cursor:pointer}
      table{width:100%;border-collapse:collapse}
      th,td{padding:8px 10px;border-bottom:1px solid #253041}
      .table{background:#0f141c;border:1px solid #253041;border-radius:14px;overflow:hidden}
    </style>
  </head>
  <body>
    <div id="app"></div>
    <script src="/main.js"></script>
  </body>
</html>
HTML

# Robust main.js with visible errors and explicit API base
cat > "$WEB_PUB/main.js" <<'JS'
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
    const btn = v.querySelector("#login");
    btn.addEventListener("click", async ()=>{
      const u = v.querySelector("#u").value.trim();
      const p = v.querySelector("#p").value.trim();
      const err = v.querySelector("#err");
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
        token = data.access_token;
        localStorage.setItem("spm_token", token);
        set(dashboardView());
      }catch(e){
        err.textContent = "Network error. Check API/CORS/console.";
        console.error("Login error:", e);
        btn.disabled = false; btn.textContent = "Login";
      }
    });
    return v;
  }

  async function authFetch(path){
    if (!token){ set(loginView()); throw new Error("no token"); }
    const res = await fetch(`${API}${path}`, { headers: {Authorization:`Bearer ${token}`}});
    if (res.status === 401){
      localStorage.removeItem("spm_token"); token = null;
      set(loginView());
      throw new Error("401 unauthorized");
    }
    return res;
  }

  function dashboardView(){
    const v = h(`
      <div>
        <div class="toolbar">
          <button id="nav_hot">What's Hot</button>
          <button id="nav_offers">Suppliers Offers</button>
          <span class="badge">API: ${API}</span>
          <span style="flex:1"></span>
          <button id="logout">Logout</button>
        </div>
        <div id="view"></div>
      </div>
    `);
    v.querySelector("#logout").addEventListener("click", ()=>{ localStorage.removeItem("spm_token"); token=null; set(loginView()); });
    v.querySelector("#nav_hot").addEventListener("click", ()=>renderHot(v.querySelector("#view")));
    v.querySelector("#nav_offers").addEventListener("click", ()=>renderOffers(v.querySelector("#view")));
    renderHot(v.querySelector("#view"));
    return v;
  }

  async function renderHot(view){
    view.innerHTML = `<h1>What's Hot (today)</h1><div class="grid"></div>`;
    const grid = view.querySelector(".grid");
    try{
      const res = await authFetch("/hot/");
      const data = await res.json();
      if (!Array.isArray(data) || data.length===0){ grid.innerHTML = "<p>No updates today.</p>"; return; }
      grid.innerHTML = data.map(r => `
        <div class="card">
          <div><strong>Network ID:</strong> ${r.network_id ?? "-"}</div>
          <div><strong>Route Type:</strong> ${r.route_type ?? "-"}</div>
          <div><strong>Updates:</strong> ${r.updates}</div>
        </div>`).join("");
    }catch(e){
      grid.innerHTML = `<p style="color:#ff8a8a;">Error loading What's Hot (see console).</p>`;
      console.error(e);
    }
  }

  async function renderOffers(view){
    view.innerHTML = `
      <h1>Suppliers Offers</h1>
      <div class="toolbar">
        <select id="route"><option value="">All routes</option><option>Direct</option><option>SS7</option><option>SIM</option><option>Local Bypass</option></select>
        <button id="reload">Reload</button>
      </div>
      <div id="err" style="margin-bottom:8px;color:#ff8a8a;"></div>
      <div class="table"><table><thead>
        <tr><th>ID</th><th>Supplier</th><th>Conn</th><th>Network</th><th>Price</th><th>Curr</th><th>Route</th><th>Updated</th></tr>
      </thead><tbody id="rows"></tbody></table></div>
    `;
    const err = view.querySelector("#err");
    const routeSel = view.querySelector("#route");
    const rows = view.querySelector("#rows");
    const load = async ()=>{
      try{
        const qs = routeSel.value ? `?route_type=${encodeURIComponent(routeSel.value)}` : "";
        const res = await authFetch(`/offers/${qs}`);
        if (!res.ok){ rows.innerHTML = ""; err.textContent = `HTTP ${res.status}`; return; }
        const items = await res.json();
        rows.innerHTML = (items||[]).map(r => `
          <tr>
            <td>${r.id}</td>
            <td>${r.supplier_id}</td>
            <td>${r.connection_id}</td>
            <td>${r.network_id ?? "-"}</td>
            <td>${r.price ?? "-"}</td>
            <td>${r.currency ?? "-"}</td>
            <td>${r.route_type ?? "-"}</td>
            <td>${r.updated_at ?? "-"}</td>
          </tr>`).join("");
        err.textContent = "";
      }catch(e){
        err.textContent = "Network error (see console).";
        console.error(e);
      }
    };
    view.querySelector("#reload").addEventListener("click", load);
    load();
  }

  set(token ? dashboardView() : loginView());
})();
JS

# Simple static server with nginx
cat > "$ROOT/web/web.Dockerfile" <<'DOCKER'
FROM nginx:alpine
COPY public /usr/share/nginx/html
DOCKER

echo "🧩 Write docker-compose.override.yml with proper builds for api & web…"
mkdir -p "$DOCKER_DIR"
cat > "$DOCKER_DIR/docker-compose.override.yml" <<'YML'
services:
  api:
    build:
      context: ../api
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

echo "🔁 Rebuild & start api/web…"
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

echo "⏳ Wait 3s…"; sleep 3

echo "🩺 CORS preflight (should show Access-Control-Allow-Origin):"
curl -i -s -X OPTIONS http://localhost:8010/users/login \
  -H "Origin: http://localhost:5183" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" | sed -n '1,25p'

echo "🔐 Test login by curl (should return access_token JSON):"
curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | sed -e 's/.*/  &/'

echo
echo "✅ Open Web UI: http://localhost:5183  (try login again; any error will show on-screen & in DevTools)"
