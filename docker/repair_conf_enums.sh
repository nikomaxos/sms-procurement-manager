#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
ROUTERS="$API_DIR/routers"
MAIN="$API_DIR/main.py"

if [ ! -f "$MAIN" ]; then
  echo "❌ $MAIN not found (expected FastAPI at api/app)."; exit 1
fi

mkdir -p "$ROUTERS"
: > "$ROUTERS/__init__.py"

# 1) Write routers/conf.py (fresh, complete, idempotent)
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
    merged = dict(DEFAULT_ENUMS)
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
    merged = dict(DEFAULT_ENUMS)
    merged.update(clean)
    return merged

@router.get("/ping")
def ping():
    return {"ok": True}
PY

# 2) Ensure CORS & include_router are present (append once, idempotent)
grep -q 'from fastapi.middleware.cors import CORSMiddleware' "$MAIN" || \
  echo 'from fastapi.middleware.cors import CORSMiddleware' >> "$MAIN"

grep -q 'app.add_middleware(CORSMiddleware' "$MAIN" || cat >> "$MAIN" <<'PY'
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
PY

grep -q 'from app.routers import conf' "$MAIN" || echo 'from app.routers import conf' >> "$MAIN"
grep -q 'app.include_router(conf.router' "$MAIN" || echo 'app.include_router(conf.router, prefix="/conf", tags=["Config"])' >> "$MAIN"

# 3) Rebuild & restart API
cd "$ROOT/docker"
docker compose up -d --build api

# 4) Verify: OpenAPI contains /conf/enums, and GET works with a token
sleep 2
if command -v jq >/dev/null 2>&1; then
  curl -sS http://localhost:8010/openapi.json | jq -r '.paths | keys[]' | grep -q '^/conf/enums$' \
    && echo "✅ /conf/enums present in OpenAPI" || { echo "❌ /conf/enums missing in OpenAPI"; exit 1; }
else
  curl -sS http://localhost:8010/openapi.json | grep -q '"/conf/enums"' \
    && echo "✅ /conf/enums present in OpenAPI" || { echo "❌ /conf/enums missing in OpenAPI"; exit 1; }
fi

TOKEN="$(curl -sS -X POST http://localhost:8010/users/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin123' | python3 - <<'PY'
import sys, json
print(json.load(sys.stdin)["access_token"])
PY
)"

echo "➡ GET /conf/enums"
curl -sS http://localhost:8010/conf/enums -H "Authorization: Bearer $TOKEN"; echo
