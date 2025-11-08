#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
WEB="$ROOT/web/public"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}🛠  Fixing API endpoints (/conf/enums, /offers, /parsers, /suppliers, /countries, /networks, /lookups) and stabilizing stack...${N}"
mkdir -p "$CORE" "$ROUT" "$WEB"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUT/__init__.py"

############################################
# 0) Minimal favicon to stop 404
############################################
if [[ ! -f "$WEB/favicon.ico" ]]; then
  # a 1x1 transparent favicon
  printf '\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x04\x00(\
\x01\x00\x00\x16\x00\x00\x00' > "$WEB/favicon.ico" || true
fi

############################################
# 1) api.Dockerfile (idempotent)
############################################
if [[ ! -f "$ROOT/api.Dockerfile" ]]; then
  cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir \
      fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" \
      pydantic python-multipart python-jose[cryptography] \
      "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1"
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER
fi

############################################
# 2) Core: database + auth
############################################
cat > "$CORE/database.py" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

_raw = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")
if _raw.startswith("postgresql://"):
    _raw = _raw.replace("postgresql://", "postgresql+psycopg://", 1)

DB_URL = _raw
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, future=True)
Base = declarative_base()
PY

cat > "$CORE/auth.py" <<'PY'
import os, time
from datetime import datetime, timedelta, timezone
from typing import Optional
from jose import jwt
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key-change-me")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "720"))
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(p: str) -> str:
    return pwd_context.hash(p.encode("utf-8")[:72])

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return pwd_context.verify(plain, hashed)
    except Exception:
        time.sleep(0.05)
        return False

def create_access_token(sub: str, minutes: int = ACCESS_TOKEN_EXPIRE_MINUTES) -> str:
    exp = datetime.now(tz=timezone.utc) + timedelta(minutes=minutes)
    return jwt.encode({"sub": sub, "exp": exp}, SECRET_KEY, algorithm=ALGORITHM)
PY

############################################
# 3) Users migration + seed
############################################
cat > "$API/migrations_users.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import hash_password

def ensure_users():
    stmts = [
        """
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR NOT NULL UNIQUE,
          password_hash VARCHAR NOT NULL,
          role VARCHAR(32) DEFAULT 'admin'
        );
        """,
        """
        INSERT INTO users (username, password_hash, role)
        SELECT 'admin', :ph, 'admin'
        WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='admin');
        """
    ]
    ph = hash_password("admin123")
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s), {"ph": ph})
PY

############################################
# 4) Domain migrations (safe, no DO $$)
############################################
cat > "$API/migrations_domain.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

def ensure_domain():
    stmts = [
        # suppliers
        """
        CREATE TABLE IF NOT EXISTS suppliers(
          id SERIAL PRIMARY KEY,
          organization_name VARCHAR NOT NULL UNIQUE
        );
        """,
        # supplier_connections
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
        # countries with extra MCCs
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
        # offers (flat schema matching UI fields)
        """
        CREATE TABLE IF NOT EXISTS offers(
          id SERIAL PRIMARY KEY,
          supplier_name TEXT NOT NULL,
          connection_name TEXT NOT NULL,
          country_name TEXT,
          network_name TEXT,
          mccmnc TEXT,
          price NUMERIC NOT NULL,
          price_effective_date DATE,
          previous_price NUMERIC,
          route_type TEXT,
          known_hops TEXT,
          sender_id_supported TEXT,
          registration_required TEXT,
          eta_days INTEGER,
          charge_model TEXT,
          is_exclusive BOOLEAN DEFAULT FALSE,
          notes TEXT,
          updated_by TEXT,
          created_at TIMESTAMPTZ DEFAULT now(),
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # config key-value (jsonb) for enums
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # parsers store
        """
        CREATE TABLE IF NOT EXISTS parsers(
          id SERIAL PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          template TEXT,
          enabled BOOLEAN DEFAULT TRUE,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """
    ]
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
PY

############################################
# 5) Routers
############################################
# users
cat > "$ROUT/users.py" <<'PY'
from fastapi import APIRouter, HTTPException, Depends
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import verify_password, create_access_token

router = APIRouter()

@router.post("/login")
def login(form_data: OAuth2PasswordRequestForm = Depends()):
    with engine.begin() as c:
        row = c.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"),
                        {"u": form_data.username}).fetchone()
    if not row or not verify_password(form_data.password, row.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token(sub=row.username)
    return {"access_token": token, "token_type": "bearer", "username": row.username, "role": row.role}
PY

# conf (enums)
cat > "$ROUT/conf.py" <<'PY'
from typing import Dict, List, Any
from fastapi import APIRouter, HTTPException, Body
from sqlalchemy import text
import json
from app.core.database import engine

router = APIRouter()

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct","SS7","SIM","Local Bypass"],
    "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
    "registration_required": ["Yes","No"],
    "sender_id_supported": ["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
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

@router.get("/enums")
def get_enums():
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).scalar()
    if not row:
        return DEFAULT_ENUMS
    if isinstance(row, (bytes, bytearray)):
        row = row.decode("utf-8", "ignore")
    if isinstance(row, str):
        try:
            return json.loads(row)
        except Exception:
            return DEFAULT_ENUMS
    return row

@router.put("/enums")
def put_enums(payload: Dict[str, Any] = Body(...)):
    _ensure_table()
    # basic validation: all lists
    for k in ["route_type","known_hops","registration_required"]:
        if k in payload and not isinstance(payload[k], list):
            raise HTTPException(status_code=400, detail=f"{k} must be a list")
    with engine.begin() as c:
        c.execute(text("""
          INSERT INTO config_kv(key,value,updated_at)
          VALUES('enums', :v::jsonb, now())
          ON CONFLICT (key) DO UPDATE SET value=:v::jsonb, updated_at=now()
        """), {"v": json.dumps(payload)})
    return {"ok": True}
PY

# suppliers + inline connections (accept id or name)
cat > "$ROUT/suppliers.py" <<'PY'
from fastapi import APIRouter, HTTPException, Path, Body
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/")
def list_suppliers():
    with engine.begin() as c:
        rows = c.execute(text("SELECT id, organization_name FROM suppliers ORDER BY organization_name")).mappings().all()
    return rows

@router.post("/")
def create_supplier(data: dict = Body(...)):
    name = (data.get("organization_name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="organization_name required")
    with engine.begin() as c:
        row = c.execute(text("""
            INSERT INTO suppliers(organization_name)
            VALUES(:n) ON CONFLICT (organization_name) DO UPDATE SET organization_name=EXCLUDED.organization_name
            RETURNING id, organization_name
        """), {"n": name}).mappings().first()
    return row

def _supplier_id(s: str) -> int:
    if s.isdigit():
        return int(s)
    with engine.begin() as c:
        r = c.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": s}).scalar()
    if not r:
        raise HTTPException(status_code=404, detail="Supplier not found")
    return int(r)

@router.get("/{supplier_id_or_name}/connections/")
def list_connections(supplier_id_or_name: str = Path(...)):
    sid = _supplier_id(supplier_id_or_name)
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE supplier_id=:sid ORDER BY connection_name
        """), {"sid": sid}).mappings().all()
    return rows

@router.post("/{supplier_id_or_name}/connections/")
def create_connection(supplier_id_or_name: str, data: dict = Body(...)):
    sid = _supplier_id(supplier_id_or_name)
    name = (data.get("connection_name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="connection_name required")
    with engine.begin() as c:
        row = c.execute(text("""
            INSERT INTO supplier_connections(supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model)
            VALUES(:sid,:n,:u,:k,:p,:cm)
            RETURNING id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
        """), {
            "sid": sid,
            "n": name,
            "u": data.get("username"),
            "k": data.get("kannel_smsc"),
            "p": bool(data.get("per_delivered", False)),
            "cm": data.get("charge_model") or "Per Submitted",
        }).mappings().first()
    return row

@router.put("/{supplier_id_or_name}/connections/{conn_id}")
def update_connection(supplier_id_or_name: str, conn_id: int, data: dict = Body(...)):
    sid = _supplier_id(supplier_id_or_name)
    with engine.begin() as c:
        row = c.execute(text("""
            UPDATE supplier_connections
            SET connection_name=COALESCE(:n, connection_name),
                username=COALESCE(:u, username),
                kannel_smsc=COALESCE(:k, kannel_smsc),
                per_delivered=COALESCE(:p, per_delivered),
                charge_model=COALESCE(:cm, charge_model)
            WHERE id=:id AND supplier_id=:sid
            RETURNING id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
        """), {
            "sid": sid, "id": conn_id,
            "n": data.get("connection_name"),
            "u": data.get("username"),
            "k": data.get("kannel_smsc"),
            "p": data.get("per_delivered"),
            "cm": data.get("charge_model"),
        }).mappings().first()
    if not row:
        raise HTTPException(status_code=404, detail="Connection not found")
    return row

@router.delete("/{supplier_id_or_name}/connections/{conn_id}")
def delete_connection(supplier_id_or_name: str, conn_id: int):
    sid = _supplier_id(supplier_id_or_name)
    with engine.begin() as c:
        res = c.execute(text("DELETE FROM supplier_connections WHERE id=:id AND supplier_id=:sid"), {"id": conn_id, "sid": sid})
    return {"deleted": res.rowcount}
PY

# countries (accept id or name for update)
cat > "$ROUT/countries.py" <<'PY'
from fastapi import APIRouter, HTTPException, Body, Path
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/")
def list_countries():
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, name, mcc, mcc2, mcc3
            FROM countries ORDER BY name
        """)).mappings().all()
    return rows

@router.post("/")
def create_country(d: dict = Body(...)):
    name = (d.get("name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="name required")
    with engine.begin() as c:
        row = c.execute(text("""
            INSERT INTO countries(name, mcc, mcc2, mcc3)
            VALUES(:n,:m1,:m2,:m3)
            ON CONFLICT (name) DO UPDATE SET mcc=EXCLUDED.mcc, mcc2=EXCLUDED.mcc2, mcc3=EXCLUDED.mcc3
            RETURNING id, name, mcc, mcc2, mcc3
        """), {"n": name, "m1": d.get("mcc"), "m2": d.get("mcc2"), "m3": d.get("mcc3")}).mappings().first()
    return row

@router.put("/{country_id_or_name}")
def update_country(country_id_or_name: str, d: dict = Body(...)):
    # accept either integer id or country name
    if country_id_or_name.isdigit():
        q = "UPDATE countries SET name=COALESCE(:n,name), mcc=:m1, mcc2=:m2, mcc3=:m3 WHERE id=:k RETURNING id,name,mcc,mcc2,mcc3"
        params = {"k": int(country_id_or_name)}
    else:
        q = "UPDATE countries SET name=COALESCE(:n,name), mcc=:m1, mcc2=:m2, mcc3=:m3 WHERE name=:k RETURNING id,name,mcc,mcc2,mcc3"
        params = {"k": country_id_or_name}
    params.update({"n": d.get("name"), "m1": d.get("mcc"), "m2": d.get("mcc2"), "m3": d.get("mcc3")})
    with engine.begin() as c:
        row = c.execute(text(q), params).mappings().first()
    if not row:
        raise HTTPException(status_code=404, detail="Country not found")
    return row
PY

# networks
cat > "$ROUT/networks.py" <<'PY'
from fastapi import APIRouter, Body
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/")
def list_networks():
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT n.id, n.name, n.country_id, n.mnc, n.mccmnc,
                   c.name as country
            FROM networks n
            LEFT JOIN countries c ON c.id = n.country_id
            ORDER BY COALESCE(c.name,''), n.name
        """)).mappings().all()
    return rows

@router.post("/")
def create_network(d: dict = Body(...)):
    with engine.begin() as c:
        row = c.execute(text("""
            INSERT INTO networks(name, country_id, mnc, mccmnc)
            VALUES(:name,:cid,:mnc,:mccmnc)
            RETURNING id, name, country_id, mnc, mccmnc
        """), {
            "name": d.get("name"),
            "cid": d.get("country_id"),
            "mnc": d.get("mnc"),
            "mccmnc": d.get("mccmnc")
        }).mappings().first()
    return row
PY

# offers (list + CRUD)
cat > "$ROUT/offers.py" <<'PY'
from fastapi import APIRouter, Query, Body, HTTPException
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/")
def list_offers(limit: int = Query(50, ge=1, le=1000), offset: int = Query(0, ge=0)):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, supplier_name, connection_name, country_name, network_name, mccmnc,
                   price, price_effective_date, previous_price, route_type, known_hops,
                   sender_id_supported, registration_required, eta_days, charge_model,
                   is_exclusive, notes, updated_by, created_at, updated_at
            FROM offers ORDER BY id DESC
            LIMIT :lim OFFSET :off
        """), {"lim": limit, "off": offset}).mappings().all()
    return rows

@router.post("/")
def create_offer(d: dict = Body(...)):
    req = ["supplier_name","connection_name","price"]
    if any(not d.get(k) for k in req):
        raise HTTPException(status_code=400, detail="supplier_name, connection_name, price required")
    with engine.begin() as c:
        row = c.execute(text("""
            INSERT INTO offers(
              supplier_name, connection_name, country_name, network_name, mccmnc,
              price, price_effective_date, previous_price, route_type, known_hops,
              sender_id_supported, registration_required, eta_days, charge_model,
              is_exclusive, notes, updated_by
            )
            VALUES(
              :supplier_name, :connection_name, :country_name, :network_name, :mccmnc,
              :price, :price_effective_date, :previous_price, :route_type, :known_hops,
              :sender_id_supported, :registration_required, :eta_days, :charge_model,
              COALESCE(:is_exclusive,false), :notes, :updated_by
            )
            RETURNING id
        """), d).scalar()
    return {"id": row}

@router.put("/{offer_id}")
def update_offer(offer_id: int, d: dict = Body(...)):
    sets = []
    params = {"id": offer_id}
    for k in ["supplier_name","connection_name","country_name","network_name","mccmnc",
              "price","price_effective_date","previous_price","route_type","known_hops",
              "sender_id_supported","registration_required","eta_days","charge_model",
              "is_exclusive","notes","updated_by"]:
        if k in d:
            sets.append(f"{k}=:{k}")
            params[k] = d[k]
    if not sets:
        return {"ok": True}
    q = "UPDATE offers SET " + ", ".join(sets) + ", updated_at=now() WHERE id=:id RETURNING id"
    with engine.begin() as c:
        r = c.execute(text(q), params).scalar()
    if not r:
        raise HTTPException(status_code=404, detail="Offer not found")
    return {"ok": True}

@router.delete("/{offer_id}")
def delete_offer(offer_id: int):
    with engine.begin() as c:
        res = c.execute(text("DELETE FROM offers WHERE id=:id"), {"id": offer_id})
    return {"deleted": res.rowcount}
PY

# parsers (simple CRUD)
cat > "$ROUT/parsers.py" <<'PY'
from fastapi import APIRouter, Body, HTTPException
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/")
def list_parsers():
    with engine.begin() as c:
        rows = c.execute(text("SELECT id, name, template, enabled FROM parsers ORDER BY name")).mappings().all()
    return rows

@router.post("/")
def create_parser(d: dict = Body(...)):
    name = (d.get("name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="name required")
    with engine.begin() as c:
        row = c.execute(text("""
            INSERT INTO parsers(name, template, enabled)
            VALUES(:n,:t,COALESCE(:e,true))
            ON CONFLICT (name) DO UPDATE SET template=EXCLUDED.template, enabled=EXCLUDED.enabled
            RETURNING id, name, template, enabled
        """), {"n": name, "t": d.get("template"), "e": d.get("enabled")}).mappings().first()
    return row

@router.put("/{parser_id}")
def update_parser(parser_id: int, d: dict = Body(...)):
    with engine.begin() as c:
        row = c.execute(text("""
            UPDATE parsers SET
              name=COALESCE(:n,name),
              template=COALESCE(:t,template),
              enabled=COALESCE(:e,enabled),
              updated_at=now()
            WHERE id=:id
            RETURNING id, name, template, enabled
        """), {"id": parser_id, "n": d.get("name"), "t": d.get("template"), "e": d.get("enabled")}).mappings().first()
    if not row:
        raise HTTPException(status_code=404, detail="Parser not found")
    return row

@router.delete("/{parser_id}")
def delete_parser(parser_id: int):
    with engine.begin() as c:
        res = c.execute(text("DELETE FROM parsers WHERE id=:id"), {"id": parser_id})
    return {"deleted": res.rowcount}
PY

# lookups (typeahead helpers)
cat > "$ROUT/lookups.py" <<'PY'
from fastapi import APIRouter, Query
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/suppliers")
def suppliers(q: str = Query("", description="search term")):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, organization_name FROM suppliers
            WHERE (:q = '' OR organization_name ILIKE '%'||:q||'%')
            ORDER BY organization_name LIMIT 50
        """), {"q": q}).mappings().all()
    return rows

@router.get("/connections")
def connections(supplier_id: int | None = None):
    if supplier_id is None:
        return []
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, connection_name FROM supplier_connections
            WHERE supplier_id=:sid ORDER BY connection_name
        """), {"sid": supplier_id}).mappings().all()
    return rows

@router.get("/countries")
def countries(q: str = ""):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, name, mcc, mcc2, mcc3 FROM countries
            WHERE (:q = '' OR name ILIKE '%'||:q||'%')
            ORDER BY name LIMIT 50
        """), {"q": q}).mappings().all()
    return rows

@router.get("/networks")
def networks(q: str = ""):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT n.id, n.name, c.name AS country
            FROM networks n LEFT JOIN countries c ON c.id=n.country_id
            WHERE (:q = '' OR n.name ILIKE '%'||:q||'%')
            ORDER BY n.name LIMIT 50
        """), {"q": q}).mappings().all()
    return rows
PY

############################################
# 6) main.py with CORS + routers + startup
############################################
cat > "$API/main.py" <<'PY'
import time, logging
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from app.core.database import engine
from app.migrations_users import ensure_users
from app.migrations_domain import ensure_domain

log = logging.getLogger("uvicorn")

def wait_for_db(max_tries=60, delay=1.0):
    for _ in range(max_tries):
        try:
            with engine.connect() as c:
                c.execute(text("SELECT 1"))
            return
        except Exception:
            time.sleep(delay)
    log.error("DB not reachable after wait; continuing")

app = FastAPI(title="SMS Procurement Manager")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=False,
    allow_methods=["*"], allow_headers=["*"]
)

@app.on_event("startup")
def _startup():
    wait_for_db()
    try:
        ensure_users()
        ensure_domain()
    except Exception as e:
        log.error("Startup migrations failed: %s", e)

# include routers
from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.suppliers import router as suppliers_router
from app.routers.countries import router as countries_router
from app.routers.networks import router as networks_router
from app.routers.offers import router as offers_router
from app.routers.parsers import router as parsers_router
from app.routers.lookups import router as lookups_router

app.include_router(users_router, prefix="/users", tags=["Users"])
app.include_router(conf_router,  prefix="/conf", tags=["Config"])
app.include_router(suppliers_router, prefix="/suppliers", tags=["Suppliers"])
app.include_router(countries_router, prefix="/countries", tags=["Countries"])
app.include_router(networks_router, prefix="/networks", tags=["Networks"])
app.include_router(offers_router, prefix="/offers", tags=["Offers"])
app.include_router(parsers_router, prefix="/parsers", tags=["Parsers"])
app.include_router(lookups_router, prefix="/lookups", tags=["Lookups"])

@app.get("/")
def root():
    return {"ok": True}
PY

############################################
# 7) docker-compose with PG healthcheck
############################################
cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: smsdb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d smsdb || exit 1"]
      interval: 2s
      timeout: 2s
      retries: 30
      start_period: 2s
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [stack]

  api:
    build:
      context: .
      dockerfile: api.Dockerfile
    environment:
      - DB_URL=postgresql://postgres:postgres@postgres:5432/smsdb
      - SECRET_KEY=dev-secret-key-change-me
      - ACCESS_TOKEN_EXPIRE_MINUTES=720
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    depends_on: [api]
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata:

networks:
  stack:
YAML

############################################
# 8) Build and up
############################################
echo -e "${Y}🐳 Building images...${N}"
docker compose -f "$COMPOSE" build
echo -e "${Y}🚀 Starting stack...${N}"
docker compose -f "$COMPOSE" down --remove-orphans || true
docker compose -f "$COMPOSE" up -d

############################################
# 9) Health checks
############################################
sleep 4
IP=$(hostname -I | awk '{print $1}')
API_URL="http://${IP}:8010/openapi.json"
SET_URL="http://${IP}:8010/conf/enums"
UI_URL="http://${IP}:5183"

echo -e "${Y}🌐 Checking API: ${API_URL}${N}"
if ! curl -s --max-time 10 "$API_URL" | grep -q '"openapi"'; then
  echo -e "${R}✖ API not reachable. Showing API logs:${N}"
  docker compose -f "$COMPOSE" logs --no-color --tail=200 api || true
  exit 1
fi
echo -e "${G}✔ API reachable${N}"

echo -e "${Y}🌐 GET /conf/enums smoke-test${N}"
curl -s --max-time 10 "$SET_URL" | head -c 200; echo

echo -e "${Y}🌐 Checking UI: ${UI_URL}${N}"
if curl -s --max-time 10 "$UI_URL" | grep -qi '<!doctype html>'; then
  echo -e "${G}✔ UI reachable${N}"
else
  echo -e "${R}✖ UI not reachable. Web logs:${N}"
  docker compose -f "$COMPOSE" logs --no-color --tail=120 web || true
  exit 1
fi

echo -e "${G}✅ Done. Try the menus again. Login: admin / admin123${N}"
echo "If UI points to wrong API, in browser console run:"
echo "  localStorage.setItem('API_BASE','http://${IP}:8010'); location.reload();"
