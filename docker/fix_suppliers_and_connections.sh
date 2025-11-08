#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE_DIR="$API_DIR/core"
MODELS_DIR="$API_DIR/models"
ROUTERS_DIR="$API_DIR/routers"
WEB_DIR="$ROOT/web/public"

mkdir -p "$CORE_DIR" "$MODELS_DIR" "$ROUTERS_DIR" "$WEB_DIR"

# ---------- models: Supplier / SupplierConnection (with per_delivered on connection) ----------
cat > "$MODELS_DIR/models.py" <<'PY'
from sqlalchemy import Column, Integer, String, Boolean, ForeignKey, DateTime, Numeric, Text
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from app.core.database import Base

class Supplier(Base):
    __tablename__ = "suppliers"
    id = Column(Integer, primary_key=True)
    organization_name = Column(String, unique=True, nullable=False)

    connections = relationship("SupplierConnection", cascade="all, delete-orphan", backref="supplier")

class SupplierConnection(Base):
    __tablename__ = "supplier_connections"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id", ondelete="CASCADE"), nullable=False)
    connection_name = Column(String, nullable=False)
    username = Column(String)          # Kannel SMSc username
    kannel_smsc = Column(String)
    charge_model = Column(String, default="Per Submitted")
    per_delivered = Column(Boolean, nullable=False, default=False)

# (kept minimal to avoid breaking /offers/ if you use it)
class OfferCurrent(Base):
    __tablename__ = "offers_current"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    network_id = Column(Integer)
    price = Column(Numeric(asdecimal=False))
    currency = Column(String(8), default="EUR")
    effective_date = Column(DateTime)
    route_type = Column(String(64))
    known_hops = Column(String(32))
    sender_id_supported = Column(String(128))
    registration_required = Column(String(16))
    eta_days = Column(Integer)
    charge_model = Column(String(32))
    is_exclusive = Column(String(8))
    notes = Column(Text)
    updated_by = Column(String(64))
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())
PY

# ---------- startup migration (idempotent) ----------
# - ensure tables exist
# - move per_delivered to supplier_connections (add there; drop from suppliers if present)
cat > "$API_DIR/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

DDL = [
    # core tables
    """
    CREATE TABLE IF NOT EXISTS suppliers(
      id SERIAL PRIMARY KEY,
      organization_name VARCHAR NOT NULL UNIQUE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS supplier_connections(
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
      connection_name VARCHAR NOT NULL,
      username VARCHAR,
      kannel_smsc VARCHAR,
      charge_model VARCHAR DEFAULT 'Per Submitted',
      per_delivered BOOLEAN DEFAULT FALSE NOT NULL
    )
    """,
    # compatibility: old column existed on suppliers — remove it if present
    "ALTER TABLE suppliers DROP COLUMN IF EXISTS per_delivered",
    # ensure per_delivered on connections
    "ALTER TABLE supplier_connections ADD COLUMN IF NOT EXISTS per_delivered BOOLEAN DEFAULT FALSE",
]

def migrate():
    with engine.begin() as conn:
        for s in DDL:
            conn.execute(text(s))
PY

# ---------- routers: Suppliers ----------
cat > "$ROUTERS_DIR/suppliers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.models import models
from pydantic import BaseModel

router = APIRouter(prefix="/suppliers", tags=["Suppliers"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

class SupplierCreate(BaseModel):
    organization_name: str

class SupplierOut(BaseModel):
    id: int
    organization_name: str
    class Config:
        from_attributes = True

class ConnectionCreate(BaseModel):
    connection_name: str
    username: Optional[str] = None   # Kannel SMSc username
    per_delivered: bool = False

class ConnectionOut(BaseModel):
    id: int
    supplier_id: int
    connection_name: str
    username: Optional[str] = None
    per_delivered: bool
    charge_model: Optional[str] = "Per Submitted"
    class Config:
        from_attributes = True

@router.get("/", response_model=List[SupplierOut])
def list_suppliers(db: Session = Depends(get_db)):
    return db.query(models.Supplier).order_by(models.Supplier.id).all()

@router.post("/", response_model=SupplierOut)
def create_supplier(
    payload: Optional[SupplierCreate] = Body(default=None),
    name: Optional[str] = None,   # backward-compat (query)
    db: Session = Depends(get_db)
):
    org = (payload.organization_name if payload else None) or name
    if not org:
        raise HTTPException(status_code=400, detail="organization_name is required")
    existing = db.query(models.Supplier).filter(models.Supplier.organization_name == org).first()
    if existing:
        return existing
    obj = models.Supplier(organization_name=org)
    db.add(obj)
    db.commit()
    db.refresh(obj)
    return obj

@router.get("/{supplier_id}/connections", response_model=List[ConnectionOut])
def list_connections(supplier_id: int, db: Session = Depends(get_db)):
    rows = db.query(models.SupplierConnection).filter(models.SupplierConnection.supplier_id == supplier_id)\
        .order_by(models.SupplierConnection.id).all()
    return rows

@router.post("/{supplier_id}/connections", response_model=ConnectionOut)
def add_connection(
    supplier_id: int,
    payload: ConnectionCreate,
    db: Session = Depends(get_db)
):
    sup = db.query(models.Supplier).get(supplier_id)
    if not sup:
        raise HTTPException(status_code=404, detail="Supplier not found")
    obj = models.SupplierConnection(
        supplier_id=supplier_id,
        connection_name=payload.connection_name,
        username=payload.username,
        per_delivered=payload.per_delivered,
    )
    db.add(obj); db.commit(); db.refresh(obj)
    return obj
PY

# ---------- main.py: ensure we include router + run migrate() on startup ----------
# Add (or ensure) CORS and startup hook.
if ! grep -q "from app.routers import suppliers" "$API_DIR/main.py" 2>/dev/null; then
  # generate a sane main.py if missing or minimal otherwise
  cat > "$API_DIR/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate
from app.routers import suppliers

app = FastAPI(title="SMS Procurement Manager")

origins = ["http://localhost:5183", "http://127.0.0.1:5183", "*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
def on_startup():
    migrate()

app.include_router(suppliers.router)

@app.get("/")
def root():
    return {"message": "Routers and Auth enabled", "version": "0.9.0"}
PY
else
  # inject include_router and startup migrate, idempotently
  python3 - <<'PY'
from pathlib import Path
p = Path.home()/ "sms-procurement-manager/api/app/main.py"
s = p.read_text()
if "from app.migrations import migrate" not in s:
    s = s.replace("from fastapi import FastAPI", "from fastapi import FastAPI\nfrom app.migrations import migrate")
if "@app.on_event(\"startup\")" not in s and "def on_startup()" not in s:
    s = s.replace("app = FastAPI", 'app = FastAPI\n\n@app.on_event("startup")\ndef on_startup():\n    migrate()\n')
if "from app.routers import suppliers" not in s:
    s += "\nfrom app.routers import suppliers\napp.include_router(suppliers.router)\n"
p.write_text(s)
print("✅ Patched main.py")
PY
fi

# ---------- Web UI: hook Create Supplier button + Add connection form ----------
# Ensure minimal index structure exists
if [ ! -f "$WEB_DIR/index.html" ]; then
  mkdir -p "$WEB_DIR"
  cat > "$WEB_DIR/index.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>SMS Procurement</title>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <link rel="stylesheet" href="main.css" />
</head>
<body>
  <div id="app"></div>
  <script src="main.js"></script>
</body>
</html>
HTML
fi

# JS: authFetch + simple Suppliers screen with working Create + Add Connection (per_delivered on connection)
cat > "$WEB_DIR/main.js" <<'JS'
const API_BASE = localStorage.getItem('API_BASE') || (location.origin.replace(':5183', ':8010'));
let token = localStorage.getItem('jwt') || '';

async function authFetch(url, opts={}) {
  opts.headers = Object.assign({
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json'
  }, opts.headers||{});
  const res = await fetch(API_BASE + url, opts);
  if (!res.ok) {
    const txt = await res.text().catch(()=> '');
    throw new Error(`${res.status} ${res.statusText} :: ${txt}`);
  }
  const ct = res.headers.get('content-type') || '';
  return ct.includes('json') ? res.json() : res.text();
}

function byId(id){return document.getElementById(id)}

function loginView() {
  const dom = `
  <div class="card">
    <h2>Login</h2>
    <form id="loginForm">
      <label>Username</label><input id="u" value="admin" />
      <label>Password</label><input id="p" type="password" value="admin123" />
      <button type="submit">Sign in</button>
    </form>
    <div id="loginMsg" class="msg"></div>
  </div>`;
  document.getElementById('app').innerHTML = dom;
  byId('loginForm').addEventListener('submit', async (e)=>{
    e.preventDefault();
    try {
      const fd = new URLSearchParams();
      fd.set('username', byId('u').value);
      fd.set('password', byId('p').value);
      const res = await fetch(API_BASE + '/users/login', {method:'POST', body:fd});
      if(!res.ok){ throw new Error(await res.text()) }
      const data = await res.json();
      token = data.access_token; localStorage.setItem('jwt', token);
      suppliersView();
    } catch(err){
      byId('loginMsg').textContent = 'Login failed: ' + err.message;
    }
  });
}

async function fetchSuppliers(){
  return authFetch('/suppliers/');
}

async function createSupplier(name){
  return authFetch('/suppliers/', {method:'POST', body:JSON.stringify({organization_name: name})});
}

async function fetchConnections(supplierId){
  return authFetch(`/suppliers/${supplierId}/connections`);
}

async function addConnection(supplierId, payload){
  return authFetch(`/suppliers/${supplierId}/connections`, {method:'POST', body: JSON.stringify(payload)});
}

async function suppliersView(){
  document.getElementById('app').innerHTML = `
    <div class="toolbar">
      <button id="btnRefresh">Refresh</button>
      <span style="opacity:.6">API: ${API_BASE}</span>
    </div>
    <div class="card">
      <h2>Suppliers</h2>
      <div class="row">
        <input id="supplierNameInput" placeholder="Organization name" />
        <button id="createSupplierBtn">Create</button>
      </div>
      <div id="suppliersList" class="list"></div>
    </div>
  `;

  const render = async ()=>{
    const list = await fetchSuppliers();
    const container = byId('suppliersList');
    container.innerHTML = '';
    for(const s of list){
      const item = document.createElement('div');
      item.className = 'item';
      item.innerHTML = `
        <div class="head">
          <b>${s.organization_name}</b> <span class="muted">#${s.id}</span>
        </div>
        <div class="connForm">
          <input placeholder="Connection name" class="cn_${s.id}" />
          <input placeholder="Kannel SMSc username" class="un_${s.id}" />
          <label><input type="checkbox" class="pd_${s.id}" /> Per Delivered</label>
          <button class="addc_${s.id}">Add connection</button>
          <span class="msg m_${s.id}"></span>
        </div>
        <div class="conns c_${s.id}"></div>
      `;
      container.appendChild(item);

      // Load existing connections
      fetchConnections(s.id).then(cs=>{
        const cbox = item.querySelector(`.c_${s.id}`);
        cbox.innerHTML = cs.map(c=>`
          <div class="connrow">
            <span>${c.connection_name}</span>
            <span class="muted">user: ${c.username||'-'}</span>
            <span class="muted">${c.per_delivered ? 'Per Delivered' : 'Per Submitted'}</span>
          </div>
        `).join('') || '<div class="muted">No connections yet</div>';
      }).catch(e=>{
        item.querySelector(`.m_${s.id}`).textContent = 'Load connections error: ' + e.message;
      });

      // Add connection
      item.querySelector(`.addc_${s.id}`).addEventListener('click', async ()=>{
        const cn = item.querySelector(`.cn_${s.id}`).value.trim();
        const un = item.querySelector(`.un_${s.id}`).value.trim();
        const pd = item.querySelector(`.pd_${s.id}`).checked;
        const msg = item.querySelector(`.m_${s.id}`);
        msg.textContent = '';
        if(!cn){ msg.textContent = 'Connection name required'; return; }
        try{
          await addConnection(s.id, {connection_name: cn, username: un, per_delivered: pd});
          msg.textContent = 'Added ✓';
          setTimeout(render, 200);
        }catch(err){ msg.textContent = err.message; }
      });
    }
  };

  byId('btnRefresh').onclick = render;
  byId('createSupplierBtn').onclick = async ()=>{
    const name = byId('supplierNameInput').value.trim();
    const btn = byId('createSupplierBtn');
    if(!name) return;
    btn.disabled = true;
    try {
      await createSupplier(name);
      byId('supplierNameInput').value = '';
      await render();
    } catch(err) {
      alert('Create failed: ' + err.message);
    } finally {
      btn.disabled = false;
    }
  };

  await render();
}

(function boot(){
  token ? suppliersView() : loginView();
})();
JS

# Simple CSS (optional, improves visual)
cat > "$WEB_DIR/main.css" <<'CSS'
body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#0b0f14;color:#e6edf3}
.card{background:#101722;border:1px solid #253042;border-radius:14px;padding:16px;margin:16px}
.toolbar{display:flex;gap:12px;align-items:center;background:#0f1621;padding:10px 16px;border-bottom:1px solid #1d2734}
.row{display:flex;gap:8px;margin:8px 0}
input{padding:8px;border-radius:10px;border:1px solid #2a3a4d;background:#0c1117;color:#e6edf3}
button{padding:8px 12px;border-radius:10px;border:1px solid #2a3a4d;background:#192231;color:#e6edf3;cursor:pointer}
button:hover{background:#1f2a3d}
.list .item{border-top:1px solid #1d2734;padding:10px 0}
.muted{opacity:.6}
.connrow{display:flex;gap:14px;align-items:center;padding:6px 0;border-left:3px solid #2a3a4d;margin:6px 0;padding-left:8px}
.msg{margin-left:8px;opacity:.9}
CSS

echo "🧱 Rebuild api & web…"
cd "$ROOT/docker"
docker compose build api web
docker compose up -d api web

echo "⏳ Waiting 3s and probing…"
sleep 3
echo "🌐 API /suppliers/ (should be 200):"
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8010/suppliers/
echo "🔧 Done. Refresh the Web UI and test creating a Supplier, then add a Connection (with Per Delivered)."
