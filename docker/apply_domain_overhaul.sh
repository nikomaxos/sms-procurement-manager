#!/usr/bin/env bash
# One-pass name-based CRUD + UI overhaul
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
ROUTERS="$API_DIR/routers"
CORE="$API_DIR/core"
WEB="$ROOT/web/public"
DOCKER="$ROOT/docker"

mkdir -p "$ROUTERS" "$CORE" "$WEB"

# ---------- 1) Central migrations (idempotent) ----------
cat > "$API_DIR/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

def migrate():
    stmts = [
        # suppliers (name unique)
        """CREATE TABLE IF NOT EXISTS suppliers(
             id SERIAL PRIMARY KEY,
             organization_name VARCHAR NOT NULL UNIQUE,
             per_delivered BOOLEAN DEFAULT FALSE
        )""",
        # connections (unique per supplier+name)
        """CREATE TABLE IF NOT EXISTS supplier_connections(
             id SERIAL PRIMARY KEY,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
             connection_name VARCHAR NOT NULL,
             username VARCHAR,
             kannel_smsc VARCHAR,
             charge_model VARCHAR DEFAULT 'Per Submitted'
        )""",
        """DO $$
           BEGIN
             IF NOT EXISTS (
               SELECT 1 FROM pg_indexes WHERE indexname='supplier_connections_uniq'
             ) THEN
               CREATE UNIQUE INDEX supplier_connections_uniq
                 ON supplier_connections (supplier_id, connection_name);
             END IF;
           END $$;""",

        # countries (name unique, mcc unique-ish)
        """CREATE TABLE IF NOT EXISTS countries(
             id SERIAL PRIMARY KEY,
             name VARCHAR NOT NULL UNIQUE,
             mcc VARCHAR
        )""",

        # networks (unique by mccmnc OR (country_id+name))
        """CREATE TABLE IF NOT EXISTS networks(
             id SERIAL PRIMARY KEY,
             country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
             name VARCHAR NOT NULL,
             mnc VARCHAR,
             mccmnc VARCHAR
        )""",
        """DO $$
           BEGIN
             IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='networks_uniq_mccmnc') THEN
               CREATE UNIQUE INDEX networks_uniq_mccmnc ON networks (mccmnc);
             END IF;
           END $$;""",

        # offers_current (unique tuple)
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
        """DO $$
           BEGIN
             IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='offers_current_uniq') THEN
               CREATE UNIQUE INDEX offers_current_uniq
                 ON offers_current (supplier_id, connection_id, network_id);
             END IF;
           END $$;""",

        # dropdown configs
        """CREATE TABLE IF NOT EXISTS dropdown_configs(
             id SMALLINT PRIMARY KEY DEFAULT 1,
             route_types JSONB DEFAULT '["Direct","SS7","SIM","Local Bypass"]'::jsonb,
             known_hops JSONB DEFAULT '["0-Hop","1-Hop","2-Hops","N-Hops"]'::jsonb,
             sender_id_supported JSONB DEFAULT '["Dynamic Alphanumeric","Dynamic Numeric","Short code"]'::jsonb,
             registration_required JSONB DEFAULT '["Yes","No"]'::jsonb,
             is_exclusive JSONB DEFAULT '["Yes","No"]'::jsonb
        )""",
        "INSERT INTO dropdown_configs(id) VALUES (1) ON CONFLICT (id) DO NOTHING",

        # parser settings and templates (DB-backed UI)
        """CREATE TABLE IF NOT EXISTS parser_settings(
             id SMALLINT PRIMARY KEY DEFAULT 1,
             imap_host VARCHAR, imap_user VARCHAR, imap_password VARCHAR,
             imap_folder VARCHAR, imap_ssl BOOLEAN DEFAULT TRUE,
             ingest_limit INTEGER DEFAULT 50, refresh_minutes INTEGER DEFAULT 5
        )""",
        "INSERT INTO parser_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING",
        """CREATE TABLE IF NOT EXISTS parser_templates(
             id SERIAL PRIMARY KEY,
             name VARCHAR UNIQUE NOT NULL,
             supplier_name VARCHAR,
             connection_name VARCHAR,
             format VARCHAR DEFAULT 'csv', -- csv/xlsx
             mapping JSONB DEFAULT '{}'::jsonb
        )""",

        # backfills
        """UPDATE offers_current oc
              SET mccmnc = n.mccmnc
             FROM networks n
            WHERE oc.network_id=n.id AND oc.mccmnc IS NULL""",
        """UPDATE offers_current oc
              SET country_id = n.country_id
             FROM networks n
            WHERE oc.network_id=n.id AND oc.country_id IS NULL""",
        # per_delivered non-null
        "UPDATE suppliers SET per_delivered=FALSE WHERE per_delivered IS NULL"
    ]
    with engine.begin() as conn:
        for s in stmts:
            conn.execute(text(s))
PY

# ---------- 2) Routers ----------
cat > "$ROUTERS/config.py" <<'PY'
from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

@router.get("/config/dropdowns")
def get_dropdowns(user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("SELECT * FROM dropdown_configs WHERE id=1")).mappings().first()
    if not r:
        return {}
    out = dict(r)
    # remove id
    out.pop("id", None)
    return out

@router.post("/config/dropdowns")
def set_dropdowns(body: dict, user=Depends(guard)):
    keys = ["route_types","known_hops","sender_id_supported","registration_required","is_exclusive"]
    sets = []
    params = {}
    for k in keys:
        if k in body:
            sets.append(f"{k} = :{k}::jsonb")
            params[k] = body[k]
    if not sets:
        return {"ok": True}
    q = "UPDATE dropdown_configs SET " + ", ".join(sets) + " WHERE id=1"
    with engine.begin() as c:
        c.execute(text(q), params)
    return {"ok": True}

@router.get("/parser/settings")
def get_parser_settings(user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("SELECT * FROM parser_settings WHERE id=1")).mappings().first()
    return dict(r) if r else {}

@router.post("/parser/settings")
def set_parser_settings(body: dict, user=Depends(guard)):
    # upsert into single row
    keys = ["imap_host","imap_user","imap_password","imap_folder","imap_ssl","ingest_limit","refresh_minutes"]
    sets = []
    params = {}
    for k in keys:
        if k in body:
            sets.append(f"{k} = :{k}")
            params[k] = body[k]
    if sets:
        q = "UPDATE parser_settings SET " + ", ".join(sets) + " WHERE id=1"
        with engine.begin() as c:
            c.execute(text(q), params)
    return {"ok": True}

@router.get("/parser/templates")
def list_templates(user=Depends(guard)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,supplier_name,connection_name,format,mapping FROM parser_templates ORDER BY name")).mappings().all()
    return [dict(r) for r in rows]

@router.post("/parser/templates")
def upsert_template(body: dict, user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO parser_templates(name,supplier_name,connection_name,format,mapping)
            VALUES (:name,:supplier,:conn,:fmt,:mapping::jsonb)
            ON CONFLICT (name) DO UPDATE SET
              supplier_name=EXCLUDED.supplier_name,
              connection_name=EXCLUDED.connection_name,
              format=EXCLUDED.format,
              mapping=EXCLUDED.mapping
            RETURNING id
        """), {
            "name": body.get("name"),
            "supplier": body.get("supplier_name"),
            "conn": body.get("connection_name"),
            "fmt": body.get("format","csv"),
            "mapping": body.get("mapping",{})
        }).first()
    return {"id": r[0] if r else None}
PY

cat > "$ROUTERS/countries.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

@router.get("/countries")
def list_countries(user=Depends(guard)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,mcc FROM countries ORDER BY name")).mappings().all()
    return [dict(r) for r in rows]

@router.post("/countries")
def create_country(body: dict, user=Depends(guard)):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    with engine.begin() as c:
        r = c.execute(text("INSERT INTO countries(name,mcc) VALUES (:n,:mcc) ON CONFLICT (name) DO NOTHING RETURNING id"),
                      {"n": name, "mcc": body.get("mcc")}).first()
        if not r:
            # already exists
            r = c.execute(text("SELECT id FROM countries WHERE name=:n"), {"n": name}).first()
    return {"id": r[0]}

@router.patch("/countries/{cid}")
def update_country(cid: int, body: dict, user=Depends(guard)):
    sets, p = [], {"id": cid}
    for k in ("name","mcc"):
        if k in body:
            sets.append(f"{k} = :{k}")
            p[k] = body[k]
    if not sets:
        return {"ok": True}
    q = "UPDATE countries SET " + ", ".join(sets) + " WHERE id=:id"
    with engine.begin() as c:
        c.execute(text(q), p)
    return {"ok": True}
PY

cat > "$ROUTERS/networks.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

def _country_id(cn, conn):
    r = conn.execute(text("SELECT id FROM countries WHERE name=:n"), {"n": cn}).first()
    if not r:
        raise HTTPException(400, f"Country not found: {cn}")
    return r[0]

@router.get("/networks")
def list_networks(country_name: str | None = Query(None), user=Depends(guard)):
    with engine.begin() as c:
        if country_name:
            rows = c.execute(text("""
              SELECT n.id, n.name, n.mnc, n.mccmnc, n.country_id, c.name AS country_name
                FROM networks n LEFT JOIN countries c ON c.id=n.country_id
               WHERE c.name=:cn ORDER BY n.name
            """), {"cn": country_name}).mappings().all()
        else:
            rows = c.execute(text("""
              SELECT n.id, n.name, n.mnc, n.mccmnc, n.country_id, c.name AS country_name
                FROM networks n LEFT JOIN countries c ON c.id=n.country_id
               ORDER BY c.name, n.name
            """)).mappings().all()
    return [dict(r) for r in rows]

@router.post("/networks")
def create_network(body: dict, user=Depends(guard)):
    name = (body.get("name") or "").strip()
    country_name = (body.get("country_name") or "").strip()
    if not name or not country_name:
        raise HTTPException(400, "name and country_name required")
    with engine.begin() as c:
        cid = _country_id(country_name, c)
        r = c.execute(text("""
          INSERT INTO networks(name,country_id,mnc,mccmnc)
          VALUES (:n,:cid,:mnc,:mm)
          ON CONFLICT (mccmnc) DO NOTHING
          RETURNING id
        """), {"n": name, "cid": cid, "mnc": body.get("mnc"), "mm": body.get("mccmnc")}).first()
        if not r:
            r = c.execute(text("SELECT id FROM networks WHERE mccmnc=:mm OR (name=:n AND country_id=:cid)"),
                          {"mm": body.get("mccmnc"), "n": name, "cid": cid}).first()
    return {"id": r[0]}

@router.patch("/networks/{nid}")
def update_network(nid: int, body: dict, user=Depends(guard)):
    sets, p = [], {"id": nid}
    if "country_name" in body:
        with engine.begin() as c:
            cid = _country_id(body["country_name"], c)
        sets.append("country_id=:cid"); p["cid"]=cid
    for k in ("name","mnc","mccmnc"):
        if k in body: sets.append(f"{k} = :{k}"); p[k]=body[k]
    if not sets: return {"ok": True}
    q = "UPDATE networks SET " + ", ".join(sets) + " WHERE id=:id"
    with engine.begin() as c: c.execute(text(q), p)
    return {"ok": True}
PY

cat > "$ROUTERS/suppliers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

@router.get("/suppliers")
def list_suppliers(user=Depends(guard)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,organization_name,per_delivered FROM suppliers ORDER BY organization_name")).mappings().all()
    return [dict(r) for r in rows]

@router.post("/suppliers")
def create_supplier(body: dict, user=Depends(guard)):
    name = (body.get("organization_name") or "").strip()
    if not name: raise HTTPException(400, "organization_name required")
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO suppliers(organization_name,per_delivered)
            VALUES (:n,COALESCE(:pd,false)) ON CONFLICT (organization_name) DO NOTHING RETURNING id
        """), {"n": name, "pd": body.get("per_delivered")}).first()
        if not r:
            r = c.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": name}).first()
    return {"id": r[0]}

@router.patch("/suppliers/{sid}")
def update_supplier(sid: int, body: dict, user=Depends(guard)):
    sets, p = [], {"id": sid}
    for k in ("organization_name","per_delivered"):
        if k in body: sets.append(f"{k} = :{k}"); p[k]=body[k]
    if not sets: return {"ok": True}
    q = "UPDATE suppliers SET " + ", ".join(sets) + " WHERE id=:id"
    with engine.begin() as c: c.execute(text(q), p)
    return {"ok": True}
PY

cat > "$ROUTERS/connections.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

def _supplier_id(name, conn):
    r = conn.execute(text("SELECT id FROM suppliers WHERE organization_name=:n"), {"n": name}).first()
    if not r: raise HTTPException(400, f"Supplier not found: {name}")
    return r[0]

@router.get("/connections")
def list_connections(supplier_name: str | None = Query(None), user=Depends(guard)):
    with engine.begin() as c:
        if supplier_name:
            rows = c.execute(text("""
                SELECT sc.id, sc.connection_name, sc.username, sc.charge_model,
                       s.organization_name AS supplier_name
                  FROM supplier_connections sc
                  JOIN suppliers s ON s.id=sc.supplier_id
                 WHERE s.organization_name=:n
                 ORDER BY sc.connection_name
            """), {"n": supplier_name}).mappings().all()
        else:
            rows = c.execute(text("""
                SELECT sc.id, sc.connection_name, sc.username, sc.charge_model,
                       s.organization_name AS supplier_name
                  FROM supplier_connections sc
                  JOIN suppliers s ON s.id=sc.supplier_id
                 ORDER BY s.organization_name, sc.connection_name
            """)).mappings().all()
    return [dict(r) for r in rows]

@router.post("/connections")
def create_connection(body: dict, user=Depends(guard)):
    sname = (body.get("supplier_name") or "").strip()
    cname = (body.get("connection_name") or "").strip()
    if not sname or not cname: raise HTTPException(400, "supplier_name and connection_name required")
    with engine.begin() as c:
        sid = _supplier_id(sname, c)
        r = c.execute(text("""
           INSERT INTO supplier_connections(supplier_id,connection_name,username,kannel_smsc,charge_model)
           VALUES (:sid,:cn,:u,:smsc,:cm)
           ON CONFLICT (supplier_id,connection_name) DO NOTHING RETURNING id
        """), {"sid": sid, "cn": cname, "u": body.get("username"),
               "smsc": body.get("kannel_smsc"), "cm": body.get("charge_model") or "Per Submitted"}).first()
        if not r:
            r = c.execute(text("SELECT id FROM supplier_connections WHERE supplier_id=:sid AND connection_name=:cn"),
                          {"sid": sid, "cn": cname}).first()
    return {"id": r[0]}
PY

cat > "$ROUTERS/offers_plus.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from typing import Any, Dict
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

def _id_by_name(conn, table, name_field, name_value):
    r = conn.execute(text(f"SELECT id FROM {table} WHERE {name_field}=:v"), {"v": name_value}).first()
    return r[0] if r else None

def _resolve_network(conn, *, network_name=None, mccmnc=None, country_name=None):
    if mccmnc:
        r = conn.execute(text("SELECT id,country_id,mccmnc FROM networks WHERE mccmnc=:mm"), {"mm": mccmnc}).first()
        if r: return r.id, r.country_id, r.mccmnc
    if network_name and country_name:
        r = conn.execute(text("""
            SELECT n.id, n.country_id, n.mccmnc FROM networks n
            JOIN countries c ON c.id=n.country_id
            WHERE n.name=:nn AND c.name=:cn
        """), {"nn": network_name, "cn": country_name}).first()
        if r: return r.id, r.country_id, r.mccmnc
    if network_name:
        r = conn.execute(text("SELECT id, country_id, mccmnc FROM networks WHERE name=:nn LIMIT 1"),
                         {"nn": network_name}).first()
        if r: return r.id, r.country_id, r.mccmnc
    return None, None, None

def _inherit_charge_model(conn, connection_id):
    r = conn.execute(text("SELECT charge_model FROM supplier_connections WHERE id=:id"), {"id": connection_id}).first()
    return (r[0] if r and r[0] else "Per Submitted")

@router.get("/offers")
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
    user=Depends(guard)
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

@router.get("/offers/{oid}")
def get_offer(oid: int, user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("""
            SELECT oc.*, s.organization_name AS supplier_name,
                   sc.connection_name, sc.username AS smsc_username,
                   c.name AS country, n.name AS network, n.mccmnc AS mccmnc_net
              FROM offers_current oc
              LEFT JOIN supplier_connections sc ON sc.id=oc.connection_id
              LEFT JOIN suppliers s ON s.id=oc.supplier_id
              LEFT JOIN networks n ON n.id=oc.network_id
              LEFT JOIN countries c ON c.id=n.country_id
             WHERE oc.id=:id
        """), {"id": oid}).mappings().first()
    if not r: raise HTTPException(404, "Not found")
    d = dict(r); d["mccmnc"] = d.get("mccmnc") or d.get("mccmnc_net")
    if isinstance(d.get("sender_id_supported"), str):
        d["sender_id_supported"] = [x.strip() for x in d["sender_id_supported"].split(",") if x.strip()]
    return d

@router.post("/offers/by_names")
def create_offer_by_names(body: dict, user=Depends(guard)):
    """
    Expected body (names only, no raw ids):
    {
      supplier_name, connection_name,
      country_name (optional if mccmnc or network identifies),
      network_name (optional if mccmnc present),
      mccmnc (optional if network_name+country_name present),
      price, currency?, price_effective_date?,
      route_type, known_hops, sender_id_supported[], registration_required,
      eta_days, is_exclusive, notes
    }
    """
    req = body
    if not req.get("supplier_name") or not req.get("connection_name"):
        raise HTTPException(400, "supplier_name and connection_name required")

    with engine.begin() as c:
        sid = _id_by_name(c, "suppliers", "organization_name", req["supplier_name"])
        if not sid: raise HTTPException(400, "Unknown supplier")

        cid = c.execute(text("""
            SELECT id FROM supplier_connections
             WHERE supplier_id=:sid AND connection_name=:cn
        """), {"sid": sid, "cn": req["connection_name"]}).scalar()
        if not cid: raise HTTPException(400, "Unknown connection for supplier")

        nid, country_id, mm = _resolve_network(
            c,
            network_name=req.get("network_name"),
            mccmnc=req.get("mccmnc"),
            country_name=req.get("country_name")
        )
        if not nid and not mm:
            raise HTTPException(400, "Provide network_name+country_name or mccmnc")

        # inherit charge model
        cm = _inherit_charge_model(c, cid)

        prev = c.execute(text("""
           SELECT price FROM offers_current
            WHERE supplier_id=:s AND connection_id=:c AND COALESCE(network_id,0)=COALESCE(:n,0)
            LIMIT 1
        """), {"s": sid, "c": cid, "n": nid}).scalar()

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
            "sid": sid, "cid": cid, "country_id": country_id, "nid": nid, "mm": mm,
            "price": req.get("price"),
            "prev": prev,
            "currency": req.get("currency") or "EUR",
            "eff": req.get("price_effective_date") or "",
            "rt": req.get("route_type"),
            "kh": req.get("known_hops"),
            "sid_sup": req.get("sender_id_supported") or [],
            "reg": req.get("registration_required"),
            "eta": req.get("eta_days"),
            "cm": cm,
            "iex": req.get("is_exclusive"),
            "notes": req.get("notes")
        }).first()
    return {"id": r[0]}
PY

# ---------- 3) Wire routers & migrations into main.py ----------
if ! grep -q "migrations import migrate" "$API_DIR/main.py" 2>/dev/null; then
  sed -i '1s/^/from app.migrations import migrate\n/' "$API_DIR/main.py" || true
fi
if ! grep -q "app = FastAPI" "$API_DIR/main.py"; then
  # rudimentary safeguard
  echo 'from fastapi import FastAPI' >> "$API_DIR/main.py"
  echo 'app = FastAPI(title="SMS Procurement Manager")' >> "$API_DIR/main.py"
fi
# Inject CORS if missing
if ! grep -q "CORSMiddleware" "$API_DIR/main.py"; then
  awk '
    /from fastapi import FastAPI/ && !seenF {print; print "from fastapi.middleware.cors import CORSMiddleware"; seenF=1; next}
    /app = FastAPI/ && !seenC {
      print;
      print "import os";
      print "origins = os.getenv(\"CORS_ORIGINS\",\"http://localhost:5183,http://127.0.0.1:5183,*\").split(\",\")";
      print "app.add_middleware(CORSMiddleware, allow_origins=origins, allow_credentials=True, allow_methods=[\"*\"], allow_headers=[\"*\"])";
      seenC=1; next
    }
    {print}
  ' "$API_DIR/main.py" > "$API_DIR/main.py.tmp" && mv "$API_DIR/main.py.tmp" "$API_DIR/main.py"
fi
# Include routers after startup, and call migrate()
if ! grep -q "include_router(offers_plus.router)" "$API_DIR/main.py"; then
  cat >> "$API_DIR/main.py" <<'PY'

migrate()  # one-shot idempotent DDL

from app.routers import config as _cfg
from app.routers import countries as _countries
from app.routers import networks as _networks
from app.routers import suppliers as _suppliers
from app.routers import connections as _connections
from app.routers import offers_plus as offers_plus

app.include_router(_cfg.router)
app.include_router(_countries.router)
app.include_router(_networks.router)
app.include_router(_suppliers.router)
app.include_router(_connections.router)
app.include_router(offers_plus.router)
PY
fi

# ---------- 4) Web UI (menus + forms using names) ----------
cat > "$WEB/index.html" <<'HTML'
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
  <small>v1.1 — <a href="#" id="logout">Logout</a></small>
</footer>
<script src="/main.js"></script>
</body>
</html>
HTML

cat > "$WEB/main.css" <<'CSS'
:root{--bg:#0b1220;--card:#121a2b;--text:#eaf1ff;--muted:#9fb0d1;--acc:#5da0ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,Segoe UI,Roboto}
header,footer{padding:12px 16px;background:linear-gradient(90deg,#0e182c,#0b1220)}
h1{margin:0;font-size:18px}
#apiInfo{float:right;color:var(--muted)}
nav{display:flex;gap:8px;flex-wrap:wrap;padding:8px 16px;background:#0e1626;border-bottom:1px solid #1b2741}
nav button{background:#16233d;color:var(--text);border:1px solid #223152;border-radius:10px;padding:8px 12px;cursor:pointer}
nav button.active{background:var(--acc);border-color:var(--acc);color:#04122a}
#app{padding:16px}
.card{background:var(--card);padding:16px;border-radius:14px;border:1px solid #1b2741;box-shadow:0 4px 18px #0006}
.toolbar{display:flex;gap:8px;align-items:center;margin:8px 0;flex-wrap:wrap}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}
input,select,textarea{background:#0e1626;color:var(--text);border:1px solid #223152;border-radius:8px;padding:8px;width:100%}
button.primary{background:var(--acc);border:none;color:#04122a;border-radius:10px;padding:8px 12px;font-weight:600}
.table{width:100%;border-collapse:collapse;margin-top:8px}
.table th,.table td{padding:8px;border-bottom:1px solid #1b2741}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;border:1px solid #28406c;color:#bcd1f3;font-size:12px}
.muted{color:var(--muted)}
.login{max-width:360px;margin:40px auto}
.right{float:right}
CSS

cat > "$WEB/main.js" <<'JS'
const API_BASE = localStorage.getItem("API_BASE") || `http://${location.hostname}:8010`;
const tokenKey = "spm_token";

const NAV = [
  {k:"dash", label:"Dashboard", view: viewDash},
  {k:"offers", label:"Offers", view: viewOffers},
  {k:"suppliers", label:"Suppliers", view: viewSuppliers},
  {k:"connections", label:"Connections", view: viewConnections},
  {k:"countries", label:"Countries", view: viewCountries},
  {k:"networks", label:"Networks", view: viewNetworks},
  {k:"parser", label:"Parser", view: viewParser},
  {k:"configs", label:"Configs", view: viewConfigs},
];

function setNav(active){
  const el = document.querySelector('#nav');
  el.innerHTML = NAV.map(n=>`<button data-k="${n.k}" class="${active===n.k?'active':''}">${n.label}</button>`).join("");
  el.querySelectorAll('button').forEach(b=>b.onclick=()=>selectView(b.dataset.k));
}
function selectView(k){ (NAV.find(x=>x.k===k)||NAV[0]).view(); setNav(k); }
function layout(inner){ return `<div class="card">${inner}</div>`; }

async function authFetch(path, opts={}){
  const t = localStorage.getItem(tokenKey);
  const h = Object.assign({"Accept":"application/json"}, opts.headers||{});
  if (t) h["Authorization"] = `Bearer ${t}`;
  const res = await fetch(`${API_BASE}${path}`, {...opts, headers: h});
  if(!res.ok){ throw new Error(`${res.status} ${await res.text().catch(()=>res.statusText)}`); }
  const ct = res.headers.get("content-type")||"";
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
      <div class="muted">API: <b id="apiBase"></b></div>
    </div>
  `);
  document.querySelector('#apiBase').textContent = API_BASE;
  document.querySelector('#lg').onclick = async ()=>{
    const body = new URLSearchParams({username: lu.value, password: lp.value});
    const r = await fetch(`${API_BASE}/users/login`, {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body});
    if(!r.ok){ alert('Login failed'); return; }
    const j = await r.json(); localStorage.setItem(tokenKey, j.access_token); boot();
  };
}

function badge(v){ return v?`<span class="badge">${v}</span>`:""; }
function opt(list, cur){ return (list||[]).map(v=>`<option ${String(v)===String(cur)?'selected':''}>${v}</option>`).join(''); }
function optObj(list, cur, idKey, nameKey){ return (list||[]).map(o=>`<option value="${o[idKey]}" ${String(o[idKey])===String(cur)?'selected':''}>${o[nameKey]}</option>`).join(''); }

async function dicts(){
  const [countries, networks, suppliers, cfg] = await Promise.all([
    authFetch('/countries').catch(()=>[]),
    authFetch('/networks').catch(()=>[]),
    authFetch('/suppliers').catch(()=>[]),
    authFetch('/config/dropdowns').catch(()=>({route_types:["Direct","SS7","SIM","Local Bypass"], known_hops:["0-Hop","1-Hop","2-Hops","N-Hops"], sender_id_supported:["Dynamic Alphanumeric","Dynamic Numeric","Short code"], registration_required:["Yes","No"], is_exclusive:["Yes","No"]}))
  ]);
  const networksById = Object.fromEntries(networks.map(n=>[String(n.id), n]));
  const networksByMM = Object.fromEntries(networks.map(n=>[String(n.mccmnc||""), n]));
  const connsBySupplier = {};
  const allConnections = await authFetch('/connections').catch(()=>[]);
  for (const c of allConnections){
    connsBySupplier[c.supplier_name]=connsBySupplier[c.supplier_name]||[];
    connsBySupplier[c.supplier_name].push(c);
  }
  return {countries, networks, suppliers, cfg, networksById, networksByMM, connsBySupplier};
}

async function viewDash(){
  document.querySelector('#app').innerHTML = layout(`
    <h2>Welcome</h2>
    <p>Use the navigation to manage Offers, Suppliers, Connections, Countries, Networks, Parser, and Configs.</p>
  `);
}

async function viewCountries(){
  const app = document.querySelector('#app');
  const list = await authFetch('/countries').catch(()=>[]);
  app.innerHTML = layout(`
    <h2>Countries</h2>
    <div class="toolbar">
      <input id="c_name" placeholder="Country Name">
      <input id="c_mcc" placeholder="MCC">
      <button class="primary" id="add">Create</button>
    </div>
    <table class="table">
      <tr><th>Name</th><th>MCC</th></tr>
      ${list.map(x=>`<tr><td>${x.name}</td><td>${x.mcc||''}</td></tr>`).join('') || `<tr><td colspan="2" class="muted">No countries</td></tr>`}
    </table>
  `);
  document.querySelector('#add').onclick = async()=>{
    await authFetch('/countries', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name: c_name.value, mcc: c_mcc.value})});
    viewCountries();
  };
}

async function viewNetworks(){
  const app = document.querySelector('#app');
  const D = await dicts();
  const list = await authFetch('/networks').catch(()=>[]);
  app.innerHTML = layout(`
    <h2>Networks</h2>
    <div class="toolbar grid">
      <div><label>Country<br/><select id="n_country"><option value="">(select)</option>${opt(D.countries.map(c=>c.name),'')}</select></label></div>
      <div><label>Name<br/><input id="n_name" placeholder="Network name"></label></div>
      <div><label>MNC<br/><input id="n_mnc" placeholder="e.g. 01"></label></div>
      <div><label>MCC-MNC<br/><input id="n_mm" placeholder="e.g. 20201"></label></div>
      <div><button class="primary" id="add">Create</button></div>
    </div>
    <table class="table">
      <tr><th>Country</th><th>Network</th><th>MCC-MNC</th><th>MNC</th></tr>
      ${list.map(n=>`<tr><td>${n.country_name||''}</td><td>${n.name}</td><td>${n.mccmnc||''}</td><td>${n.mnc||''}</td></tr>`).join('') || `<tr><td colspan="4" class="muted">No networks</td></tr>`}
    </table>
  `);
  document.querySelector('#add').onclick = async()=>{
    const body={country_name: n_country.value, name: n_name.value, mnc: n_mnc.value, mccmnc: n_mm.value};
    await authFetch('/networks', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    viewNetworks();
  };
}

async function viewSuppliers(){
  const app = document.querySelector('#app');
  const list = await authFetch('/suppliers').catch(()=>[]);
  app.innerHTML = layout(`
    <h2>Suppliers</h2>
    <div class="toolbar">
      <input id="s_name" placeholder="Organization Name">
      <label><input id="s_pd" type="checkbox"> Per Delivered</label>
      <button class="primary" id="add">Create</button>
    </div>
    <table class="table">
      <tr><th>Supplier</th><th>Per Delivered</th></tr>
      ${list.map(s=>`<tr><td>${s.organization_name}</td><td>${s.per_delivered?'Yes':'No'}</td></tr>`).join('') || `<tr><td colspan="2" class="muted">No suppliers</td></tr>`}
    </table>
  `);
  document.querySelector('#add').onclick = async()=>{
    await authFetch('/suppliers', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({organization_name: s_name.value, per_delivered: s_pd.checked})});
    viewSuppliers();
  };
}

async function viewConnections(){
  const app = document.querySelector('#app');
  const D = await dicts();
  const conns = await authFetch('/connections').catch(()=>[]);
  app.innerHTML = layout(`
    <h2>Connections</h2>
    <div class="toolbar grid">
      <div><label>Supplier<br/><select id="cx_sup">${opt(D.suppliers.map(s=>s.organization_name),'')}</select></label></div>
      <div><label>Connection Name<br/><input id="cx_name"></label></div>
      <div><label>SMSC Username<br/><input id="cx_user"></label></div>
      <div><label>Charge Model<br/><input id="cx_cm" value="Per Submitted"></label></div>
      <div><button class="primary" id="add">Create</button></div>
    </div>
    <table class="table">
      <tr><th>Supplier</th><th>Connection</th><th>Username</th><th>Charge Model</th></tr>
      ${conns.map(c=>`<tr><td>${c.supplier_name}</td><td>${c.connection_name}</td><td>${c.username||''}</td><td>${c.charge_model||''}</td></tr>`).join('') || `<tr><td colspan="4" class="muted">No connections</td></tr>`}
    </table>
  `);
  document.querySelector('#add').onclick = async()=>{
    const body={supplier_name: cx_sup.value, connection_name: cx_name.value, username: cx_user.value, charge_model: cx_cm.value};
    await authFetch('/connections', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    viewConnections();
  };
}

async function viewOffers(){
  const app = document.querySelector('#app');
  const D = await dicts();
  app.innerHTML = layout(`
    <h2>Offers</h2>
    <div class="card" style="margin:12px 0">
      <div class="grid">
        <div><label>Country<br/><select id="f_country"><option value="">(All)</option>${opt(D.countries.map(c=>c.name),'')}</select></label></div>
        <div><label>Route Type<br/><select id="f_rt"><option value="">(All)</option>${opt(D.cfg.route_types,'')}</select></label></div>
        <div><label>Known Hops<br/><select id="f_kh"><option value="">(All)</option>${opt(D.cfg.known_hops,'')}</select></label></div>
        <div><label>Supplier Name<br/><input id="f_sname" placeholder="contains…"></label></div>
        <div><label>Connection Name<br/><input id="f_cname" placeholder="contains…"></label></div>
        <div><label>Sender ID Supported<br/><select id="f_sid"><option value="">(All)</option>${opt(D.cfg.sender_id_supported,'')}</select></label></div>
        <div><label>Registration Required<br/><select id="f_rr"><option value="">(All)</option>${opt(D.cfg.registration_required,'')}</select></label></div>
        <div><label>Is Exclusive<br/><select id="f_ix"><option value="">(All)</option>${opt(D.cfg.is_exclusive,'')}</select></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="apply">Apply Filters</button></div>
    </div>

    <div id="create" class="card" style="margin:12px 0">
      <h3>Create / Upsert Offer (names only)</h3>
      <div class="grid">
        <div><label>Supplier<br/><select id="o_sup">${opt(D.suppliers.map(s=>s.organization_name),'')}</select></label></div>
        <div><label>Connection<br/><select id="o_conn"></select></label></div>
        <div><label>Country<br/><select id="o_country"><option value="">(auto)</option>${opt(D.countries.map(c=>c.name),'')}</select></label></div>
        <div><label>Network<br/><select id="o_network"><option value="">(choose)</option>${opt(D.networks.map(n=>n.name),'')}</select></label></div>
        <div><label>MCC-MNC<br/><select id="o_mm"><option value="">(choose)</option>${opt(D.networks.map(n=>n.mccmnc).filter(Boolean),'')}</select></label></div>
        <div><label>Price<br/><input id="o_price" type="number" step="0.0001"></label></div>
        <div><label>Price Effective Date<br/><input id="o_eff" type="datetime-local"></label></div>
        <div><label>Route Type<br/><select id="o_rt">${opt(D.cfg.route_types,'Direct')}</select></label></div>
        <div><label>Known Hops<br/><select id="o_kh">${opt(D.cfg.known_hops,'0-Hop')}</select></label></div>
        <div><label>Sender ID Supported<br/><select id="o_sid" multiple size="3">${opt(D.cfg.sender_id_supported,'')}</select></label></div>
        <div><label>Registration Required<br/><select id="o_rr">${opt(D.cfg.registration_required,'No')}</select></label></div>
        <div><label>ETA in days<br/><input id="o_eta" type="number" min="0"></label></div>
        <div><label>Is Exclusive<br/><select id="o_ix">${opt(D.cfg.is_exclusive,'No')}</select></label></div>
        <div style="grid-column:1/-1"><label>Notes<br/><textarea id="o_notes" rows="3" style="width:100%"></textarea></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="saveOffer">Save</button></div>
    </div>

    <div id="list" class="card"></div>
    <div id="detail" class="card" style="display:none;margin-top:12px"></div>
  `);

  // bind supplier -> connections
  const connsAll = await authFetch('/connections').catch(()=>[]);
  function fillConns(){
    const s = o_sup.value;
    const options = connsAll.filter(c=>c.supplier_name===s).map(c=>`<option>${c.connection_name}</option>`).join('');
    o_conn.innerHTML = options || '<option>(none)</option>';
  }
  o_sup.onchange = fillConns; fillConns();

  // network <-> mm binding
  o_network.onchange = ()=>{ const n = (awaitNetByName(o_network.value)||{}); o_country.value = n.country_name||o_country.value; o_mm.value = n.mccmnc||o_mm.value; };
  o_mm.onchange = ()=>{ const n = (awaitNetByMM(o_mm.value)||{}); o_network.value = n.name||o_network.value; o_country.value = n.country_name||o_country.value; };

  const nets = await authFetch('/networks').catch(()=>[]);
  const byName = Object.fromEntries(nets.map(n=>[n.name,n]));
  const byMM   = Object.fromEntries(nets.map(n=>[n.mccmnc||'',n]));
  async function awaitNetByName(name){ return byName[name]; }
  async function awaitNetByMM(mm){ return byMM[mm]; }

  document.querySelector('#saveOffer').onclick = async ()=>{
    const sid = Array.from(o_sid.selectedOptions).map(o=>o.value);
    const body = {
      supplier_name: o_sup.value,
      connection_name: o_conn.value,
      country_name: o_country.value || null,
      network_name: o_network.value || null,
      mccmnc: o_mm.value || null,
      price: o_price.value? parseFloat(o_price.value): null,
      price_effective_date: o_eff.value? new Date(o_eff.value).toISOString(): null,
      route_type: o_rt.value, known_hops: o_kh.value,
      sender_id_supported: sid,
      registration_required: o_rr.value,
      eta_days: o_eta.value? parseInt(o_eta.value,10): null,
      is_exclusive: o_ix.value,
      notes: o_notes.value || null
    };
    await authFetch('/offers/by_names', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    await loadList();
    alert('Offer saved.');
  };

  document.querySelector('#apply').onclick = loadList;

  async function loadList(){
    const p = new URLSearchParams();
    if (f_country.value) p.set('country_name', f_country.value);
    if (f_rt.value) p.set('route_type', f_rt.value);
    if (f_kh.value) p.set('known_hops', f_kh.value);
    if (f_sname.value) p.set('supplier_name', f_sname.value);
    if (f_cname.value) p.set('connection_name', f_cname.value);
    if (f_sid.value) p.set('sender_id_supported', f_sid.value);
    if (f_rr.value) p.set('registration_required', f_rr.value);
    if (f_ix.value) p.set('is_exclusive', f_ix.value);

    const data = await authFetch(`/offers?${p.toString()}`);
    list.innerHTML = `
      <table class="table">
        <tr>
          <th>Supplier</th><th>Connection</th><th>Country</th><th>Network</th><th>MCC-MNC</th>
          <th>Price</th><th>Effective</th><th>Prev</th>
          <th>Route</th><th>Hops</th><th>SID</th><th>Reg</th><th>ETA</th><th>Charge</th><th>Exclusive</th><th>Notes</th>
        </tr>
        ${data.map(d=>`
          <tr class="row" data-id="${d.id}">
            <td>${d.supplier_name||''}</td>
            <td>${d.connection_name||''}${d.smsc_username?`<br/><span class="muted">${d.smsc_username}</span>`:''}</td>
            <td>${d.country||''}</td>
            <td>${d.network||''}</td>
            <td>${d.mccmnc||''}</td>
            <td>${d.price??''}</td>
            <td>${d.price_effective_date? new Date(d.price_effective_date).toLocaleString():''}</td>
            <td>${d.previous_price==null?'—':d.previous_price}</td>
            <td>${badge(d.route_type)}</td>
            <td>${badge(d.known_hops)}</td>
            <td>${(d.sender_id_supported||[]).join(', ')}</td>
            <td>${badge(d.registration_required)}</td>
            <td>${d.eta_days??''}</td>
            <td>${d.charge_model||''}</td>
            <td>${badge(d.is_exclusive)}</td>
            <td>${d.notes?('<span class="muted">'+d.notes+'</span>'):''}</td>
          </tr>`).join('') || `<tr><td colspan="16" class="muted">No offers</td></tr>`}
      </table>`;
    list.querySelectorAll('.row').forEach(r=> r.onclick = ()=> openDetail(r.dataset.id));
  }

  async function openDetail(id){
    const d = await authFetch(`/offers/${id}`);
    detail.style.display = '';
    const cfg = await authFetch('/config/dropdowns');
    const nets = await authFetch('/networks').catch(()=>[]);
    const mmOptions  = opt(nets.map(n=>n.mccmnc).filter(Boolean), d.mccmnc||'');
    const nOptions   = opt(nets.map(n=>n.name), d.network||'');

    detail.innerHTML = `
      <h3>Offer Detail</h3>
      <div class="grid">
        <div><label>Supplier<br/><input disabled value="${d.supplier_name||''}"></label></div>
        <div><label>Connection<br/><input disabled value="${d.connection_name||''}${d.smsc_username?(' / '+d.smsc_username):''}"></label></div>
        <div><label>Country<br/><input disabled value="${d.country||''}"></label></div>
        <div><label>Network<br/><select id="e_net">${nOptions}</select></label></div>
        <div><label>MCC-MNC<br/><select id="e_mm">${mmOptions}</select></label></div>
        <div><label>Price<br/><input id="e_price" type="number" step="0.0001" value="${d.price??''}"></label></div>
        <div><label>Effective<br/><input id="e_eff" type="datetime-local" value="${d.price_effective_date? new Date(d.price_effective_date).toISOString().slice(0,16):''}"></label></div>
        <div><label>Prev<br/><input disabled value="${d.previous_price==null?'—':d.previous_price}"></label></div>
        <div><label>Route<br/><select id="e_rt">${opt(cfg.route_types,d.route_type||'')}</select></label></div>
        <div><label>Hops<br/><select id="e_kh">${opt(cfg.known_hops,d.known_hops||'')}</select></label></div>
        <div><label>Sender ID Supported<br/><input id="e_sid" value="${(d.sender_id_supported||[]).join(', ')}" placeholder="comma-separated"></label></div>
        <div><label>Reg Required<br/><select id="e_rr">${opt(cfg.registration_required,d.registration_required||'')}</select></label></div>
        <div><label>ETA days<br/><input id="e_eta" type="number" min="0" value="${d.eta_days??''}"></label></div>
        <div><label>Exclusive<br/><select id="e_ix">${opt(cfg.is_exclusive,d.is_exclusive||'')}</select></label></div>
        <div style="grid-column:1/-1"><label>Notes<br/><textarea id="e_notes" rows="3" style="width:100%">${d.notes||''}</textarea></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="save">Save</button></div>
    `;
    const netsByName = Object.fromEntries(nets.map(n=>[n.name,n]));
    const netsByMM   = Object.fromEntries(nets.map(n=>[n.mccmnc||'',n]));
    const eNet = document.querySelector('#e_net'), eMM = document.querySelector('#e_mm');
    eNet.onchange = ()=>{ const n = netsByName[eNet.value]; if(n) eMM.value = n.mccmnc||''; };
    eMM.onchange  = ()=>{ const n = netsByMM[eMM.value]; if(n) eNet.value = n.name||''; };
    document.querySelector('#save').onclick = async ()=>{
      const sid = (e_sid.value||'').split(',').map(x=>x.trim()).filter(Boolean);
      const eff = e_eff.value? new Date(eff.value).toISOString(): null;
      const body = {
        network_id: null,
        mccmnc: eMM.value||null,
        price: e_price.value? parseFloat(e_price.value): null,
        price_effective_date: e_eff.value? new Date(e_eff.value).toISOString(): null,
        route_type: e_rt.value||null,
        known_hops: e_kh.value||null,
        sender_id_supported: sid,
        registration_required: e_rr.value||null,
        eta_days: e_eta.value? parseInt(e_eta.value,10): null,
        is_exclusive: e_ix.value||null,
        notes: e_notes.value||null
      };
      await authFetch(`/offers/${id}`, {method:'PATCH', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
      await viewOffers();
      alert('Saved.');
    };
  }

  await loadList();
}

async function viewParser(){
  const app = document.querySelector('#app');
  const settings = await authFetch('/parser/settings').catch(()=>({}));
  const templates = await authFetch('/parser/templates').catch(()=>[]);
  app.innerHTML = layout(`
    <h2>Parser</h2>
    <div class="card">
      <h3>Settings</h3>
      <div class="grid">
        <div><label>IMAP Host<br/><input id="ps_host" value="${settings.imap_host||''}"></label></div>
        <div><label>IMAP User<br/><input id="ps_user" value="${settings.imap_user||''}"></label></div>
        <div><label>IMAP Password<br/><input id="ps_pass" type="password" value="${settings.imap_password||''}"></label></div>
        <div><label>IMAP Folder<br/><input id="ps_folder" value="${settings.imap_folder||''}"></label></div>
        <div><label>SSL<br/><select id="ps_ssl"><option ${settings.imap_ssl!==false?'selected':''}>true</option><option ${settings.imap_ssl===false?'selected':''}>false</option></select></label></div>
        <div><label>Ingest Limit<br/><input id="ps_lim" type="number" value="${settings.ingest_limit||50}"></label></div>
        <div><label>Refresh Minutes<br/><input id="ps_ref" type="number" value="${settings.refresh_minutes||5}"></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="savePs">Save Settings</button></div>
    </div>

    <div class="card" style="margin-top:12px">
      <h3>Templates</h3>
      <div class="grid">
        <div><label>Name<br/><input id="pt_name"></label></div>
        <div><label>Supplier<br/><input id="pt_sup"></label></div>
        <div><label>Connection<br/><input id="pt_conn"></label></div>
        <div><label>Format<br/><select id="pt_fmt"><option>csv</option><option>xlsx</option></select></label></div>
        <div style="grid-column:1/-1"><label>Mapping (JSON)<br/><textarea id="pt_map" rows="5" style="width:100%" placeholder='{"price":"Price","mccmnc":"MCCMNC"}'></textarea></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="saveTpl">Save Template</button></div>
      <div id="tplList" style="margin-top:8px"></div>
    </div>
  `);
  document.querySelector('#savePs').onclick = async ()=>{
    const body = {
      imap_host: ps_host.value, imap_user: ps_user.value, imap_password: ps_pass.value,
      imap_folder: ps_folder.value, imap_ssl: ps_ssl.value==='true',
      ingest_limit: parseInt(ps_lim.value||'50',10),
      refresh_minutes: parseInt(ps_ref.value||'5',10)
    };
    await authFetch('/parser/settings', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Settings saved.');
  };
  document.querySelector('#saveTpl').onclick = async ()=>{
    let mapping={}; try{ mapping=JSON.parse(pt_map.value||'{}') }catch(e){ alert('Invalid JSON'); return; }
    const body = {name: pt_name.value, supplier_name: pt_sup.value, connection_name: pt_conn.value, format: pt_fmt.value, mapping};
    await authFetch('/parser/templates', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Template saved.'); selectView('parser');
  };
  const list = templates.map(t=>`<div class="muted">• ${t.name} — ${t.supplier_name||''} / ${t.connection_name||''} (${t.format})</div>`).join('') || '<div class="muted">No templates</div>';
  document.querySelector('#tplList').innerHTML = list;
}

async function viewConfigs(){
  const app = document.querySelector('#app');
  const cfg = await authFetch('/config/dropdowns').catch(()=>({route_types:["Direct","SS7","SIM","Local Bypass"], known_hops:["0-Hop","1-Hop","2-Hops","N-Hops"], sender_id_supported:["Dynamic Alphanumeric","Dynamic Numeric","Short code"], registration_required:["Yes","No"], is_exclusive:["Yes","No"]}))
  function csv(a){return (a||[]).join(', ')}
  app.innerHTML = layout(`
    <h2>Dropdown Configs</h2>
    <div class="grid">
      <label>Route Types<br/><input id="rt" value="${csv(cfg.route_types)}"></label>
      <label>Known Hops<br/><input id="kh" value="${csv(cfg.known_hops)}"></label>
      <label>Sender ID Supported<br/><input id="sid" value="${csv(cfg.sender_id_supported)}"></label>
      <label>Registration Required<br/><input id="rr" value="${csv(cfg.registration_required)}"></label>
      <label>Is Exclusive<br/><input id="ix" value="${csv(cfg.is_exclusive)}"></label>
    </div>
    <div class="toolbar"><button class="primary" id="saveCfg">Save</button></div>
  `);
  const split = s => (s||'').split(',').map(x=>x.trim()).filter(Boolean);
  document.querySelector('#saveCfg').onclick = async ()=>{
    const body = {route_types: split(rt.value), known_hops: split(kh.value), sender_id_supported: split(sid.value), registration_required: split(rr.value), is_exclusive: split(ix.value)};
    await authFetch('/config/dropdowns', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Saved.');
  };
}

function boot(){ document.querySelector('#apiBase').textContent = API_BASE; setNav('offers'); selectView('offers'); }
document.getElementById('logout').onclick = ()=>{ localStorage.removeItem(tokenKey); requireLogin(); };

(async function init(){
  document.querySelector('#apiBase').textContent = API_BASE;
  const t = localStorage.getItem(tokenKey);
  if(!t){ return requireLogin(); }
  try{ await authFetch('/'); boot(); }catch{ requireLogin(); }
})();
JS

# ---------- 5) Rebuild & restart api/web ----------
echo "🔁 Rebuilding api & web…"
( cd "$DOCKER" && docker compose build api web && docker compose up -d api web )

echo "✅ Domain overhaul applied."
echo "Open Web UI:  http://localhost:5183   (or http://<your-ip>:5183)"
echo "Login: admin / admin123"
echo "Tip: to point UI at a remote API: localStorage.setItem('API_BASE','http://<ip>:8010'); location.reload()"
