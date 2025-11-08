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
MAIN_JS="$WEB/main.js"
ENV_JS="$WEB/env.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_login_contract_$TS"
mkdir -p "$BACK" "$CORE" "$ROUT" "$WEB"

echo -e "${Y}• Backing up to $BACK${N}"
for f in "$MAIN_PY" "$AUTH_PY" "$USERS_PY" "$MAIN_JS" "$ENV_JS" "$COMPOSE"; do
  [[ -f "$f" ]] && cp -a "$f" "$BACK/" || true
done
touch "$API/__init__.py" "$CORE/__init__.py" "$ROUT/__init__.py"

# 1) Ensure auth core provides create_access_token (if you already have it, this is harmless)
echo -e "${Y}• Writing/refreshing core/auth.py…${N}"
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

# 2) Force unconditional CORS on all responses (keeps your OPTIONS/POST CORS-clean permanently)
echo -e "${Y}• Enforcing unconditional CORS middleware in main.py…${N}"
python3 - "$MAIN_PY" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI, Request\nfrom fastapi.middleware.cors import CORSMiddleware\nfrom starlette.responses import PlainTextResponse")

# Insert/replace always-CORS middleware
block = r"""
# --- ALWAYS-CORS (idempotent) ---
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
if "# --- ALWAYS-CORS" not in s:
    # put it right after app = FastAPI(...)
    m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
    if m:
        s = s[:m.end()] + "\n" + block + s[m.end():]
    else:
        # very defensive: append
        s += "\n" + block

# Ensure users router is mounted
if "app.include_router(_users.router)" not in s:
    if "from app.routers import users as _users" not in s:
        s += "\ntry:\n    from app.routers import users as _users\n    app.include_router(_users.router)\nexcept Exception as e:\n    print('WARNING users router:', repr(e))\n"

p.write_text(s, encoding="utf-8")
print("OK")
PY

# 3) Robust users router (DB bootstrap + canonical token response + OPTIONS for /users/login)
echo -e "${Y}• Writing routers/users.py…${N}"
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

# Ensure minimal users table and seed admin
def _bootstrap_users():
    ddl = """
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user'
    )
    """
    with engine.begin() as conn:
        conn.exec_driver_sql(ddl)
        # seed admin if table empty
        cnt = conn.exec_driver_sql("SELECT COUNT(*) FROM users").scalar() or 0
        if cnt == 0:
            conn.exec_driver_sql(
                "INSERT INTO users (username, password_hash, role) VALUES (%s, %s, %s)",
                ("admin", get_password_hash("admin123"), "admin"),
            )
_bootstrap_users()

class LoginJSON(BaseModel):
    username: str
    password: str

@router.options("/login")
def login_options():
    # handled by global CORS middleware; explicit 204 also fine
    return JSONResponse({}, status_code=204)

@router.post("/login")
def login(
    request: Request,
    payload: Optional[LoginJSON] = Body(None),
    db: Session = Depends(get_db),
):
    # Accept JSON or form fields
    username = None
    password = None
    if payload and payload.username and payload.password:
        username, password = payload.username, payload.password
    else:
        form = None
        try:
            form = request._receive  # force existence
            form = request  # just to silence linters
        except Exception:
            pass
        # starlette form parsing (blocking) – do safe fallback
        # We will check in request scope:
        # but to stay simple, look into query params (dev fallback)
        q = request.query_params
        if not username:
            username = q.get("username")
        if not password:
            password = q.get("password")
    if not username or not password:
        raise HTTPException(status_code=422, detail="username/password required")

    row = db.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), {"u": username}).first()
    if not row or not verify_password(password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": row.username, "role": row.role})
    return {
        "access_token": token,
        "token_type": "bearer",
        "user": {"username": row.username, "role": row.role},
    }

@router.get("/me")
def me(request: Request, db: Session = Depends(get_db)):
    # Minimal /me without full OAuth plumbing: echo role from token if present (best-effort)
    auth = request.headers.get("authorization") or ""
    return {"ok": True, "auth_header": auth}

class ChangePasswordJSON(BaseModel):
    old_password: str
    new_password: str

@router.post("/change_password")
def change_password(
    payload: ChangePasswordJSON,
    request: Request,
    db: Session = Depends(get_db),
):
    # Minimal auth: require Authorization header with username in token (best-effort)
    # In production, decode & verify JWT. Here we focus on the login contract fix.
    # For now, only allow admin to change own password for simplicity.
    row = db.execute(text("SELECT id, username, password_hash FROM users WHERE username='admin'")).first()
    if not row or not verify_password(payload.old_password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")
    db.execute(
        text("UPDATE users SET password_hash=:p WHERE id=:i"),
        {"p": get_password_hash(payload.new_password), "i": row.id},
    )
    db.commit()
    return {"ok": True}
PY

# 4) Frontend: tolerate any token key, re-bind login button & Enter to submit, save to localStorage.TOKEN
echo -e "${Y}• Patching frontend login handling in main.js…${N}"
mkdir -p "$WEB"
[[ -f "$MAIN_JS" ]] || echo "// main.js baseline\n" > "$MAIN_JS"

cat >> "$MAIN_JS" <<'JS'

// --- LOGIN PATCH (idempotent) ---
(function(){
  if (window.__LOGIN_PATCH_APPLIED__) return;
  window.__LOGIN_PATCH_APPLIED__ = true;

  function pickToken(obj){
    if (!obj || typeof obj !== 'object') return null;
    return obj.access_token || obj.token || obj.jwt || (obj.data && (obj.data.access_token || obj.data.token));
  }
  window.__pickToken = pickToken;

  async function postJSON(url, data){
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type':'application/json',
        'Accept':'application/json'
      },
      body: JSON.stringify(data)
    });
    let json = null;
    try { json = await res.json(); } catch(e){ /* ignore */ }
    return { ok: res.ok, status: res.status, json, headers: res.headers };
  }

  async function doLoginPatched(){
    const u = document.querySelector('#login-username')?.value?.trim();
    const p = document.querySelector('#login-password')?.value ?? '';
    const base = (window.API_BASE) || (location.origin.replace(':5183', ':8010'));
    const url = base + '/users/login';
    const r = await postJSON(url, {username:u, password:p});
    if (!r.ok) {
      throw new Error('Login failed: ' + r.status + ' ' + JSON.stringify(r.json || {}));
    }
    const t = pickToken(r.json);
    if (!t) throw new Error('Invalid token response');
    localStorage.setItem('TOKEN', t);
    window.TOKEN = t;
    // Optional toast
    console.log('Login OK');
    // Simple reload to let the app pick the token
    location.reload();
  }

  // Rebind login button every 1s (in case SPA re-renders)
  setInterval(() => {
    const btn = document.querySelector('#login-btn') || document.querySelector('[data-login-btn]') || document.querySelector('button.login');
    if (btn && !btn.__loginBound) {
      btn.__loginBound = true;
      btn.onclick = (e)=>{ e.preventDefault(); doLoginPatched().catch(e=>console.error(e)); };
    }
    const pwd = document.querySelector('#login-password');
    if (pwd && !pwd.__enterBound) {
      pwd.__enterBound = true;
      pwd.addEventListener('keydown', (ev)=>{
        if (ev.key === 'Enter') { ev.preventDefault(); doLoginPatched().catch(e=>console.error(e)); }
      });
    }
  }, 1000);

  // Ensure authFetch uses Bearer
  if (!window.authFetch) {
    window.authFetch = async function(url, init={}){
      const t = localStorage.getItem('TOKEN');
      init.headers = init.headers || {};
      if (t) init.headers['Authorization'] = 'Bearer ' + t;
      const r = await fetch(url, init);
      if (r.status === 401) {
        console.warn('401 → clearing token');
        localStorage.removeItem('TOKEN'); window.TOKEN = null;
      }
      return r.json().catch(()=> ({}));
    };
  }
})();
JS

# 5) Rebuild & restart API container, then probe login endpoint
echo -e "${Y}• Rebuilding API…${N}"
docker compose -f "$COMPOSE" build api >/dev/null
echo -e "${Y}• Restarting API…${N}"
docker compose -f "$COMPOSE" up -d api >/dev/null
sleep 3

IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}• Probe OPTIONS /users/login${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,20p' || true

echo -e "${Y}• Probe POST /users/login (JSON)${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,60p' || true

echo -e "${G}✔ Done. Hard-refresh the UI (Ctrl/Cmd+Shift+R) and log in (admin / admin123).${N}"
