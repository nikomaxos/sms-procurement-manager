#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
MIG="$API_DIR/migrations_domain.py"
DOCKER_DIR="$ROOT/docker"

# 1) Rewrite migrations_domain.py with safe dollar-quoting (function outside DO; DO only guards trigger)
cat > "$MIG" <<'PY'
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
        # parser templates
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
        # config_kv for enums/settings
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,

        # --- FIXED SECTION ---
        # Create/replace trigger function using a distinct tag ($f$), NOT inside a DO block.
        """
        CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER
        LANGUAGE plpgsql
        AS $f$
        BEGIN
          NEW.updated_at = now();
          RETURN NEW;
        END;
        $f$;
        """,

        # Create trigger only if it doesn't exist (safe DO; no nested function body here).
        """
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='offers_current_touch_updated_at') THEN
            CREATE TRIGGER offers_current_touch_updated_at
            BEFORE UPDATE ON offers_current
            FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
          END IF;
        END
        $$;
        """,
    ]

    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
PY

# 2) Rebuild/start API
cd "$DOCKER_DIR"
docker compose up -d --build api

# 3) Wait for health
echo "⏳ waiting for API on :8010 ..."
for i in $(seq 1 40); do
  if curl -sf http://localhost:8010/openapi.json >/dev/null; then
    echo "✅ API is up"
    break
  fi
  sleep 0.5
  if [ $i -eq 40 ]; then
    echo "❌ timeout. Last logs:"
    docker logs docker-api-1 --tail=200
    exit 1
  fi
done

# 4) Smoke test: login and a couple of endpoints
TOKEN="$(curl -sS -X POST http://localhost:8010/users/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin123' | python3 - <<'PY'
import sys,json
s=sys.stdin.read().strip()
print("" if not s else json.loads(s)["access_token"])
PY
)"

if [ -z "$TOKEN" ]; then
  echo "❌ login failed"
  docker logs docker-api-1 --tail=200
  exit 1
fi
echo "🔐 token ok (${#TOKEN} chars)"

echo "GET /conf/enums"
curl -sS http://localhost:8010/conf/enums -H "Authorization: Bearer $TOKEN" | head -c 200; echo
echo "GET /suppliers/"
curl -sS http://localhost:8010/suppliers/ -H "Authorization: Bearer $TOKEN" | head -c 200; echo
