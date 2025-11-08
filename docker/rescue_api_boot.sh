#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUTERS="$API/routers"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}🛠  API Rescue: patch DB URL, safe migrations, robust main.py${N}"

# 0) Backups
TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/rescue_api_$TS"
mkdir -p "$BACK"
[[ -f "$COMPOSE" ]] && cp -a "$COMPOSE" "$BACK/docker-compose.yml.bak"
[[ -d "$API" ]] && tar -czf "$BACK/api_app.tgz" -C "$ROOT/api" app || true
echo -e "${G}✔ Backups at $BACK${N}"

# 1) Ensure compose uses psycopg v3 driver in DB_URL
if [[ -f "$COMPOSE" ]]; then
  # remove legacy version + container_name noise
  sed -i -E '/^[[:space:]]*version:/d' "$COMPOSE" || true
  sed -i -E '/^[[:space:]]*container_name:/d' "$COMPOSE" || true
  # fix DB_URL
  if grep -q 'DB_URL: *postgresql://' "$COMPOSE"; then
    sed -i 's#DB_URL: *postgresql://#DB_URL: postgresql+psycopg://#' "$COMPOSE"
    echo -e "${G}✔ DB_URL switched to postgresql+psycopg://${N}"
  fi
fi

mkdir -p "$CORE" "$ROUTERS"

# 2) Safe domain migrations (no DO $$, no trigger function)
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
        # countries with up to 3 MCCs
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
          mnc VARCHAR(8),
          mccmnc VARCHAR(12)
        );
        """,
        # offers (flat, denormalized names ok for now)
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
        """,
        # config_kv for enums/settings
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # simple updated_at touch via SQL (avoid triggers)
        "CREATE INDEX IF NOT EXISTS idx_offers_updated_at ON offers(updated_at);",
        "CREATE INDEX IF NOT EXISTS idx_cfg_updated_at ON config_kv(updated_at);",
    ]
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
PY

# 3) Robust main.py: CORS, startup migration, include routers if present; fallback routers otherwise
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Dict, List, Any, Optional
from sqlalchemy import text
import json, os

from app.core.database import engine
origins = ["*"]

app = FastAPI(title="SMS Procurement Manager", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---- run migrations safely on startup (won't crash process) ----
@app.on_event("startup")
def _safe_boot():
    try:
        from app.migrations_domain import migrate_domain
        migrate_domain()
    except Exception as e:
        # Log but do NOT raise to avoid crash loops
        print("!! MIGRATION WARNING:", e)

# health
@app.get("/health")
def health():
    return {"status": "ok"}

# ---- Try to include project routers if they exist ----
def _try_include(module_path: str, prefix: Optional[str] = None):
    try:
        mod = __import__(module_path, fromlist=['router'])
        r = getattr(mod, 'router', None)
        if r is not None:
            app.include_router(r, prefix=prefix or "")
            return True
    except Exception as e:
        print(f"!! Router include failed: {module_path} -> {e}")
    return False

have_conf = _try_include("app.routers.conf")
have_offers = _try_include("app.routers.offers")
have_offers_plus = _try_include("app.routers.offers_plus")
have_networks = _try_include("app.routers.networks")
have_countries = _try_include("app.routers.countries")
have_suppliers = _try_include("app.routers.suppliers")
have_connections = _try_include("app.routers.connections")
have_parsers = _try_include("app.routers.parsers")
have_metrics = _try_include("app.routers.metrics")
_try_include("app.routers.users")
_try_include("app.routers.settings")
_try_include("app.routers.hot")
_try_include("app.routers.lookups")
_try_include("app.routers.create_api")

# ---- Fallback minimal routers to prevent 404s if modules are missing ----
# config/enums fallback
if not have_conf:
    class EnumsModel(BaseModel):
        route_type: List[str] = ["Direct","SS7","SIM","Local Bypass"]
        known_hops: List[str] = ["0-Hop","1-Hop","2-Hops","N-Hops"]
        registration_required: List[str] = ["Yes","No"]
        sender_id_supported: List[str] = ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"]

    def _ensure_cfg():
        ddl = """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """
        with engine.begin() as c:
            c.execute(text(ddl))

    @app.get("/conf/enums")
    def get_enums() -> Dict[str, Any]:
        _ensure_cfg()
        row = None
        with engine.begin() as c:
            row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).fetchone()
        if row and row[0]:
            try:
                return dict(row[0])
            except Exception:
                try:
                    return json.loads(row[0])
                except Exception:
                    pass
        return EnumsModel().dict()

    @app.put("/conf/enums")
    def put_enums(payload: Dict[str, Any]):
        _ensure_cfg()
        j = json.dumps(payload)
        with engine.begin() as c:
            c.execute(text("INSERT INTO config_kv(key,value,updated_at) VALUES('enums', :v, now()) "
                           "ON CONFLICT (key) DO UPDATE SET value=:v, updated_at=now()"),
                      {"v": j})
        return {"ok": True}

# networks fallback
if not have_networks:
    @app.get("/networks/")
    def networks_list():
        with engine.begin() as c:
            rs = c.execute(text("SELECT id, name, country_id, mnc, mccmnc FROM networks ORDER BY id DESC"))
            return [dict(r._mapping) for r in rs]

# offers fallback (list only)
if not have_offers and not have_offers_plus:
    @app.get("/offers/")
    def offers_list(limit: int = 50, offset: int = 0):
        q = text("SELECT * FROM offers ORDER BY updated_at DESC LIMIT :lim OFFSET :off")
        with engine.begin() as c:
            rows = c.execute(q, {"lim": limit, "off": offset})
            return [dict(r._mapping) for r in rows]

# parsers fallback
if not have_parsers:
    @app.get("/parsers/")
    def parsers_list():
        return []

# metrics/trends fallback
if not have_metrics:
    @app.get("/metrics/trends")
    def trends(d: Optional[str] = None):
        # minimal empty structure the UI expects
        return {"date": d, "by_route": {}, "top_networks": []}
PY

# 4) Rebuild + restart stack
echo -e "${Y}🐳 Rebuilding containers…${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 5) Quick checks
sleep 2
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}🔎 Health checks:${N}"
if curl -sS "http://$IP:8010/health" | grep -q '"ok"'; then
  echo -e "  ${G}API health OK${N}"
else
  echo -e "  ${R}API health FAILED — showing last logs:${N}"
  docker logs "$(docker compose -f "$COMPOSE" ps -q api)" --tail=120 || true
fi
echo -e "  UI: http://$IP:5183"
