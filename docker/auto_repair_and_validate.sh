#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ROOT="$HOME/sms-procurement-manager"
JS="$ROOT/web/public/main.js"
WEB="$ROOT/web/public"
API_DIR="$ROOT/api/app"
MAIN_PY="$API_DIR/main.py"
ROUTERS="$API_DIR/routers"
MIG="$API_DIR/migrations_domain.py"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${YELLOW}🧠 Auto-repair + validator started for SMS Procurement Manager${NC}"

mkdir -p "$WEB" "$ROUTERS"

# ------------------------------------------------------------
# 0) Ensure docker-compose.yml exists (api + web + postgres)
# ------------------------------------------------------------
if [[ ! -f "$COMPOSE" ]]; then
  echo -e "${YELLOW}Recreating docker-compose.yml...${NC}"
  cat > "$COMPOSE" <<'YAML'
version: "3.9"
services:
  postgres:
    image: postgres:15
    container_name: docker-postgres-1
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
    container_name: docker-api-1
    environment:
      - DB_URL=postgresql://postgres:postgres@postgres:5432/smsdb
    ports:
      - "8010:8000"
    depends_on: [postgres]
    networks: [stack]

  web:
    image: nginx:stable-alpine
    container_name: docker-web-1
    volumes:
      - ./web/public:/usr/share/nginx/html:ro
    ports:
      - "5183:80"
    networks: [stack]

networks:
  stack:

volumes:
  pgdata:
YAML
  echo -e "${GREEN}✔ docker-compose.yml created${NC}"
else
  echo -e "${GREEN}✔ docker-compose.yml present${NC}"
fi

# ------------------------------------------------------------
# 1) Ensure FastAPI CORS is permissive and /conf included
# ------------------------------------------------------------
if [[ -f "$MAIN_PY" ]]; then
  python3 - "$MAIN_PY" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

# Ensure app = FastAPI(...) exists
if "app = FastAPI(" not in s:
    s = "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware\napp = FastAPI()\n"+s

# Ensure CORS middleware with '*' and allow_credentials=False (Bearer used)
if "app.add_middleware(CORSMiddleware" not in s:
    s = s.replace("app = FastAPI(", "app = FastAPI(")
    s = re.sub(r"(app\s*=\s*FastAPI\(.*?\))", r"""\1
origins = ['*']
app.add_middleware(CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=['*'],
    allow_headers=['*']
)""", s, count=1, flags=re.S)

# Ensure /conf router is included
if "include_router(conf.router" not in s:
    if "from app.routers import conf" not in s:
        s = s.replace("from fastapi import FastAPI", "from fastapi import FastAPI\nfrom app.routers import conf")
    if "app.include_router(conf.router" not in s:
        # mount with tags prefix
        if "app = FastAPI(" in s:
            s = s.replace("app = FastAPI(", "app = FastAPI(")
        s = s.replace("app = FastAPI()", "app = FastAPI()\napp.include_router(conf.router, prefix='/conf', tags=['Settings'])")
        if "include_router(conf.router" not in s:
            s += "\napp.include_router(conf.router, prefix='/conf', tags=['Settings'])\n"

p.write_text(s, encoding="utf-8")
print("✓ main.py CORS + conf wired")
PY
else
  echo -e "${YELLOW}⚠ $MAIN_PY missing, skipping CORS patch${NC}"
fi

# ------------------------------------------------------------
# 2) Ensure routers/conf.py exists with GET/PUT /conf/enums
# ------------------------------------------------------------
CONF_PY="$ROUTERS/conf.py"
if [[ ! -f "$CONF_PY" ]]; then
  cat > "$CONF_PY" <<'PY'
from typing import Dict, List, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
import json
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct", "SS7", "SIM", "Local Bypass"],
    "known_hops": ["0-Hop", "1-Hop", "2-Hops", "N-Hops"],
    "registration_required": ["Yes", "No"],
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"]
}

def _ensure_table() -> None:
    ddl = """
    CREATE TABLE IF NOT EXISTS config_kv(
      key TEXT PRIMARY KEY,
      value JSONB NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    """
    with engine.begin() as c:
        c.execute(text(ddl))

def _coerce_dict(stored: Any) -> Dict[str, Any]:
    if stored is None:
        return {}
    if isinstance(stored, (bytes, bytearray)):
        stored = stored.decode("utf-8", errors="ignore")
    if isinstance(stored, str):
        try:
            return json.loads(stored)
        except Exception:
            return {}
    if isinstance(stored, dict):
        return stored
    return {}

@router.get("/enums")
def get_enums(user=Depends(get_current_user)):
    _ensure_table()
    with engine.begin() as c:
        r = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).scalar()
    merged = DEFAULT_ENUMS.copy()
    merged.update(_coerce_dict(r))
    return merged

@router.put("/enums")
def put_enums(payload: Dict[str, Any] = Body(...), user=Depends(get_current_user)):
    _ensure_table()
    for k in payload:
        if not isinstance(payload[k], list):
            raise HTTPException(status_code=400, detail=f"{k} must be a list")
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value) VALUES('enums', :v) ON CONFLICT(key) DO UPDATE SET value=:v, updated_at=now()"),
                  {"v": json.dumps(payload)})
    return {"ok": True}
PY
  echo -e "${GREEN}✔ routers/conf.py created${NC}"
else
  echo -e "${GREEN}✔ routers/conf.py present${NC}"
fi

# ------------------------------------------------------------
# 3) Normalize SQL DO $$ trigger block if present
# ------------------------------------------------------------
if [[ -f "$MIG" ]] && grep -q "DO \$\$ BEGIN" "$MIG"; then
  echo -e "${YELLOW}Normalizing DO $$ block...${NC}"
  sed -i '/DO \$\$ BEGIN/,/END \$\$/c\
DO $$ \
BEGIN \
  CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$ \
  BEGIN \
    NEW.updated_at = now(); \
    RETURN NEW; \
  END; \
  $$ LANGUAGE plpgsql; \
END $$;' "$MIG"
  echo -e "${GREEN}✔ SQL normalized${NC}"
else
  echo -e "${GREEN}✔ SQL OK${NC}"
fi

# ------------------------------------------------------------
# 4) JS: Try to repair; if still broken, replace with clean UI
# ------------------------------------------------------------
REPLACED=0
if [[ -f "$JS" ]]; then
  echo -e "${YELLOW}Repairing main.js...${NC}"
  cp -a "$JS" "$JS.bak.$(date +%s)"
  sed -i 's/function __ensureSettingsCSS() { (async/function __ensureSettingsCSS() {\n(async/g' "$JS" || true
  sed -i 's/function __ensureSettingsCSS();/function __ensureSettingsCSS() {/' "$JS" || true
  sed -i 's/(async (fn) {/(async () => {/' "$JS" || true
  sed -i 's/(async (fn) => {/(async () => {/' "$JS" || true
  # add missing closing brace if file lacks any top-level }
  if ! tail -n 1 "$JS" | grep -q '}'; then echo "}" >> "$JS"; fi

  # quick validation
  if command -v node >/dev/null 2>&1; then
    if ! node --check "$JS" >/dev/null 2>&1; then
      echo -e "${YELLOW}main.js still invalid → replacing with clean baseline UI...${NC}"
      REPLACED=1
    fi
  fi
else
  echo -e "${YELLOW}main.js missing → creating from scratch...${NC}"
  REPLACED=1
fi

if [[ "$REPLACED" -eq 1 ]]; then
  cat > "$JS" <<'JS'
/* Clean baseline UI for SMS Procurement Manager */
(() => {
  "use strict";
  const API_BASE = (window.localStorage.getItem('API_BASE')) || (window.location.origin.replace(':5183', ':8010'));
  let TOKEN = window.localStorage.getItem('TOKEN') || '';

  const $ = s => document.querySelector(s);
  const el = (t, attrs, ...kids) => {
    const n = document.createElement(t);
    if (attrs) for (const [k,v] of Object.entries(attrs)) {
      if (k === 'class') n.className = v;
      else if (k.startsWith('on') && typeof v === 'function') n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    for (const k of kids) n.append(k);
    return n;
  };
  const btn = (txt, kind, on) => el('button', {class:`btn ${kind||''}`, onclick:on}, txt);

  function header() {
    const h = el('div',{class:'topbar'},
      el('div',{class:'left'}, btn('Market trends','', ()=>viewTrends()),
                               btn('Offers','', ()=>viewOffers()),
                               btn('Suppliers','', ()=>viewSuppliers()),
                               btn('Countries','', ()=>viewCountries()),
                               btn('Networks','', ()=>viewNetworks()),
                               btn('Parsers','', ()=>viewParsers()),
                               btn('Settings','', ()=>viewSettings())),
      el('div',{class:'right'},
        el('span',{id:'login-status'}, TOKEN?'User: admin':'Not logged in'),
        TOKEN?btn('Logout','red',()=>{TOKEN='';localStorage.removeItem('TOKEN'); renderLogin();}):null
      )
    );
    return h;
  }

  async function authFetch(url, opt={}) {
    const o = Object.assign({headers:{}}, opt);
    if (!o.headers['Content-Type'] && !(o.body instanceof FormData)) o.headers['Content-Type']='application/json';
    if (TOKEN) o.headers['Authorization']='Bearer '+TOKEN;
    // CORS preflight friendly
    return fetch(url, o).then(async r=>{
      if (!r.ok) {
        const t = await r.text().catch(()=>r.statusText);
        throw new Error(r.status+' '+t);
      }
      const ct = r.headers.get('content-type')||'';
      if (ct.includes('application/json')) return r.json();
      return r.text();
    });
  }

  function renderLogin() {
    const app = $('#app'); app.innerHTML='';
    app.append(
      el('div',{class:'page'},
        el('h1',null,'Login'),
        el('div',{class:'card'},
          el('label',null,'API Base'),
          el('input',{id:'api_base', value:API_BASE, oninput:(e)=>localStorage.setItem('API_BASE', e.target.value)}),
          el('label',null,'Username'),
          el('input',{id:'u', value:'admin'}),
          el('label',null,'Password'),
          el('input',{id:'p', type:'password', value:'admin123', onkeydown:(e)=>{if(e.key==='Enter') doLogin();}}),
          btn('Login','green', ()=>doLogin())
        )
      )
    );
  }

  async function doLogin() {
    try {
      const form = new URLSearchParams();
      form.set('username', $('#u').value);
      form.set('password', $('#p').value);
      const tok = await fetch((localStorage.getItem('API_BASE')||API_BASE)+'/users/login',{
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:form
      }).then(r=>r.json());
      if (!tok.access_token) throw new Error('No token');
      TOKEN = tok.access_token; localStorage.setItem('TOKEN', TOKEN);
      render();
    } catch(e) {
      alert('Login failed: '+e.message);
    }
  }

  function go(fn){ Promise.resolve().then(fn).catch(e=>alert(e.message)); }

  // --- Views (minimal, working) ---
  function viewTrends() {
    go(async ()=>{
      const app=$('#app'); app.innerHTML='';
      app.append(el('div',{class:'page'}, el('h1',null,'Market trends'),
        el('div',{class:'card'}, el('label',null,'Date'),
          el('input',{id:'trend_date', type:'date', value:new Date().toISOString().slice(0,10), onchange:()=>viewTrends()}),
          el('div',{id:'trend_out'}, 'Loading...')
        )));
      const d = $('#trend_date').value;
      const data = await authFetch((localStorage.getItem('API_BASE')||API_BASE)+`/metrics/trends?d=${d}`);
      $('#trend_out').textContent = JSON.stringify(data);
    });
  }

  async function listSimple(path, title){
    const app=$('#app'); app.innerHTML='';
    app.append(el('div',{class:'page'}, el('h1',null,title),
      el('div',{class:'card'}, el('div',{id:'listout'}, 'Loading...'))));
    const rows = await authFetch((localStorage.getItem('API_BASE')||API_BASE)+path);
    $('#listout').textContent = JSON.stringify(rows);
  }
  const viewOffers   = ()=>listSimple('/offers/?limit=50&offset=0','Offers');
  const viewSuppliers= ()=>listSimple('/suppliers/','Suppliers');
  const viewCountries= ()=>listSimple('/countries/','Countries');
  const viewNetworks = ()=>listSimple('/networks/','Networks');
  const viewParsers  = ()=>listSimple('/parsers/','Parsers');

  function viewSettings(){
    go(async ()=>{
      const app=$('#app'); app.innerHTML='';
      app.append(el('div',{class:'page'}, el('h1',null,'Settings'),
        el('div',{class:'card'}, el('h2',null,'Drop Down Menus'),
          el('div',{id:'ddm'}, 'Loading...'),
          btn('Save All','blue', async ()=>{
            const payload = collectEnums();
            await authFetch((localStorage.getItem('API_BASE')||API_BASE)+'/conf/enums',{
              method:'PUT', body:JSON.stringify(payload)
            });
            alert('Saved');
          })
        )
      ));
      const enums = await authFetch((localStorage.getItem('API_BASE')||API_BASE)+'/conf/enums');
      renderEnums(enums);
    });
  }

  function renderEnums(enums){
    const wrap=el('div',{class:'lists-wrap'});
    wrap.append(enumList('route_type','Route Type', enums.route_type||[]));
    wrap.append(enumList('known_hops','Known Hops', enums.known_hops||[]));
    wrap.append(enumList('registration_required','Registration Required', enums.registration_required||[]));
    $('#ddm').replaceChildren(wrap);
  }

  function enumList(key, label, arr){
    const box=el('div',{class:'fieldset'});
    box.append(el('label',{class:'lbl'}, label));
    const ul=el('ul',{class:'pill-list'});
    for (const v of arr){
      ul.append(el('li',{class:'pill-row'}, el('span',{class:'pill'}, v),
        btn('✎','yellow',()=>{
          const nv = prompt('Edit value', v);
          if(nv && nv.trim()){ updateEnum(key, v, nv.trim()); }
        }),
        btn('🗑','red',()=>{ removeEnum(key, v); })
      ));
    }
    ul.append(el('li',null, el('input',{placeholder:'Add new...', onkeydown:(e)=>{
      if (e.key==='Enter' && e.target.value.trim()){
        addEnum(key, e.target.value.trim()); e.target.value='';
      }
    }})));
    box.append(ul);
    return box;
  }

  function currentEnumsFromDOM(){
    const out={route_type:[], known_hops:[], registration_required:[]};
    document.querySelectorAll('.fieldset').forEach(fs=>{
      const lbl = fs.querySelector('.lbl').textContent;
      const list = Array.from(fs.querySelectorAll('.pill')).map(x=>x.textContent);
      if (lbl.includes('Route Type')) out.route_type = list;
      if (lbl.includes('Known Hops')) out.known_hops = list;
      if (lbl.includes('Registration')) out.registration_required = list;
    });
    return out;
  }
  function collectEnums(){ return currentEnumsFromDOM(); }
  function updateEnum(k, oldv, nv){
    const fs = Array.from(document.querySelectorAll('.fieldset')).find(x=>x.querySelector('.lbl').textContent.includes(k.replace('_',' ').replace(/\b\w/g,c=>c.toUpperCase())));
    const pills = fs.querySelectorAll('.pill');
    for(const p of pills){ if(p.textContent===oldv){ p.textContent=nv; break; } }
  }
  function removeEnum(k, v){
    const ps = Array.from(document.querySelectorAll('.pill')).find(x=>x.textContent===v);
    if (ps) ps.parentElement.remove();
  }
  function addEnum(k, v){
    const fs = Array.from(document.querySelectorAll('.fieldset')).find(x=>x.querySelector('.lbl').textContent.toLowerCase().includes(k.replace('_',' ')));
    const ul = fs.querySelector('.pill-list');
    ul.append(el('li',{class:'pill-row'}, el('span',{class:'pill'}, v),
      btn('✎','yellow',()=>{ const nv=prompt('Edit value', v); if(nv&&nv.trim()) updateEnum(k,v,nv.trim()); }),
      btn('🗑','red',()=> removeEnum(k, v))
    ));
  }

  function render(){
    const root = document.body;
    root.innerHTML = '';
    const style = document.createElement('style');
    style.textContent = `
body { font-family: system-ui, sans-serif; margin:0; background:#f5f6f7; }
.topbar { display:flex; justify-content:space-between; align-items:center; padding:10px 12px; background:#111827; color:white; position:sticky; top:0; }
.topbar .btn { margin-right:6px; }
.page { padding:16px; }
.card { border:1px solid #ddd; border-radius:10px; padding:14px; background:#fff; }
.btn { padding:6px 10px; border-radius:8px; border:1px solid #888; background:#eee; cursor:pointer; }
.btn.green { background:#22c55e; color:white; border-color:#16a34a; }
.btn.blue  { background:#3b82f6; color:white; border-color:#2563eb; }
.btn.yellow{ background:#fbbf24; color:#000; border-color:#d97706; }
.btn.red   { background:#ef4444; color:white; border-color:#dc2626; }
.pill-list { list-style:none; padding:0; margin:8px 0; }
.pill-row { display:flex; align-items:center; gap:8px; margin:4px 0; }
.pill { display:inline-block; padding:4px 8px; border-radius:999px; background:#eee; }
.fieldset { margin:12px 0; }
.fieldset .lbl { display:block; font-weight:600; margin-bottom:6px; }
.lists-wrap { display:grid; grid-template-columns: repeat(auto-fit, minmax(260px,1fr)); gap:16px; }
input { padding:6px 8px; border:1px solid #ccc; border-radius:8px; margin:4px 0; }
`;
    document.head.append(style);
    const app = el('div',{id:'app'});
    document.body.append(header(), app);

    if (!TOKEN) renderLogin();
    else viewTrends();
  }

  render();
})();
JS
  echo -e "${GREEN}✔ main.js replaced with clean baseline UI${NC}"
fi

# ------------------------------------------------------------
# 5) Validate all layers
# ------------------------------------------------------------
echo -e "${YELLOW}🔍 Validating all files...${NC}"
fail=0
# bash
find "$ROOT/docker" -type f -name "*.sh" -maxdepth 1 -print0 2>/dev/null | xargs -0 -I{} bash -n {} || fail=1
# python
if [[ -d "$API_DIR" ]]; then
  find "$API_DIR" -type f -name "*.py" -print0 | xargs -0 -I{} python3 -m py_compile {} || fail=1
fi
# node
if command -v node >/dev/null 2>&1; then
  node --check "$JS" || fail=1
fi
if [[ $fail -ne 0 ]]; then
  echo -e "${RED}❌ Validation errors remain — aborting rebuild.${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Syntax OK across all layers${NC}"

# ------------------------------------------------------------
# 6) Rebuild and health-check
# ------------------------------------------------------------
echo -e "${YELLOW}🐳 Rebuilding Docker stack...${NC}"
docker compose -f "$COMPOSE" down --remove-orphans || true
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

sleep 5
API_IP=$(hostname -I | awk '{print $1}')
API_URL="http://${API_IP}:8010/openapi.json"
UI_URL="http://${API_IP}:5183"

echo -e "${YELLOW}🌐 Checking API: $API_URL${NC}"
if curl -s --max-time 6 "$API_URL" | grep -q "openapi"; then
  echo -e "${GREEN}✔ API reachable${NC}"
else
  echo -e "${RED}✖ API unreachable${NC}"
  docker logs docker-api-1 | tail -n 120 || true
  exit 1
fi

echo -e "${YELLOW}🌐 Checking UI: $UI_URL${NC}"
if curl -s --max-time 6 "$UI_URL" | grep -q "<!DOCTYPE html>"; then
  echo -e "${GREEN}✔ UI reachable${NC}"
else
  echo -e "${RED}✖ UI unreachable${NC}"
  docker logs docker-web-1 | tail -n 60 || true
  exit 1
fi

echo -e "${GREEN}🚀 All repairs + validations PASSED${NC}"
echo -e "Open UI: ${YELLOW}$UI_URL${NC}  |  API: ${YELLOW}${API_IP}:8010${NC}"
echo -e "Tip: localStorage.setItem('API_BASE','http://${API_IP}:8010'); location.reload()"
