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
  $(basename "$0") --restore last  # rollback last backup
"; }

# ---------------- Restore mode ----------------
if [[ "${1-}" == "--restore" ]]; then
  ts="${2-last}"
  [[ "$ts" == "last" ]] && { [[ -f "$LAST" ]] || { echo -e "${R}No last backup${N}"; exit 1; }; ts="$(cat "$LAST")"; }
  tgz="$BACK/$ts.tar.gz"
  [[ -f "$tgz" ]] || { echo -e "${R}Backup not found:${N} $tgz"; exit 1; }
  echo -e "${Y}🧺 Restoring backup $ts ...${N}"
  tar -xzf "$tgz" -C /
  echo -e "${Y}🔁 Rebuilding & restarting...${N}"
  docker compose -f "$COMPOSE" down --remove-orphans || true
  docker compose -f "$COMPOSE" build
  docker compose -f "$COMPOSE" up -d
  echo -e "${G}✔ Restored.${N}"
  exit 0
fi

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

mkdir -p "$CORE" "$ROUT" "$WEB"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$ROUT/__init__.py"

# ---------------- API: extend users router ----------------
# Adds admin list/create/delete/reset and self change_password
python3 - <<'PY'
import os, re
from pathlib import Path
api = Path(os.path.expanduser("~/sms-procurement-manager/api/app"))
users_p = api/"routers"/"users.py"
if not users_p.exists():
    raise SystemExit("users.py not found; your stack should already have it (login/me).")

s = users_p.read_text(encoding="utf-8")

# Ensure imports
if "from sqlalchemy import text" not in s:
    s = s.replace("from fastapi import APIRouter, Depends, HTTPException, status",
                  "from fastapi import APIRouter, Depends, HTTPException, status\nfrom sqlalchemy import text")
if "from app.core.database import engine" not in s:
    if "from app.core.database import" in s:
        pass
    else:
        s = s.replace("from app.core.auth import", "from app.core.database import engine\nfrom app.core.auth import")

# Helpers to check admin from current_user
admin_block = r'''
def _row_to_user_obj(row):
    return {"id": row.id, "username": row.username, "is_admin": bool(row.is_admin)}

@router.get("/", tags=["Users"])
def list_users(current=Depends(get_current_user)):
    if not current.get("is_admin"):
        raise HTTPException(status_code=403, detail="Admin only")
    with engine.begin() as c:
        rows = c.execute(text("SELECT id, username, COALESCE(is_admin,false) AS is_admin FROM users ORDER BY id")).mappings().all()
    return [_row_to_user_obj(r) for r in rows]

@router.post("/", tags=["Users"])
def create_user(payload: dict, current=Depends(get_current_user)):
    if not current.get("is_admin"):
        raise HTTPException(403, "Admin only")
    u = (payload.get("username") or "").strip()
    p = (payload.get("password") or "").strip()
    is_admin = bool(payload.get("is_admin", False))
    if not u or not p:
        raise HTTPException(400, "Username and password required")
    from passlib.hash import bcrypt
    ph = bcrypt.hash(p)
    with engine.begin() as c:
        try:
            c.execute(text("INSERT INTO users(username,password_hash,is_admin) VALUES(:u,:ph,:ad)"),
                      dict(u=u, ph=ph, ad=is_admin))
        except Exception as e:
            raise HTTPException(400, f"Create failed: {e}")
    return {"ok": True}

@router.delete("/{user_id}", tags=["Users"])
def delete_user(user_id: int, current=Depends(get_current_user)):
    if not current.get("is_admin"):
        raise HTTPException(403, "Admin only")
    if user_id == current["id"]:
        raise HTTPException(400, "Cannot delete yourself")
    with engine.begin() as c:
        c.execute(text("DELETE FROM users WHERE id=:i"), dict(i=user_id))
    return {"ok": True}

@router.post("/{user_id}/password", tags=["Users"])
def admin_set_password(user_id: int, payload: dict, current=Depends(get_current_user)):
    if not current.get("is_admin"):
        raise HTTPException(403, "Admin only")
    p = (payload.get("password") or "").strip()
    if not p: raise HTTPException(400, "Password required")
    from passlib.hash import bcrypt
    ph = bcrypt.hash(p)
    with engine.begin() as c:
        c.execute(text("UPDATE users SET password_hash=:ph WHERE id=:i"), dict(ph=ph, i=user_id))
    return {"ok": True}

@router.post("/change_password", tags=["Users"])
def self_change_password(payload: dict, current=Depends(get_current_user)):
    old = (payload.get("old_password") or "").strip()
    new = (payload.get("new_password") or "").strip()
    if len(new) < 6:
        raise HTTPException(400, "New password too short")
    from passlib.hash import bcrypt
    # fetch current hash
    with engine.begin() as c:
        row = c.execute(text("SELECT password_hash FROM users WHERE id=:i"), dict(i=current["id"])).first()
        if not row: raise HTTPException(404, "User not found")
        if not bcrypt.verify(old, row[0]): raise HTTPException(401, "Old password incorrect")
        c.execute(text("UPDATE users SET password_hash=:ph WHERE id=:i"),
                  dict(ph=bcrypt.hash(new), i=current["id"]))
    return {"ok": True}
'''

if "def list_users(" not in s:
    # append at end
    s = s.rstrip() + "\n\n" + admin_block

users_p.write_text(s, encoding="utf-8")
print("✓ users.py: admin & self password endpoints added")
PY

# ---------------- API: extend settings router with /settings/scrape ----------------
python3 - <<'PY'
import os
from pathlib import Path
api = Path(os.path.expanduser("~/sms-procurement-manager/api/app"))
settings_p = api/"routers"/"settings.py"
if not settings_p.exists():
    # create a minimal settings router if missing (imap may already exist)
    settings_p.write_text("from fastapi import APIRouter\nrouter=APIRouter(prefix='/settings',tags=['Settings'])\n", encoding="utf-8")

s = settings_p.read_text(encoding="utf-8")

need_imports = []
if "from sqlalchemy import text" not in s: need_imports.append("from sqlalchemy import text")
if "import json" not in s: need_imports.append("import json")
if "from app.core.database import engine" not in s: need_imports.append("from app.core.database import engine")
if "from app.core.auth import get_current_user" not in s: need_imports.append("from app.core.auth import get_current_user")
if need_imports:
    s = s.replace("router = APIRouter", "\n".join(need_imports) + "\nrouter = APIRouter")

# Add scrape config get/put and test
scrape_block = r'''
DEFAULT_SCRAPE = {
    "enabled": False,
    "interval_seconds": 600,
    "concurrency": 2,
    "timeout_seconds": 20,
    "respect_robots": True,
    "rate_limit_per_domain": 2,
    "user_agent": "SPM-Scraper/1.0",
    "proxy_url": "",
    "allow_domains": [],
    "deny_domains": [],
    "base_urls": [],
    "headers": [],        # list of {"name":"Header-Name","value":"x"}
    "templates": []       # list of {"source":"ExampleSite","field_map":[{"field":"price","selector":".price"}]}
}

def _kv_get(key, default):
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key=:k"), dict(k=key)).first()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES (:k,:v)"),
                      dict(k=key, v=json.dumps(default)))
            return default
        v = row[0]
        if isinstance(v, str):
            import json as _json
            try: v = _json.loads(v)
            except Exception: v = default
        return v or default

def _kv_set(key, value):
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value,updated_at) VALUES(:k,:v,now()) "
                       "ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()"),
                  dict(k=key, v=json.dumps(value)))

@router.get("/scrape")
def get_scrape(current=Depends(get_current_user)):
    # ensure table exists
    with engine.begin() as c:
        c.execute(text("""CREATE TABLE IF NOT EXISTS config_kv(
            key TEXT PRIMARY KEY, value JSONB NOT NULL, updated_at TIMESTAMPTZ DEFAULT now()
        )"""))
    return _kv_get("scrape", DEFAULT_SCRAPE)

@router.put("/scrape")
def put_scrape(payload: dict, current=Depends(get_current_user)):
    cur = _kv_get("scrape", DEFAULT_SCRAPE)
    # merge limited keys only
    for k in DEFAULT_SCRAPE.keys():
        if k in payload: cur[k] = payload[k]
    _kv_set("scrape", cur)
    return cur

@router.post("/scrape/test")
def test_scrape(payload: dict|None=None, current=Depends(get_current_user)):
    # lightweight validation only (we are not running the scraper here)
    cfg = _kv_get("scrape", DEFAULT_SCRAPE)
    if payload:
        for k in DEFAULT_SCRAPE.keys():
            if k in payload: cfg[k] = payload[k]
    if not isinstance(cfg.get("interval_seconds"), int) or cfg["interval_seconds"] < 30:
        return {"ok": False, "error": "interval_seconds should be >= 30"}
    if not isinstance(cfg.get("concurrency"), int) or cfg["concurrency"] < 1:
        return {"ok": False, "error": "concurrency should be >= 1"}
    return {"ok": True}
'''

if "DEFAULT_SCRAPE" not in s:
    s = s.rstrip() + "\n" + scrape_block

settings_p.write_text(s, encoding="utf-8")
print("✓ settings.py: /settings/scrape endpoints added")
PY

# ---------------- API: ensure CORS and router includes ----------------
env API="$API" python3 - <<'PY'
import os, re
from pathlib import Path
api_dir = Path(os.environ['API'])
p = api_dir/'main.py'
s = p.read_text(encoding='utf-8')

# CORS
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")
if "app.add_middleware(CORSMiddleware" not in s:
    s = re.sub(r"(app\s*=\s*FastAPI\([^\)]*\))",
               r"\1\napp.add_middleware(CORSMiddleware, allow_origins=['*'], allow_credentials=False, allow_methods=['*'], allow_headers=['*'])",
               s, count=1, flags=re.S)

# Include routers
if "from app.routers.settings import router as settings" not in s:
    s = s.replace("from app.routers.metrics import router as metrics",
                  "from app.routers.metrics import router as metrics\nfrom app.routers.settings import router as settings")
if "app.include_router(settings)" not in s:
    s = s.replace("app.include_router(metrics)", "app.include_router(metrics)\napp.include_router(settings)")

p.write_text(s, encoding='utf-8')
print("✓ main.py wired for CORS and settings router")
PY

# ---------------- Frontend: extend Settings UI with two new accordions ----------------
python3 - <<'PY'
import os, re
from pathlib import Path
web = Path(os.path.expanduser("~/sms-procurement-manager/web/public"))
js_p = web/"main.js"
src = js_p.read_text(encoding="utf-8")

def ensure_theme():
    theme = (web/"theme.css")
    if not theme.exists():
        theme.write_text(":root{--bg-0:#faf5ee;--text-0:#2b1e12}\n", encoding="utf-8")
    if (web/"index.html").exists():
        ih = (web/"index.html").read_text(encoding="utf-8")
        if "theme.css" not in ih:
            ih = ih.replace("</head>", '  <link rel="stylesheet" href="theme.css"/>\n</head>')
            (web/"index.html").write_text(ih, encoding="utf-8")

ensure_theme()

# Replace viewSettings with a compact accordion that contains DropDowns, IMAP, Scrape, Users
pat = re.compile(r"async\s+function\s+viewSettings\s*\(\)\s*\{.*?\n\}", re.S)

block = r"""
async function viewSettings(){
  await go(async ()=>{
    // enums
    const enums = await authFetch(API_BASE + '/conf/enums').catch(()=>({route_type:[],known_hops:[],registration_required:[]}));
    const state = JSON.parse(JSON.stringify(enums));
    function listBlock(key,label){
      const add = el('input',{placeholder:'Add value',style:'width:160px'});
      const addBtn = el('button',{class:'btn green'},'Add');
      const saveBtn = el('button',{class:'btn blue'},'Save');
      const ul = el('ul',{class:'pill-list'});
      function render(){
        ul.innerHTML='';
        (state[key]||[]).forEach((v,i)=>{
          const row = el('li',{class:'pill-row'}, el('span',{class:'pill'},v),
            el('button',{class:'btn yellow'},'Edit'), el('button',{class:'btn red'},'Del'));
          row.children[1].onclick=()=>{const nv=prompt('Edit',v); if(nv&&nv.trim()&&nv!==v){state[key][i]=nv.trim(); render();}};
          row.children[2].onclick=()=>{state[key].splice(i,1); render();};
          ul.append(row);
        });
      }
      addBtn.onclick=()=>{const v=add.value.trim(); if(v){state[key]=state[key]||[]; state[key].push(v); add.value=''; render();}};
      saveBtn.onclick=async()=>{const p={}; p[key]=state[key]; await authFetch(API_BASE+'/conf/enums',{method:'PUT',body:JSON.stringify(p)}).then(()=>alert(label+' saved')).catch(e=>alert('Save failed: '+e.message));};
      render();
      return el('div',{class:'card'}, el('div',{class:'row'},el('strong',{},label), add, addBtn, saveBtn), ul);
    }
    const dd = el('details',{class:'accordion'},
      el('summary',{},'Drop Down Menus'),
      el('div',{class:'acc-body'},
        el('div',{class:'grid-2'},
          listBlock('route_type','Route type'),
          listBlock('known_hops','Known hops'),
          listBlock('registration_required','Registration required')
        ),
        el('div',{class:'row',style:'margin-top:6px'},
          el('button',{class:'btn blue'},'Save All')
        )
      )
    );
    dd.querySelector('.btn.blue').onclick = async ()=>{await authFetch(API_BASE+'/conf/enums',{method:'PUT',body:JSON.stringify(state)}).then(()=>alert('All dropdowns saved')).catch(e=>alert('Save All failed: '+e.message));};

    // IMAP (reads existing values)
    let imap = await authFetch(API_BASE+'/settings/imap').catch(()=>({host:'',port:993,username:'',password:'',use_ssl:true,folders:[]}));
    const host = el('input',{value:imap.host||'',placeholder:'imap.example.com'});
    const port = el('input',{type:'number',value:String(imap.port??993),style:'width:110px'});
    const user = el('input',{value:imap.username||'',placeholder:'username'});
    const pass = el('input',{type:'password',value:imap.password||'',placeholder:'password'});
    const ssl  = el('input',{type:'checkbox'}); ssl.checked=!!imap.use_ssl;
    const saveImap = el('button',{class:'btn blue'},'Save IMAP');
    saveImap.onclick = async ()=>{
      const body={host:host.value.trim(),port:Number(port.value||993),username:user.value.trim(),password:pass.value,use_ssl:ssl.checked,folders:imap.folders||[]};
      await authFetch(API_BASE+'/settings/imap',{method:'PUT',body:JSON.stringify(body)}).then(()=>alert('IMAP saved')).catch(e=>alert('Save IMAP failed: '+e.message));
    };
    const imapCard = el('details',{class:'accordion'},
      el('summary',{},'IMAP Settings'),
      el('div',{class:'acc-body'},
        el('div',{class:'grid-2'},
          el('div',{class:'card'},
            el('div',{class:'row'},el('div',{class:'lbl'},'Host'),host),
            el('div',{class:'row'},el('div',{class:'lbl'},'Port'),port),
            el('div',{class:'row'},el('div',{class:'lbl'},'Username'),user),
            el('div',{class:'row'},el('div',{class:'lbl'},'Password'),pass),
            el('div',{class:'row'},el('div',{class:'lbl'},'Use SSL'),ssl),
            el('div',{class:'row'}, saveImap)
          )
        )
      )
    );

    // Scraping Settings
    let scrape = await authFetch(API_BASE+'/settings/scrape').catch(()=>({
      enabled:false,interval_seconds:600,concurrency:2,timeout_seconds:20,respect_robots:true,
      rate_limit_per_domain:2,user_agent:'SPM-Scraper/1.0',proxy_url:'',allow_domains:[],deny_domains:[],
      base_urls:[],headers:[],templates:[]
    }));
    function chipEditor(arr, placeholder){
      const wrap = el('div',{}), list = el('div',{class:'row'}), input = el('input',{placeholder});
      const add = el('button',{class:'btn green'},'Add');
      function render(){
        list.innerHTML=''; (arr||[]).forEach((v,i)=> list.append(el('span',{class:'pill'},v), el('button',{class:'btn red'},'x',null,(btn)=> btn.onclick=()=>{arr.splice(i,1); render();})));
      }
      add.onclick=()=>{const v=input.value.trim(); if(v){arr.push(v); input.value=''; render();}};
      wrap.append(list, el('div',{class:'row'}, input, add));
      render(); return wrap;
    }
    function headersEditor(harr){
      const box = el('div',{}), tbl = el('div',{}), addN = el('input',{placeholder:'Header-Name'}), addV = el('input',{placeholder:'value'});
      const add = el('button',{class:'btn green'},'Add');
      function render(){
        tbl.innerHTML=''; (harr||[]).forEach((h,i)=>{
          const n = el('input',{value:h.name||'',style:'width:180px'}), v = el('input',{value:h.value||'',style:'width:260px'});
          const del = el('button',{class:'btn red'},'Del');
          del.onclick=()=>{harr.splice(i,1); render();};
          n.oninput=()=>h.name=n.value; v.oninput=()=>h.value=v.value;
          tbl.append(el('div',{class:'row'}, el('div',{class:'lbl'},'H'+(i+1)), n, v, del));
        });
      }
      add.onclick=()=>{const n=addN.value.trim(), v=addV.value.trim(); if(n){harr.push({name:n,value:v}); addN.value=''; addV.value=''; render();}};
      box.append(tbl, el('div',{class:'row'}, addN, addV, add)); render(); return box;
    }
    function templateEditor(tarr){
      const box = el('div',{}), tbl = el('div',{}), addName = el('input',{placeholder:'Source name'});
      const add = el('button',{class:'btn green'},'Add template');
      function render(){
        tbl.innerHTML=''; (tarr||[]).forEach((t,i)=>{
          t.field_map = t.field_map||[];
          const src = el('input',{value:t.source||'',placeholder:'Source',style:'width:160px'}); src.oninput=()=>t.source=src.value;
          const addRow = el('button',{class:'btn yellow'},'Add field');
          const rows = el('div',{});
          function renderRows(){
            rows.innerHTML=''; t.field_map.forEach((m,j)=>{
              const f=el('input',{value:m.field||'',placeholder:'field',style:'width:120px'}); f.oninput=()=>m.field=f.value;
              const sel=el('input',{value:m.selector||'',placeholder:'CSS selector',style:'width:240px'}); sel.oninput=()=>m.selector=sel.value;
              const del=el('button',{class:'btn red'},'Del'); del.onclick=()=>{t.field_map.splice(j,1); renderRows();};
              rows.append(el('div',{class:'row'}, f, sel, del));
            });
          }
          addRow.onclick=()=>{t.field_map.push({field:'',selector:''}); renderRows();};
          const delT = el('button',{class:'btn red'},'Delete template'); delT.onclick=()=>{tarr.splice(i,1); render();};
          renderRows();
          tbl.append(el('div',{class:'card'}, el('div',{class:'row'}, el('div',{class:'lbl'},'Source'), src, addRow, delT), rows));
        });
      }
      add.onclick=()=>{const n=addName.value.trim(); tarr.push({source:n||('Source '+(tarr.length+1)), field_map:[]}); addName.value=''; render();};
      box.append(el('div',{class:'row'}, addName, add), tbl); render(); return box;
    }

    const scSave = el('button',{class:'btn blue'},'Save Scraping');
    const scTest = el('button',{class:'btn yellow'},'Test Settings');
    scSave.onclick = async ()=>{
      await authFetch(API_BASE+'/settings/scrape',{method:'PUT',body:JSON.stringify(scrape)})
        .then(()=>alert('Scraping saved')).catch(e=>alert('Save failed: '+e.message));
    };
    scTest.onclick = async ()=>{
      const r = await authFetch(API_BASE+'/settings/scrape/test',{method:'POST',body:JSON.stringify(scrape)}).catch(e=>({ok:false,error:e.message}));
      alert(r.ok ? 'OK' : ('Invalid: '+r.error));
    };

    const sc = el('details',{class:'accordion'},
      el('summary',{},'Scraping Settings'),
      el('div',{class:'acc-body'},
        el('div',{class:'grid-2'},
          el('div',{class:'card'},
            el('div',{class:'row'}, el('div',{class:'lbl'},'Enabled'), (()=>{
              const c=el('input',{type:'checkbox'}); c.checked=!!scrape.enabled; c.onchange=()=>scrape.enabled=c.checked; return c;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'Interval (s)'), (()=>{
              const i=el('input',{type:'number',value:String(scrape.interval_seconds||600),style:'width:120px'}); i.oninput=()=>scrape.interval_seconds=Number(i.value||600); return i;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'Concurrency'), (()=>{
              const i=el('input',{type:'number',value:String(scrape.concurrency||2),style:'width:120px'}); i.oninput=()=>scrape.concurrency=Number(i.value||2); return i;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'Timeout (s)'), (()=>{
              const i=el('input',{type:'number',value:String(scrape.timeout_seconds||20),style:'width:120px'}); i.oninput=()=>scrape.timeout_seconds=Number(i.value||20); return i;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'Robots.txt'), (()=>{
              const c=el('input',{type:'checkbox'}); c.checked=!!scrape.respect_robots; c.onchange=()=>scrape.respect_robots=c.checked; return c;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'Rate limit / domain'), (()=>{
              const i=el('input',{type:'number',value:String(scrape.rate_limit_per_domain||2),style:'width:120px'}); i.oninput=()=>scrape.rate_limit_per_domain=Number(i.value||2); return i;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'User-Agent'), (()=>{
              const i=el('input',{value:scrape.user_agent||'SPM-Scraper/1.0',style:'width:320px'}); i.oninput=()=>scrape.user_agent=i.value; return i;
            })()),
            el('div',{class:'row'}, el('div',{class:'lbl'},'Proxy URL'), (()=>{
              const i=el('input',{value:scrape.proxy_url||'',style:'width:320px'}); i.oninput=()=>scrape.proxy_url=i.value; return i;
            })()),
            el('hr',{}),
            el('div',{class:'lbl'},'Allow domains'),
            chipEditor(scrape.allow_domains,'example.com'),
            el('div',{class:'lbl'},'Deny domains'),
            chipEditor(scrape.deny_domains,'blocked.com'),
            el('div',{class:'lbl'},'Base URLs'),
            chipEditor(scrape.base_urls,'https://example.com/offers')
          ),
          el('div',{class:'card'},
            el('div',{class:'lbl'},'Custom Headers'), headersEditor(scrape.headers),
            el('hr',{}),
            el('div',{class:'lbl'},'Templates (selectors mapping)'), templateEditor(scrape.templates),
            el('div',{class:'row'}, scSave, scTest)
          )
        )
      )
    );

    // Users management
    const me = await authFetch(API_BASE+'/users/me').catch(()=>({username:'',is_admin:false}));
    const usersCard = el('details',{class:'accordion'}, el('summary',{},'Users management'));
    const body = el('div',{class:'acc-body'}); usersCard.append(body);

    if(me.is_admin){
      const rows = await authFetch(API_BASE+'/users/').catch(()=>[]);
      const table = el('table',{class:'table'},
        el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Username'), el('th',{},'Admin'), el('th',{},'Actions'))),
        el('tbody',{}, ...(rows||[]).map(u=>{
          const tr = el('tr',{}, el('td',{},String(u.id)), el('td',{},u.username), el('td',{}, String(!!u.is_admin)),
            el('td',{},
              el('button',{class:'btn yellow'},'Reset password',null,(b)=> b.onclick=async()=>{
                const np = prompt('New password for '+u.username); if(!np) return;
                await authFetch(API_BASE+`/users/${u.id}/password`,{method:'POST',body:JSON.stringify({password:np})})
                  .then(()=>alert('Password updated')).catch(e=>alert('Reset failed: '+e.message));
              }),
              el('button',{class:'btn red', style:'margin-left:6px'},'Delete',null,(b)=> b.onclick=async()=>{
                if(!confirm('Delete '+u.username+' ?')) return;
                await authFetch(API_BASE+`/users/${u.id}`,{method:'DELETE'})
                  .then(()=>{alert('Deleted'); viewSettings();})
                  .catch(e=>alert('Delete failed: '+e.message));
              })
            )
          ); return tr;
        }))
      );
      const nu = el('input',{placeholder:'username'}), np = el('input',{placeholder:'password',type:'password'}), adm = el('input',{type:'checkbox'});
      const add = el('button',{class:'btn green'},'Create user');
      add.onclick = async ()=>{
        await authFetch(API_BASE+'/users/',{method:'POST',body:JSON.stringify({username:nu.value.trim(),password:np.value,is_admin:adm.checked})})
          .then(()=>{alert('User created'); viewSettings();})
          .catch(e=>alert('Create failed: '+e.message));
      };
      body.append(el('div',{class:'card'}, el('h3',{},'Users (admin)') , table, el('div',{class:'row'}, nu, np, el('label',{},adm,' admin'), add)));
    } else {
      const oldp = el('input',{type:'password',placeholder:'old password'});
      const newp = el('input',{type:'password',placeholder:'new password'});
      const save = el('button',{class:'btn blue'},'Change password');
      save.onclick = async ()=>{
        await authFetch(API_BASE+'/users/change_password',{method:'POST',body:JSON.stringify({old_password:oldp.value,new_password:newp.value})})
          .then(()=>alert('Password changed')).catch(e=>alert('Change failed: '+e.message));
      };
      body.append(el('div',{class:'card'}, el('h3',{},'Change password'), el('div',{class:'row'}, el('div',{class:'lbl'},'Old'), oldp), el('div',{class:'row'}, el('div',{class:'lbl'},'New'), newp), save));
    }

    // mount page
    const app = $('#app'); app.innerHTML='';
    app.append(dd, imapCard, sc, usersCard);
  });
}
"""

if pat.search(src):
    src = pat.sub(block, src)
else:
    src += "\n" + block

js_p.write_text(src, encoding="utf-8")
print("✓ main.js: Settings UI extended (Scraping + Users)")
PY

# ---------------- Rebuild & restart ----------------
echo -e "${Y}🔁 Restarting stack...${N}"
docker compose -f "$COMPOSE" down --remove-orphans || true
docker compose -f "$COMPOSE" build
docker compose -f "$COMPOSE" up -d

# ---------------- Health checks ----------------
sleep 4
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}🌐 API check:${N} http://$IP:8010/openapi.json"
if curl -sf "http://$IP:8010/openapi.json" >/tmp/openapi.json; then
  echo -e "${G}✔ API up${N}"
  grep -oE '"/(settings|users|conf)/[^"]*' /tmp/openapi.json | sort -u
else
  echo -e "${R}✖ API not reachable — api logs follow:${N}"
  docker logs "$(docker ps --format '{{.Names}}' | grep api)" --tail=120 || true
fi
echo -e "${G}✅ Done. UI: http://$IP:5183  (login as admin)${N}"
echo -e "${Y}Undo anytime:${N} $(basename "$0") --restore last"
