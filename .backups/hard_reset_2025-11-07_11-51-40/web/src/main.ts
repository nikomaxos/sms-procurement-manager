type Token = { access_token:string; token_type:string };
const API = (window as any).__API_BASE__ || "http://localhost:8010";

const el = (sel:string) => document.querySelector(sel) as HTMLElement;

let token:string|null = localStorage.getItem("spm_token");

const app = el("#app");

function renderLogin() {
  app.innerHTML = `
    <h1>Sign in</h1>
    <div class="grid">
      <input id="u" placeholder="username" />
      <input id="p" placeholder="password" type="password" />
      <button id="login">Login</button>
    </div>
  `;
  el("#login").addEventListener("click", async () => {
    const u = (el("#u") as HTMLInputElement).value.trim();
    const p = (el("#p") as HTMLInputElement).value.trim();
    const form = new URLSearchParams({username:u, password:p});
    const res = await fetch(`${API}/users/login`, {
      method:"POST", headers:{"Content-Type":"application/x-www-form-urlencoded"},
      body: form.toString()
    });
    if (!res.ok) { alert("Invalid credentials"); return; }
    const data = await res.json() as Token;
    token = data.access_token;
    localStorage.setItem("spm_token", token!);
    renderDashboard();
  });
}

async function authFetch(path:string) {
  if (!token) throw new Error("no token");
  const res = await fetch(`${API}${path}`, { headers: {Authorization:`Bearer ${token}`}});
  if (res.status === 401) {
    localStorage.removeItem("spm_token"); token = null; renderLogin(); return {items:[]};
  }
  return res.json();
}

function renderDashboard() {
  app.innerHTML = `
    <div class="toolbar">
      <button id="nav_hot">What's Hot</button>
      <button id="nav_offers">Suppliers Offers</button>
      <span class="badge">API: ${API}</span>
      <span style="flex:1"></span>
      <button id="logout">Logout</button>
    </div>
    <div id="view"></div>
  `;
  el("#logout").addEventListener("click", () => { localStorage.removeItem("spm_token"); token = null; renderLogin(); });
  el("#nav_hot").addEventListener("click", renderHot);
  el("#nav_offers").addEventListener("click", renderOffers);
  renderHot();
}

async function renderHot() {
  const view = el("#view");
  view.innerHTML = `<h1>What's Hot (today)</h1><div class="grid"></div>`;
  const data = await authFetch("/hot/");
  const grid = view.querySelector(".grid")!;
  if (!Array.isArray(data) || data.length === 0) { grid.innerHTML = "<p>No updates today.</p>"; return; }
  grid.innerHTML = data.map((r:any) => `
    <div class="card">
      <div class="kv"><strong>Network ID:</strong> <span>${r.network_id ?? "-"}</span></div>
      <div class="kv"><strong>Route Type:</strong> <span>${r.route_type ?? "-"}</span></div>
      <div class="kv"><strong>Updates:</strong> <span>${r.updates}</span></div>
    </div>
  `).join("");
}

async function renderOffers() {
  const view = el("#view");
  view.innerHTML = `
    <h1>Suppliers Offers</h1>
    <div class="toolbar">
      <select id="route"><option value="">All routes</option><option>Direct</option><option>SS7</option><option>SIM</option><option>Local Bypass</option></select>
      <button id="reload">Reload</button>
    </div>
    <table class="table"><thead>
      <tr><th>ID</th><th>Supplier</th><th>Conn</th><th>Network</th><th>Price</th><th>Curr</th><th>Route</th><th>Updated</th></tr>
    </thead><tbody id="rows"></tbody></table>
  `;
  const load = async () => {
    const route = (el("#route") as HTMLSelectElement).value;
    const qs = route ? `?route_type=${encodeURIComponent(route)}` : "";
    const items = await authFetch(`/offers/${qs}`);
    const tb = el("#rows");
    tb.innerHTML = (items||[]).map((r:any) => `
      <tr>
        <td>${r.id}</td>
        <td>${r.supplier_id}</td>
        <td>${r.connection_id}</td>
        <td>${r.network_id ?? "-"}</td>
        <td>${r.price ?? "-"}</td>
        <td>${r.currency ?? "-"}</td>
        <td>${r.route_type ?? "-"}</td>
        <td>${r.updated_at ?? "-"}</td>
      </tr>
    `).join("");
  };
  el("#reload").addEventListener("click", load);
  load();
}

if (!token) renderLogin(); else renderDashboard();
