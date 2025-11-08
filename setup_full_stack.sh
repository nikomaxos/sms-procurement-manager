#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api"
WEB_DIR="$ROOT/web"
DOCKER_DIR="$ROOT/docker"

mkdir -p "$API_DIR/app"/{core,models,routers} "$WEB_DIR"/{public,src}
mkdir -p "$DOCKER_DIR"

############################################
# API: core/config.py
############################################
cat > "$API_DIR/app/core/config.py" <<'PY'
import os

APP_NAME = "SMS Procurement Manager"
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")

DB_URL = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")

# CORS
CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "http://localhost:5183").split(",") if o.strip()]

# Auth
JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALGO = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "120"))
PY

############################################
# API: core/database.py
############################################
cat > "$API_DIR/app/core/database.py" <<'PY'
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base
from app.core.config import DB_URL

engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine, future=True)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
PY

############################################
# API: core/auth.py
############################################
cat > "$API_DIR/app/core/auth.py" <<'PY'
from datetime import datetime, timedelta, timezone
from typing import Optional
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy.orm import Session
from app.core.config import JWT_SECRET, JWT_ALGO, ACCESS_TOKEN_EXPIRE_MINUTES
from app.core.database import get_db
from app.models.models import User

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def create_access_token(subject: str, minutes: Optional[int] = None) -> str:
    exp = datetime.now(timezone.utc) + timedelta(minutes=minutes or ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {"sub": subject, "exp": exp}
    return jwt.encode(to_encode, JWT_SECRET, algorithm=JWT_ALGO)

def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)) -> User:
    credentials_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials", headers={"WWW-Authenticate": "Bearer"}
    )
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGO])
        username: str = payload.get("sub")  # type: ignore
        if username is None:
            raise credentials_exc
    except JWTError:
        raise credentials_exc
    user = db.query(User).filter(User.username == username).first()
    if not user:
        raise credentials_exc
    return user
PY

############################################
# API: models/models.py
############################################
cat > "$API_DIR/app/models/models.py" <<'PY'
from sqlalchemy import Column, Integer, String, Boolean, Text, DateTime, ForeignKey, Float, UniqueConstraint
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String(128), unique=True, nullable=False)
    password_hash = Column(String(300), nullable=False)
    role = Column(String(32), default="user")
    created_at = Column(DateTime(timezone=True), server_default=func.now())

class Supplier(Base):
    __tablename__ = "suppliers"
    id = Column(Integer, primary_key=True)
    organization_name = Column(String, nullable=False)
    per_delivered = Column(Boolean, nullable=False, server_default="false")
    connections = relationship("SupplierConnection", back_populates="supplier", cascade="all, delete-orphan")

class SupplierConnection(Base):
    __tablename__ = "supplier_connections"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id"))
    connection_name = Column(String)
    kannel_smsc = Column(String)
    username = Column(String)
    charge_model = Column(String, default="Per Submitted")
    supplier = relationship("Supplier", back_populates="connections")

class Country(Base):
    __tablename__ = "countries"
    id = Column(Integer, primary_key=True)
    name = Column(String)
    mcc = Column(String)

class Network(Base):
    __tablename__ = "networks"
    id = Column(Integer, primary_key=True)
    country_id = Column(Integer, ForeignKey("countries.id"))
    name = Column(String)
    mnc = Column(String)
    mccmnc = Column(String)
    __table_args__ = (UniqueConstraint('mccmnc', name='uq_network_mccmnc'),)

class ParsingTemplate(Base):
    __tablename__ = "parsing_templates"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id"))
    connection_id = Column(Integer, ForeignKey("supplier_connections.id"))
    name = Column(String, nullable=False)
    enabled = Column(Boolean, nullable=False, server_default="true")
    conditions = Column(Text)  # JSON as text
    mapping = Column(Text)     # JSON as text
    options = Column(Text)     # JSON as text

class ParsingEvent(Base):
    __tablename__ = "parsing_events"
    id = Column(Integer, primary_key=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    level = Column(String(16))
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    details = Column(Text)

class OfferCurrent(Base):
    __tablename__ = "offers_current"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id"))
    connection_id = Column(Integer, ForeignKey("supplier_connections.id"))
    network_id = Column(Integer, ForeignKey("networks.id"), nullable=True)
    price = Column(Float)
    currency = Column(String(8), server_default="EUR")
    effective_date = Column(DateTime(timezone=True))
    route_type = Column(String(64))
    known_hops = Column(String(32))
    sender_id_supported = Column(String(128))
    registration_required = Column(String(16))
    eta_days = Column(Integer)
    charge_model = Column(String(32))
    is_exclusive = Column(String(8))
    notes = Column(Text)
    updated_by = Column(String(128))
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

class OfferHistory(Base):
    __tablename__ = "offers_history"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    network_id = Column(Integer)
    price = Column(Float)
    currency = Column(String(8))
    effective_date = Column(DateTime(timezone=True))
    route_type = Column(String(64))
    known_hops = Column(String(32))
    sender_id_supported = Column(String(128))
    registration_required = Column(String(16))
    eta_days = Column(Integer)
    charge_model = Column(String(32))
    is_exclusive = Column(String(8))
    notes = Column(Text)
    updated_by = Column(String(128))
    updated_at = Column(DateTime(timezone=True), server_default=func.now())
PY

############################################
# API: routers/users.py
############################################
cat > "$API_DIR/app/routers/users.py" <<'PY'
from fastapi import APIRouter, Depends, Form, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.core.auth import create_access_token, verify_password
from app.models.models import User

router = APIRouter(tags=["Users"])

@router.post("/users/login")
def login(username: str = Form(...), password: str = Form(...), db: Session = Depends(get_db)):
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token(user.username)
    return {"access_token": token, "token_type": "bearer"}
PY

############################################
# API: routers/suppliers.py
############################################
cat > "$API_DIR/app/routers/suppliers.py" <<'PY'
from typing import List
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.core.auth import get_current_user
from app.models.models import Supplier, SupplierConnection

router = APIRouter(prefix="/suppliers", tags=["Suppliers"])

@router.get("/", dependencies=[Depends(get_current_user)])
def list_suppliers(db: Session = Depends(get_db)) -> List[dict]:
    rows = db.query(Supplier).order_by(Supplier.id.asc()).all()
    return [{"id": s.id, "organization_name": s.organization_name, "per_delivered": bool(s.per_delivered)} for s in rows]

@router.post("/", dependencies=[Depends(get_current_user)])
def create_supplier(name: str = Query(...), per_delivered: bool = Query(False), db: Session = Depends(get_db)) -> dict:
    s = Supplier(organization_name=name, per_delivered=per_delivered)
    db.add(s); db.commit(); db.refresh(s)
    return {"id": s.id, "organization_name": s.organization_name, "per_delivered": bool(s.per_delivered)}

@router.post("/{supplier_id}/connections", dependencies=[Depends(get_current_user)])
def add_connection(supplier_id: int, name: str = Query(...), smsc: str = Query(...), username: str = Query(...),
                   charge_model: str = Query("Per Submitted"), db: Session = Depends(get_db)):
    s = db.query(Supplier).get(supplier_id)
    if not s:
        raise HTTPException(status_code=404, detail="Supplier not found")
    c = SupplierConnection(supplier_id=supplier_id, connection_name=name, kannel_smsc=smsc, username=username, charge_model=charge_model)
    db.add(c); db.commit(); db.refresh(c)
    return {"id": c.id, "supplier_id": c.supplier_id, "connection_name": c.connection_name, "kannel_smsc": c.kannel_smsc, "username": c.username, "charge_model": c.charge_model}
PY

############################################
# API: routers/offers.py
############################################
cat > "$API_DIR/app/routers/offers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from sqlalchemy import and_
from app.core.database import get_db
from app.core.auth import get_current_user
from app.models.models import OfferCurrent

router = APIRouter(prefix="/offers", tags=["Offers"])

@router.get("/", dependencies=[Depends(get_current_user)])
def list_offers(
    db: Session = Depends(get_db),
    supplier_id: Optional[int] = Query(None),
    connection_id: Optional[int] = Query(None),
    route_type: Optional[str] = Query(None),
    limit: int = Query(200)
) -> List[dict]:
    q = db.query(OfferCurrent)
    conds = []
    if supplier_id: conds.append(OfferCurrent.supplier_id == supplier_id)
    if connection_id: conds.append(OfferCurrent.connection_id == connection_id)
    if route_type: conds.append(OfferCurrent.route_type == route_type)
    if conds: q = q.filter(and_(*conds))
    rows = q.order_by(OfferCurrent.updated_at.desc()).limit(limit).all()
    return [dict(
        id=r.id, supplier_id=r.supplier_id, connection_id=r.connection_id, network_id=r.network_id,
        price=r.price, currency=r.currency, effective_date=str(r.effective_date) if r.effective_date else None,
        route_type=r.route_type, known_hops=r.known_hops, sender_id_supported=r.sender_id_supported,
        registration_required=r.registration_required, eta_days=r.eta_days, charge_model=r.charge_model,
        is_exclusive=r.is_exclusive, notes=r.notes, updated_at=str(r.updated_at) if r.updated_at else None
    ) for r in rows]
PY

############################################
# API: routers/hot.py
############################################
cat > "$API_DIR/app/routers/hot.py" <<'PY'
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from sqlalchemy import func
from app.core.database import get_db
from app.core.auth import get_current_user
from app.models.models import OfferCurrent

router = APIRouter(prefix="/hot", tags=["What's Hot"])

@router.get("/", dependencies=[Depends(get_current_user)])
def whats_hot(db: Session = Depends(get_db), day: str = Query(None)):
    # day format: YYYY-MM-DD; default = today (UTC)
    if day:
        start = datetime.fromisoformat(day).replace(tzinfo=timezone.utc)
    else:
        start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start.replace(hour=23, minute=59, second=59, microsecond=999999)
    q = (
        db.query(OfferCurrent.network_id, OfferCurrent.route_type, func.count(OfferCurrent.id))
          .filter(OfferCurrent.updated_at >= start, OfferCurrent.updated_at <= end)
          .group_by(OfferCurrent.network_id, OfferCurrent.route_type)
          .order_by(func.count(OfferCurrent.id).desc())
    )
    return [{"network_id": n, "route_type": rt, "updates": cnt} for (n, rt, cnt) in q.all()]
PY

############################################
# API: routers/health.py
############################################
cat > "$API_DIR/app/routers/health.py" <<'PY'
from fastapi import APIRouter
router = APIRouter()

@router.get("/healthz")
def healthz():
    return {"ok": True}
PY

############################################
# API: main.py
############################################
cat > "$API_DIR/app/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.core.config import APP_NAME, APP_VERSION, CORS_ORIGINS
from app.core.database import Base, engine
from app.routers import users, suppliers, offers, hot, health

Base.metadata.create_all(bind=engine)

app = FastAPI(title=APP_NAME, version=APP_VERSION)

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS or ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(users.router)
app.include_router(suppliers.router)
app.include_router(offers.router)
app.include_router(hot.router)
app.include_router(health.router)

@app.get("/")
def root():
    return {"message":"SMS Procurement Manager API is running", "version": APP_VERSION}
PY

############################################
# API: Dockerfile
############################################
cat > "$API_DIR/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim

WORKDIR /app
COPY app /app/app

# system deps for psycopg2 & lxml speed
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev && rm -rf /var/lib/apt/lists/*

# pin auth deps to avoid bcrypt bugs
RUN pip install --no-cache-dir \
    fastapi==0.112.2 uvicorn[standard]==0.30.6 \
    "SQLAlchemy==2.0.32" "psycopg2-binary==2.9.9" \
    "passlib==1.7.4" "bcrypt==4.0.1" \
    "python-jose[cryptography]==3.3.0" \
    "python-multipart==0.0.9"

ENV PYTHONUNBUFFERED=1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCKER

############################################
# WEB: public + src (Tailwind CDN, modern UI)
############################################
cat > "$WEB_DIR/public/env.js" <<'JS'
window.__API_BASE__ = "http://localhost:8010";
JS

cat > "$WEB_DIR/public/style.css" <<'CSS'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap');
:root{ --bg:#0b1220; --card:#121a2b; --text:#e7ecf6; --muted:#9fb0d1; --accent:#61dafb; }
*{ box-sizing:border-box }
html,body{ margin:0; height:100%; }
body{ font-family:Inter,system-ui,Segoe UI,Roboto,Arial; background:var(--bg); color:var(--text); }
.container{ max-width:1100px; margin:32px auto; padding:0 16px; }
.card{ background:var(--card); border-radius:16px; padding:20px; box-shadow:0 10px 30px rgba(0,0,0,.3) }
input,select,button{ border-radius:12px; border:1px solid #223; padding:10px 12px; background:#0f172a; color:var(--text) }
button{ background:#1f2a44; cursor:pointer }
button:hover{ filter:brightness(1.1) }
.grid{ display:grid; gap:16px }
.grid-2{ grid-template-columns:1fr 1fr }
.kv{ display:flex; gap:10px; align-items:center; }
.badge{ padding:2px 8px; border-radius:999px; background:#223; color:var(--muted); font-size:12px; }
h1{ font-size:22px; margin:0 0 16px }
h2{ font-size:18px; margin:24px 0 8px }
.table{ width:100%; border-collapse:collapse }
.table th, .table td{ border-bottom:1px solid #1d2740; padding:10px 8px; text-align:left; font-size:14px }
.toolbar{ display:flex; gap:10px; margin-bottom:12px; flex-wrap:wrap }
CSS

cat > "$WEB_DIR/public/index.html" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <title>SMS Procurement Manager</title>
    <link rel="stylesheet" href="/style.css"/>
    <script src="/env.js"></script>
  </head>
  <body>
    <div class="container">
      <div class="card">
        <div id="app"></div>
      </div>
    </div>
    <script src="/main.js"></script>
  </body>
</html>
HTML

cat > "$WEB_DIR/src/main.ts" <<'TS'
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
TS

############################################
# WEB: simple build-less nginx serve
############################################
cat > "$WEB_DIR/public/main.js" <<'JS'
(()=>{const e=e=>document.querySelector(e);let t=localStorage.getItem("spm_token");const n=e("#app");function r(){n.innerHTML='\n    <h1>Sign in</h1>\n    <div class="grid">\n      <input id="u" placeholder="username" />\n      <input id="p" placeholder="password" type="password" />\n      <button id="login">Login</button>\n    </div>\n  ',e("#login").addEventListener("click",async()=>{const n=e("#u").value.trim(),r=e("#p").value.trim(),o=new URLSearchParams({username:n,password:r}),a=await fetch(`${window.__API_BASE__||"http://localhost:8010"}/users/login`,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:o.toString()});if(!a.ok)return void alert("Invalid credentials");const s=await a.json();t=s.access_token,localStorage.setItem("spm_token",t),o2()})}async function o(e){if(!t)throw new Error("no token");const n=await fetch(`${(window.__API_BASE__||"http://localhost:8010")+e}`,{headers:{Authorization:`Bearer ${t}`}});return 401===n.status&&(localStorage.removeItem("spm_token"),t=null,r(),{items:[]}),n.json()}function o2(){n.innerHTML=`\n    <div class="toolbar">\n      <button id="nav_hot">What's Hot</button>\n      <button id="nav_offers">Suppliers Offers</button>\n      <span class="badge">API: ${(window.__API_BASE__||"http://localhost:8010")}</span>\n      <span style="flex:1"></span>\n      <button id="logout">Logout</button>\n    </div>\n    <div id="view"></div>\n  `,e("#logout").addEventListener("click",()=>{localStorage.removeItem("spm_token"),t=null,r()}),e("#nav_hot").addEventListener("click",a),e("#nav_offers").addEventListener("click",s),a()}async function a(){const t=e("#view");t.innerHTML="<h1>What's Hot (today)</h1><div class=\"grid\"></div>";const n=await o("/hot/"),r=t.querySelector(".grid");Array.isArray(n)&&n.length?r.innerHTML=n.map((e=>`\n    <div class="card">\n      <div class="kv"><strong>Network ID:</strong> <span>${null!=e.network_id?e.network_id:"-"}</span></div>\n      <div class="kv"><strong>Route Type:</strong> <span>${e.route_type||"-"}</span></div>\n      <div class="kv"><strong>Updates:</strong> <span>${e.updates}</span></div>\n    </div>\n  `)).join(""):r.innerHTML="<p>No updates today.</p>"}async function s(){const t=e("#view");t.innerHTML='\n    <h1>Suppliers Offers</h1>\n    <div class="toolbar">\n      <select id="route"><option value="">All routes</option><option>Direct</option><option>SS7</option><option>SIM</option><option>Local Bypass</option></select>\n      <button id="reload">Reload</button>\n    </div>\n    <table class="table"><thead>\n      <tr><th>ID</th><th>Supplier</th><th>Conn</th><th>Network</th><th>Price</th><th>Curr</th><th>Route</th><th>Updated</th></tr>\n    </thead><tbody id="rows"></tbody></table>\n  ';const n=async()=>{const n=e("#route").value,r=n?`?route_type=${encodeURIComponent(n)}`:"",a=await o(`/offers/${r}`),s=e("#rows");s.innerHTML=(a||[]).map((e=>`\n      <tr>\n        <td>${e.id}</td>\n        <td>${e.supplier_id}</td>\n        <td>${e.connection_id}</td>\n        <td>${null!=e.network_id?e.network_id:"-"}</td>\n        <td>${null!=e.price?e.price:"-"}</td>\n        <td>${e.currency||"-"}</td>\n        <td>${e.route_type||"-"}</td>\n        <td>${e.updated_at||"-"}</td>\n      </tr>\n    `)).join("")};e("#reload").addEventListener("click",n),n()}t?o2():r()})();
JS

cat > "$WEB_DIR/web.Dockerfile" <<'DOCKER'
FROM nginx:alpine
COPY public /usr/share/nginx/html
EXPOSE 80
DOCKER

############################################
# Compose override (api + web + worker command/CORS)
############################################
cat > "$DOCKER_DIR/docker-compose.override.yml" <<'YML'
services:
  api:
    build:
      context: ../api
      dockerfile: api.Dockerfile
    environment:
      DB_URL: ${DB_URL:-postgresql://postgres:postgres@postgres:5432/smsdb}
      JWT_SECRET: ${JWT_SECRET:-changeme}
      CORS_ORIGINS: ${CORS_ORIGINS:-http://localhost:5183}
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

############################################
# Build & start api+web
############################################
cd "$DOCKER_DIR"
docker compose build api web
docker compose up -d api web

# Create admin user if missing (admin/admin123)
docker exec -i docker-api-1 python3 - <<'PY' || true
from app.core.database import SessionLocal, Base, engine
from app.core.auth import get_password_hash
from app.models.models import User
Base.metadata.create_all(bind=engine)
db = SessionLocal()
u = db.query(User).filter_by(username="admin").first()
if not u:
    u = User(username="admin", password_hash=get_password_hash("admin123"), role="admin")
    db.add(u); db.commit()
print("Admin OK")
db.close()
PY

echo "🔎 Testing API..."
curl -sS http://localhost:8010/ | sed -e 's/.*/  &/'
echo
echo "🔎 OpenAPI has /users/login ?"
curl -sS http://localhost:8010/openapi.json | grep -A2 '"/users/login"' || echo " (not found)"
echo
echo "✅ Done. Open http://localhost:5183"
