#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUTERS="$API/routers"
DOCKER_DIR="$ROOT/docker"

mkdir -p "$CORE" "$ROUTERS"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUTERS/__init__.py"

########################################
# api.Dockerfile (root-level)
########################################
cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy pydantic \
    "psycopg[binary]" python-multipart \
    "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1" "python-jose[cryptography]"
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

########################################
# docker-compose override: expose 8010
########################################
mkdir -p "$DOCKER_DIR"
if ! grep -q "8010:8000" "$DOCKER_DIR/docker-compose.override.yml" 2>/dev/null; then
cat >> "$DOCKER_DIR/docker-compose.override.yml" <<'YML'

services:
  api:
    build:
      context: ..
      dockerfile: api.Dockerfile
    ports:
      - "8010:8000"
    depends_on:
      - postgres
    environment:
      DB_URL: ${DB_URL:-postgresql://postgres:postgres@postgres:5432/smsdb}
      JWT_SECRET: ${JWT_SECRET:-devsecret}
      JWT_EXPIRE_DAYS: "7"
YML
fi

########################################
# core/database.py
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
# core/auth.py (JWT + bcrypt)
########################################
cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy import text
from app.core.database import engine

SECRET = os.getenv("JWT_SECRET", "devsecret")
ALGO   = "HS256"
EXP_D  = int(os.getenv("JWT_EXPIRE_DAYS", "7"))

oauth2 = OAuth2PasswordBearer(tokenUrl="/users/login")
pwdctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(p: str) -> str:
    return pwdctx.hash(p)

def verify_password(p: str, h: str) -> bool:
    try:
        return pwdctx.verify(p, h)
    except Exception:
        return False

def create_access_token(sub: str) -> str:
    exp = int(time.time()) + EXP_D * 24 * 3600
    return jwt.encode({"sub": sub, "exp": exp}, SECRET, algorithm=ALGO)

def get_current_user(token: str = Depends(oauth2)) -> dict:
    cred_err = HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    try:
        payload = jwt.decode(token, SECRET, [ALGO])
        sub = payload.get("sub")
        if not sub: raise cred_err
    except JWTError:
        raise cred_err
    with engine.begin() as c:
        r = c.execute(text("SELECT id, username, role FROM users WHERE username=:u"), {"u": sub}).mappings().first()
    if not r: raise cred_err
    return {"id": r["id"], "username": r["username"], "role": r["role"]}
PY

########################################
# migrations.py (users + admin)
########################################
cat > "$API/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine
from passlib.context import CryptContext

pwdctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

def migrate_users():
    stmts = [
        """
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR NOT NULL UNIQUE,
          password_hash VARCHAR NOT NULL,
          role VARCHAR(16) DEFAULT 'admin',
          created_at TIMESTAMPTZ DEFAULT now()
        );
        """
    ]
    with engine.begin() as c:
        for s in stmts: c.execute(text(s))

def ensure_admin():
    with engine.begin() as c:
        r = c.execute(text("SELECT 1 FROM users WHERE username='admin'")).scalar()
        if not r:
            h = pwdctx.hash("admin123")
            c.execute(text("INSERT INTO users(username,password_hash,role) VALUES('admin',:h,'admin')"), {"h": h})
PY

########################################
# migrations_domain.py (all business tables)
########################################
cat > "$API/migrations_domain.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

def migrate_domain():
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
        # countries
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
          country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
          name VARCHAR NOT NULL,
          mnc VARCHAR(4),
          mccmnc VARCHAR(16)
        );
        """,
        # offers_current
        """
        CREATE TABLE IF NOT EXISTS offers_current(
          id SERIAL PRIMARY KEY,
          supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
          connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE SET NULL,
          country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
          network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,

          price DOUBLE PRECISION NOT NULL,
          currency VARCHAR(8) DEFAULT 'EUR',
          price_effective_date TIMESTAMPTZ NULL,
          previous_price DOUBLE PRECISION NULL,

          route_type VARCHAR(64),
          known_hops VARCHAR(32),
          sender_id_supported VARCHAR(256),
          registration_required VARCHAR(16),
          eta_days INTEGER,
          charge_model VARCHAR(64),
          is_exclusive BOOLEAN DEFAULT FALSE,
          notes TEXT,
          updated_by VARCHAR(64),
          mccmnc VARCHAR(16),

          created_at TIMESTAMPTZ DEFAULT now(),
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # parser_templates
        """
        CREATE TABLE IF NOT EXISTS parser_templates(
          id SERIAL PRIMARY KEY,
          name VARCHAR NOT NULL UNIQUE,
          editor_html TEXT,
          rule_json JSONB,
          active BOOLEAN DEFAULT TRUE,
          created_at TIMESTAMPTZ DEFAULT now(),
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # config_kv (for enums)
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # updated_at trigger
        """
        DO $$ BEGIN
          CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$
          BEGIN
            NEW.updated_at = now();
            RETURN NEW;
          END; $$ LANGUAGE plpgsql;
        END $$;
        """,
        """
        DO $$ BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='offers_current_touch_updated_at') THEN
            CREATE TRIGGER offers_current_touch_updated_at
            BEFORE UPDATE ON offers_current
            FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
          END IF;
        END $$;
        """,
    ]
    with engine.begin() as c:
        for s in stmts: c.execute(text(s))
PY

########################################
# routers/users.py
########################################
cat > "$ROUTERS/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import verify_password, create_access_token, get_current_user

router = APIRouter()

@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends()):
    with engine.begin() as c:
        r = c.execute(text("SELECT username, password_hash, role FROM users WHERE username=:u"),
                      {"u": form.username}).mappings().first()
    if not r or not verify_password(form.password, r["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token(r["username"])
    return {"access_token": token, "token_type": "bearer"}

@router.get("/me")
def me(user = Depends(get_current_user)):
    return {"username": user["username"], "role": user["role"]}
PY

########################################
# routers/conf.py  (/conf/enums GET/PUT)
########################################
cat > "$ROUTERS/conf.py" <<'PY'
from typing import Dict, List, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
import json
from app.core.auth import get_current_user
from app.core.database import engine

router = APIRouter()

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct", "SS7", "SIM", "Local Bypass"],
    "known_hops": ["0-Hop", "1-Hop", "2-Hops", "N-Hops"],
    "registration_required": ["Yes", "No"],
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"]
}

def _ensure_table() -> None:
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        )"""))

def _get_enums() -> dict:
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).scalar()
    if not row:
        return DEFAULT_ENUMS.copy()
    if isinstance(row, (bytes, bytearray)):
        row = row.decode("utf-8", "ignore")
    if isinstance(row, str):
        try: return json.loads(row)
        except Exception: return DEFAULT_ENUMS.copy()
    return row or DEFAULT_ENUMS.copy()

@router.get("/enums")
def get_enums(_=Depends(get_current_user)):
    return _get_enums()

@router.put("/enums")
def put_enums(payload: dict = Body(...), _=Depends(get_current_user)):
    _ensure_table()
    merged = _get_enums()
    merged.update(payload or {})
    js = json.dumps(merged)
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value) VALUES('enums', CAST(:v AS jsonb)) \
                        ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()"), {"v": js})
    return merged
PY

########################################
# routers/suppliers.py  (+ nested connections)
########################################
cat > "$ROUTERS/suppliers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Path, Body
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

@router.get("/", response_model=List[dict])
def list_suppliers(q: Optional[str]=Query(None), limit:int=50, offset:int=0, _=Depends(get_current_user)):
    sql = "SELECT id, organization_name FROM suppliers"
    params = {}
    if q:
        sql += " WHERE organization_name ILIKE :q"
        params["q"] = f"%{q}%"
    sql += " ORDER BY organization_name LIMIT :limit OFFSET :offset"
    params.update({"limit":limit, "offset":offset})
    with engine.begin() as c:
        rows = c.execute(text(sql), params).mappings().all()
    return [dict(r) for r in rows]

@router.post("/", response_model=dict)
def create_supplier(payload: dict = Body(...), _=Depends(get_current_user)):
    name = (payload.get("organization_name") or "").strip()
    if not name:
        raise HTTPException(422, "organization_name is required")
    with engine.begin() as c:
        r = c.execute(text("INSERT INTO suppliers(organization_name) VALUES (:n) RETURNING id, organization_name"), {"n": name}).mappings().first()
    return dict(r)

@router.put("/{supplier_id}", response_model=dict)
def update_supplier(supplier_id:int=Path(...), payload:dict=Body(...), _=Depends(get_current_user)):
    name = (payload.get("organization_name") or "").strip()
    if not name:
        raise HTTPException(422, "organization_name is required")
    with engine.begin() as c:
        r = c.execute(text("UPDATE suppliers SET organization_name=:n WHERE id=:i RETURNING id, organization_name"), {"n":name, "i":supplier_id}).mappings().first()
    if not r: raise HTTPException(404, "Supplier not found")
    return dict(r)

@router.delete("/{supplier_id}", response_model=dict)
def delete_supplier(supplier_id:int=Path(...), _=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("DELETE FROM suppliers WHERE id=:i RETURNING id"), {"i":supplier_id}).scalar()
    if not r: raise HTTPException(404, "Supplier not found")
    return {"ok": True, "id": supplier_id}

# ---------- Connections ----------
@router.get("/{supplier_id}/connections/", response_model=List[dict])
def list_connections(supplier_id:int=Path(...), q: Optional[str]=Query(None), _=Depends(get_current_user)):
    sql = "SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model FROM supplier_connections WHERE supplier_id=:sid"
    params = {"sid": supplier_id}
    if q:
        sql += " AND (connection_name ILIKE :q OR COALESCE(username,'') ILIKE :q OR COALESCE(kannel_smsc,'') ILIKE :q)"
        params["q"] = f"%{q}%"
    sql += " ORDER BY connection_name"
    with engine.begin() as c:
        rows = c.execute(text(sql), params).mappings().all()
    return [dict(r) for r in rows]

@router.post("/{supplier_id}/connections/", response_model=dict)
def create_connection(supplier_id:int=Path(...), payload:dict=Body(...), _=Depends(get_current_user)):
    name = (payload.get("connection_name") or "").strip()
    if not name:
        raise HTTPException(422, "connection_name is required")
    username = payload.get("username")
    kannel = payload.get("kannel_smsc")
    per_delivered = bool(payload.get("per_delivered", False))
    charge_model = (payload.get("charge_model") or "Per Submitted").strip()
    with engine.begin() as c:
        r = c.execute(text("""
          INSERT INTO supplier_connections(supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model)
          VALUES (:sid,:n,:u,:k,:pd,:cm)
          RETURNING id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
        """), {"sid":supplier_id,"n":name,"u":username,"k":kannel,"pd":per_delivered,"cm":charge_model}).mappings().first()
    return dict(r)

@router.put("/{supplier_id}/connections/{conn_id}", response_model=dict)
def update_connection(supplier_id:int, conn_id:int, payload:dict=Body(...), _=Depends(get_current_user)):
    fields = {
        "connection_name": payload.get("connection_name"),
        "username": payload.get("username"),
        "kannel_smsc": payload.get("kannel_smsc"),
        "per_delivered": payload.get("per_delivered"),
        "charge_model": payload.get("charge_model"),
    }
    set_parts = []
    params = {"sid":supplier_id, "cid":conn_id}
    for k,v in fields.items():
        if v is not None:
            set_parts.append(f"{k}=:{k}")
            params[k]=v
    if not set_parts:
        raise HTTPException(422, "No changes provided")
    sql = f"UPDATE supplier_connections SET {', '.join(set_parts)} WHERE id=:cid AND supplier_id=:sid RETURNING id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model"
    with engine.begin() as c:
        r = c.execute(text(sql), params).mappings().first()
    if not r: raise HTTPException(404, "Connection not found")
    return dict(r)

@router.delete("/{supplier_id}/connections/{conn_id}", response_model=dict)
def delete_connection(supplier_id:int, conn_id:int, _=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("DELETE FROM supplier_connections WHERE id=:cid AND supplier_id=:sid RETURNING id"), {"cid":conn_id,"sid":supplier_id}).scalar()
    if not r: raise HTTPException(404, "Connection not found")
    return {"ok":True,"id":conn_id}
PY

########################################
# routers/countries.py
########################################
cat > "$ROUTERS/countries.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Path, Body
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

@router.get("/", response_model=List[dict])
def list_countries(q: Optional[str]=Query(None), limit:int=50, offset:int=0, _=Depends(get_current_user)):
    sql = "SELECT id, name, mcc, mcc2, mcc3 FROM countries"
    params={}
    if q:
        sql += " WHERE name ILIKE :q OR COALESCE(mcc,'') ILIKE :q OR COALESCE(mcc2,'') ILIKE :q OR COALESCE(mcc3,'') ILIKE :q"
        params["q"]=f"%{q}%"
    sql += " ORDER BY name LIMIT :limit OFFSET :offset"
    params.update({"limit":limit,"offset":offset})
    with engine.begin() as c:
        rows = c.execute(text(sql), params).mappings().all()
    return [dict(r) for r in rows]

@router.post("/", response_model=dict)
def create_country(payload:dict=Body(...), _=Depends(get_current_user)):
    name=(payload.get("name") or "").strip()
    if not name: raise HTTPException(422,"name required")
    mcc = (payload.get("mcc") or None)
    mcc2 = (payload.get("mcc2") or None)
    mcc3 = (payload.get("mcc3") or None)
    with engine.begin() as c:
        r=c.execute(text("""
            INSERT INTO countries(name,mcc,mcc2,mcc3) VALUES(:n,:m1,:m2,:m3)
            RETURNING id, name, mcc, mcc2, mcc3
        """),{"n":name,"m1":mcc,"m2":mcc2,"m3":mcc3}).mappings().first()
    return dict(r)

@router.put("/{country_id}", response_model=dict)
def update_country(country_id:int, payload:dict=Body(...), _=Depends(get_current_user)):
    fields={"name":payload.get("name"), "mcc":payload.get("mcc"), "mcc2":payload.get("mcc2"), "mcc3":payload.get("mcc3")}
    set_parts=[]; params={"id":country_id}
    for k,v in fields.items():
        if v is not None: set_parts.append(f"{k}=:{k}"); params[k]=v
    if not set_parts: raise HTTPException(422,"No changes")
    sql=f"UPDATE countries SET {', '.join(set_parts)} WHERE id=:id RETURNING id,name,mcc,mcc2,mcc3"
    with engine.begin() as c:
        r=c.execute(text(sql),params).mappings().first()
    if not r: raise HTTPException(404,"Country not found")
    return dict(r)

@router.delete("/{country_id}", response_model=dict)
def delete_country(country_id:int, _=Depends(get_current_user)):
    with engine.begin() as c:
        r=c.execute(text("DELETE FROM countries WHERE id=:id RETURNING id"),{"id":country_id}).scalar()
    if not r: raise HTTPException(404,"Country not found")
    return {"ok":True,"id":country_id}
PY

########################################
# routers/networks.py
########################################
cat > "$ROUTERS/networks.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Body, Path
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

def _auto_mccmnc(mcc: str, mnc: str) -> str:
    if not mcc or not mnc: return None
    return f"{mcc}-{mnc}"

@router.get("/", response_model=List[dict])
def list_networks(q: Optional[str]=Query(None), country: Optional[str]=Query(None), limit:int=50, offset:int=0, _=Depends(get_current_user)):
    sql = """
      SELECT n.id, n.name, n.mnc, n.mccmnc, n.country_id, c.name AS country_name, c.mcc, c.mcc2, c.mcc3
      FROM networks n LEFT JOIN countries c ON n.country_id=c.id
    """
    where=[]; params={}
    if q:
        where.append("(n.name ILIKE :q OR COALESCE(n.mnc,'') ILIKE :q OR COALESCE(n.mccmnc,'') ILIKE :q)")
        params["q"]=f"%{q}%"
    if country:
        where.append("c.name ILIKE :cn"); params["cn"]=f"%{country}%"
    if where: sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY c.name, n.name LIMIT :limit OFFSET :offset"
    params.update({"limit":limit,"offset":offset})
    with engine.begin() as c:
        rows=c.execute(text(sql),params).mappings().all()
    return [dict(r) for r in rows]

@router.post("/", response_model=dict)
def create_network(payload:dict=Body(...), _=Depends(get_current_user)):
    name=(payload.get("name") or "").strip()
    if not name: raise HTTPException(422,"name required")
    country_name=payload.get("country_name")
    mnc=(payload.get("mnc") or None)
    cid=None; mcc=None
    if country_name:
        with engine.begin() as c:
            cr=c.execute(text("SELECT id, mcc FROM countries WHERE name=:n"),{"n":country_name}).mappings().first()
        if not cr: raise HTTPException(422,"country_name not found")
        cid=cr["id"]; mcc=cr["mcc"]
    mccmnc=_auto_mccmnc(mcc, mnc) if mcc and mnc else None
    with engine.begin() as c:
        r=c.execute(text("""
          INSERT INTO networks(name, country_id, mnc, mccmnc)
          VALUES (:n,:cid,:mnc,:mccmnc)
          RETURNING id, name, country_id, mnc, mccmnc
        """),{"n":name,"cid":cid,"mnc":mnc,"mccmnc":mccmnc}).mappings().first()
    return dict(r)

@router.put("/{network_id}", response_model=dict)
def update_network(network_id:int, payload:dict=Body(...), _=Depends(get_current_user)):
    changes={}; params={"id":network_id}
    if (nm:=payload.get("name")) is not None: changes["name"]=nm
    if (mnc:=payload.get("mnc"))  is not None: changes["mnc"]=mnc
    country_name = payload.get("country_name")
    cid=None; mcc=None
    if country_name is not None:
        if country_name=="":
            cid=None
        else:
            with engine.begin() as c:
                cr=c.execute(text("SELECT id, mcc FROM countries WHERE name=:n"),{"n":country_name}).mappings().first()
            if not cr: raise HTTPException(422,"country_name not found")
            cid=cr["id"]; mcc=cr["mcc"]
        changes["country_id"]=cid
    # recompute mccmnc if mnc or country changed
    if "mnc" in changes or "country_id" in changes:
        if mcc is None and changes.get("country_id") is not None:
            with engine.begin() as c:
                cr=c.execute(text("SELECT mcc FROM countries WHERE id=:i"),{"i":changes["country_id"]}).mappings().first()
            mcc = cr["mcc"] if cr else None
        nmnc = changes.get("mnc")
        if nmnc is None:
            with engine.begin() as c:
                r=c.execute(text("SELECT mnc FROM networks WHERE id=:i"),{"i":network_id}).mappings().first()
            nmnc = r["mnc"] if r else None
        changes["mccmnc"] = f"{mcc}-{nmnc}" if mcc and nmnc else None
    if not changes: raise HTTPException(422,"No changes")
    sets=", ".join([f"{k}=:{k}" for k in changes.keys()])
    params.update(changes)
    with engine.begin() as c:
        r=c.execute(text(f"UPDATE networks SET {sets} WHERE id=:id RETURNING id, name, country_id, mnc, mccmnc")).mappings().first()
    if not r: raise HTTPException(404,"Network not found")
    return dict(r)

@router.delete("/{network_id}", response_model=dict)
def delete_network(network_id:int, _=Depends(get_current_user)):
    with engine.begin() as c:
        r=c.execute(text("DELETE FROM networks WHERE id=:id RETURNING id"),{"id":network_id}).scalar()
    if not r: raise HTTPException(404,"Network not found")
    return {"ok":True,"id":network_id}
PY

########################################
# routers/offers.py
########################################
cat > "$ROUTERS/offers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Body
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

def _id_by_name(table:str, name:str):
    if not name: return None
    with engine.begin() as c:
        r=c.execute(text(f"SELECT id FROM {table} WHERE name=:n OR organization_name=:n"),{"n":name}).scalar()
    return r

def _conn_id(supplier_id:int, connection_name:str):
    with engine.begin() as c:
        r=c.execute(text("""SELECT id FROM supplier_connections WHERE supplier_id=:sid AND connection_name=:n"""),{"sid":supplier_id,"n":connection_name}).scalar()
    return r

@router.get("/", response_model=List[dict])
def list_offers(
    limit:int=50, offset:int=0,
    supplier: Optional[str]=Query(None),
    connection: Optional[str]=Query(None),
    country: Optional[str]=Query(None),
    network: Optional[str]=Query(None),
    route_type: Optional[str]=Query(None),
    known_hops: Optional[str]=Query(None),
    sender_id_supported: Optional[str]=Query(None),
    registration_required: Optional[str]=Query(None),
    is_exclusive: Optional[bool]=Query(None),
    q: Optional[str]=Query(None),
    _=Depends(get_current_user)
):
    sql = """
      SELECT o.id, o.price, o.currency, o.price_effective_date, o.previous_price,
             o.route_type, o.known_hops, o.sender_id_supported, o.registration_required,
             o.eta_days, o.charge_model, o.is_exclusive, o.notes, o.updated_by, o.mccmnc,
             s.organization_name AS supplier_name,
             sc.connection_name AS connection_name,
             c.name AS country_name, n.name AS network_name
      FROM offers_current o
      LEFT JOIN suppliers s ON o.supplier_id=s.id
      LEFT JOIN supplier_connections sc ON o.connection_id=sc.id
      LEFT JOIN countries c ON o.country_id=c.id
      LEFT JOIN networks n ON o.network_id=n.id
    """
    where=[]; params={"limit":limit,"offset":offset}
    def add_filter(col, val, param):
        if val is None: return
        where.append(f"{col} ILIKE :{param}"); params[param]=f"%{val}%"
    add_filter("s.organization_name", supplier, "supplier")
    add_filter("sc.connection_name", connection, "connection")
    add_filter("c.name", country, "country")
    add_filter("n.name", network, "network")
    add_filter("o.route_type", route_type, "rt")
    add_filter("o.known_hops", known_hops, "kh")
    add_filter("o.sender_id_supported", sender_id_supported, "sid")
    add_filter("o.registration_required", registration_required, "reg")
    if is_exclusive is not None:
        where.append("o.is_exclusive = :ex"); params["ex"]=is_exclusive
    if q:
        where.append("""(
          COALESCE(s.organization_name,'')||' '||COALESCE(sc.connection_name,'')||' '||
          COALESCE(c.name,'')||' '||COALESCE(n.name,'')||' '||COALESCE(o.notes,'')
        ) ILIKE :q"""); params["q"]=f"%{q}%"
    if where: sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY o.updated_at DESC, o.id DESC LIMIT :limit OFFSET :offset"
    with engine.begin() as c:
        rows = c.execute(text(sql), params).mappings().all()
    return [dict(r) for r in rows]

@router.post("/", response_model=dict)
def add_offer(payload:dict=Body(...), _=Depends(get_current_user)):
    supplier_name = payload.get("supplier_name")
    connection_name = payload.get("connection_name")
    if not supplier_name or not connection_name:
        raise HTTPException(422, "supplier_name and connection_name are required")
    supplier_id = _id_by_name("suppliers", supplier_name)
    if not supplier_id: raise HTTPException(422,"supplier_name not found")
    connection_id = _conn_id(supplier_id, connection_name)
    if not connection_id: raise HTTPException(422,"connection_name not found under supplier")

    country_name = payload.get("country_name")
    network_name = payload.get("network_name")
    mccmnc = payload.get("mccmnc")
    country_id = _id_by_name("countries", country_name) if country_name else None
    network_id = _id_by_name("networks", network_name) if network_name else None

    price = payload.get("price")
    if price is None: raise HTTPException(422,"price required")

    cols = ["supplier_id","connection_id","country_id","network_id","price","currency",
            "price_effective_date","previous_price","route_type","known_hops","sender_id_supported",
            "registration_required","eta_days","charge_model","is_exclusive","notes","updated_by","mccmnc"]
    vals = {k: payload.get(k) for k in cols}
    vals["supplier_id"]=supplier_id; vals["connection_id"]=connection_id
    vals["country_id"]=country_id; vals["network_id"]=network_id
    if not vals.get("charge_model"):
        with engine.begin() as c:
            cm=c.execute(text("SELECT charge_model FROM supplier_connections WHERE id=:i"),{"i":connection_id}).scalar()
        vals["charge_model"]=cm
    placeholders=", ".join([f":{k}" for k in cols])
    with engine.begin() as c:
        r=c.execute(text(f"""
          INSERT INTO offers_current({", ".join(cols)}) VALUES ({placeholders})
          RETURNING id
        """), vals).mappings().first()
    return {"id": r["id"], **{k: vals[k] for k in cols}}
PY

########################################
# routers/parsers.py
########################################
cat > "$ROUTERS/parsers.py" <<'PY'
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Path, Body
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user
import json

router = APIRouter()

@router.get("/", response_model=List[dict])
def list_parsers(q: Optional[str]=Query(None), _=Depends(get_current_user)):
    sql="SELECT id, name, active, created_at, updated_at FROM parser_templates"
    params={}
    if q:
        sql += " WHERE name ILIKE :q"; params["q"]=f"%{q}%"
    sql += " ORDER BY name"
    with engine.begin() as c:
        rows=c.execute(text(sql),params).mappings().all()
    return [dict(r) for r in rows]

@router.get("/{pid}", response_model=dict)
def get_parser(pid:int, _=Depends(get_current_user)):
    with engine.begin() as c:
        r=c.execute(text("SELECT id,name,editor_html,rule_json,active,created_at,updated_at FROM parser_templates WHERE id=:i"),{"i":pid}).mappings().first()
    if not r: raise HTTPException(404,"Parser not found")
    out=dict(r); 
    if isinstance(out.get("rule_json"), (bytes, bytearray)): out["rule_json"]=out["rule_json"].decode("utf-8","ignore")
    return out

@router.post("/", response_model=dict)
def create_parser(payload:dict=Body(...), _=Depends(get_current_user)):
    name=(payload.get("name") or "").strip()
    if not name: raise HTTPException(422,"name required")
    editor_html=payload.get("editor_html") or ""
    rule_json=payload.get("rule_json") or {}
    js=json.dumps(rule_json)
    with engine.begin() as c:
        r=c.execute(text("""
          INSERT INTO parser_templates(name,editor_html,rule_json,active)
          VALUES (:n,:h,CAST(:j AS jsonb),TRUE)
          RETURNING id,name,active
        """),{"n":name,"h":editor_html,"j":js}).mappings().first()
    return dict(r)

@router.put("/{pid}", response_model=dict)
def update_parser(pid:int, payload:dict=Body(...), _=Depends(get_current_user)):
    fields={"name":payload.get("name"), "editor_html":payload.get("editor_html"), "active":payload.get("active")}
    sets=[]; params={"id":pid}
    for k,v in fields.items():
        if v is not None: sets.append(f"{k}=:{k}"); params[k]=v
    if "rule_json" in payload and payload["rule_json"] is not None:
        sets.append("rule_json=CAST(:j AS jsonb)"); params["j"]=json.dumps(payload["rule_json"])
    if not sets: raise HTTPException(422,"No changes")
    sql=f"UPDATE parser_templates SET {', '.join(sets)}, updated_at=now() WHERE id=:id RETURNING id,name,active"
    with engine.begin() as c:
        r=c.execute(text(sql),params).mappings().first()
    if not r: raise HTTPException(404,"Parser not found")
    return dict(r)

@router.delete("/{pid}", response_model=dict)
def delete_parser(pid:int, _=Depends(get_current_user)):
    with engine.begin() as c:
        r=c.execute(text("DELETE FROM parser_templates WHERE id=:i RETURNING id"),{"i":pid}).scalar()
    if not r: raise HTTPException(404,"Parser not found")
    return {"ok":True,"id":pid}
PY

########################################
# routers/metrics.py
########################################
cat > "$ROUTERS/metrics.py" <<'PY'
from typing import Dict, List
from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

@router.get("/trends", response_model=dict)
def trends(d: str = Query(..., description="YYYY-MM-DD"), _=Depends(get_current_user)):
    sql = """
    SELECT COALESCE(route_type, 'Unspecified') AS rt, n.name AS network_name, COUNT(*) AS cnt
    FROM offers_current o
    LEFT JOIN networks n ON o.network_id=n.id
    WHERE DATE(o.created_at AT TIME ZONE 'UTC') = :d
       OR DATE(o.updated_at AT TIME ZONE 'UTC') = :d
       OR DATE(o.price_effective_date AT TIME ZONE 'UTC') = :d
    GROUP BY rt, network_name
    """
    with engine.begin() as c:
        rows = c.execute(text(sql), {"d": d}).mappings().all()
    data: Dict[str, List[dict]] = {}
    for r in rows:
        key = r["rt"]
        if key not in data: data[key]=[]
        data[key].append({"network_name": r["network_name"] or "(unknown)", "count": r["cnt"]})
    for k in list(data.keys()):
        data[k] = sorted(data[k], key=lambda x: x["count"], reverse=True)[:10]
    return data
PY

########################################
# boot + main
########################################
cat > "$API/boot.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate_users, ensure_admin
from app.migrations_domain import migrate_domain

app = FastAPI(title="SMS Procurement Manager")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

migrate_users()
ensure_admin()
migrate_domain()

from app.routers import users, conf, suppliers, countries, networks, offers, parsers, metrics
app.include_router(users.router,    prefix="/users",    tags=["Users"])
app.include_router(conf.router,     prefix="/conf",     tags=["Config"])
app.include_router(suppliers.router,prefix="/suppliers",tags=["Suppliers"])
app.include_router(countries.router,prefix="/countries",tags=["Countries"])
app.include_router(networks.router, prefix="/networks", tags=["Networks"])
app.include_router(offers.router,   prefix="/offers",   tags=["Offers"])
app.include_router(parsers.router,  prefix="/parsers",  tags=["Parsers"])
app.include_router(metrics.router,  prefix="/metrics",  tags=["Metrics"])

@app.get("/")
def root():
    return {"ok": True}
PY

cat > "$API/main.py" <<'PY'
from app.boot import app
PY

########################################
# Rebuild + bring up
########################################
cd "$DOCKER_DIR"
docker compose up -d --build api

# Wait for API to listen
echo "⏳ waiting for API :8010 ..."
for i in $(seq 1 40); do
  if curl -sf http://localhost:8010/openapi.json >/dev/null 2>&1; then
    echo "✅ API is up"
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -q '^docker-api-1$'; then
    echo "❌ api container not running"
    docker ps -a
    exit 1
  fi
  sleep 0.5
  if [ $i -eq 40 ]; then
    echo "❌ timeout waiting API"
    docker logs docker-api-1 --tail=200
    exit 1
  fi
done

echo "== OpenAPI paths =="
curl -sS http://localhost:8010/openapi.json | python3 - <<'PY'
import sys, json
paths = json.load(sys.stdin).get("paths", {})
for k in sorted(paths.keys()):
    print(k)
PY

echo
echo "== Login smoke =="
TOK="$(curl -sS -X POST http://localhost:8010/users/login -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=admin&password=admin123' | python3 - <<'PY'
import sys,json
s=sys.stdin.read().strip()
print("" if not s else json.loads(s)["access_token"])
PY
)"
if [ -z "$TOK" ]; then
  echo "❌ login failed"
  docker logs docker-api-1 --tail=200
  exit 1
fi
echo "✅ token ok (${#TOK} chars)"

echo "== Endpoint smoke =="
for ep in /suppliers/ /countries/ /networks/ "/offers/?limit=1&offset=0" "/metrics/trends?d=$(date -u +%F)" /parsers/ /conf/enums ; do
  printf "GET %s\n" "$ep"
  curl -sS "http://localhost:8010$ep" -H "Authorization: Bearer $TOK" | head -c 200; echo
done
