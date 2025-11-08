#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
WEB="$ROOT/web/public"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}🛠 Repairing API + UI end-to-end...${N}"
mkdir -p "$CORE" "$ROUT" "$WEB"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUT/__init__.py"

############################################
# 0) Compose (conflict-free, no container_name)
############################################
cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: smsdb
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [stack]

  api:
    build:
      context: .
      dockerfile: api.Dockerfile
    environment:
      DB_URL: postgresql+psycopg://postgres:postgres@postgres:5432/smsdb
    depends_on: [postgres]
    ports: ["8010:8000"]
    networks: [stack]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    depends_on: [api]
    ports: ["5183:80"]
    networks: [stack]

volumes:
  pgdata:

networks:
  stack:
YAML

############################################
# 1) API Dockerfile
############################################
cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" \
    pydantic python-multipart python-jose[cryptography] \
    "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1"
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

############################################
# 2) Core: DB + Auth
############################################
cat > "$CORE/database.py" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

DB_URL = os.getenv("DB_URL", "postgresql+psycopg://postgres:postgres@postgres:5432/smsdb")
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, future=True)
Base = declarative_base()
PY

cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional
from fastapi import Depends, HTTPException, status, APIRouter
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.hash import bcrypt
from sqlalchemy import text
from app.core.database import engine, SessionLocal

SECRET = os.getenv("JWT_SECRET", "devsecret-change-me")
ALGO = "HS256"
EXPIRE = 60*60*8

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")

def seed_admin():
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR NOT NULL UNIQUE,
          password_hash VARCHAR NOT NULL,
          role VARCHAR DEFAULT 'user'
        );
        """))
        r = c.execute(text("SELECT 1 FROM users WHERE username='admin';")).fetchone()
        if not r:
            c.execute(text("INSERT INTO users (username,password_hash,role) VALUES (:u,:p,'admin')"),
                dict(u='admin', p=bcrypt.hash('admin123')))

def authenticate(u: str, p: str) -> Optional[dict]:
    with engine.begin() as c:
        row = c.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), dict(u=u)).fetchone()
        if row and bcrypt.verify(p, row.password_hash):
            return dict(id=row.id, username=row.username, role=row.role)
    return None

def create_token(user: dict) -> str:
    payload = {"sub": user["username"], "uid": user["id"], "role": user["role"], "exp": int(time.time()) + EXPIRE}
    return jwt.encode(payload, SECRET, algorithm=ALGO)

def get_current_user(token: str = Depends(oauth2_scheme)) -> dict:
    try:
        payload = jwt.decode(token, SECRET, algorithms=[ALGO])
        return {"id": payload["uid"], "username": payload["sub"], "role": payload.get("role","user")}
    except JWTError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
PY

############################################
# 3) Migrations (minimal and safe)
############################################
cat > "$API/migrations_domain.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

def migrate_domain():
    stmts = [
        # enums storage
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # countries (+ extra MCCs)
        """
        CREATE TABLE IF NOT EXISTS countries(
          id SERIAL PRIMARY KEY,
          name VARCHAR NOT NULL UNIQUE,
          mcc VARCHAR(4),
          mcc2 VARCHAR(4),
          mcc3 VARCHAR(4)
        );
        """,
        # networks
        """
        CREATE TABLE IF NOT EXISTS networks(
          id SERIAL PRIMARY KEY,
          name VARCHAR NOT NULL,
          country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
          mnc VARCHAR(4),
          mccmnc VARCHAR(8)
        );
        """,
        # suppliers
        """
        CREATE TABLE IF NOT EXISTS suppliers(
          id SERIAL PRIMARY KEY,
          organization_name VARCHAR NOT NULL UNIQUE
        );
        """,
        # connections (per_delivered moved here)
        """
        CREATE TABLE IF NOT EXISTS supplier_connections(
          id SERIAL PRIMARY KEY,
          supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
          connection_name VARCHAR NOT NULL,
          username VARCHAR,
          kannel_smsc VARCHAR,
          per_delivered BOOLEAN DEFAULT FALSE,
          charge_model VARCHAR(64) DEFAULT 'Per Submitted'
        );
        """,
        # offers (flat, simple)
        """
        CREATE TABLE IF NOT EXISTS offers(
          id SERIAL PRIMARY KEY,
          supplier_name VARCHAR NOT NULL,
          connection_name VARCHAR NOT NULL,
          country_name VARCHAR,
          network_name VARCHAR,
          mccmnc VARCHAR,
          price NUMERIC NOT NULL,
          price_effective_date DATE,
          previous_price NUMERIC,
          route_type VARCHAR,
          known_hops VARCHAR,
          sender_id_supported VARCHAR,
          registration_required VARCHAR,
          eta_days INTEGER,
          charge_model VARCHAR,
          is_exclusive BOOLEAN DEFAULT FALSE,
          notes TEXT,
          updated_by VARCHAR,
          created_at TIMESTAMPTZ DEFAULT now(),
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """
    ]
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
PY

############################################
# 4) Routers
############################################
cat > "$ROUT/users.py" <<'PY'
from fastapi import APIRouter, Depends
from fastapi.security import OAuth2PasswordRequestForm
from app.core.auth import authenticate, create_token, get_current_user

router = APIRouter(prefix="/users", tags=["Users"])

@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends()):
    user = authenticate(form.username, form.password)
    if not user:
        return {"detail":"Unauthorized"}, 401
    return {"access_token": create_token(user), "token_type": "bearer"}

@router.get("/me")
def me(current = Depends(get_current_user)):
    return current
PY

cat > "$ROUT/conf.py" <<'PY'
from typing import Dict, List, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
import json
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/conf", tags=["Config"])

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct","SS7","SIM","Local Bypass"],
    "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
    "registration_required": ["Yes","No"]
}

def _ensure_table():
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """))

def _get_enums() -> Dict[str, Any]:
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums';")).fetchone()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES ('enums', :v)"),
                      dict(v=json.dumps(DEFAULT_ENUMS)))
            return DEFAULT_ENUMS
        val = row.value
        if isinstance(val, str):
            try: val = json.loads(val)
            except Exception: val = {}
        return {**DEFAULT_ENUMS, **(val or {})}

@router.get("/enums")
def read_enums(current = Depends(get_current_user)):
    return _get_enums()

@router.put("/enums")
def write_enums(payload: Dict[str, Any] = Body(...), current = Depends(get_current_user)):
    # merge incoming keys (partial update supported)
    cur = _get_enums()
    for k,v in payload.items():
        cur[k] = v
    with engine.begin() as c:
        c.execute(text("UPDATE config_kv SET value=:v, updated_at=now() WHERE key='enums'"),
                  dict(v=json.dumps(cur)))
    return cur
PY

cat > "$ROUT/countries.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/countries", tags=["Countries"])

class CountryIn(BaseModel):
    name: str
    mcc: Optional[str] = None
    mcc2: Optional[str] = None
    mcc3: Optional[str] = None

class CountryOut(CountryIn):
    id: int

@router.get("/", response_model=List[CountryOut])
def list_countries(current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,mcc,mcc2,mcc3 FROM countries ORDER BY name")).all()
    return [dict(id=r.id, name=r.name, mcc=r.mcc, mcc2=r.mcc2, mcc3=r.mcc3) for r in rows]

@router.post("/", response_model=CountryOut)
def create_country(body: CountryIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO countries(name,mcc,mcc2,mcc3)
            VALUES(:name,:mcc,:mcc2,:mcc3) RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}

@router.put("/{country_id}", response_model=CountryOut)
def update_country(country_id: int, body: CountryIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("""
            UPDATE countries SET name=:name, mcc=:mcc, mcc2=:mcc2, mcc3=:mcc3 WHERE id=:id
        """), dict(id=country_id, **body.model_dump()))
        r = c.execute(text("SELECT id,name,mcc,mcc2,mcc3 FROM countries WHERE id=:id"),
                      dict(id=country_id)).fetchone()
        if not r: raise HTTPException(404, "Not Found")
    return dict(id=r.id, name=r.name, mcc=r.mcc, mcc2=r.mcc2, mcc3=r.mcc3)

@router.delete("/{country_id}")
def delete_country(country_id: int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM countries WHERE id=:id"), dict(id=country_id))
    return {"ok": True}
PY

cat > "$ROUT/networks.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/networks", tags=["Networks"])

class NetworkIn(BaseModel):
    name: str
    country_id: Optional[int] = None
    mnc: Optional[str] = None
    mccmnc: Optional[str] = None

class NetworkOut(NetworkIn):
    id: int

@router.get("/", response_model=List[NetworkOut])
def list_networks(current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,country_id,mnc,mccmnc FROM networks ORDER BY name")).all()
    return [dict(id=r.id, name=r.name, country_id=r.country_id, mnc=r.mnc, mccmnc=r.mccmnc) for r in rows]

@router.post("/", response_model=NetworkOut)
def create_network(body: NetworkIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO networks(name,country_id,mnc,mccmnc)
            VALUES(:name,:country_id,:mnc,:mccmnc) RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}

@router.put("/{network_id}", response_model=NetworkOut)
def update_network(network_id:int, body:NetworkIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("""
            UPDATE networks SET name=:name,country_id=:country_id,mnc=:mnc,mccmnc=:mccmnc WHERE id=:id
        """), dict(id=network_id, **body.model_dump()))
        r = c.execute(text("SELECT id,name,country_id,mnc,mccmnc FROM networks WHERE id=:id"),
                      dict(id=network_id)).fetchone()
        if not r: raise HTTPException(404,"Not Found")
    return dict(id=r.id, name=r.name, country_id=r.country_id, mnc=r.mnc, mccmnc=r.mccmnc)

@router.delete("/{network_id}")
def delete_network(network_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM networks WHERE id=:id"), dict(id=network_id))
    return {"ok": True}
PY

cat > "$ROUT/suppliers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/suppliers", tags=["Suppliers"])

class SupplierIn(BaseModel):
    organization_name: str

class SupplierOut(SupplierIn):
    id: int

@router.get("/", response_model=List[SupplierOut])
def list_suppliers(current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,organization_name FROM suppliers ORDER BY organization_name")).all()
    return [dict(id=r.id, organization_name=r.organization_name) for r in rows]

@router.post("/", response_model=SupplierOut)
def create_supplier(body: SupplierIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO suppliers(organization_name) VALUES(:organization_name) RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}

@router.put("/{supplier_id}", response_model=SupplierOut)
def update_supplier(supplier_id:int, body:SupplierIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("UPDATE suppliers SET organization_name=:n WHERE id=:id"),
                  dict(id=supplier_id, n=body.organization_name))
        r = c.execute(text("SELECT id,organization_name FROM suppliers WHERE id=:id"),
                      dict(id=supplier_id)).fetchone()
        if not r: raise HTTPException(404,"Not Found")
    return dict(id=r.id, organization_name=r.organization_name)

@router.delete("/{supplier_id}")
def delete_supplier(supplier_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM suppliers WHERE id=:id"), dict(id=supplier_id))
    return {"ok": True}
PY

cat > "$ROUT/connections.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/suppliers/{supplier_id}/connections", tags=["Connections"])

class ConnIn(BaseModel):
    connection_name: str
    username: Optional[str] = None
    kannel_smsc: Optional[str] = None
    per_delivered: Optional[bool] = False
    charge_model: Optional[str] = "Per Submitted"

class ConnOut(ConnIn):
    id: int
    supplier_id: int

@router.get("/", response_model=List[ConnOut])
def list_conns(supplier_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE supplier_id=:sid ORDER BY id
        """), dict(sid=supplier_id)).all()
    return [dict(id=r.id, supplier_id=r.supplier_id, connection_name=r.connection_name, username=r.username,
                 kannel_smsc=r.kannel_smsc, per_delivered=r.per_delivered, charge_model=r.charge_model) for r in rows]

@router.post("/", response_model=ConnOut)
def create_conn(supplier_id:int, body:ConnIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO supplier_connections(supplier_id,connection_name,username,kannel_smsc,per_delivered,charge_model)
            VALUES(:sid,:n,:u,:k,:p,:cm) RETURNING id
        """), dict(sid=supplier_id, n=body.connection_name, u=body.username, k=body.kannel_smsc,
                   p=bool(body.per_delivered), cm=body.charge_model)).fetchone()
    return {**body.model_dump(), "id": r.id, "supplier_id": supplier_id}

@router.put("/{conn_id}", response_model=ConnOut)
def update_conn(supplier_id:int, conn_id:int, body:ConnIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("""
            UPDATE supplier_connections
            SET connection_name=:n, username=:u, kannel_smsc=:k, per_delivered=:p, charge_model=:cm
            WHERE id=:cid AND supplier_id=:sid
        """), dict(cid=conn_id, sid=supplier_id, n=body.connection_name, u=body.username,
                   k=body.kannel_smsc, p=bool(body.per_delivered), cm=body.charge_model))
        r = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE id=:cid AND supplier_id=:sid
        """), dict(cid=conn_id, sid=supplier_id)).fetchone()
        if not r: raise HTTPException(404,"Not Found")
    return dict(id=r.id, supplier_id=r.supplier_id, connection_name=r.connection_name, username=r.username,
                kannel_smsc=r.kannel_smsc, per_delivered=r.per_delivered, charge_model=r.charge_model)

@router.delete("/{conn_id}")
def delete_conn(supplier_id:int, conn_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM supplier_connections WHERE id=:cid AND supplier_id=:sid"),
                  dict(cid=conn_id, sid=supplier_id))
    return {"ok": True}
PY

cat > "$ROUT/offers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/offers", tags=["Offers"])

class OfferIn(BaseModel):
    supplier_name: str
    connection_name: str
    country_name: Optional[str] = None
    network_name: Optional[str] = None
    mccmnc: Optional[str] = None
    price: float
    price_effective_date: Optional[str] = None
    previous_price: Optional[float] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[str] = None
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    charge_model: Optional[str] = None
    is_exclusive: Optional[bool] = False
    notes: Optional[str] = None
    updated_by: Optional[str] = None

class OfferOut(OfferIn):
    id: int

@router.get("/")
def list_offers(limit:int=50, offset:int=0, current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("""
        SELECT id,supplier_name,connection_name,country_name,network_name,mccmnc,price,price_effective_date,
               previous_price,route_type,known_hops,sender_id_supported,registration_required,eta_days,
               charge_model,is_exclusive,notes,updated_by
        FROM offers ORDER BY id DESC LIMIT :l OFFSET :o
        """), dict(l=limit,o=offset)).all()
    data = [dict(id=r.id, supplier_name=r.supplier_name, connection_name=r.connection_name,
                 country_name=r.country_name, network_name=r.network_name, mccmnc=r.mccmnc,
                 price=float(r.price), price_effective_date=str(r.price_effective_date) if r.price_effective_date else None,
                 previous_price=float(r.previous_price) if r.previous_price is not None else None,
                 route_type=r.route_type, known_hops=r.known_hops, sender_id_supported=r.sender_id_supported,
                 registration_required=r.registration_required, eta_days=r.eta_days,
                 charge_model=r.charge_model, is_exclusive=r.is_exclusive, notes=r.notes, updated_by=r.updated_by)
            for r in rows]
    return {"rows": data, "total": len(data)}

@router.post("/", response_model=OfferOut)
def create_offer(body:OfferIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
          INSERT INTO offers(supplier_name,connection_name,country_name,network_name,mccmnc,price,
                             price_effective_date,previous_price,route_type,known_hops,sender_id_supported,
                             registration_required,eta_days,charge_model,is_exclusive,notes,updated_by)
          VALUES(:supplier_name,:connection_name,:country_name,:network_name,:mccmnc,:price,
                 :price_effective_date,:previous_price,:route_type,:known_hops,:sender_id_supported,
                 :registration_required,:eta_days,:charge_model,:is_exclusive,:notes,:updated_by)
          RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}
PY

cat > "$ROUT/parsers.py" <<'PY'
from fastapi import APIRouter, Depends
from app.core.auth import get_current_user
router = APIRouter(prefix="/parsers", tags=["Parsers"])

@router.get("/")
def list_parsers(current=Depends(get_current_user)):
    # Stub to satisfy UI
    return {"templates": [], "notes": "WYSIWYG to be implemented"}
PY

cat > "$ROUT/metrics.py" <<'PY'
from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/metrics", tags=["Metrics"])

@router.get("/trends")
def trends(d: str, current=Depends(get_current_user)):
    # Return top-10 networks by count of offers (dummy grouping on existing flat table)
    with engine.begin() as c:
        rows = c.execute(text("""
          SELECT COALESCE(network_name,'(Unknown)') AS name, COUNT(*) AS n
          FROM offers
          WHERE (price_effective_date = :d) OR (created_at::date = :d) OR (updated_at::date = :d)
          GROUP BY 1 ORDER BY 2 DESC LIMIT 10
        """), dict(d=d)).all()
    return {"date": d, "buckets": [{"label": r.name, "value": int(r.n)} for r in rows]}
PY

############################################
# 5) main.py (CORS for all origins + include routers)
############################################
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.auth import seed_admin
from app.migrations_domain import migrate_domain
from app.routers.users import router as users
from app.routers.conf import router as conf
from app.routers.countries import router as countries
from app.routers.networks import router as networks
from app.routers.suppliers import router as suppliers
from app.routers.connections import router as connections
from app.routers.offers import router as offers
from app.routers.parsers import router as parsers
from app.routers.metrics import router as metrics

app = FastAPI(title="SMS Procurement Manager", version="0.2")

# Permissive CORS (we use Bearer tokens, no cookies)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
def _startup():
    seed_admin()
    migrate_domain()

app.include_router(users)
app.include_router(conf)
app.include_router(countries)
app.include_router(networks)
app.include_router(suppliers)
app.include_router(connections)
app.include_router(offers)
app.include_router(parsers)
app.include_router(metrics)

@app.get("/")
def root():
    return {"ok": True}
PY

############################################
# 6) WEB: theme + baseline UI with per-category Save
############################################
cat > "$ROOT/web.Dockerfile" <<'DOCKER'
FROM nginx:stable-alpine
COPY web/public /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; && \
    find /usr/share/nginx/html -type f -exec chmod 644 {} \;
DOCKER

# theme.css
cat > "$WEB/theme.css" <<'CSS'
:root{
  --bg-0:#f7efe6; --bg-1:#fff7ef; --bg-2:#fde9d8;
  --text-0:#2b1e12; --text-1:#4b2e16; --border:#e4c9ad;
  --primary:#b45309; --accent:#d97706;
  --ok:#16a34a; --info:#2563eb; --warn:#f59e0b; --danger:#dc2626;
  --shadow: 0 6px 14px rgba(124, 90, 60, .12); --radius:12px;
}
*{box-sizing:border-box} html,body{margin:0;background:var(--bg-0);color:var(--text-0);font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial}
a{color:var(--accent)}
#app{padding:16px}
.header{position:sticky;top:0;z-index:20;background:linear-gradient(180deg,rgba(253,233,216,.92),rgba(247,239,230,.92));border-bottom:1px solid var(--border)}
.nav{display:flex;gap:10px;align-items:center;padding:10px 16px}
.nav .brand{font-weight:800;margin-right:auto}
.card{background:var(--bg-1);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);padding:14px;margin:12px 0}
input,select,textarea{background:#fff;color:var(--text-0);border:1px solid var(--border);border-radius:10px;padding:8px 10px}
.btn{border:none;border-radius:999px;color:#fff;background:var(--primary);padding:8px 12px;cursor:pointer;box-shadow:var(--shadow)}
.btn.green{background:var(--ok)} .btn.blue{background:var(--info)} .btn.yellow{background:var(--warn);color:#3b270e} .btn.red{background:var(--danger)}
.table{width:100%;border:1px solid var(--border);background:#fff;border-radius:12px;overflow:hidden}
.table th,.table td{padding:10px;border-bottom:1px solid var(--border);text-align:left}
.pill-list{list-style:none;margin:8px 0;padding:0}.pill-row{display:flex;gap:8px;align-items:center;margin:6px 0}
.pill{display:inline-block;padding:6px 10px;border-radius:999px;background:#fff;border:1px solid var(--border)}
CSS

# index.html
cat > "$WEB/index.html" <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
<link rel="stylesheet" href="theme.css"/>
</head><body>
<div class="header"><div class="nav">
  <div class="brand">SMS Procurement Manager</div>
  <button id="btnTrends" class="btn">Trends</button>
  <button id="btnOffers" class="btn blue">Offers</button>
  <button id="btnSuppliers" class="btn">Suppliers</button>
  <button id="btnCountries" class="btn">Countries</button>
  <button id="btnNetworks" class="btn">Networks</button>
  <button id="btnParsers" class="btn">Parsers</button>
  <button id="btnSettings" class="btn yellow">Settings</button>
  <div id="userbox" style="margin-left:auto"></div>
</div></div>
<div id="app"></div>
<script src="env.js"></script>
<script src="main.js"></script>
</body></html>
HTML

# env.js
cat > "$WEB/env.js" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS

# main.js (baseline, per-category Save + Save All + Enter-to-login)
cat > "$WEB/main.js" <<'JS'
const $ = s=>document.querySelector(s);
const el = (t, attrs={}, ...kids)=>{ const x=document.createElement(t); for(const k in attrs){ if(attrs[k]!==null) x.setAttribute(k, attrs[k]); } kids.flat().forEach(k=>x.append(k.nodeType? k : document.createTextNode(k))); return x; };

let TOKEN = localStorage.getItem('TOKEN') || '';

async function authFetch(url, opt={}){
  opt.headers = Object.assign({'Content-Type':'application/json'}, opt.headers||{});
  if (TOKEN) opt.headers['Authorization'] = 'Bearer '+TOKEN;
  const resp = await fetch(url, opt);
  if (!resp.ok){
    const text = await resp.text().catch(()=> '');
    throw new Error(`${resp.status} ${text || resp.statusText}`);
  }
  const ct = resp.headers.get('content-type') || '';
  return ct.includes('application/json') ? resp.json() : resp.text();
}

function loginView(){
  const page = el('div',{class:'page'},
    el('div',{class:'card'},
      el('h2',{},'Login'),
      el('label',{},'API Base'), el('input',{id:'api',value:window.API_BASE,style:"width:100%"}),
      el('label',{},'Username'), el('input',{id:'u',value:'admin',style:"width:100%"}),
      el('label',{},'Password'), el('input',{id:'p',type:'password',value:'admin123',style:"width:100%"}),
      el('div',{style:"margin-top:8px;display:flex;gap:8px"},
        el('button',{class:'btn blue', id:'loginBtn'},'Login')
      )
    )
  );
  $('#app').innerHTML = ''; $('#app').append(page);
  $('#loginBtn').onclick = doLogin;
  $('#p').addEventListener('keydown', (e)=>{ if(e.key==='Enter') doLogin(); });
}

async function doLogin(){
  window.API_BASE = $('#api').value || window.API_BASE;
  localStorage.setItem('API_BASE', window.API_BASE);
  const form = new URLSearchParams();
  form.set('username', $('#u').value);
  form.set('password', $('#p').value);
  try{
    const data = await fetch(window.API_BASE+'/users/login',{method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:form});
    if(!data.ok){ alert('Login failed'); return; }
    const tok = await data.json();
    TOKEN = tok.access_token; localStorage.setItem('TOKEN', TOKEN);
    render(); // go home
  }catch(e){ alert(e.message); }
}

function ensureNav(){
  $('#btnTrends').onclick = viewTrends;
  $('#btnOffers').onclick = viewOffers;
  $('#btnSuppliers').onclick = viewSuppliers;
  $('#btnCountries').onclick = viewCountries;
  $('#btnNetworks').onclick = viewNetworks;
  $('#btnParsers').onclick = viewParsers;
  $('#btnSettings').onclick = viewSettings;
  $('#userbox').innerHTML = TOKEN ? 'User: admin ' : '';
  if (TOKEN){
    const lo = el('button',{class:'btn red',style:'margin-left:8px'},'Logout');
    lo.onclick = ()=>{ TOKEN=''; localStorage.removeItem('TOKEN'); render(); };
    $('#userbox').append(lo);
  }
}

async function viewTrends(){
  try{
    const today = new Date().toISOString().slice(0,10);
    const res = await authFetch(window.API_BASE+'/metrics/trends?d='+today);
    const card = el('div',{class:'card'}, el('h2',{},'Market trends (top networks)'),
      el('pre',{}, JSON.stringify(res.buckets, null, 2)));
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Trends error: '+e.message); }
}

async function listSimple(path){
  return authFetch(window.API_BASE+path);
}

async function viewOffers(){
  try{
    const data = await authFetch(window.API_BASE+'/offers/?limit=50&offset=0');
    const rows = data.rows || [];
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Supplier'), el('th',{},'Connection'), el('th',{},'Price'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.supplier_name), el('td',{}, r.connection_name), el('td',{}, String(r.price)) )))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Offers'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Offers error: '+e.message); }
}

async function viewSuppliers(){
  try{
    const rows = await listSimple('/suppliers/');
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Organization'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.organization_name))))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Suppliers'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Suppliers error: '+e.message); }
}

async function viewCountries(){
  try{
    const rows = await listSimple('/countries/');
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Name'), el('th',{},'MCC'), el('th',{},'MCC2'), el('th',{},'MCC3'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.name), el('td',{}, r.mcc||''), el('td',{}, r.mcc2||''), el('td',{}, r.mcc3||''))))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Countries'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Countries error: '+e.message); }
}

async function viewNetworks(){
  try{
    const rows = await listSimple('/networks/');
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Name'), el('th',{},'Country ID'), el('th',{},'MNC'), el('th',{},'MCC-MNC'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.name), el('td',{}, r.country_id||''), el('td',{}, r.mnc||''), el('td',{}, r.mccmnc||''))))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Networks'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Networks error: '+e.message); }
}

async function viewParsers(){
  try{
    const res = await listSimple('/parsers/');
    const card = el('div',{class:'card'}, el('h2',{},'Parsers (WYSIWYG planned)'), el('pre',{}, JSON.stringify(res,null,2)));
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Parsers error: '+e.message); }
}

async function viewSettings(){
  try{
    const enums = await authFetch(window.API_BASE+'/conf/enums');
    const state = JSON.parse(JSON.stringify(enums));
    const dirty = { route_type:false, known_hops:false, registration_required:false, any:false };

    function listBlock(key, label){
      const addInput = el('input',{placeholder:'Add new value', style:"width:200px"});
      const addBtn = el('button',{class:'btn green'},'Add');
      const saveBtn = el('button',{class:'btn blue'},`Save ${label}`);
      const ul = el('ul',{class:'pill-list'});

      function render(){
        ul.innerHTML = '';
        (state[key]||[]).forEach((v,i)=>{
          ul.append(el('li',{class:'pill-row'},
            el('span',{class:'pill'}, v),
            el('button',{class:'btn yellow'},'Edit'),
            el('button',{class:'btn red'},'Delete')
          ));
          ul.lastChild.children[1].onclick = ()=>{
            const nv = prompt('Edit value', v);
            if(nv && nv.trim() && nv!==v){ state[key][i]=nv.trim(); dirty[key]=dirty.any=true; render(); }
          };
          ul.lastChild.children[2].onclick = ()=>{
            state[key].splice(i,1); dirty[key]=dirty.any=true; render();
          };
        });
      }
      addBtn.onclick = ()=>{
        const nv = addInput.value.trim();
        if(nv){ state[key] = state[key]||[]; state[key].push(nv); addInput.value=''; dirty[key]=dirty.any=true; render(); }
      };
      saveBtn.onclick = async ()=>{
        try{
          const payload = {}; payload[key] = state[key];
          await authFetch(window.API_BASE+'/conf/enums', {method:'PUT', body: JSON.stringify(payload)});
          dirty[key]=false;
          alert(`${label} saved`);
        }catch(e){ alert(`Save ${label} failed: `+e.message); }
      };
      render();
      return el('div',{class:'card'},
        el('h3',{}, label),
        ul,
        el('div',{style:"display:flex;gap:8px"}, addInput, addBtn, saveBtn)
      );
    }

    const big = el('div',{class:'card'}, el('h2',{},'Drop Down Menus'));
    big.append(listBlock('route_type','Route type'));
    big.append(listBlock('known_hops','Known hops'));
    big.append(listBlock('registration_required','Registration required'));

    const saveAll = el('button',{class:'btn blue'},'Save All');
    saveAll.onclick = async ()=>{
      try{
        await authFetch(window.API_BASE+'/conf/enums', {method:'PUT', body: JSON.stringify(state)});
        alert('All dropdowns saved');
      }catch(e){ alert('Save All failed: '+e.message); }
    };

    const wrap = el('div',{class:'page'}, big, el('div',{}, saveAll));
    $('#app').innerHTML = ''; $('#app').append(wrap);
  }catch(e){ alert('Settings error: '+e.message); }
}

function render(){
  ensureNav();
  if (!TOKEN) return loginView();
  viewTrends();
}
document.addEventListener('DOMContentLoaded', render);
JS

############################################
# 7) Build & Up
############################################
echo -e "${Y}🧹 Cleaning old stack...${N}"
docker compose -f "$COMPOSE" down --remove-orphans || true

echo -e "${Y}🐳 Building images...${N}"
docker compose -f "$COMPOSE" build

echo -e "${Y}🚀 Starting...${N}"
docker compose -f "$COMPOSE" up -d

echo -e "${Y}⏳ Waiting API...${N}"
sleep 5
IP=$(hostname -I | awk '{print $1}')
OPENAPI="http://${IP}:8010/openapi.json"
if curl -sf "$OPENAPI" >/tmp/openapi.json; then
  echo -e "${G}✔ API up. Listing paths:${N}"
  grep -oE '"/[^"]+"' /tmp/openapi.json | sed 's/"//g' | sed 's/\\//g' | sort -u | head -n 200
else
  echo -e "${R}✖ API not reachable yet. Check: docker logs $(docker ps --format '{{.Names}}' | grep api)${N}"
fi

echo -e "${G}✅ Done. Open UI: http://${IP}:5183  (Login: admin / admin123)${N}"
