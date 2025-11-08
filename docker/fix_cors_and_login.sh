#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_APP="$ROOT/api/app"
API_MAIN="$API_APP/main.py"
WEB_DIR="$ROOT/web"
DOCKER_DIR="$ROOT/docker"

echo "🔧 Ensuring FastAPI CORS middleware is present..."
mkdir -p "$API_APP"
if ! grep -q "CORSMiddleware" "$API_MAIN"; then
  # Insert CORS block after FastAPI app creation
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
  echo "✅ CORS block injected into main.py"
else
  echo "ℹ️ CORS already present in main.py"
fi

echo "🔧 Forcing compose override with permissive CORS..."
mkdir -p "$DOCKER_DIR"
cat > "$DOCKER_DIR/docker-compose.override.yml" <<'YML'
services:
  api:
    environment:
      CORS_ORIGINS: "http://localhost:5183,http://127.0.0.1:5183,*"
    ports:
      - "8010:8000"
    restart: unless-stopped
  web:
    ports:
      - "5183:80"
    restart: unless-stopped
YML

echo "🔧 Injecting explicit API base in Web UI…"
mkdir -p "$WEB_DIR/public"
INDEX="$WEB_DIR/public/index.html"
MAINJS="$WEB_DIR/public/main.js"

# Create a minimal index.html if missing
if [ ! -f "$INDEX" ]; then
cat > "$INDEX" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8"/>
    <title>SMS Procurement Manager</title>
    <script>window.__API_BASE__="http://localhost:8010";</script>
    <link rel="stylesheet" href="/main.css">
  </head>
  <body>
    <div id="app"></div>
    <script src="/main.js"></script>
  </body>
</html>
HTML
else
  # Ensure the API base line exists before main.js
  if ! grep -q "__API_BASE__" "$INDEX"; then
    sed -i '0,/<script/s//<script>window.__API_BASE__="http:\/\/localhost:8010";<\/script>\n&/' "$INDEX"
  fi
fi

# Ensure we have the robust main.js (in case it’s missing)
if [ ! -f "$MAINJS" ]; then
cat > "$MAINJS" <<'JS'
(function () {
  const API = (window.__API_BASE__ || "http://localhost:8010");
  const app = document.querySelector("#app");
  let token = localStorage.getItem("spm_token");

  function h(html){ const d=document.createElement("div"); d.innerHTML=html.trim(); return d.firstChild; }
  function set(view){ app.innerHTML=""; app.appendChild(view); }

  function loginView(){
    const v = h(`
      <div>
        <h1>Sign in</h1>
        <div class="grid">
          <input id="u" placeholder="username" />
          <input id="p" placeholder="password" type="password" />
          <button id="login">Login</button>
        </div>
        <div id="err" style="margin-top:8px;color:#ff8a8a;"></div>
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
          <div class="kv"><strong>Network ID:</strong> <span>${r.network_id ?? "-"}</span></div>
          <div class="kv"><strong>Route Type:</strong> <span>${r.route_type ?? "-"}</span></div>
          <div class="kv"><strong>Updates:</strong> <span>${r.updates}</span></div>
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
      <table class="table"><thead>
        <tr><th>ID</th><th>Supplier</th><th>Conn</th><th>Network</th><th>Price</th><th>Curr</th><th>Route</th><th>Updated</th></tr>
      </thead><tbody id="rows"></tbody></table>
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
fi

echo "🔁 Rebuild & restart api/web…"
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

echo "⏳ Wait 3s…"; sleep 3
echo "🩺 CORS preflight (should show Access-Control-Allow-Origin):"
curl -i -s -X OPTIONS http://localhost:8010/users/login \
  -H "Origin: http://localhost:5183" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" | sed -n '1,20p'

echo "🔐 Login via curl (should return access_token):"
curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | sed -e 's/.*/  &/'

echo
echo "✅ Now open http://localhost:5183 and try login again."
