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
DB_PY="$CORE/database.py"

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
BACK="$ROOT/.backups/rebuild_$TS"

echo -e "${Y}• Backing up current files to ${BACK}${N}"
mkdir -p "$BACK" "$CORE" "$ROUT" "$WEB"
for f in "$COMPOSE" "$API_DF" "$WEB_DF" $API $WEB; do
  [[ -e "$f" ]] && cp -a "$f" "$BACK/" || true
done

echo -e "${Y}• Writing clean API (database/auth/main/routers)…${N}"
mkdir -p "$API" "$CORE" "$ROUT"
touch "$API/__init__.py" "$CORE/__init__.py" "$ROUT/__init__.py"

# ---------------- core/database.py ----------------
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

# ---------------- core/auth.py ----------------
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

# ---------------- routers/users.py ----------------
cat > "$USERS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from sqlalchemy import text
from urllib.parse import parse_qs
import json
from jose import jwt, JWTError

from app.core.database import get_db, engine
from app.core.auth import verify_password, get_password_hash, create_access_token, SECRET_KEY, ALGORITHM

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

    # JSON
    raw = await request.body()
    txt = raw.decode("utf-8", "ignore") if raw else ""
    if txt:
        try:
            data = json.loads(txt)
            if isinstance(data, dict):
                username = data.get("username") or data.get("user") or data.get("email")
                password = data.get("password") or data.get("pass")
        except Exception:
            pass

    # Form (multipart/x-www-form-urlencoded)
    if not (username and password):
        try:
            form = await request.form()
            username = username or form.get("username") or form.get("user") or form.get("email")
            password = password or form.get("password") or form.get("pass")
        except Exception:
            pass

    # Raw urlencoded
    if not (username and password) and txt and "=" in txt:
        qs = parse_qs(txt)
        username = username or (qs.get("username") or qs.get("user") or qs.get("email") or [None])[0]
        password = password or (qs.get("password") or qs.get("pass") or [None])[0]

    # Query params
    if not (username and password):
        q = request.query_params
        username = username or q.get("username") or q.get("user") or q.get("email")
        password = password or q.get("password") or q.get("pass")

    if not (username and password):
        raise HTTPException(status_code=422, detail="username/password required")

    row = db.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), {"u": username}).first()
    if not row or not verify_password(password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": row.username, "role": row.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": row.username, "role": row.role}}

@router.get("/me")
def me(request: Request):
    # Very light auth: read Bearer token and decode; if invalid, anonymous
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

# ---------------- routers/conf.py ----------------
cat > "$CONF_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/conf", tags=["conf"])

@router.get("/enums")
def enums():
    # Minimal stub to satisfy UI
    return {
      "countries": [],
      "mccmnc": [],
      "vendors": [],
      "tags": [],
    }
PY

# ---------------- routers/settings.py ----------------
cat > "$SETTINGS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/settings", tags=["settings"])

@router.get("/imap")
def get_imap():
    return {}

@router.post("/imap")
def set_imap(cfg: dict):
    return {"ok": True, "saved": cfg}

@router.get("/scrape")
def get_scrape():
    return {}

@router.post("/scrape")
def set_scrape(cfg: dict):
    return {"ok": True, "saved": cfg}
PY

# ---------------- routers/metrics.py ----------------
cat > "$METRICS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/metrics", tags=["metrics"])

@router.get("/trends")
def trends(d: str):
    return {"date": d, "series": []}
PY

# ---------------- routers/networks.py ----------------
cat > "$NETWORKS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/networks", tags=["networks"])

@router.get("/")
def list_networks():
    return []
PY

# ---------------- routers/parsers.py ----------------
cat > "$PARSERS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/parsers", tags=["parsers"])

@router.get("/")
def list_parsers():
    return []
PY

# ---------------- routers/offers.py ----------------
cat > "$OFFERS_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/offers", tags=["offers"])

@router.get("/")
def list_offers(limit: int = 50, offset: int = 0):
    return {"count": 0, "results": []}
PY

# ---------------- routers/health.py ----------------
cat > "$HEALTH_PY" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/health", tags=["health"])

@router.get("")
def health():
    return {"ok": True}
PY

# ---------------- main.py with global CORS (preflight + errors) ----------------
cat > "$MAIN_PY" <<'PY'
import importlib, os, pkgutil
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import PlainTextResponse

app = FastAPI(title="SMS Procurement Manager (clean)")

# CORS on every response including preflight & errors
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

@app.middleware("http")
async def always_cors(request: Request, call_next):
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

# Mount routers explicitly to avoid accidental duplicates/skip logic
from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router
from app.routers.metrics import router as metrics_router
from app.routers.networks import router as networks_router
from app.routers.parsers import router as parsers_router
from app.routers.offers import router as offers_router
from app.routers.health import router as health_router

app.include_router(users_router)
app.include_router(conf_router)
app.include_router(settings_router)
app.include_router(metrics_router)
app.include_router(networks_router)
app.include_router(parsers_router)
app.include_router(offers_router)
app.include_router(health_router)
PY

echo -e "${Y}• Writing clean WEB (warm palette + robust login)…${N}"
mkdir -p "$WEB"

# ---------------- web/public/index.html ----------------
cat > "$INDEX_HTML" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SMS Procurement Manager</title>
  <style>
    :root{
      --bg:#1f1713;        /* warm dark espresso */
      --panel:#2a1f1a;     /* panel */
      --accent:#d98b48;    /* amber */
      --accent-2:#b86b3d;  /* cinnamon */
      --text:#f6efe9;      /* warm off-white */
      --muted:#cbb7a7;
      --error:#ff5d5d;
      --ok:#7bd88f;
      --radius:14px;
    }
    html,body{height:100%; margin:0; background:var(--bg); color:var(--text); font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;}
    .wrap{max-width:1100px; margin:0 auto; padding:20px;}
    .nav{display:flex; gap:8px; margin-bottom:16px; position:sticky; top:0; background:linear-gradient(180deg, rgba(31,23,19,.98), rgba(31,23,19,.6)); backdrop-filter: blur(6px); padding:10px; border-radius:var(--radius);}
    .btn{background:var(--panel); color:var(--text); border:1px solid rgba(255,255,255,.08); padding:10px 14px; border-radius:var(--radius); cursor:pointer}
    .btn:hover{background:#3a2c24}
    .accent{background:var(--accent); color:#1a120d; border:none}
    .panel{background:var(--panel); padding:16px; border-radius:var(--radius); border:1px solid rgba(255,255,255,.08)}
    input,select{background:#201712; color:var(--text); border:1px solid rgba(255,255,255,.12); border-radius:12px; padding:10px 12px; outline:none}
    input::placeholder{color:#9b8a7d}
    .grid{display:grid; gap:12px}
    .two{grid-template-columns: 1fr 1fr}
    .three{grid-template-columns: repeat(3,1fr)}
    .compact fieldset{border:none; margin:0; padding:0}
    .compact legend{font-weight:600; color:var(--muted); margin-bottom:8px}
    .compact .row{display:grid; grid-template-columns: 180px 1fr; align-items:center; gap:10px; margin:6px 0}
    .error{color:var(--error)}
    .muted{color:var(--muted)}
  </style>
</head>
<body>
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
      <div class="grid two">
        <label>Username <input id="login-username" placeholder="admin"></label>
        <label>Password <input id="login-password" type="password" placeholder="admin123"></label>
      </div>
      <div style="margin-top:12px">
        <button id="login-btn" class="btn accent">Login</button>
        <span id="login-error" class="error" style="margin-left:10px"></span>
      </div>
    </div>

    <div id="content" class="panel"></div>
  </div>

  <script src="env.js"></script>
  <script src="main.js"></script>
</body>
</html>
HTML

# ---------------- web/public/env.js ----------------
cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS

# ---------------- web/public/main.js ----------------
cat > "$MAIN_JS" <<'JS'
(function(){
  const $ = (s)=>document.querySelector(s);
  const api = ()=> window.API_BASE || location.origin.replace(':5183', ':8010');

  async function postJSON(url, body){
    const r = await fetch(url, {
      method:'POST',
      headers: {'Content-Type':'application/json','Accept':'application/json'},
      body: JSON.stringify(body||{})
    });
    const txt = await r.text(); let json={}; try{ json = txt? JSON.parse(txt):{}; }catch(e){}
    return {ok:r.ok, status:r.status, json, raw:r};
  }
  window.authFetch = async function(url, init={}){
    const t = localStorage.getItem('TOKEN');
    init.headers = Object.assign({'Accept':'application/json'}, init.headers||{});
    if(t) init.headers['Authorization'] = 'Bearer '+t;
    const r = await fetch(url, init);
    if(r.status===401){ localStorage.removeItem('TOKEN'); showLogin(); throw new Error('401 Unauthorized'); }
    if(!r.ok){ const b=await r.text(); throw new Error(r.status+' '+b); }
    const ct = r.headers.get('content-type')||''; return ct.includes('application/json')? r.json(): r.text();
  };

  function showLogin(){
    $('#login-panel').style.display='';
    $('#content').innerHTML='';
    $('#login-error').textContent='';
    $('#login-username')?.focus();
  }
  function showUser(u){
    $('#user-slot').textContent = u && u.username ? (u.username+' ('+(u.role||'')+')') : 'Guest';
  }

  window.doLogin = async function(){
    const u = $('#login-username')?.value?.trim();
    const p = $('#login-password')?.value||'';
    if(!u||!p){ $('#login-error').textContent='Type username & password'; return; }
    const {ok,status,json} = await postJSON(api()+'/users/login', {username:u, password:p});
    if(!ok || !json.access_token){ $('#login-error').textContent = (json?.detail||('Login failed '+status)); return; }
    localStorage.setItem('TOKEN', json.access_token);
    $('#login-panel').style.display='none';
    await init();
  };

  async function viewOffers(){
    const d = await authFetch(api()+'/offers/?limit=50&offset=0');
    $('#content').innerHTML = '<h2>Offers</h2><pre>'+JSON.stringify(d,null,2)+'</pre>';
  }
  async function viewNetworks(){
    const d = await authFetch(api()+'/networks/');
    $('#content').innerHTML = '<h2>Networks</h2><pre>'+JSON.stringify(d,null,2)+'</pre>';
  }
  async function viewParsers(){
    const d = await authFetch(api()+'/parsers/');
    $('#content').innerHTML = '<h2>Parsers</h2><pre>'+JSON.stringify(d,null,2)+'</pre>';
  }
  async function viewSettings(){
    const e = await authFetch(api()+'/conf/enums');
    const im = await authFetch(api()+'/settings/imap');
    const sc = await authFetch(api()+'/settings/scrape');
    $('#content').innerHTML =
      '<h2>Settings</h2>'+
      '<div class="grid two compact">'+
      '<fieldset><legend>Dropdown categories</legend>'+
        '<div class="row"><div>Vendors</div><input placeholder="add vendor"/></div>'+
        '<div class="row"><div>Tags</div><input placeholder="add tag"/></div>'+
      '</fieldset>'+
      '<fieldset><legend>IMAP</legend>'+
        '<div class="row"><div>Server</div><input placeholder="imap.example.com"/></div>'+
        '<div class="row"><div>User</div><input placeholder="user@example.com"/></div>'+
      '</fieldset>'+
      '<fieldset><legend>Scraping</legend>'+
        '<div class="row"><div>Interval</div><input placeholder="*/10 * * * *"/></div>'+
        '<div class="row"><div>Agent</div><input placeholder="Mozilla/5.0"/></div>'+
      '</fieldset>'+
      '</div>';
  }

  async function init(){
    // try get user (if token present)
    let u=null; try { u = await authFetch(api()+'/users/me'); } catch(e){ /* ignore */ }
    showUser(u);
    if(!localStorage.getItem('TOKEN')){ showLogin(); return; }
    // default view
    try { await viewOffers(); } catch(e){ $('#content').textContent = 'Ready.'; }
  }

  // nav wiring
  document.addEventListener('click', (e)=>{
    const v = e.target?.getAttribute?.('data-view');
    if(!v) return;
    e.preventDefault();
    if(v==='offers') return viewOffers();
    if(v==='networks') return viewNetworks();
    if(v==='parsers') return viewParsers();
    if(v==='settings') return viewSettings();
  });
  $('#login-btn')?.addEventListener('click', (e)=>{ e.preventDefault(); window.doLogin(); });
  $('#login-password')?.addEventListener('keydown', (e)=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); }});
  $('#logout')?.addEventListener('click', ()=>{ localStorage.removeItem('TOKEN'); showUser(null); showLogin(); });

  // start
  if(!localStorage.getItem('TOKEN')) showLogin();
  init();
})();
JS

echo -e "${Y}• Writing Dockerfiles & docker-compose.yml…${N}"
# ---------------- api.Dockerfile ----------------
cat > "$API_DF" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" \
    pydantic python-multipart python-jose[cryptography] "passlib[bcrypt]==1.7.4"
ENV PYTHONUNBUFFERED=1
CMD ["uvicorn", "app.main:app", "--host","0.0.0.0","--port","8000"]
DOCKER

# ---------------- web.Dockerfile ----------------
cat > "$WEB_DF" <<'DOCKER'
FROM nginx:stable-alpine
COPY web/public /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; && \
    find /usr/share/nginx/html -type f -exec chmod 644 {} \;
DOCKER

# ---------------- docker-compose.yml ----------------
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

echo -e "${Y}• Rebuilding images and starting stack…${N}"
docker compose -f "$COMPOSE" down --remove-orphans >/dev/null 2>&1 || true
docker compose -f "$COMPOSE" build >/dev/null
docker compose -f "$COMPOSE" up -d >/dev/null
sleep 4

IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n▶ OPTIONS /users/login (preflight)${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,20p'

echo -e "${Y}\n▶ POST JSON /users/login (admin/admin123)${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,40p'

echo -e "${G}\n✔ Done. Open http://${IP}:5183 , hard-refresh (Ctrl/Cmd+Shift+R), then login with admin / admin123.${N}"
