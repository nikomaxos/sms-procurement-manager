#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUT="$API/routers"
WEB="$ROOT/web/public"

COMPOSE="$ROOT/docker-compose.yml"
API_DF="$ROOT/api.Dockerfile"
WEB_DF="$ROOT/web.Dockerfile"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/hard_reset_$TS"
echo -e "${Y}• Backing up to $BACK${N}"
mkdir -p "$BACK"
[ -e "$ROOT/api" ] && cp -a "$ROOT/api" "$BACK/" || true
[ -e "$ROOT/web" ] && cp -a "$ROOT/web" "$BACK/" || true
[ -e "$COMPOSE" ] && cp -a "$COMPOSE" "$BACK/" || true
[ -e "$API_DF" ] && cp -a "$API_DF" "$BACK/" || true
[ -e "$WEB_DF" ] && cp -a "$WEB_DF" "$BACK/" || true

echo -e "${Y}• Laying down clean API structure…${N}"
mkdir -p "$CORE" "$MODELS" "$ROUT" "$WEB"
touch "$API/__init__.py" "$CORE/__init__.py" "$MODELS/__init__.py" "$ROUT/__init__.py"

# ---------- api/core/database.py ----------
cat > "$CORE/database.py" <<'PY'
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

# ---------- api/core/auth.py ----------
cat > "$CORE/auth.py" <<'PY'
import os
from datetime import datetime, timedelta, timezone
from typing import Optional, Dict, Any

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import jwt, JWTError

SECRET_KEY = os.getenv("SECRET_KEY", "dev-change-me")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "1440"))

security = HTTPBearer(auto_error=False)

def create_access_token(data: Dict[str, Any], expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(security)) -> Dict[str, Any]:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    token = credentials.credentials
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        sub = payload.get("sub")
        role = payload.get("role")
        if not sub:
            raise HTTPException(status_code=401, detail="Invalid token")
        return {"username": sub, "role": role or "user"}
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
PY

# ---------- api/models/user.py ----------
cat > "$MODELS/user.py" <<'PY'
from sqlalchemy import Column, Integer, String, UniqueConstraint
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String(64), nullable=False, unique=True)
    hashed_password = Column(String(255), nullable=False)
    role = Column(String(32), nullable=False, default="admin")
    __table_args__ = (UniqueConstraint('username', name='uq_user_username'),)
PY

# ---------- api/models/kv.py ----------
cat > "$MODELS/kv.py" <<'PY'
from sqlalchemy import Column, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.types import JSON
from app.core.database import Base

try:
    JSONType = JSONB
except Exception:
    JSONType = JSON  # fallback if not PG driver exposes JSONB

class KVSetting(Base):
    __tablename__ = "kv_settings"
    id = Column(Integer, primary_key=True)
    key = Column(String(128), nullable=False, unique=True)
    value = Column(JSONType, nullable=False, default={})
    __table_args__ = (UniqueConstraint('key', name='uq_kv_key'),)
PY

# ---------- api/routers/users.py ----------
cat > "$ROUT/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session
from passlib.context import CryptContext

from app.core.database import get_db, Base, engine, SessionLocal
from app.core.auth import create_access_token, get_current_user
from app.models.user import User

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
router = APIRouter(prefix="/users", tags=["users"])

class LoginIn(BaseModel):
    username: str
    password: str

@router.post("/login")
def login(payload: LoginIn, db: Session = Depends(get_db)):
    # seed admin if table empty
    if db.query(User).count() == 0:
        h = pwd_context.hash("admin123")
        db.add(User(username="admin", hashed_password=h, role="admin"))
        db.commit()
    user = db.query(User).filter(User.username == payload.username).one_or_none()
    if not user or not pwd_context.verify(payload.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token({"sub": user.username, "role": user.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": user.username, "role": user.role}}

@router.get("/me")
def me(current = Depends(get_current_user)):
    return {"user": current}
PY

# ---------- api/routers/conf.py (protected) ----------
cat > "$ROUT/conf.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.core.auth import get_current_user
from app.models.kv import KVSetting

router = APIRouter(prefix="/conf", tags=["conf"], dependencies=[Depends(get_current_user)])
ENUM_KEYS = ["countries","mccmnc","vendors","tags"]

def _get(db: Session, key: str):
    return db.query(KVSetting).filter(KVSetting.key==key).one_or_none()

@router.get("/enums")
def get_enums(db: Session = Depends(get_db)):
    out = {}
    for k in ENUM_KEYS:
        row = _get(db, f"enums.{k}")
        out[k] = (row.value if row else [])
    return out

@router.put("/enums")
def put_enums(payload: dict, db: Session = Depends(get_db)):
    for k in ENUM_KEYS:
        lst = payload.get(k, [])
        if not isinstance(lst, list):
            raise HTTPException(400, f"{k} must be a list")
        row = _get(db, f"enums.{k}")
        if row is None:
            row = KVSetting(key=f"enums.{k}", value=lst); db.add(row)
        else:
            row.value = lst
    db.commit()
    return {"ok": True}
PY

# ---------- api/routers/settings.py (protected) ----------
cat > "$ROUT/settings.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.core.auth import get_current_user
from app.models.kv import KVSetting
import ssl, imaplib

router = APIRouter(prefix="/settings", tags=["settings"], dependencies=[Depends(get_current_user)])

def kv_get(db: Session, key: str, default):
    row = db.query(KVSetting).filter(KVSetting.key==key).one_or_none()
    return row.value if row else default

def kv_put(db: Session, key: str, value):
    row = db.query(KVSetting).filter(KVSetting.key==key).one_or_none()
    if row is None:
        row = KVSetting(key=key, value=value); db.add(row)
    else:
        row.value = value
    db.commit()

@router.get("/imap")
def get_imap(db: Session = Depends(get_db)):
    return kv_get(db, "imap", {
        "host":"", "port":993, "username":"", "password":"",
        "ssl":True, "folder":"INBOX", "enabled":False
    })

@router.put("/imap")
def put_imap(cfg: dict, db: Session = Depends(get_db)):
    if not isinstance(cfg, dict): raise HTTPException(400, "Invalid IMAP config")
    cfg.setdefault("port", 993); cfg.setdefault("ssl", True)
    cfg.setdefault("folder","INBOX"); cfg.setdefault("enabled", False)
    kv_put(db, "imap", cfg); return {"ok": True}

@router.post("/imap/test")
def test_imap(db: Session = Depends(get_db)):
    cfg = kv_get(db, "imap", {})
    host = cfg.get("host"); port = int(cfg.get("port", 993))
    user = cfg.get("username"); pwd = cfg.get("password")
    use_ssl = bool(cfg.get("ssl", True))
    if not host or not user or not pwd:
        raise HTTPException(400, "Set host/username/password first")
    try:
        if use_ssl:
            ctx = ssl.create_default_context()
            with imaplib.IMAP4_SSL(host, port, ssl_context=ctx) as M:
                M.login(user, pwd); typ, _ = M.select(cfg.get("folder","INBOX")); return {"ok": typ=="OK"}
        else:
            with imaplib.IMAP4(host, port) as M:
                M.login(user, pwd); typ, _ = M.select(cfg.get("folder","INBOX")); return {"ok": typ=="OK"}
    except Exception as e:
        raise HTTPException(400, f"IMAP connect failed: {e}")

@router.get("/scrape")
def get_scrape(db: Session = Depends(get_db)):
    return kv_get(db, "scrape", {
        "enabled": False, "interval_minutes": 30, "user_agent": "Mozilla/5.0",
        "max_concurrency": 4, "start_urls": [], "allow_domains": [],
        "block_domains": [], "render_js": False
    })

@router.put("/scrape")
def put_scrape(cfg: dict, db: Session = Depends(get_db)):
    if not isinstance(cfg, dict): raise HTTPException(400, "Invalid scrape config")
    kv_put(db, "scrape", cfg); return {"ok": True}
PY

# ---------- api/routers/offers.py & metrics.py (protected stubs) ----------
cat > "$ROUT/offers.py" <<'PY'
from fastapi import APIRouter, Depends
from app.core.auth import get_current_user

router = APIRouter(prefix="/offers", tags=["offers"], dependencies=[Depends(get_current_user)])

@router.get("/")
def list_offers(limit: int = 50, offset: int = 0):
    return {"items": [], "total": 0, "limit": limit, "offset": offset}
PY

cat > "$ROUT/metrics.py" <<'PY'
from fastapi import APIRouter, Depends
from app.core.auth import get_current_user
router = APIRouter(prefix="/metrics", tags=["metrics"], dependencies=[Depends(get_current_user)])

@router.get("/trends")
def trends(d: str):
    return {"date": d, "series": []}
PY

# ---------- api/main.py ----------
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from app.core.database import Base, engine, SessionLocal
from app.models.user import User
from passlib.context import CryptContext

from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router
from app.routers.offers import router as offers_router
from app.routers.metrics import router as metrics_router

app = FastAPI(title="SMS Procurement Manager API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],            # dev: permissive; no cookies; Bearer only
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# create tables
Base.metadata.create_all(bind=engine)

# seed admin if empty
pwd_context = Passlib = CryptContext(schemes=["bcrypt"], deprecated="auto")
with SessionLocal() as db:  # one-shot seed
    if db.query(User).count() == 0:
        db.add(User(username="admin", hashed_password=pwd_context.hash("admin123"), role="admin"))
        db.commit()

@app.get("/health")
def health(): return {"ok": True}

# routers
app.include_router(users_router)     # /users/login, /users/me
app.include_router(conf_router)      # protected
app.include_router(settings_router)  # protected
app.include_router(offers_router)    # protected
app.include_router(metrics_router)   # protected
PY

# ---------- web/public/index.html ----------
cat > "$WEB/index.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SMS Procurement Manager</title>
</head>
<body>
  <div id="app"></div>
  <script src="main.js"></script>
</body>
</html>
HTML

# ---------- web/public/main.js ----------
cat > "$WEB/main.js" <<'JS'
(() => {
  const API = (window.API_BASE || (location.origin.replace(':5183', ':8010')));
  let tk = localStorage.getItem('tk') || '';

  async function authFetch(path, opts = {}) {
    const url = path.startsWith('http') ? path : `${API}${path}`;
    const headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
    if (tk) headers['Authorization'] = 'Bearer ' + tk;
    const res = await fetch(url, Object.assign({}, opts, { headers }));
    if (res.status === 401) { logout(); throw new Error('401'); }
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : res.text();
  }
  const getJSON = (p)=>authFetch(p, {method:'GET'});
  const putJSON = (p,b)=>authFetch(p, {method:'PUT', body: JSON.stringify(b)});
  const postJSON = (p,b)=>authFetch(p, {method:'POST', body: JSON.stringify(b)});

  const app = document.getElementById('app');
  const H = (t,a={},k=[])=>{ const e=document.createElement(t);
    for (const [k2,v] of Object.entries(a)) {
      if (k2==='class') e.className=v;
      else if (k2.startsWith('on')) e.addEventListener(k2.slice(2), v);
      else e.setAttribute(k2, v===true?'':v);
    }
    (Array.isArray(k)?k:[k]).forEach(x=>{ if(x==null)return; e.appendChild(x instanceof Node?x:document.createTextNode(String(x))); });
    return e;
  };

  function css() {
    const s = document.createElement('style');
    s.textContent = `
:root { --bg:#0f0f10; --card:#1a1b1e; --ink:#f5f5f7; --muted:#b9beca; --accent:#67d2a4; }
*{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.4 system-ui,Segoe UI,Roboto,sans-serif}
nav{display:flex;gap:8px;padding:10px 12px;border-bottom:1px solid #25262b;position:sticky;top:0;background:#121315}
button{background:var(--accent);color:#101114;border:0;padding:8px 12px;border-radius:10px;cursor:pointer}
button.ghost{background:transparent;color:var(--ink);border:1px solid #333}
.card{background:var(--card);border:1px solid #2a2b31;border-radius:14px;padding:12px;margin:12px}
.row{display:flex;gap:8px;align-items:center;margin:6px 0}
input[type=text],input[type=password],input[type=number]{flex:1;padding:6px 8px;border-radius:8px;border:1px solid #333;background:#121315;color:var(--ink)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.small{font-size:12px;color:var(--muted)}
hr{border:0;border-top:1px solid #2a2b31;margin:10px 0}
`; document.head.appendChild(s); }
  css();

  function logout(){ tk=''; localStorage.removeItem('tk'); loginScreen(); }

  function listEditor(title, arr) {
    const card = H('div',{class:'card'},[H('h3',{},title)]);
    const list = H('div');
    const draw = ()=>{ list.innerHTML=''; arr.forEach((v,i)=> list.appendChild(H('div',{class:'row'},[
      H('input',{type:'text',value:v,oninput:e=>arr[i]=e.target.value}),
      H('button',{onclick:()=>{arr.splice(i,1);draw();}},'Remove')
    ]))); };
    draw();
    const add = H('div',{class:'row'},[
      H('input',{type:'text',placeholder:'Add…',id:`add-${title}`}),
      H('button',{onclick:()=>{const el=card.querySelector(`#add-${title}`); if(el.value.trim()){arr.push(el.value.trim());el.value='';draw();}}},'Add')
    ]);
    card.appendChild(list); card.appendChild(add); return card;
  }

  async function settingsPage() {
    app.innerHTML='';
    const nav = H('nav',{},[
      H('button',{onclick:settingsPage},'Settings'),
      H('button',{class:'ghost',onclick:logout},'Logout')
    ]);
    app.appendChild(nav);

    // fetch protected configs
    const [enums, imap, scrape] = await Promise.all([
      getJSON('/conf/enums'), getJSON('/settings/imap'), getJSON('/settings/scrape')
    ]);

    // Enums
    const countries=[...(enums.countries||[])], mccmnc=[...(enums.mccmnc||[])],
          vendors=[...(enums.vendors||[])], tags=[...(enums.tags||[])];
    const enumsCard = H('div',{class:'card'},[
      H('h2',{},'Dropdown Enums'),
      H('div',{class:'small'},'Manage values for dropdowns across the app.'),
      listEditor('Countries', countries),
      listEditor('MCCMNC', mccmnc),
      listEditor('Vendors', vendors),
      listEditor('Tags', tags),
      H('div',{class:'row'},[ H('button',{onclick:async()=>{ await putJSON('/conf/enums',{countries,mccmnc,vendors,tags}); alert('Enums saved'); }},'Save Enums') ])
    ]);

    // IMAP
    const im = imap;
    const imCard = H('div',{class:'card'},[
      H('h2',{},'IMAP Settings'),
      H('div',{class:'grid2'},[
        H('div',{},[
          H('div',{class:'row'},[H('label',{},'Host'), H('input',{type:'text',value:im.host||'',oninput:e=>im.host=e.target.value})]),
          H('div',{class:'row'},[H('label',{},'Port'), H('input',{type:'number',value:im.port??993,oninput:e=>im.port=+e.target.value})]),
          H('div',{class:'row'},[H('label',{},'Username'), H('input',{type:'text',value:im.username||'',oninput:e=>im.username=e.target.value})]),
          H('div',{class:'row'},[H('label',{},'Password'), H('input',{type:'password',value:im.password||'',oninput:e=>im.password=e.target.value})]),
        ]),
        H('div',{},[
          H('div',{class:'row'},[H('label',{},'Folder'), H('input',{type:'text',value:im.folder||'INBOX',oninput:e=>im.folder=e.target.value})]),
          H('div',{class:'row'},[H('label',{},'SSL'), H('input',{type:'checkbox', ...(im.ssl?{checked:true}:{}) ,onchange:e=>im.ssl=e.target.checked})]),
          H('div',{class:'row'},[H('label',{},'Enabled'), H('input',{type:'checkbox', ...(im.enabled?{checked:true}:{}) ,onchange:e=>im.enabled=e.target.checked})]),
        ])
      ]),
      H('div',{class:'row'},[
        H('button',{onclick:async()=>{ await putJSON('/settings/imap', im); alert('IMAP saved'); }},'Save IMAP'),
        H('button',{class:'ghost',onclick:async()=>{ try{ const r=await postJSON('/settings/imap/test',{}); alert(r.ok?'IMAP OK':'IMAP failed'); }catch(e){ alert('IMAP failed: '+e.message); } }},'Test IMAP')
      ])
    ]);

    // Scrape
    const sc = scrape;
    function arrEditor(title, arr){
      const c=H('div',{class:'card'},[H('h3',{},title)]), l=H('div'); const draw=()=>{l.innerHTML=''; arr.forEach((v,i)=>l.appendChild(H('div',{class:'row'},[
        H('input',{type:'text',value:v,oninput:e=>arr[i]=e.target.value}),
        H('button',{onclick:()=>{arr.splice(i,1);draw();}},'Remove')
      ])));}; draw();
      c.appendChild(l); c.appendChild(H('div',{class:'row'},[
        H('input',{type:'text',placeholder:'Add…',id:`add-${title}`}),
        H('button',{onclick:()=>{const el=c.querySelector(`#add-${title}`); if(el.value.trim()){arr.push(el.value.trim()); el.value=''; draw(); }}},'Add')
      ])); return c;
    }
    const scCard = H('div',{class:'card'},[
      H('h2',{},'Scraping Settings'),
      H('div',{class:'grid2'},[
        H('div',{},[
          H('div',{class:'row'},[H('label',{},'Enabled'), H('input',{type:'checkbox', ...(sc.enabled?{checked:true}:{}) ,onchange:e=>sc.enabled=e.target.checked})]),
          H('div',{class:'row'},[H('label',{},'Interval (min)'), H('input',{type:'number',value:sc.interval_minutes??30,oninput:e=>sc.interval_minutes=+e.target.value})]),
          H('div',{class:'row'},[H('label',{},'User-Agent'), H('input',{type:'text',value:sc.user_agent||'Mozilla/5.0',oninput:e=>sc.user_agent=e.target.value})]),
          H('div',{class:'row'},[H('label',{},'Max concurrency'), H('input',{type:'number',value:sc.max_concurrency??4,oninput:e=>sc.max_concurrency=+e.target.value})]),
        ]),
        H('div',{},[
          H('div',{class:'row'},[H('label',{},'Render JS'), H('input',{type:'checkbox', ...(sc.render_js?{checked:true}:{}) ,onchange:e=>sc.render_js=e.target.checked})]),
        ])
      ]),
      arrEditor('Start URLs', sc.start_urls = sc.start_urls || []),
      arrEditor('Allow Domains', sc.allow_domains = sc.allow_domains || []),
      arrEditor('Block Domains', sc.block_domains = sc.block_domains || []),
      H('div',{class:'row'},[ H('button',{onclick:async()=>{ await putJSON('/settings/scrape', sc); alert('Scrape settings saved'); }},'Save Scrape') ])
    ]);

    app.appendChild(enumsCard);
    app.appendChild(imCard);
    app.appendChild(scCard);
  }

  async function tryMe() {
    const res = await fetch(`${API}/users/me`, { headers: tk? {Authorization:'Bearer '+tk} : {} });
    if (res.ok) { await settingsPage(); return true; }
    return false;
  }

  async function doLogin(u,p) {
    const r = await fetch(`${API}/users/login`, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({username:u, password:p}) });
    if (!r.ok) { alert('Login failed'); return; }
    const j = await r.json();
    tk = j.access_token; localStorage.setItem('tk', tk);
    await settingsPage();
  }

  function loginScreen() {
    app.innerHTML='';
    const u = H('input',{type:'text',placeholder:'Username',value:'admin'});
    const p = H('input',{type:'password',placeholder:'Password',value:'admin123'});
    const btn = H('button',{onclick:()=>doLogin(u.value,p.value)},'Login');
    const card = H('div',{class:'card'},[H('h2',{},'Login'), u, p, btn]);
    app.appendChild(card);
  }

  (async () => { if (!(await tryMe())) loginScreen(); })();
})();
JS

# ---------- Dockerfiles ----------
cat > "$API_DF" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" pydantic "python-jose[cryptography]" passlib "bcrypt"
# pin to avoid bcrypt __about__ issue
RUN pip install --no-cache-dir --upgrade --force-reinstall "passlib[bcrypt]==1.7.4" "bcrypt==3.2.2"
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

cat > "$WEB_DF" <<'DOCKER'
FROM nginx:alpine
COPY web/public /usr/share/nginx/html
DOCKER

# ---------- docker-compose.yml ----------
cat > "$COMPOSE" <<'YML'
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
      DB_URL: postgresql://postgres:postgres@postgres:5432/smsdb
      SECRET_KEY: dev-change-me
      ACCESS_TOKEN_EXPIRE_MINUTES: "1440"
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
YML

echo -e "${Y}• Rebuilding & starting…${N}"
docker compose -f "$COMPOSE" up -d --build

sleep 2
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}• Probing (expect 204 on OPTIONS, 200 on login; 401 on protected GET without token)…${N}"
curl -i -s -X OPTIONS "http://${IP}:8010/users/login" | sed -n '1,10p'
echo
# protected endpoints should be 401 without token:
curl -i -s "http://${IP}:8010/conf/enums" | sed -n '1,5p'
echo
# login to get token
TOKEN=$(curl -s -X POST "http://${IP}:8010/users/login" -H "Content-Type: application/json" --data '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" || true)
if [ -n "$TOKEN" ]; then
  echo -e "${G}✔ Got token. Testing protected endpoints with auth…${N}"
  curl -s -H "Authorization: Bearer $TOKEN" "http://${IP}:8010/conf/enums" | sed -n '1,60p'
else
  echo -e "${R}✖ Login failed in probe. Check 'docker compose logs api'.${N}"
fi

echo -e "${G}\n✔ Done. Open http://${IP}:5183 , hard-refresh, login (admin/admin123). Settings page renders forms and all endpoints are protected.${N}"
