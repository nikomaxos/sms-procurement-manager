#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
MODELS="$API/models"
WEB="$ROOT/web"
WEBPUB="$WEB/public"
DOCK="$ROOT/docker"

mkdir -p "$CORE" "$ROUT" "$MODELS" "$WEBPUB"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUT/__init__.py"; : > "$MODELS/__init__.py"

########################
# Core: DB + Auth
########################
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
from typing import Optional
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy import text
from .database import SessionLocal

JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
ALGO = "HS256"
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(pw: str) -> str:
    return pwd_context.hash((pw or "")[:72])

def verify_password(pw: str, hashed: str) -> bool:
    return pwd_context.verify((pw or "")[:72], hashed)

def create_access_token(sub: str, ttl_sec: int = 86400):
    exp = int(time.time()) + ttl_sec
    return jwt.encode({"sub": sub, "exp": exp}, JWT_SECRET, algorithm=ALGO)

def decode_token(tok: str) -> Optional[str]:
    try:
        return jwt.decode(tok, JWT_SECRET, algorithms=[ALGO]).get("sub")
    except JWTError:
        return None

def get_current_user(token: str = Depends(oauth2_scheme)) -> str:
    sub = decode_token(token)
    if not sub:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Could not validate credentials")
    return sub
PY

########################
# Migrations
########################
cat > "$API/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

DDL = [
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
  per_delivered BOOLEAN DEFAULT FALSE,
  charge_model VARCHAR DEFAULT 'Per Submitted'
)
""",
"""
CREATE TABLE IF NOT EXISTS countries(
  id SERIAL PRIMARY KEY,
  name VARCHAR NOT NULL UNIQUE,
  mcc VARCHAR,
  mcc2 VARCHAR,
  mcc3 VARCHAR
)
""",
"""
CREATE TABLE IF NOT EXISTS networks(
  id SERIAL PRIMARY KEY,
  name VARCHAR NOT NULL,
  country_name VARCHAR,
  mcc VARCHAR,
  mnc VARCHAR,
  mccmnc VARCHAR
)
""",
"""
CREATE TABLE IF NOT EXISTS offers(
  id SERIAL PRIMARY KEY,
  supplier_name VARCHAR NOT NULL,
  connection_name VARCHAR NOT NULL,
  country_name VARCHAR,
  network_name VARCHAR,
  mccmnc VARCHAR,
  price DOUBLE PRECISION NOT NULL,
  price_effective_date DATE,
  previous_price DOUBLE PRECISION,
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
"""
CREATE TABLE IF NOT EXISTS conf_enums(
  id INTEGER PRIMARY KEY,
  data JSONB NOT NULL
)
""",
"""
CREATE TABLE IF NOT EXISTS parser_templates(
  id SERIAL PRIMARY KEY,
  name VARCHAR UNIQUE,
  description TEXT,
  html TEXT,
  active BOOLEAN DEFAULT FALSE
)
"""
]

POST = [
"INSERT INTO conf_enums(id, data) VALUES (1, '{\"route_type\":[\"Direct\",\"SS7\",\"SIM\",\"Local Bypass\"],\"known_hops\":[\"0-Hop\",\"1-Hop\",\"2-Hops\",\"N-Hops\"],\"registration_required\":[\"Yes\",\"No\"]}') ON CONFLICT (id) DO NOTHING"
]

def migrate():
    with engine.begin() as conn:
        for stmt in DDL:
            conn.execute(text(stmt))
        for stmt in [
          "ALTER TABLE offers ALTER COLUMN updated_at SET DEFAULT now()",
          "ALTER TABLE supplier_connections ALTER COLUMN per_delivered SET DEFAULT FALSE",
          "ALTER TABLE countries ADD COLUMN IF NOT EXISTS mcc2 VARCHAR",
          "ALTER TABLE countries ADD COLUMN IF NOT EXISTS mcc3 VARCHAR",
          "ALTER TABLE networks ADD COLUMN IF NOT EXISTS country_name VARCHAR",
          "ALTER TABLE networks ADD COLUMN IF NOT EXISTS mcc VARCHAR",
          "ALTER TABLE networks ADD COLUMN IF NOT EXISTS mnc VARCHAR",
          "ALTER TABLE networks ADD COLUMN IF NOT EXISTS mccmnc VARCHAR"
        ]:
            conn.execute(text(stmt))
        for p in POST:
            conn.execute(text(p))
PY

########################
# Routers
########################
cat > "$ROUT/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core import auth

router = APIRouter(tags=["Users"])

@router.post("/users/login")
def login(form: OAuth2PasswordRequestForm = Depends()):
    username = form.username
    password = form.password
    with SessionLocal() as db:
        db.execute(text("""
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR UNIQUE,
          password_hash VARCHAR,
          role VARCHAR
        )"""))
        row = db.execute(text("SELECT id, password_hash FROM users WHERE username=:u"), {"u": username}).first()
        if not row and username == "admin":
            db.execute(text("INSERT INTO users(username,password_hash,role) VALUES(:u,:p,'admin')"),
                       {"u": "admin", "p": auth.get_password_hash("admin123")})
            db.commit()
            row = db.execute(text("SELECT id, password_hash FROM users WHERE username='admin'")).first()
        if not row:
            raise HTTPException(status_code=401, detail="User not found")
        if not auth.verify_password(password, row.password_hash):
            raise HTTPException(status_code=401, detail="Wrong password")
    tok = auth.create_access_token(username, 86400)
    return {"access_token": tok, "token_type": "bearer"}

@router.get("/users/me")
def me(user: str = Depends(auth.get_current_user)):
    return {"user": user}
PY

cat > "$ROUT/conf.py" <<'PY'
from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
router = APIRouter(tags=["Config"])

@router.get("/conf/enums")
def get_enums(user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        row = db.execute(text("SELECT data FROM conf_enums WHERE id=1")).first()
        return row[0] if row else {}

@router.put("/conf/enums")
def put_enums(body: dict, user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("INSERT INTO conf_enums(id,data) VALUES(1,:d) ON CONFLICT (id) DO UPDATE SET data=:d"), {"d": body})
        db.commit()
        return {"ok": True}
PY

cat > "$ROUT/suppliers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user

router = APIRouter(tags=["Suppliers"])

@router.get("/suppliers/")
def list_suppliers(q: str | None = None, limit: int = 50, offset: int = 0, user: str = Depends(get_current_user)):
    sql = "SELECT id, organization_name FROM suppliers"
    params = {}
    if q:
        sql += " WHERE organization_name ILIKE :q"; params["q"] = f"%{q}%"
    sql += " ORDER BY organization_name LIMIT :l OFFSET :o"
    params["l"]=limit; params["o"]=offset
    with SessionLocal() as db:
        return [dict(r._mapping) for r in db.execute(text(sql), params).all()]

@router.post("/suppliers/")
def create_supplier(body: dict, user: str = Depends(get_current_user)):
    name = (body.get("organization_name") or "").strip()
    if not name: raise HTTPException(400,"organization_name required")
    with SessionLocal() as db:
        db.execute(text("INSERT INTO suppliers(organization_name) VALUES(:n) ON CONFLICT DO NOTHING"), {"n": name})
        db.commit()
        return {"organization_name": name}

@router.put("/suppliers/{name}")
def rename_supplier(name: str, body: dict, user: str = Depends(get_current_user)):
    new = (body.get("organization_name") or "").strip()
    if not new: raise HTTPException(400,"organization_name required")
    with SessionLocal() as db:
        r = db.execute(text("UPDATE suppliers SET organization_name=:new WHERE organization_name=:old RETURNING id"), {"new":new,"old":name}).first()
        if not r: raise HTTPException(404,"Not found")
        db.commit(); return {"id": r.id, "organization_name": new}

@router.delete("/suppliers/{name}")
def delete_supplier(name: str, user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("DELETE FROM suppliers WHERE organization_name=:n"),{"n":name}); db.commit(); return {"ok":True}

@router.get("/suppliers/{supplier_name}/connections/")
def list_connections(supplier_name: str, q: str | None = None, user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        sid = db.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": supplier_name}).scalar()
        if not sid: return []
        sql = "SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model FROM supplier_connections WHERE supplier_id=:sid"
        params={"sid":sid}
        if q: sql += " AND (connection_name ILIKE :q OR COALESCE(username,'') ILIKE :q)"; params["q"]=f"%{q}%"
        return [dict(r._mapping) for r in db.execute(text(sql), params).all()]

@router.post("/suppliers/{supplier_name}/connections/")
def create_connection(supplier_name: str, body: dict, user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        sid = db.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": supplier_name}).scalar()
        if not sid: raise HTTPException(404,"Supplier not found")
        db.execute(text("""
          INSERT INTO supplier_connections(supplier_id,connection_name,username,kannel_smsc,per_delivered,charge_model)
          VALUES(:sid,:n,:u,:k,COALESCE(:pd,false),COALESCE(:cm,'Per Submitted'))
        """), {"sid":sid,"n":body.get("connection_name"),"u":body.get("username"),"k":body.get("kannel_smsc"),
               "pd":body.get("per_delivered"),"cm":body.get("charge_model")})
        db.commit(); return {"ok":True}

@router.put("/suppliers/{supplier_name}/connections/{connection_name}")
def update_connection(supplier_name: str, connection_name: str, body: dict, user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        sid = db.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": supplier_name}).scalar()
        if not sid: raise HTTPException(404,"Supplier not found")
        sets=[]; params={"sid":sid,"old":connection_name}
        for k in ("connection_name","username","kannel_smsc","charge_model"):
            if k in body and body[k] is not None:
                sets.append(f"{k}=:{k}"); params[k]=body[k]
        if "per_delivered" in body:
            sets.append("per_delivered=:per_delivered"); params["per_delivered"]=bool(body["per_delivered"])
        if not sets: return {"ok":True}
        r = db.execute(text(f"UPDATE supplier_connections SET {', '.join(sets)} WHERE supplier_id=:sid AND connection_name=:old RETURNING id"), params).first()
        if not r: raise HTTPException(404,"Connection not found")
        db.commit(); return {"ok":True}

@router.delete("/suppliers/{supplier_name}/connections/{connection_name}")
def delete_connection(supplier_name: str, connection_name: str, user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        sid = db.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": supplier_name}).scalar()
        if not sid: raise HTTPException(404,"Supplier not found")
        db.execute(text("DELETE FROM supplier_connections WHERE supplier_id=:sid AND connection_name=:n"),{"sid":sid,"n":connection_name})
        db.commit(); return {"ok":True}
PY

cat > "$ROUT/countries.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
router = APIRouter(tags=["Countries"])

@router.get("/countries/")
def list_countries(q: str|None=None, limit:int=50, offset:int=0, user:str=Depends(get_current_user)):
    sql="SELECT id,name,mcc,mcc2,mcc3 FROM countries"
    params={}
    if q: sql+=" WHERE name ILIKE :q"; params["q"]=f"%{q}%"
    sql+=" ORDER BY name LIMIT :l OFFSET :o"; params["l"]=limit; params["o"]=offset
    with SessionLocal() as db:
        return [dict(r._mapping) for r in db.execute(text(sql), params).all()]

@router.post("/countries/")
def create_country(body:dict, user:str=Depends(get_current_user)):
    name=(body.get("name") or "").strip()
    if not name: raise HTTPException(400,"name required")
    with SessionLocal() as db:
        db.execute(text("""
          INSERT INTO countries(name,mcc,mcc2,mcc3) VALUES(:n,:m,:m2,:m3)
          ON CONFLICT (name) DO UPDATE SET mcc=EXCLUDED.mcc, mcc2=EXCLUDED.mcc2, mcc3=EXCLUDED.mcc3
        """),{"n":name,"m":body.get("mcc"),"m2":body.get("mcc2"),"m3":body.get("mcc3")})
        db.commit(); return {"name":name}

@router.put("/countries/{name}")
def update_country(name:str, body:dict, user:str=Depends(get_current_user)):
    sets=[]; params={"old":name}
    for k in ("name","mcc","mcc2","mcc3"):
        if k in body: sets.append(f"{k}=:{k}"); params[k]=body[k]
    if not sets: return {"ok":True}
    with SessionLocal() as db:
        r=db.execute(text(f"UPDATE countries SET {', '.join(sets)} WHERE name=:old RETURNING id")).first()
        if not r: raise HTTPException(404,"Not found")
        db.commit(); return {"ok":True}

@router.delete("/countries/{name}")
def delete_country(name:str, user:str=Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("DELETE FROM countries WHERE name=:n"),{"n":name}); db.commit(); return {"ok":True}
PY

cat > "$ROUT/networks.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user

router = APIRouter(tags=["Networks"])

@router.get("/networks/")
def list_networks(q:str|None=None, country:str|None=None, mccmnc:str|None=None, limit:int=50, offset:int=0, user:str=Depends(get_current_user)):
    sql="SELECT id,name,country_name,mcc,mnc,mccmnc FROM networks WHERE 1=1"
    params={}
    if q: sql+=" AND name ILIKE :q"; params["q"]=f"%{q}%"
    if country: sql+=" AND country_name ILIKE :c"; params["c"]=f"%{country}%"
    if mccmnc: sql+=" AND mccmnc ILIKE :mm"; params["mm"]=f"%{mccmnc}%"
    sql+=" ORDER BY country_name,name LIMIT :l OFFSET :o"; params["l"]=limit; params["o"]=offset
    with SessionLocal() as db:
        return [dict(r._mapping) for r in db.execute(text(sql), params).all()]

@router.post("/networks/")
def create_network(body:dict, user:str=Depends(get_current_user)):
    name=(body.get("name") or "").strip()
    if not name: raise HTTPException(400,"name required")
    ctry=(body.get("country_name") or body.get("country") or "").strip() or None
    mnc=(body.get("mnc") or "").strip() or None
    mcc=(body.get("mcc") or "").strip() or None
    mm=(body.get("mccmnc") or "").strip() or None
    if not mm and mcc and mnc: mm=mcc+mnc
    with SessionLocal() as db:
        if ctry and not mcc:
            row = db.execute(text("SELECT name,mcc,mcc2,mcc3 FROM countries WHERE name ILIKE :n"), {"n": ctry}).first()
            if row:
                mccs=[x for x in [row.mcc,row.mcc2,row.mcc3] if x]
                if len(mccs)==1: mcc=mccs[0]; 
        if not mm and mcc and mnc: mm=mcc+mnc
        db.execute(text("""
          INSERT INTO networks(name,country_name,mcc,mnc,mccmnc)
          VALUES(:n,:c,:mcc,:mnc,:mm) ON CONFLICT DO NOTHING
        """), {"n":name,"c":ctry,"mcc":mcc,"mnc":mnc,"mm":mm})
        db.commit(); return {"name":name}

@router.put("/networks/by-name/{name}")
def update_network(name:str, body:dict, user:str=Depends(get_current_user)):
    sets=[]; params={"old":name}
    for k in ("name","country_name","mcc","mnc","mccmnc"):
        if k in body: sets.append(f"{k}=:{k}"); params[k]=body[k]
    if ("mcc" in body or "mnc" in body) and "mccmnc" not in body:
        sets.append("mccmnc = CASE WHEN COALESCE(:mcc,'')<>'' AND COALESCE(:mnc,'')<>'' THEN :mcc||:mnc ELSE mccmnc END")
        params.setdefault("mcc", body.get("mcc")); params.setdefault("mnc", body.get("mnc"))
    if not sets: return {"ok":True}
    with SessionLocal() as db:
        r=db.execute(text(f"UPDATE networks SET {', '.join(sets)} WHERE name=:old RETURNING id")).first()
        if not r: raise HTTPException(404,"Not found")
        db.commit(); return {"ok":True}

@router.delete("/networks/by-name/{name}")
def delete_network(name:str, user:str=Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("DELETE FROM networks WHERE name=:n"),{"n":name}); db.commit(); return {"ok":True}
PY

cat > "$ROUT/offers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user

router = APIRouter(tags=["Offers"])

def where_from_filters(p):
    wh=["1=1"]; params={}
    def add(col, key, like=False):
        v=p.get(key)
        if v is None or str(v)=="":
            return
        if like:
            wh.append(f"{col} ILIKE :{key}"); params[key]=f"%{v}%"
        else:
            wh.append(f"{col} = :{key}"); params[key]=v
    add("supplier_name","supplier_name",True)
    add("connection_name","connection_name",True)
    add("country_name","country",True)
    add("network_name","network_name",True)
    add("mccmnc","mccmnc",True)
    add("route_type","route_type",True)
    add("known_hops","known_hops",True)
    add("sender_id_supported","sender_id_supported",True)
    add("registration_required","registration_required",True)
    if p.get("is_exclusive") in ("true","false",True,False):
        wh.append("is_exclusive = :is_exclusive"); params["is_exclusive"] = (p.get("is_exclusive") in ("true", True))
    q=p.get("q")
    if q:
        qq=f"%{q}%"; wh.append("(notes ILIKE :qq OR network_name ILIKE :qq OR mccmnc ILIKE :qq)"); params["qq"]=qq
    return " AND ".join(wh), params

@router.get("/offers/")
def list_offers(response: Response, limit:int=50, offset:int=0, **filters):
    with SessionLocal() as db:
        where, params = where_from_filters(filters)
        total = db.execute(text(f"SELECT COUNT(*) FROM offers WHERE {where}"), params).scalar() or 0
        rows = db.execute(text(f"""
          SELECT id, supplier_name, connection_name, country_name, network_name, mccmnc, price, price_effective_date,
                 previous_price, route_type, known_hops, sender_id_supported, registration_required, eta_days,
                 charge_model, is_exclusive, notes, updated_by
          FROM offers WHERE {where}
          ORDER BY updated_at DESC, id DESC
          LIMIT :l OFFSET :o
        """), dict(params, l=limit, o=offset)).all()
        response.headers["X-Total-Count"] = str(total)
        return [dict(r._mapping) for r in rows]

@router.post("/offers/")
def add_offer(body: dict, user: str = Depends(get_current_user)):
    need = ["supplier_name","connection_name","price"]
    for n in need:
        if not body.get(n): raise HTTPException(400, f"{n} required")
    with SessionLocal() as db:
        db.execute(text("""
          INSERT INTO offers(supplier_name,connection_name,country_name,network_name,mccmnc,price,price_effective_date,
                             previous_price,route_type,known_hops,sender_id_supported,registration_required,eta_days,
                             charge_model,is_exclusive,notes,updated_by)
          VALUES(:s,:c,:country,:network,:mm,:p,:pe,:pp,:rt,:kh,:sid,:reg,:eta,:cm,:ex,:notes,:up)
        """), {"s":body.get("supplier_name"), "c":body.get("connection_name"),
               "country":body.get("country_name"), "network":body.get("network_name"),
               "mm":body.get("mccmnc"), "p":body.get("price"),
               "pe":body.get("price_effective_date"), "pp":body.get("previous_price"),
               "rt":body.get("route_type"), "kh":body.get("known_hops"),
               "sid":body.get("sender_id_supported"), "reg":body.get("registration_required"),
               "eta":body.get("eta_days"), "cm":body.get("charge_model"),
               "ex":body.get("is_exclusive"), "notes":body.get("notes"),
               "up":body.get("updated_by")})
        db.commit(); return {"ok": True}

@router.put("/offers/{oid}")
def update_offer(oid:int, body: dict, user: str = Depends(get_current_user)):
    sets=[]; params={"id":oid}
    for k in ("supplier_name","connection_name","country_name","network_name","mccmnc","price","price_effective_date","previous_price",
              "route_type","known_hops","sender_id_supported","registration_required","eta_days","charge_model","is_exclusive","notes","updated_by"):
        if k in body:
            sets.append(f"{k}=:{k}"); params[k]=body[k]
    if not sets: return {"ok": True}
    sets.append("updated_at=now()")
    with SessionLocal() as db:
        r=db.execute(text(f"UPDATE offers SET {', '.join(sets)} WHERE id=:id RETURNING id")).first()
        if not r: raise HTTPException(404,"Not found")
        db.commit(); return {"ok": True}

@router.delete("/offers/{oid}")
def delete_offer(oid:int, user:str=Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("DELETE FROM offers WHERE id=:i"),{"i":oid}); db.commit(); return {"ok":True}

@router.post("/offers/bulk")
def bulk_update(body: dict, user: str = Depends(get_current_user)):
    ids = body.get("ids") or []
    patch = body.get("set") or {}
    if not ids or not patch: return {"ok": True, "updated": 0}
    sets=[]; params={"ids":ids}
    for k in ("route_type","known_hops","sender_id_supported","registration_required","eta_days","charge_model","is_exclusive","notes"):
        if k in patch:
            sets.append(f"{k}=:{k}"); params[k]=patch[k]
    if not sets: return {"ok":True, "updated":0}
    sets.append("updated_at=now()")
    with SessionLocal() as db:
        r=db.execute(text(f"UPDATE offers SET {', '.join(sets)} WHERE id = ANY(:ids)"), params)
        db.commit(); return {"ok": True, "updated": r.rowcount}
PY

cat > "$ROUT/metrics.py" <<'PY'
from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
from datetime import date

router = APIRouter(tags=["Metrics"])

@router.get("/metrics/trends")
def trends(d: str | None = None, user: str = Depends(get_current_user)):
    if not d: d = date.today().isoformat()
    with SessionLocal() as db:
        rows = [dict(r._mapping) for r in db.execute(text("""
        WITH picked AS (
          SELECT COALESCE(route_type,'__UNKNOWN__') rt, COALESCE(network_name,'__UNKNOWN__') net
          FROM offers
          WHERE (price_effective_date = :d)
             OR (DATE(created_at) = :d)
             OR (DATE(updated_at) = :d)
        )
        SELECT rt, net, COUNT(*) cnt
        FROM picked
        GROUP BY rt, net
        ORDER BY rt, cnt DESC
        """), {"d": d}).all()]
    out = {"date": d, "by_route_type": {}}
    for r in rows:
        key = "Unknown" if r["rt"]=="__UNKNOWN__" else r["rt"]
        out["by_route_type"].setdefault(key, []).append({"network_name": "Unknown" if r["net"]=="__UNKNOWN__" else r["net"], "count": r["cnt"]})
    for k in list(out["by_route_type"].keys()):
        out["by_route_type"][k] = out["by_route_type"][k][:10]
    return out
PY

cat > "$ROUT/lookups.py" <<'PY'
from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
router = APIRouter(tags=["Lookups"])

def _list(sql, params):
    with SessionLocal() as db:
        return [r[0] for r in db.execute(text(sql), params).all()]

@router.get("/lookup/suppliers")
def sup(q:str|None=None, user:str=Depends(get_current_user)):
    return _list("SELECT organization_name FROM suppliers WHERE organization_name ILIKE :q ORDER BY 1 LIMIT 20", {"q": f"%{q or ''}%"})

@router.get("/lookup/connections")
def con(q:str|None=None, supplier_name:str|None=None, user:str=Depends(get_current_user)):
    if supplier_name:
        with SessionLocal() as db:
            sid = db.execute(text("SELECT id FROM suppliers WHERE organization_name ILIKE :n"), {"n": supplier_name}).scalar()
            if not sid: return []
            return [r[0] for r in db.execute(text("SELECT connection_name FROM supplier_connections WHERE supplier_id=:sid AND connection_name ILIKE :q ORDER BY 1 LIMIT 20"), {"sid":sid,"q": f"%{q or ''}%"}).all()]
    return _list("SELECT connection_name FROM supplier_connections WHERE connection_name ILIKE :q ORDER BY 1 LIMIT 20", {"q": f"%{q or ''}%"})

@router.get("/lookup/countries")
def cou(q:str|None=None, user:str=Depends(get_current_user)):
    return _list("SELECT name FROM countries WHERE name ILIKE :q ORDER BY 1 LIMIT 20", {"q": f"%{q or ''}%"})

@router.get("/lookup/networks")
def net(q:str|None=None, country_name:str|None=None, user:str=Depends(get_current_user)):
    if country_name:
        return _list("SELECT name FROM networks WHERE country_name ILIKE :c AND name ILIKE :q ORDER BY 1 LIMIT 20", {"c": f"%{country_name}%", "q": f"%{q or ''}%"})
    return _list("SELECT name FROM networks WHERE name ILIKE :q ORDER BY 1 LIMIT 20", {"q": f"%{q or ''}%"})
PY

cat > "$ROUT/parsers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
router = APIRouter(tags=["Parsers"])

@router.get("/parsers/")
def list_all(user:str=Depends(get_current_user)):
    with SessionLocal() as db:
        rows = db.execute(text("SELECT id,name,description,html,active FROM parser_templates ORDER BY name")).all()
        return [dict(r._mapping) for r in rows]

@router.post("/parsers/")
def create(body:dict, user:str=Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("INSERT INTO parser_templates(name,description,html,active) VALUES(:n,:d,:h,:a)"),
                   {"n":body.get("name"),"d":body.get("description"),"h":body.get("html") or "", "a":bool(body.get("active"))})
        db.commit(); return {"ok":True}

@router.put("/parsers/{pid}")
def update(pid:int, body:dict, user:str=Depends(get_current_user)):
    sets=[]; params={"id":pid}
    for k in ("name","description","html","active"):
        if k in body: sets.append(f"{k}=:{k}"); params[k]=body[k]
    if not sets: return {"ok":True}
    with SessionLocal() as db:
        r=db.execute(text(f"UPDATE parser_templates SET {', '.join(sets)} WHERE id=:id RETURNING id")).first()
        if not r: raise HTTPException(404,"Not found")
        db.commit(); return {"ok":True}

@router.delete("/parsers/{pid}")
def delete(pid:int, user:str=Depends(get_current_user)):
    with SessionLocal() as db:
        db.execute(text("DELETE FROM parser_templates WHERE id=:i"),{"i":pid})
        db.commit(); return {"ok":True}
PY

########################
# main.py
########################
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate
from app.routers import users, suppliers, countries, networks, offers, conf, metrics, lookups, parsers

app = FastAPI(title="SMS Procurement Manager", version="0.3.0")

origins = ["http://localhost:5183","http://127.0.0.1:5183","*"]
app.add_middleware(CORSMiddleware,
    allow_origins=origins, allow_credentials=True, allow_methods=["*"], allow_headers=["*"]
)

migrate()

app.include_router(users.router)
app.include_router(conf.router)
app.include_router(lookups.router)
app.include_router(suppliers.router)
app.include_router(countries.router)
app.include_router(networks.router)
app.include_router(offers.router)
app.include_router(metrics.router)
app.include_router(parsers.router)

@app.get("/")
def root():
    return {"message":"OK","version":"0.3.0"}
PY

########################
# Web UI (Nginx)
########################
cat > "$WEB/Dockerfile" <<'DOCKER'
FROM nginx:alpine
COPY public /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
RUN chown -R nginx:nginx /usr/share/nginx/html
DOCKER

cat > "$WEB/nginx.conf" <<'NGX'
events {}
http {
  include       mime.types;
  default_type  application/octet-stream;
  sendfile      on;
  server {
    listen 80;
    server_name _;
    add_header Cache-Control "no-cache";
    location / { root /usr/share/nginx/html; index index.html; try_files $uri /index.html; }
  }
}
NGX

cat > "$WEBPUB/index.html" <<'HTML'
<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
<link rel="stylesheet" href="main.css"/>
</head>
<body>
<header>
  <div class="brand">SMS Procurement Manager</div>
  <div class="user">
    <span id="userLbl">User: <b id="userName">-</b></span>
    <button id="logoutBtn" class="btn btn-red small" style="display:none">Logout</button>
    <button id="apiBtn" class="btn small">API</button>
  </div>
</header>

<nav>
  <button data-view="trends">Market trends</button>
  <button data-view="offers">Offers</button>
  <button data-view="suppliers">Suppliers</button>
  <button data-view="connections">Connections</button>
  <button data-view="countries">Countries</button>
  <button data-view="networks">Networks</button>
  <button data-view="parsers">Parsers</button>
  <button data-view="settings">Settings</button>
  <span id="apiBaseInfo" class="muted"></span>
</nav>

<section id="filters"></section>
<section id="view"></section>

<div id="apiModal" class="modal" style="display:none">
  <div class="modal-card">
    <h3>Configure API</h3>
    <label>API Base</label>
    <input id="apiInput" placeholder="http://localhost:8010"/>
    <div class="row right"><button id="apiSave" class="btn btn-blue">Save</button> <button id="apiClose" class="btn">Close</button></div>
  </div>
</div>

<div id="loginModal" class="modal" style="display:none">
  <div class="modal-card">
    <h3>Login</h3>
    <label>Username</label><input id="user"/>
    <label>Password</label><input id="pass" type="password"/>
    <div class="row">
      <button id="loginBtn" class="btn btn-green">Login</button>
      <span id="loginMsg" class="muted"></span>
    </div>
  </div>
</div>

<script src="main.js"></script>
</body>
</html>
HTML

cat > "$WEBPUB/main.css" <<'CSS'
*{box-sizing:border-box;font-family:system-ui,Segoe UI,Roboto,Arial}
body{margin:0;background:#0b0f14;color:#e6edf3}
header{display:flex;justify-content:space-between;align-items:center;padding:10px 14px;background:#111827;border-bottom:1px solid #1f2937}
.brand{font-weight:700}
.user{display:flex;gap:8px;align-items:center}
nav{display:flex;gap:8px;align-items:center;padding:8px 14px;border-bottom:1px solid #1f2937;background:#0f172a;flex-wrap:wrap}
nav button{background:#1f2937;color:#e6edf3;border:1px solid #374151;border-radius:8px;padding:6px 10px;cursor:pointer}
nav button.active{outline:2px solid #2563eb}
section#filters, section#view{padding:14px}
.card{background:#0f172a;border:1px solid #1f2937;border-radius:10px;padding:12px;margin-bottom:12px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.right{justify-content:flex-end}
input,select,textarea{background:#111827;color:#e6edf3;border:1px solid #374151;border-radius:8px;padding:8px;min-width:180px}
label{font-size:12px;color:#9ca3af;display:block;margin:8px 0 4px}
table{width:100%;border-collapse:collapse}
th,td{border-bottom:1px solid #1f2937;padding:8px;text-align:left}
.actions button{margin-right:4px}
.muted{opacity:.7}
.btn{background:#1f2937;border:1px solid #374151;border-radius:8px;color:#e6edf3;padding:6px 10px;cursor:pointer}
.btn-green{background:#065f46;border-color:#065f46}
.btn-blue{background:#1d4ed8;border-color:#1d4ed8}
.btn-yellow{background:#92400e;border-color:#92400e}
.btn-red{background:#7f1d1d;border-color:#7f1d1d}
.small{padding:4px 8px;font-size:12px}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center}
.modal-card{background:#0f172a;border:1px solid #1f2937;border-radius:12px;padding:16px;width:min(680px,96vw)}
.barwrap{display:flex;gap:8px;align-items:flex-end;height:200px;padding:8px;border:1px dashed #1f2937;border-radius:8px}
.bar{width:48px;background:#2563eb;display:flex;align-items:end;justify-content:center;border-radius:6px}
.bar span{font-size:11px;margin-bottom:4px}
legend-badge{padding:2px 6px;background:#1f2937;border-radius:999px}
.details-row{padding:8px;background:#0b1220;border:1px solid #172034;border-radius:8px;margin:8px 0}
.pager{display:flex;gap:8px;align-items:center}
.checkbox{width:18px;height:18px}
CSS

cat > "$WEBPUB/main.js" <<'JS'
const $ = s=>document.querySelector(s);
const tokenKey='SPM_TOKEN', apiKey='API_BASE';
let API_BASE = localStorage.getItem(apiKey) || 'http://localhost:8010';
let TOKEN = localStorage.getItem(tokenKey) || '';

function navActivate(v){ document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('active', b.dataset.view===v)); }
function setAPIInfo(){ $('#apiBaseInfo').textContent = API_BASE; }
function setUser(u){ $('#userName').textContent = u || '-'; $('#logoutBtn').style.display = u ? '' : 'none'; }

async function authFetch(path, opts={}){
  const url = API_BASE.replace(/\/$/,'') + path;
  const headers = opts.headers || {};
  if (TOKEN) headers['Authorization'] = 'Bearer '+TOKEN;
  if (opts.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
  opts.headers = headers;
  const r = await fetch(url, opts);
  if (!r.ok) {
    const t = await r.text().catch(()=>String(r.status));
    throw new Error(`${r.status} ${t}`);
  }
  const ct = r.headers.get('content-type')||'';
  return ct.includes('application/json') ? r.json() : r.text();
}
async function verifyToken(){ if(!TOKEN) return false; try{ await authFetch('/users/me'); return true; }catch{ localStorage.removeItem(tokenKey); TOKEN=''; return false; } }
function onEnter(selector, fn){ document.querySelectorAll(selector).forEach(el=>el.addEventListener('keydown', e=>{ if(e.key==='Enter'){ e.preventDefault(); fn(); } })); }

function openLogin(){ $('#loginModal').style.display='flex'; }
function closeLogin(){ $('#loginModal').style.display='none'; }
$('#loginBtn').onclick = async ()=>{
  try{
    const form = new URLSearchParams(); form.append('username',$('#user').value); form.append('password',$('#pass').value);
    const r = await fetch(API_BASE.replace(/\/$/,'') + '/users/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:form});
    if(!r.ok){ $('#loginMsg').textContent='Login failed'; return; }
    const j = await r.json(); TOKEN=j.access_token; localStorage.setItem(tokenKey,TOKEN); setUser($('#user').value||'admin'); closeLogin(); render('trends');
  }catch(e){ $('#loginMsg').textContent=e.message; }
};
$('#logoutBtn').onclick = ()=>{ localStorage.removeItem(tokenKey); TOKEN=''; setUser(''); openLogin(); };

$('#apiBtn').onclick = ()=>{ $('#apiInput').value = API_BASE; $('#apiModal').style.display='flex'; };
$('#apiClose').onclick = ()=> $('#apiModal').style.display='none';
$('#apiSave').onclick = ()=>{ API_BASE = $('#apiInput').value.trim() || API_BASE; localStorage.setItem(apiKey, API_BASE); setAPIInfo(); $('#apiModal').style.display='none'; };

async function viewTrends(){
  navActivate('trends');
  $('#filters').innerHTML = `<div class="card row"><label>Date</label><input id="tDate" type="date"/><button id="tGo" class="btn btn-blue">Search</button></div>`;
  $('#view').innerHTML = `<div class="card"><div>Loading…</div></div>`;
  const today = new Date().toISOString().slice(0,10); $('#tDate').value = $('#tDate').value || today;
  const go = async ()=>{
    const d=$('#tDate').value || today;
    const data = await authFetch(`/metrics/trends?d=${encodeURIComponent(d)}`);
    const keys=Object.keys(data.by_route_type||{});
    let html = '';
    for(const rt of [...keys.filter(k=>k!=='Unknown'), ...keys.filter(k=>'Unknown'===k)]){
      const arr=data.by_route_type[rt]||[]; const max=Math.max(1,...arr.map(x=>x.count));
      html += `<div class="card"><h3>${rt}</h3><div class="barwrap">${
        arr.map(x=>`<div class="bar" title="${x.network_name} = ${x.count}" style="height:${Math.round((x.count/max)*180)+20}px"><span>${x.count}</span></div>`).join('')
      }</div><div class="legend">${
        arr.map(x=>`<legend-badge>${x.network_name}</legend-badge>`).join('')
      }</div></div>`;
    }
    $('#view').innerHTML = html || '<div class="card">No data.</div>';
  };
  $('#tGo').onclick = go; onEnter('#filters input', go); await go();
}

let OffersPager={limit:50,offset:0,total:0}, pageData=[], selectedIds=new Set();
function setLookups(selector, path){
  const input = document.querySelector(selector); const dl = document.querySelector(input.getAttribute('list'));
  input.addEventListener('input', async ()=>{ const q=input.value; try{ const arr = await authFetch(path+'?q='+encodeURIComponent(q)); dl.innerHTML = arr.map(v=>`<option value="${v}">`).join(''); }catch{} });
}
function filtersQS(){
  const p=new URLSearchParams();
  const map = { '#of_sup':'supplier_name','#of_con':'connection_name','#of_country':'country','#of_net':'network_name','#of_mm':'mccmnc','#of_route':'route_type','#of_hops':'known_hops','#of_sid':'sender_id_supported','#of_reg':'registration_required' };
  for(const sel in map){ const v=(document.querySelector(sel).value||'').trim(); if(v) p.set(map[sel], v); }
  const ex=$('#of_ex').value.trim(); if(ex) p.set('is_exclusive', ex);
  p.set('limit', OffersPager.limit); p.set('offset', OffersPager.offset);
  return p.toString();
}
async function loadOffers(reset=false){
  if(reset){ OffersPager.offset=0; selectedIds.clear(); }
  const qs = filtersQS();
  const r = await fetch(API_BASE.replace(/\/$/,'') + '/offers/?' + qs, {headers:{'Authorization':'Bearer '+TOKEN}});
  const total = parseInt(r.headers.get('X-Total-Count')||'0',10); const rows = await r.json(); OffersPager.total=total; pageData=rows;
  $('#pageInfo').textContent = `Total ${total} • showing ${rows.length} (offset ${OffersPager.offset})`;
  $('#view').innerHTML = `<div class="card">
    <table>
      <thead><tr>
        <th><input type="checkbox" id="selHead"></th>
        <th>Supplier</th><th>Connection</th><th>Country</th><th>Network</th><th>MCCMNC</th>
        <th>Price</th><th>Eff.</th><th>Prev</th><th>Route</th><th>Hops</th><th>Sender</th>
        <th>Reg</th><th>ETA</th><th>Charge</th><th>Exclusive</th><th>Notes</th><th></th>
      </tr></thead>
      <tbody>${
        rows.map(o=>`<tr>
          <td><input type="checkbox" class="rowchk" data-id="${o.id}" ${selectedIds.has(o.id)?'checked':''}></td>
          <td>${o.supplier_name}</td><td>${o.connection_name}</td><td>${o.country_name||''}</td><td>${o.network_name||''}</td><td>${o.mccmnc||''}</td>
          <td>${o.price}</td><td>${o.price_effective_date||''}</td><td>${o.previous_price??''}</td>
          <td>${o.route_type||''}</td><td>${o.known_hops||''}</td><td>${o.sender_id_supported||''}</td>
          <td>${o.registration_required||''}</td><td>${o.eta_days??''}</td><td>${o.charge_model||''}</td>
          <td>${o.is_exclusive?'Yes':'No'}</td><td>${o.notes||''}</td>
          <td class="actions"><button class="btn btn-yellow" data-act="edit" data-id="${o.id}">Edit</button>
                              <button class="btn btn-red" data-act="del" data-id="${o.id}">Delete</button></td>
        </tr>`).join('')
      }</tbody></table></div>`;
  $('#selHead').onclick = (e)=>{ document.querySelectorAll('.rowchk').forEach(c=>{ c.checked=e.target.checked; c.dispatchEvent(new Event('change')); }); };
  document.querySelectorAll('.rowchk').forEach(c=> c.onchange = ()=>{ const id=parseInt(c.dataset.id,10); if(c.checked) selectedIds.add(id); else selectedIds.delete(id); });
  document.querySelectorAll('button[data-act="del"]').forEach(b=> b.onclick = async ()=>{ if(!confirm('Delete?')) return; await authFetch('/offers/'+b.dataset.id,{method:'DELETE'}); loadOffers(); });
  document.querySelectorAll('button[data-act="edit"]').forEach(b=> b.onclick = ()=> openOfferEditor(b.dataset.id));
}
async function selectAllOnPage(state){ document.querySelectorAll('.rowchk').forEach(c=>{ c.checked=state; c.dispatchEvent(new Event('change')); }); }
async function selectAllAcross(){ const qs=filtersQS().replace(/limit=\d+/,'limit=1000').replace(/offset=\d+/,'offset=0'); const all=await authFetch('/offers/?'+qs); selectedIds=new Set(all.map(x=>x.id)); loadOffers(); }
async function bulkUpdateSelected(){
  if(selectedIds.size===0){ alert('No rows selected'); return; }
  const field = prompt('Field to set (route_type, known_hops, registration_required, sender_id_supported, eta_days, charge_model, is_exclusive, notes):');
  if(!field) return; let val = prompt('Value (true/false for is_exclusive; integer for eta_days; text for others):','');
  if(field==='is_exclusive'){ val=(val==='true'); } else if(field==='eta_days'){ val=val?parseInt(val,10):null; }
  await authFetch('/offers/bulk',{method:'POST', body:JSON.stringify({ids:Array.from(selectedIds), set:{[field]:val}})}); await loadOffers();
}
async function openOfferEditor(id){
  const o = pageData.find(x=> String(x.id)===String(id)); if(!o){ alert('Row not found'); return; }
  const html = `<div class="card"><h3>Edit Offer #${o.id}</h3>
    <div class="row">
      <div><label>Supplier</label><input id="e_sup" value="${o.supplier_name||''}" list="dl_sup"/></div>
      <div><label>Connection</label><input id="e_con" value="${o.connection_name||''}" list="dl_con"/></div>
      <div><label>Country</label><input id="e_country" value="${o.country_name||''}" list="dl_cty"/></div>
      <div><label>Network</label><input id="e_net" value="${o.network_name||''}" list="dl_net"/></div>
      <div><label>MCCMNC</label><input id="e_mm" value="${o.mccmnc||''}"/></div>
      <div><label>Price</label><input id="e_price" type="number" step="0.0001" value="${o.price}"/></div>
      <div><label>Effective date</label><input id="e_eff" type="date" value="${o.price_effective_date||''}"/></div>
      <div><label>Prev price</label><input id="e_prev" type="number" step="0.0001" value="${o.previous_price??''}"/></div>
      <div><label>Route</label><input id="e_route" value="${o.route_type||''}"/></div>
      <div><label>Hops</label><input id="e_hops" value="${o.known_hops||''}"/></div>
      <div><label>Sender ID</label><input id="e_sid" value="${o.sender_id_supported||''}"/></div>
      <div><label>Registration</label><input id="e_reg" value="${o.registration_required||''}"/></div>
      <div><label>ETA days</label><input id="e_eta" type="number" value="${o.eta_days??''}"/></div>
      <div><label>Charge model</label><input id="e_charge" value="${o.charge_model||''}"/></div>
      <div><label>Exclusive</label><select id="e_ex"><option value=""></option><option ${o.is_exclusive?'selected':''} value="true">Yes</option><option ${!o.is_exclusive?'selected':''} value="false">No</option></select></div>
      <div><label>Notes</label><input id="e_notes" value="${o.notes||''}"/></div>
    </div>
    <div class="row right"><button id="e_save" class="btn btn-yellow">Save</button> <button id="e_cancel" class="btn">Cancel</button></div>
  </div>
  <datalist id="dl_sup"></datalist><datalist id="dl_con"></datalist><datalist id="dl_cty"></datalist><datalist id="dl_net"></datalist>`;
  $('#view').insertAdjacentHTML('afterbegin', html);
  setLookups('#e_sup','/lookup/suppliers'); setLookups('#e_con','/lookup/connections'); setLookups('#e_country','/lookup/countries'); setLookups('#e_net','/lookup/networks');
  $('#e_cancel').onclick = ()=> loadOffers();
  $('#e_save').onclick = async ()=>{
    const body = {
      supplier_name: $('#e_sup').value.trim(), connection_name: $('#e_con').value.trim(),
      country_name: $('#e_country').value.trim()||null, network_name: $('#e_net').value.trim()||null,
      mccmnc: $('#e_mm').value.trim()||null, price: parseFloat($('#e_price').value),
      price_effective_date: $('#e_eff').value||null, previous_price: ($('#e_prev').value?parseFloat($('#e_prev').value):null),
      route_type: $('#e_route').value||null, known_hops: $('#e_hops').value||null,
      sender_id_supported: $('#e_sid').value||null, registration_required: $('#e_reg').value||null,
      eta_days: ($('#e_eta').value?parseInt($('#e_eta').value,10):null), charge_model: $('#e_charge').value||null,
      is_exclusive: ($('#e_ex').value===''?null:($('#e_ex').value==='true')), notes: $('#e_notes').value||null,
      updated_by: $('#userName').textContent||'admin'
    };
    await authFetch('/offers/'+o.id,{method:'PUT', body:JSON.stringify(body)}); await loadOffers();
  };
}

async function viewOffers(){
  navActivate('offers');
  $('#filters').innerHTML = `
  <div class="card">
    <div class="row">
      <div><label>Supplier</label><input id="of_sup" list="dl_sup"/></div>
      <div><label>Connection</label><input id="of_con" list="dl_con"/></div>
      <div><label>Country</label><input id="of_country" list="dl_cty"/></div>
      <div><label>Network</label><input id="of_net" list="dl_net"/></div>
      <div><label>MCCMNC</label><input id="of_mm"/></div>
      <div><label>Route</label><input id="of_route"/></div>
      <div><label>Hops</label><input id="of_hops"/></div>
      <div><label>Sender ID</label><input id="of_sid"/></div>
      <div><label>Registration</label><input id="of_reg"/></div>
      <div><label>Exclusive</label><select id="of_ex"><option value=""></option><option>true</option><option>false</option></select></div>
    </div>
    <div class="row">
      <button id="ofSearch" class="btn btn-blue">Search</button>
      <select id="pageSize"><option>10</option><option selected>50</option><option>100</option><option>1000</option></select>
      <div class="pager"><button id="prevPage" class="btn">Prev</button><span id="pageInfo" class="muted"></span><button id="nextPage" class="btn">Next</button></div>
      <button id="bulkBtn" class="btn btn-yellow">Bulk update selected</button>
      <button id="selAllPage" class="btn">Select page</button>
      <button id="selAllAll" class="btn">Select ALL</button>
    </div>
  </div>
  <datalist id="dl_sup"></datalist><datalist id="dl_con"></datalist><datalist id="dl_cty"></datalist><datalist id="dl_net"></datalist>
  <div class="card">
    <h3>Create new offer</h3>
    <div class="row">
      <div><label>Supplier</label><input id="nf_sup" list="dl_sup"/></div>
      <div><label>Connection</label><input id="nf_con" list="dl_con"/></div>
      <div><label>Country</label><input id="nf_country" list="dl_cty"/></div>
      <div><label>Network</label><input id="nf_net" list="dl_net"/></div>
      <div><label>MCCMNC</label><input id="nf_mm"/></div>
      <div><label>Price</label><input id="nf_price" type="number" step="0.0001"/></div>
      <div><label>Effective date</label><input id="nf_eff" type="date"/></div>
      <div><label>Prev price</label><input id="nf_prev" type="number" step="0.0001"/></div>
      <div><label>Route</label><input id="nf_route"/></div>
      <div><label>Hops</label><input id="nf_hops"/></div>
      <div><label>Sender ID</label><input id="nf_sid"/></div>
      <div><label>Registration</label><input id="nf_reg"/></div>
      <div><label>ETA days</label><input id="nf_eta" type="number"/></div>
      <div><label>Charge model</label><input id="nf_charge"/></div>
      <div><label>Exclusive</label><select id="nf_ex"><option value=""></option><option value="true">Yes</option><option value="false">No</option></select></div>
      <div><label>Notes</label><input id="nf_notes"/></div>
    </div>
    <div class="row right"><button id="nf_create" class="btn btn-green">Create</button></div>
  </div>`;
  setLookups('#of_sup','/lookup/suppliers'); setLookups('#of_con','/lookup/connections'); setLookups('#of_country','/lookup/countries'); setLookups('#of_net','/lookup/networks');
  onEnter('#filters input', ()=> loadOffers(true)); $('#ofSearch').onclick = ()=> loadOffers(true);
  $('#pageSize').onchange = ()=>{ OffersPager.limit=parseInt($('#pageSize').value,10); OffersPager.offset=0; loadOffers(); };
  $('#prevPage').onclick = ()=>{ OffersPager.offset=Math.max(0,OffersPager.offset-OffersPager.limit); loadOffers(); };
  $('#nextPage').onclick = ()=>{ if(OffersPager.offset+OffersPager.limit<OffersPager.total){ OffersPager.offset+=OffersPager.limit; loadOffers(); } };
  $('#selAllPage').onclick = ()=> selectAllOnPage(true); $('#selAllAll').onclick = ()=> selectAllAcross();
  $('#bulkBtn').onclick = bulkUpdateSelected;
  $('#nf_create').onclick = async ()=>{
    const body = {
      supplier_name: $('#nf_sup').value.trim(), connection_name: $('#nf_con').value.trim(),
      country_name: $('#nf_country').value.trim()||null, network_name: $('#nf_net').value.trim()||null, mccmnc: $('#nf_mm').value.trim()||null,
      price: parseFloat($('#nf_price').value), price_effective_date: $('#nf_eff').value||null, previous_price: ($('#nf_prev').value?parseFloat($('#nf_prev').value):null),
      route_type: $('#nf_route').value||null, known_hops: $('#nf_hops').value||null, sender_id_supported: $('#nf_sid').value||null, registration_required: $('#nf_reg').value||null,
      eta_days: ($('#nf_eta').value?parseInt($('#nf_eta').value,10):null), charge_model: $('#nf_charge').value||null, is_exclusive: ($('#nf_ex').value===''?null:($('#nf_ex').value==='true')),
      notes: $('#nf_notes').value||null, updated_by: $('#userName').textContent||'admin'
    };
    if(!body.supplier_name || !body.connection_name || isNaN(body.price)){ alert('Supplier, Connection, Price required'); return; }
    await authFetch('/offers/', {method:'POST', body: JSON.stringify(body)}); await loadOffers(true);
  };
  OffersPager.limit=parseInt($('#pageSize').value,10); OffersPager.offset=0; await loadOffers(true);
}

async function viewSuppliers(){
  navActivate('suppliers');
  $('#filters').innerHTML = `<div class="card row"><input id="sq" placeholder="Search supplier…"/><button id="sf" class="btn btn-blue">Search</button><input id="snew" placeholder="New supplier name"/><button id="screate" class="btn btn-green">Create</button></div>`;
  $('#sf').onclick=renderSuppliers; onEnter('#filters input', renderSuppliers);
  $('#screate').onclick = async ()=>{ const n=$('#snew').value.trim(); if(!n) return; await authFetch('/suppliers/',{method:'POST',body:JSON.stringify({organization_name:n})}); $('#snew').value=''; renderSuppliers(); };
  await renderSuppliers();
}
async function renderSuppliers(){
  const q=$('#sq').value.trim();
  const list = await authFetch('/suppliers/'+(q?`?q=${encodeURIComponent(q)}`:''));
  $('#view').innerHTML = `<div class="card">${
    list.map(s=>`<details>
      <summary><b>${s.organization_name}</b>
        <span class="actions"><button class="btn btn-yellow" data-act="rn" data-id="${s.id}" data-name="${s.organization_name}">Rename</button>
        <button class="btn btn-red" data-act="del" data-name="${s.organization_name}">Delete</button></span>
      </summary>
      <div class="details-row" id="cbox-${s.id}">
        <div class="row">
          <input id="cname-${s.id}" placeholder="Connection name"/>
          <input id="cuser-${s.id}" placeholder="Kannel username"/>
          <input id="csmsc-${s.id}" placeholder="Kannel SMSc"/>
          <label><input type="checkbox" id="cpd-${s.id}"/> Per Delivered</label>
          <select id="ccm-${s.id}"><option>Per Submitted</option><option>Per Delivered</option></select>
          <button class="btn btn-green" id="cadd-${s.id}">Add</button>
        </div>
        <div id="ctable-${s.id}"></div>
      </div>
    </details>`).join('')
  }</div>`;
  $('#view').querySelectorAll('button[data-act="del"]').forEach(b=> b.onclick = async ()=>{ if(!confirm('Delete supplier?')) return; await authFetch('/suppliers/'+encodeURIComponent(b.dataset.name),{method:'DELETE'}); renderSuppliers(); });
  $('#view').querySelectorAll('button[data-act="rn"]').forEach(b=> b.onclick = async ()=>{ const nv=prompt('Rename', b.dataset.name); if(!nv) return; await authFetch('/suppliers/'+encodeURIComponent(b.dataset.name),{method:'PUT',body:JSON.stringify({organization_name:nv})}); renderSuppliers(); });
  for(const s of list){ await loadConnectionsPanel(s); }
}
async function loadConnectionsPanel(s){
  const dst = '#ctable-'+s.id;
  const list = await authFetch('/suppliers/'+encodeURIComponent(s.organization_name)+'/connections/');
  $(dst).innerHTML = `<table><thead><tr><th>Name</th><th>Username</th><th>SMSc</th><th>Per Delivered</th><th>Charge</th><th></th></tr></thead><tbody>${
    list.map(c=>`<tr>
      <td>${c.connection_name}</td><td>${c.username||''}</td><td>${c.kannel_smsc||''}</td><td>${c.per_delivered?'Yes':'No'}</td><td>${c.charge_model||''}</td>
      <td class="actions"><button class="btn btn-yellow" data-act="edit" data-n="${c.connection_name}">Edit inline</button>
      <button class="btn btn-red" data-act="del" data-n="${c.connection_name}">Delete</button></td></tr>
      <tr><td colspan="6"><div class="details-row" id="cedit-${s.id}-${c.connection_name}" style="display:none">
        <div class="row">
          <label>Name</label><input id="en-${s.id}" value="${c.connection_name}">
          <label>Username</label><input id="eu-${s.id}" value="${c.username||''}">
          <label>SMSc</label><input id="ek-${s.id}" value="${c.kannel_smsc||''}">
          <label>Per Delivered</label><input type="checkbox" id="ep-${s.id}" ${c.per_delivered?'checked':''}>
          <label>Charge</label><input id="ec-${s.id}" value="${c.charge_model||''}">
          <button class="btn btn-yellow" data-act="save" data-n="${c.connection_name}">Save</button>
        </div></div></td></tr>`).join('')
  }</tbody></table>`;
  $('#cadd-'+s.id).onclick = async ()=>{
    const body={connection_name:$('#cname-'+s.id).value.trim(), username:$('#cuser-'+s.id).value.trim()||null, kannel_smsc:$('#csmsc-'+s.id).value.trim()||null, per_delivered:$('#cpd-'+s.id).checked, charge_model:$('#ccm-'+s.id).value};
    if(!body.connection_name) return; await authFetch('/suppliers/'+encodeURIComponent(s.organization_name)+'/connections/', {method:'POST', body:JSON.stringify(body)}); await loadConnectionsPanel(s);
  };
  $(dst).querySelectorAll('button[data-act="edit"]').forEach(b=> b.onclick = ()=>{ const p=$('#cedit-'+s.id+'-'+b.dataset.n); p.style.display = p.style.display==='none'?'':'none'; });
  $(dst).querySelectorAll('button[data-act="del"]').forEach(b=> b.onclick = async ()=>{ if(!confirm('Delete connection?')) return; await authFetch('/suppliers/'+encodeURIComponent(s.organization_name)+'/connections/'+encodeURIComponent(b.dataset.n),{method:'DELETE'}); await loadConnectionsPanel(s); });
  $(dst).querySelectorAll('button[data-act="save"]').forEach(b=> b.onclick = async ()=>{
    const body={connection_name:$('#en-'+s.id).value.trim(), username:$('#eu-'+s.id).value.trim()||null, kannel_smsc:$('#ek-'+s.id).value.trim()||null, per_delivered:$('#ep-'+s.id).checked, charge_model:$('#ec-'+s.id).value.trim()||null};
    await authFetch('/suppliers/'+encodeURIComponent(s.organization_name)+'/connections/'+encodeURIComponent(b.dataset.n),{method:'PUT', body:JSON.stringify(body)}); await loadConnectionsPanel(s);
  });
}

async function viewConnections(){
  navActivate('connections');
  $('#filters').innerHTML = `<div class="card row"><label>Supplier</label><input id="sq" placeholder="Supplier name"/><label>Search</label><input id="cq" placeholder="contains…"/><button id="cf" class="btn btn-blue">Search</button></div>`;
  onEnter('#filters input', renderConnections); $('#cf').onclick = renderConnections; await renderConnections();
}
async function renderConnections(){
  const s=$('#sq').value.trim(); const q=$('#cq').value.trim();
  if(!s){ $('#view').innerHTML = '<div class="card">Type a supplier name</div>'; return; }
  const arr = await authFetch('/suppliers/'+encodeURIComponent(s)+'/connections/'+(q?`?q=${encodeURIComponent(q)}`:''));
  $('#view').innerHTML = `<div class="card"><table><thead><tr><th>Name</th><th>Username</th><th>SMSc</th><th>Per Delivered</th><th>Charge</th></tr></thead><tbody>${
    arr.map(c=>`<tr><td>${c.connection_name}</td><td>${c.username||''}</td><td>${c.kannel_smsc||''}</td><td>${c.per_delivered?'Yes':'No'}</td><td>${c.charge_model||''}</td></tr>`).join('')
  }</tbody></table></div>`;
}

async function viewCountries(){
  navActivate('countries');
  $('#filters').innerHTML = `<div class="card row">
    <input id="cq" placeholder="Search country…"/><button id="cF" class="btn btn-blue">Search</button>
    <label>Name</label><input id="cName"/><label>MCC</label><input id="cMcc"/><label>2nd MCC</label><input id="cMcc2"/><label>3rd MCC</label><input id="cMcc3"/>
    <button id="cCreate" class="btn btn-green">Create</button></div>`;
  onEnter('#filters input', renderCountries); $('#cF').onclick = renderCountries;
  $('#cCreate').onclick = async ()=>{ const body={name:$('#cName').value.trim(), mcc:$('#cMcc').value.trim()||null, mcc2:$('#cMcc2').value.trim()||null, mcc3:$('#cMcc3').value.trim()||null}; if(!body.name) return; await authFetch('/countries/',{method:'POST', body:JSON.stringify(body)}); $('#cName').value='';$('#cMcc').value='';$('#cMcc2').value='';$('#cMcc3').value=''; renderCountries(); };
  await renderCountries();
}
async function renderCountries(){
  const q=$('#cq').value.trim();
  const list = await authFetch('/countries/'+(q?`?q=${encodeURIComponent(q)}`:''));
  $('#view').innerHTML = `<div class="card"><table><thead><tr><th>Name</th><th>MCC</th><th>2nd MCC</th><th>3rd MCC</th><th></th></tr></thead><tbody>${
    list.map(c=>`<tr><td>${c.name}</td><td>${c.mcc||''}</td><td>${c.mcc2||''}</td><td>${c.mcc3||''}</td>
      <td class="actions"><button class="btn btn-yellow" data-act="edit" data-name="${c.name}">Edit</button><button class="btn btn-red" data-act="del" data-name="${c.name}">Delete</button></td></tr>
      <tr><td colspan="5"><div class="details-row" id="ced-${c.name}" style="display:none">
        <div class="row"><label>Name</label><input id="e_name_${c.name}" value="${c.name}">
        <label>MCC</label><input id="e_mcc_${c.name}" value="${c.mcc||''}">
        <label>2nd MCC</label><input id="e_mcc2_${c.name}" value="${c.mcc2||''}">
        <label>3rd MCC</label><input id="e_mcc3_${c.name}" value="${c.mcc3||''}">
        <button class="btn btn-yellow" data-act="save" data-name="${c.name}">Save</button></div></div></td></tr>`).join('')
  }</tbody></table></div>`;
  $('#view').querySelectorAll('button[data-act="del"]').forEach(b=> b.onclick = async ()=>{ if(!confirm('Delete?')) return; await authFetch('/countries/'+encodeURIComponent(b.dataset.name),{method:'DELETE'}); renderCountries(); });
  $('#view').querySelectorAll('button[data-act="edit"]').forEach(b=> b.onclick = ()=>{ const d=$('#ced-'+b.dataset.name); d.style.display = d.style.display==='none'?'':'none'; });
  $('#view').querySelectorAll('button[data-act="save"]').forEach(b=> b.onclick = async ()=>{
    const nm=$('#e_name_'+b.dataset.name).value; const m=$('#e_mcc_'+b.dataset.name).value; const m2=$('#e_mcc2_'+b.dataset.name).value; const m3=$('#e_mcc3_'+b.dataset.name).value;
    await authFetch('/countries/'+encodeURIComponent(b.dataset.name),{method:'PUT', body:JSON.stringify({name:nm,mcc:m,mcc2:m2,mcc3:m3})}); renderCountries();
  });
}

async function viewNetworks(){
  navActivate('networks');
  $('#filters').innerHTML = `<div class="card row">
    <label>Search name</label><input id="nq"><label>Country</label><input id="nc" list="dl_cty"><label>MCCMNC</label><input id="nmm">
    <button id="nF" class="btn btn-blue">Search</button>
    <label>Name</label><input id="nn"><label>Country</label><input id="ncountry" list="dl_cty"><label>MNC</label><input id="nmnc">
    <button id="nCreate" class="btn btn-green">Create</button></div>`;
  onEnter('#filters input', renderNetworks); $('#nF').onclick = renderNetworks;
  $('#nCreate').onclick = async ()=>{
    const body={name:$('#nn').value.trim(), country_name:$('#ncountry').value.trim()||null, mnc:$('#nmnc').value.trim()||null};
    if(!body.name) return;
    if(body.country_name){
      try{
        const arr = await authFetch('/countries/?q='+encodeURIComponent(body.country_name));
        if(arr && arr[0]){
          const m=[arr[0].mcc,arr[0].mcc2,arr[0].mcc3].filter(Boolean);
          if(m.length>1){ const pick=prompt(`Country ${arr[0].name} has multiple MCCs (${m.join(', ')}). Type the one to use:`, m[0]); if(pick) body.mcc=pick; }
          else if(m.length===1){ body.mcc=m[0]; }
        }
      }catch{}
    }
    await authFetch('/networks/',{method:'POST', body:JSON.stringify(body)}); $('#nn').value='';$('#ncountry').value='';$('#nmnc').value=''; renderNetworks();
  };
  await renderNetworks();
}
async function renderNetworks(){
  const q=$('#nq').value.trim(), c=$('#nc').value.trim(), mm=$('#nmm').value.trim();
  const arr = await authFetch('/networks/'+(q||c||mm?`?${new URLSearchParams({q:q||'',country:c||'',mccmnc:mm||''})}`:''));
  $('#view').innerHTML = `<div class="card"><table><thead><tr><th>Name</th><th>Country</th><th>MCC</th><th>MNC</th><th>MCCMNC</th><th></th></tr></thead><tbody>${
    arr.map(n=>`<tr><td>${n.name}</td><td>${n.country_name||''}</td><td>${n.mcc||''}</td><td>${n.mnc||''}</td><td>${n.mccmnc||''}</td>
      <td class="actions"><button class="btn btn-yellow" data-act="edit" data-name="${n.name}">Edit</button><button class="btn btn-red" data-act="del" data-name="${n.name}">Delete</button></td></tr>
      <tr><td colspan="6"><div class="details-row" id="ned-${n.name}" style="display:none"><div class="row">
        <label>Name</label><input id="en_${n.name}" value="${n.name}"><label>Country</label><input id="ec_${n.name}" value="${n.country_name||''}" list="dl_cty">
        <label>MCC</label><input id="em_${n.name}" value="${n.mcc||''}" readonly><label>MNC</label><input id="emn_${n.name}" value="${n.mnc||''}">
        <label>MCCMNC</label><input id="emm_${n.name}" value="${n.mccmnc||''}" readonly><button class="btn btn-yellow" data-act="save" data-name="${n.name}">Save</button>
      </div></div></td></tr>`).join('')
  }</tbody></table></div>`;
  $('#view').querySelectorAll('button[data-act="del"]').forEach(b=> b.onclick = async ()=>{ if(!confirm('Delete?')) return; await authFetch('/networks/by-name/'+encodeURIComponent(b.dataset.name),{method:'DELETE'}); renderNetworks(); });
  $('#view').querySelectorAll('button[data-act="edit"]').forEach(b=> b.onclick = ()=>{ const d=$('#ned-'+b.dataset.name); d.style.display = d.style.display==='none'?'':'none'; });
  $('#view').querySelectorAll('button[data-act="save"]').forEach(b=> b.onclick = async ()=>{
    const nm=$('#en_'+b.dataset.name).value.trim(); const c=$('#ec_'+b.dataset.name).value.trim(); const mnc=$('#emn_'+b.dataset.name).value.trim(); let mcc=$('#em_'+b.dataset.name).value.trim();
    if(c){ try{ const arr=await authFetch('/countries/?q='+encodeURIComponent(c)); if(arr && arr[0]){ const m=[arr[0].mcc,arr[0].mcc2,arr[0].mcc3].filter(Boolean); if(m.length>1 && !m.includes(mcc)){ const pick=prompt(`Country ${arr[0].name} has multiple MCCs (${m.join(', ')}). Type the one to use:`, m[0]); if(pick) mcc=pick; } else if(m.length===1){ mcc=m[0]; } } }catch{} }
    const mm = mcc && mnc ? mcc+mnc : ($('#emm_'+b.dataset.name).value||null);
    await authFetch('/networks/by-name/'+encodeURIComponent(b.dataset.name),{method:'PUT', body:JSON.stringify({name:nm, country_name:c||null, mnc:mnc||null, mcc:mcc||null, mccmnc:mm||null})}); renderNetworks();
  });
}

async function viewParsers(){
  navActivate('parsers'); $('#filters').innerHTML = '';
  const list = await authFetch('/parsers/').catch(()=>[]);
  $('#view').innerHTML = `<div class="card"><div class="row"><input id="pname" placeholder="Template name"><input id="pdesc" placeholder="Description"><button id="pcreate" class="btn btn-green">Create</button></div></div><div id="plist"></div>`;
  $('#pcreate').onclick = async ()=>{ const body={name:$('#pname').value.trim(), description:$('#pdesc').value.trim(), html:"<p>Describe your parser here</p>", active:false}; if(!body.name) return; await authFetch('/parsers/',{method:'POST', body:JSON.stringify(body)}); await viewParsers(); };
  const wrap=$('#plist');
  wrap.innerHTML = list.map(p=>`<div class="card"><h3>${p.name}</h3><div contenteditable="true" id="html_${p.id}" style="min-height:120px;border:1px dashed #1f2937;padding:8px">${p.html||''}</div>
    <div class="row right"><label><input type="checkbox" id="act_${p.id}" ${p.active?'checked':''}> Active</label>
    <button class="btn btn-yellow" data-id="${p.id}" data-act="save">Save</button><button class="btn btn-red" data-id="${p.id}" data-act="del">Delete</button></div></div>`).join('');
  wrap.querySelectorAll('button[data-act="save"]').forEach(b=> b.onclick = async ()=>{ const id=b.dataset.id; const html=$('#html_'+id).innerHTML; const active=$('#act_'+id).checked; await authFetch('/parsers/'+id,{method:'PUT', body:JSON.stringify({html,active})}); alert('Saved'); });
  wrap.querySelectorAll('button[data-act="del"]').forEach(b=> b.onclick = async ()=>{ if(!confirm('Delete?')) return; await authFetch('/parsers/'+b.dataset.id,{method:'DELETE'}); await viewParsers(); });
}

async function viewSettings(){
  navActivate('settings');
  const e = await authFetch('/conf/enums');
  const mk=(title,key,arr)=>`<div class="card"><h3>${title}</h3><div class="row" id="wrap_${key}">${arr.map((v,i)=>`<span class="legend"><input value="${v}" id="${key}_${i}"> <button class="btn btn-red small" data-k="${key}" data-i="${i}">X</button></span>`).join('')}</div><div class="row"><input id="new_${key}" placeholder="Add value"><button class="btn btn-green" data-add="${key}">Add</button></div></div>`;
  $('#filters').innerHTML=''; $('#view').innerHTML = mk('Route Type','route_type',e.route_type||[])+mk('Known Hops','known_hops',e.known_hops||[])+mk('Registration Required','registration_required',e.registration_required||[])+`<div class="row right"><button id="saveEnums" class="btn btn-blue">Save All</button></div>`;
  $('#view').querySelectorAll('button[data-add]').forEach(b=> b.onclick = ()=>{ const key=b.dataset.add; const val=$('#new_'+key).value.trim(); if(!val) return; const wrap=$('#wrap_'+key); const idx=wrap.querySelectorAll('input').length; wrap.insertAdjacentHTML('beforeend', `<span class="legend"><input value="${val}" id="${key}_${idx}"> <button class="btn btn-red small" data-k="${key}" data-i="${idx}">X</button></span>`); $('#new_'+key).value=''; });
  $('#view').addEventListener('click',(e)=>{ const t=e.target; if(t.matches('button[data-k]')){ t.parentElement.remove(); } });
  $('#saveEnums').onclick = async ()=>{ const get=(key)=> Array.from($('#wrap_'+key).querySelectorAll('input')).map(i=>i.value.trim()).filter(Boolean); const body={route_type:get('route_type'), known_hops:get('known_hops'), registration_required:get('registration_required')}; await authFetch('/conf/enums',{method:'PUT', body:JSON.stringify(body)}); alert('Saved'); };
}

function render(view){
  if(!TOKEN){ openLogin(); return; }
  switch(view){
    case 'trends': return viewTrends();
    case 'offers': return viewOffers();
    case 'suppliers': return viewSuppliers();
    case 'connections': return viewConnections();
    case 'countries': return viewCountries();
    case 'networks': return viewNetworks();
    case 'parsers': return viewParsers();
    case 'settings': return viewSettings();
  }
}
document.querySelectorAll('nav button').forEach(b=> b.onclick = ()=> render(b.dataset.view));
window.addEventListener('load', async ()=>{ setAPIInfo(); const ok=await verifyToken(); if(ok){ setUser('admin'); render('trends'); } else { openLogin(); } });
JS

########################
# api.Dockerfile (root)
########################
cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi uvicorn[standard] sqlalchemy pydantic psycopg[binary] python-multipart passlib[bcrypt]==1.7.4 bcrypt==4.0.1 python-jose[cryptography]
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

########################
# Compose override for api/web
########################
cat > "$DOCK/docker-compose.override.yml" <<'YML'
services:
  api:
    build:
      context: ..
      dockerfile: api.Dockerfile
    environment:
      DB_URL: postgresql+psycopg://postgres:postgres@postgres:5432/smsdb
      JWT_SECRET: changeme
    ports:
      - "8010:8000"
    depends_on:
      - postgres
  web:
    build:
      context: ../web
      dockerfile: Dockerfile
    ports:
      - "5183:80"
    depends_on:
      - api
YML

########################
# Build & start
########################
cd "$DOCK"
docker compose up -d --build api web
sleep 3
echo "API root:"; curl -sS http://localhost:8010/ ; echo
echo "Login sanity:"; curl -sS -X POST http://localhost:8010/users/login -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=admin&password=admin123' ; echo
echo "Web UI: http://localhost:5183  (set API via ⚙ if browsing from LAN)"
