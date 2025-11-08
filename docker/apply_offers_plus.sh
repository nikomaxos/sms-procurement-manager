#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_APP="$ROOT/api/app"
ROUTERS="$API_APP/routers"
MAIN="$API_APP/main.py"
WEB="$ROOT/web/public"
DOCKER="$ROOT/docker"

mkdir -p "$ROUTERS" "$WEB"

echo "🧱 Writing offers_plus router…"
cat > "$ROUTERS/offers_plus.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from typing import Optional, List, Any, Dict
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
# auth guard (fallback to no-op if missing)
try:
    from app.core.auth import get_current_user as auth_guard
except Exception:
    def auth_guard(): return True

router = APIRouter()

def _migrate():
    stmts = [
        # base reference tables
        """CREATE TABLE IF NOT EXISTS suppliers(
             id SERIAL PRIMARY KEY,
             organization_name VARCHAR NOT NULL,
             per_delivered BOOLEAN DEFAULT FALSE
        )""",
        """CREATE TABLE IF NOT EXISTS supplier_connections(
             id SERIAL PRIMARY KEY,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
             connection_name VARCHAR,
             username VARCHAR,
             kannel_smsc VARCHAR,
             charge_model VARCHAR DEFAULT 'Per Submitted'
        )""",
        """CREATE TABLE IF NOT EXISTS countries(
             id SERIAL PRIMARY KEY,
             name VARCHAR,
             mcc VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS networks(
             id SERIAL PRIMARY KEY,
             country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
             name VARCHAR,
             mnc VARCHAR,
             mccmnc VARCHAR
        )""",
        # offers table (the "current" view with upsert behavior)
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
        # unique constraint for upsert by tuple (supplier, connection, network)
        """DO $$
           BEGIN
             IF NOT EXISTS (
               SELECT 1 FROM pg_indexes
                WHERE schemaname='public'
                  AND indexname='offers_current_uniq') THEN
               CREATE UNIQUE INDEX offers_current_uniq
                 ON offers_current (supplier_id, connection_id, network_id);
             END IF;
           END $$;""",
        # make sure columns exist / types correct (migrations)
        "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS previous_price DOUBLE PRECISION",
        "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS price_effective_date TIMESTAMP",
        "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS mccmnc VARCHAR",
        "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS country_id INTEGER",
        # sender_id_supported to jsonb
        """DO $$
           BEGIN
             IF EXISTS (
               SELECT 1 FROM information_schema.columns
               WHERE table_name='offers_current' AND column_name='sender_id_supported'
                 AND udt_name NOT IN ('json','jsonb')
             ) THEN
               ALTER TABLE offers_current
                 ALTER COLUMN sender_id_supported TYPE JSONB
                 USING CASE
                   WHEN sender_id_supported IS NULL OR sender_id_supported='' THEN '[]'::jsonb
                   WHEN sender_id_supported LIKE '%[%' THEN sender_id_supported::jsonb
                   ELSE to_jsonb( string_to_array(sender_id_supported, ',') )
                 END;
             END IF;
           END $$;""",
        # backfill country_id/mccmnc when possible
        """UPDATE offers_current oc
              SET mccmnc = n.mccmnc
            FROM networks n
           WHERE oc.network_id = n.id AND oc.mccmnc IS NULL""",
        """UPDATE offers_current oc
              SET country_id = n.country_id
            FROM networks n
           WHERE oc.network_id = n.id AND oc.country_id IS NULL""",
    ]
    with engine.begin() as conn:
        for s in stmts:
            conn.execute(text(s))

_migrate()

def rowdict(r): return dict(r._mapping) if hasattr(r,"_mapping") else dict(r)

# ====== Schemas ======
class OfferIn(BaseModel):
    supplier_id: int
    connection_id: int
    # either network_id or mccmnc (or both)
    network_id: Optional[int] = None
    mccmnc: Optional[str] = None
    price: float
    currency: str = "EUR"
    price_effective_date: Optional[str] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: List[str] = []
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    # charge model is inherited; allow override but we will fill from connection if missing
    charge_model: Optional[str] = None
    is_exclusive: Optional[str] = None
    notes: Optional[str] = None

class OfferPatch(BaseModel):
    # non-editable: supplier_id, connection_id, country (derived)
    network_id: Optional[int] = None
    mccmnc: Optional[str] = None
    price: Optional[float] = None
    currency: Optional[str] = None
    price_effective_date: Optional[str] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[List[str]] = None
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    is_exclusive: Optional[str] = None
    notes: Optional[str] = None

# ====== Helpers ======
def _resolve_net_and_country(conn, network_id: Optional[int], mccmnc: Optional[str]):
    nid, mm, cid = network_id, mccmnc, None
    if nid is None and mm:
        r = conn.execute(text("SELECT id, country_id FROM networks WHERE mccmnc = :mm LIMIT 1"), {"mm": mm}).fetchone()
        if r: nid, cid = r.id, r.country_id
    elif nid is not None and not mm:
        r = conn.execute(text("SELECT mccmnc, country_id FROM networks WHERE id=:nid"), {"nid": nid}).fetchone()
        if r: mm, cid = r.mccmnc, r.country_id
    elif nid is not None and mm is not None:
        r = conn.execute(text("SELECT mccmnc, country_id FROM networks WHERE id=:nid"), {"nid": nid}).fetchone()
        if r and (r.mccmnc != mm):
            # prefer network_id truth; sync mccmnc
            mm, cid = r.mccmnc, r.country_id
    if cid is None and nid is not None:
        r = conn.execute(text("SELECT country_id FROM networks WHERE id=:nid"), {"nid": nid}).fetchone()
        if r: cid = r.country_id
    return nid, mm, cid

def _inherit_charge_model(conn, connection_id: int, provided: Optional[str]) -> str:
    if provided:
        return provided
    r = conn.execute(text("SELECT charge_model FROM supplier_connections WHERE id=:cid"), {"cid": connection_id}).fetchone()
    return (r.charge_model if r and r.charge_model else "Per Submitted")

# ====== Read dictionaries for UI binding ======
@router.get("/countries/")
def list_countries(user=Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text("SELECT id, name, mcc FROM countries ORDER BY name")).fetchall()
    return [rowdict(r) for r in rows]

@router.get("/networks/")
def list_networks(country_id: Optional[int] = None, user=Depends(auth_guard)):
    with engine.begin() as conn:
        if country_id:
            rows = conn.execute(text(
                "SELECT id, country_id, name, mnc, mccmnc FROM networks WHERE country_id=:cid ORDER BY name"
            ), {"cid": country_id}).fetchall()
        else:
            rows = conn.execute(text(
                "SELECT id, country_id, name, mnc, mccmnc FROM networks ORDER BY name"
            )).fetchall()
    return [rowdict(r) for r in rows]

# ====== Offers: list with filters & joins ======
@router.get("/offers/")
def list_offers(
    country_id: Optional[int] = None,
    route_type: Optional[str] = None,
    known_hops: Optional[str] = None,
    supplier_name: Optional[str] = None,
    connection_name: Optional[str] = None,
    sender_id_supported: Optional[str] = None,
    registration_required: Optional[str] = None,
    is_exclusive: Optional[str] = None,
    limit: int = Query(200, ge=1, le=500),
    user=Depends(auth_guard)
):
    q = """
    SELECT
      oc.id, oc.supplier_id, oc.connection_id, oc.country_id, oc.network_id,
      s.organization_name AS supplier_name,
      sc.connection_name AS connection_name,
      sc.username        AS smsc_username,
      c.name             AS country_name,
      n.name             AS network_name,
      n.mccmnc           AS mccmnc,
      oc.price, oc.previous_price, oc.currency, oc.price_effective_date,
      oc.route_type, oc.known_hops, oc.sender_id_supported, oc.registration_required,
      oc.eta_days, oc.charge_model, oc.is_exclusive, oc.notes,
      oc.updated_by, oc.updated_at
    FROM offers_current oc
      LEFT JOIN supplier_connections sc ON sc.id = oc.connection_id
      LEFT JOIN suppliers s ON s.id = oc.supplier_id
      LEFT JOIN networks n ON n.id = oc.network_id
      LEFT JOIN countries c ON c.id = n.country_id
    WHERE 1=1
    """
    params: Dict[str, Any] = {}
    if country_id:
        q += " AND COALESCE(oc.country_id, c.id) = :country_id"
        params["country_id"] = country_id
    if route_type:
        q += " AND oc.route_type = :route_type"
        params["route_type"] = route_type
    if known_hops:
        q += " AND oc.known_hops = :known_hops"
        params["known_hops"] = known_hops
    if supplier_name:
        q += " AND s.organization_name ILIKE :sname"
        params["sname"] = f"%{supplier_name}%"
    if connection_name:
        q += " AND sc.connection_name ILIKE :cname"
        params["cname"] = f"%{connection_name}%"
    if sender_id_supported:
        # expect a single value - contained in jsonb array
        q += " AND oc.sender_id_supported @> :sid::jsonb"
        params["sid"] = f'["{sender_id_supported}"]'
    if registration_required:
        q += " AND oc.registration_required = :reg"
        params["reg"] = registration_required
    if is_exclusive:
        q += " AND oc.is_exclusive = :iex"
        params["iex"] = is_exclusive

    q += " ORDER BY oc.updated_at DESC LIMIT :limit"
    params["limit"] = limit

    with engine.begin() as conn:
        rows = conn.execute(text(q), params).fetchall()
    # normalize sender_id_supported to list
    out = []
    for r in rows:
        d = rowdict(r)
        if isinstance(d.get("sender_id_supported"), str):
            d["sender_id_supported"] = [x.strip() for x in d["sender_id_supported"].split(",") if x.strip()]
        out.append(d)
    return out

# ====== Offer detail ======
@router.get("/offers/{offer_id}")
def get_offer(offer_id: int, user=Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            SELECT
              oc.*, s.organization_name AS supplier_name,
              sc.connection_name, sc.username AS smsc_username,
              c.name AS country_name, n.name AS network_name, n.mccmnc AS mccmnc_net
            FROM offers_current oc
              LEFT JOIN supplier_connections sc ON sc.id=oc.connection_id
              LEFT JOIN suppliers s ON s.id=oc.supplier_id
              LEFT JOIN networks n ON n.id=oc.network_id
              LEFT JOIN countries c ON c.id=n.country_id
            WHERE oc.id=:id
        """), {"id": offer_id}).fetchone()
    if not r:
        raise HTTPException(404, "Offer not found")
    d = rowdict(r)
    # unify mccmnc view
    d["mccmnc"] = d.get("mccmnc") or d.get("mccmnc_net")
    if isinstance(d.get("sender_id_supported"), str):
        d["sender_id_supported"] = [x.strip() for x in d["sender_id_supported"].split(",") if x.strip()]
    return d

# ====== Create (upsert on tuple), auto-derive charge model & country/mccmnc ======
@router.post("/offers/")
def create_offer(body: OfferIn, user=Depends(auth_guard)):
    with engine.begin() as conn:
        nid, mm, cid = _resolve_net_and_country(conn, body.network_id, body.mccmnc)
        if not nid and not mm:
            raise HTTPException(400, "Provide network_id or mccmnc")

        cm = _inherit_charge_model(conn, body.connection_id, body.charge_model)

        # find previous price for the same tuple
        prev = conn.execute(text("""
            SELECT price FROM offers_current
            WHERE supplier_id=:s AND connection_id=:c AND COALESCE(network_id,0)=COALESCE(:n,0)
            LIMIT 1
        """), {"s": body.supplier_id, "c": body.connection_id, "n": nid}).fetchone()
        previous_price = prev.price if prev else None

        # UPSERT
        r = conn.execute(text("""
            INSERT INTO offers_current(
              supplier_id, connection_id, country_id, network_id, mccmnc,
              price, previous_price, currency, price_effective_date,
              route_type, known_hops, sender_id_supported, registration_required,
              eta_days, charge_model, is_exclusive, notes, updated_by, updated_at
            ) VALUES(
              :supplier_id, :connection_id, :country_id, :network_id, :mccmnc,
              :price, :previous_price, :currency, COALESCE(NULLIF(:eff,''), NOW())::timestamp,
              :route_type, :known_hops, :sender_id_supported::jsonb, :registration_required,
              :eta_days, :charge_model, :is_exclusive, :notes, 'webui', NOW()
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
              updated_by = 'webui',
              updated_at = NOW()
            RETURNING id
        """), {
            "supplier_id": body.supplier_id,
            "connection_id": body.connection_id,
            "country_id": cid,
            "network_id": nid,
            "mccmnc": mm,
            "price": body.price,
            "previous_price": previous_price,
            "currency": body.currency,
            "eff": body.price_effective_date or "",
            "route_type": body.route_type,
            "known_hops": body.known_hops,
            "sender_id_supported": body.sender_id_supported or [],
            "registration_required": body.registration_required,
            "eta_days": body.eta_days,
            "charge_model": cm,
            "is_exclusive": body.is_exclusive,
            "notes": body.notes
        }).fetchone()
    return {"id": r.id}

# ====== Update (editable fields only) ======
@router.patch("/offers/{offer_id}")
def update_offer(offer_id: int, body: OfferPatch, user=Depends(auth_guard)):
    with engine.begin() as conn:
        cur = conn.execute(text("SELECT * FROM offers_current WHERE id=:id"), {"id": offer_id}).fetchone()
        if not cur:
            raise HTTPException(404, "Offer not found")

        nid, mm, cid = _resolve_net_and_country(conn, body.network_id, body.mccmnc)
        if body.network_id is None and body.mccmnc is None:
            # keep current values
            nid = cur.network_id
            mm  = cur.mccmnc
            cid = cur.country_id

        # build partial update
        q = "UPDATE offers_current SET "
        sets = []
        p = {"id": offer_id}
        def S(col, val, key):
            if val is not None:
                sets.append(f"{col} = :{key}")
                p[key] = val
        # editable fields
        S("price", body.price, "price")
        S("currency", body.currency, "currency")
        S("price_effective_date", body.price_effective_date, "eff")
        S("route_type", body.route_type, "rt")
        S("known_hops", body.known_hops, "kh")
        if body.sender_id_supported is not None:
            sets.append("sender_id_supported = :sid::jsonb")
            p["sid"] = body.sender_id_supported
        S("registration_required", body.registration_required, "reg")
        S("eta_days", body.eta_days, "eta")
        S("is_exclusive", body.is_exclusive, "iex")
        S("notes", body.notes, "notes")

        # network/mccmnc/country (editable)
        sets += ["network_id = :nid", "mccmnc = :mm", "country_id = :cid"]
        p.update({"nid": nid, "mm": mm, "cid": cid})

        if not sets:
            return {"ok": True}
        q += ", ".join(sets) + ", updated_at=NOW(), updated_by='webui' WHERE id=:id"
        conn.execute(text(q), p)

    return {"ok": True}
PY

echo "🧩 Ensuring router is included in main.py…"
if ! grep -q "from app.routers import offers_plus" "$MAIN"; then
  cat >> "$MAIN" <<'PY'

# Attach advanced offers router
try:
    from app.routers import offers_plus
    app.include_router(offers_plus.router)
except Exception as e:
    print("WARN: could not include offers_plus:", e)
PY
fi

echo "🎨 Updating Web UI (filters + create + detail edit)…"
# index.html (keeps the existing look from previous step, just ensures links)
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
    <small>v1.0 — <a href="#" id="logout">Logout</a></small>
  </footer>
  <script src="/main.js"></script>
</body>
</html>
HTML

# main.css – same skeleton as earlier (kept concise)
cat > "$WEB/main.css" <<'CSS'
:root { --bg:#0b1220; --card:#121a2b; --text:#eaf1ff; --muted:#9fb0d1; --acc:#5da0ff; }
*{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,Segoe UI,Roboto}
header,footer{padding:12px 16px;background:linear-gradient(90deg,#0e182c,#0b1220)}
h1{margin:0;font-size:18px}
#apiInfo{float:right;color:var(--muted)}
nav{display:flex;gap:8px;flex-wrap:wrap;padding:8px 16px;background:#0e1626;border-bottom:1px solid #1b2741}
nav button{background:#15223a;color:var(--text);border:1px solid #223152;border-radius:10px;padding:8px 12px;cursor:pointer}
nav button.active{background:var(--acc);border-color:var(--acc);color:#04122a}
#app{padding:16px}
.card{background:var(--card);padding:16px;border-radius:14px;border:1px solid #1b2741;box-shadow:0 4px 18px #00000066}
.toolbar{display:flex;gap:8px;align-items:center;margin:8px 0;flex-wrap:wrap}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}
input,select,textarea{background:#0e1626;color:var(--text);border:1px solid #223152;border-radius:8px;padding:8px}
button.primary{background:var(--acc);border:none;color:#04122a;border-radius:10px;padding:8px 12px;font-weight:600}
.table{width:100%;border-collapse:collapse;margin-top:8px}
.table th,.table td{padding:8px;border-bottom:1px solid #1b2741}
a.link{color:#9cc6ff;cursor:pointer;text-decoration:underline}
.muted{color:var(--muted)}
.login{max-width:360px;margin:40px auto}
.right{float:right}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;border:1px solid #28406c;color:#bcd1f3;font-size:12px}
CSS

# main.js – offers list with filters, create, detail edit (exact fields)
cat > "$WEB/main.js" <<'JS'
const API_BASE = localStorage.getItem("API_BASE") || `http://${location.hostname}:8010`;
const tokenKey = "spm_token";

const navItems = [
  {key:"offers", label:"Suppliers Offers", view: viewOffers},
  {key:"suppliers", label:"Suppliers", view: viewSuppliers},
  {key:"configs", label:"Dropdown Configs", view: viewConfigs},
];

function setNav(active){
  const n=document.querySelector('#nav');
  n.innerHTML = navItems.map(it=>`<button data-k="${it.key}" class="${active===it.key?'active':''}">${it.label}</button>`).join("");
  n.querySelectorAll('button').forEach(b=>b.onclick=()=>selectView(b.dataset.k));
}
function selectView(k){ (navItems.find(x=>x.key===k)||navItems[0]).view(); setNav(k); }
function layout(inner){ return `<div class="card">${inner}</div>`; }

async function authFetch(path, opts={}){
  const t = localStorage.getItem(tokenKey);
  const h = opts.headers || {};
  if (t) h["Authorization"] = `Bearer ${t}`;
  opts.headers = h;
  const res = await fetch(`${API_BASE}${path}`, opts);
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
    const r = await fetch(`${API_BASE}/users/login`, { method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body });
    if(!r.ok){ alert('Login failed'); return; }
    const j = await r.json(); localStorage.setItem(tokenKey, j.access_token); boot();
  };
}

function badge(v){ return v?`<span class="badge">${v}</span>`:""; }

async function dicts(){
  const [countries, networks, cfg] = await Promise.all([
    authFetch('/countries/').catch(()=>[]),
    authFetch('/networks/').catch(()=>[]),
    authFetch('/config/dropdowns').catch(()=>({
      route_types:["Direct","SS7","SIM","Local Bypass"],
      known_hops:["0-Hop","1-Hop","2-Hops","N-Hops"],
      sender_id_supported:["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
      registration_required:["Yes","No"],
      is_exclusive:["Yes","No"],
    })),
  ]);
  const byIdNet = Object.fromEntries(networks.map(n=>[String(n.id), n]));
  const byMccmnc = Object.fromEntries(networks.map(n=>[String(n.mccmnc||""), n]));
  const countriesById = Object.fromEntries(countries.map(c=>[String(c.id), c]));
  return {countries, networks, cfg, byIdNet, byMccmnc, countriesById};
}

function options(arr, v){ return (arr||[]).map(x=>`<option ${String(x)===String(v)?'selected':''}>${x}</option>`).join(''); }
function optionsObj(arr, v, idKey, nameKey){ return (arr||[]).map(o=>`<option value="${o[idKey]}" ${String(o[idKey])===String(v)?'selected':''}>${o[nameKey]}</option>`).join(''); }

async function viewOffers(){
  const app = document.querySelector('#app');
  const D = await dicts();

  // Filters UI
  app.innerHTML = layout(`
    <h2>Suppliers Offers</h2>
    <div class="card" style="margin:12px 0">
      <div class="grid">
        <div><label>Country<br/>
          <select id="f_country"><option value="">(All)</option>${optionsObj(D.countries, "", "id", "name")}</select>
        </label></div>
        <div><label>Route Type<br/>
          <select id="f_rt"><option value="">(All)</option>${options(D.cfg.route_types,"")}</select>
        </label></div>
        <div><label>Known Hops<br/>
          <select id="f_kh"><option value="">(All)</option>${options(D.cfg.known_hops,"")}</select>
        </label></div>
        <div><label>Supplier Name<br/><input id="f_sname" placeholder="contains…"></label></div>
        <div><label>Connection Name<br/><input id="f_cname" placeholder="contains…"></label></div>
        <div><label>Sender ID Supported<br/>
          <select id="f_sid"><option value="">(All)</option>${options(D.cfg.sender_id_supported,"")}</select>
        </label></div>
        <div><label>Registration Required<br/>
          <select id="f_reg"><option value="">(All)</option>${options(D.cfg.registration_required,"")}</select>
        </label></div>
        <div><label>Is Exclusive<br/>
          <select id="f_iex"><option value="">(All)</option>${options(D.cfg.is_exclusive,"")}</select>
        </label></div>
      </div>
      <div class="toolbar"><button class="primary" id="applyFilters">Apply Filters</button></div>
    </div>

    <div id="createBox" class="card" style="margin:12px 0">
      <h3>Create Offer</h3>
      <div class="grid">
        <div><label>Supplier ID<br/><input id="c_supplier" type="number"></label></div>
        <div><label>Connection ID<br/><input id="c_conn" type="number"></label></div>
        <div><label>Network<br/>
          <select id="c_network"><option value="">(choose)</option>${optionsObj(D.networks, "", "id", "name")}</select></label></div>
        <div><label>MCC-MNC<br/>
          <select id="c_mccmnc"><option value="">(choose)</option>${options(D.networks.map(n=>n.mccmnc).filter(Boolean),"")}</select></label></div>
        <div><label>Price<br/><input id="c_price" type="number" step="0.0001"></label></div>
        <div><label>Price Effective Date<br/><input id="c_eff" type="datetime-local"></label></div>
        <div><label>Route Type<br/><select id="c_rt">${options(D.cfg.route_types,"Direct")}</select></label></div>
        <div><label>Known Hops<br/><select id="c_kh">${options(D.cfg.known_hops,"0-Hop")}</select></label></div>
        <div><label>Sender ID Supported<br/>
          <select id="c_sid" multiple size="3">${options(D.cfg.sender_id_supported,"")}</select></label></div>
        <div><label>Registration Required<br/><select id="c_reg">${options(D.cfg.registration_required,"No")}</select></label></div>
        <div><label>ETA in days<br/><input id="c_eta" type="number" min="0"></label></div>
        <div><label>Is Exclusive<br/><select id="c_iex">${options(D.cfg.is_exclusive,"No")}</select></label></div>
        <div style="grid-column:1/-1"><label>Notes<br/><textarea id="c_notes" rows="3" style="width:100%"></textarea></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="createBtn">Create</button></div>
    </div>

    <div id="listBox" class="card"></div>
    <div id="detailBox" class="card" style="margin-top:12px;display:none"></div>
  `);

  // dynamic link: network <-> mccmnc (create form)
  const netSel = document.querySelector('#c_network');
  const mmSel  = document.querySelector('#c_mccmnc');
  netSel.onchange = ()=>{ const n = D.byIdNet[netSel.value]; if(n) mmSel.value = n.mccmnc || ""; };
  mmSel.onchange  = ()=>{ const n = D.byMccmnc[mmSel.value]; if(n) netSel.value = String(n.id); };

  document.querySelector('#createBtn').onclick = async ()=>{
    const sidSel = Array.from(document.querySelector('#c_sid').selectedOptions).map(o=>o.value);
    const body = {
      supplier_id: parseInt(c_supplier.value,10),
      connection_id: parseInt(c_conn.value,10),
      network_id: netSel.value ? parseInt(netSel.value,10) : null,
      mccmnc: mmSel.value || null,
      price: parseFloat(c_price.value),
      currency: "EUR",
      price_effective_date: c_eff.value ? new Date(c_eff.value).toISOString() : null,
      route_type: c_rt.value,
      known_hops: c_kh.value,
      sender_id_supported: sidSel,
      registration_required: c_reg.value,
      eta_days: c_eta.value ? parseInt(c_eta.value,10) : null,
      is_exclusive: c_iex.value,
      notes: c_notes.value || null
    };
    await authFetch('/offers/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    await loadList();
    alert('Offer saved (Charge Model auto-inherited).');
  };

  document.querySelector('#applyFilters').onclick = loadList;

  async function loadList(){
    const params = new URLSearchParams();
    if (f_country.value) params.set('country_id', f_country.value);
    if (f_rt.value) params.set('route_type', f_rt.value);
    if (f_kh.value) params.set('known_hops', f_kh.value);
    if (f_sname.value) params.set('supplier_name', f_sname.value);
    if (f_cname.value) params.set('connection_name', f_cname.value);
    if (f_sid.value) params.set('sender_id_supported', f_sid.value);
    if (f_reg.value) params.set('registration_required', f_reg.value);
    if (f_iex.value) params.set('is_exclusive', f_iex.value);

    const data = await authFetch(`/offers/?${params.toString()}`);
    const rows = (data||[]).map(d=>`
      <tr data-id="${d.id}" class="rowlink">
        <td>${d.supplier_name||''}</td>
        <td>${(d.connection_name||'')}${d.smsc_username?`<br/><span class="muted">${d.smsc_username}</span>`:''}</td>
        <td>${d.country_name||''}</td>
        <td>${d.network_name||''}</td>
        <td>${d.mccmnc||''}</td>
        <td>${d.price??''}</td>
        <td>${d.price_effective_date?new Date(d.price_effective_date).toLocaleString():''}</td>
        <td>${d.previous_price==null?'—':d.previous_price}</td>
        <td>${badge(d.route_type)}</td>
        <td>${badge(d.known_hops)}</td>
        <td>${(d.sender_id_supported||[]).join(', ')}</td>
        <td>${badge(d.registration_required)}</td>
        <td>${d.eta_days??''}</td>
        <td>${d.charge_model||''}</td>
        <td>${badge(d.is_exclusive)}</td>
        <td>${d.notes?('<span class="muted">'+d.notes+'</span>'):''}</td>
      </tr>
    `).join('');
    listBox.innerHTML = `
      <table class="table">
        <tr>
          <th>Supplier Name</th>
          <th>Connection</th>
          <th>Country</th>
          <th>Network</th>
          <th>MCC-MNC</th>
          <th>Price</th>
          <th>Price Effective Date</th>
          <th>Previous price</th>
          <th>Route Type</th>
          <th>Known Hops</th>
          <th>Sender ID Supported</th>
          <th>Registration required</th>
          <th>ETA in days</th>
          <th>Charge Model</th>
          <th>Is Exclusive</th>
          <th>Notes</th>
        </tr>${rows || `<tr><td colspan="16" class="muted">No records</td></tr>`}
      </table>`;
    listBox.querySelectorAll('.rowlink').forEach(tr=>{
      tr.onclick = ()=> openDetail(tr.dataset.id);
    });
  }

  async function openDetail(id){
    const d = await authFetch(`/offers/${id}`);
    // Non editable: Supplier Name, Connection, Country
    const sidList = (await authFetch('/config/dropdowns')).sender_id_supported || ["Dynamic Alphanumeric","Dynamic Numeric","Short code"];
    // networks for binding
    const netOptions = optionsObj(D.networks, d.network_id, "id", "name");
    const mmOptions  = options(D.networks.map(n=>n.mccmnc).filter(Boolean), d.mccmnc||d.mccmnc_net);
    const sidBoxes = sidList.map(v=>{
      const checked = (d.sender_id_supported||[]).includes(v) ? 'checked' : '';
      return `<label><input type="checkbox" name="sid" value="${v}" ${checked}> ${v}</label>`;
    }).join('<br/>');
    detailBox.style.display = '';
    detailBox.innerHTML = `
      <h3>Offer #${d.id}</h3>
      <div class="grid">
        <div><label>Supplier Name<br/><input value="${d.supplier_name||''}" disabled></label></div>
        <div><label>Connection<br/><input value="${(d.connection_name||'')+(d.smsc_username?(' / '+d.smsc_username):'')}" disabled></label></div>
        <div><label>Country<br/><input value="${d.country_name||''}" disabled></label></div>
        <div><label>Network<br/><select id="e_network">${netOptions}</select></label></div>
        <div><label>MCC-MNC<br/><select id="e_mccmnc">${mmOptions}</select></label></div>
        <div><label>Price<br/><input id="e_price" type="number" step="0.0001" value="${d.price??''}"></label></div>
        <div><label>Price Effective Date<br/><input id="e_eff" type="datetime-local" value="${d.price_effective_date? new Date(d.price_effective_date).toISOString().slice(0,16):''}"></label></div>
        <div><label>Previous price<br/><input value="${d.previous_price==null?'—':d.previous_price}" disabled></label></div>
        <div><label>Route Type<br/>
          <select id="e_rt">${options((await authFetch('/config/dropdowns')).route_types,d.route_type||'')}</select></label></div>
        <div><label>Known Hops<br/>
          <select id="e_kh">${options((await authFetch('/config/dropdowns')).known_hops,d.known_hops||'')}</select></label></div>
        <div><label>Sender ID Supported<br/>${sidBoxes}</label></div>
        <div><label>Registration required<br/>
          <select id="e_reg">${options((await authFetch('/config/dropdowns')).registration_required,d.registration_required||'')}</select></label></div>
        <div><label>ETA in days<br/><input id="e_eta" type="number" min="0" value="${d.eta_days??''}"></label></div>
        <div><label>Is Exclusive<br/>
          <select id="e_iex">${options((await authFetch('/config/dropdowns')).is_exclusive,d.is_exclusive||'')}</select></label></div>
        <div style="grid-column:1/-1"><label>Notes<br/><textarea id="e_notes" rows="3" style="width:100%">${d.notes||''}</textarea></label></div>
      </div>
      <div class="toolbar"><button class="primary" id="saveDetail">Save</button></div>
    `;
    const eNet = document.querySelector('#e_network');
    const eMM  = document.querySelector('#e_mccmnc');
    eNet.onchange = ()=>{ const n = D.byIdNet[eNet.value]; if(n) eMM.value = n.mccmnc||""; };
    eMM.onchange  = ()=>{ const n = D.byMccmnc[eMM.value]; if(n) eNet.value = String(n.id); };

    document.querySelector('#saveDetail').onclick = async ()=>{
      const eff = document.querySelector('#e_eff').value;
      const sidVals = Array.from(document.querySelectorAll('input[name="sid"]:checked')).map(i=>i.value);
      const body = {
        network_id: eNet.value? parseInt(eNet.value,10): null,
        mccmnc: eMM.value || null,
        price: document.querySelector('#e_price').value? parseFloat(document.querySelector('#e_price').value): null,
        price_effective_date: eff? new Date(eff).toISOString(): null,
        route_type: document.querySelector('#e_rt').value||null,
        known_hops: document.querySelector('#e_kh').value||null,
        sender_id_supported: sidVals,
        registration_required: document.querySelector('#e_reg').value||null,
        eta_days: document.querySelector('#e_eta').value? parseInt(document.querySelector('#e_eta').value,10): null,
        is_exclusive: document.querySelector('#e_iex').value||null,
        notes: document.querySelector('#e_notes').value||null,
      };
      await authFetch(`/offers/${d.id}`, {method:'PATCH', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
      await loadList();
      alert('Saved.');
    };
  }

  await loadList();
}

async function viewSuppliers(){
  const app = document.querySelector('#app');
  const s = await authFetch('/suppliers/').catch(()=>[]);
  app.innerHTML = layout(`
    <h2>Suppliers</h2>
    <div class="toolbar">
      <input id="org" placeholder="Organization Name">
      <label><input id="pd" type="checkbox"> Per Delivered</label>
      <button class="primary" id="add">Add</button>
    </div>
    <table class="table">
    <tr><th>ID</th><th>Supplier Name</th><th>Per Delivered</th></tr>
    ${s.map(x=>`<tr><td>${x.id}</td><td>${x.organization_name}</td><td>${x.per_delivered?'Yes':'No'}</td></tr>`).join('')||`<tr><td colspan="3" class="muted">Empty</td></tr>`}
    </table>
  `);
  document.querySelector('#add').onclick = async ()=>{
    const body={organization_name: org.value, per_delivered: pd.checked};
    await authFetch('/suppliers/', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    viewSuppliers();
  };
}

async function viewConfigs(){
  const app = document.querySelector('#app');
  const cfg = await authFetch('/config/dropdowns').catch(()=>({
    route_types:["Direct","SS7","SIM","Local Bypass"],
    known_hops:["0-Hop","1-Hop","2-Hops","N-Hops"],
    sender_id_supported:["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
    registration_required:["Yes","No"],
    is_exclusive:["Yes","No"]
  }));
  function csv(a){return (a||[]).join(', ')}
  app.innerHTML = layout(`
    <h2>Dropdown Configurations</h2>
    <div class="grid">
      <label>Route Types<br/><input id="rt" value="${csv(cfg.route_types)}"></label>
      <label>Known Hops<br/><input id="kh" value="${csv(cfg.known_hops)}"></label>
      <label>Sender ID Supported<br/><input id="sid" value="${csv(cfg.sender_id_supported)}"></label>
      <label>Registration Required<br/><input id="rr" value="${csv(cfg.registration_required)}"></label>
      <label>Is Exclusive<br/><input id="iex" value="${csv(cfg.is_exclusive)}"></label>
    </div>
    <div class="toolbar"><button class="primary" id="saveCfg">Save</button></div>
  `);
  const split = s => (s||'').split(',').map(x=>x.trim()).filter(Boolean);
  document.querySelector('#saveCfg').onclick = async ()=>{
    const body = {route_types: split(rt.value), known_hops: split(kh.value), sender_id_supported: split(sid.value), registration_required: split(rr.value), is_exclusive: split(iex.value)};
    await authFetch('/config/dropdowns',{method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    alert('Saved.');
  };
}

function boot(){
  document.querySelector('#apiBase').textContent = API_BASE;
  setNav("offers"); selectView("offers");
}
document.getElementById('logout').onclick = ()=>{ localStorage.removeItem(tokenKey); requireLogin(); };

(async function init(){
  document.querySelector('#apiBase').textContent = API_BASE;
  const t = localStorage.getItem(tokenKey);
  if(!t){ return requireLogin(); }
  try{ await authFetch('/'); boot(); }catch{ requireLogin(); }
})();
JS

echo "🔁 Rebuild & restart api/web…"
cd "$DOCKER"
docker compose build api web
docker compose up -d api web

echo "✅ Done."
echo "Open Web UI:  http://localhost:5183  (or http://<your-ip>:5183)"
echo "Login: admin / admin123"
echo "Tip: if needed -> localStorage.setItem('API_BASE','http://<ip>:8010'); location.reload()"
