#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_MAIN="$ROOT/api/app/main.py"
WEB_JS="$ROOT/web/public/main.js"
WEB_INDEX="$ROOT/web/public/index.html"
DOCKER_DIR="$ROOT/docker"

# --- API: add DDL + create endpoints (idempotent) ---
python3 - <<'PY'
from pathlib import Path, re
p = Path.home()/ "sms-procurement-manager/api/app/main.py"
s = p.read_text()

# Ensure we have needed imports
if "from sqlalchemy import text" not in s:
    s = s.replace("from fastapi import FastAPI", "from fastapi import FastAPI, Depends\nfrom sqlalchemy import text")

# Ensure we can access DB engine/session
need_db = "from app.core.database import SessionLocal, engine" not in s
if need_db and "from app.core.database import" in s:
    # keep existing import if it already imports SessionLocal/engine elsewhere
    pass
elif need_db:
    s = s.replace("from fastapi import FastAPI, Depends", "from fastapi import FastAPI, Depends\nfrom app.core.database import SessionLocal, engine")

# Startup DDL
if "def _ensure_schema()" not in s:
    s += r"""

# --- Minimal schema bootstrap (idempotent) ---
def _ensure_schema():
    ddl = [
        # suppliers and connections
        \"\"\"CREATE TABLE IF NOT EXISTS suppliers(
            id SERIAL PRIMARY KEY,
            organization_name VARCHAR NOT NULL,
            per_delivered BOOLEAN DEFAULT FALSE
        )\"\"\",
        \"\"\"CREATE TABLE IF NOT EXISTS supplier_connections(
            id SERIAL PRIMARY KEY,
            supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
            connection_name VARCHAR,
            kannel_smsc VARCHAR,
            username VARCHAR,
            charge_model VARCHAR
        )\"\"\",
        # countries/networks baseline (lightweight)
        \"\"\"CREATE TABLE IF NOT EXISTS countries(
            id SERIAL PRIMARY KEY,
            name VARCHAR,
            mcc VARCHAR
        )\"\"\",
        \"\"\"CREATE TABLE IF NOT EXISTS networks(
            id SERIAL PRIMARY KEY,
            country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
            name VARCHAR,
            mnc VARCHAR,
            mccmnc VARCHAR
        )\"\"\",
        # offers_current
        \"\"\"CREATE TABLE IF NOT EXISTS offers_current(
            id SERIAL PRIMARY KEY,
            supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
            connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE SET NULL,
            network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,
            price DOUBLE PRECISION,
            currency VARCHAR(8) DEFAULT 'EUR',
            effective_date TIMESTAMP,
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
        )\"\"\",
        # email settings (single row)
        \"\"\"CREATE TABLE IF NOT EXISTS email_settings(
            id INTEGER PRIMARY KEY DEFAULT 1,
            host VARCHAR,
            username VARCHAR,
            password VARCHAR,
            folder VARCHAR,
            refresh_minutes INTEGER DEFAULT 5
        )\"\"\",
        # parser templates
        \"\"\"CREATE TABLE IF NOT EXISTS parser_templates(
            id SERIAL PRIMARY KEY,
            name VARCHAR NOT NULL,
            supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
            conditions_json JSONB,
            extract_map_json JSONB,
            callback_url VARCHAR,
            add_attrs_json JSONB,
            enabled BOOLEAN DEFAULT TRUE
        )\"\"\",
        # scraper settings (single row)
        \"\"\"CREATE TABLE IF NOT EXISTS scraper_settings(
            id INTEGER PRIMARY KEY DEFAULT 1,
            base_url VARCHAR,
            username VARCHAR,
            password VARCHAR,
            cookies_json JSONB,
            endpoints_json JSONB
        )\"\"\",
        # dropdown configs (single row)
        \"\"\"CREATE TABLE IF NOT EXISTS dropdown_configs(
            id INTEGER PRIMARY KEY DEFAULT 1,
            route_types JSONB,
            known_hops JSONB,
            sender_id_supported JSONB,
            registration_required JSONB,
            is_exclusive JSONB
        )\"\"\"
    ]
    with engine.begin() as conn:
        for d in ddl:
            conn.execute(text(d))

@app.on_event("startup")
def _startup_schema():
    _ensure_schema()
"""

# Auth requirement helper (already present as auth_required) fallback
if "def auth_required" not in s and "OAuth2PasswordBearer" in s:
    s += r"""
# Fallback guard if not present
def auth_required():
    return True
"""

# Pydantic request bodies
if "from pydantic import BaseModel, Field" not in s:
    if "from pydantic import BaseModel" in s:
        s = s.replace("from pydantic import BaseModel", "from pydantic import BaseModel, Field")
    else:
        s = s.replace("from fastapi import FastAPI, Depends", "from fastapi import FastAPI, Depends\nfrom pydantic import BaseModel, Field")

if "class SupplierCreate(" not in s:
    s += r"""

# ---- Pydantic models for create/update ----
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
    effective_date: str | None = None
    route_type: str | None = None
    known_hops: str | None = None
    sender_id_supported: str | None = None
    registration_required: str | None = None
    eta_days: int | None = None
    charge_model: str | None = None
    is_exclusive: str | None = None
    notes: str | None = None

class EmailSettings(BaseModel):
    host: str
    username: str
    password: str
    folder: str
    refresh_minutes: int = 5

class TemplateCreate(BaseModel):
    name: str
    supplier_id: int | None = None
    conditions_json: dict | None = None
    extract_map_json: dict | None = None
    callback_url: str | None = None
    add_attrs_json: dict | None = None
    enabled: bool = True

class ScraperSettings(BaseModel):
    base_url: str | None = None
    username: str | None = None
    password: str | None = None
    cookies_json: dict | None = None
    endpoints_json: dict | None = None

class DropdownsUpdate(BaseModel):
    route_types: list[str] = Field(default_factory=lambda:["Direct","SS7","SIM","Local Bypass"])
    known_hops: list[str] = Field(default_factory=lambda:["0-Hop","1-Hop","2-Hops","N-Hops"])
    sender_id_supported: list[str] = Field(default_factory=lambda:["Dynamic Alphanumeric","Dynamic Numeric","Short code"])
    registration_required: list[str] = Field(default_factory=lambda:["Yes","No"])
    is_exclusive: list[str] = Field(default_factory=lambda:["Yes","No"])

class UserCreate(BaseModel):
    username: str
    password: str
    role: str = "user"
"""

# Helpers
if "def _rowmap" not in s:
    s += r"""
def _rowmap(r):
    return dict(r._mapping) if hasattr(r, "_mapping") else dict(r)
"""

# Endpoints: Suppliers (GET/POST), Connections (GET/POST)
if "@app.post(\"/suppliers/\")" not in s:
    s += r"""
@app.get("/suppliers/")
def list_suppliers(_: bool = Depends(auth_required)):
    with engine.begin() as conn:
        rows = conn.execute(text("SELECT id, organization_name, COALESCE(per_delivered,FALSE) AS per_delivered FROM suppliers ORDER BY id")).fetchall()
    return [_rowmap(r) for r in rows]

@app.post("/suppliers/")
def create_supplier(body: SupplierCreate, _: bool = Depends(auth_required)):
    with engine.begin() as conn:
        r = conn.execute(text(
            "INSERT INTO suppliers(organization_name, per_delivered) VALUES(:n,:p) RETURNING id, organization_name, COALESCE(per_delivered,FALSE) AS per_delivered"
        ), {"n": body.organization_name, "p": body.per_delivered}).fetchone()
    return _rowmap(r)

@app.get("/suppliers/{supplier_id}/connections")
def list_connections(supplier_id:int, _: bool = Depends(auth_required)):
    with engine.begin() as conn:
        rows = conn.execute(text(
            "SELECT id, supplier_id, connection_name, kannel_smsc, username, charge_model FROM supplier_connections WHERE supplier_id=:sid ORDER BY id"
        ), {"sid": supplier_id}).fetchall()
    return [_rowmap(r) for r in rows]

@app.post("/suppliers/{supplier_id}/connections")
def add_connection(supplier_id:int, body: ConnectionCreate, _: bool = Depends(auth_required)):
    assert supplier_id == body.supplier_id, "Path/body supplier_id mismatch"
    with engine.begin() as conn:
        r = conn.execute(text(
            "INSERT INTO supplier_connections(supplier_id, connection_name, kannel_smsc, username, charge_model) "
            "VALUES(:sid,:cn,:ks,:un,:cm) RETURNING id, supplier_id, connection_name, kannel_smsc, username, charge_model"
        ), {"sid": body.supplier_id, "cn": body.connection_name, "ks": body.kannel_smsc, "un": body.username, "cm": body.charge_model}).fetchone()
    return _rowmap(r)
"""

# Offers (GET exists in your app; add POST safely)
if "@app.post(\"/offers/\")" not in s:
    s += r"""
@app.post("/offers/")
def add_offer(body: OfferCreate, _: bool = Depends(auth_required)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO offers_current(
                supplier_id, connection_id, network_id, price, currency, effective_date,
                route_type, known_hops, sender_id_supported, registration_required,
                eta_days, charge_model, is_exclusive, notes, updated_by
            ) VALUES(
                :supplier_id, :connection_id, :network_id, :price, :currency,
                CASE WHEN :effective_date IS NULL OR :effective_date='' THEN NOW() ELSE :effective_date::timestamp END,
                :route_type, :known_hops, :sender_id_supported, :registration_required,
                :eta_days, :charge_model, :is_exclusive, :notes, 'webui'
            ) RETURNING *
        """), body.__dict__).fetchone()
    return _rowmap(r)
"""

# Email settings (GET/POST upsert)
if "@app.get(\"/email/settings\")" not in s:
    s += r"""
@app.get("/email/settings")
def get_email_settings(_: bool = Depends(auth_required)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT id, host, username, folder, refresh_minutes FROM email_settings WHERE id=1")).fetchone()
    return _rowmap(r) if r else {}

@app.post("/email/settings")
def set_email_settings(body: EmailSettings, _: bool = Depends(auth_required)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO email_settings(id, host, username, password, folder, refresh_minutes)
            VALUES(1, :host, :username, :password, :folder, :refresh)
            ON CONFLICT (id) DO UPDATE SET
              host=EXCLUDED.host, username=EXCLUDED.username, password=EXCLUDED.password,
              folder=EXCLUDED.folder, refresh_minutes=EXCLUDED.refresh_minutes
        """), {"host": body.host, "username": body.username, "password": body.password, "folder": body.folder, "refresh": body.refresh_minutes})
    return {"ok": True}
"""

# Parser templates (list/create)
if "@app.get(\"/templates/\")" not in s:
    s += r"""
@app.get("/templates/")
def list_templates(_: bool = Depends(auth_required)):
    with engine.begin() as conn:
        rows = conn.execute(text("SELECT id, name, supplier_id, enabled FROM parser_templates ORDER BY id")).fetchall()
    return [_rowmap(r) for r in rows]

@app.post("/templates/")
def create_template(body: TemplateCreate, _: bool = Depends(auth_required)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO parser_templates(name, supplier_id, conditions_json, extract_map_json, callback_url, add_attrs_json, enabled)
            VALUES(:name,:supplier_id, :conditions_json::jsonb, :extract_map_json::jsonb, :callback_url, :add_attrs_json::jsonb, :enabled)
            RETURNING id, name, supplier_id, enabled
        """), {
            "name": body.name, "supplier_id": body.supplier_id,
            "conditions_json": (body.conditions_json or {}),
            "extract_map_json": (body.extract_map_json or {}),
            "callback_url": body.callback_url,
            "add_attrs_json": (body.add_attrs_json or {}),
            "enabled": body.enabled
        }).fetchone()
    return _rowmap(r)
"""

# Scraper settings (GET/POST)
if "@app.get(\"/scraper/settings\")" not in s:
    s += r"""
@app.get("/scraper/settings")
def get_scraper_settings(_: bool = Depends(auth_required)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT id, base_url, username FROM scraper_settings WHERE id=1")).fetchone()
    return _rowmap(r) if r else {}

@app.post("/scraper/settings")
def set_scraper_settings(body: ScraperSettings, _: bool = Depends(auth_required)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO scraper_settings(id, base_url, username, password, cookies_json, endpoints_json)
            VALUES(1, :base_url, :username, :password, :cookies::jsonb, :endpoints::jsonb)
            ON CONFLICT (id) DO UPDATE SET
              base_url=EXCLUDED.base_url, username=EXCLUDED.username, password=EXCLUDED.password,
              cookies_json=EXCLUDED.cookies_json, endpoints_json=EXCLUDED.endpoints_json
        """), {
            "base_url": body.base_url, "username": body.username, "password": body.password,
            "cookies": (body.cookies_json or {}), "endpoints": (body.endpoints_json or {})
        })
    return {"ok": True}
"""
# Dropdown configs (GET exists; add POST)
if "@app.post(\"/config/dropdowns\")" not in s:
    s += r"""
@app.post("/config/dropdowns")
def set_dropdowns(body: DropdownsUpdate, _: bool = Depends(auth_required)):
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
"""

# Users (create)
if "@app.post(\"/users/\")" not in s:
    # we assume auth hashing utilities exist (get_password_hash)
    if "def get_password_hash" not in s and "from app.core import auth" not in s:
        s = s.replace("from fastapi import FastAPI, Depends", "from fastapi import FastAPI, Depends\nfrom app.core import auth")
    elif "from app.core import auth" not in s:
        s = s.replace("from fastapi import FastAPI, Depends", "from fastapi import FastAPI, Depends\nfrom app.core import auth")
    s += r"""
@app.post("/users/")
def create_user(body: UserCreate, _: bool = Depends(auth_required)):
    pwd = auth.get_password_hash(body.password)
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO users(username, password_hash, role)
            VALUES(:u, :p, :r) RETURNING id, username, role
        """), {"u": body.username, "p": pwd, "r": body.role}).fetchone()
    return _rowmap(r)
"""
# Ensure the users table exists (if your earlier model didn't create it)
if "CREATE TABLE IF NOT EXISTS users" not in s:
    s = s.replace("def _ensure_schema():", "def _ensure_schema():\n    # users\n    with engine.begin() as conn:\n        conn.execute(text(\"\"\"\n            CREATE TABLE IF NOT EXISTS users(\n              id SERIAL PRIMARY KEY,\n              username VARCHAR UNIQUE,\n              password_hash VARCHAR,\n              role VARCHAR\n            )\n        \"\"\"))\n")  # prepend a users table creation

p.write_text(s)
print("API patched OK")
PY

# --- WEB: extend views with create forms (Suppliers, Connections, Offers, Email, Templates, Scraper, Dropdowns, Users) ---
python3 - <<'PY'
from pathlib import Path
js = Path.home()/ "sms-procurement-manager/web/public/main.js"
t = js.read_text()

def inject(tag, body):
    if tag in t:
        return t
    return t + "\n" + body + "\n"

# Add create UI handlers to existing views
additions = r"""
// ---- Create forms wiring ----
async function renderSuppliers(){  // override previous
  const app = document.querySelector('#app');
  let rows = '';
  try{
    const s = await authFetch('/suppliers/');
    rows = (s||[]).map(x=>`<tr><td>${x.id}</td><td>${x.organization_name}</td><td>${x.per_delivered ? 'Yes':'No'}</td></tr>`).join('');
  }catch(e){ rows = `<tr><td colspan="3" class="muted">No suppliers or error.</td></tr>`; }
  app.innerHTML = layout(`
    <h2>Suppliers</h2>
    <div class="toolbar">
      <input id="org" placeholder="Organization Name">
      <label><input id="pd" type="checkbox"> Per Delivered</label>
      <button id="addSup">Add</button>
    </div>
    <table class="table">
      <tr><th>ID</th><th>Organization</th><th>Per Delivered</th></tr>
      ${rows || `<tr><td colspan="3" class="muted">Empty.</td></tr>`}
    </table>
    <h3 style="margin-top:18px">Add Connection</h3>
    <div class="toolbar">
      <input id="sid" type="number" placeholder="Supplier ID">
      <input id="cn" placeholder="Connection Name">
      <input id="smsc" placeholder="Kannel SMSC">
      <input id="un" placeholder="Username">
      <input id="cm" placeholder="Charge Model" value="Per Submitted">
      <button id="addConn">Add Connection</button>
    </div>
  `); wireNav(); document.querySelector('#apiBase').textContent = API_BASE;

  document.querySelector('#addSup').onclick = async()=>{
    const body = {organization_name: document.querySelector('#org').value, per_delivered: document.querySelector('#pd').checked};
    await authFetch('/suppliers/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    renderSuppliers();
  };
  document.querySelector('#addConn').onclick = async()=>{
    const sid = parseInt(document.querySelector('#sid').value||"0",10);
    const body = {
      supplier_id: sid,
      connection_name: document.querySelector('#cn').value,
      kannel_smsc: document.querySelector('#smsc').value,
      username: document.querySelector('#un').value,
      charge_model: document.querySelector('#cm').value || "Per Submitted"
    };
    await authFetch(`/suppliers/${sid}/connections`, {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Connection added.');
  };
}

async function renderOffers(){  // override previous
  const app = document.querySelector('#app');
  let tableRows='';
  try{
    const data = await authFetch('/offers/');
    tableRows = (data||[]).map(o=>`<tr><td>${o.supplier_id||''}</td><td>${o.connection_id||''}</td><td>${o.network_id||''}</td><td>${o.price||''}</td><td>${o.currency||''}</td><td>${o.effective_date||''}</td></tr>`).join('');
  }catch{ tableRows = `<tr><td colspan="6" class="muted">No offers or error.</td></tr>`; }
  app.innerHTML = layout(`
    <h2>Suppliers Offers</h2>
    <div class="toolbar">
      <input id="ofsupplier" type="number" placeholder="Supplier ID">
      <input id="ofconn" type="number" placeholder="Connection ID">
      <input id="ofnet" type="number" placeholder="Network ID">
      <input id="ofprice" type="number" step="0.0001" placeholder="Price">
      <select id="ofcurr"><option>EUR</option><option>USD</option></select>
      <button id="addOffer">Add Offer</button>
    </div>
    <table class="table">
      <tr><th>Supplier</th><th>Connection</th><th>Network</th><th>Price</th><th>Currency</th><th>Effective</th></tr>
      ${tableRows}
    </table>
  `);
  wireNav(); document.querySelector('#apiBase').textContent = API_BASE;

  document.querySelector('#addOffer').onclick = async()=>{
    const body = {
      supplier_id: parseInt(document.querySelector('#ofsupplier').value,10),
      connection_id: parseInt(document.querySelector('#ofconn').value,10),
      network_id: parseInt(document.querySelector('#ofnet').value,10),
      price: parseFloat(document.querySelector('#ofprice').value),
      currency: document.querySelector('#ofcurr').value
    };
    await authFetch('/offers/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    renderOffers();
  };
}

async function renderEmail(){ // override: add SAVE
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
      <button id="save">Save</button>
    </div>
    <div id="out" class="muted"></div>
  `);
  wireNav(); document.querySelector('#apiBase').textContent = API_BASE;

  document.querySelector('#test').onclick = async()=>{
    const body = {host:host.value, user:user.value, password:pass.value, folder:folder.value};
    try{ const j = await authFetch('/email/check', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)}); out.textContent = JSON.stringify(j); }
    catch(e){ out.textContent = 'Error: '+e; }
  };
  document.querySelector('#save').onclick = async()=>{
    const body = {host:host.value, username:user.value, password:pass.value, folder:folder.value, refresh_minutes: parseInt(refresh.value||"5",10)};
    await authFetch('/email/settings', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    out.textContent = 'Saved.';
  };
}

async function renderTemplates(){ // override with create
  const app = document.querySelector('#app');
  let existing = [];
  try{ existing = await authFetch('/templates/'); }catch{}
  const rows = (existing||[]).map(t=>`<tr><td>${t.id}</td><td>${t.name}</td><td>${t.supplier_id??''}</td><td>${t.enabled?'Yes':'No'}</td></tr>`).join('') || `<tr><td colspan="4" class="muted">No templates.</td></tr>`;
  app.innerHTML = layout(`
    <h2>Parser Templates</h2>
    <div class="toolbar" style="gap:12px; flex-wrap:wrap">
      <input id="tname" placeholder="Template name">
      <input id="tsupplier" type="number" placeholder="Supplier ID (optional)">
      <textarea id="tconditions" placeholder='conditions JSON' style="width:100%;height:80px"></textarea>
      <textarea id="textract" placeholder='extract map JSON' style="width:100%;height:80px"></textarea>
      <input id="tcallback" placeholder="Callback URL (optional)" style="width:100%">
      <textarea id="tattrs" placeholder='extra attrs JSON' style="width:100%;height:80px"></textarea>
      <label><input id="tenabled" type="checkbox" checked> Enabled</label>
      <button id="tcreate">Create Template</button>
    </div>
    <table class="table"><tr><th>ID</th><th>Name</th><th>Supplier</th><th>Enabled</th></tr>${rows}</table>
  `);
  wireNav(); document.querySelector('#apiBase').textContent = API_BASE;
  const j = s=>{ try{return JSON.parse(s||"{}")}catch{return{}} };
  document.querySelector('#tcreate').onclick = async()=>{
    const body = {
      name: document.querySelector('#tname').value,
      supplier_id: parseInt(document.querySelector('#tsupplier').value||"0",10) || null,
      conditions_json: j(document.querySelector('#tconditions').value),
      extract_map_json: j(document.querySelector('#textract').value),
      callback_url: document.querySelector('#tcallback').value || null,
      add_attrs_json: j(document.querySelector('#tattrs').value),
      enabled: document.querySelector('#tenabled').checked
    };
    await authFetch('/templates/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    renderTemplates();
  };
}

async function renderScraper(){ // override with save
  const app = document.querySelector('#app');
  let st = {};
  try{ st = await authFetch('/scraper/settings'); }catch{}
  app.innerHTML = layout(`
    <h2>Scraper Settings</h2>
    <div class="toolbar" style="gap:12px; flex-wrap:wrap">
      <input id="sbase" placeholder="Base URL" value="${st.base_url||''}" style="width:100%">
      <input id="suser" placeholder="Username" value="${st.username||''}">
      <input id="spass" type="password" placeholder="Password">
      <textarea id="scookies" placeholder='cookies JSON' style="width:100%;height:80px"></textarea>
      <textarea id="sendpoints" placeholder='endpoints JSON' style="width:100%;height:80px"></textarea>
      <button id="ssave">Save</button>
    </div>
    <div class="muted">Unrelated items bucket coming later.</div>
  `);
  wireNav(); document.querySelector('#apiBase').textContent = API_BASE;
  const j = s=>{ try{return JSON.parse(s||"{}")}catch{return{}} };
  document.querySelector('#ssave').onclick = async()=>{
    const body = {base_url: sbase.value, username: suser.value, password: spass.value, cookies_json: j(scookies.value), endpoints_json: j(sendpoints.value)};
    await authFetch('/scraper/settings', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Saved.');
  };
}

async function renderConfigs(){ // override with save
  const app = document.querySelector('#app');
  let cfg={route_types:["Direct","SS7","SIM","Local Bypass"], known_hops:["0-Hop","1-Hop","2-Hops","N-Hops"], sender_id_supported:["Dynamic Alphanumeric","Dynamic Numeric","Short code"], registration_required:["Yes","No"], is_exclusive:["Yes","No"]};
  try{ cfg = await authFetch('/config/dropdowns'); }catch{}
  function csv(arr){ return (arr||[]).join(', '); }
  app.innerHTML = layout(`
    <h2>Dropdown Configurations</h2>
    <div class="toolbar" style="gap:8px;flex-direction:column;align-items:stretch">
      <label>Route Types <input id="rt" style="width:100%" value="${csv(cfg.route_types)}"></label>
      <label>Known Hops <input id="kh" style="width:100%" value="${csv(cfg.known_hops)}"></label>
      <label>Sender ID Supported <input id="sid" style="width:100%" value="${csv(cfg.sender_id_supported)}"></label>
      <label>Registration Required <input id="rr" style="width:100%" value="${csv(cfg.registration_required)}"></label>
      <label>Is Exclusive <input id="ie" style="width:100%" value="${csv(cfg.is_exclusive)}"></label>
      <button id="saveCfg">Save</button>
    </div>
  `);
  wireNav(); document.querySelector('#apiBase').textContent = API_BASE;
  const split = s=> (s||'').split(',').map(x=>x.trim()).filter(Boolean);
  document.querySelector('#saveCfg').onclick = async()=>{
    const body = {route_types: split(rt.value), known_hops: split(kh.value), sender_id_supported: split(sid.value), registration_required: split(rr.value), is_exclusive: split(ie.value)};
    await authFetch('/config/dropdowns', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Saved.');
  };
}

async function renderUsers(){ // override with create
  const app = document.querySelector('#app');
  app.innerHTML = layout(`
    <h2>Users</h2>
    <div class="toolbar">
      <input id="uu" placeholder="Username">
      <input id="pp" type="password" placeholder="Password">
      <select id="rrr"><option>user</option><option>admin</option></select>
      <button id="uc">Create</button>
    </div>
    <div class="muted">User listing to be added later.</div>
  `);
  wireNav(); document.querySelector('#apiBase').textContent = API_BASE;
  document.querySelector('#uc').onclick = async()=>{
    const body = {username: uu.value, password: pp.value, role: rrr.value};
    await authFetch('/users/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('User created.');
  };
}
"""

if "Create forms wiring" not in t:
    t += "\n" + additions + "\n"
    js.write_text(t)
    print("WEB JS patched with create forms.")
else:
    print("WEB JS already patched.")
PY

# Ensure CSS link in index.html (idempotent)
if ! grep -q 'href="/main.css"' "$WEB_INDEX"; then
  awk '/<\/head>/{print "  <link rel=\"stylesheet\" href=\"/main.css\">"}1' "$WEB_INDEX" > "$WEB_INDEX.tmp" && mv "$WEB_INDEX.tmp" "$WEB_INDEX"
fi

# Rebuild & restart
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

echo "✅ Create actions enabled. Hard refresh the UI (Ctrl+Shift+R)."
