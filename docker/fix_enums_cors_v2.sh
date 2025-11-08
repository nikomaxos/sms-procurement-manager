#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
ROUT="$API/routers"

# Sanity
if [ ! -f "$API/main.py" ]; then
  echo "❌ $API/main.py not found. Abort."
  exit 1
fi
mkdir -p "$ROUT"
: > "$ROUT/__init__.py"

################################
# 1) Ensure permissive CORS
################################
API_PATH="$API" python3 - <<'PY'
import os, re
from pathlib import Path

api = Path(os.environ["API_PATH"])
p = api / "main.py"
s = p.read_text(encoding="utf-8")

# Import
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace(
        "from fastapi import FastAPI",
        "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware",
    )

# Add middleware once (append is safe; runs after app is created)
if "app.add_middleware(CORSMiddleware" not in s:
    s += """

# --- Injected: permissive CORS (wildcard origins, no cookies) ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
"""

p.write_text(s, encoding="utf-8")
print("✓ CORS ensured in main.py")
PY

################################
# 2) /conf/enums router
################################
cat > "$ROUT/conf.py" <<'PY'
from typing import Optional, List, Dict, Any
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import SessionLocal

router = APIRouter()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

DEFAULT_ENUMS = {
    "route_type": ["Direct", "SS7", "SIM", "Local Bypass"],
    "known_hops": ["0-Hop", "1-Hop", "2-Hops", "N-Hops"],
    "registration_required": ["Yes", "No"],
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"],
}

class EnumsPayload(BaseModel):
    route_type: Optional[List[str]] = None
    known_hops: Optional[List[str]] = None
    registration_required: Optional[List[str]] = None
    sender_id_supported: Optional[List[str]] = None

def ensure_table(db):
    db.execute(text("""
        CREATE TABLE IF NOT EXISTS app_settings (
            k TEXT PRIMARY KEY,
            v JSONB
        )
    """))
    db.commit()

@router.get("/enums")
def get_enums(db = Depends(get_db)) -> Dict[str, Any]:
    ensure_table(db)
    row = db.execute(text("SELECT v FROM app_settings WHERE k='enums'")).first()
    if row and row[0]:
        cur = dict(DEFAULT_ENUMS)
        cur.update(row[0])
        return cur
    return DEFAULT_ENUMS

@router.put("/enums")
def put_enums(payload: EnumsPayload, db = Depends(get_db)) -> Dict[str, Any]:
    ensure_table(db)
    import json
    cur = dict(DEFAULT_ENUMS)
    inc = {k:v for k,v in payload.dict().items() if v is not None}
    cur.update(inc)
    db.execute(
        text("INSERT INTO app_settings (k, v) VALUES ('enums', :v::jsonb) "
             "ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v"),
        {"v": json.dumps(cur)}
    )
    db.commit()
    return cur
PY
echo "✓ wrote routers/conf.py"

################################
# 3) Wire router in main.py
################################
API_PATH="$API" python3 - <<'PY'
import os
from pathlib import Path

api = Path(os.environ["API_PATH"])
p = api / "main.py"
s = p.read_text(encoding="utf-8")

if "from app.routers import conf" not in s:
    if "from app.routers import" in s:
        s = s.replace("from app.routers import", "from app.routers import conf,")
    else:
        s = s.replace("from fastapi import FastAPI", "from fastapi import FastAPI\nfrom app.routers import conf")

if "include_router(conf.router" not in s:
    s += "\napp.include_router(conf.router, prefix='/conf', tags=['Conf'])\n"

p.write_text(s, encoding="utf-8")
print("✓ main.py updated to include /conf router")
PY

################################
# 4) Rebuild & restart API
################################
cd "$ROOT/docker"
docker compose up -d --build api
sleep 2

################################
# 5) Verify preflight + roundtrip
################################
IP=$(hostname -I | awk '{print $1}')
echo "== Preflight =="
curl -i -s -X OPTIONS "http://localhost:8010/conf/enums" \
  -H "Origin: http://$IP:5183" \
  -H "Access-Control-Request-Method: PUT" \
  -H "Access-Control-Request-Headers: content-type,authorization" | sed -n '1,30p'

echo "== PUT test =="
curl -i -s -X PUT "http://localhost:8010/conf/enums" \
  -H "Content-Type: application/json" \
  -d '{"route_type":["Direct","SS7","SIM","Local Bypass","_TEST_"]}' | sed -n '1,25p'

echo "== GET test =="
curl -s "http://localhost:8010/conf/enums"
echo
