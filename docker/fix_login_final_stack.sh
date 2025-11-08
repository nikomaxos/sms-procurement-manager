#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUT="$API/routers"
WEB="$ROOT/web/public"

MAIN_PY="$API/main.py"
DB_PY="$CORE/database.py"
AUTH_PY="$CORE/auth.py"
MODELS_INIT="$MODELS/__init__.py"
USER_MODEL="$MODELS/user.py"
USERS_PY="$ROUT/users.py"
CONF_PY="$ROUT/conf.py"
SETTINGS_PY="$ROUT/settings.py"
METRICS_PY="$ROUT/metrics.py"
NETWORKS_PY="$ROUT/networks.py"
PARSERS_PY="$ROUT/parsers.py"
OFFERS_PY="$ROUT/offers.py"
HEALTH_PY="$ROUT/health.py"

ENV_JS="$WEB/env.js"
MAIN_JS="$WEB/main.js"
INDEX_HTML="$WEB/index.html"

COMPOSE="$ROOT/docker-compose.yml"
API_DF="$ROOT/api.Dockerfile"
WEB_DF="$ROOT/web.Dockerfile"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/final_$TS"

echo -e "${Y}• Backup to $BACK${N}"
mkdir -p "$BACK" "$CORE" "$MODELS" "$ROUT" "$WEB"
for f in "$COMPOSE" "$API_DF" "$WEB_DF" $API $WEB; do [[ -e "$f" ]] && cp -a "$f" "$BACK/" || true; done
touch "$API/__init__.py" "$CORE/__init__.py" "$ROUT/__init__.py"

echo -e "${Y}• Write DB/auth/models/main/routers…${N}"

# ----- core/database.py -----
cat > "$DB_PY" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

DB_URL = os.getenv("DB_URL", "postgresql+psycopg://postgres:postgres@postgres:5432/smsdb")
if DB_URL.startswith("postgresql://"):
    DB_URL = DB_URL.replace("postgresql://", "postgresql+psycopg://", 1)

engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, future=True)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
PY

# ----- core/auth.py -----
cat > "$CORE/auth.py" <<'PY'
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

# ----- models/__init__.py -----
cat > "$MODELS_INIT" <<'PY'
from app.core.database import Base
from .user import User  # noqa: F401
PY

# ----- models/user.py -----
cat > "$USER_MODEL" <<'PY'
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy import String
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(32), default="user")
PY

# ----- routers/users.py -----
cat > "$USERS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session
from jose import jwt, JWTError

from app.core.database import get_db, SessionLocal
from app.core.auth import verify_password, get_password_hash, create_access_token, SECRET_KEY, ALGORITHM
from app.models.user import User

router = APIRouter(prefix="/users", tags=["users"])

def ensure_admin():
    with SessionLocal() as db:
        admin = db.execute(select(User).where(User.username=="admin")).scalar_one_or_none()
        if not admin:
            u = User(username="admin", password_hash=get_password_hash("admin123"), role="admin")
            db.add(u); db.commit()

@router.post("/login")
async def login(payload: dict, db: Session = Depends(get_db)):
    # JSON-only to keep it deterministic
    username = (payload or {}).get("username")
    password = (payload or {}).get("password")
    if not username or not password:
        raise HTTPException(status_code=422, detail="username/password required")

    user = db.execute(select(User).where(User.username==username)).scalar_one_or_none()
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": user.username, "role": user.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": user.username, "role": user.role}}

@router.get("/me")
def me(request: Request):
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        token = auth.split(" ", 1)[1]
        try:
            payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
            return {"username": payload.get("sub"), "role": payload.get("role")}
        except JWTError:
            pass
    return {"username": None, "role": None}
PY

# ----- other stub routers your UI calls -----
cat > "$CONF_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/conf", tags=["conf"])
@router.get("/enums")
def enums():
    return {"countries": [], "mccmnc": [], "vendors": [], "tags": []}
PY

cat > "$SETTINGS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/settings", tags=["settings"])
@router.get("/imap")   def get_imap():   return {}
@router.post("/imap")  def set_imap(cfg: dict): return {"ok": True, "saved": cfg}
@router.get("/scrape") def get_scrape(): return {}
@router.post("/scrape")def set_scrape(cfg: dict):return {"ok": True, "saved": cfg}
PY

cat > "$METRICS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/metrics", tags=["metrics"])
@router.get("/trends")
def trends(d: str): return {"date": d, "series": []}
PY

cat > "$NETWORKS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/networks", tags=["networks"])
@router.get("/") def list_networks(): return []
PY

cat > "$PARSERS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/parsers", tags=["parsers"])
@router.get("/") def list_parsers(): return []
PY

cat > "$OFFERS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/offers", tags=["offers"])
@router.get("/") def list_offers(limit: int = 50, offset: int = 0): return {"count": 0, "results": []}
PY

cat > "$HEALTH_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/health", tags=["health"])
@router.get("") def health(): return {"ok": True}
PY

# ----- main.py: global CORS + startup DB create/admin seed + explicit routers -----
cat > "$MAIN_PY" <<'PY'
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import PlainTextResponse
from sqlalchemy import select

from app.core.database import Base, engine, SessionLocal
from app.models.user import User
from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router
from app.routers.metrics import router as metrics_router
from app.routers.networks import router as networks_router
from app.routers.parsers import router as parsers_router
from app.routers.offers import router as offers_router
from app.routers.health import router as health_router

app = FastAPI(title="SMS Procurement Manager (final)")

# Global CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

# Ensure CORS even on errors and preflight
@app.middleware("http")
async def always_cors(request: Request, call_next):
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        try:
            resp = await call_next(request)
        except Exception as e:
            # return plain 500 but keep CORS so the browser can see it
            resp = PlainTextResponse("Internal Server Error", status_code=500)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp

@app.on_event("startup")
def init_db_and_admin():
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        admin = db.execute(select(User).where(User.username=="admin")).scalar_one_or_none()
        if not admin:
            db.add(User(username="admin", password_hash="$2b$12$V83kM0xwP2YV3YFZJmG3zOZ2oG3jv8x3wYtQz6s9aYk3rCz9ZQH2G", role="admin"))  # bcrypt for "admin123"
            db.commit()

# routers
app.include_router(users_router)
app.include_router(conf_router)
app.include_router(settings_router)
app.include_router(metrics_router)
app.include_router(networks_router)
app.include_router(parsers_router)
app.include_router(offers_router)
app.include_router(health_router)
PY

echo -e "${Y}• Write minimal WEB (warm palette + JSON login)…${N}"
cat > "$INDEX_HTML" <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
<style>
:root{--bg:#1f1713;--panel:#2a1f1a;--accent:#d98b48;--text:#f6efe9;--muted:#cbb7a7;--radius:14px;}
html,body{height:100%;margin:0;background:var(--bg);color:var(--text);font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:20px}
.nav{display:flex;gap:8px;margin-bottom:16px;position:sticky;top:0;background:linear-gradient(180deg,rgba(31,23,19,.98),rgba(31,23,19,.6));backdrop-filter:blur(6px);padding:10px;border-radius:var(--radius)}
.btn{background:var(--panel);color:var(--text);border:1px solid rgba(255,255,255,.08);padding:10px 14px;border-radius:var(--radius);cursor:pointer}
.btn:hover{background:#3a2c24}.accent{background:var(--accent);color:#1a120d;border:none}
.panel{background:var(--panel);padding:16px;border-radius:var(--radius);border:1px solid rgba(255,255,255,.08)}
input{background:#201712;color:var(--text);border:1px solid rgba(255,255,255,.12);border-radius:12px;padding:10px 12px;outline:none}
.muted{color:var(--muted)}.error{color:#ff6e6e}
</style></head><body>
<div class="wrap">
  <div class="nav">
    <button class="btn" data-view="offers">Offers</button>
    <button class="btn" data-view="networks">Networks</button>
    <button class="btn" data-view="parsers">Parsers</button>
    <button class="btn" data-view="settings">Settings</button>
    <div style="flex:1"></div>
    <div id="user-slot" class="muted">Guest</div>
    <button id="logout" class="btn">Logout</button>
  </div>
  <div id="login-panel" class="panel" style="display:none">
    <h2>Login</h2>
    <div><input id="login-username" placeholder="admin"> <input id="login-password" type="password" placeholder="admin123"></div>
    <div style="margin-top:12px"><button id="login-btn" class="btn accent">Login</button> <span id="login-error" class="error"></span></div>
  </div>
  <div id="content" class="panel"></div>
</div>
<script src="env.js"></script><script src="main.js"></script>
</body></html>
HTML

cat > "$ENV_JS" <<'JS'
(function(){ const saved=localStorage.getItem('API_BASE'); window.API_BASE=saved||location.origin.replace(':5183',':8010');})();
JS

cat > "$MAIN_JS" <<'JS'
(function(){
  const $=s=>document.querySelector(s);
  const API=()=>window.API_BASE||location.origin.replace(':5183',':8010');

  async function postJSON(url, body){
    const r = await fetch(url,{method:'POST',headers:{'Content-Type':'application/json','Accept':'application/json'},body:JSON.stringify(body||{})});
    const txt = await r.text(); let js={}; try{js=txt?JSON.parse(txt):{};}catch(e){}
    return {ok:r.ok, status:r.status, json:js, raw:r};
  }

  window.authFetch = async function(url, init={}){
    const t = localStorage.getItem('TOKEN');
    init.headers = Object.assign({'Accept':'application/json'}, init.headers||{});
    if(t) init.headers['Authorization']='Bearer '+t;
    const r = await fetch(url, init);
    if(r.status===401){ localStorage.removeItem('TOKEN'); showLogin(); throw new Error('401'); }
    if(!r.ok){ throw new Error(r.status+' '+await r.text()); }
    return r.headers.get('content-type')?.includes('application/json')? r.json(): r.text();
  };

  function showLogin(){ $('#login-panel').style.display=''; $('#content').innerHTML=''; $('#login-error').textContent=''; }
  function showUser(u){ $('#user-slot').textContent = u&&u.username ? (u.username+' ('+(u.role||'')+')') : 'Guest'; }

  window.doLogin = async function(){
    const u=$('#login-username').value.trim(), p=$('#login-password').value;
    if(!u||!p){ $('#login-error').textContent='Type username & password'; return; }
    const {ok,status,json} = await postJSON(API()+'/users/login', {username:u,password:p});
    if(!ok || !json.access_token){ $('#login-error').textContent=(json?.detail||('Login failed '+status)); return; }
    localStorage.setItem('TOKEN', json.access_token); $('#login-panel').style.display='none'; await init();
  };

  async function viewOffers(){ $('#content').innerHTML='<h2>Offers</h2><pre>'+JSON.stringify(await authFetch(API()+'/offers/?limit=50&offset=0'),null,2)+'</pre>'; }
  async function viewNetworks(){ $('#content').innerHTML='<h2>Networks</h2><pre>'+JSON.stringify(await authFetch(API()+'/networks/'),null,2)+'</pre>'; }
  async function viewParsers(){ $('#content').innerHTML='<h2>Parsers</h2><pre>'+JSON.stringify(await authFetch(API()+'/parsers/'),null,2)+'</pre>'; }
  async function viewSettings(){
    const e=await authFetch(API()+'/conf/enums');
    const im=await authFetch(API()+'/settings/imap');
    const sc=await authFetch(API()+'/settings/scrape');
    $('#content').innerHTML='<h2>Settings</h2><pre>'+JSON.stringify({e,im,sc},null,2)+'</pre>';
  }

  async function init(){
    let u=null; try{ u=await authFetch(API()+'/users/me'); }catch(e){}
    showUser(u); if(!localStorage.getItem('TOKEN')){ showLogin(); return; }
    try{ await viewOffers(); }catch(e){ $('#content').textContent='Ready.'; }
  }

  document.addEventListener('click', (e)=>{ const v=e.target?.getAttribute?.('data-view'); if(!v) return;
    e.preventDefault(); if(v==='offers') return viewOffers(); if(v==='networks') return viewNetworks(); if(v==='parsers') return viewParsers(); if(v==='settings') return viewSettings();
  });
  $('#login-btn')?.addEventListener('click', (e)=>{ e.preventDefault(); window.doLogin(); });
  $('#login-password')?.addEventListener('keydown',(e)=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); }});
  $('#logout')?.addEventListener('click', ()=>{ localStorage.removeItem('TOKEN'); showUser(null); showLogin(); });

  if(!localStorage.getItem('TOKEN')) showLogin(); init();
})();
JS

echo -e "${Y}• Dockerfiles & compose…${N}"
cat > "$API_DF" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" pydantic python-multipart python-jose[cryptography] "passlib[bcrypt]==1.7.4"
ENV PYTHONUNBUFFERED=1
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

cat > "$WEB_DF" <<'DOCKER'
FROM nginx:stable-alpine
COPY web/public /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; && \
    find /usr/share/nginx/html -type f -exec chmod 644 {} \;
DOCKER

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
      SECRET_KEY: dev-secret-change-me
    depends_on: [postgres]
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
    dockerfile: web.Dockerfile
    restart: unless-stopped
    depends_on: [api]
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata:

networks:
  stack:
YAML

echo -e "${Y}• Rebuild (no cache) & start…${N}"
docker compose -f "$COMPOSE" down --remove-orphans >/dev/null 2>&1 || true
docker compose -f "$COMPOSE" build --no-cache >/dev/null
docker compose -f "$COMPOSE" up -d >/dev/null
sleep 4

IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n▶ OPTIONS /users/login${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" -H "Origin: http://${IP}:5183" -H "Access-Control-Request-Method: POST" | sed -n '1,30p'

echo -e "${Y}\n▶ POST /users/login (JSON)${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" -H "Origin: http://${IP}:5183" -H "Content-Type: application/json" --data '{"username":"admin","password":"admin123"}' | sed -n '1,60p'

echo -e "${G}\n✔ Open http://${IP}:5183 , hard refresh, login admin/admin123.${N}"
