#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
ROUTERS="$API_DIR/routers"
CORE="$API_DIR/core"
WEB_DIR="$ROOT/web/public"

req() { [[ -f "$1" ]] || { echo "❌ Missing: $1"; exit 1; }; }

mkdir -p "$CORE" "$ROUTERS" "$WEB_DIR"

# --- Sanity: main.py present ---
req "$API_DIR/main.py"

# --- 0) CORS: allow all origins, no credentials ---
python3 - "$API_DIR/main.py" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

# Insert or replace CORS block just after app = FastAPI(...)
pat = re.compile(r"(app\s*=\s*FastAPI\([^\)]*\)\s*)", re.S)
if "app.add_middleware(CORSMiddleware" not in s and pat.search(s):
    s = pat.sub(r"""\1
origins = ['*']
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=['*'],
    allow_headers=['*'],
)
""", s, count=1)
else:
    # normalize existing to permissive
    s = re.sub(r"app\.add_middleware\(\s*CORSMiddleware[^)]+\)",
               "app.add_middleware(CORSMiddleware, allow_origins=['*'], allow_credentials=False, allow_methods=['*'], allow_headers=['*'])",
               s, flags=re.S)

p.write_text(s, encoding="utf-8")
print("✓ CORS normalized")
PY

# --- 1) conf.py: ensure JSONB cast + json.dumps(body) ---
if [[ -f "$ROUTERS/conf.py" ]]; then
python3 - "$ROUTERS/conf.py" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
if "import json" not in s:
    s = "import json\n" + s
# cast to jsonb for both insert & upsert forms
s = re.sub(r"VALUES\((:?[^\)]*):d\)", r"VALUES(\1:d::jsonb)", s)
s = re.sub(r"SET\s+data\s*=\s*:d\b", r"SET data=:d::jsonb", s)
# ensure dumps on body
s = s.replace("{\"d\": body}", "{\"d\": json.dumps(body)}")
p.write_text(s, encoding="utf-8")
print("✓ conf.py patched (jsonb + dumps)")
PY
else
cat > "$ROUTERS/conf.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
import json

router = APIRouter(tags=["Config"])

# enums store in one row k='enums'
@router.get("/conf/enums")
def get_enums(user: str = Depends(get_current_user)):
    with SessionLocal() as db:
        r = db.execute(text("SELECT v FROM app_settings WHERE k='enums'")).first()
        return r[0] if r else {"route_type": [], "known_hops": [], "registration_required": []}

@router.put("/conf/enums")
def put_enums(body: dict, user: str = Depends(get_current_user)):
    if not isinstance(body, dict):
        raise HTTPException(400, "Invalid body")
    with SessionLocal() as db:
        db.execute(
            text("INSERT INTO app_settings(k,v) VALUES('enums', :v::jsonb) "
                 "ON CONFLICT (k) DO UPDATE SET v=:v::jsonb"),
            {"v": json.dumps(body)}
        )
        db.commit()
        return {"ok": True}
PY
fi

# --- 2) migrations.py: ensure app_settings table exists ---
if [[ -f "$API_DIR/migrations.py" ]]; then
python3 - "$API_DIR/migrations.py" <<'PY'
from pathlib import Path
p=Path(__import__("sys").argv[0])
# no-op placeholder; we only ensure file exists
print("✓ migrations.py present")
PY
else
cat > "$API_DIR/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

DDL = [
    """
    CREATE TABLE IF NOT EXISTS app_settings(
      k TEXT PRIMARY KEY,
      v JSONB
    )
    """
]

def migrate():
    with engine.begin() as con:
        for ddl in DDL:
            con.execute(text(ddl))

def migrate_with_retry():
    import time
    last = None
    for _ in range(20):
        try:
            migrate()
            return
        except Exception as e:
            last = e
            time.sleep(0.5)
    raise RuntimeError(f"DB not ready or migration failed: {last}")
PY
fi

# --- 3) settings router: IMAP & System sections ---
cat > "$ROUTERS/settings.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
import imaplib, json

router = APIRouter(tags=["Settings"])

def _get(k):
    with SessionLocal() as db:
        r = db.execute(text("SELECT v FROM app_settings WHERE k=:k"), {"k":k}).first()
        return r[0] if r else None

def _set(k, v):
    with SessionLocal() as db:
        db.execute(text("INSERT INTO app_settings(k,v) VALUES(:k,:v::jsonb) "
                        "ON CONFLICT (k) DO UPDATE SET v=:v::jsonb"),
                   {"k":k, "v":json.dumps(v)})
        db.commit()

@router.get("/settings/imap")
def get_imap(user: str = Depends(get_current_user)):
    return _get("imap") or {}

@router.put("/settings/imap")
def put_imap(body: dict, user: str = Depends(get_current_user)):
    _set("imap", body or {}); return {"ok":True}

@router.post("/settings/imap/test")
def test_imap(body: dict|None=None, user: str = Depends(get_current_user)):
    cfg = body or _get("imap") or {}
    host = cfg.get("host"); port=int(cfg.get("port") or (993 if cfg.get("ssl",True) else 143))
    username = cfg.get("user"); password = cfg.get("password"); use_ssl = bool(cfg.get("ssl",True))
    if not (host and username and password):
        raise HTTPException(400,"host/user/password required")
    try:
        M = imaplib.IMAP4_SSL(host, port) if use_ssl else imaplib.IMAP4(host, port)
        M.login(username, password)
        typ, data = M.list()
        M.logout()
        if typ != 'OK': raise HTTPException(400,"IMAP LIST failed")
        folders=[]
        for b in data or []:
            t = b.decode('utf-8', 'ignore')
            name = t.split(' "/" ',1)[-1].strip().strip('"')
            if name: folders.append(name)
        return {"ok":True, "folders":sorted(set(folders))}
    except imaplib.IMAP4.error as e:
        raise HTTPException(400, f"IMAP error: {e}")
    except Exception as e:
        raise HTTPException(400, f"IMAP connect error: {e}")

@router.get("/settings/system")
def get_system(user: str = Depends(get_current_user)):
    return _get("system") or {"note":"CORS=* (no credentials)"}

@router.put("/settings/system")
def put_system(body: dict, user: str = Depends(get_current_user)):
    _set("system", body or {}); return {"ok":True}
PY

# --- 4) Wire settings router in main.py (idempotent) & call migrate_with_retry() ---
python3 - "$API_DIR/main.py" <<'PY'
import sys, pathlib, re
p=pathlib.Path(sys.argv[1]); s=p.read_text(encoding="utf-8")
if "from app.migrations import migrate_with_retry" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom app.migrations import migrate_with_retry")
if "from app.routers import" in s and "settings" not in s:
    s = s.replace("from app.routers import ",
                  "from app.routers import ", 1)  # keep line, we'll add include below
    if "from app.routers import users" in s and "settings" not in s:
        s = s.replace("from app.routers import users, suppliers, countries, networks, offers, conf, metrics, lookups, parsers",
                      "from app.routers import users, suppliers, countries, networks, offers, conf, metrics, lookups, parsers, settings")
if "migrate_with_retry()" not in s:
    s = re.sub(r"(app\s*=\s*FastAPI\([^\)]*\))", r"\1\nmigrate_with_retry()", s, count=1, flags=re.S)
if "app.include_router(settings.router)" not in s and "parsers.router" in s:
    s = s.replace("app.include_router(parsers.router)", "app.include_router(parsers.router)\napp.include_router(settings.router)")
elif "app.include_router(settings.router)" not in s:
    s = s + "\nfrom app.routers import settings\napp.include_router(settings.router)\n"
p.write_text(s, encoding="utf-8")
print("✓ settings wired & migrations on startup")
PY

# --- 5) Minimal UI patches in web/public/main.js (best-effort, skip if pattern missing) ---
if [[ -f "$WEB_DIR/main.js" ]]; then
  cp "$WEB_DIR/main.js" "$WEB_DIR/main.js.bak.$(date +%s)" || true
  # remove "Per Delivered" checkbox in add-connection row (label with id cpd-...)
  sed -i -E '/id="cpd-\$\{?s\.id\}?"/d' "$WEB_DIR/main.js" || true
  # change inline Per Delivered input to dropdown
  sed -i -E 's#<label>Per Delivered</label><input[^>]*id="ep-\$\{?s\.id\}?"[^>]*>#<label>Per Delivered</label><select id="ep-${s.id}"><option value="true">Yes</option><option value="false">No</option></select>#' "$WEB_DIR/main.js" || true
  # change inline Charge to dropdown
  sed -i -E 's#<label>Charge</label><input[^>]*id="ec-\$\{?s\.id\}?"[^>]*>#<label>Charge</label><select id="ec-${s.id}"><option>Per Submitted</option><option>Per Delivered</option></select>#' "$WEB_DIR/main.js" || true
  # ensure save body translates dropdown values properly
  sed -i -E 's/per_delivered:\s*\$\("#ep-\$\{?s\.id\}?"\)\.checked/per_delivered:($("#ep-${s.id}").value==="true")/g' "$WEB_DIR/main.js" || true
  echo "✓ main.js patched (checkbox removed, dropdowns added)"
else
  echo "ℹ️ $WEB_DIR/main.js not found; UI patch skipped"
fi

# --- 6) Rebuild & restart api+web ---
cd "$ROOT/docker"
docker compose up -d --build api web
sleep 2

echo "== Smoke =="
curl -sS -X OPTIONS http://localhost:8010/users/login \
  -H "Origin: http://localhost:5183" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" | sed -n '1,20p'
echo
curl -sS -X PUT http://localhost:8010/conf/enums \
  -H "Authorization: Bearer test" -H "Content-Type: application/json" \
  -d '{"route_type":["Direct"],"known_hops":["0-Hop"],"registration_required":["Yes","No"]}' | cat
echo
echo "Open UI: http://localhost:5183"
