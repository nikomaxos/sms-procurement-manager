#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE_DIR="$API_DIR/core"
ROUT_DIR="$API_DIR/routers"
WEB_DIR="$ROOT/web/public"
MAIN_PY="$API_DIR/main.py"
AUTH_PY="$CORE_DIR/auth.py"
USERS_PY="$ROUT_DIR/users.py"
ENV_JS="$WEB_DIR/env.js"
MAIN_JS="$WEB_DIR/main.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_login_cors_frontend_$TS"
mkdir -p "$BACK" "$CORE_DIR" "$ROUT_DIR" "$WEB_DIR"

echo -e "${Y}• Backing up files to ${BACK}${N}"
[[ -f "$MAIN_PY" ]] && cp -a "$MAIN_PY" "$BACK/main.py.bak" || true
[[ -f "$AUTH_PY" ]] && cp -a "$AUTH_PY" "$BACK/auth.py.bak" || true
[[ -f "$USERS_PY" ]] && cp -a "$USERS_PY" "$BACK/users.py.bak" || true
[[ -f "$ENV_JS"  ]] && cp -a "$ENV_JS"  "$BACK/env.js.bak"  || true
[[ -f "$MAIN_JS" ]] && cp -a "$MAIN_JS" "$BACK/main.js.bak" || true
[[ -f "$COMPOSE" ]] && cp -a "$COMPOSE" "$BACK/docker-compose.yml.bak" || true

# ────────────────────────────────────────────────────────────────────────────────
# 1) Ensure permissive CORS early in main.py (idempotent)
# ────────────────────────────────────────────────────────────────────────────────
echo -e "${Y}• Patching API CORS in main.py…${N}"
python3 - <<'PY'
import re, os
from pathlib import Path
p = Path(os.environ["MAIN_PY"])
s = p.read_text(encoding="utf-8")

if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

m = re.search(r"app\s*=\s*FastAPI\s*\([^)]*\)", s, flags=re.S)
if not m:
    raise SystemExit("FastAPI() instance not found in main.py")

cors_block = """
# --- injected CORS ---
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
    # Even if added before, keep running.
    pass
# --- end injected CORS ---
"""

insert_at = m.end()
# Inject once only
if "injected CORS" not in s:
    s = s[:insert_at] + "\n" + cors_block + s[insert_at:]

# Make sure there's a simple health endpoint (handy for checks)
if 'def health()' not in s and '"/health"' not in s:
    s += """

from fastapi import APIRouter
_health_router = APIRouter()
@_health_router.get("/health")
def health():
    return {"ok": True}
app.include_router(_health_router)
"""

Path(os.environ["MAIN_PY"]).write_text(s, encoding="utf-8")
print("OK")
PY
MAIN_PY="$MAIN_PY" MAIN_PY="$MAIN_PY" true >/dev/null 2>&1

# ────────────────────────────────────────────────────────────────────────────────
# 2) Solid auth helpers (bcrypt + pbkdf2 fallback) in core/auth.py
# ────────────────────────────────────────────────────────────────────────────────
echo -e "${Y}• Writing core/auth.py…${N}"
cat > "$AUTH_PY" <<'PY'
import os
from datetime import datetime, timedelta, timezone
from typing import Dict, Any, Optional
from jose import jwt
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "change-me-in-prod")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "1440"))

# Support bcrypt but fall back to pure-python pbkdf2_sha256 if wheel/import fails
pwd_context = CryptContext(schemes=["bcrypt", "pbkdf2_sha256"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return pwd_context.verify(plain_password, hashed_password)
    except Exception:
        return False

def create_access_token(data: Dict[str, Any], expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
PY

# ────────────────────────────────────────────────────────────────────────────────
# 3) Users router: /users/login (JSON+form), /users/me, /users/change_password
#    Seeds admin/admin123 if users table empty.
# ────────────────────────────────────────────────────────────────────────────────
echo -e "${Y}• Writing routers/users.py…${N}"
cat > "$USERS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, status, Request
from pydantic import BaseModel, Field
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db, engine
from app.core.auth import verify_password, get_password_hash, create_access_token

router = APIRouter(prefix="/users", tags=["users"])

def _ensure_users():
    create_sql = """
    CREATE TABLE IF NOT EXISTS users(
      id SERIAL PRIMARY KEY,
      username VARCHAR(150) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      role VARCHAR(32) DEFAULT 'user',
      is_active BOOLEAN DEFAULT TRUE
    );
    """
    with engine.begin() as c:
        c.execute(text(create_sql))
        cnt = c.execute(text("SELECT COUNT(*) FROM users")).scalar_one()
        if cnt == 0:
            c.execute(
                text("INSERT INTO users(username, password_hash, role, is_active) VALUES (:u,:p,:r,TRUE)"),
                {"u": "admin", "p": get_password_hash("admin123"), "r": "admin"}
            )

class LoginPayload(BaseModel):
    username: str
    password: str

class NewUserPayload(BaseModel):
    username: str = Field(min_length=3, max_length=150)
    password: str = Field(min_length=4, max_length=128)
    role: str = "user"
    is_active: bool = True

class PWChangePayload(BaseModel):
    current_password: str
    new_password: str = Field(min_length=4, max_length=128)

def _get_user_row(db: Session, username: str):
    return db.execute(
        text("SELECT id, username, password_hash, role, is_active FROM users WHERE username=:u"),
        {"u": username}
    ).fetchone()

@router.post("/login")
async def login(request: Request, db: Session = Depends(get_db)):
    _ensure_users()
    payload: Optional[LoginPayload] = None
    try:
        data = await request.json()
        payload = LoginPayload(**data)
    except Exception:
        form = await request.form()
        if "username" in form and "password" in form:
            payload = LoginPayload(username=form["username"], password=form["password"])
    if not payload:
        raise HTTPException(status_code=422, detail="username/password required")

    row = _get_user_row(db, payload.username)
    if not row or not verify_password(payload.password, row[2]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    token = create_access_token({"sub": row[1], "role": row[3]})
    return {"access_token": token, "token_type": "bearer"}

@router.get("/me")
def me(authorization: Optional[str] = None, db: Session = Depends(get_db)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1]
    from jose import jwt, JWTError
    from app.core.auth import SECRET_KEY, ALGORITHM
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username = payload.get("sub")
        if not username:
            raise HTTPException(status_code=401, detail="Invalid token payload")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    row = _get_user_row(db, username)
    if not row:
        raise HTTPException(status_code=401, detail="User not found")
    return {"id": row[0], "username": row[1], "role": row[3], "is_active": row[4]}

@router.post("/")
def create_user(body: NewUserPayload, authorization: Optional[str] = None, db: Session = Depends(get_db)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1]
    from jose import jwt, JWTError
    from app.core.auth import SECRET_KEY, ALGORITHM
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("role") != "admin":
            raise HTTPException(status_code=403, detail="Admin only")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    exists = db.execute(text("SELECT 1 FROM users WHERE username=:u"), {"u": body.username}).fetchone()
    if exists:
        raise HTTPException(status_code=409, detail="Username already exists")

    db.execute(
        text("INSERT INTO users(username, password_hash, role, is_active) VALUES (:u,:p,:r,:a)"),
        {"u": body.username, "p": get_password_hash(body.password), "r": body.role, "a": body.is_active}
    )
    db.commit()
    return {"ok": True}

@router.post("/change_password")
def change_password(body: PWChangePayload, authorization: Optional[str] = None, db: Session = Depends(get_db)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1]
    from jose import jwt, JWTError
    from app.core.auth import SECRET_KEY, ALGORITHM
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username = payload.get("sub")
        if not username:
            raise HTTPException(status_code=401, detail="Invalid token payload")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    row = _get_user_row(db, username)
    if not row or not verify_password(body.current_password, row[2]):
        raise HTTPException(status_code=401, detail="Wrong current password")

    db.execute(
        text("UPDATE users SET password_hash=:p WHERE id=:id"),
        {"p": get_password_hash(body.new_password), "id": row[0]}
    )
    db.commit()
    return {"ok": True}
PY

# ────────────────────────────────────────────────────────────────────────────────
# 4) Frontend prelude: API_BASE, go(), authFetch(), login overlay + ENTER submit
#    (idempotent: only prepends if marker missing)
# ────────────────────────────────────────────────────────────────────────────────
echo -e "${Y}• Patching frontend prelude + login overlay…${N}"
mkdir -p "$WEB_DIR"
[[ -f "$ENV_JS" ]] || cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS

if [[ ! -f "$MAIN_JS" ]] || ! grep -q "/* PRELUDE_AUTH_MARKER */" "$MAIN_JS"; then
  cat > "$WEB_DIR/.prelude.js" <<'JS'
/* PRELUDE_AUTH_MARKER */
window.API_BASE = window.API_BASE || (localStorage.getItem('API_BASE') || location.origin.replace(':5183', ':8010'));

window.go = window.go || (fn => Promise.resolve(fn()).catch(console.error));

window.authFetch = window.authFetch || (async (url, opts={})=>{
  opts.headers = opts.headers || {};
  const t = localStorage.getItem('access_token');
  if (t) opts.headers['Authorization'] = 'Bearer ' + t;
  if (!opts.headers['Content-Type'] && opts.body && typeof opts.body === 'string') {
    // likely JSON string
    opts.headers['Content-Type'] = 'application/json';
  }
  const r = await fetch(url, opts);
  if (r.status === 401) {
    ensureLoginUI();
    throw new Error('Unauthorized');
  }
  return r.ok ? (await r.json().catch(()=>({ok:true}))) : (()=>{
    return r.text().then(t => { throw new Error(t || r.statusText); });
  })();
});

function ensureLoginUI(){
  if (document.getElementById('login-overlay')) return;
  const div = document.createElement('div');
  div.id = 'login-overlay';
  div.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:9999;';
  div.innerHTML = `
    <div style="background:#1e2328;color:#f5efe6;min-width:320px;max-width:420px;width:92%;padding:18px;border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.4);font-family:system-ui,Segoe UI,Roboto">
      <h2 style="margin:0 0 12px 0;font-size:20px;">Sign in</h2>
      <label style="display:block;margin:.4rem 0 .2rem">Username</label>
      <input id="login-user" style="width:100%;padding:10px;border-radius:8px;border:1px solid #39424c;background:#11161a;color:#f5efe6" value="admin">
      <label style="display:block;margin:.8rem 0 .2rem">Password</label>
      <input id="login-pass" type="password" style="width:100%;padding:10px;border-radius:8px;border:1px solid #39424c;background:#11161a;color:#f5efe6" value="admin123">
      <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px">
        <button id="login-cancel" style="padding:8px 12px;border:0;border-radius:10px;background:#3a3f45;color:#eee;cursor:pointer">Cancel</button>
        <button id="login-btn" style="padding:8px 12px;border:0;border-radius:10px;background:#c96f1a;color:#fff;cursor:pointer">Login</button>
      </div>
      <div id="login-msg" style="margin-top:8px;font-size:12px;color:#ffb4a2;display:none"></div>
    </div>`;
  document.body.appendChild(div);

  const u = div.querySelector('#login-user');
  const p = div.querySelector('#login-pass');
  const b = div.querySelector('#login-btn');
  const c = div.querySelector('#login-cancel');
  const m = div.querySelector('#login-msg');

  async function doLogin(){
    try{
      m.style.display='none';
      const res = await fetch(API_BASE + '/users/login', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({username:u.value.trim(), password:p.value})
      });
      if(!res.ok){
        const t = await res.text();
        throw new Error(t || res.statusText);
      }
      const j = await res.json();
      if(!j.access_token) throw new Error('No token in response');
      localStorage.setItem('access_token', j.access_token);
      document.body.removeChild(div);
      location.reload();
    }catch(e){
      m.textContent = 'Login failed: ' + (e.message || e);
      m.style.display='block';
    }
  }
  b.onclick = doLogin;
  c.onclick = ()=>document.body.removeChild(div);
  p.addEventListener('keydown', (ev)=>{ if(ev.key==='Enter'){ ev.preventDefault(); doLogin(); }});
}

document.addEventListener('keydown', (ev)=>{
  if((ev.ctrlKey||ev.metaKey) && ev.key.toLowerCase()==='l'){
    ev.preventDefault(); ensureLoginUI();
  }
});
/* END PRELUDE_AUTH_MARKER */
JS
  # Prepend safely
  if [[ -f "$MAIN_JS" ]]; then
    mv "$MAIN_JS" "$MAIN_JS.__orig.$TS"
    cat "$WEB_DIR/.prelude.js" "$MAIN_JS.__orig.$TS" > "$MAIN_JS"
  else
    cp "$WEB_DIR/.prelude.js" "$MAIN_JS"
  fi
fi

# ────────────────────────────────────────────────────────────────────────────────
# 5) Rebuild & restart API+WEB
# ────────────────────────────────────────────────────────────────────────────────
echo -e "${Y}• Rebuilding containers (api, web)…${N}"
docker compose -f "$COMPOSE" build api web >/dev/null
echo -e "${Y}• Restarting stack…${N}"
docker compose -f "$COMPOSE" up -d api web >/dev/null
sleep 3

# ────────────────────────────────────────────────────────────────────────────────
# 6) Quick CORS probes
# ────────────────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}• Probing CORS headers on /users/login …${N}"
curl -s -i -H "Origin: http://${IP}:5183" -H "Access-Control-Request-Method: POST" -X OPTIONS "http://${IP}:8010/users/login" | sed -n '1,20p' || true
echo -e "${Y}• Probing /openapi.json …${N}"
curl -s -i -H "Origin: http://${IP}:5183" "http://${IP}:8010/openapi.json" | sed -n '1,10p' || true

echo -e "${G}✔ Done. Hard refresh the UI (Ctrl/Cmd+Shift+R).${N}"
echo -e "${Y}Default credentials:${N} admin / admin123"
