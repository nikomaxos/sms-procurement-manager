#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
MAIN_PY="$API_DIR/main.py"
WEB_DIR="$ROOT/web/public"
MAIN_JS="$WEB_DIR/main.js"
COMPOSE="$ROOT/docker-compose.yml"
BACK="$ROOT/.backups/fix_go_and_cors_v2"
TS="$(date +%F_%H-%M-%S)"
mkdir -p "$BACK"

echo -e "${Y}• Backing up files...${N}"
[[ -f "$MAIN_PY" ]] && cp -a "$MAIN_PY" "$BACK/main.py.$TS.bak"
[[ -f "$MAIN_JS" ]] && cp -a "$MAIN_JS" "$BACK/main.js.$TS.bak"

# 1) Patch API CORS (use env to pass path safely into Python)
echo -e "${Y}• Patching API CORS…${N}"
MAIN_PY_ENV="$MAIN_PY" python3 - <<'PY'
import os, re
from pathlib import Path

p = Path(os.environ["MAIN_PY_ENV"])
s = p.read_text(encoding="utf-8")

# Ensure CORSMiddleware import
if "from fastapi.middleware.cors import CORSMiddleware" not in s:
    if "from fastapi import FastAPI" in s:
        s = s.replace(
            "from fastapi import FastAPI",
            "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware",
            1
        )
    else:
        s = "from fastapi.middleware.cors import CORSMiddleware\n" + s

# Ensure middleware block (once)
if "app.add_middleware(CORSMiddleware" not in s:
    m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", s, flags=re.S)
    if not m:
        raise SystemExit("Couldn't find FastAPI() instantiation in main.py")
    insert_at = m.end()
    block = """
\n# --- injected CORS (idempotent) ---
origins = ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,  # Bearer tokens only
    allow_methods=["*"],
    allow_headers=["*"],
)
# --- end injected CORS ---
"""
    s = s[:insert_at] + block + s[insert_at:]
p.write_text(s, encoding="utf-8")
print("OK")
PY

# 2) Ensure UI helpers (go, $, $$, authFetch) – refresh the PRELUDE block safely
echo -e "${Y}• Ensuring UI prelude (go, $, $$, authFetch)…${N}"
mkdir -p "$WEB_DIR"
touch "$MAIN_JS"

# Strip any previous PRELUDE block completely
if grep -q "/* PRELUDE_INSERT */" "$MAIN_JS"; then
  awk '
    BEGIN{skip=0}
    /\/\* PRELUDE_INSERT \*\//{skip=1}
    /\/\* END_PRELUDE_INSERT \*\//{skip=0; next}
    skip==0{print}
  ' "$MAIN_JS" > "$MAIN_JS.tmp" && mv "$MAIN_JS.tmp" "$MAIN_JS"
fi

# Prepend a clean prelude (idempotent guards inside)
TMP="$(mktemp)"
cat > "$TMP" <<'JS'
/* PRELUDE_INSERT */
;(()=>{

  // Minimal selector helpers
  if(!window.$){ window.$ = (s)=>document.querySelector(s); }
  if(!window.$$){ window.$$ = (s)=>Array.from(document.querySelectorAll(s)); }

  // Async guard runner used across views
  if(typeof window.go!=='function'){
    window.go = async (fn)=>{
      try { await fn(); }
      catch(e){ console.error(e); alert(e?.message || 'Unexpected error'); }
    };
  }

  // Token getter/setter
  if(!window.getToken){
    window.getToken = ()=> localStorage.getItem('TOKEN') || '';
    window.setToken = (t)=> localStorage.setItem('TOKEN', t||'');
  }

  // Robust auth fetch with CORS & JSON handling
  if(typeof window.authFetch!=='function'){
    window.authFetch = async (url, opts={})=>{
      const token = getToken();
      const headers = Object.assign({}, opts.headers||{});
      if(!(opts.body instanceof FormData) && !headers['Content-Type']){
        headers['Content-Type'] = 'application/json';
      }
      if(token) headers['Authorization'] = `Bearer ${token}`;
      const res = await fetch(url, { mode:'cors', credentials:'omit', ...opts, headers });
      if(!res.ok){
        const txt = await res.text().catch(()=> '');
        const err = new Error(`${res.status} ${txt || res.statusText}`);
        err.status = res.status; err.body = txt;
        throw err;
      }
      const ct = res.headers.get('content-type') || '';
      return ct.includes('application/json') ? res.json() : res.text();
    };
  }

  // Login with Enter inside password field
  document.addEventListener('keydown', (e)=>{
    if(e.key === 'Enter'){
      const pwd = document.querySelector('#password');
      const btn = document.querySelector('#login-btn');
      if(pwd && btn && !getToken()){ btn.click(); }
    }
  });

})();
 /* END_PRELUDE_INSERT */
JS

cat "$TMP" "$MAIN_JS" > "$MAIN_JS.new" && mv "$MAIN_JS.new" "$MAIN_JS"
rm -f "$TMP"
echo -e "${G}  - Prelude refreshed${N}"

# 3) Rebuild & restart api + web
echo -e "${Y}• Rebuilding containers (api, web)…${N}"
docker compose -f "$COMPOSE" build api web
docker compose -f "$COMPOSE" up -d api web

# 4) Verify CORS quickly
IP="$(hostname -I | awk '{print $1}')"
echo -e "${Y}• Verifying CORS header on GET /openapi.json…${N}"
if curl -sSI -H "Origin: http://$IP:5183" "http://$IP:8010/openapi.json" | grep -qi 'access-control-allow-origin: *\*'; then
  echo -e "${G}  - CORS OK (Access-Control-Allow-Origin: *)${N}"
else
  echo -e "${R}  - CORS header NOT seen. Check api logs.${N}"
fi

echo -e "${G}✔ Done. Backups in: $BACK${N}"
echo -e "${Y}Tip:${N} hard-refresh the UI (Ctrl/Cmd+Shift+R) to pick up the new prelude."
