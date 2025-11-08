#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"

mkdir -p "$CORE" "$ROUT"
: > "$ROUT/__init__.py"

############################
# 1) CORS (permissive)
############################
python3 - <<'PY'
from pathlib import Path
p = Path("'"$API"'/main.py")
s = p.read_text(encoding="utf-8")

# Import CORSMiddleware if missing
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

# Ensure middleware is added right after app = FastAPI(...)
if "CORSMiddleware" not in s or "app.add_middleware(CORSMiddleware" not in s:
    s = s.replace(
        "app = FastAPI(",
        "app = FastAPI("
    )
    # insert block once, after app = FastAPI(...)
    split_at = s.find("app = FastAPI(")
    if split_at != -1:
        # find end of the FastAPI(...) call
        start = split_at
        end = s.find(")", start)
        if end != -1:
            end += 1
            before = s[:end]
            after = s[end:]
            cors_block = """

# CORS: wildcard origins, no cookies (we use Authorization header)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
"""
            s = before + cors_block + after

# Make sure we keep only one middleware block (dedupe naive)
lines = []
added = False
for line in s.splitlines():
    lines.append(line)
s = "\n".join(lines)

p.write_text(s, encoding="utf-8")
print("✓ CORS ensured in main.py")
PY

########################################
# 2) /conf/enums router (JSONB storage)
########################################
cat > "$ROUT/conf.py" <<'PY'
from typing import List, Optional, Dict, Any
from fastapi import APIRouter, Depends, HTTPException
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

# Default choices
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

@router.get("/enums")
def get_enums(db = Depends(get_db)) -> Dict[str, Any]:
    row = db.execute(text("SELECT v FROM app_settings WHERE k='enums'")).first()
    if row and row[0]:
        # merge with defaults to guarantee keys
        current = dict(DEFAULT_ENUMS)
        current.update(row[0])
        return current
    return DEFAULT_ENUMS

@router.put("/enums")
def put_enums(payload: EnumsPayload, db = Depends(get_db)) -> Dict[str, Any]:
    import json
    # merge with defaults and incoming fields
    current = dict(DEFAULT_ENUMS)
    incoming = {k: v for k, v in payload.dict().items() if v is not None}
    current.update(incoming)
    js = json.dumps(current)
    # jsonb upsert (works with psycopg v3)
    db.execute(
        text("INSERT INTO app_settings (k, v) VALUES ('enums', :v::jsonb) "
             "ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v"),
        {"v": js}
    )
    db.commit()
    return current
PY
echo "✓ wrote routers/conf.py"

########################################
# 3) Ensure router is included in main
########################################
python3 - <<'PY'
from pathlib import Path
p = Path("'"$API"'/main.py")
s = p.read_text(encoding="utf-8")

if "from app.routers import conf" not in s:
    # try to append import near other router imports if present
    if "from app.routers import" in s:
        s = s.replace("from app.routers import", "from app.routers import conf,")
    else:
        s = s.replace("from fastapi import FastAPI", "from fastapi import FastAPI\nfrom app.routers import conf")

if "include_router(conf.router" not in s:
    # include under /conf
    insert_at = s.rfind("app = FastAPI(")
    # safer: just append after app creation
    if "app.include_router(" in s:
        s += "\n"
    s += "\napp.include_router(conf.router, prefix='/conf', tags=['Conf'])\n"

p.write_text(s, encoding="utf-8")
print("✓ main.py now includes /conf router")
PY

########################################
# 4) Rebuild & restart API
########################################
cd "$ROOT/docker"
docker compose up -d --build api
sleep 2

echo "== Preflight OPTIONS =="
ORIGIN="http://$(hostname -I | awk '{print $1}'):5183"
curl -i -s -X OPTIONS "http://localhost:8010/conf/enums" \
  -H "Origin: ${ORIGIN}" \
  -H "Access-Control-Request-Method: PUT" \
  -H "Access-Control-Request-Headers: content-type,authorization" | sed -n '1,40p'

echo "== PUT roundtrip =="
curl -i -s -X PUT "http://localhost:8010/conf/enums" \
  -H "Content-Type: application/json" \
  -d '{"route_type":["Direct","SS7","SIM","Local Bypass","TestX"]}'
echo
echo "== GET check =="
curl -s "http://localhost:8010/conf/enums" | jq .
