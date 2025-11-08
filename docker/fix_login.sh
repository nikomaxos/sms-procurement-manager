#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
DOCKER_DIR="$ROOT/docker"
API_DIR="$ROOT/api"
WEB_DIR="$ROOT/web"

echo "🔧 Ensuring API CORS is permissive (for testing)..."
mkdir -p "$DOCKER_DIR"
# Force CORS_ORIGINS to allow localhost:5183 (and * as fallback while debugging)
cat > "$DOCKER_DIR/docker-compose.override.yml" <<'YML'
services:
  api:
    build:
      context: ../api
      dockerfile: api.Dockerfile
    environment:
      DB_URL: ${DB_URL:-postgresql://postgres:postgres@postgres:5432/smsdb}
      JWT_SECRET: ${JWT_SECRET:-changeme}
      CORS_ORIGINS: ${CORS_ORIGINS:-http://localhost:5183,*}
    depends_on:
      postgres:
        condition: service_started
    ports:
      - "8010:8000"
    restart: unless-stopped

  web:
    build:
      context: ../web
      dockerfile: web.Dockerfile
    depends_on:
      api:
        condition: service_started
    ports:
      - "5183:80"
    restart: unless-stopped

  worker:
    command: ["python3", "-m", "app.runloop"]
    environment:
      PYTHONPATH: /app
YML

echo "🛠 Updating Web UI main.js with better error handling..."
mkdir -p "$WEB_DIR/public"
cat > "$WEB_DIR/public/main.js" <<'JS'
// Robust, non-minified main.js with visible errors
(function () {
  const API = (window.__API_BASE__ || "http://localhost:8010");
  const app = document.querySelector("#app");
  let token = localStorage.getItem("spm_token");

  function h(html){ const d=document.createElement("div"); d.innerHTML=html.trim(); return d.firstChild; }
  function set(view){ app.innerHTML=""; app.appendChild(view); }
  function msg(m){ alert(m); }

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

echo "🔧 (Re)building API & Web…"
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

echo "⏳ Waiting 3s…"; sleep 3

echo "🩺 CORS preflight sanity (should include Access-Control-Allow-Origin):"
curl -i -s -X OPTIONS http://localhost:8010/users/login \
  -H "Origin: http://localhost:5183" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" | sed -n '1,20p'

echo "🔐 Mint token via curl (should return access_token JSON):"
curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | sed -e 's/.*/  &/'

echo
echo "✅ Open Web UI: http://localhost:5183  (try login again; any error will be shown on-screen and in the browser console)"
