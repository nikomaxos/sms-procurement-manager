#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
MAIN="$API_DIR/main.py"
MIG="$API_DIR/migrations.py"

[ -f "$MAIN" ] || { echo "❌ $MAIN missing"; exit 1; }

# 1) Write a solid migrations.py with migrate() + migrate_with_retry()
cat > "$MIG" <<'PY'
from sqlalchemy import text
from app.core.database import engine

DDL = [
    # app-wide settings (JSONB)
    """
    CREATE TABLE IF NOT EXISTS app_settings (
      k TEXT PRIMARY KEY,
      v JSONB
    )
    """,
    # suppliers
    """
    CREATE TABLE IF NOT EXISTS suppliers (
      id SERIAL PRIMARY KEY,
      organization_name VARCHAR NOT NULL UNIQUE
    )
    """,
    # supplier connections (per_delivered is per-connection)
    """
    CREATE TABLE IF NOT EXISTS supplier_connections (
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
      connection_name VARCHAR NOT NULL,
      username VARCHAR,
      kannel_smsc VARCHAR,
      per_delivered BOOLEAN DEFAULT FALSE,
      charge_model VARCHAR DEFAULT 'Per Submitted',
      UNIQUE (supplier_id, connection_name)
    )
    """,
    # countries with extra MCC fields
    """
    CREATE TABLE IF NOT EXISTS countries (
      id SERIAL PRIMARY KEY,
      name VARCHAR NOT NULL UNIQUE,
      mcc VARCHAR,
      mcc2 VARCHAR,
      mcc3 VARCHAR
    )
    """,
    # networks
    """
    CREATE TABLE IF NOT EXISTS networks (
      id SERIAL PRIMARY KEY,
      country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
      name VARCHAR NOT NULL,
      mnc VARCHAR,
      mccmnc VARCHAR,
      UNIQUE (name, country_id)
    )
    """,
    # offers (current)
    """
    CREATE TABLE IF NOT EXISTS offers_current (
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
      connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE SET NULL,
      country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
      network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,
      mccmnc VARCHAR,
      price DOUBLE PRECISION NOT NULL,
      price_effective_date TIMESTAMP NULL,
      previous_price DOUBLE PRECISION NULL,
      route_type VARCHAR,
      known_hops VARCHAR,
      sender_id_supported VARCHAR,
      registration_required VARCHAR,
      eta_days INTEGER,
      charge_model VARCHAR,
      is_exclusive BOOLEAN DEFAULT FALSE,
      notes TEXT,
      updated_by VARCHAR,
      updated_at TIMESTAMP DEFAULT NOW()
    )
    """,
    # useful indexes
    "CREATE INDEX IF NOT EXISTS idx_offers_current_updated_at ON offers_current(updated_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_offers_current_network ON offers_current(network_id)",
    "CREATE INDEX IF NOT EXISTS idx_offers_current_route ON offers_current(route_type)",
]

def migrate():
    with engine.begin() as con:
        for ddl in DDL:
            con.execute(text(ddl))

def migrate_with_retry():
    import time
    last = None
    for _ in range(30):
        try:
            migrate()
            return
        except Exception as e:
            last = e
            time.sleep(0.5)
    raise RuntimeError(f"DB not ready or migration failed: {last}")
PY

echo "✓ wrote $MIG"

# 2) Ensure main.py imports & calls migrate_with_retry() once after app creation
python3 - <<PY "$MAIN"
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")

if "from app.migrations import migrate_with_retry" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom app.migrations import migrate_with_retry")

# insert the call right after "app = FastAPI(...)" if missing
if "migrate_with_retry()" not in s:
    s = re.sub(r"(app\s*=\s*FastAPI\([^\)]*\))",
               r"\\1\nmigrate_with_retry()", s, count=1, flags=re.S)

p.write_text(s, encoding="utf-8")
print("✓ main.py patched to import & call migrate_with_retry()")
PY

# 3) Rebuild + start API container
cd "$ROOT/docker"
docker compose up -d --build api

# 4) Quick smoke tests
sleep 2
echo "== uvicorn import state =="
docker logs docker-api-1 --tail=60 | sed -n '1,60p'
echo "== / root =="
curl -sS http://localhost:8010/ | sed -n '1,120p' || true
echo
echo "== /openapi.json has users/login? =="
curl -sS http://localhost:8010/openapi.json | grep -A1 '"/users/login"' || true
