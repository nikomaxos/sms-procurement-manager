#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
DOCK="$ROOT/docker"

mkdir -p "$CORE" "$ROUT"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUT/__init__.py"

########################################
# api.Dockerfile (root-level, used by compose)
########################################
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

########################################
# core/database.py (psycopg v3 DSN)
########################################
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

########################################
# core/auth.py (JWT, bcrypt, admin seed)
########################################
cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional, Dict, Any
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy import text
from app.core.database import SessionLocal

SECRET = os.getenv("JWT_SECRET", "changeme")
ALGO = "HS256"
TOKEN_TTL = 60*60*24*7

pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2 = OAuth2PasswordBearer(tokenUrl="/users/login")
router = APIRouter(prefix="/users", tags=["Users"])

def _ensure_users():
    with SessionLocal() as db, db.begin():
        db.execute(text("""
            CREATE TABLE IF NOT EXISTS users(
              id SERIAL PRIMARY KEY,
              username VARCHAR UNIQUE NOT NULL,
              password_hash VARCHAR NOT NULL,
              role VARCHAR DEFAULT 'user'
            )
        """))
        # seed admin
        if not db.execute(text("SELECT 1 FROM users WHERE username='admin'")).first():
            db.execute(
                text("INSERT INTO users(username,password_hash,role) VALUES(:u,:p,'admin')"),
                {"u":"admin","p":pwd.hash("admin123")}
            )

def get_current_user(token: str = Depends(oauth2)) -> Dict[str, Any]:
    try:
        payload = jwt.decode(token, SECRET, algorithms=[ALGO])
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    return {"sub": payload.get("sub","admin")}

@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends()):
    with SessionLocal() as db:
        row = db.execute(text("SELECT password_hash FROM users WHERE username=:u"), {"u":form.username}).first()
        if not row or not pwd.verify(form.password, row.password_hash):
            raise HTTPException(status_code=401, detail="Invalid credentials")
    tok = jwt.encode({"sub": form.username, "exp": int(time.time())+TOKEN_TTL}, SECRET, algorithm=ALGO)
    return {"access_token": tok, "token_type": "bearer"}

@router.get("/me")
def me(user: Dict[str,Any]=Depends(get_current_user)):
    return {"user": user["sub"]}
PY

########################################
# migrations.py (tables + simple upserts)
########################################
cat > "$API/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

def migrate_all():
    stmts = [
        # config_kv for enums/settings
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        )
        """,
        # suppliers
        """
        CREATE TABLE IF NOT EXISTS suppliers(
          id SERIAL PRIMARY KEY,
          organization_name VARCHAR UNIQUE NOT NULL
        )
        """,
        # supplier_connections (per_delivered here)
        """
        CREATE TABLE IF NOT EXISTS supplier_connections(
          id SERIAL PRIMARY KEY,
          supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
          connection_name VARCHAR NOT NULL,
          username VARCHAR,
          kannel_smsc VARCHAR,
          per_delivered BOOLEAN DEFAULT FALSE,
          charge_model VARCHAR(64) DEFAULT 'Per Submitted',
          UNIQUE(supplier_id, connection_name)
        )
        """,
        # countries (with extra MCCs)
        """
        CREATE TABLE IF NOT EXISTS countries(
          id SERIAL PRIMARY KEY,
          name VARCHAR UNIQUE NOT NULL,
          mcc VARCHAR(4),
          mcc2 VARCHAR(4),
          mcc3 VARCHAR(4)
        )
        """,
        # networks (name + country fk by name)
        """
        CREATE TABLE IF NOT EXISTS networks(
          id SERIAL PRIMARY KEY,
          name VARCHAR NOT NULL,
          country_name VARCHAR REFERENCES countries(name) ON UPDATE CASCADE ON DELETE SET NULL,
          mcc VARCHAR(4),
          mnc VARCHAR(4),
          mccmnc VARCHAR(8),
          UNIQUE(name, country_name)
        )
        """,
        # offers (name-based columns)
        """
        CREATE TABLE IF NOT EXISTS offers(
          id SERIAL PRIMARY KEY,
          supplier_name VARCHAR NOT NULL,
          connection_name VARCHAR NOT NULL,
          country_name VARCHAR,
          network_name VARCHAR,
          mccmnc VARCHAR(8),
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
        )
        """,
    ]
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
PY

########################################
# routers: conf, suppliers(+connections), countries, networks, offers, parsers, metrics
########################################
# conf (GET/PUT /conf/enums)
cat > "$ROUT/conf.py" <<'PY'
from typing import Dict, List, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
import json
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/conf", tags=["Config"])
DEFAULT_ENUMS = {
    "route_type": ["Direct", "SS7", "SIM", "Local Bypass"],
    "known_hops": ["0-Hop", "1-Hop", "2-Hops", "N-Hops"],
    "registration_required": ["Yes", "No"],
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"],
}

def _ensure():
    with engine.begin() as c:
        c.execute(text("""
            CREATE TABLE IF NOT EXISTS config_kv(
              key TEXT PRIMARY KEY,
              value JSONB NOT NULL,
              updated_at TIMESTAMPTZ DEFAULT now()
            )
        """))
        cur = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).first()
        if not cur:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES('enums', :v)"),
                      {"v": json.dumps(DEFAULT_ENUMS)})

@router.get("/enums")
def get_enums(user=Depends(get_current_user)):
    _ensure()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).first()
        return row.value if row and row.value else DEFAULT_ENUMS

@router.put("/enums")
def put_enums(payload: Dict[str, List[str]] = Body(...), user=Depends(get_current_user)):
    _ensure()
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value) VALUES('enums', :v) ON CONFLICT (key) DO UPDATE SET value=excluded.value, updated_at=now()"),
                  {"v": json.dumps(payload)})
    return {"ok": True}
PY

# suppliers & connections (name-based)
cat > "$ROUT/suppliers.py" <<'PY'
from typing import List, Optional, Dict, Any
from fastapi import APIRouter, Depends, HTTPException, Body, Path
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(tags=["Suppliers"])

@router.get("/suppliers/")
def list_suppliers(user=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id, organization_name FROM suppliers ORDER BY organization_name")).mappings().all()
        return list(rows)

@router.post("/suppliers/")
def create_supplier(payload: Dict[str, Any] = Body(...), user=Depends(get_current_user)):
    name = (payload.get("organization_name") or "").strip()
    if not name:
        raise HTTPException(422, "organization_name required")
    with engine.begin() as c:
        c.execute(text("INSERT INTO suppliers(organization_name) VALUES(:n) ON CONFLICT (organization_name) DO NOTHING"), {"n": name})
        row = c.execute(text("SELECT id, organization_name FROM suppliers WHERE organization_name=:n"), {"n": name}).mappings().first()
        return row

def _supplier_id(c, supplier_key: str) -> int:
    if supplier_key.isdigit():
        r = c.execute(text("SELECT id FROM suppliers WHERE id=:i"), {"i": int(supplier_key)}).first()
    else:
        r = c.execute(text("SELECT id FROM suppliers WHERE organization_name ILIKE :n"), {"n": supplier_key}).first()
    if not r: raise HTTPException(404, "Supplier not found")
    return int(r[0])

@router.get("/suppliers/{supplier_key}/connections/")
def list_connections(supplier_key: str = Path(...), user=Depends(get_current_user)):
    with engine.begin() as c:
        sid = _supplier_id(c, supplier_key)
        rows = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE supplier_id=:sid ORDER BY connection_name
        """), {"sid": sid}).mappings().all()
        return list(rows)

@router.post("/suppliers/{supplier_key}/connections/")
def create_connection(
    supplier_key: str,
    payload: Dict[str, Any] = Body(...),
    user=Depends(get_current_user),
):
    with engine.begin() as c:
        sid = _supplier_id(c, supplier_key)
        name = (payload.get("connection_name") or "").strip()
        if not name: raise HTTPException(422, "connection_name required")
        c.execute(text("""
            INSERT INTO supplier_connections(supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model)
            VALUES(:sid,:n,:u,:k,COALESCE(:pd,false),COALESCE(:cm,'Per Submitted'))
            ON CONFLICT (supplier_id, connection_name)
            DO UPDATE SET username=excluded.username, kannel_smsc=excluded.kannel_smsc, per_delivered=excluded.per_delivered, charge_model=excluded.charge_model
        """), {
            "sid": sid,
            "n": name,
            "u": payload.get("username"),
            "k": payload.get("kannel_smsc"),
            "pd": payload.get("per_delivered"),
            "cm": payload.get("charge_model"),
        })
        row = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE supplier_id=:sid AND connection_name=:n
        """), {"sid": sid, "n": name}).mappings().first()
        return row
PY

# countries (name-based)
cat > "$ROUT/countries.py" <<'PY'
from typing import Dict, Any
from fastapi import APIRouter, Depends, HTTPException, Body, Path
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(tags=["Countries"])

@router.get("/countries/")
def list_countries(user=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id, name, mcc, mcc2, mcc3 FROM countries ORDER BY name")).mappings().all()
        return list(rows)

@router.post("/countries/")
def create_country(payload: Dict[str,Any]=Body(...), user=Depends(get_current_user)):
    name = (payload.get("name") or "").strip()
    if not name: raise HTTPException(422, "name required")
    with engine.begin() as c:
        c.execute(text("""
            INSERT INTO countries(name, mcc, mcc2, mcc3)
            VALUES(:n,:m1,:m2,:m3)
            ON CONFLICT (name) DO UPDATE SET mcc=excluded.mcc, mcc2=excluded.mcc2, mcc3=excluded.mcc3
        """), {"n":name, "m1":payload.get("mcc"), "m2":payload.get("mcc2"), "m3":payload.get("mcc3")})
        row = c.execute(text("SELECT id, name, mcc, mcc2, mcc3 FROM countries WHERE name=:n"), {"n":name}).mappings().first()
        return row

@router.put("/countries/{country_key}")
def update_country(country_key: str, payload: Dict[str,Any]=Body(...), user=Depends(get_current_user)):
    with engine.begin() as c:
        name = country_key
        r = c.execute(text("SELECT id FROM countries WHERE name ILIKE :n"), {"n":name}).first()
        if not r: raise HTTPException(404, "Country not found")
        c.execute(text("""
            UPDATE countries SET mcc=:m1, mcc2=:m2, mcc3=:m3 WHERE name ILIKE :n
        """), {"n":name, "m1":payload.get("mcc"), "m2":payload.get("mcc2"), "m3":payload.get("mcc3")})
        row = c.execute(text("SELECT id, name, mcc, mcc2, mcc3 FROM countries WHERE name ILIKE :n"), {"n":name}).mappings().first()
        return row
PY

# networks (country lookup by name, MCC autofill)
cat > "$ROUT/networks.py" <<'PY'
from typing import Dict, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(tags=["Networks"])

@router.get("/networks/")
def list_networks(user=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, name, country_name, mcc, mnc, mccmnc
            FROM networks ORDER BY country_name, name
        """)).mappings().all()
        return list(rows)

@router.post("/networks/")
def create_network(payload: Dict[str,Any]=Body(...), user=Depends(get_current_user)):
    name = (payload.get("name") or "").strip()
    if not name: raise HTTPException(422, "name required")
    country = payload.get("country_name")
    mnc = (payload.get("mnc") or "").strip() or None
    with engine.begin() as c:
        mcc = payload.get("mcc")
        if country and not mcc:
            row = c.execute(text("SELECT mcc,mcc2,mcc3 FROM countries WHERE name ILIKE :n"), {"n":country}).mappings().first()
            if row:
                # if multiple MCCs present, require explicit mcc from UI (future), else pick primary
                mcc = row["mcc"]
        mccmnc = (mcc or "") + (mnc or "")
        c.execute(text("""
            INSERT INTO networks(name, country_name, mcc, mnc, mccmnc)
            VALUES(:n,:c,:mcc,:mnc,:mccmnc)
            ON CONFLICT (name, country_name)
            DO UPDATE SET mcc=excluded.mcc, mnc=excluded.mnc, mccmnc=excluded.mccmnc
        """), {"n":name, "c":country, "mcc":mcc, "mnc":mnc, "mccmnc": mccmnc or None})
        row = c.execute(text("""
            SELECT id, name, country_name, mcc, mnc, mccmnc FROM networks WHERE name=:n AND (country_name IS NOT DISTINCT FROM :c)
        """), {"n":name, "c":country}).mappings().first()
        return row
PY

# offers (list + create)
cat > "$ROUT/offers.py" <<'PY'
from typing import Dict, Any
from fastapi import APIRouter, Depends, HTTPException, Body, Query
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(tags=["Offers"])

@router.get("/offers/")
def list_offers(limit: int = Query(50, ge=1, le=1000), offset: int = Query(0, ge=0), user=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, supplier_name, connection_name, country_name, network_name, mccmnc, price,
                   price_effective_date, previous_price, route_type, known_hops, sender_id_supported,
                   registration_required, eta_days, charge_model, is_exclusive, notes, updated_by,
                   created_at, updated_at
            FROM offers ORDER BY updated_at DESC, id DESC
            LIMIT :lim OFFSET :off
        """), {"lim":limit, "off":offset}).mappings().all()
        return list(rows)

@router.post("/offers/")
def add_offer(payload: Dict[str,Any]=Body(...), user=Depends(get_current_user)):
    required = ["supplier_name","connection_name","price"]
    for f in required:
        if not payload.get(f): raise HTTPException(422, f"{f} required")
    with engine.begin() as c:
        # previous price (same supplier+connection+network/mccmnc)
        prev = c.execute(text("""
            SELECT price FROM offers
            WHERE supplier_name=:s AND connection_name=:cn
              AND COALESCE(mccmnc,'') = COALESCE(:mm,'')
              AND COALESCE(network_name,'') = COALESCE(:nn,'')
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
        """), {
            "s": payload.get("supplier_name"),
            "cn": payload.get("connection_name"),
            "mm": payload.get("mccmnc"),
            "nn": payload.get("network_name")
        }).first()
        prev_price = prev[0] if prev else None
        c.execute(text("""
            INSERT INTO offers(
              supplier_name, connection_name, country_name, network_name, mccmnc, price,
              price_effective_date, previous_price, route_type, known_hops, sender_id_supported,
              registration_required, eta_days, charge_model, is_exclusive, notes, updated_by
            ) VALUES(
              :supplier_name, :connection_name, :country_name, :network_name, :mccmnc, :price,
              :price_effective_date, :previous_price, :route_type, :known_hops, :sender_id_supported,
              :registration_required, :eta_days, :charge_model, COALESCE(:is_exclusive,false), :notes, :updated_by
            )
        """), {**payload, "previous_price": payload.get("previous_price") or prev_price})
        row = c.execute(text("SELECT * FROM offers ORDER BY id DESC LIMIT 1")).mappings().first()
        return row
PY

# parsers (skeleton so UI doesn't 404)
cat > "$ROUT/parsers.py" <<'PY'
from typing import Dict, Any, List
from fastapi import APIRouter, Depends, Body
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/parsers", tags=["Parsers"])

def _ensure():
    with engine.begin() as c:
        c.execute(text("""
            CREATE TABLE IF NOT EXISTS parsers(
              id SERIAL PRIMARY KEY,
              name TEXT UNIQUE NOT NULL,
              template TEXT,
              updated_at TIMESTAMPTZ DEFAULT now()
            )
        """))

@router.get("/")
def list_parsers(user=Depends(get_current_user)):
    _ensure()
    with engine.begin() as c:
        rows = c.execute(text("SELECT id, name, template, updated_at FROM parsers ORDER BY name")).mappings().all()
        return list(rows)

@router.post("/")
def upsert_parser(payload: Dict[str,Any]=Body(...), user=Depends(get_current_user)):
    _ensure()
    name = (payload.get("name") or "").strip()
    template = payload.get("template") or ""
    with engine.begin() as c:
        c.execute(text("""
            INSERT INTO parsers(name, template) VALUES(:n,:t)
            ON CONFLICT (name) DO UPDATE SET template=excluded.template, updated_at=now()
        """), {"n":name,"t":template})
        row = c.execute(text("SELECT id, name, template, updated_at FROM parsers WHERE name=:n"), {"n":name}).mappings().first()
        return row
PY

# metrics (trends: per route_type top networks for a date)
cat > "$ROUT/metrics.py" <<'PY'
from datetime import date
from typing import Dict, List
from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/metrics", tags=["Metrics"])

@router.get("/trends")
def trends(d: date = Query(..., description="Target date YYYY-MM-DD"), user=Depends(get_current_user)):
    q = text("""
        SELECT COALESCE(route_type,'(unknown)') AS rt,
               COALESCE(network_name, COALESCE(mccmnc,'(unknown)')) AS net,
               COUNT(*) AS cnt
        FROM offers
        WHERE (DATE(created_at)=:d OR DATE(updated_at)=:d OR DATE(price_effective_date)=:d)
        GROUP BY rt, net
    """)
    data: Dict[str,List[Dict[str,int]]] = {}
    with engine.begin() as c:
        for r in c.execute(q, {"d": d.isoformat()}).mappings().all():
            rt = r["rt"]
            data.setdefault(rt, []).append({"network": r["net"], "count": r["cnt"]})
    # top 10 each
    for k in list(data.keys()):
        data[k] = sorted(data[k], key=lambda x: (-x["count"], x["network"]))[:10]
    return data
PY

########################################
# main.py (CORS **and** include routers, seed admin, run migrations)
########################################
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import os

from app.core.auth import router as users_router, _ensure_users
from app.migrations import migrate_all
from app.routers.conf import router as conf_router
from app.routers.suppliers import router as suppliers_router
from app.routers.countries import router as countries_router
from app.routers.networks import router as networks_router
from app.routers.offers import router as offers_router
from app.routers.parsers import router as parsers_router
from app.routers.metrics import router as metrics_router

app = FastAPI(title="SMS Procurement Manager")

# --- unified CORS (no credentials + wildcard + all methods/headers) ---
origins = os.getenv("CORS_ORIGINS", "http://localhost:5183,http://127.0.0.1:5183,http://192.168.50.102:5183,*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,      # includes '*'
    allow_credentials=False,    # IMPORTANT: False so '*' is valid
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
    max_age=600,
)

# Routers
app.include_router(users_router)
app.include_router(conf_router)
app.include_router(suppliers_router)
app.include_router(countries_router)
app.include_router(networks_router)
app.include_router(offers_router)
app.include_router(parsers_router)
app.include_router(metrics_router)

@app.get("/")
def root():
    return {"ok": True}

# Startup init
@app.on_event("startup")
def _init():
    migrate_all()
    _ensure_users()
PY

########################################
# Build & start API
########################################
cd "$DOCK"
docker compose up -d --build api

# Wait API
echo "⏳ waiting API..."
for i in $(seq 1 40); do
  if curl -sf http://localhost:8010/openapi.json >/dev/null; then echo "✅ API up"; break; fi
  sleep 0.5
  if [ $i -eq 40 ]; then echo "❌ timeout"; docker logs docker-api-1 --tail=200; exit 1; fi
done

# Preflight sanity
ORIGIN="http://$(hostname -I | awk '{print $1}'):5183"
echo "🩺 Preflight check /offers with Origin=$ORIGIN"
curl -i -s -X OPTIONS "http://localhost:8010/offers/?limit=1" \
  -H "Origin: $ORIGIN" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: authorization,content-type" \
  | sed -n '1,25p'

# Login
TOK="$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | python3 - <<'PY'
import sys,json
d=sys.stdin.read().strip()
print("" if not d else json.loads(d)["access_token"])
PY
)"
test -n "$TOK" || { echo "❌ login failed"; docker logs docker-api-1 --tail=200; exit 1; }
echo "🔐 token ok (${#TOK} chars)"

# Auth GET sanity
curl -i -s "http://localhost:8010/conf/enums" \
  -H "Origin: $ORIGIN" \
  -H "Authorization: Bearer $TOK" \
  | sed -n '1,25p'
