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
COMPOSE="$ROOT/docker-compose.yml"
API_DF="$ROOT/api.Dockerfile"
WEB_DF="$ROOT/web.Dockerfile"
INDEX_HTML="$WEB/index.html"
ENV_JS="$WEB/env.js"
PRELUDE_JS="$WEB/prelude.js"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/fix_stack_$TS"
mkdir -p "$BACK" "$CORE" "$ROUTERS" "$MODELS" "$WEB"

echo -e "${Y}• Backing up to $BACK …${N}"
tar -czf "$BACK/stack.tgz" -C "$ROOT" \
  api/app web/public api.Dockerfile web.Dockerfile docker-compose.yml 2>/dev/null || true
echo -e "${G}✔ Backup saved (${BACK}/stack.tgz). To restore: tar -xzf … -C $ROOT${N}"

# 1) Clean compose (no container_name/version), restart policy set
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
echo -e "${G}✔ docker-compose.yml refreshed${N}"

# 2) Dockerfiles
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
cat > "$WEB_DF" <<'DOCKER'
FROM nginx:stable-alpine
COPY web/public /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; && \
    find /usr/share/nginx/html -type f -exec chmod 644 {} \;
DOCKER
echo -e "${G}✔ Dockerfiles OK${N}"

# 3) Ensure auth core exists (only if missing)
if [[ ! -f "$CORE/auth.py" ]]; then
  cat > "$CORE/auth.py" <<'PY'
import os, time
from datetime import datetime, timedelta
from typing import Optional, Dict, Any
from jose import jwt, JWTError
from passlib.context import CryptContext
from fastapi import Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import select
from app.core.database import SessionLocal
from app.models.models import User

SECRET = os.getenv("JWT_SECRET", "dev-secret-change-me")
ALGO = "HS256"
ACCESS_MIN = int(os.getenv("JWT_MINUTES", "720"))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(p: str) -> str:
    return pwd_context.hash(p)

def verify_password(p: str, hashed: str) -> bool:
    return pwd_context.verify(p, hashed)

def create_access_token(data: Dict[str, Any], minutes: Optional[int] = None) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=minutes or ACCESS_MIN)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET, algorithm=ALGO)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def get_current_user(token: str = Depends(lambda authorization: authorization), db: Session = Depends(get_db)):
    # Accept "Authorization: Bearer <token>" or raw token in dependency override
    from fastapi import Request
    try:
        # Fast path: if a plain token passed in, try it
        try:
            payload = jwt.decode(token.split()[-1], SECRET, algorithms=[ALGO])
        except Exception:
            # Fallback to header
            req = Request(scope={"type": "http"})
            auth = req.headers.get("authorization", "")
            payload = jwt.decode(auth.split()[-1], SECRET, algorithms=[ALGO])
        uid = int(payload.get("sub"))
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    u = db.execute(select(User).where(User.id == uid)).scalar_one_or_none()
    if not u:
        raise HTTPException(status_code=401, detail="User not found")
    return u
PY
  echo -e "${Y}• auth core created${N}"
fi

# 4) main.py with CORS + auto-include routers
cat > "$API_MAIN" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="SMS Procurement Manager API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# health
@app.get("/healthz")
def healthz():
    return {"ok": True}

# auto include all routers
import pkgutil, importlib
from app import routers as _routers_pkg
for _, modname, ispkg in pkgutil.iter_modules(_routers_pkg.__path__):
    m = importlib.import_module(f"app.routers.{modname}")
    r = getattr(m, "router", None)
    if r:
        app.include_router(r)
PY
echo -e "${G}✔ main.py written (CORS + auto-routers)${N}"

# 5) users router with JSON+form login
cat > "$ROUTERS/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import select
from app.core.database import SessionLocal
from app.core.auth import create_access_token, verify_password, get_password_hash, get_current_user
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
    username = (body.username if body else None)
    password = (body.password if body else None)
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

    token = create_access_token({"sub": str(u.id), "username": u.username, "is_admin": bool(getattr(u,"is_admin",False))})
    return {"access_token": token, "token_type": "bearer"}

@router.get("/users/me")
def me(current = Depends(get_current_user)):
    return {"id": current.id, "username": current.username, "is_admin": bool(getattr(current,"is_admin",False))}

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
echo -e "${G}✔ users router ready${N}"

# 6) env.js, prelude.js, index.html (minimal) for login + warm theme
cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS

cat > "$PRELUDE_JS" <<'JS'
/* global helpers + warm theme + login panel */
(function(){
  if (window.__PRELUDE__) return; window.__PRELUDE__=true;
  const css=`
:root{
  --bg:#f7efe8; --card:#fff9f4; --text:#2a2623;
  --brand:#c26b2b; --brand-2:#8f4f1a; --ok:#2f855a; --warn:#b7791f; --err:#c53030;
}
*{box-sizing:border-box} body{margin:0;font-family:Inter,system-ui,Segoe UI,Roboto,Ubuntu,Arial,sans-serif;background:var(--bg);color:var(--text)}
.nav{display:flex;gap:.5rem;padding:.6rem .8rem;background:linear-gradient(180deg,#fff6,#fff0),var(--card);position:sticky;top:0;border-bottom:1px solid #0001}
.btn{padding:.55rem .9rem;border-radius:.6rem;border:0;cursor:pointer;margin:.15rem;background:var(--brand);color:#fff}
.btn.green{background:var(--ok)} .btn.yellow{background:#d69e2e} .btn.red{background:#e53e3e}
.card{max-width:520px;margin:8vh auto;background:var(--card);border-radius:12px;padding:20px;box-shadow:0 6px 28px rgba(0,0,0,.10);border:1px solid #0001}
label{display:block;margin:.55rem 0 .25rem;font-weight:600}
input{width:100%;padding:.55rem .6rem;border:1px solid #0002;border-radius:.5rem;background:#fff}
`;
  const st=document.createElement('style'); st.textContent=css; document.head.appendChild(st);

  window.$=(s)=>document.querySelector(s);
  window.$$=(s)=>Array.from(document.querySelectorAll(s));
  window.el=function(t,a,...k){const n=document.createElement(t);if(a)for(const [k2,v] of Object.entries(a)){if(k2==='class')n.className=v;else if(k2.startsWith('on')&&typeof v==='function')n.addEventListener(k2.slice(2),v);else n.setAttribute(k2,v)};for(const x of k)n.append(x&&x.nodeType?x:(x??''));return n};
  window.btn=(t,c,cb)=>{const b=el('button',{class:'btn '+(c||'')},t); if(cb)b.onclick=cb; return b;};
  window.go=(fn)=>Promise.resolve().then(fn).catch(console.error);

  window.authFetch=async (url,opts={})=>{
    const headers=opts.headers?{...opts.headers}:{};
    if(!headers['Content-Type'] && !(opts.body instanceof FormData)) headers['Content-Type']='application/json';
    const tok=localStorage.getItem('token'); if(tok) headers['Authorization']='Bearer '+tok;
    const res=await fetch(url,{...opts,headers});
    if(res.status===401){ localStorage.removeItem('token'); try{ window.showLogin(); }catch(_){}; throw new Error('401'); }
    if(!res.ok){ const txt=await res.text().catch(()=> ''); throw new Error(res.status+' '+txt); }
    const ct=res.headers.get('content-type')||''; return ct.includes('application/json')?res.json():res.text();
  };

  window.showLogin=function(){
    const app=document.getElementById('app')||document.body; app.innerHTML='';
    const p=el('div',{class:'card'},
      el('h2',null,'Login'),
      el('label',null,'Username'),
      el('input',{id:'loginUser',type:'text',placeholder:'admin'}),
      el('label',null,'Password'),
      el('input',{id:'loginPass',type:'password',placeholder:'••••••'}),
      btn('Login','green', async ()=>{
        const u=$('#loginUser')?.value?.trim(); const pw=$('#loginPass')?.value||'';
        if(!u||!pw){ alert('Enter username & password'); return; }
        const r=await window.authFetch((window.API_BASE||'')+'/users/login',{method:'POST',body:JSON.stringify({username:u,password:pw})});
        if(r && r.access_token){ localStorage.setItem('token',r.access_token); location.reload(); } else alert('Login failed');
      })
    );
    app.append(p);
    const pass=$('#loginPass'); if(pass){ pass.addEventListener('keydown',ev=>{ if(ev.key==='Enter') p.querySelector('button')?.click(); }); }
  };

  // auto-show login if no token
  if(!localStorage.getItem('token')) setTimeout(()=>window.showLogin(),0);
})();
JS

# Create minimal index.html (keeps your existing main.js intact if present)
if [[ ! -f "$INDEX_HTML" ]]; then
  cat > "$INDEX_HTML" <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
</head><body>
  <div class="nav" id="nav">
    <button class="btn" onclick="location.reload()">Home</button>
    <button class="btn" onclick="(async()=>{try{const me=await authFetch((API_BASE||'')+'/users/me');alert('Logged in as '+me.username);}catch(e){showLogin();}})()">Me</button>
  </div>
  <div id="app"></div>
  <script src="env.js"></script>
  <script src="prelude.js"></script>
  <script src="main.js"></script>
</body></html>
HTML
fi

echo -e "${G}✔ Frontend prelude + warm theme + login ready${N}"

# 7) Build & up
echo -e "${Y}• Rebuilding + starting containers…${N}"
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# 8) Health + seed admin if needed
sleep 3
IP=$(hostname -I | awk '{print $1}')
API_URL="http://${IP}:8010"
UI_URL="http://${IP}:5183"

echo -e "${Y}• API health…${N}"
if curl -fsS "$API_URL/healthz" >/dev/null; then echo -e "${G}✔ API up${N}"; else echo -e "${R}✖ API not healthy${N}"; fi

echo -e "${Y}• Try login admin/admin123…${N}"
if ! curl -sS -X POST "$API_URL/users/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin123"}' | grep -q access_token; then
  echo -e "${Y}• Seeding admin inside API…${N}"
  docker compose -f "$COMPOSE" exec -T api python - <<'PY' || true
from app.core.database import SessionLocal
from app.core.auth import get_password_hash
from app.models.models import User
from sqlalchemy import select
db=SessionLocal()
u=db.execute(select(User).where(User.username=='admin')).scalar_one_or_none()
if not u:
  u=User(username='admin', password_hash=get_password_hash('admin123'), is_admin=True)
  db.add(u); db.commit()
print("admin seeded")
PY
fi

echo -e "${G}✔ Done. Open ${UI_URL}. If you see login, use admin/admin123. 401s will auto-show login; Enter key submits.${N}"
