#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
ROUT="$API/routers"
MAIN="$API/main.py"

mkdir -p "$ROUT"
: > "$ROUT/__init__.py"

# 1) Create routers/conf.py
cat > "$ROUT/conf.py" <<'PY'
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
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"],
}

def _ensure_table():
    ddl = """
    CREATE TABLE IF NOT EXISTS config_kv(
      key TEXT PRIMARY KEY,
      value JSONB NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    """
    with engine.begin() as c:
        c.execute(text(ddl))

def _merge_defaults(stored: Any) -> Dict[str, List[str]]:
    # stored can be dict or JSON string (driver dependent)
    if isinstance(stored, str):
        try:
            stored = json.loads(stored)
        except Exception:
            stored = {}
    if not isinstance(stored, dict):
        stored = {}
    merged = DEFAULT_ENUMS.copy()
    merged.update({k: v for k, v in stored.items() if isinstance(v, list)})
    return merged

@router.get("/enums")
def get_enums(_: dict = Depends(get_current_user)):
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).scalar()
    return _merge_defaults(row)

@router.put("/enums")
def put_enums(payload: Dict[str, List[str]] = Body(...), _: dict = Depends(get_current_user)):
    _ensure_table()
    # validate lists of strings
    clean: Dict[str, List[str]] = {}
    for k, v in payload.items():
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            raise HTTPException(status_code=422, detail=f"{k} must be an array of strings")
        clean[k] = v
    data = json.dumps(clean)
    upsert = text("""
      INSERT INTO config_kv(key, value, updated_at)
      VALUES ('enums', CAST(:val AS jsonb), now())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
    """)
    with engine.begin() as c:
        c.execute(upsert, {"val": data})
    return _merge_defaults(clean)
PY

# 2) Ensure it’s included in main.py
if ! grep -q "from app.routers import conf" "$MAIN"; then
  echo -e "\nfrom app.routers import conf" >> "$MAIN"
fi
if ! grep -q "include_router(conf.router" "$MAIN"; then
  echo -e "app.include_router(conf.router, prefix=\"/conf\", tags=[\"Config\"]) # added by add_conf_router" >> "$MAIN"
fi

# 3) Rebuild & restart API
cd "$ROOT/docker"
docker compose up -d --build api

# 4) Quick smoke tests
echo "⏳ Waiting 2s…"; sleep 2

# fetch a token
TOKEN=$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | python3 - <<'PY'
import sys, json
try:
    print(json.load(sys.stdin)["access_token"])
except Exception:
    print("")
PY
)

if [ -z "${TOKEN:-}" ]; then
  echo "❌ Could not get token. Logs:"
  docker logs docker-api-1 --tail=120
  exit 1
fi

echo "🔎 GET /conf/enums"
curl -sS http://localhost:8010/conf/enums -H "Authorization: Bearer $TOKEN"; echo

echo "📝 PUT /conf/enums (sample add)"
curl -sS -X PUT http://localhost:8010/conf/enums \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"route_type":["Direct","SS7","SIM","Local Bypass","Test-X"]}' ; echo
