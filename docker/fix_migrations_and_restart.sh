#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
MODELS="$API_DIR/models/models.py"

# 0) Safety: fix any accidental "primary key=" typos in models (idempotent)
if [ -f "$MODELS" ]; then
  sed -i -E 's/primary[ _]?key=/primary_key=/g' "$MODELS" || true
fi

# 1) Rewrite migrations.py with valid Python (no backslash-escaped quotes)
cat > "$API_DIR/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

DDL = [
    # suppliers
    """
    CREATE TABLE IF NOT EXISTS suppliers(
      id SERIAL PRIMARY KEY,
      organization_name VARCHAR NOT NULL UNIQUE,
      per_delivered BOOLEAN DEFAULT FALSE
    )
    """,
    # supplier connections
    """
    CREATE TABLE IF NOT EXISTS supplier_connections(
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
      connection_name VARCHAR NOT NULL,
      username VARCHAR,
      kannel_smsc VARCHAR,
      charge_model VARCHAR DEFAULT 'Per Submitted',
      UNIQUE(supplier_id, connection_name)
    )
    """,
    # countries / networks
    """
    CREATE TABLE IF NOT EXISTS countries(
      id SERIAL PRIMARY KEY,
      name VARCHAR NOT NULL UNIQUE,
      mcc VARCHAR
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS networks(
      id SERIAL PRIMARY KEY,
      country_id INTEGER REFERENCES countries(id) ON DELETE CASCADE,
      name VARCHAR NOT NULL,
      mnc VARCHAR,
      mccmnc VARCHAR,
      UNIQUE(country_id, name)
    )
    """,
    # offers_current (latest only shown in UI)
    """
    CREATE TABLE IF NOT EXISTS offers_current(
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
      connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE SET NULL,
      network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,
      price DOUBLE PRECISION,
      currency VARCHAR(8) DEFAULT 'EUR',
      effective_date TIMESTAMP,
      previous_price DOUBLE PRECISION,
      route_type VARCHAR(64),
      known_hops VARCHAR(32),
      sender_id_supported VARCHAR(128),
      registration_required VARCHAR(16),
      eta_days INTEGER,
      charge_model VARCHAR(32),
      is_exclusive VARCHAR(8),
      notes TEXT,
      updated_by VARCHAR,
      updated_at TIMESTAMP DEFAULT NOW()
    )
    """,
    # offers_history (full audit)
    """
    CREATE TABLE IF NOT EXISTS offers_history(
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER,
      connection_id INTEGER,
      network_id INTEGER,
      price DOUBLE PRECISION,
      currency VARCHAR(8) DEFAULT 'EUR',
      effective_date TIMESTAMP,
      previous_price DOUBLE PRECISION,
      route_type VARCHAR(64),
      known_hops VARCHAR(32),
      sender_id_supported VARCHAR(128),
      registration_required VARCHAR(16),
      eta_days INTEGER,
      charge_model VARCHAR(32),
      is_exclusive VARCHAR(8),
      notes TEXT,
      updated_by VARCHAR,
      updated_at TIMESTAMP DEFAULT NOW()
    )
    """,
    # email parsing templates
    """
    CREATE TABLE IF NOT EXISTS email_templates(
      id SERIAL PRIMARY KEY,
      supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
      name VARCHAR NOT NULL,
      config JSONB NOT NULL,
      UNIQUE(supplier_id, name)
    )
    """,
    # parsing logs
    """
    CREATE TABLE IF NOT EXISTS parsing_logs(
      id SERIAL PRIMARY KEY,
      created_at TIMESTAMP DEFAULT NOW(),
      level VARCHAR(16),
      message TEXT,
      context JSONB
    )
    """
]

def migrate():
    with engine.begin() as conn:
        for ddl in DDL:
            conn.execute(text(ddl))

def migrate_with_retry(tries: int = 30, delay: float = 1.0):
    import time
    last = None
    for i in range(tries):
        try:
            migrate()
            return True
        except Exception as e:
            last = e
            time.sleep(delay)
    raise RuntimeError(f"DB not ready or migration failed: {last}")
PY

# 2) Rebuild & restart API
cd "$ROOT/docker"
docker compose build api
docker compose up -d api

# 3) Show logs quickly
sleep 2
docker logs docker-api-1 --tail=80 || true

# 4) Ensure admin user exists (idempotent)
docker exec -i docker-api-1 python3 - <<'PY'
from app.core import auth
from app.models import models
from app.core.database import SessionLocal, Base, engine
from app.migrations import migrate_with_retry

migrate_with_retry()
Base.metadata.create_all(bind=engine)
db=SessionLocal()
u=db.query(models.User).filter_by(username="admin").first()
if not u:
    u=models.User(username="admin", password_hash=auth.get_password_hash("admin123"), role="admin")
    db.add(u); db.commit(); print("✅ Admin user created")
else:
    print("ℹ️ Admin user already exists")
db.close()
PY

# 5) Quick probes
echo "🌐 Root:"
curl -sS http://localhost:8010/ ; echo
echo "🔐 Login:"
TOKEN=$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
echo "Token length: ${#TOKEN}"
echo "📦 /offers (should 200 OK, maybe []):"
curl -sS http://localhost:8010/offers/ -H "Authorization: Bearer $TOKEN" ; echo
