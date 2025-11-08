#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
WEB="$ROOT/web/public"

MAIN_PY="$API/main.py"
USERS_PY="$ROUT/users.py"
AUTH_PY="$CORE/auth.py"
MAIN_JS="$WEB/main.js"
ENV_JS="$WEB/env.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_login_accept_all_$TS"
mkdir -p "$BACK" "$CORE" "$ROUT" "$WEB"

echo -e "${Y}• Backup to $BACK${N}"
for f in "$MAIN_PY" "$USERS_PY" "$AUTH_PY" "$MAIN_JS" "$ENV_JS" "$COMPOSE"; do [[ -f "$f" ]] && cp -a "$f" "$BACK/" || true; done
touch "$API/__init__.py" "$CORE/__init__.py" "$ROUT/__init__.py"

# 1) Ensure auth core is present (create_access_token etc.)
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

# 2) Harden CORS on all paths (preflight + errors)
python3 - <<'PY'
import re, os
from pathlib import Path
p = Path(os.environ["MAIN_PY"])
s = p.read_text(encoding="utf-8")
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI, Request\nfrom fastapi.middleware.cors import CORSMiddleware\nfrom starlette.responses import PlainTextResponse")
if "app = FastAPI" not in s:
    s += "\napp = FastAPI()\n"
if "# --- ALWAYS-CORS ---" not in s:
    m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
    pos = m.end() if m else len(s)
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
    s = s[:pos] + "\n" + block + s[pos:]
p.write_text(s, encoding="utf-8")
print("CORS OK")
PY
MAIN_PY="$MAIN_PY" 

# 3) Login endpoint that ACCEPTS JSON, x-www-form-urlencoded, multipart, raw text, or query params
cat > "$USERS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from sqlalchemy import text
from urllib.parse import parse_qs
import json

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

@router.options("/login")
def login_options():
    return JSONResponse({}, status_code=204)

@router.post("/login")
async def login(request: Request, db: Session = Depends(get_db)):
    username = None
    password = None

    # 1) JSON body
    try:
        body = await request.body()
        txt = body.decode("utf-8", "ignore") if body else ""
        if txt:
            try:
                data = json.loads(txt)
                if isinstance(data, dict):
                    username = data.get("username") or data.get("user") or data.get("email")
                    password = data.get("password") or data.get("pass")
            except Exception:
                pass
    except Exception:
        pass

    # 2) Form (multipart or x-www-form-urlencoded)
    if not (username and password):
        try:
            form = await request.form()
            username = username or form.get("username") or form.get("user") or form.get("email")
            password = password or form.get("password") or form.get("pass")
        except Exception:
            pass

    # 3) Raw urlencoded in body
    if not (username and password) and 'txt' in locals() and txt and "=" in txt:
        qs = parse_qs(txt)
        username = username or (qs.get("username") or qs.get("user") or qs.get("email") or [None])[0]
        password = password or (qs.get("password") or qs.get("pass") or [None])[0]

    # 4) Query string fall-back
    if not (username and password):
        q = request.query_params
        username = username or q.get("username") or q.get("user") or q.get("email")
        password = password or q.get("password") or q.get("pass")

    if not (username and password):
        raise HTTPException(status_code=400, detail="username/password required")

    row = db.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), {"u": username}).first()
    if not row or not verify_password(password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": row.username, "role": row.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": row.username, "role": row.role}}
PY

# 4) Frontend override: force JSON login + Enter key + safe authFetch + go()
[[ -f "$ENV_JS" ]] || cat > "$ENV_JS" <<'JS'
(function(){ const saved = localStorage.getItem('API_BASE'); window.API_BASE = saved || (location.origin.replace(':5183', ':8010')); })();
JS

[[ -f "$MAIN_JS" ]] || echo "// main.js baseline" > "$MAIN_JS"

cat >> "$MAIN_JS" <<'JS'

// ===== FORCE LOGIN JSON (idempotent, overrides any previous) =====
(function(){
  if (window.__LOGIN_FORCE_PATCH__) return; window.__LOGIN_FORCE_PATCH__=true;
  const apiBase = ()=> (window.API_BASE || location.origin.replace(':5183', ':8010'));

  async function postJSON(url, body){
    const r = await fetch(url, {
      method: 'POST',
      headers: {'Content-Type':'application/json','Accept':'application/json'},
      body: JSON.stringify(body||{})
    });
    const text = await r.text();
    let json = {}; try{ json = text? JSON.parse(text):{}; }catch(e){}
    return {ok:r.ok, status:r.status, json, raw:r};
  }
  function tokenOf(j){ return j && (j.access_token || j.token || j.jwt || (j.data && (j.data.access_token||j.data.token))); }

  window.doLogin = async function(){
    const uEl = document.querySelector('#login-username, #username, input[name="username"]');
    const pEl = document.querySelector('#login-password, #password, input[name="password"]');
    const u = (uEl && uEl.value ? uEl.value.trim(): "");
    const p = (pEl && pEl.value ? pEl.value: "");
    if(!u || !p){ alert('Type username & password'); return; }
    const {ok,status,json} = await postJSON(apiBase()+'/users/login', {username:u, password:p});
    if(!ok){ console.error('Login failed', status, json); alert('Login failed: '+status); return; }
    const t = tokenOf(json);
    if(!t){ console.error('Invalid token response', json); alert('Invalid token response'); return; }
    localStorage.setItem('TOKEN', t); window.TOKEN=t; location.reload();
  };

  setInterval(()=>{
    (document.querySelectorAll('#login-btn, button.login, [data-login-btn]')||[]).forEach(btn=>{
      if(!btn.__patched){ btn.__patched=true; btn.addEventListener('click', e=>{e.preventDefault(); window.doLogin();}); }
    });
    const pw = document.querySelector('#login-password, #password, input[name="password"]');
    if(pw && !pw.__enter){ pw.__enter=true; pw.addEventListener('keydown', e=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); } }); }
  }, 700);

  if(!window.authFetch){
    window.authFetch = async function(url, init={}){
      const t = localStorage.getItem('TOKEN');
      init.headers = Object.assign({}, init.headers||{});
      if(t) init.headers['Authorization'] = 'Bearer '+t;
      const r = await fetch(url, init);
      if(r.status===401){ localStorage.removeItem('TOKEN'); }
      if(!r.ok){ const body=await r.text(); throw new Error(r.status+' '+body); }
      const ct = r.headers.get('content-type')||''; return ct.includes('application/json')? r.json(): r.text();
    };
  }
  if(!window.go){ window.go = fn=>Promise.resolve().then(fn).catch(console.error); }
})();
JS

# 5) Rebuild & restart
echo -e "${Y}• Rebuilding api & web…${N}"
docker compose -f "$COMPOSE" build api web >/dev/null
echo -e "${Y}• Restarting…${N}"
docker compose -f "$COMPOSE" up -d api web >/dev/null
sleep 3

# 6) Probes: JSON + form; show CORS headers too
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n▶ OPTIONS /users/login${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,20p'

echo -e "${Y}\n▶ POST JSON /users/login${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,80p'

echo -e "${Y}\n▶ POST FORM /users/login (x-www-form-urlencoded)${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" -H "Content-Type: application/x-www-form-urlencoded" \
  --data 'username=admin&password=admin123' | sed -n '1,80p'

echo -e "${G}\n✔ If both POSTs return 200 with an access_token, hard-refresh the UI (Ctrl/Cmd+Shift+R) and log in (admin/admin123).${N}"
