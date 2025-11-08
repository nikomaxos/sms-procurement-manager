#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
MAIN_JS="$WEB/main.js"
ENV_JS="$WEB/env.js"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/restore_login_overlay_and_401_$TS"
mkdir -p "$BACK"

echo -e "${Y}• Backing up UI files to ${BACK}${N}"
[[ -f "$MAIN_JS" ]] && cp -a "$MAIN_JS" "$BACK/main.js.bak" || true
[[ -f "$ENV_JS"  ]] && cp -a "$ENV_JS"  "$BACK/env.js.bak"  || true

# 1) Ensure env.js (lets UI find the API if user hasn’t set API_BASE)
mkdir -p "$WEB"
if [[ ! -f "$ENV_JS" ]]; then
  cat > "$ENV_JS" <<'JS'
(function(){
  const saved = localStorage.getItem('API_BASE');
  window.API_BASE = saved || (location.origin.replace(':5183', ':8010'));
})();
JS
  echo -e "${G}✔ env.js written${N}"
fi

# 2) Prepare prelude (idempotent) to guarantee $, $$, go, authFetch + 401 handler
PRELUDE_MARK="/* == PRELUDE START (auth+utils) == */"
PRELUDE_SNIP='
/* == PRELUDE START (auth+utils) == */
(function(){
  if (window.__AUTH_PRELUDE__) return; window.__AUTH_PRELUDE__ = true;

  window.$  = window.$  || (s=>document.querySelector(s));
  window.$$ = window.$$ || (s=>Array.from(document.querySelectorAll(s)));

  window.go = window.go || function(fn){ Promise.resolve().then(fn).catch(e=>console.error(e)); };

  // Central auth fetch with 401 handling (forces login overlay)
  window.authFetch = async function(url, opts){
    opts = opts || {};
    const headers = opts.headers ? {...opts.headers} : {};
    if (!headers["Content-Type"] && !(opts.body instanceof FormData)) headers["Content-Type"]="application/json";
    const tok = localStorage.getItem("token");
    if (tok) headers["Authorization"] = "Bearer " + tok;
    const res = await fetch(url, {...opts, headers});
    if (res.status === 401) {
      try { await res.text(); } catch(e){}
      localStorage.removeItem("token");
      if (window.showLoginOverlay) window.showLoginOverlay("Session expired. Please sign in again.");
      throw new Error("401 Unauthorized");
    }
    if (!res.ok) {
      const txt = await res.text().catch(()=>String(res.status));
      throw new Error(res.status + " " + txt);
    }
    const ct = (res.headers.get("content-type")||"");
    return ct.includes("application/json") ? res.json() : res.text();
  };

  // Warm minimal theme (readable defaults)
  (function injectTheme(){
    if (document.getElementById("warm-theme")) return;
    const s = document.createElement("style");
    s.id = "warm-theme";
    s.textContent = `
      :root{
        --bg:#1f1a17; --panel:#2a2421; --muted:#5a514d; --accent:#d98c3f; --accent-2:#c6722a; --text:#f4e9e2;
      }
      body{ background:var(--bg); color:var(--text); font-family:system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif; }
      .topbar{ background:linear-gradient(180deg, #2f2925, #261f1c); color:var(--text); border-bottom:1px solid #3b332f; }
      .btn{ background:var(--accent); color:#1a120f; border:none; padding:.55rem .9rem; border-radius:10px; cursor:pointer; }
      .btn:hover{ filter:brightness(1.05); }
      .btn.ghost{ background:transparent; color:var(--accent); border:1px solid var(--accent); }
      .card{ background:var(--panel); border:1px solid #3b332f; border-radius:12px; padding:14px; }
      input,select,textarea{ background:#201b18; color:var(--text); border:1px solid #3b332f; border-radius:8px; padding:.5rem .6rem; outline:none; }
      label{ font-size:.92rem; color:#e8d8cf; }
      a{ color:var(--accent); }
    `;
    document.head.appendChild(s);
  })();

  // Lightweight toast
  window.toast = function(msg){
    let t = document.getElementById("toast");
    if (!t) { t = document.createElement("div"); t.id="toast";
      Object.assign(t.style, {position:"fixed",left:"50%",top:"20px",transform:"translateX(-50%)",background:"#000a",color:"#fff",padding:"8px 12px",borderRadius:"8px",zIndex:99999});
      document.body.appendChild(t);
    }
    t.textContent = msg; t.style.opacity="1"; setTimeout(()=>{t.style.opacity="0";}, 2200);
  };
})();
 /* == PRELUDE END == */
'

# 3) Login overlay (idempotent) appended; doesn’t replace your app, only adds a fallback UI for auth
OVERLAY_MARK="/* == LOGIN OVERLAY START == */"
OVERLAY_SNIP='
/* == LOGIN OVERLAY START == */
(function(){
  if (window.__LOGIN_OVERLAY__) return; window.__LOGIN_OVERLAY__ = true;

  function overlayCSS(){
    if (document.getElementById("login-overlay-css")) return;
    const s = document.createElement("style"); s.id="login-overlay-css";
    s.textContent = `
    .login-veil{position:fixed;inset:0;background:#0008;backdrop-filter: blur(4px);display:flex;align-items:center;justify-content:center;z-index:99998;}
    .login-panel{width: min(420px, 92vw); box-shadow: 0 8px 32px #0008;}
    .login-grid{display:grid;grid-template-columns:1fr;gap:10px;margin-top:6px;}
    .row{display:flex;gap:8px;align-items:center;}
    .row label{width:110px}
    `;
    document.head.appendChild(s);
  }

  window.showLoginOverlay = function(message){
    overlayCSS();
    if (document.querySelector(".login-veil")) document.querySelector(".login-veil").remove();

    const veil = document.createElement("div");
    veil.className = "login-veil";
    const panel = document.createElement("div");
    panel.className = "card login-panel";
    panel.innerHTML = `
      <h2 style="margin:0 0 6px 0;">Sign in</h2>
      <div class="muted" style="margin-bottom:8px;color:var(--muted)">${message ? String(message) : "Please authenticate to continue."}</div>
      <div class="login-grid">
        <div class="row"><label>API</label><input id="apiBase" placeholder="http://IP:8010" /></div>
        <div class="row"><label>Username</label><input id="loginUser" placeholder="admin" /></div>
        <div class="row"><label>Password</label><input id="loginPass" type="password" placeholder="••••••••" /></div>
      </div>
      <div style="display:flex;gap:10px;justify-content:flex-end;margin-top:12px;">
        <button class="btn ghost" id="cancelLogin">Cancel</button>
        <button class="btn" id="doLogin" data-action="login">Login</button>
      </div>
    `;
    veil.appendChild(panel);
    document.body.appendChild(veil);

    // Defaults:
    const apiInput = panel.querySelector("#apiBase");
    apiInput.value = (window.API_BASE || localStorage.getItem("API_BASE") || location.origin.replace(":5183", ":8010"));
    const userI   = panel.querySelector("#loginUser");
    const passI   = panel.querySelector("#loginPass");
    userI.value = localStorage.getItem("last_user") || "";

    // Enter to login:
    panel.addEventListener("keydown", (e)=>{ if (e.key==="Enter") panel.querySelector("#doLogin").click(); });

    panel.querySelector("#cancelLogin").onclick = ()=> veil.remove();
    panel.querySelector("#doLogin").onclick = async ()=>{
      const api = apiInput.value.trim().replace(/\/+$/,"");
      const u = userI.value.trim(); const p = passI.value;
      if (!api || !u || !p) { toast("Fill API, username and password"); return; }
      localStorage.setItem("API_BASE", api); window.API_BASE = api;
      try {
        const res = await fetch(api + "/users/login", {
          method: "POST",
          headers: {"Content-Type":"application/json"},
          body: JSON.stringify({username: u, password: p})
        });
        if (!res.ok) { throw new Error((await res.text()) || String(res.status)); }
        const data = await res.json();
        if (!data || !data.access_token) throw new Error("Invalid token response");
        localStorage.setItem("token", data.access_token);
        localStorage.setItem("last_user", u);
        toast("Signed in");
        veil.remove();
        // Try to refresh the current view if your app has a render()
        if (typeof window.render === "function") { window.render(); }
      } catch (e) {
        console.error(e);
        toast("Login failed");
      }
    };
  };

  // If no token on load, show overlay once DOM is ready.
  if (!localStorage.getItem("token")) {
    const fire = ()=> window.showLoginOverlay();
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", fire, {once:true});
    else fire();
  }
})();
 /* == LOGIN OVERLAY END == */
'

# 4) Apply prelude + overlay to main.js (only if not already present)
if [[ ! -f "$MAIN_JS" ]]; then
  echo "/* app main.js placeholder */" > "$MAIN_JS"
fi

if ! grep -qF "$PRELUDE_MARK" "$MAIN_JS"; then
  printf "%s\n" "$PRELUDE_SNIP" | cat - "$MAIN_JS" > "$MAIN_JS.new" && mv "$MAIN_JS.new" "$MAIN_JS"
  echo -e "${G}✔ Prelude inserted at top${N}"
else
  echo -e "${G}✔ Prelude already present (skipped)${N}"
fi

if ! grep -qF "$OVERLAY_MARK" "$MAIN_JS"; then
  printf "\n%s\n" "$OVERLAY_SNIP" >> "$MAIN_JS"
  echo -e "${G}✔ Login overlay appended${N}"
else
  echo -e "${G}✔ Login overlay already present (skipped)${N}"
fi

# 5) Rebuild web (so Nginx serves updated JS) and restart
echo -e "${Y}• Rebuilding web + restarting stack…${N}"
docker compose -f "$COMPOSE" build web
docker compose -f "$COMPOSE" up -d web

# 6) Quick UI reachability
sleep 1
IP=$(hostname -I | awk '{print $1}')
echo -e "${G}UI:${N} http://${IP}:5183"
echo -e "${Y}Tip:${N} If API base is different, set it in the overlay or run in DevTools: localStorage.setItem('API_BASE','http://<host>:8010'); location.reload();"
