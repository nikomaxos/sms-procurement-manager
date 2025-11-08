#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUT="$API/routers"
WEB="$ROOT/web/public"

DB_PY="$CORE/database.py"
MAIN_PY="$API/main.py"
KV_MODEL="$MODELS/kv.py"
CONF_PY="$ROUT/conf.py"
SETTINGS_PY="$ROUT/settings.py"
MAIN_JS="$WEB/main.js"
API_DF="$ROOT/api.Dockerfile"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/restore_settings_$TS"
mkdir -p "$BACK" "$CORE" "$MODELS" "$ROUT" "$WEB"
for f in "$DB_PY" "$MAIN_PY" "$KV_MODEL" "$CONF_PY" "$SETTINGS_PY" "$MAIN_JS" "$API_DF" "$COMPOSE"; do
  [ -f "$f" ] && cp -a "$f" "$BACK/" || true
done

touch "$API/__init__.py" "$CORE/__init__.py" "$MODELS/__init__.py" "$ROUT/__init__.py"

echo -e "${Y}• Writing core/database.py (engine/Base/Session/get_db)…${N}"
cat > "$DB_PY" <<'PY'
import os, re
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

echo -e "${Y}• Writing models/kv.py (JSON settings store)…${N}"
cat > "$KV_MODEL" <<'PY'
from sqlalchemy import Column, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.types import JSON
from app.core.database import Base

try:
    JSONType = JSONB
except Exception:
    JSONType = JSON  # fallback if not on Postgres

class KVSetting(Base):
    __tablename__ = "kv_settings"
    id = Column(Integer, primary_key=True)
    key = Column(String(128), nullable=False, unique=True)
    value = Column(JSONType, nullable=False, default={})
    __table_args__ = (UniqueConstraint('key', name='uq_kv_key'),)
PY

echo -e "${Y}• Writing routers/conf.py (enums GET/PUT)…${N}"
cat > "$CONF_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.models.kv import KVSetting

router = APIRouter(prefix="/conf", tags=["conf"])

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
    # payload like {"countries":[...], "mccmnc":[...], ...}
    for k in ENUM_KEYS:
        lst = payload.get(k, [])
        if not isinstance(lst, list):
            raise HTTPException(400, f"{k} must be a list")
        row = _get(db, f"enums.{k}")
        if row is None:
            row = KVSetting(key=f"enums.{k}", value=lst)
            db.add(row)
        else:
            row.value = lst
    db.commit()
    return {"ok": True}
PY

echo -e "${Y}• Writing routers/settings.py (imap/scrape GET/PUT + test)…${N}"
cat > "$SETTINGS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.models.kv import KVSetting
import ssl, imaplib

router = APIRouter(prefix="/settings", tags=["settings"])

def kv_get(db: Session, key: str, default):
    row = db.query(KVSetting).filter(KVSetting.key==key).one_or_none()
    return row.value if row else default

def kv_put(db: Session, key: str, value):
    row = db.query(KVSetting).filter(KVSetting.key==key).one_or_none()
    if row is None:
        row = KVSetting(key=key, value=value)
        db.add(row)
    else:
        row.value = value
    db.commit()

@router.get("/imap")
def get_imap(db: Session = Depends(get_db)):
    return kv_get(db, "imap", {
        "host": "", "port": 993, "username": "", "password": "",
        "ssl": True, "folder": "INBOX", "enabled": False
    })

@router.put("/imap")
def put_imap(cfg: dict, db: Session = Depends(get_db)):
    # minimal validation
    if not isinstance(cfg, dict): raise HTTPException(400, "Invalid IMAP config")
    cfg.setdefault("port", 993); cfg.setdefault("ssl", True)
    cfg.setdefault("folder","INBOX"); cfg.setdefault("enabled", False)
    kv_put(db, "imap", cfg)
    return {"ok": True}

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
                M.login(user, pwd)
                typ, _ = M.select(cfg.get("folder","INBOX"))
                return {"ok": typ=="OK"}
        else:
            with imaplib.IMAP4(host, port) as M:
                M.login(user, pwd)
                typ, _ = M.select(cfg.get("folder","INBOX"))
                return {"ok": typ=="OK"}
    except Exception as e:
        raise HTTPException(400, f"IMAP connect failed: {e}")

@router.get("/scrape")
def get_scrape(db: Session = Depends(get_db)):
    return kv_get(db, "scrape", {
        "enabled": False,
        "interval_minutes": 30,
        "user_agent": "Mozilla/5.0",
        "max_concurrency": 4,
        "start_urls": [],
        "allow_domains": [],
        "block_domains": [],
        "render_js": False
    })

@router.put("/scrape")
def put_scrape(cfg: dict, db: Session = Depends(get_db)):
    if not isinstance(cfg, dict): raise HTTPException(400, "Invalid scrape config")
    kv_put(db, "scrape", cfg)
    return {"ok": True}
PY

echo -e "${Y}• Ensuring main.py wires routers + creates tables + CORS…${N}"
cat > "$MAIN_PY" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.core.database import Base, engine
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router

app = FastAPI(title="SMS Procurement Manager API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # dev
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
def health(): return {"ok": True}

# create tables
Base.metadata.create_all(bind=engine)

# routers
app.include_router(conf_router)
app.include_router(settings_router)
PY

# Keep bcrypt/passlib pin (critical for login)
if ! grep -q 'passlib\[bcrypt\]==1.7.4' "$API_DF" 2>/dev/null; then
  echo -e "${Y}• Appending bcrypt/passlib pin in api.Dockerfile…${N}"
  cat >> "$API_DF" <<'DOCKER'

# --- bcrypt/passlib pin to avoid backend version mismatch ---
RUN pip install --no-cache-dir --upgrade --force-reinstall \
    "passlib[bcrypt]==1.7.4" "bcrypt==3.2.2"
# ------------------------------------------------------------
DOCKER
fi

echo -e "${Y}• Updating web/public/main.js Settings UI…${N}"
cat > "$MAIN_JS" <<'JS'
/* Minimal SPA harness (keeps existing login token behavior) */
(() => {
  const API = (window.API_BASE || (location.origin.replace(':5183', ':8010')));
  let tk = localStorage.getItem('tk') || '';

  async function authFetch(url, opts = {}) {
    opts.headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
    if (tk) opts.headers['Authorization'] = 'Bearer ' + tk;
    const res = await fetch(url, opts);
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : res.text();
  }

  async function postJSON(url, body) {
    return authFetch(url, { method:'POST', body: JSON.stringify(body) });
  }
  async function putJSON(url, body) {
    return authFetch(url, { method:'PUT', body: JSON.stringify(body) });
  }
  async function getJSON(url) {
    return authFetch(url, { method:'GET' });
  }

  // UI helpers
  const app = document.getElementById('app') || document.body;
  const H = (tag, attrs={}, kids=[]) => {
    const el = document.createElement(tag);
    for (const [k,v] of Object.entries(attrs)) {
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (v !== null && v !== undefined) el.setAttribute(k, v);
    }
    for (const kid of (Array.isArray(kids) ? kids : [kids])) {
      if (kid == null) continue;
      if (kid instanceof Node) el.appendChild(kid); else el.appendChild(document.createTextNode(String(kid)));
    }
    return el;
  };

  const styles = document.getElementById('app-styles') || H('style', { id:'app-styles' }, `
:root { --bg:#1b1a19; --card:#242321; --ink:#f3e9dc; --muted:#bfae99; --accent:#d49a6a; --accent2:#8fb996; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.4 system-ui, Segoe UI, Roboto, sans-serif; }
nav { display:flex; gap:8px; padding:10px 12px; position:sticky; top:0; background:linear-gradient(180deg, rgba(27,26,25,.95), rgba(27,26,25,.75)); backdrop-filter: blur(6px); }
button { background:var(--accent); color:#111; border:0; padding:8px 12px; border-radius:10px; cursor:pointer; }
button.ghost { background:transparent; color:var(--ink); border:1px solid var(--muted); }
.card { background:var(--card); border:1px solid #333; border-radius:14px; padding:12px; margin:12px 12px 0; }
.grid2 { display:grid; grid-template-columns: 1fr 1fr; gap:12px; }
.row { display:flex; gap:8px; align-items:center; margin:6px 0; }
.row input[type=text], .row input[type=number], .row input[type=password] { flex:1; padding:6px 8px; border-radius:8px; border:1px solid #444; background:#151513; color:var(--ink); }
.tagrow { display:flex; gap:6px; margin:4px 0; }
.badge { padding:4px 8px; border-radius:999px; background:#2f2e2b; border:1px solid #3e3c38; color:var(--muted); }
.small { font-size:12px; color:var(--muted); }
hr { border:0; border-top:1px solid #3a3834; margin:10px 0; }
  `);
  document.head.appendChild(styles);

  function listEditor(title, items, onAdd, onDel) {
    const wrap = H('div', { class:'card' }, [H('h3', {}, title)]);
    const list = H('div');
    function redraw() {
      list.innerHTML = '';
      items.forEach((v,i) => {
        list.appendChild(
          H('div', { class:'row' }, [
            H('input', { type:'text', value:v, oninput: e=> items[i]=e.target.value }),
            H('button', { onclick: () => { items.splice(i,1); redraw(); } }, 'Remove')
          ])
        );
      });
    }
    redraw();
    wrap.appendChild(list);
    wrap.appendChild(H('div', { class:'row' }, [
      H('input', { type:'text', placeholder:'Add new…', id:`add-${title}` }),
      H('button', { onclick: () => {
        const inp = wrap.querySelector(`#add-${title}`);
        if (inp.value.trim()) { items.push(inp.value.trim()); inp.value=''; redraw(); onAdd && onAdd(); }
      } }, 'Add')
    ]));
    return wrap;
  }

  async function viewSettings() {
    app.innerHTML = '';
    const panel = H('div');

    // fetch all
    const [enums, imap, scrape] = await Promise.all([
      getJSON(`${API}/conf/enums`),
      getJSON(`${API}/settings/imap`),
      getJSON(`${API}/settings/scrape`),
    ]);

    // Enums section (compact)
    const enumsCard = H('div', { class:'card' }, [
      H('h2', {}, 'Dropdown Enums'),
      H('div', { class:'small' }, 'Manage values shown in dropdowns across the app.')
    ]);

    const countries = [...(enums.countries||[])];
    const mccmnc = [...(enums.mccmnc||[])];
    const vendors = [...(enums.vendors||[])];
    const tags = [...(enums.tags||[])];

    enumsCard.appendChild(listEditor('Countries', countries));
    enumsCard.appendChild(listEditor('MCCMNC', mccmnc));
    enumsCard.appendChild(listEditor('Vendors', vendors));
    enumsCard.appendChild(listEditor('Tags', tags));
    enumsCard.appendChild(H('div', { class:'row' }, [
      H('button', { onclick: async() => {
        await authFetch(`${API}/conf/enums`, { method:'PUT', body: JSON.stringify({ countries, mccmnc, vendors, tags })});
        alert('Enums saved');
      }}, 'Save Enums')
    ]));

    // IMAP section
    const imapCard = H('div', { class:'card' }, [
      H('h2', {}, 'IMAP Settings'),
      H('div', { class:'grid2' }, [
        H('div', {}, [
          H('div', { class:'row' }, [H('label', {}, 'Host'), H('input', { type:'text', value: imap.host || '', oninput: e=> imap.host=e.target.value })]),
          H('div', { class:'row' }, [H('label', {}, 'Port'), H('input', { type:'number', value: imap.port ?? 993, oninput: e=> imap.port=+e.target.value })]),
          H('div', { class:'row' }, [H('label', {}, 'Username'), H('input', { type:'text', value: imap.username || '', oninput: e=> imap.username=e.target.value })]),
          H('div', { class:'row' }, [H('label', {}, 'Password'), H('input', { type:'password', value: imap.password || '', oninput: e=> imap.password=e.target.value })]),
        ]),
        H('div', {}, [
          H('div', { class:'row' }, [H('label', {}, 'Folder'), H('input', { type:'text', value: imap.folder || 'INBOX', oninput: e=> imap.folder=e.target.value })]),
          H('div', { class:'row' }, [
            H('label', {}, 'SSL'),
            H('input', { type:'checkbox', ...(imap.ssl?{checked:true}:{}) , onchange: e=> imap.ssl = e.target.checked })
          ]),
          H('div', { class:'row' }, [
            H('label', {}, 'Enabled'),
            H('input', { type:'checkbox', ...(imap.enabled?{checked:true}:{}) , onchange: e=> imap.enabled = e.target.checked })
          ]),
        ])
      ]),
      H('div', { class:'row' }, [
        H('button', { onclick: async()=>{ await putJSON(`${API}/settings/imap`, imap); alert('IMAP saved'); } }, 'Save IMAP'),
        H('button', { class:'ghost', onclick: async()=>{ try{ const r=await postJSON(`${API}/settings/imap/test`,{}); alert(r.ok?'IMAP OK':'IMAP failed'); } catch(e){ alert('IMAP failed: '+e.message);} } }, 'Test IMAP')
      ])
    ]);

    // Scrape section
    const sc = scrape;
    const scrapeCard = H('div', { class:'card' }, [
      H('h2', {}, 'Scraping Settings'),
      H('div', { class:'grid2' }, [
        H('div', {}, [
          H('div', { class:'row' }, [H('label', {}, 'Enabled'), H('input', { type:'checkbox', ...(sc.enabled?{checked:true}:{}) , onchange: e=> sc.enabled = e.target.checked })]),
          H('div', { class:'row' }, [H('label', {}, 'Interval (min)'), H('input', { type:'number', value: sc.interval_minutes ?? 30, oninput:e=> sc.interval_minutes=+e.target.value })]),
          H('div', { class:'row' }, [H('label', {}, 'User-Agent'), H('input', { type:'text', value: sc.user_agent || 'Mozilla/5.0', oninput:e=> sc.user_agent=e.target.value })]),
          H('div', { class:'row' }, [H('label', {}, 'Max concurrency'), H('input', { type:'number', value: sc.max_concurrency ?? 4, oninput:e=> sc.max_concurrency=+e.target.value })]),
        ]),
        H('div', {}, [
          H('div', { class:'row' }, [H('label', {}, 'Render JS'), H('input', { type:'checkbox', ...(sc.render_js?{checked:true}:{}) , onchange: e=> sc.render_js = e.target.checked })]),
        ])
      ]),
    ]);

    function arrayEditor(title, arr) {
      const card = H('div', { class:'card' }, [H('h3',{},title)]);
      const list = H('div');
      function redraw() {
        list.innerHTML='';
        arr.forEach((v,i) => list.appendChild(
          H('div',{class:'row'},[
            H('input',{type:'text', value:v, oninput:e=>arr[i]=e.target.value}),
            H('button',{onclick:()=>{arr.splice(i,1); redraw();}},'Remove')
          ])
        ));
      }
      redraw();
      const add = H('div',{class:'row'},[
        H('input',{type:'text', placeholder:'Add…', id:`add-${title}`}),
        H('button',{onclick:()=>{const inp=card.querySelector(`#add-${title}`); if(inp.value.trim()){arr.push(inp.value.trim()); inp.value=''; redraw();}}},'Add')
      ]);
      card.appendChild(list); card.appendChild(add);
      return card;
    }

    scrapeCard.appendChild(arrayEditor('Start URLs', sc.start_urls = sc.start_urls || []));
    scrapeCard.appendChild(arrayEditor('Allow Domains', sc.allow_domains = sc.allow_domains || []));
    scrapeCard.appendChild(arrayEditor('Block Domains', sc.block_domains = sc.block_domains || []));
    scrapeCard.appendChild(H('div',{class:'row'},[
      H('button',{onclick:async()=>{ await putJSON(`${API}/settings/scrape`, sc); alert('Scrape settings saved'); }},'Save Scrape')
    ]));

    // Render page
    const nav = H('nav', {}, [
      H('button', { onclick: viewSettings }, 'Settings'),
      H('span',{class:'badge'}, 'Logged in')
    ]);
    app.appendChild(nav);
    panel.appendChild(enumsCard);
    panel.appendChild(imapCard);
    panel.appendChild(scrapeCard);
    app.appendChild(panel);
  }

  // If no token, show a simple login
  async function doLogin(u,p) {
    const res = await fetch(`${API}/users/login`, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({username:u, password:p})
    });
    if(!res.ok){ alert('Login failed'); return; }
    const j = await res.json();
    tk = j.access_token; localStorage.setItem('tk', tk);
    await viewSettings();
  }

  function loginScreen() {
    app.innerHTML='';
    const u = H('input',{type:'text', placeholder:'Username', value:'admin'});
    const p = H('input',{type:'password', placeholder:'Password', value:'admin123'});
    const btn = H('button',{onclick:()=>doLogin(u.value,p.value)},'Login');
    const card = H('div',{class:'card'},[H('h2',{},'Login'),u,p,btn]);
    app.appendChild(card);
  }

  // bootstrap
  (async () => {
    if (tk) { try { await viewSettings(); return; } catch(_){} }
    loginScreen();
  })();
})();
JS

echo -e "${Y}• Rebuilding API (no cache) and starting…${N}"
docker compose -f "$COMPOSE" build --no-cache api
docker compose -f "$COMPOSE" up -d api web

# Give API a breath, then probe
sleep 2
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n• Probing endpoints…${N}"
curl -s "http://${IP}:8010/conf/enums" | sed -n '1,40p'
curl -s "http://${IP}:8010/settings/imap" | sed -n '1,40p'
curl -s "http://${IP}:8010/settings/scrape" | sed -n '1,40p'

echo -e "${G}\n✔ Done. Hard-refresh the UI (Ctrl/Cmd+Shift+R) → Settings now shows full forms with Save buttons.${N}"
