#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
WEB="$ROOT/web/public"
COMPOSE="$ROOT/docker-compose.yml"
BACK="$ROOT/.backups"
LAST="$BACK/.last_backup"

usage(){ echo "Usage:
  $(basename "$0")                 # apply updates (backs up first)
  $(basename "$0") --restore last
  $(basename "$0") --restore 2025-11-05_13-42-11
"; }

# ---------- Restore mode ----------
if [[ "${1-}" == "--restore" ]]; then
  ts="${2-}"
  [[ -z "$ts" ]] && { usage; exit 1; }
  [[ "$ts" == "last" ]] && { [[ -f "$LAST" ]] || { echo -e "${R}No last backup${N}"; exit 1; }; ts="$(cat "$LAST")"; }
  tgz="$BACK/$ts.tar.gz"
  [[ -f "$tgz" ]] || { echo -e "${R}Backup not found:${N} $tgz"; exit 1; }
  echo -e "${Y}🧺 Restoring backup $ts ...${N}"
  tar -xzf "$tgz" -C /
  echo -e "${Y}🔁 Rebuilding & restarting...${N}"
  docker compose -f "$COMPOSE" down --remove-orphans || true
  docker compose -f "$COMPOSE" build
  docker compose -f "$COMPOSE" up -d
  echo -e "${G}✔ Restored. UI unchanged from that snapshot.${N}"
  exit 0
fi

# ---------- Backup ----------
echo -e "${Y}🗂 Creating backup...${N}"
mkdir -p "$BACK"
ts="$(date +%F_%H-%M-%S)"
tgz="$BACK/$ts.tar.gz"
tar -czf "$tgz" \
  "$COMPOSE" \
  "$ROOT/api.Dockerfile" \
  "$ROOT/web.Dockerfile" \
  -C "$ROOT" api/app web/public 2>/dev/null || true
echo "$ts" > "$LAST"
echo -e "${G}✔ Backup saved:${N} $tgz"
echo -e "${Y}Tip:${N} $(basename "$0") --restore last   # instant undo"

echo -e "${Y}📦 Applying compact Settings + IMAP + UI tweaks...${N}"
mkdir -p "$CORE" "$ROUT" "$WEB"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUT/__init__.py"

# ---------- Settings router (IMAP) ----------
cat > "$ROUT/settings.py" <<'PY'
from typing import Dict, Any
from fastapi import APIRouter, Depends, Body, HTTPException
from sqlalchemy import text
import json, imaplib, ssl
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/settings", tags=["Settings"])

def _ensure_table():
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );"""))

def _get(key:str, default:Dict[str,Any]):
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key=:k"), dict(k=key)).fetchone()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES (:k,:v)"),
                      dict(k=key, v=json.dumps(default)))
            return default
        val = row.value
        if isinstance(val, str):
            try: val = json.loads(val)
            except Exception: val = default
        return {**default, **(val or {})}

def _set(key:str, value:Dict[str,Any]):
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value,updated_at) VALUES(:k,:v,now()) "
                       "ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()"),
                  dict(k=key, v=json.dumps(value)))

DEFAULT_IMAP = {"host":"", "port":993, "username":"", "password":"", "use_ssl":True, "folders":[]}

@router.get("/imap")
def read_imap(current=Depends(get_current_user)):
    return _get("imap", DEFAULT_IMAP)

@router.put("/imap")
def write_imap(payload: Dict[str,Any] = Body(...), current=Depends(get_current_user)):
    cur = _get("imap", DEFAULT_IMAP)
    cur.update({k: payload.get(k, cur.get(k)) for k in DEFAULT_IMAP.keys()})
    _set("imap", cur)
    return cur

@router.post("/imap/test")
def test_imap(payload: Dict[str,Any] = Body(None), current=Depends(get_current_user)):
    cfg = _get("imap", DEFAULT_IMAP)
    if payload: cfg.update({k: payload.get(k, cfg.get(k)) for k in DEFAULT_IMAP.keys()})
    host, port, user, pwd, use_ssl = cfg["host"], int(cfg["port"]), cfg["username"], cfg["password"], bool(cfg["use_ssl"])
    if not host or not user:
        raise HTTPException(400, "Host and Username are required")
    try:
        if use_ssl: M = imaplib.IMAP4_SSL(host, port)
        else:
            M = imaplib.IMAP4(host, port)
            M.starttls(ssl_context=ssl.create_default_context())
        typ, _ = M.login(user, pwd)
        if typ != "OK": raise HTTPException(401, "Login failed")
        typ, boxes = M.list()
        M.logout()
        folders = []
        if typ == "OK" and boxes:
            for line in boxes:
                name = line.decode(errors="ignore").split(' "/" ',1)[-1].strip().strip('"')
                if name: folders.append(name)
        return {"ok": True, "folders": folders[:100]}
    except imaplib.IMAP4.error as e:
        raise HTTPException(401, f"IMAP error: {e}")
    except Exception as e:
        raise HTTPException(500, f"IMAP connect failed: {e}")
PY

# ---------- Ensure a conf router exists (GET/PUT /conf/enums) ----------
if [[ ! -f "$ROUT/conf.py" ]]; then
  cat > "$ROUT/conf.py" <<'PY'
from typing import Dict, List
from fastapi import APIRouter, Depends, Body
from sqlalchemy import text
import json
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/conf", tags=["Conf"])

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct","SS7","SIM","Local Bypass"],
    "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
    "registration_required": ["Yes","No"]
}

def _ensure_table():
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );"""))

def _get_json(key:str, default):
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key=:k"), dict(k=key)).fetchone()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES (:k,:v)"),
                      dict(k=key, v=json.dumps(default)))
            return default
        v = row.value
        if isinstance(v, str):
            try: v = json.loads(v)
            except Exception: v = default
        return v or default

def _set_json(key:str, value):
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value,updated_at) VALUES(:k,:v,now()) "
                       "ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()"),
                  dict(k=key, v=json.dumps(value)))

@router.get("/enums")
def get_enums(current=Depends(get_current_user)):
    return _get_json("enums", DEFAULT_ENUMS)

@router.put("/enums")
def put_enums(payload: dict = Body(...), current=Depends(get_current_user)):
    cur = _get_json("enums", DEFAULT_ENUMS)
    cur.update(payload or {})
    _set_json("enums", cur)
    return cur
PY
fi

# ---------- Patch main.py safely (CORS + include routers) ----------
env API="$API" python3 - <<'PY'
import os, re
from pathlib import Path

api_dir = Path(os.environ['API'])
p = api_dir / 'main.py'
s = p.read_text(encoding='utf-8')

# Import CORS if missing
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

# Add middleware (allow-all, no credentials)
if "app.add_middleware(CORSMiddleware" not in s:
    s = re.sub(r"(app\s*=\s*FastAPI\([^\)]*\))",
               r"\1\napp.add_middleware(CORSMiddleware, allow_origins=['*'], allow_credentials=False, allow_methods=['*'], allow_headers=['*'])",
               s, count=1, flags=re.S)

# Ensure routers imports
if "from app.routers.settings import router as settings" not in s:
    s = s.replace("from app.routers.metrics import router as metrics",
                  "from app.routers.metrics import router as metrics\nfrom app.routers.settings import router as settings")
if "from app.routers.conf import router as conf" not in s:
    s = s.replace("from app.routers.metrics import router as metrics",
                  "from app.routers.metrics import router as metrics\nfrom app.routers.conf import router as conf")

# Ensure include_router calls
if "app.include_router(settings)" not in s:
    s = s.replace("app.include_router(metrics)", "app.include_router(metrics)\napp.include_router(settings)")
if "app.include_router(conf)" not in s:
    s = s.replace("app.include_router(metrics)", "app.include_router(metrics)\napp.include_router(conf)")

p.write_text(s, encoding='utf-8')
print("✓ main.py updated (CORS + routers)")
PY

# ---------- Warm palette + compact CSS ----------
cat > "$WEB/theme.css" <<'CSS'
:root{
  --bg-0:#f7efe6; --bg-1:#fff7ef; --bg-2:#fde9d8;
  --text-0:#2b1e12; --text-1:#4b2e16; --border:#e4c9ad;
  --primary:#b45309; --accent:#d97706;
  --ok:#16a34a; --info:#2563eb; --warn:#f59e0b; --danger:#dc2626;
  --shadow:0 6px 14px rgba(124,90,60,.12); --radius:12px;
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg-0);color:var(--text-0);font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial}
#app{padding:16px}
.header{position:sticky;top:0;z-index:20;background:linear-gradient(180deg,rgba(253,233,216,.95),rgba(247,239,230,.95));border-bottom:1px solid var(--border)}
.nav{display:flex;gap:10px;align-items:center;padding:10px 16px}
.nav .brand{font-weight:800;margin-right:auto}
.card{background:var(--bg-1);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);padding:12px;margin:10px 0}
.btn{border:none;border-radius:999px;color:#fff;background:var(--primary);padding:6px 10px;cursor:pointer;box-shadow:var(--shadow);font-size:14px}
.btn.green{background:var(--ok)} .btn.blue{background:var(--info)} .btn.yellow{background:var(--warn);color:#3b270e} .btn.red{background:var(--danger)}
input,select,textarea{background:#fff;color:var(--text-0);border:1px solid var(--border);border-radius:10px;padding:6px 8px;font-size:14px}
.table{width:100%;border:1px solid var(--border);background:#fff;border-radius:12px;overflow:hidden}
.table th,.table td{padding:8px;border-bottom:1px solid var(--border);text-align:left;font-size:14px}

/* Compact chips */
.pill-list{list-style:none;margin:6px 0;padding:0}
.pill-row{display:flex;gap:6px;align-items:center;margin:4px 0}
.pill{display:inline-block;padding:4px 8px;border-radius:999px;background:#fff;border:1px solid var(--border);font-size:13px}

/* Accordion for spatial economy */
details.accordion{border:1px solid var(--border);border-radius:10px;background:#fff;margin:8px 0}
details.accordion > summary{cursor:pointer;padding:8px 10px;font-weight:700;background:var(--bg-2);border-radius:10px}
details.accordion[open] > summary{border-bottom:1px solid var(--border);border-bottom-left-radius:0;border-bottom-right-radius:0}
.acc-body{padding:10px}
.grid-2{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.lbl{min-width:120px;font-weight:600}
.small-note{font-size:12px;opacity:.8}
CSS

# Ensure index.html links theme.css
if [[ -f "$WEB/index.html" ]]; then
  if ! grep -q 'theme.css' "$WEB/index.html"; then
    sed -i 's#</head>#  <link rel="stylesheet" href="theme.css"/>\n</head>#' "$WEB/index.html"
  fi
fi

# ---------- Patch Settings view in main.js (accordion + IMAP + per-category save) ----------
env WEB="$WEB" python3 - <<'PY'
import os, re
from pathlib import Path
web = Path(os.environ['WEB'])
js_path = web/'main.js'
js = js_path.read_text(encoding='utf-8')

# Replace/append viewSettings
pat = re.compile(r"async\s+function\s+viewSettings\s*\(\)\s*\{.*?\n\}", re.S)
replacement = r"""
async function viewSettings(){
  try{
    const enums = await authFetch(window.API_BASE+'/conf/enums');
    const state = JSON.parse(JSON.stringify(enums || {route_type:[], known_hops:[], registration_required:[]}));
    let imap = await authFetch(window.API_BASE+'/settings/imap').catch(()=>({host:"",port:993,username:"",password:"",use_ssl:true,folders:[]}));
    let imapFoldersCache = [];

    function listBlock(key, label){
      const add = el('input',{placeholder:'Add value',style:'width:160px'});
      const addBtn = el('button',{class:'btn green'},'Add');
      const saveBtn = el('button',{class:'btn blue'},'Save');
      const ul = el('ul',{class:'pill-list'});
      function render(){
        ul.innerHTML = '';
        (state[key]||[]).forEach((v,i)=>{
          const row = el('li',{class:'pill-row'},
            el('span',{class:'pill'}, v),
            el('button',{class:'btn yellow'},'Edit'),
            el('button',{class:'btn red'},'Del')
          );
          row.children[1].onclick = ()=>{ const nv=prompt('Edit value', v); if(nv && nv.trim() && nv!==v){ state[key][i]=nv.trim(); render(); }};
          row.children[2].onclick = ()=>{ state[key].splice(i,1); render(); };
          ul.append(row);
        });
      }
      addBtn.onclick = ()=>{ const v=add.value.trim(); if(v){ state[key]=state[key]||[]; state[key].push(v); add.value=''; render(); } };
      saveBtn.onclick = async ()=>{ const payload={}; payload[key]=state[key]; await authFetch(window.API_BASE+'/conf/enums',{method:'PUT',body:JSON.stringify(payload)}).then(()=>alert(label+' saved')).catch(e=>alert('Save failed: '+e.message)); };
      render();
      return el('div',{class:'card'}, el('div',{class:'row'}, el('span',{style:'font-weight:700'},label), add, addBtn, saveBtn), ul);
    }

    const drop = el('details',{class:'accordion'}, // collapsed by default to save space
      el('summary',{},'Drop Down Menus'),
      el('div',{class:'acc-body'},
        el('div',{class:'grid-2'},
          listBlock('route_type','Route type'),
          listBlock('known_hops','Known hops'),
          listBlock('registration_required','Registration required')
        ),
        el('div',{class:'row',style:'margin-top:6px'}, el('button',{class:'btn blue'},'Save All'))
      )
    );
    drop.querySelector('.btn.blue').onclick = async ()=>{
      await authFetch(window.API_BASE+'/conf/enums',{method:'PUT',body:JSON.stringify(state)}).then(()=>alert('All dropdowns saved')).catch(e=>alert('Save All failed: '+e.message));
    };

    // IMAP block
    function imapField(lbl, node){ return el('div',{class:'row'}, el('div',{class:'lbl'},lbl), node); }
    const host = el('input',{value:imap.host||'',placeholder:'imap.example.com'});
    const port = el('input',{value:String(imap.port??993),type:'number',min:'1',max:'65535',style:'width:110px'});
    const user = el('input',{value:imap.username||'',placeholder:'username'});
    const pass = el('input',{value:imap.password||'',type:'password',placeholder:'password'});
    const ssl  = el('input',{type:'checkbox'}); ssl.checked = !!imap.use_ssl;
    const folderWrap = el('div',{});
    function renderFolders(list){
      folderWrap.innerHTML=''; const grid=el('div',{class:'grid-2'});
      (list||[]).forEach(name=>{
        const cb=el('input',{type:'checkbox'}); cb.checked=(imap.folders||[]).includes(name);
        cb.onchange=()=>{ if(cb.checked){ if(!imap.folders.includes(name)) imap.folders.push(name); } else { imap.folders = imap.folders.filter(x=>x!==name); } };
        grid.append(el('label',{},cb,' ',name));
      });
      if(!list || !list.length) grid.append(el('div',{class:'small-note'},'No folders yet. Click "Fetch folders".'));
      folderWrap.append(grid);
    }
    renderFolders(imap.folders);
    const fetchBtn = el('button',{class:'btn yellow'},'Fetch folders');
    fetchBtn.onclick = async ()=>{
      const payload={host:host.value.trim(),port:Number(port.value||993),username:user.value.trim(),password:pass.value,use_ssl:ssl.checked};
      const res = await authFetch(window.API_BASE+'/settings/imap/test',{method:'POST',body:JSON.stringify(payload)}).catch(e=>{alert('IMAP test failed: '+e.message); return {folders:[]};});
      imapFoldersCache=res.folders||[]; renderFolders(imapFoldersCache);
    };
    const saveImap = el('button',{class:'btn blue'},'Save IMAP');
    saveImap.onclick = async ()=>{
      const body={host:host.value.trim(),port:Number(port.value||993),username:user.value.trim(),password:pass.value,use_ssl:ssl.checked,folders:imap.folders||[]};
      await authFetch(window.API_BASE+'/settings/imap',{method:'PUT',body:JSON.stringify(body)}).then(()=>alert('IMAP saved')).catch(e=>alert('Save IMAP failed: '+e.message));
    };
    const imapCard = el('details',{class:'accordion'},
      el('summary',{},'IMAP Settings'),
      el('div',{class:'acc-body'},
        el('div',{class:'grid-2'},
          el('div',{class:'card'},
            imapField('Host',host), imapField('Port',port), imapField('Username',user), imapField('Password',pass), imapField('Use SSL',ssl),
            el('div',{class:'row'}, fetchBtn, saveImap),
            el('div',{class:'small-note'},'Use "Fetch folders" to list mailboxes; tick which ones to monitor.')
          ),
          el('div',{class:'card'}, el('div',{class:'lbl'},'Folders to monitor'), folderWrap )
        )
      )
    );

    $('#app').innerHTML=''; $('#app').append(el('div',{}, drop, imapCard));
  }catch(e){ alert('Settings error: '+e.message); }
}
"""
if pat.search(js): js = pat.sub(replacement, js)
else: js = js + "\n" + replacement
js_path.write_text(js, encoding='utf-8')
print("✓ main.js Settings view updated")
PY

# ---------- Rebuild / restart ----------
echo -e "${Y}🔁 Restarting stack...${N}"
docker compose -f "$COMPOSE" down --remove-orphans || true
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# ---------- Health checks ----------
sleep 4
IP=$(hostname -I | awk '{print $1}')
OPENAPI="http://${IP}:8010/openapi.json"
if curl -sf "$OPENAPI" >/tmp/openapi.json; then
  echo -e "${G}✔ API up. Key paths:${N}"
  grep -oE '"/(conf|settings)/[^"]*"' /tmp/openapi.json | sed 's/"//g' | sort -u
else
  echo -e "${R}✖ API not reachable. API logs:${N}"
  docker logs "$(docker ps --format '{{.Names}}' | grep api)" --tail=120 || true
fi
echo -e "${G}✅ Done. UI: http://${IP}:5183  | Login: admin / admin123${N}"
echo -e "${Y}Undo at any time:${N} $(basename "$0") --restore last    (backups in $BACK)"
