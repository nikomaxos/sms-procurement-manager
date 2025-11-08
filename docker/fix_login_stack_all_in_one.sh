#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUTERS="$API/routers"
MODELS="$API/models"
WEB="$ROOT/web/public"

API_MAIN="$API/main.py"
MAIN_JS="$WEB/main.js"
ENV_JS="$WEB/env.js"
COMPOSE="$ROOT/docker-compose.yml"
API_DF="$ROOT/api.Dockerfile"
WEB_DF="$ROOT/web.Dockerfile"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_login_stack_$TS"
mkdir -p "$BACK" "$CORE" "$ROUTERS" "$MODELS" "$WEB"

echo -e "${Y}• Backing up to $BACK…${N}"
for f in "$COMPOSE" "$API_MAIN" "$ROUTERS/users.py" "$MAIN_JS" "$ENV_JS" "$API_DF" "$WEB_DF"; do
  [[ -f "$f" ]] && cp -a "$f" "$BACK/$(basename "$f").bak" || true
done

# 0) Ensure Dockerfiles
if [[ ! -f "$API_DF" ]]; then
  cat > "$API_DF" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
      fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" \
      pydantic python-multipart python-jose[cryptography] \
      "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1"
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER
fi

if [[ ! -f "$WEB_DF" ]]; then
  cat > "$WEB_DF" <<'DOCKER'
FROM nginx:stable-alpine
COPY web/public /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; && \
    find /usr/share/nginx/html -type f -exec chmod 644 {} \;
DOCKER
fi

# 1) Clean, valid docker-compose.yml
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

# 2) Users router: JSON & form login
cat > "$ROUTERS/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel
from sqlalchemy.orm import Session
from sqlalchemy import select
from typing import Optional
from app.core.database import SessionLocal
from app.core.auth import create_access_token, verify_password, get_current_user, get_password_hash
from app.models.models import User

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
    username = (body.username if body else None) if body else None
    password = (body.password if body else None) if body else None
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
    u = User(username=payload.username, password_hash=get_password_hash(payload.password), is_admin=bool(payload.is_admin))
    db.add(u); db.commit(); db.refresh(u)
    return {"id": u.id, "username": u.username, "is_admin": bool(u.is_admin)}
PY

# 3) main.py: CORS + dynamic auto-mount of all routers
if [[ ! -f "$API_MAIN" ]]; then
  cat > "$API_MAIN" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="SMS Procurement Manager API")

# CORS (bearer only, no cookies)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Auto-discover & include all routers in app.routers
import pkgutil, importlib
from app import routers as _routers_pkg
for _, modname, ispkg in pkgutil.iter_modules(_routers_pkg.__path__):
    m = importlib.import_module(f"app.routers.{modname}")
    r = getattr(m, "router", None)
    if r:
        app.include_router(r)
PY
else
  python3 - <<'PY'
from pathlib import Path
import re
p = Path(r"'"$API_MAIN"'")
s = p.read_text(encoding="utf-8")
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")
if "app.add_middleware(CORSMiddleware" not in s:
    m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
    if m:
        i = m.end()
        s = s[:i] + """
# --- CORS injected ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
# --- end CORS ---
""" + s[i:]
if "pkgutil" not in s or "app.routers" not in s or "include_router" not in s:
    s += """
# --- auto include routers ---
import pkgutil, importlib
from app import routers as _routers_pkg
for _, modname, ispkg in pkgutil.iter_modules(_routers_pkg.__path__):
    m = importlib.import_module(f"app.routers.{modname}")
    r = getattr(m, "router", None)
    if r: app.include_router(r)
# --- end auto include ---
"""
p.write_text(s, encoding="utf-8")
print("OK")
PY
fi

# 4) UI env.js
if [[ ! -f "$ENV_JS" ]]; then
  cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS
fi

# 5) UI prelude + login panel (Enter-to-login) + 401 handler
if [[ ! -f "$MAIN_JS" ]]; then
  touch "$MAIN_JS"
fi

MAIN_JS_PATH="$MAIN_JS" python3 - <<'PY'
import os
from pathlib import Path
p = Path(os.environ["MAIN_JS_PATH"])
src = p.read_text(encoding="utf-8")
prelude = r"""
/* == PRELUDE START == */
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
  window.btn = (t,c,cb)=>{ const b=el('button',{class:'btn '+(c||'')},t); if(cb)b.onclick=cb; return b; };
  window.go  = (fn)=>Promise.resolve().then(fn).catch(console.error);

  window.authFetch = async function(url, opts){
    opts = opts || {};
    const headers = opts.headers ? {...opts.headers} : {};
    if (!headers['Content-Type'] && !(opts.body instanceof FormData)) headers['Content-Type'] = 'application/json';
    const tok = localStorage.getItem('token'); if (tok) headers['Authorization'] = 'Bearer '+tok;
    const res = await fetch(url, {...opts, headers});
    if (res.status === 401){ localStorage.removeItem('token'); try{ window.showLogin(); }catch(_){}; throw new Error('401'); }
    if (!res.ok){ const txt = await res.text().catch(()=> ''); throw new Error(res.status+' '+txt); }
    const ct = res.headers.get('content-type')||''; return ct.includes('application/json') ? res.json() : res.text();
  };

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
        const u = $('#loginUser')?.value?.trim(); const pw = $('#loginPass')?.value||'';
        if(!u||!pw){ alert('Enter username & password'); return; }
        const r = await window.authFetch((window.API_BASE||'')+'/users/login',{method:'POST', body: JSON.stringify({username:u,password:pw})});
        if(r && r.access_token){ localStorage.setItem('token', r.access_token); location.reload(); } else { alert('Login failed'); }
      })
    );
    app.append(panel);
    const pass = document.getElementById('loginPass');
    if(pass){ pass.addEventListener('keydown', (ev)=>{ if(ev.key==='Enter'){ panel.querySelector('button')?.click(); }}); }
  };

  // Auto-show login if no token
  if (!localStorage.getItem('token')) setTimeout(()=>window.showLogin(),0);
})();
 /* == PRELUDE END == */
"""
if "/* == PRELUDE START ==" not in src:
    src = prelude + "\n" + src
p.write_text(src, encoding="utf-8")
print("OK")
PY

# 6) Minimal index.html if missing (so nginx serves something)
if [[ ! -f "$WEB/index.html" ]]; then
  cat > "$WEB/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
<style>
  body{font-family:system-ui,Segoe UI,Roboto,Ubuntu,Arial,sans-serif;background:#f9f4ef;color:#2b2b2b;margin:0}
  .btn{padding:.55rem .9rem;border-radius:.6rem;border:0;cursor:pointer;margin:.2rem}
  .btn.green{background:#2f855a;color:#fff}
  .card{max-width:420px;margin:8vh auto;background:#fff;border-radius:12px;padding:20px;box-shadow:0 6px 28px rgba(0,0,0,.08)}
  label{display:block;margin:.5rem 0 .25rem;font-weight:600}
  input{width:100%;padding:.55rem .6rem;border:1px solid #ddd;border-radius:.5rem}
</style>
</head><body>
<div id="app"></div>
<script src="env.js"></script>
<script src="main.js"></script>
</body></html>
HTML
fi

# 7) Rebuild + up
echo -e "${Y}• Rebuilding & starting…${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 8) Health checks + optional admin seed if login fails
sleep 2
IP=$(hostname -I | awk '{print $1}')
API="http://${IP}:8010"
UI="http://${IP}:5183"

echo -e "${Y}• Check API OpenAPI…${N}"
if curl -fsS "$API/openapi.json" >/dev/null; then echo -e "${G}✔ API OK${N}"; else echo -e "${R}✖ API not reachable${N}"; fi

echo -e "${Y}• Try login as admin/admin123…${N}"
if ! curl -sS -X POST "$API/users/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin123"}' | grep -q access_token; then
  echo -e "${Y}• Seeding default admin inside the api container…${N}"
  docker compose -f "$COMPOSE" exec -T api python - <<'PY' || true
from app.core.database import SessionLocal
from app.core.auth import get_password_hash
from app.models.models import User
from sqlalchemy import select
db = SessionLocal()
u = db.execute(select(User).where(User.username=='admin')).scalar_one_or_none()
if not u:
    u = User(username='admin', password_hash=get_password_hash('admin123'), is_admin=True)
    db.add(u); db.commit()
print("admin seeded")
PY
fi

echo -e "${G}✔ Done. Open ${UI} — login panel should appear. Use admin/admin123. 401s auto-show login; Enter key submits.${N}"
