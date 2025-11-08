#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
ROUTERS_DIR="$API_DIR/routers"
MAIN_PY="$API_DIR/main.py"
WEB_DIR="$ROOT/web/public"
DOCKER_DIR="$ROOT/docker"

mkdir -p "$ROUTERS_DIR" "$WEB_DIR"

echo "🧱 Writing API router: create_api.py ..."
cat > "$ROUTERS_DIR/create_api.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List
from sqlalchemy import text
from app.core.database import engine
# Prefer the existing auth guard. If missing, fallback to a no-op.
try:
    from app.core.auth import get_current_user as auth_guard
except Exception:
    def auth_guard():
        return True

router = APIRouter()

# --- DDL: run once at import (idempotent) ---
def _ddl():
    ddls = [
        # users (in case your earlier model didn't create it)
        """CREATE TABLE IF NOT EXISTS users(
             id SERIAL PRIMARY KEY,
             username VARCHAR UNIQUE,
             password_hash VARCHAR,
             role VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS suppliers(
             id SERIAL PRIMARY KEY,
             organization_name VARCHAR NOT NULL,
             per_delivered BOOLEAN DEFAULT FALSE
        )""",
        """CREATE TABLE IF NOT EXISTS supplier_connections(
             id SERIAL PRIMARY KEY,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
             connection_name VARCHAR,
             kannel_smsc VARCHAR,
             username VARCHAR,
             charge_model VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS countries(
             id SERIAL PRIMARY KEY,
             name VARCHAR,
             mcc VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS networks(
             id SERIAL PRIMARY KEY,
             country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
             name VARCHAR,
             mnc VARCHAR,
             mccmnc VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS offers_current(
             id SERIAL PRIMARY KEY,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
             connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE SET NULL,
             network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,
             price DOUBLE PRECISION,
             currency VARCHAR(8) DEFAULT 'EUR',
             effective_date TIMESTAMP DEFAULT NOW(),
             route_type VARCHAR(64),
             known_hops VARCHAR(32),
             sender_id_supported VARCHAR(128),
             registration_required VARCHAR(16),
             eta_days INTEGER,
             charge_model VARCHAR(32),
             is_exclusive VARCHAR(8),
             notes TEXT,
             updated_by VARCHAR(128),
             updated_at TIMESTAMP DEFAULT NOW()
        )""",
        """CREATE TABLE IF NOT EXISTS email_settings(
             id INTEGER PRIMARY KEY DEFAULT 1,
             host VARCHAR,
             username VARCHAR,
             password VARCHAR,
             folder VARCHAR,
             refresh_minutes INTEGER DEFAULT 5
        )""",
        """CREATE TABLE IF NOT EXISTS parser_templates(
             id SERIAL PRIMARY KEY,
             name VARCHAR NOT NULL,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
             conditions_json JSONB,
             extract_map_json JSONB,
             callback_url VARCHAR,
             add_attrs_json JSONB,
             enabled BOOLEAN DEFAULT TRUE
        )""",
        """CREATE TABLE IF NOT EXISTS scraper_settings(
             id INTEGER PRIMARY KEY DEFAULT 1,
             base_url VARCHAR,
             username VARCHAR,
             password VARCHAR,
             cookies_json JSONB,
             endpoints_json JSONB
        )""",
        """CREATE TABLE IF NOT EXISTS dropdown_configs(
             id INTEGER PRIMARY KEY DEFAULT 1,
             route_types JSONB,
             known_hops JSONB,
             sender_id_supported JSONB,
             registration_required JSONB,
             is_exclusive JSONB
        )""",
    ]
    with engine.begin() as conn:
        for d in ddls:
            conn.execute(text(d))

_ddl()

def _row(r):
    return dict(r._mapping) if hasattr(r, "_mapping") else dict(r)

# --------- Pydantic bodies ----------
class SupplierCreate(BaseModel):
    organization_name: str
    per_delivered: bool = False

class ConnectionCreate(BaseModel):
    supplier_id: int
    connection_name: str
    kannel_smsc: str
    username: str
    charge_model: str = "Per Submitted"

class OfferCreate(BaseModel):
    supplier_id: int
    connection_id: int
    network_id: int
    price: float
    currency: str = "EUR"
    effective_date: Optional[str] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[str] = None
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    charge_model: Optional[str] = None
    is_exclusive: Optional[str] = None
    notes: Optional[str] = None

class EmailSettings(BaseModel):
    host: str
    username: str
    password: str
    folder: str
    refresh_minutes: int = 5

class TemplateCreate(BaseModel):
    name: str
    supplier_id: Optional[int] = None
    conditions_json: Optional[dict] = None
    extract_map_json: Optional[dict] = None
    callback_url: Optional[str] = None
    add_attrs_json: Optional[dict] = None
    enabled: bool = True

class ScraperSettings(BaseModel):
    base_url: Optional[str] = None
    username: Optional[str] = None
    password: Optional[str] = None
    cookies_json: Optional[dict] = None
    endpoints_json: Optional[dict] = None

class DropdownsUpdate(BaseModel):
    route_types: List[str] = Field(default_factory=lambda: ["Direct","SS7","SIM","Local Bypass"])
    known_hops: List[str] = Field(default_factory=lambda: ["0-Hop","1-Hop","2-Hops","N-Hops"])
    sender_id_supported: List[str] = Field(default_factory=lambda: ["Dynamic Alphanumeric","Dynamic Numeric","Short code"])
    registration_required: List[str] = Field(default_factory=lambda: ["Yes","No"])
    is_exclusive: List[str] = Field(default_factory=lambda: ["Yes","No"])

# --------- Suppliers & Connections ----------
@router.get("/suppliers/")
def list_suppliers(user = Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text(
            "SELECT id, organization_name, COALESCE(per_delivered,false) per_delivered FROM suppliers ORDER BY id"
        )).fetchall()
    return [_row(r) for r in rows]

@router.post("/suppliers/")
def create_supplier(body: SupplierCreate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text(
            "INSERT INTO suppliers(organization_name, per_delivered) VALUES(:n,:p) RETURNING id, organization_name, COALESCE(per_delivered,false) per_delivered"
        ), {"n": body.organization_name, "p": body.per_delivered}).fetchone()
    return _row(r)

@router.get("/suppliers/{supplier_id}/connections")
def list_connections(supplier_id:int, user = Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text(
            "SELECT id, supplier_id, connection_name, kannel_smsc, username, charge_model FROM supplier_connections WHERE supplier_id=:sid ORDER BY id"
        ), {"sid": supplier_id}).fetchall()
    return [_row(r) for r in rows]

@router.post("/suppliers/{supplier_id}/connections")
def add_connection(supplier_id:int, body: ConnectionCreate, user = Depends(auth_guard)):
    if supplier_id != body.supplier_id:
        raise HTTPException(400, "supplier_id mismatch")
    with engine.begin() as conn:
        r = conn.execute(text(
            "INSERT INTO supplier_connections(supplier_id, connection_name, kannel_smsc, username, charge_model) "
            "VALUES(:sid,:cn,:ks,:un,:cm) RETURNING id, supplier_id, connection_name, kannel_smsc, username, charge_model"
        ), {"sid": body.supplier_id, "cn": body.connection_name, "ks": body.kannel_smsc, "un": body.username, "cm": body.charge_model}).fetchone()
    return _row(r)

# --------- Offers ----------
# NOTE: GET /offers/ likely exists already in your app; we only add POST.
@router.post("/offers/")
def add_offer(body: OfferCreate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO offers_current(
                supplier_id, connection_id, network_id, price, currency, effective_date,
                route_type, known_hops, sender_id_supported, registration_required,
                eta_days, charge_model, is_exclusive, notes, updated_by
            ) VALUES(
                :supplier_id, :connection_id, :network_id, :price, :currency,
                COALESCE(NULLIF(:effective_date,''), NOW())::timestamp,
                :route_type, :known_hops, :sender_id_supported, :registration_required,
                :eta_days, :charge_model, :is_exclusive, :notes, 'webui'
            ) RETURNING *
        """), body.__dict__).fetchone()
    return _row(r)

# --------- Email settings ----------
@router.get("/email/settings")
def get_email_settings(user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT id, host, username, folder, refresh_minutes FROM email_settings WHERE id=1")).fetchone()
    return _row(r) if r else {}

@router.post("/email/settings")
def set_email_settings(body: EmailSettings, user = Depends(auth_guard)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO email_settings(id, host, username, password, folder, refresh_minutes)
            VALUES(1, :host, :username, :password, :folder, :refresh)
            ON CONFLICT (id) DO UPDATE SET
               host=EXCLUDED.host, username=EXCLUDED.username, password=EXCLUDED.password,
               folder=EXCLUDED.folder, refresh_minutes=EXCLUDED.refresh_minutes
        """), {"host":body.host, "username":body.username, "password":body.password, "folder":body.folder, "refresh":body.refresh_minutes})
    return {"ok": True}

# --------- Parser templates ----------
@router.get("/templates/")
def list_templates(user = Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text("SELECT id, name, supplier_id, enabled FROM parser_templates ORDER BY id")).fetchall()
    return [_row(r) for r in rows]

@router.post("/templates/")
def create_template(body: TemplateCreate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO parser_templates(name, supplier_id, conditions_json, extract_map_json, callback_url, add_attrs_json, enabled)
            VALUES(:name,:supplier_id, :conditions_json::jsonb, :extract_map_json::jsonb, :callback_url, :add_attrs_json::jsonb, :enabled)
            RETURNING id, name, supplier_id, enabled
        """), {
            "name": body.name,
            "supplier_id": body.supplier_id,
            "conditions_json": body.conditions_json or {},
            "extract_map_json": body.extract_map_json or {},
            "callback_url": body.callback_url,
            "add_attrs_json": body.add_attrs_json or {},
            "enabled": body.enabled
        }).fetchone()
    return _row(r)

# --------- Scraper settings ----------
@router.get("/scraper/settings")
def get_scraper_settings(user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT id, base_url, username FROM scraper_settings WHERE id=1")).fetchone()
    return _row(r) if r else {}

@router.post("/scraper/settings")
def set_scraper_settings(body: ScraperSettings, user = Depends(auth_guard)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO scraper_settings(id, base_url, username, password, cookies_json, endpoints_json)
            VALUES(1, :base_url, :username, :password, :cookies::jsonb, :endpoints::jsonb)
            ON CONFLICT (id) DO UPDATE SET
               base_url=EXCLUDED.base_url, username=EXCLUDED.username, password=EXCLUDED.password,
               cookies_json=EXCLUDED.cookies_json, endpoints_json=EXCLUDED.endpoints_json
        """), {
            "base_url": body.base_url, "username": body.username, "password": body.password,
            "cookies": body.cookies_json or {}, "endpoints": body.endpoints_json or {}
        })
    return {"ok": True}

# --------- Dropdown configs ----------
@router.get("/config/dropdowns")
def get_dropdowns(user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT route_types, known_hops, sender_id_supported, registration_required, is_exclusive FROM dropdown_configs WHERE id=1")).fetchone()
    if r:
        d = _row(r)
        return {k: (d.get(k) or []) for k in ["route_types","known_hops","sender_id_supported","registration_required","is_exclusive"]}
    return {
        "route_types": ["Direct","SS7","SIM","Local Bypass"],
        "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
        "sender_id_supported": ["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
        "registration_required": ["Yes","No"],
        "is_exclusive": ["Yes","No"]
    }

@router.post("/config/dropdowns")
def set_dropdowns(body: DropdownsUpdate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO dropdown_configs(id, route_types, known_hops, sender_id_supported, registration_required, is_exclusive)
            VALUES(1, :rt::jsonb, :kh::jsonb, :sid::jsonb, :rr::jsonb, :ie::jsonb)
            ON CONFLICT (id) DO UPDATE SET
              route_types=EXCLUDED.route_types,
              known_hops=EXCLUDED.known_hops,
              sender_id_supported=EXCLUDED.sender_id_supported,
              registration_required=EXCLUDED.registration_required,
              is_exclusive=EXCLUDED.is_exclusive
        """), {
            "rt": body.route_types, "kh": body.known_hops, "sid": body.sender_id_supported,
            "rr": body.registration_required, "ie": body.is_exclusive
        })
    return {"ok": True}
PY

echo "🧩 Making sure main.py includes the router ..."
if ! grep -q "from app.routers import create_api" "$MAIN_PY"; then
  cat >> "$MAIN_PY" <<'PY'

# ---- attach create_api router (idempotent) ----
try:
    from app.routers import create_api
    app.include_router(create_api.router)
except Exception as e:
    print("WARN: could not include create_api router:", e)
PY
fi

echo "🎨 Writing Web UI (index.html, main.css, main.js) ..."
cat > "$WEB_DIR/index.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SMS Procurement Manager</title>
  <link rel="stylesheet" href="/main.css">
</head>
<body>
  <header>
    <h1>SMS Procurement Manager</h1>
    <div id="apiInfo">API: <span id="apiBase"></span></div>
  </header>

  <nav id="nav"></nav>

  <main id="app"></main>

  <footer>
    <small>v0.9 — <a href="#" id="logout">Logout</a></small>
  </footer>

  <script src="/main.js"></script>
</body>
</html>
HTML

cat > "$WEB_DIR/main.css" <<'CSS'
:root { --bg:#0b1220; --card:#121a2b; --text:#eaf1ff; --muted:#9fb0d1; --acc:#5da0ff; }
*{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,Segoe UI,Roboto}
header,footer{padding:12px 16px;background:linear-gradient(90deg,#0e182c,#0b1220)}
h1{margin:0;font-size:18px}
#apiInfo{float:right;color:var(--muted)}
nav{display:flex;gap:8px;flex-wrap:wrap;padding:8px 16px;background:#0e1626;border-bottom:1px solid #1b2741}
nav button{background:#15223a;color:var(--text);border:1px solid #223152;border-radius:10px;padding:8px 12px;cursor:pointer}
nav button.active{background:var(--acc);border-color:var(--acc);color:#04122a}
#app{padding:16px}
.card{background:var(--card);padding:16px;border-radius:14px;border:1px solid #1b2741;box-shadow:0 4px 18px #00000066}
.toolbar{display:flex;gap:8px;align-items:center;margin:8px 0;flex-wrap:wrap}
input,select,textarea{background:#0e1626;color:var(--text);border:1px solid #223152;border-radius:8px;padding:8px}
button.primary{background:var(--acc);border:none;color:#04122a;border-radius:10px;padding:8px 12px;font-weight:600}
.table{width:100%;border-collapse:collapse;margin-top:8px}
.table th,.table td{padding:8px;border-bottom:1px solid #1b2741}
.muted{color:var(--muted)}
.center{display:flex;align-items:center;justify-content:center;height:60vh}
.login{max-width:360px;margin:40px auto}
CSS

cat > "$WEB_DIR/main.js" <<'JS'
const API_BASE = localStorage.getItem("API_BASE") || `http://${location.hostname}:8010`;
const tokenKey = "spm_token";

const navItems = [
  {key:"hot", label:"What's New", view: renderHot},
  {key:"offers", label:"Suppliers Offers", view: renderOffers},
  {key:"suppliers", label:"Suppliers", view: renderSuppliers},
  {key:"email", label:"Email Connection", view: renderEmail},
  {key:"templates", label:"Parser Templates", view: renderTemplates},
  {key:"scraper", label:"Scraper Settings", view: renderScraper},
  {key:"configs", label:"Dropdown Configs", view: renderConfigs},
  {key:"users", label:"Users", view: renderUsers},
];

function setNav(active="hot"){
  const n=document.querySelector('#nav');
  n.innerHTML = navItems.map(it=>`<button data-k="${it.key}" class="${active===it.key?'active':''}">${it.label}</button>`).join("");
  n.querySelectorAll('button').forEach(b=>{
    b.onclick = ()=>{ selectView(b.dataset.k); };
  });
}
function selectView(key){
  const item = navItems.find(x=>x.key===key) || navItems[0];
  setNav(key);
  item.view();
}

function layout(inner){
  return `<div class="card">${inner}</div>`;
}

async function authFetch(path, opts={}){
  const t = localStorage.getItem(tokenKey);
  const h = opts.headers || {};
  if (t) h["Authorization"] = `Bearer ${t}`;
  opts.headers = h;
  const res = await fetch(`${API_BASE}${path}`, opts);
  if(!res.ok){
    const txt = await res.text().catch(()=>res.statusText);
    throw new Error(`${res.status} ${txt}`);
  }
  const ct = res.headers.get("content-type") || "";
  return ct.includes("application/json") ? res.json() : res.text();
}

async function requireLogin(){
  const app = document.querySelector('#app');
  app.innerHTML = layout(`
    <div class="login">
      <h2>Login</h2>
      <div class="toolbar">
        <input id="lu" placeholder="Username" value="admin">
        <input id="lp" type="password" placeholder="Password" value="admin123">
        <button class="primary" id="lg">Login</button>
      </div>
      <div class="muted">API: <span id="apiBase"></span></div>
      <div class="muted" style="margin-top:6px">Tip: the API base is detected from your host. Set a custom one with:<br/>localStorage.setItem('API_BASE','http://IP:8010')</div>
    </div>
  `);
  document.querySelector('#apiBase').textContent = API_BASE;
  document.querySelector('#lg').onclick = async ()=>{
    const body = new URLSearchParams({username: lu.value, password: lp.value});
    const res = await fetch(`${API_BASE}/users/login`, {
      method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body
    });
    if(!res.ok){ alert('Login failed'); return; }
    const j = await res.json();
    localStorage.setItem(tokenKey, j.access_token);
    boot();
  };
}

async function renderHot(){
  const app = document.querySelector('#app');
  app.innerHTML = layout(`
    <h2>What's New</h2>
    <p class="muted">Create endpoints are enabled across all menus. Use the navigation above.</p>
    <div>API base: <b id="apiBase"></b></div>
  `);
  document.querySelector('#apiBase').textContent = API_BASE;
}

async function renderOffers(){
  const app = document.querySelector('#app');
  let rows='';
  try {
    const data = await authFetch('/offers/');
    rows = (data||[]).map(o=>`<tr>
      <td>${o.supplier_id??''}</td><td>${o.connection_id??''}</td><td>${o.network_id??''}</td>
      <td>${o.price??''}</td><td>${o.currency??''}</td><td>${o.effective_date??''}</td>
    </tr>`).join('');
  } catch(e) {
    rows = `<tr><td colspan="6" class="muted">${e}</td></tr>`;
  }
  app.innerHTML = layout(`
    <h2>Suppliers Offers</h2>
    <div class="toolbar">
      <input id="ofsupplier" type="number" placeholder="Supplier ID">
      <input id="ofconn" type="number" placeholder="Connection ID">
      <input id="ofnet" type="number" placeholder="Network ID">
      <input id="ofprice" type="number" step="0.0001" placeholder="Price">
      <select id="ofcurr"><option>EUR</option><option>USD</option></select>
      <button class="primary" id="addOffer">Add Offer</button>
    </div>
    <table class="table">
      <tr><th>Supplier</th><th>Connection</th><th>Network</th><th>Price</th><th>Currency</th><th>Effective</th></tr>
      ${rows || `<tr><td colspan="6" class="muted">No offers</td></tr>`}
    </table>
  `);
  document.querySelector('#addOffer').onclick = async ()=>{
    const body = {
      supplier_id: parseInt(ofsupplier.value,10),
      connection_id: parseInt(ofconn.value,10),
      network_id: parseInt(ofnet.value,10),
      price: parseFloat(ofprice.value),
      currency: ofcurr.value
    };
    await authFetch('/offers/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    renderOffers();
  };
}

async function renderSuppliers(){
  const app = document.querySelector('#app');
  let rows='';
  try{
    const s = await authFetch('/suppliers/');
    rows = (s||[]).map(x=>`<tr><td>${x.id}</td><td>${x.organization_name}</td><td>${x.per_delivered?'Yes':'No'}</td></tr>`).join('');
  }catch(e){
    rows = `<tr><td colspan="3" class="muted">${e}</td></tr>`;
  }
  app.innerHTML = layout(`
    <h2>Suppliers</h2>
    <div class="toolbar">
      <input id="org" placeholder="Organization Name">
      <label><input id="pd" type="checkbox"> Per Delivered</label>
      <button class="primary" id="addSup">Add</button>
    </div>
    <h3>Connections</h3>
    <div class="toolbar">
      <input id="sid" type="number" placeholder="Supplier ID">
      <input id="cn" placeholder="Connection Name">
      <input id="smsc" placeholder="Kannel SMSC">
      <input id="un" placeholder="Username">
      <input id="cm" placeholder="Charge Model" value="Per Submitted">
      <button id="addConn">Add Connection</button>
    </div>
    <table class="table">
      <tr><th>ID</th><th>Organization</th><th>Per Delivered</th></tr>
      ${rows || `<tr><td colspan="3" class="muted">Empty</td></tr>`}
    </table>
  `);
  document.querySelector('#addSup').onclick = async ()=>{
    const body = {organization_name: org.value, per_delivered: pd.checked};
    await authFetch('/suppliers/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    renderSuppliers();
  };
  document.querySelector('#addConn').onclick = async ()=>{
    const sid = parseInt(document.querySelector('#sid').value||"0",10);
    const body = {
      supplier_id: sid,
      connection_name: cn.value,
      kannel_smsc: smsc.value,
      username: un.value,
      charge_model: cm.value || "Per Submitted"
    };
    await authFetch(`/suppliers/${sid}/connections`, {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Connection added.');
  };
}

async function renderEmail(){
  const app = document.querySelector('#app');
  app.innerHTML = layout(`
    <h2>Email Connection</h2>
    <div class="toolbar">
      <input id="host" placeholder="IMAP host">
      <input id="user" placeholder="IMAP user">
      <input id="pass" type="password" placeholder="IMAP app-password">
      <input id="folder" placeholder="Folder (e.g. INBOX)">
      <input id="refresh" type="number" placeholder="Refresh minutes" value="5" style="width:140px">
      <button id="test">Test</button>
      <button class="primary" id="save">Save</button>
    </div>
    <div id="out" class="muted"></div>
  `);
  document.querySelector('#test').onclick = async ()=>{
    const body = {host:host.value, user:user.value, password:pass.value, folder:folder.value};
    try{ const j = await authFetch('/email/check',{method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)}); out.textContent = JSON.stringify(j); }
    catch(e){ out.textContent = e; }
  };
  document.querySelector('#save').onclick = async ()=>{
    const body = {host:host.value, username:user.value, password:pass.value, folder:folder.value, refresh_minutes: parseInt(refresh.value||"5",10)};
    await authFetch('/email/settings',{method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    out.textContent = 'Saved.';
  };
}

async function renderTemplates(){
  const app = document.querySelector('#app');
  let existing=[];
  try{ existing = await authFetch('/templates/'); }catch{}
  const rows = (existing||[]).map(t=>`<tr><td>${t.id}</td><td>${t.name}</td><td>${t.supplier_id??''}</td><td>${t.enabled?'Yes':'No'}</td></tr>`).join('') || `<tr><td colspan="4" class="muted">No templates.</td></tr>`;
  app.innerHTML = layout(`
    <h2>Parser Templates</h2>
    <div class="toolbar" style="gap:12px;flex-wrap:wrap">
      <input id="tname" placeholder="Template name">
      <input id="tsupplier" type="number" placeholder="Supplier ID (optional)">
      <textarea id="tconditions" placeholder='conditions JSON' style="width:100%;height:80px"></textarea>
      <textarea id="textract" placeholder='extract map JSON' style="width:100%;height:80px"></textarea>
      <input id="tcallback" placeholder="Callback URL (optional)" style="width:100%">
      <textarea id="tattrs" placeholder='extra attrs JSON' style="width:100%;height:80px"></textarea>
      <label><input id="tenabled" type="checkbox" checked> Enabled</label>
      <button class="primary" id="tcreate">Create Template</button>
    </div>
    <table class="table"><tr><th>ID</th><th>Name</th><th>Supplier</th><th>Enabled</th></tr>${rows}</table>
  `);
  const j = s=>{ try{return JSON.parse(s||"{}")}catch{return{}} };
  document.querySelector('#tcreate').onclick = async ()=>{
    const body = {
      name: tname.value,
      supplier_id: parseInt(tsupplier.value||"0",10) || null,
      conditions_json: j(tconditions.value),
      extract_map_json: j(textract.value),
      callback_url: tcallback.value || null,
      add_attrs_json: j(tattrs.value),
      enabled: tenabled.checked
    };
    await authFetch('/templates/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    renderTemplates();
  };
}

async function renderScraper(){
  const app = document.querySelector('#app');
  let st={};
  try{ st = await authFetch('/scraper/settings'); }catch{}
  app.innerHTML = layout(`
    <h2>Scraper Settings</h2>
    <div class="toolbar" style="gap:12px;flex-wrap:wrap">
      <input id="sbase" placeholder="Base URL" value="${st.base_url||''}" style="width:100%">
      <input id="suser" placeholder="Username" value="${st.username||''}">
      <input id="spass" type="password" placeholder="Password">
      <textarea id="scookies" placeholder='cookies JSON' style="width:100%;height:80px"></textarea>
      <textarea id="sendpoints" placeholder='endpoints JSON' style="width:100%;height:80px"></textarea>
      <button class="primary" id="ssave">Save</button>
    </div>
  `);
  const j = s=>{ try{return JSON.parse(s||"{}")}catch{return{}} };
  document.querySelector('#ssave').onclick = async ()=>{
    const body = {base_url:sbase.value, username:suser.value, password:spass.value, cookies_json:j(scookies.value), endpoints_json:j(sendpoints.value)};
    await authFetch('/scraper/settings',{method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Saved.');
  };
}

async function renderConfigs(){
  const app = document.querySelector('#app');
  let cfg={};
  try{ cfg = await authFetch('/config/dropdowns'); }catch{
    cfg = {route_types:["Direct","SS7","SIM","Local Bypass"], known_hops:["0-Hop","1-Hop","2-Hops","N-Hops"], sender_id_supported:["Dynamic Alphanumeric","Dynamic Numeric","Short code"], registration_required:["Yes","No"], is_exclusive:["Yes","No"]};
  }
  function csv(a){return (a||[]).join(', ')}
  app.innerHTML = layout(`
    <h2>Dropdown Configurations</h2>
    <div class="toolbar" style="gap:8px;flex-direction:column;align-items:stretch">
      <label>Route Types <input id="rt" style="width:100%" value="${csv(cfg.route_types)}"></label>
      <label>Known Hops <input id="kh" style="width:100%" value="${csv(cfg.known_hops)}"></label>
      <label>Sender ID Supported <input id="sid" style="width:100%" value="${csv(cfg.sender_id_supported)}"></label>
      <label>Registration Required <input id="rr" style="width:100%" value="${csv(cfg.registration_required)}"></label>
      <label>Is Exclusive <input id="ie" style="width:100%" value="${csv(cfg.is_exclusive)}"></label>
      <button class="primary" id="saveCfg">Save</button>
    </div>
  `);
  const split = s => (s||'').split(',').map(x=>x.trim()).filter(Boolean);
  document.querySelector('#saveCfg').onclick = async ()=>{
    const body = {route_types: split(rt.value), known_hops: split(kh.value), sender_id_supported: split(sid.value), registration_required: split(rr.value), is_exclusive: split(ie.value)};
    await authFetch('/config/dropdowns',{method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Saved.');
  };
}

async function renderUsers(){
  const app = document.querySelector('#app');
  app.innerHTML = layout(`
    <h2>Users</h2>
    <div class="toolbar">
      <input id="uu" placeholder="Username">
      <input id="pp" type="password" placeholder="Password">
      <select id="rrr"><option>user</option><option>admin</option></select>
      <button class="primary" id="uc">Create</button>
    </div>
    <div class="muted">User listing coming later.</div>
  `);
  document.querySelector('#uc').onclick = async ()=>{
    const body = {username: uu.value, password: pp.value, role: rrr.value};
    await authFetch('/users/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('User created.');
  };
}

function boot(){
  document.querySelector('#apiBase').textContent = API_BASE;
  setNav("hot");
  selectView("hot");
}

document.getElementById('logout').onclick = ()=>{ localStorage.removeItem(tokenKey); requireLogin(); };

(async function init(){
  document.querySelector('#apiBase').textContent = API_BASE;
  const t = localStorage.getItem(tokenKey);
  if (!t) return requireLogin();
  try{
    await authFetch('/'); // ping
    boot();
  }catch{
    requireLogin();
  }
})();
JS

echo "🛠 Rebuild & restart api/web ..."
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

echo "✅ Done."
echo "Open Web UI:  http://localhost:5183  (or http://<your-ip>:5183)"
echo "Login with:   admin / admin123"
echo "If API differs, set from devtools: localStorage.setItem('API_BASE','http://<ip>:8010'); hard refresh."
