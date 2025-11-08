#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
ROUTERS="$API/routers"
MAIN="$API/main.py"

mkdir -p "$ROUTERS"
: > "$ROUTERS/__init__.py"

# 1) Create routers/conf.py
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
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"],
}

def _ensure_table() -> None:
    ddl = """
    CREATE TABLE IF NOT EXISTS config_kv(
      key TEXT PRIMARY KEY,
      value JSONB NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    """
    with engine.begin() as c:
        c.execute(text(ddl))

def _coerce_dict(stored: Any) -> Dict[str, Any]:
    if stored is None:
        return {}
    if isinstance(stored, (bytes, bytearray)):
        stored = stored.decode("utf-8", errors="ignore")
    if isinstance(stored, str):
        try:
            return json.loads(stored)
        except Exception:
            return {}
    if isinstance(stored, dict):
        return stored
    return {}

@router.get("/enums")
def get_enums(_: dict = Depends(get_current_user)):
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).scalar()
    data = _coerce_dict(row)
    merged = DEFAULT_ENUMS.copy()
    # keep only list-of-strings
    for k, v in data.items():
        if isinstance(v, list) and all(isinstance(x, str) for x in v):
            merged[k] = v
    return merged

@router.put("/enums")
def put_enums(payload: Dict[str, List[str]] = Body(...), _: dict = Depends(get_current_user)):
    _ensure_table()
    clean: Dict[str, List[str]] = {}
    for k, v in payload.items():
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            raise HTTPException(status_code=422, detail=f"{k} must be an array of strings")
        clean[k] = v
    js = json.dumps(clean)
    upsert = text("""
      INSERT INTO config_kv (key, value, updated_at)
      VALUES ('enums', CAST(:js AS jsonb), now())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
    """)
    with engine.begin() as c:
        c.execute(upsert, {"js": js})
    merged = DEFAULT_ENUMS.copy()
    merged.update(clean)
    return merged

@router.get("/ping")
def ping():
    return {"ok": True}
PY

# 2) Wire router into main.py (idempotent)
if ! grep -q "from app.routers import conf" "$MAIN"; then
  printf "\nfrom app.routers import conf\n" >> "$MAIN"
fi

if ! grep -q 'include_router(conf.router' "$MAIN"; then
  printf 'app.include_router(conf.router, prefix="/conf", tags=["Config"])\n' >> "$MAIN"
fi

# 3) Rebuild & restart API
cd "$ROOT/docker"
docker compose up -d --build api

# 4) Verify
sleep 2
TOKEN="$(curl -sS -X POST http://localhost:8010/users/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin123' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"

echo "🔎 GET /conf/enums"
curl -sS http://localhost:8010/conf/enums -H "Authorization: Bearer $TOKEN"; echo

echo "📝 PUT /conf/enums (sample add)"
curl -sS -X PUT http://localhost:8010/conf/enums \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"route_type":["Direct","SS7","SIM","Local Bypass","Test-X"]}'; echo

echo "🔎 GET /conf/enums (after)"
curl -sS http://localhost:8010/conf/enums -H "Authorization: Bearer $TOKEN"; echo
