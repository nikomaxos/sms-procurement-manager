/* PRELUDE_AUTH_MARKER */
window.API_BASE = window.API_BASE || (localStorage.getItem('API_BASE') || location.origin.replace(':5183', ':8010'));
window.go = window.go || (fn => Promise.resolve(fn()).catch(console.error));

window.authFetch = window.authFetch || (async (url, opts={})=>{
  opts.headers = opts.headers || {};
  const t = localStorage.getItem('access_token');
  if (t) opts.headers['Authorization'] = 'Bearer ' + t;
  if (opts.body && typeof opts.body === 'object' && !(opts.body instanceof FormData)) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(opts.body);
  }
  const r = await fetch(url, opts);
  if (r.status === 401) { ensureLoginUI(); throw new Error('Unauthorized'); }
  if (!r.ok) {
    const tt = await r.text().catch(()=>r.statusText);
    throw new Error(tt || r.statusText);
  }
  const ct = r.headers.get('content-type') || '';
  return ct.includes('application/json') ? r.json() : r.text();
});

function ensureLoginUI(){
  if (document.getElementById('login-overlay')) return;
  const div = document.createElement('div');
  div.id = 'login-overlay';
  div.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:9999;';
  div.innerHTML = `
    <div style="background:#1e2328;color:#f5efe6;min-width:320px;max-width:420px;width:92%;padding:18px;border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.4);font-family:system-ui,Segoe UI,Roboto">
      <h2 style="margin:0 0 12px 0;font-size:20px;">Sign in</h2>
      <label style="display:block;margin:.4rem 0 .2rem">Username</label>
      <input id="login-user" style="width:100%;padding:10px;border-radius:8px;border:1px solid #39424c;background:#11161a;color:#f5efe6" value="admin">
      <label style="display:block;margin:.8rem 0 .2rem">Password</label>
      <input id="login-pass" type="password" style="width:100%;padding:10px;border-radius:8px;border:1px solid #39424c;background:#11161a;color:#f5efe6" value="admin123">
      <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px">
        <button id="login-cancel" style="padding:8px 12px;border:0;border-radius:10px;background:#3a3f45;color:#eee;cursor:pointer">Cancel</button>
        <button id="login-btn" style="padding:8px 12px;border:0;border-radius:10px;background:#c96f1a;color:#fff;cursor:pointer">Login</button>
      </div>
      <div id="login-msg" style="margin-top:8px;font-size:12px;color:#ffb4a2;display:none"></div>
    </div>`;
  document.body.appendChild(div);
  const u = div.querySelector('#login-user');
  const p = div.querySelector('#login-pass');
  const b = div.querySelector('#login-btn');
  const c = div.querySelector('#login-cancel');
  const m = div.querySelector('#login-msg');

  async function doLogin(){
    try{
      m.style.display='none';
      const res = await fetch(API_BASE + '/users/login', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({username:u.value.trim(), password:p.value})
      });
      if(!res.ok){ throw new Error(await res.text()); }
      const j = await res.json();
      if(!j.access_token) throw new Error('No token in response');
      localStorage.setItem('access_token', j.access_token);
      document.body.removeChild(div);
      location.reload();
    }catch(e){ m.textContent='Login failed: '+(e && e.message || e); m.style.display='block'; }
  }
  b.onclick = doLogin;
  c.onclick = ()=>document.body.removeChild(div);
  p.addEventListener('keydown', (ev)=>{ if(ev.key==='Enter'){ ev.preventDefault(); doLogin(); }});
}
document.addEventListener('keydown', (ev)=>{ if((ev.ctrlKey||ev.metaKey) && ev.key.toLowerCase()==='l'){ ev.preventDefault(); ensureLoginUI(); }});
/* END PRELUDE_AUTH_MARKER */
