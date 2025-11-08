#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
ROUT="$API/routers"
WEBPUB="$ROOT/web/public"

mkdir -p "$CORE" "$ROUT" "$WEBPUB"

################################
# API: CORS + enums JSON + IMAP/System settings
################################
# main.py → permissive CORS (*) without credentials (we use Bearer, not cookies)
python3 - <<'PY'
from pathlib import Path
p=Path("""'"$API"'/main.py""")
s=p.read_text()
import re
# ensure CORSMiddleware import
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    s=s.replace("from fastapi import FastAPI","from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")
# replace origins block to '*' and allow_credentials=False
s=re.sub(r"origins\s*=\s*\[.*?\]\s*\napp\.add_middleware\([^\)]*\)",
         "origins = ['*']\napp.add_middleware(CORSMiddleware,\n    allow_origins=origins, allow_credentials=False, allow_methods=['*'], allow_headers=['*']\n)",
         s, flags=re.S)
Path(p).write_text(s)
print("✓ CORS updated in main.py")
PY

# conf.py → cast JSON to jsonb to avoid psycopg adapter 500s
python3 - <<'PY'
import json
from pathlib import Path
p=Path("""'"$ROUT"'/conf.py""")
s=p.read_text()
if "import json" not in s:
    s="import json\n"+s
s=s.replace("DO UPDATE SET data=:d", "DO UPDATE SET data=:d::jsonb")
s=s.replace("VALUES(1,:d)", "VALUES(1,:d::jsonb)")
s=s.replace("body: dict", "body: dict")
# ensure we dump JSON body
if "json.dumps(body)" not in s:
    s=s.replace(" {\"d\": body}", " {\"d\": json.dumps(body)}")
Path(p).write_text(s)
print("✓ conf.py JSONB cast")
PY

# migrations.py → ensure app_settings table exists
python3 - <<'PY'
from pathlib import Path
p=Path("""'"$API"'/migrations.py""")
s=p.read_text()
if "app_settings" not in s:
    s=s.replace("DDL = [", "DDL = [\n\"\"\"\nCREATE TABLE IF NOT EXISTS app_settings(\n  k TEXT PRIMARY KEY,\n  v JSONB\n)\n\"\"\",\n")
Path(p).write_text(s)
print("✓ migrations: app_settings ensured")
PY

# settings.py router (IMAP + System)
cat > "$ROUT/settings.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import get_current_user
import imaplib
import ssl
import json

router = APIRouter(tags=["Settings"])

def _get_k(key:str):
    with SessionLocal() as db:
        r=db.execute(text("SELECT v FROM app_settings WHERE k=:k"),{"k":key}).first()
        return r[0] if r else None

def _set_k(key:str, val):
    with SessionLocal() as db:
        db.execute(text("INSERT INTO app_settings(k,v) VALUES(:k,:v::jsonb) ON CONFLICT (k) DO UPDATE SET v=:v::jsonb"),
                   {"k":key, "v":json.dumps(val)})
        db.commit(); return True

@router.get("/settings/imap")
def get_imap(user:str=Depends(get_current_user)):
    return _get_k("imap") or {}

@router.put("/settings/imap")
def put_imap(body:dict, user:str=Depends(get_current_user)):
    # expected keys: host, port, user, password, ssl, folders(list)
    _set_k("imap", body or {}); return {"ok":True}

@router.post("/settings/imap/test")
def test_imap(body:dict|None=None, user:str=Depends(get_current_user)):
    cfg = body or _get_k("imap") or {}
    host = cfg.get("host"); port=int(cfg.get("port") or (993 if cfg.get("ssl",True) else 143))
    username = cfg.get("user"); password = cfg.get("password"); use_ssl = bool(cfg.get("ssl", True))
    if not (host and username and password):
        raise HTTPException(400, "host/user/password required")
    try:
        if use_ssl:
            M = imaplib.IMAP4_SSL(host, port)
        else:
            M = imaplib.IMAP4(host, port)
        M.login(username, password)
        typ, data = M.list()
        M.logout()
        if typ != 'OK':
            raise HTTPException(400, "IMAP LIST failed")
        folders=[]
        for b in data or []:
            try:
                # b like: b'(\\HasNoChildren) "/" "INBOX"'
                t = b.decode('utf-8', errors='ignore')
                name = t.split(' "/" ',1)[-1].strip().strip('"')
                if name: folders.append(name)
            except Exception:
                pass
        return {"ok":True, "folders":sorted(set(folders))}
    except imaplib.IMAP4.error as e:
        raise HTTPException(400, f"IMAP error: {e}")
    except Exception as e:
        raise HTTPException(400, f"IMAP connect error: {e}")

@router.get("/settings/system")
def get_system(user:str=Depends(get_current_user)):
    return _get_k("system") or {"note":"CORS is currently set to allow all origins (no credentials)."}

@router.put("/settings/system")
def put_system(body:dict, user:str=Depends(get_current_user)):
    _set_k("system", body or {}); return {"ok":True}
PY

# main.py include settings router (idempotent)
python3 - <<'PY'
from pathlib import Path, re
p=Path("""'"$API"'/main.py""")
s=p.read_text()
if "from app.routers import users, suppliers" in s and "settings" not in s:
    s=s.replace("from app.routers import users, suppliers, countries, networks, offers, conf, metrics, lookups, parsers",
                "from app.routers import users, suppliers, countries, networks, offers, conf, metrics, lookups, parsers, settings")
if "app.include_router(settings.router)" not in s:
    s=s.replace("app.include_router(parsers.router)", "app.include_router(parsers.router)\napp.include_router(settings.router)")
p.write_text(s)
print("✓ settings router wired")
PY

################################
# WEB: Suppliers UI + Settings UI (dirty/save-all) + IMAP/System sections
################################
# main.js tweaks:
# - remove checkbox on "add connection" row
# - inline edit: Per Delivered -> dropdown Yes/No, Charge Model -> dropdown
# - Settings: single “Drop Down Menus” category card; Save All appears only when dirty; navigation guard
# - IMAP category with test/folders multi-select
# - System category
python3 - <<'PY'
from pathlib import Path, re, json
p=Path("""'"$WEBPUB"'/main.js""")
s=p.read_text()

# --- Suppliers add-connection row: remove Per Delivered checkbox ---
s=re.sub(r'<label><input type="checkbox" id="cpd-\${s.id}"/> Per Delivered</label>\s*', '', s)

# --- Suppliers inline edit: make per_delivered dropdown + charge model dropdown ---
s=re.sub(r'<label>Per Delivered</label><input type="checkbox" id="ep-\$\{s.id\}"[^>]*>',
         '<label>Per Delivered</label><select id="ep-${s.id}"><option value="true">Yes</option><option value="false">No</option></select>', s)
s=re.sub(r'<label>Charge</label><input id="ec-\$\{s.id\}"[^>]*>',
         '<label>Charge</label><select id="ec-${s.id}"><option>Per Submitted</option><option>Per Delivered</option></select>', s)

# when saving inline, convert dropdowns to values
s=s.replace(
"const body={connection_name:$('#en-'+s.id).value.trim(), username:$('#eu-'+s.id).value.trim()||null, kannel_smsc:$('#ek-'+s.id).value.trim()||null, per_delivered:$('#ep-'+s.id).checked, charge_model:$('#ec-'+s.id).value.trim()||null};",
"const body={connection_name:$('#en-'+s.id).value.trim(), username:$('#eu-'+s.id).value.trim()||null, kannel_smsc:$('#ek-'+s.id).value.trim()||null, per_delivered:($('#ep-'+s.id).value==='true'), charge_model:$('#ec-'+s.id).value};"
)

# --- Settings page overhaul ---
# Inject global dirty guard helpers
if "let __DIRTY__ = false;" not in s:
    s=s.replace("const tokenKey='SPM_TOKEN', apiKey='API_BASE';",
                "const tokenKey='SPM_TOKEN', apiKey='API_BASE';\nlet __DIRTY__ = false; let __DIRTY_SCOPE = '';\nfunction markDirty(scope){ __DIRTY__=true; __DIRTY_SCOPE=scope||__DIRTY_SCOPE; const b=document.getElementById('saveEnums'); if(b) b.style.display=''; const bi=document.getElementById('imapSave'); if(bi) bi.style.display=''; const bs=document.getElementById('sysSave'); if(bs) bs.style.display=''; }\nfunction clearDirty(){ __DIRTY__=false; __DIRTY_SCOPE=''; const b=document.getElementById('saveEnums'); if(b) b.style.display='none'; const bi=document.getElementById('imapSave'); if(bi) bi.style.display='none'; const bs=document.getElementById('sysSave'); if(bs) bs.style.display='none'; }")

# Guard render() to prompt if dirty
s=s.replace("function render(view){",
"""function render(view){
  if(__DIRTY__){
    if(!confirm('You have unsaved changes. Save them before leaving? Click "Cancel" to stay on the page.')){ return; }
    // if user chooses to leave anyway, just clear (they will lose changes)
    clearDirty();
  }
""")

# Rebuild Settings view
s=re.sub(r"async function viewSettings\(\)[\s\S]*?}\n\nfunction render",
r"""async function viewSettings(){
  navActivate('settings'); clearDirty();
  const enums = await authFetch('/conf/enums').catch(()=>({}));
  const sys = await authFetch('/settings/system').catch(()=>({}));
  const imap = await authFetch('/settings/imap').catch(()=>({}));

  $('#filters').innerHTML = '';
  $('#view').innerHTML = `
    <div class="card">
      <h2>Drop Down Menus</h2>
      <div id="ddm">
        ${buildEnumBlock('Route Type','route_type',enums.route_type||[])}
        ${buildEnumBlock('Known Hops','known_hops',enums.known_hops||[])}
        ${buildEnumBlock('Registration Required','registration_required',enums.registration_required||[])}
      </div>
      <div class="row right"><button id="saveEnums" class="btn btn-blue" style="display:none">Save All</button></div>
    </div>

    <div class="card">
      <h2>IMAP</h2>
      <div class="row">
        <div><label>Host</label><input id="imapHost" value="${imap.host||''}"></div>
        <div><label>Port</label><input id="imapPort" value="${imap.port||''}"></div>
        <div><label>User</label><input id="imapUser" value="${imap.user||''}"></div>
        <div><label>Password</label><input id="imapPass" type="password" value="${imap.password||''}"></div>
        <div><label>SSL</label><select id="imapSSL"><option value="true" ${(imap.ssl??true)?'selected':''}>Yes</option><option value="false" ${!(imap.ssl??true)?'selected':''}>No</option></select></div>
        <button id="imapTest" class="btn btn-blue">Test & List Folders</button>
      </div>
      <div class="row"><label>Monitor folders (multi-select)</label><select id="imapFolders" multiple size="8" style="min-width:280px"></select></div>
      <div class="row right"><button id="imapSave" class="btn btn-blue" style="display:none">Save All</button></div>
      <div class="muted">Pick folders after a successful test. Changes are blocked from leaving until saved or discarded.</div>
    </div>

    <div class="card">
      <h2>System</h2>
      <div class="row">
        <div><label>API Base (client-side)</label><input id="sysApi" value="${localStorage.getItem('API_BASE')||''}"><button id="sysApplyApi" class="btn">Apply to this browser</button></div>
      </div>
      <div class="row">
        <div><label>Notes</label><textarea id="sysNotes" rows="3" style="min-width:420px">${(sys && sys.note) || ''}</textarea></div>
      </div>
      <div class="row right"><button id="sysSave" class="btn btn-blue" style="display:none">Save All</button></div>
      <div class="muted">Server CORS is configured to allow all origins (no credentials). The app should be reachable by any LAN IP or local domain.</div>
    </div>
  `;

  // Enum helpers
  window.buildEnumBlock = function(title,key,arr){
    const inputs = (arr||[]).map((v,i)=>`<span class="legend"><input value="${v}" id="${key}_${i}"> <button class="btn btn-red small" data-k="${key}" data-i="${i}">X</button></span>`).join('');
    return `<div class="card"><h3>${title}</h3><div class="row" id="wrap_${key}">${inputs}</div><div class="row"><input id="new_${key}" placeholder="Add value"><button class="btn btn-green" data-add="${key}">Add</button></div></div>`;
  }

  // Dirty tracking across settings
  $('#view').addEventListener('input', ()=> markDirty('settings'));
  $('#view').addEventListener('click', (e)=>{
    const t=e.target;
    if(t.matches('button[data-add]')){ const key=t.dataset.add; const val=$('#new_'+key).value.trim(); if(!val) return; const wrap=$('#wrap_'+key); const idx=wrap.querySelectorAll('input').length; wrap.insertAdjacentHTML('beforeend', `<span class="legend"><input value="${val}" id="${key}_${idx}"> <button class="btn btn-red small" data-k="${key}" data-i="${idx}">X</button></span>`); $('#new_'+key).value=''; markDirty('settings'); }
    if(t.matches('button[data-k]')){ t.parentElement.remove(); markDirty('settings'); }
  });

  $('#saveEnums').onclick = async ()=>{
    const get=(key)=> Array.from($('#wrap_'+key).querySelectorAll('input')).map(i=>i.value.trim()).filter(Boolean);
    await authFetch('/conf/enums',{method:'PUT', body: JSON.stringify({route_type:get('route_type'), known_hops:get('known_hops'), registration_required:get('registration_required')})});
    clearDirty(); alert('Saved');
  };

  // IMAP
  const fillFolders = (arr, selected)=>{
    const sel = $('#imapFolders'); sel.innerHTML = (arr||[]).map(f=>`<option ${selected&&selected.includes(f)?'selected':''}>${f}</option>`).join('');
  };
  fillFolders(imap.folders||[], imap.folders||[]);
  $('#imapTest').onclick = async ()=>{
    const body={host:$('#imapHost').value.trim(), port:$('#imapPort').value.trim(), user:$('#imapUser').value.trim(), password:$('#imapPass').value, ssl:($('#imapSSL').value==='true')};
    const r = await authFetch('/settings/imap/test',{method:'POST', body:JSON.stringify(body)});
    fillFolders(r.folders||[], (imap.folders||[]));
    markDirty('imap');
  };
  $('#imapSave').onclick = async ()=>{
    const body={host:$('#imapHost').value.trim(), port:$('#imapPort').value.trim(), user:$('#imapUser').value.trim(), password:$('#imapPass').value, ssl:($('#imapSSL').value==='true'),
                folders: Array.from($('#imapFolders').selectedOptions).map(o=>o.value)};
    await authFetch('/settings/imap',{method:'PUT', body:JSON.stringify(body)}); clearDirty(); alert('Saved');
  };

  // System
  $('#sysApplyApi').onclick = ()=>{ const v=$('#sysApi').value.trim(); if(v){ localStorage.setItem('API_BASE', v); alert('Applied to this browser.'); } };
  $('#sysSave').onclick = async ()=>{
    const body={note: $('#sysNotes').value};
    await authFetch('/settings/system',{method:'PUT', body:JSON.stringify(body)}); clearDirty(); alert('Saved');
  };
}

function render""", 1)
Path(p).write_text(s)
print("✓ web/public/main.js updated")
PY

# Rebuild & restart
cd "$ROOT/docker"
docker compose up -d --build api web
sleep 2
echo "Sanity:"
curl -sS http://localhost:8010/ | jq . 2>/dev/null || true
echo "PUT enums smoke test:"
curl -sS -X PUT http://localhost:8010/conf/enums -H 'Authorization: Bearer test' -H 'Content-Type: application/json' -d '{"route_type":["Direct"],"known_hops":["0-Hop"],"registration_required":["Yes","No"]}' | cat
echo
echo "Open UI: http://localhost:5183"
