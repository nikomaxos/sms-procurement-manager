#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
API="$ROOT/api/app/main.py"
DOCKER="$ROOT/docker"

mkdir -p "$WEB"

# 1) Overwrite index.html with a modern shell + dynamic API base
cat > "$WEB/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SMS Procurement Manager</title>
  <link rel="stylesheet" href="/main.css">
  <script>
    (function(){
      if (!window.__API_BASE__) {
        var proto = location.protocol;
        var host  = location.hostname;
        window.__API_BASE__ = proto + '//' + host + ':8010';
      }
    })();
  </script>
</head>
<body>
  <div id="app"></div>
  <footer class="muted" style="margin-top:24px;">
    API: <span id="apiBase"></span>
  </footer>
  <script src="/main.js"></script>
</body>
</html>
HTML

# 2) Write a simple SPA main.js with full nav + views (safe stubs)
cat > "$WEB/main.js" <<'JS'
const API_BASE = window.__API_BASE__;
const qs = (s,el=document)=>el.querySelector(s);

function setToken(t){ sessionStorage.setItem('spm_token', t||''); }
function getToken(){ return sessionStorage.getItem('spm_token') || ''; }

async function authFetch(path, init={}) {
  const token = getToken();
  init.headers = Object.assign({'Authorization': 'Bearer ' + token}, init.headers||{});
  const res = await fetch(API_BASE + path, init);
  if (!res.ok) throw new Error(res.status + ' ' + res.statusText);
  return res.json();
}

function layout(inner){
  const nav = `
  <div class="card" style="margin-bottom:12px;">
    <div class="toolbar">
      <button data-view="dashboard">What’s Hot</button>
      <button data-view="offers">Suppliers Offers</button>
      <span class="badge">Data</span>
      <button data-view="suppliers">Suppliers</button>
      <button data-view="email">Email Connection</button>
      <button data-view="templates">Parser Templates</button>
      <button data-view="scraper">Scraper Settings</button>
      <button data-view="progress">Parsing Progress</button>
      <span class="badge">Settings</span>
      <button data-view="configs">Dropdown Configs</button>
      <button data-view="users">Users</button>
      <span style="flex:1"></span>
      <button id="logoutBtn" title="Logout">Logout</button>
    </div>
  </div>`;
  return nav + `<div class="card">${inner}</div>`;
}

async function renderLogin(){
  const app = qs('#app');
  app.innerHTML = `
  <div class="card" style="max-width:420px;margin:auto;">
    <h2>Login</h2>
    <div class="toolbar">
      <input id="u" placeholder="Username" value="admin">
      <input id="p" type="password" placeholder="Password" value="admin123">
      <button id="go">Login</button>
    </div>
    <div class="muted">API: ${API_BASE}</div>
    <div id="err" class="muted" style="color:#ffb0b0;"></div>
  </div>`;
  qs('#go').onclick = async()=>{
    qs('#err').textContent='';
    const fd = new URLSearchParams(); fd.set('username', qs('#u').value); fd.set('password', qs('#p').value);
    try{
      const res = await fetch(API_BASE + '/users/login', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: fd});
      if(!res.ok){ qs('#err').textContent='Login failed ('+res.status+')'; return; }
      const j = await res.json();
      setToken(j.access_token || '');
      await renderDashboard();
    }catch(e){ qs('#err').textContent='Network error'; }
  };
  qs('#apiBase').textContent = API_BASE;
}

async function renderDashboard(){
  const app = qs('#app');
  try{
    const items = await authFetch('/hot/');
    const rows = (items||[]).map(it=>`<tr><td>${it.country||''}</td><td>${it.network||''}</td><td>${it.route_type||''}</td><td>${it.updates||0}</td></tr>`).join('') || `<tr><td colspan="4" class="muted">No updates.</td></tr>`;
    app.innerHTML = layout(`
      <h2>What’s Hot (today)</h2>
      <table class="table">
        <tr><th>Country</th><th>Network</th><th>Route</th><th>#Updates</th></tr>
        ${rows}
      </table>
    `);
    wireNav();
  }catch(e){
    if(String(e).includes('401')){ setToken(''); return renderLogin(); }
    app.innerHTML = layout(`<div class="muted">Error loading hot: ${e}</div>`); wireNav();
  }
  qs('#apiBase').textContent = API_BASE;
}

async function renderOffers(){
  const app = qs('#app');
  try{
    const data = await authFetch('/offers/');
    const rows = (data||[]).map(o=>`<tr><td>${o.supplier||o.supplier_id||''}</td><td>${o.connection||o.connection_id||''}</td><td>${o.mccmnc||o.network_id||''}</td><td>${o.price||''}</td><td>${o.currency||''}</td><td>${o.effective_date||''}</td></tr>`).join('') || `<tr><td colspan="6" class="muted">No offers yet.</td></tr>`;
    app.innerHTML = layout(`
      <h2>Suppliers Offers</h2>
      <table class="table">
        <tr><th>Supplier</th><th>Connection</th><th>MCC-MNC</th><th>Price</th><th>Currency</th><th>Effective</th></tr>
        ${rows}
      </table>
    `);
    wireNav();
  }catch(e){
    if(String(e).includes('401')){ setToken(''); return renderLogin(); }
    app.innerHTML = layout(`<div class="muted">Error loading offers: ${e}</div>`); wireNav();
  }
  qs('#apiBase').textContent = API_BASE;
}

async function renderSuppliers(){
  const app = qs('#app');
  let rows = '';
  try{
    const s = await authFetch('/suppliers/');
    rows = (s||[]).map(x=>`<tr><td>${x.id}</td><td>${x.organization_name}</td><td>${x.per_delivered ? 'Yes':'No'}</td></tr>`).join('');
  }catch(e){ rows = `<tr><td colspan="3" class="muted">No suppliers or error.</td></tr>`; }
  app.innerHTML = layout(`
    <h2>Suppliers</h2>
    <table class="table">
      <tr><th>ID</th><th>Organization</th><th>Per Delivered</th></tr>
      ${rows || `<tr><td colspan="3" class="muted">Empty.</td></tr>`}
    </table>
  `); wireNav(); qs('#apiBase').textContent = API_BASE;
}

async function renderEmail(){
  const app = qs('#app');
  app.innerHTML = layout(`
    <h2>Email Connection</h2>
    <div class="toolbar">
      <input id="host" placeholder="IMAP host">
      <input id="user" placeholder="IMAP user">
      <input id="pass" type="password" placeholder="IMAP app-password">
      <input id="folder" placeholder="Folder (e.g. INBOX)">
      <button id="test">Test</button>
    </div>
    <div id="out" class="muted"></div>
  `);
  wireNav();
  qs('#test').onclick = async()=>{
    qs('#out').textContent = 'Testing…';
    try{
      const j = await authFetch('/email/check', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          host: qs('#host').value, user: qs('#user').value, password: qs('#pass').value, folder: qs('#folder').value
        })
      });
      qs('#out').textContent = JSON.stringify(j);
    }catch(e){ qs('#out').textContent = 'Error: '+e; }
  };
  qs('#apiBase').textContent = API_BASE;
}

async function renderTemplates(){
  const app = qs('#app');
  app.innerHTML = layout(`<h2>Parser Templates</h2><div class="muted">UI scaffold. No templates yet.</div>`); wireNav(); qs('#apiBase').textContent = API_BASE;
}
async function renderScraper(){
  const app = qs('#app');
  let j = {};
  try{ j = await authFetch('/scraper/status'); }catch{}
  app.innerHTML = layout(`
    <h2>Scraper</h2>
    <div class="toolbar"><button id="run">Run Now</button><span class="muted">status: ${j.running?'running':'idle'}</span></div>
    <pre class="muted" style="white-space:pre-wrap">${JSON.stringify(j, null, 2)}</pre>
  `);
  wireNav();
  qs('#run').onclick = async()=>{
    try{ await authFetch('/scraper/run', {method:'POST'}); alert('Scraper triggered (stub)'); }catch(e){ alert('Error: '+e); }
  };
  qs('#apiBase').textContent = API_BASE;
}
async function renderProgress(){
  const app = qs('#app');
  let j={};
  try{ j = await authFetch('/parsing/progress'); }catch{}
  app.innerHTML = layout(`
    <h2>Parsing Progress</h2>
    <div class="toolbar muted">processed: ${j.processed||0} | diffs: ${j.diffs||0} | identical: ${j.identical||0} | errors: ${j.errors||0}</div>
    <pre class="muted" style="white-space:pre-wrap">${JSON.stringify(j.items||[], null, 2)}</pre>
  `); wireNav(); qs('#apiBase').textContent = API_BASE;
}
async function renderConfigs(){
  const app = qs('#app');
  let j={};
  try{ j = await authFetch('/config/dropdowns'); }catch{}
  function pill(title, arr){ return `<div style="margin:8px 0;"><div class="muted">${title}</div><div>${(arr||[]).map(v=>`<span class="badge">${v}</span>`).join(' ')}</div></div>`; }
  app.innerHTML = layout(`
    <h2>Dropdown Configurations</h2>
    ${pill('Route Types', j.route_types)}
    ${pill('Known Hops', j.known_hops)}
    ${pill('Sender ID', j.sender_id_supported)}
    ${pill('Registration Required', j.registration_required)}
    ${pill('Is Exclusive', j.is_exclusive)}
  `); wireNav(); qs('#apiBase').textContent = API_BASE;
}
async function renderUsers(){
  const app = qs('#app');
  app.innerHTML = layout(`<h2>Users</h2><div class="muted">Admin user exists. User management to be wired.</div>`); wireNav(); qs('#apiBase').textContent = API_BASE;
}

function wireNav(){
  document.querySelectorAll('[data-view]').forEach(btn=>{
    btn.onclick = async()=>{
      const v = btn.getAttribute('data-view');
      if      (v==='dashboard') await renderDashboard();
      else if (v==='offers')    await renderOffers();
      else if (v==='suppliers') await renderSuppliers();
      else if (v==='email')     await renderEmail();
      else if (v==='templates') await renderTemplates();
      else if (v==='scraper')   await renderScraper();
      else if (v==='progress')  await renderProgress();
      else if (v==='configs')   await renderConfigs();
      else if (v==='users')     await renderUsers();
    };
  });
  const lo = qs('#logoutBtn');
  if (lo) lo.onclick = ()=>{ setToken(''); renderLogin(); };
}

(async function start(){
  qs('#apiBase').textContent = API_BASE;
  const token = getToken();
  if (!token) return renderLogin();
  try { await authFetch('/hot/'); await renderDashboard(); }
  catch { setToken(''); await renderLogin(); }
})();
JS

# 3) Add API stubs (idempotent)
python3 - <<'PY'
from pathlib import Path
p = Path.home()/ "sms-procurement-manager/api/app/main.py"
s = p.read_text()

need = []
if "/suppliers/" not in s:
    need.append("""
@app.get("/suppliers/")
def suppliers(_: bool = Depends(auth_required)):
    return []
""")
if "/parsing/progress" not in s:
    need.append("""
@app.get("/parsing/progress")
def parsing_progress(_: bool = Depends(auth_required)):
    return {"processed":0,"diffs":0,"identical":0,"errors":0,"items":[]}
""")
if "/config/dropdowns" not in s:
    need.append("""
@app.get("/config/dropdowns")
def dropdowns(_: bool = Depends(auth_required)):
    return {
        "route_types":["Direct","SS7","SIM","Local Bypass"],
        "known_hops":["0-Hop","1-Hop","2-Hops","N-Hops"],
        "sender_id_supported":["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
        "registration_required":["Yes","No"],
        "is_exclusive":["Yes","No"]
    }
""")
if "/email/check" not in s:
    need.append("""
from pydantic import BaseModel
class EmailCheck(BaseModel):
    host:str; user:str; password:str; folder:str
@app.post("/email/check")
def email_check(_: bool = Depends(auth_required), req: EmailCheck = None):
    # shim: just echo
    return {"ok": False, "message":"IMAP check stub","host": req.host if req else None}
""")
if "/scraper/status" not in s:
    need.append("""
@app.get("/scraper/status")
def scraper_status(_: bool = Depends(auth_required)):
    return {"running": False, "unmatched":{"connections":[],"smscs":[],"usernames":[],"networks":[]}}
""")
if "/scraper/run" not in s:
    need.append("""
@app.post("/scraper/run")
def scraper_run(_: bool = Depends(auth_required)):
    return {"accepted": True}
""")
if need:
    s += "\n".join(need)
    p.write_text(s)
    print("Added stubs:", [n.splitlines()[1].strip() for n in need])
else:
    print("All stubs present")
PY

# 4) Rebuild & restart web + api
cd "$DOCKER"
docker compose build web api
docker compose up -d web api

echo "✅ Done. Open the UI and hard refresh (Ctrl+Shift+R). You should see the full menu."
