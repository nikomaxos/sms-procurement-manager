#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
API_MAIN="$API/main.py"
ROUTERS="$API/routers"
MODELS="$API/models"
WEB="$ROOT/web/public"
MAIN_JS="$WEB/main.js"
ENV_JS="$WEB/env.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_login_and_401s_$TS"
mkdir -p "$BACK"

echo -e "${Y}• Backing up to ${BACK}${N}"
[[ -f "$COMPOSE"  ]] && cp -a "$COMPOSE"  "$BACK/docker-compose.yml.bak" || true
[[ -f "$API_MAIN" ]] && cp -a "$API_MAIN" "$BACK/main.py.bak"             || true
[[ -f "$ROUTERS/users.py" ]] && cp -a "$ROUTERS/users.py" "$BACK/users.py.bak" || true
[[ -f "$MAIN_JS"  ]] && cp -a "$MAIN_JS"  "$BACK/main.js.bak"              || true
[[ -f "$ENV_JS"   ]] && cp -a "$ENV_JS"   "$BACK/env.js.bak"               || true

mkdir -p "$ROUTERS" "$MODELS" "$WEB"

# 0) Compose: ensure clean + correct DB driver and restart policy
echo -e "${Y}• Normalizing docker-compose.yml…${N}"
cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: smsdb
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [stack]

  api:
    build:
      context: .
      dockerfile: api.Dockerfile
    restart: unless-stopped
    environment:
      DB_URL: postgresql+psycopg://postgres:postgres@postgres:5432/smsdb
    depends_on:
      - postgres
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
    # expects a web.Dockerfile that copies web/public → /usr/share/nginx/html
      dockerfile: web.Dockerfile
    restart: unless-stopped
    depends_on:
      - api
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata: {}

networks:
  stack: {}
YAML

# 1) API: make /users/login accept BOTH JSON and form-data (idempotent write)
echo -e "${Y}• (Re)writing routers/users.py with flexible login…${N}"
cat > "$ROUTERS/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel
from sqlalchemy.orm import Session
from sqlalchemy import select
from typing import Optional
from app.core.database import SessionLocal
from app.core.auth import create_access_token, verify_password, get_current_user
from app.models.models import User  # assumes models/models.py defines User

router = APIRouter()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

class LoginIn(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

@router.post("/users/login")
async def login(request: Request, body: Optional[LoginIn] = None, db: Session = Depends(get_db)):
    # 1st try JSON body
    username = (body.username if body else None) if body else None
    password = (body.password if body else None) if body else None

    # If missing, try classic form payload
    if not username or not password:
        try:
            form = await request.form()
            username = username or form.get("username")
            password = password or form.get("password")
        except Exception:
            pass

    if not username or not password:
        raise HTTPException(status_code=422, detail="username/password required")

    u = db.execute(select(User).where(User.username == username)).scalar_one_or_none()
    if not u or not verify_password(password, u.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    token = create_access_token({"sub": str(u.id), "username": u.username, "is_admin": bool(getattr(u, "is_admin", False))})
    return {"access_token": token, "token_type": "bearer"}

@router.get("/users/me")
def me(current = Depends(get_current_user)):
    return {"id": current.id, "username": current.username, "is_admin": bool(getattr(current, "is_admin", False))}

class CreateUser(BaseModel):
    username: str
    password: str
    is_admin: Optional[bool] = False

@router.post("/users/create")
def create_user(payload: CreateUser, db: Session = Depends(get_db), current = Depends(get_current_user)):
    if not getattr(current, "is_admin", False):
        raise HTTPException(status_code=403, detail="admin only")
    exists = db.execute(select(User).where(User.username == payload.username)).scalar_one_or_none()
    if exists:
        raise HTTPException(status_code=409, detail="username exists")

    # reuse password utilities from core.auth
    from app.core.auth import get_password_hash
    u = User(username=payload.username, password_hash=get_password_hash(payload.password), is_admin=bool(payload.is_admin))
    db.add(u)
    db.commit()
    db.refresh(u)
    return {"id": u.id, "username": u.username, "is_admin": bool(u.is_admin)}
PY

# 2) API main.py: ensure CORS + include users router (idempotent)
echo -e "${Y}• Patching API CORS & mounting users router…${N}"
MAIN_PY_PATH="$API_MAIN" python3 - <<'PY'
import os, re
from pathlib import Path
p = Path(os.environ["MAIN_PY_PATH"])
s = p.read_text(encoding="utf-8")

if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

# Ensure app = FastAPI(...) exists
m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
if not m:
    raise SystemExit("FastAPI() instantiation not found in main.py")

# Inject CORS once
if "app.add_middleware(CORSMiddleware" not in s:
    ins = m.end()
    s = s[:ins] + """
# --- injected CORS ---
origins = ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
# --- end injected CORS ---
""" + s[ins:]

# Ensure users router is included
if "from app.routers import users" not in s:
    s = s.replace("from app.routers import", "from app.routers import users,")
if "app.include_router(users.router)" not in s:
    # include under API root
    s += "\napp.include_router(users.router)\n"

p.write_text(s, encoding="utf-8")
print("OK")
PY

# 3) UI env.js (so API_BASE is set even after reload)
if [[ ! -f "$ENV_JS" ]]; then
  echo -e "${Y}• Writing env.js…${N}"
  cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS
fi

# 4) UI: harden prelude (authFetch 401 handler) + add login panel & enter-to-login
echo -e "${Y}• Patching main.js prelude/login…${N}"
touch "$MAIN_JS"

python3 - <<'PY'
from pathlib import Path
import re, os

p = Path(os.environ["MAIN_JS_PATH"]) if "MAIN_JS_PATH" in os.environ else Path("")
if not p:
    raise SystemExit("MAIN_JS_PATH missing")
src = p.read_text(encoding="utf-8")

# Ensure prelude with authFetch exists; if not, prepend one.
if "window.authFetch" not in src or "/* == PRELUDE START" not in src:
    prelude = r"""
/* == PRELUDE START (idempotent) == */
(function(){
  if (window.__PRELUDE__) return; window.__PRELUDE__ = true;
  window.$  = (s)=>document.querySelector(s);
  window.$$ = (s)=>Array.from(document.querySelectorAll(s));
  window.el = function(tag, attrs, ...kids){
    const n = document.createElement(tag);
    if (attrs) for (const [k,v] of Object.entries(attrs)) {
      if (k==='class') n.className=v;
      else if (k.startsWith('on') && typeof v==='function') n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    for (const k of kids) n.append(k && k.nodeType ? k : (k ?? ''));
    return n;
  };
  window.btn = (text, color, onclick)=>{ const b=el('button',{class:'btn '+(color||'')},text); if(onclick)b.onclick=onclick; return b; };
  window.go  = (fn)=>Promise.resolve().then(fn).catch(console.error);

  window.showLogin = function(){
    const app = document.getElementById('app') || document.body;
    app.innerHTML = '';
    const panel = el('div',{class:'card'},
      el('h2',null,'Login'),
      el('label',null,'Username'),
      el('input',{id:'loginUser',type:'text',placeholder:'admin'}),
      el('label',null,'Password'),
      el('input',{id:'loginPass',type:'password',placeholder:'••••••'}),
      btn('Login','green', async ()=>{
        const u = document.getElementById('loginUser')?.value?.trim();
        const p = document.getElementById('loginPass')?.value||'';
        if(!u||!p){ alert('Enter username & password'); return; }
        try{
          const r = await window.authFetch((window.API_BASE||'') + '/users/login',{
            method:'POST',
            body: JSON.stringify({username:u, password:p})
          });
          if(r && r.access_token){
            localStorage.setItem('token', r.access_token);
            location.reload();
          }else{
            alert('Login failed');
          }
        }catch(e){ console.error(e); alert('Login failed'); }
      })
    );
    app.append(panel);
    const pass = document.getElementById('loginPass');
    if(pass){
      pass.addEventListener('keydown', (ev)=>{ if(ev.key==='Enter'){ panel.querySelector('button')?.click(); }});
    }
  };

  window.authFetch = async function(url, opts){
    opts = opts || {};
    const headers = opts.headers ? {...opts.headers} : {};
    if (!headers['Content-Type'] && !(opts.body instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
    }
    const tok = localStorage.getItem('token');
    if (tok) headers['Authorization'] = 'Bearer '+tok;
    const res = await fetch(url, {...opts, headers});
    if (res.status === 401){
      localStorage.removeItem('token');
      try{ window.showLogin(); }catch(_){}
      throw new Error('401 Unauthorized');
    }
    if (!res.ok){
      const txt = await res.text().catch(()=> '');
      throw new Error(res.status+' '+txt);
    }
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : res.text();
  };
})();
 /* == PRELUDE END == */
"""
    src = prelude + "\n" + src

# If authFetch exists but lacks 401 handling, replace function body
src = re.sub(
    r"window\.authFetch\s*=\s*async function\s*\([^\)]*\)\s*\{[\s\S]*?\};",
    """window.authFetch = async function(url, opts){
    opts = opts || {};
    const headers = opts.headers ? {...opts.headers} : {};
    if (!headers['Content-Type'] && !(opts.body instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
    }
    const tok = localStorage.getItem('token');
    if (tok) headers['Authorization'] = 'Bearer '+tok;
    const res = await fetch(url, {...opts, headers});
    if (res.status === 401){
      localStorage.removeItem('token');
      try{ window.showLogin(); }catch(_){}
      throw new Error('401 Unauthorized');
    }
    if (!res.ok){
      const txt = await res.text().catch(()=> '');
      throw new Error(res.status+' '+txt);
    }
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : res.text();
  };""",
    src, flags=re.S
)

# Ensure there is a visible Login entry point if no token (simple fallback)
if "window.renderNav" not in src:
    src += """
// Minimal fallback nav to reach login if no token
(function(){
  if (document.getElementById('app')) return;
  const root = document.createElement('div'); root.id='app'; document.body.appendChild(root);
  if (!localStorage.getItem('token')) window.showLogin();
})();
"""

p.write_text(src, encoding="utf-8")
print("OK")
PY
# pass path env to python
MAIN_JS_PATH="$MAIN_JS" python3 - <<'PY'
import os, sys
# the previous python block uses MAIN_JS_PATH via env; nothing to do here, just placeholder
print("", end="")
PY

# 5) Ensure env.js exists (if missing)
if [[ ! -f "$ENV_JS" ]]; then
  cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS
fi

# 6) Rebuild + restart
echo -e "${Y}• docker compose build + up…${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 7) Quick health & auth sanity
sleep 2
IP=$(hostname -I | awk '{print $1}')
API="http://${IP}:8010"
UI="http://${IP}:5183"

echo -e "${Y}• Check API openapi…${N}"
if curl -fsS "$API/openapi.json" >/dev/null; then
  echo -e "${G}✔ API reachable${N}"
else
  echo -e "${R}✖ API not reachable; logs (api):${N}"
  docker compose -f "$COMPOSE" logs api --tail=120 || true
fi

echo -e "${Y}• CORS preflight /users/me…${N}"
curl -s -D - -o /dev/null -X OPTIONS "$API/users/me" \
  -H "Origin: $UI" \
  -H "Access-Control-Request-Method: GET" | tr -d '\r' | grep -i '^access-control-allow-origin' || echo "(no ACAO)"

echo -e "${G}✔ Done. Open ${UI} — if you see 401s, the login panel will appear; Enter key works.${N}"
