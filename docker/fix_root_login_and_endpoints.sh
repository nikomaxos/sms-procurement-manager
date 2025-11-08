#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
WEB="$ROOT/web/public"
MAIN_PY="$API/main.py"
AUTH_PY="$CORE/auth.py"
USERS_PY="$ROUT/users.py"
STUBS_PY="$ROUT/stubs.py"
MAIN_JS="$WEB/main.js"
ENV_JS="$WEB/env.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_root_login_$TS"
mkdir -p "$BACK" "$CORE" "$ROUT" "$WEB"

echo -e "${Y}• Backing up to $BACK${N}"
for f in "$MAIN_PY" "$AUTH_PY" "$USERS_PY" "$STUBS_PY" "$MAIN_JS" "$ENV_JS" "$COMPOSE"; do
  [[ -f "$f" ]] && cp -a "$f" "$BACK/" || true
done
touch "$API/__init__.py" "$CORE/__init__.py" "$ROUT/__init__.py"

# ─────────────────────────────────────────────────────────────────────────
# 1) Auth core (create_access_token, hashing) — idempotent
# ─────────────────────────────────────────────────────────────────────────
cat > "$AUTH_PY" <<'PY'
import os
from datetime import datetime, timedelta, timezone
from typing import Dict, Any, Optional
from jose import jwt
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-change-me")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "1440"))
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)

def create_access_token(data: Dict[str, Any], expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
PY

# ─────────────────────────────────────────────────────────────────────────
# 2) ALWAYS-CORS + ensure routers mounted (users, stubs) — idempotent
# ─────────────────────────────────────────────────────────────────────────
MAIN_PY_ENV="$MAIN_PY" python3 - <<'PY'
import os, re
from pathlib import Path
p = Path(os.environ["MAIN_PY_ENV"])
s = p.read_text(encoding="utf-8")

if "from fastapi import FastAPI" not in s:
    s = "from fastapi import FastAPI\n" + s
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI, Request\nfrom fastapi.middleware.cors import CORSMiddleware\nfrom starlette.responses import PlainTextResponse")

if "app = FastAPI" not in s:
    s = s + "\napp = FastAPI()\n"

# Inject CORS middleware once
if "# --- ALWAYS-CORS ---" not in s:
    m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
    ins = m.end() if m else len(s)
    block = """
# --- ALWAYS-CORS ---
try:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["*"],
    )
except Exception:
    pass

@app.middleware("http")
async def _always_cors(request: Request, call_next):
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        resp = await call_next(request)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp
# --- END ALWAYS-CORS ---
"""
    s = s[:ins] + "\n" + block + s[ins:]

# Ensure includes for users + stubs
if "from app.routers import users as _users" not in s:
    s += "\nfrom app.routers import users as _users\n"
if "from app.routers import stubs as _stubs" not in s:
    s += "from app.routers import stubs as _stubs\n"
if "app.include_router(_users.router)" not in s:
    s += "app.include_router(_users.router)\n"
if "app.include_router(_stubs.router)" not in s:
    s += "app.include_router(_stubs.router)\n"

p.write_text(s, encoding="utf-8")
print("OK")
PY

# ─────────────────────────────────────────────────────────────────────────
# 3) Users router — JSON/form login that returns canonical token
# ─────────────────────────────────────────────────────────────────────────
cat > "$USERS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, status, Body, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db, engine
from app.core.auth import verify_password, get_password_hash, create_access_token

router = APIRouter(prefix="/users", tags=["users"])

def _bootstrap_users():
    ddl = """
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user'
    );
    """
    with engine.begin() as conn:
        conn.exec_driver_sql(ddl)
        cnt = conn.exec_driver_sql("SELECT COUNT(*) FROM users").scalar() or 0
        if cnt == 0:
            conn.exec_driver_sql(
                "INSERT INTO users (username, password_hash, role) VALUES (%s,%s,%s)",
                ("admin", get_password_hash("admin123"), "admin"),
            )
_bootstrap_users()

class LoginJSON(BaseModel):
    username: str
    password: str

@router.options("/login")
def login_options():
    return JSONResponse({}, status_code=204)

@router.post("/login")
def login(request: Request, payload: Optional[LoginJSON] = Body(None), db: Session = Depends(get_db)):
    username = None; password = None
    if payload and payload.username and payload.password:
        username, password = payload.username, payload.password
    else:
        # best-effort: read query params if a legacy form submit arrives without JSON
        q = request.query_params
        username = username or q.get("username")
        password = password or q.get("password")

    if not username or not password:
        raise HTTPException(status_code=422, detail="username/password required")

    row = db.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), {"u": username}).first()
    if not row or not verify_password(password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": row.username, "role": row.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": row.username, "role": row.role}}

@router.get("/me")
def me(request: Request):
    return {"ok": True}
PY

# ─────────────────────────────────────────────────────────────────────────
# 4) Stub the missing endpoints with persisted settings (Postgres)
#    /metrics/trends, /conf/enums (GET/PUT), /settings/imap (GET/PUT), /settings/scrape (GET/PUT)
# ─────────────────────────────────────────────────────────────────────────
cat > "$STUBS_PY" <<'PY'
from fastapi import APIRouter, Depends, Body
from sqlalchemy.orm import Session
from sqlalchemy import text
from typing import Any, Dict
from app.core.database import engine, get_db

router = APIRouter(tags=["stubs"])

def _bootstrap_kv():
    with engine.begin() as conn:
        conn.exec_driver_sql("""
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL DEFAULT '{}'::jsonb
        );
        """)
_bootstrap_kv()

def _get(conn, key: str) -> Dict[str, Any]:
    row = conn.exec_driver_sql("SELECT value FROM app_settings WHERE key=%s", (key,)).first()
    return (row[0] if row else {}) or {}

def _put(conn, key: str, value: Dict[str, Any]):
    conn.exec_driver_sql("INSERT INTO app_settings(key,value) VALUES (%s,%s) ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value", (key, value))

@router.get("/metrics/trends")
def trends(d: str = ""):
    # Return empty but valid series for UI
    return {"date": d, "series": []}

@router.get("/conf/enums")
def get_enums(db: Session = Depends(get_db)):
    with engine.begin() as conn:
        return _get(conn, "conf_enums")

@router.put("/conf/enums")
def put_enums(payload: Dict[str, Any] = Body(default={}), db: Session = Depends(get_db)):
    with engine.begin() as conn:
        _put(conn, "conf_enums", payload or {})
    return {"ok": True}

@router.get("/settings/imap")
def get_imap(db: Session = Depends(get_db)):
    with engine.begin() as conn:
        return _get(conn, "settings_imap")

@router.put("/settings/imap")
def put_imap(payload: Dict[str, Any] = Body(default={}), db: Session = Depends(get_db)):
    with engine.begin() as conn:
        _put(conn, "settings_imap", payload or {})
    return {"ok": True}

@router.get("/settings/scrape")
def get_scrape(db: Session = Depends(get_db)):
    with engine.begin() as conn:
        return _get(conn, "settings_scrape")

@router.put("/settings/scrape")
def put_scrape(payload: Dict[str, Any] = Body(default={}), db: Session = Depends(get_db)):
    with engine.begin() as conn:
        _put(conn, "settings_scrape", payload or {})
    return {"ok": True}
PY

# ─────────────────────────────────────────────────────────────────────────
# 5) Frontend patch — POST JSON, accept token, bind Enter + button
# ─────────────────────────────────────────────────────────────────────────
[[ -f "$ENV_JS" ]] || cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS

[[ -f "$MAIN_JS" ]] || echo "// main.js baseline" > "$MAIN_JS"

# Append a safe patch block (does not override existing functions unless missing)
cat >> "$MAIN_JS" <<'JS'

// ===== LOGIN ROOT-CAUSE PATCH (idempotent) =====
(function(){
  if (window.__LOGIN_ROOT_PATCH__) return; window.__LOGIN_ROOT_PATCH__=true;
  const apiBase = ()=> (window.API_BASE || location.origin.replace(':5183', ':8010'));

  async function postJSON(url, body){
    const r = await fetch(url, {
      method: 'POST',
      headers: {'Content-Type':'application/json', 'Accept':'application/json'},
      body: JSON.stringify(body||{})
    });
    const txt = await r.text();
    let json = {}; try { json = txt ? JSON.parse(txt) : {}; } catch(e){}
    return {ok:r.ok, status:r.status, json, raw:r};
  }

  function pickToken(j){ return j && (j.access_token || j.token || j.jwt || (j.data && (j.data.access_token||j.data.token))); }

  async function doLoginPatched(){
    const u = (document.querySelector('#login-username, #username, input[name="username"]')||{}).value?.trim();
    const p = (document.querySelector('#login-password, #password, input[name="password"]')||{}).value ?? '';
    if(!u || !p){ alert('Type username & password'); return; }
    const {ok,status,json} = await postJSON(apiBase()+'/users/login', {username:u, password:p});
    if(!ok){ console.error('Login failed', status, json); alert('Login failed: '+status); return; }
    const t = pickToken(json);
    if(!t){ console.error('Invalid token response', json); alert('Invalid token response'); return; }
    localStorage.setItem('TOKEN', t); window.TOKEN=t;
    location.reload();
  }

  if (!window.doLogin) window.doLogin = doLoginPatched;

  // Bind button + Enter on password defensively
  setInterval(()=>{
    const btn = document.querySelector('#login-btn, button.login, [data-login-btn]');
    if(btn && !btn.__bound){ btn.__bound=true; btn.addEventListener('click', (e)=>{e.preventDefault(); window.doLogin();}); }
    const pw = document.querySelector('#login-password, #password, input[name="password"]');
    if(pw && !pw.__enter){ pw.__enter=true; pw.addEventListener('keydown', (e)=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); } }); }
  }, 800);

  // authFetch that preserves caller expectations (JSON on success; throws on !ok)
  if (!window.authFetch){
    window.authFetch = async function(url, init={}){
      const t = localStorage.getItem('TOKEN');
      init.headers = init.headers || {};
      if (t) init.headers['Authorization'] = 'Bearer '+t;
      const r = await fetch(url, init);
      if (r.status === 401){ localStorage.removeItem('TOKEN'); }
      if (!r.ok){ const j = await r.text(); throw new Error(r.status+' '+j); }
      const ct = r.headers.get('content-type')||'';
      if (ct.includes('application/json')) return r.json();
      return r.text();
    };
  }

  // Provide go() if missing so views using it won't error
  if (!window.go) window.go = (fn)=>Promise.resolve().then(fn).catch(console.error);
})();
JS

# ─────────────────────────────────────────────────────────────────────────
# 6) Rebuild & restart containers
# ─────────────────────────────────────────────────────────────────────────
echo -e "${Y}• Rebuilding API & WEB…${N}"
docker compose -f "$COMPOSE" build api web >/dev/null
echo -e "${Y}• Restarting…${N}"
docker compose -f "$COMPOSE" up -d api web >/dev/null
sleep 3

# ─────────────────────────────────────────────────────────────────────────
# 7) FACT-BASED PROBES (headers + JSON)
# ─────────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n▶ OPTIONS /users/login (CORS)${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,20p'

echo -e "${Y}\n▶ POST /users/login (JSON)${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,80p'

echo -e "${Y}\n▶ GET /conf/enums${N}"
curl -s -i "http://${IP}:8010/conf/enums" | sed -n '1,40p'

echo -e "${Y}\n▶ GET /settings/imap${N}"
curl -s -i "http://${IP}:8010/settings/imap" | sed -n '1,40p'

echo -e "${Y}\n▶ GET /metrics/trends?d=$(date +%F)${N}"
curl -s -i "http://${IP}:8010/metrics/trends?d=$(date +%F)" | sed -n '1,40p'

echo -e "${G}\n✔ If the probes are 200/204 with JSON bodies, hard-refresh the UI (Ctrl/Cmd+Shift+R) and log in (admin/admin123).${N}"
