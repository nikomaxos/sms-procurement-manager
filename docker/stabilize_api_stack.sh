#!/usr/bin/env bash
# Stabilize Postgres+API+Web: pinned deps, startup migrations with retry, clean routers, start order.

set -euo pipefail
ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
MODELS="$API/models"
DOCKER="$ROOT/docker"

mkdir -p "$CORE" "$ROUT" "$MODELS"
touch "$API/__init__.py" "$CORE/__init__.py" "$ROUT/__init__.py" "$MODELS/__init__.py"

# ---------- core/database.py ----------
cat > "$CORE/database.py" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

DB_URL = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine, future=True)
Base = declarative_base()
PY

# ---------- core/auth.py (pinned bcrypt workaround, 72-byte trim) ----------
cat > "$CORE/auth.py" <<'PY'
import os, time
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.context import CryptContext

SECRET = os.getenv("JWT_SECRET", "changeme")
ALGO   = "HS256"
MINS   = int(os.getenv("ACCESS_TOKEN_MINUTES", "360"))

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")
pwd_context   = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(p: str) -> str:
    if p and len(p) > 72: p = p[:72]
    return pwd_context.hash(p or "")

def verify_password(p: str, h: str) -> bool:
    try:
        if p and len(p) > 72: p = p[:72]
        return pwd_context.verify(p or "", h or "")
    except Exception:
        return False

def create_access_token(sub: str) -> str:
    exp = int(time.time()) + MINS*60
    return jwt.encode({"sub": sub, "exp": exp}, SECRET, algorithm=ALGO)

def decode_token(token: str):
    try:
        return jwt.decode(token, SECRET, algorithms=[ALGO]).get("sub")
    except JWTError:
        return None

def get_current_user(token: str = Depends(oauth2_scheme)) -> str:
    sub = decode_token(token)
    if not sub:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Could not validate credentials")
    return sub
PY

# ---------- models/models.py ----------
cat > "$MODELS/models.py" <<'PY'
from sqlalchemy import Column, Integer, String, Boolean, ForeignKey, Float, Text, DateTime
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.sql import func
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, index=True)
    password_hash = Column(String)
    role = Column(String, default="user")

class Supplier(Base):
    __tablename__ = "suppliers"
    id = Column(Integer, primary_key=True)
    organization_name = Column(String, unique=True, nullable=False)
    per_delivered = Column(Boolean, default=False)

class SupplierConnection(Base):
    __tablename__ = "supplier_connections"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id", ondelete="CASCADE"))
    connection_name = Column(String, nullable=False)
    username = Column(String)
    kannel_smsc = Column(String)
    charge_model = Column(String, default="Per Submitted")

class Country(Base):
    __tablename__ = "countries"
    id = Column(Integer, primary_key=True)
    name = Column(String, unique=True, nullable=False)
    mcc = Column(String)

class Network(Base):
    __tablename__ = "networks"
    id = Column(Integer, primary key=True)
    country_id = Column(Integer, ForeignKey("countries.id", ondelete="SET NULL"))
    name = Column(String, nullable=False)
    mnc = Column(String)
    mccmnc = Column(String)

class OfferCurrent(Base):
    __tablename__ = "offers_current"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id", ondelete="CASCADE"))
    connection_id = Column(Integer, ForeignKey("supplier_connections.id", ondelete="CASCADE"))
    country_id = Column(Integer, ForeignKey("countries.id", ondelete="SET NULL"))
    network_id = Column(Integer, ForeignKey("networks.id", ondelete="SET NULL"))
    mccmnc = Column(String)
    price = Column(Float)
    previous_price = Column(Float)
    currency = Column(String, default="EUR")
    price_effective_date = Column(DateTime)
    route_type = Column(String)
    known_hops = Column(String)
    sender_id_supported = Column(JSONB)
    registration_required = Column(String)
    eta_days = Column(Integer)
    charge_model = Column(String)
    is_exclusive = Column(String)
    notes = Column(Text)
    updated_by = Column(String)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())
PY

# ---------- migrations.py with RETRY ----------
cat > "$API/migrations.py" <<'PY'
import time
from sqlalchemy import text
from app.core.database import engine

STMTs = [
    """CREATE TABLE IF NOT EXISTS users(
         id SERIAL PRIMARY KEY,
         username VARCHAR UNIQUE,
         password_hash VARCHAR,
         role VARCHAR DEFAULT 'user'
    )""",
    """CREATE TABLE IF NOT EXISTS suppliers(
         id SERIAL PRIMARY KEY,
         organization_name VARCHAR NOT NULL UNIQUE,
         per_delivered BOOLEAN DEFAULT FALSE
    )""",
    """CREATE TABLE IF NOT EXISTS supplier_connections(
         id SERIAL PRIMARY KEY,
         supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
         connection_name VARCHAR NOT NULL,
         username VARCHAR,
         kannel_smsc VARCHAR,
         charge_model VARCHAR DEFAULT 'Per Submitted'
    )""",
    """DO $$ BEGIN
       IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='supplier_connections_uniq') THEN
         CREATE UNIQUE INDEX supplier_connections_uniq ON supplier_connections(supplier_id, connection_name);
       END IF;
     END $$;""",
    """CREATE TABLE IF NOT EXISTS countries(
         id SERIAL PRIMARY KEY,
         name VARCHAR NOT NULL UNIQUE,
         mcc VARCHAR
    )""",
    """CREATE TABLE IF NOT EXISTS networks(
         id SERIAL PRIMARY KEY,
         country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
         name VARCHAR NOT NULL,
         mnc VARCHAR,
         mccmnc VARCHAR
    )""",
    """DO $$ BEGIN
       IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='networks_uniq_mccmnc') THEN
         CREATE UNIQUE INDEX networks_uniq_mccmnc ON networks(mccmnc);
       END IF;
     END $$;""",
    """CREATE TABLE IF NOT EXISTS offers_current(
         id SERIAL PRIMARY KEY,
         supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
         connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE CASCADE,
         country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
         network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,
         mccmnc VARCHAR,
         price DOUBLE PRECISION,
         previous_price DOUBLE PRECISION,
         currency VARCHAR(8) DEFAULT 'EUR',
         price_effective_date TIMESTAMP DEFAULT NOW(),
         route_type VARCHAR(64),
         known_hops VARCHAR(32),
         sender_id_supported JSONB DEFAULT '[]'::jsonb,
         registration_required VARCHAR(16),
         eta_days INTEGER,
         charge_model VARCHAR(32),
         is_exclusive VARCHAR(8),
         notes TEXT,
         updated_by VARCHAR(128),
         updated_at TIMESTAMP DEFAULT NOW()
    )""",
    """DO $$ BEGIN
       IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='offers_current_uniq') THEN
         CREATE UNIQUE INDEX offers_current_uniq ON offers_current(supplier_id, connection_id, network_id);
       END IF;
     END $$;""",
    "UPDATE suppliers SET per_delivered=FALSE WHERE per_delivered IS NULL"
]

def migrate_with_retry(max_tries=40, delay=2.0):
    last = None
    for i in range(max_tries):
        try:
            with engine.begin() as c:
                for s in STMTs:
                    c.execute(text(s))
            return True
        except Exception as e:
            last = e
            time.sleep(delay)
    raise RuntimeError(f\"DB not ready or migration failed: {last}\")
PY

# ---------- routers (minimal, name-based) ----------
cat > "$ROUT/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import select
from app.core.database import SessionLocal, Base, engine
from app.core import auth
from app.models import models

router = APIRouter()

@router.post("/users/login", tags=["Users"])
def login(form: OAuth2PasswordRequestForm = Depends()):
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    try:
        u = db.execute(select(models.User).where(models.User.username==form.username)).scalars().first()
        if not u or not auth.verify_password(form.password, u.password_hash):
            raise HTTPException(status_code=400, detail="Invalid credentials")
        return {"access_token": auth.create_access_token(u.username), "token_type":"bearer"}
    finally:
        db.close()
PY

cat > "$ROUT/countries.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

@router.get("/countries", tags=["Countries"])
def list_countries(user=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,mcc FROM countries ORDER BY name")).mappings().all()
    return [dict(r) for r in rows]

@router.post("/countries", tags=["Countries"])
def create_country(body: dict, user=Depends(get_current_user)):
    name = (body.get("name") or "").strip()
    if not name: raise HTTPException(400, "name required")
    with engine.begin() as c:
        r = c.execute(text("INSERT INTO countries(name,mcc) VALUES(:n,:m) ON CONFLICT(name) DO NOTHING RETURNING id"),
                      {"n":name, "m":body.get("mcc")}).first()
        if not r:
            r = c.execute(text("SELECT id FROM countries WHERE name=:n"), {"n":name}).first()
    return {"id": r[0]}
PY

cat > "$ROUT/networks.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

def _country_id(cn, conn):
    r = conn.execute(text("SELECT id FROM countries WHERE name=:n"), {"n":cn}).first()
    if not r: raise HTTPException(400, f"Country not found: {cn}")
    return r[0]

@router.get("/networks", tags=["Networks"])
def list_networks(country_name: str | None = Query(None), user=Depends(get_current_user)):
    with engine.begin() as c:
        if country_name:
            rows = c.execute(text("""
                SELECT n.id, n.name, n.mnc, n.mccmnc, n.country_id, c.name AS country_name
                  FROM networks n LEFT JOIN countries c ON c.id=n.country_id
                 WHERE c.name=:cn ORDER BY n.name
            """), {"cn":country_name}).mappings().all()
        else:
            rows = c.execute(text("""
                SELECT n.id, n.name, n.mnc, n.mccmnc, n.country_id, c.name AS country_name
                  FROM networks n LEFT JOIN countries c ON c.id=n.country_id
                 ORDER BY c.name, n.name
            """)).mappings().all()
    return [dict(r) for r in rows]

@router.post("/networks", tags=["Networks"])
def create_network(body: dict, user=Depends(get_current_user)):
    name = (body.get("name") or "").strip()
    cn   = (body.get("country_name") or "").strip()
    if not name or not cn: raise HTTPException(400, "name and country_name required")
    with engine.begin() as c:
        cid = _country_id(cn, c)
        r = c.execute(text("""
           INSERT INTO networks(name,country_id,mnc,mccmnc)
           VALUES(:n,:cid,:mnc,:mm)
           ON CONFLICT(mccmnc) DO NOTHING
           RETURNING id
        """), {"n":name, "cid":cid, "mnc":body.get("mnc"), "mm":body.get("mccmnc")}).first()
        if not r:
            r = c.execute(text("SELECT id FROM networks WHERE (mccmnc=:mm) OR (name=:n AND country_id=:cid)"),
                          {"mm":body.get("mccmnc"), "n":name, "cid":cid}).first()
    return {"id": r[0]}
PY

cat > "$ROUT/suppliers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

@router.get("/suppliers", tags=["Suppliers"])
def list_suppliers(user=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,organization_name,per_delivered FROM suppliers ORDER BY organization_name")).mappings().all()
    return [dict(r) for r in rows]

@router.post("/suppliers", tags=["Suppliers"])
def create_supplier(body: dict, user=Depends(get_current_user)):
    name = (body.get("organization_name") or "").strip()
    if not name: raise HTTPException(400, "organization_name required")
    with engine.begin() as c:
        r = c.execute(text("""
           INSERT INTO suppliers(organization_name,per_delivered)
           VALUES(:n,COALESCE(:pd,false))
           ON CONFLICT(organization_name) DO NOTHING
           RETURNING id
        """), {"n":name, "pd":body.get("per_delivered")}).first()
        if not r:
            r = c.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n":name}).first()
    return {"id": r[0]}
PY

cat > "$ROUT/connections.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

def _supplier_id(name, conn):
    r = conn.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n":name}).first()
    if not r: raise HTTPException(400, f"Supplier not found: {name}")
    return r[0]

@router.get("/connections", tags=["Connections"])
def list_connections(supplier_name: str | None = Query(None), user=Depends(get_current_user)):
    with engine.begin() as c:
        if supplier_name:
            rows = c.execute(text("""
               SELECT sc.id, sc.connection_name, sc.username, sc.charge_model,
                      s.organization_name AS supplier_name
                 FROM supplier_connections sc
                 JOIN suppliers s ON s.id=sc.supplier_id
                WHERE s.organization_name=:n
                ORDER BY sc.connection_name
            """), {"n":supplier_name}).mappings().all()
        else:
            rows = c.execute(text("""
               SELECT sc.id, sc.connection_name, sc.username, sc.charge_model,
                      s.organization_name AS supplier_name
                 FROM supplier_connections sc
                 JOIN suppliers s ON s.id=sc.supplier_id
                ORDER BY s.organization_name, sc.connection_name
            """)).mappings().all()
    return [dict(r) for r in rows]

@router.post("/connections", tags=["Connections"])
def create_connection(body: dict, user=Depends(get_current_user)):
    sname = (body.get("supplier_name") or "").strip()
    cname = (body.get("connection_name") or "").strip()
    if not sname or not cname: raise HTTPException(400, "supplier_name and connection_name required")
    with engine.begin() as c:
        sid = _supplier_id(sname, c)
        r = c.execute(text("""
           INSERT INTO supplier_connections(supplier_id,connection_name,username,kannel_smsc,charge_model)
           VALUES(:sid,:cn,:u,:smsc,:cm)
           ON CONFLICT(supplier_id,connection_name) DO NOTHING
           RETURNING id
        """), {"sid":sid, "cn":cname, "u":body.get("username"),
               "smsc":body.get("kannel_smsc"), "cm":body.get("charge_model") or "Per Submitted"}).first()
        if not r:
            r = c.execute(text("SELECT id FROM supplier_connections WHERE supplier_id=:sid AND connection_name=:cn"),
                          {"sid":sid, "cn":cname}).first()
    return {"id": r[0]}
PY

cat > "$ROUT/offers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from typing import Any, Dict
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

def _id_by_name(conn, table, name_field, name_value):
    r = conn.execute(text(f"SELECT id FROM {table} WHERE {name_field}=:v"), {"v":name_value}).first()
    return r[0] if r else None

def _resolve_network(conn, *, network_name=None, mccmnc=None, country_name=None):
    if mccmnc:
        r = conn.execute(text("SELECT id,country_id,mccmnc FROM networks WHERE mccmnc=:mm"), {"mm":mccmnc}).first()
        if r: return r.id, r.country_id, r.mccmnc
    if network_name and country_name:
        r = conn.execute(text("""
            SELECT n.id, n.country_id, n.mccmnc FROM networks n
            JOIN countries c ON c.id=n.country_id
            WHERE n.name=:nn AND c.name=:cn
        """), {"nn":network_name, "cn":country_name}).first()
        if r: return r.id, r.country_id, r.mccmnc
    if network_name:
        r = conn.execute(text("SELECT id, country_id, mccmnc FROM networks WHERE name=:nn LIMIT 1"), {"nn":network_name}).first()
        if r: return r.id, r.country_id, r.mccmnc
    return None, None, None

def _inherit_charge_model(conn, connection_id):
    r = conn.execute(text("SELECT charge_model FROM supplier_connections WHERE id=:id"), {"id":connection_id}).first()
    return (r[0] if r and r[0] else "Per Submitted")

@router.get("/offers", tags=["Offers"])
def list_offers(
    country_name: str | None = Query(None),
    route_type: str | None = Query(None),
    known_hops: str | None = Query(None),
    supplier_name: str | None = Query(None),
    connection_name: str | None = Query(None),
    sender_id_supported: str | None = Query(None),
    registration_required: str | None = Query(None),
    is_exclusive: str | None = Query(None),
    limit: int = Query(200, ge=1, le=500),
    user=Depends(get_current_user)
):
    q = """
    SELECT oc.id, s.organization_name AS supplier_name,
           sc.connection_name, sc.username AS smsc_username,
           c.name AS country, n.name AS network, n.mccmnc,
           oc.price, oc.previous_price, oc.currency, oc.price_effective_date,
           oc.route_type, oc.known_hops, oc.sender_id_supported,
           oc.registration_required, oc.eta_days, oc.charge_model,
           oc.is_exclusive, oc.notes, oc.updated_by, oc.updated_at
      FROM offers_current oc
      LEFT JOIN supplier_connections sc ON sc.id=oc.connection_id
      LEFT JOIN suppliers s ON s.id=oc.supplier_id
      LEFT JOIN networks n ON n.id=oc.network_id
      LEFT JOIN countries c ON c.id=n.country_id
     WHERE 1=1
    """
    p: Dict[str, Any] = {}
    if country_name: q += " AND c.name=:country"; p["country"]=country_name
    if route_type: q += " AND oc.route_type=:rt"; p["rt"]=route_type
    if known_hops: q += " AND oc.known_hops=:kh"; p["kh"]=known_hops
    if supplier_name: q += " AND s.organization_name ILIKE :sn"; p["sn"]=f"%{supplier_name}%"
    if connection_name: q += " AND sc.connection_name ILIKE :cn"; p["cn"]=f"%{connection_name}%"
    if sender_id_supported:
        q += " AND oc.sender_id_supported @> :sid::jsonb"; p["sid"]=f'["{sender_id_supported}"]'
    if registration_required: q += " AND oc.registration_required=:rr"; p["rr"]=registration_required
    if is_exclusive: q += " AND oc.is_exclusive=:ix"; p["ix"]=is_exclusive
    q += " ORDER BY oc.updated_at DESC LIMIT :lim"; p["lim"]=limit
    with engine.begin() as c:
        rows = c.execute(text(q), p).mappings().all()
    out=[]
    for r in rows:
        d = dict(r)
        if isinstance(d.get("sender_id_supported"), str):
            d["sender_id_supported"] = [x.strip() for x in d["sender_id_supported"].split(",") if x.strip()]
        out.append(d)
    return out

@router.post("/offers/by_names", tags=["Offers"])
def create_offer_by_names(body: dict, user=Depends(get_current_user)):
    if not body.get("supplier_name") or not body.get("connection_name"):
        raise HTTPException(400, "supplier_name and connection_name required")
    with engine.begin() as c:
        sid = _id_by_name(c, "suppliers", "organization_name", body["supplier_name"])
        if not sid: raise HTTPException(400, "Unknown supplier")
        cid = c.execute(text("""
           SELECT id FROM supplier_connections
            WHERE supplier_id=:s AND connection_name=:cn
        """), {"s":sid, "cn":body["connection_name"]}).scalar()
        if not cid: raise HTTPException(400, "Unknown connection for supplier")

        nid, country_id, mm = _resolve_network(
            c,
            network_name=body.get("network_name"),
            mccmnc=body.get("mccmnc"),
            country_name=body.get("country_name")
        )
        if not nid and not mm:
            raise HTTPException(400, "Provide network_name+country_name or mccmnc")

        cm = _inherit_charge_model(c, cid)
        prev = c.execute(text("""
           SELECT price FROM offers_current
            WHERE supplier_id=:s AND connection_id=:c AND COALESCE(network_id,0)=COALESCE(:n,0)
            LIMIT 1
        """), {"s":sid, "c":cid, "n":nid}).scalar()

        r = c.execute(text("""
          INSERT INTO offers_current(
            supplier_id, connection_id, country_id, network_id, mccmnc,
            price, previous_price, currency, price_effective_date,
            route_type, known_hops, sender_id_supported, registration_required,
            eta_days, charge_model, is_exclusive, notes, updated_by, updated_at
          ) VALUES (
            :sid, :cid, :country_id, :nid, :mm,
            :price, :prev, COALESCE(:currency,'EUR'), COALESCE(NULLIF(:eff,''), NOW())::timestamp,
            :rt, :kh, :sid_sup::jsonb, :reg,
            :eta, :cm, :iex, :notes, 'webui', NOW()
          )
          ON CONFLICT (supplier_id, connection_id, network_id)
          DO UPDATE SET
            previous_price = offers_current.price,
            price = EXCLUDED.price,
            currency = EXCLUDED.currency,
            price_effective_date = EXCLUDED.price_effective_date,
            route_type = EXCLUDED.route_type,
            known_hops = EXCLUDED.known_hops,
            sender_id_supported = EXCLUDED.sender_id_supported,
            registration_required = EXCLUDED.registration_required,
            eta_days = EXCLUDED.eta_days,
            charge_model = EXCLUDED.charge_model,
            is_exclusive = EXCLUDED.is_exclusive,
            notes = EXCLUDED.notes,
            mccmnc = EXCLUDED.mccmnc,
            country_id = EXCLUDED.country_id,
            updated_by = 'webui', updated_at = NOW()
          RETURNING id
        """), {
            "sid":sid, "cid":cid, "country_id":country_id, "nid":nid, "mm":mm,
            "price":body.get("price"), "prev":prev,
            "currency": body.get("currency") or "EUR",
            "eff": body.get("price_effective_date") or "",
            "rt": body.get("route_type"),
            "kh": body.get("known_hops"),
            "sid_sup": body.get("sender_id_supported") or [],
            "reg": body.get("registration_required"),
            "eta": body.get("eta_days"),
            "cm": cm,
            "iex": body.get("is_exclusive"),
            "notes": body.get("notes")
        }).first()
    return {"id": r[0]}
PY

# ---------- main.py with CORS + STARTUP RETRY ----------
cat > "$API/main.py" <<'PY'
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate_with_retry

app = FastAPI(title="SMS Procurement Manager", version="stable")

origins = os.getenv("CORS_ORIGINS","http://localhost:5183,http://127.0.0.1:5183,*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
def on_startup():
    migrate_with_retry()

@app.get("/")
def root():
    return {"message":"API up","version":"stable"}

from app.routers import users, countries, networks, suppliers, connections, offers
app.include_router(users.router)
app.include_router(countries.router)
app.include_router(networks.router)
app.include_router(suppliers.router)
app.include_router(connections.router)
app.include_router(offers.router)
PY

# ---------- api.Dockerfile (pinned deps) ----------
cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy pydantic psycopg[binary] python-multipart \
    passlib[bcrypt]==1.7.4 bcrypt==4.0.1 python-jose[cryptography]
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

echo "🔧 Ensuring Postgres is up (docker-postgres-1)…"
# bring up Postgres if compose has it
( cd "$DOCKER" && docker compose up -d postgres ) || true
# wait for pg (if container exists)
if docker ps --format '{{.Names}}' | grep -q '^docker-postgres-1$'; then
  echo "⏳ Waiting for Postgres to accept connections…"
  for i in {1..40}; do
    if docker exec docker-postgres-1 pg_isready -U postgres -d smsdb -h 127.0.0.1 >/dev/null 2>&1; then
      echo "✅ Postgres ready"
      break
    fi
    sleep 2
  done
fi

echo "🔁 Build & start API…"
( cd "$DOCKER" && docker compose build api && docker compose up -d api )

echo "📋 API logs (tail 60):"
docker logs docker-api-1 --tail=60 || true

echo "👤 Ensure admin user (admin/admin123)…"
docker exec -i docker-api-1 python3 - <<'PY'
from app.core import auth
from app.models import models
from app.core.database import SessionLocal, Base, engine
Base.metadata.create_all(bind=engine)
db=SessionLocal()
u=db.query(models.User).filter_by(username="admin").first()
if not u:
    u=models.User(username="admin", password_hash=auth.get_password_hash("admin123"), role="admin")
    db.add(u); db.commit(); print("✅ Admin created")
else:
    print("ℹ️ Admin exists")
db.close()
PY

echo "🌐 Probe root & login…"
curl -sS http://localhost:8010/ ; echo
TOKEN=$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | python3 -c 'import sys,json; d=sys.stdin.read(); print(json.loads(d)["access_token"])')
echo "Token chars: ${#TOKEN}"
echo "📦 GET /offers ->"
curl -sS http://localhost:8010/offers -H "Authorization: Bearer $TOKEN" ; echo
