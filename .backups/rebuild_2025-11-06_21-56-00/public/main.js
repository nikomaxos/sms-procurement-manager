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

/* == PRELUDE START (idempotent) == */
(function(){
  if (window.__PRELUDE__) return;
  window.__PRELUDE__ = true;

  window.$  = (s)=>document.querySelector(s);
  window.$$ = (s)=>Array.from(document.querySelectorAll(s));

  window.el = function(tag, attrs, ...kids){
    const n = document.createElement(tag);
    if (attrs) for (const [k,v] of Object.entries(attrs)) {
      if (k === 'class') n.className = v;
      else if (k.startsWith('on') && typeof v === 'function') n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    for (const k of kids) n.append(k && k.nodeType ? k : (k ?? ''));
    return n;
  };

  window.btn = function(text, color, onclick){
    const b = el('button', { class: 'btn ' + (color||'') }, text);
    if (onclick) b.addEventListener('click', onclick);
    return b;
  };

  window.go = function(fn){ Promise.resolve().then(fn).catch(e => console.error(e)); };

  window.authFetch = async function(url, opts){
    opts = opts || {};
    const headers = opts.headers ? {...opts.headers} : {};
    if (!headers['Content-Type'] && !(opts.body instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
    }
    const tok = localStorage.getItem('token');
    if (tok) headers['Authorization'] = 'Bearer ' + tok;
    const res = await fetch(url, {...opts, headers});
    if (!res.ok) {
      const txt = await res.text().catch(()=>'');
      throw new Error(res.status + ' ' + txt);
    }
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : res.text();
  };

  // Enter-to-Login convenience (tries common selectors)
  document.addEventListener('keydown', (e)=>{
    if (e.key === 'Enter') {
      const loginBtn = document.querySelector('[data-action="login"], #loginBtn, button.login');
      if (loginBtn) loginBtn.click();
    }
  });
})();
 /* == PRELUDE END == */
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
const $ = s=>document.querySelector(s);
const el = (t, attrs={}, ...kids)=>{ const x=document.createElement(t); for(const k in attrs){ if(attrs[k]!==null) x.setAttribute(k, attrs[k]); } kids.flat().forEach(k=>x.append(k.nodeType? k : document.createTextNode(k))); return x; };

let TOKEN = localStorage.getItem('TOKEN') || '';

async function authFetch(url, opt={}){
  opt.headers = Object.assign({'Content-Type':'application/json'}, opt.headers||{});
  if (TOKEN) opt.headers['Authorization'] = 'Bearer '+TOKEN;
  const resp = await fetch(url, opt);
  if (!resp.ok){
    const text = await resp.text().catch(()=> '');
    throw new Error(`${resp.status} ${text || resp.statusText}`);
  }
  const ct = resp.headers.get('content-type') || '';
  return ct.includes('application/json') ? resp.json() : resp.text();
}

function loginView(){
  const page = el('div',{class:'page'},
    el('div',{class:'card'},
      el('h2',{},'Login'),
      el('label',{},'API Base'), el('input',{id:'api',value:window.API_BASE,style:"width:100%"}),
      el('label',{},'Username'), el('input',{id:'u',value:'admin',style:"width:100%"}),
      el('label',{},'Password'), el('input',{id:'p',type:'password',value:'admin123',style:"width:100%"}),
      el('div',{style:"margin-top:8px;display:flex;gap:8px"},
        el('button',{class:'btn blue', id:'loginBtn'},'Login')
      )
    )
  );
  $('#app').innerHTML = ''; $('#app').append(page);
  $('#loginBtn').onclick = doLogin;
  $('#p').addEventListener('keydown', (e)=>{ if(e.key==='Enter') doLogin(); });
}

async function doLogin(){
  window.API_BASE = $('#api').value || window.API_BASE;
  localStorage.setItem('API_BASE', window.API_BASE);
  const form = new URLSearchParams();
  form.set('username', $('#u').value);
  form.set('password', $('#p').value);
  try{
    const data = await fetch(window.API_BASE+'/users/login',{method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:form});
    if(!data.ok){ alert('Login failed'); return; }
    const tok = await data.json();
    TOKEN = tok.access_token; localStorage.setItem('TOKEN', TOKEN);
    render(); // go home
  }catch(e){ alert(e.message); }
}

function ensureNav(){
  $('#btnTrends').onclick = viewTrends;
  $('#btnOffers').onclick = viewOffers;
  $('#btnSuppliers').onclick = viewSuppliers;
  $('#btnCountries').onclick = viewCountries;
  $('#btnNetworks').onclick = viewNetworks;
  $('#btnParsers').onclick = viewParsers;
  $('#btnSettings').onclick = viewSettings;
  $('#userbox').innerHTML = TOKEN ? 'User: admin ' : '';
  if (TOKEN){
    const lo = el('button',{class:'btn red',style:'margin-left:8px'},'Logout');
    lo.onclick = ()=>{ TOKEN=''; localStorage.removeItem('TOKEN'); render(); };
    $('#userbox').append(lo);
  }
}

async function viewTrends(){
  try{
    const today = new Date().toISOString().slice(0,10);
    const res = await authFetch(window.API_BASE+'/metrics/trends?d='+today);
    const card = el('div',{class:'card'}, el('h2',{},'Market trends (top networks)'),
      el('pre',{}, JSON.stringify(res.buckets, null, 2)));
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Trends error: '+e.message); }
}

async function listSimple(path){
  return authFetch(window.API_BASE+path);
}

async function viewOffers(){
  try{
    const data = await authFetch(window.API_BASE+'/offers/?limit=50&offset=0');
    const rows = data.rows || [];
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Supplier'), el('th',{},'Connection'), el('th',{},'Price'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.supplier_name), el('td',{}, r.connection_name), el('td',{}, String(r.price)) )))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Offers'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Offers error: '+e.message); }
}

async function viewSuppliers(){
  try{
    const rows = await listSimple('/suppliers/');
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Organization'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.organization_name))))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Suppliers'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Suppliers error: '+e.message); }
}

async function viewCountries(){
  try{
    const rows = await listSimple('/countries/');
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Name'), el('th',{},'MCC'), el('th',{},'MCC2'), el('th',{},'MCC3'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.name), el('td',{}, r.mcc||''), el('td',{}, r.mcc2||''), el('td',{}, r.mcc3||''))))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Countries'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Countries error: '+e.message); }
}

async function viewNetworks(){
  try{
    const rows = await listSimple('/networks/');
    const table = el('table',{class:'table'},
      el('thead',{}, el('tr',{}, el('th',{},'ID'), el('th',{},'Name'), el('th',{},'Country ID'), el('th',{},'MNC'), el('th',{},'MCC-MNC'))),
      el('tbody',{}, rows.map(r=> el('tr',{}, el('td',{}, r.id), el('td',{}, r.name), el('td',{}, r.country_id||''), el('td',{}, r.mnc||''), el('td',{}, r.mccmnc||''))))
    );
    const card = el('div',{class:'card'}, el('h2',{},'Networks'), table);
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Networks error: '+e.message); }
}

async function viewParsers(){
  try{
    const res = await listSimple('/parsers/');
    const card = el('div',{class:'card'}, el('h2',{},'Parsers (WYSIWYG planned)'), el('pre',{}, JSON.stringify(res,null,2)));
    $('#app').innerHTML=''; $('#app').append(card);
  }catch(e){ alert('Parsers error: '+e.message); }
}



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



function render(){
  ensureNav();
  if (!TOKEN) return loginView();
  viewTrends();
}
document.addEventListener('DOMContentLoaded', render);


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


// --- LOGIN PATCH (idempotent) ---
(function(){
  if (window.__LOGIN_PATCH_APPLIED__) return;
  window.__LOGIN_PATCH_APPLIED__ = true;

  function pickToken(obj){
    if (!obj || typeof obj !== 'object') return null;
    return obj.access_token || obj.token || obj.jwt || (obj.data && (obj.data.access_token || obj.data.token));
  }
  window.__pickToken = pickToken;

  async function postJSON(url, data){
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type':'application/json',
        'Accept':'application/json'
      },
      body: JSON.stringify(data)
    });
    let json = null;
    try { json = await res.json(); } catch(e){ /* ignore */ }
    return { ok: res.ok, status: res.status, json, headers: res.headers };
  }

  async function doLoginPatched(){
    const u = document.querySelector('#login-username')?.value?.trim();
    const p = document.querySelector('#login-password')?.value ?? '';
    const base = (window.API_BASE) || (location.origin.replace(':5183', ':8010'));
    const url = base + '/users/login';
    const r = await postJSON(url, {username:u, password:p});
    if (!r.ok) {
      throw new Error('Login failed: ' + r.status + ' ' + JSON.stringify(r.json || {}));
    }
    const t = pickToken(r.json);
    if (!t) throw new Error('Invalid token response');
    localStorage.setItem('TOKEN', t);
    window.TOKEN = t;
    // Optional toast
    console.log('Login OK');
    // Simple reload to let the app pick the token
    location.reload();
  }

  // Rebind login button every 1s (in case SPA re-renders)
  setInterval(() => {
    const btn = document.querySelector('#login-btn') || document.querySelector('[data-login-btn]') || document.querySelector('button.login');
    if (btn && !btn.__loginBound) {
      btn.__loginBound = true;
      btn.onclick = (e)=>{ e.preventDefault(); doLoginPatched().catch(e=>console.error(e)); };
    }
    const pwd = document.querySelector('#login-password');
    if (pwd && !pwd.__enterBound) {
      pwd.__enterBound = true;
      pwd.addEventListener('keydown', (ev)=>{
        if (ev.key === 'Enter') { ev.preventDefault(); doLoginPatched().catch(e=>console.error(e)); }
      });
    }
  }, 1000);

  // Ensure authFetch uses Bearer
  if (!window.authFetch) {
    window.authFetch = async function(url, init={}){
      const t = localStorage.getItem('TOKEN');
      init.headers = init.headers || {};
      if (t) init.headers['Authorization'] = 'Bearer ' + t;
      const r = await fetch(url, init);
      if (r.status === 401) {
        console.warn('401 → clearing token');
        localStorage.removeItem('TOKEN'); window.TOKEN = null;
      }
      return r.json().catch(()=> ({}));
    };
  }
})();

// ===== LOGIN ROOT-CAUSE PATCH (idempotent) =====
(function(){
  if (window.__LOGIN_ROOT_PATCH__) return; window.__LOGIN_ROOT_PATCH__=true;
  const apiBase = ()=> (window.API_BASE || location.origin.replace(':5183', ':8010'));

  async function postJSON(url, body){
    const r = await fetch(url, {
      method: 'POST',
      headers: {'Content-Type':'application/json', 'Accept':'application/json'},
      body: JSON.stringify(body||{})
    });
    const txt = await r.text();
    let json = {}; try { json = txt ? JSON.parse(txt) : {}; } catch(e){}
    return {ok:r.ok, status:r.status, json, raw:r};
  }

  function pickToken(j){ return j && (j.access_token || j.token || j.jwt || (j.data && (j.data.access_token||j.data.token))); }

  async function doLoginPatched(){
    const u = (document.querySelector('#login-username, #username, input[name="username"]')||{}).value?.trim();
    const p = (document.querySelector('#login-password, #password, input[name="password"]')||{}).value ?? '';
    if(!u || !p){ alert('Type username & password'); return; }
    const {ok,status,json} = await postJSON(apiBase()+'/users/login', {username:u, password:p});
    if(!ok){ console.error('Login failed', status, json); alert('Login failed: '+status); return; }
    const t = pickToken(json);
    if(!t){ console.error('Invalid token response', json); alert('Invalid token response'); return; }
    localStorage.setItem('TOKEN', t); window.TOKEN=t;
    location.reload();
  }

  if (!window.doLogin) window.doLogin = doLoginPatched;

  // Bind button + Enter on password defensively
  setInterval(()=>{
    const btn = document.querySelector('#login-btn, button.login, [data-login-btn]');
    if(btn && !btn.__bound){ btn.__bound=true; btn.addEventListener('click', (e)=>{e.preventDefault(); window.doLogin();}); }
    const pw = document.querySelector('#login-password, #password, input[name="password"]');
    if(pw && !pw.__enter){ pw.__enter=true; pw.addEventListener('keydown', (e)=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); } }); }
  }, 800);

  // authFetch that preserves caller expectations (JSON on success; throws on !ok)
  if (!window.authFetch){
    window.authFetch = async function(url, init={}){
      const t = localStorage.getItem('TOKEN');
      init.headers = init.headers || {};
      if (t) init.headers['Authorization'] = 'Bearer '+t;
      const r = await fetch(url, init);
      if (r.status === 401){ localStorage.removeItem('TOKEN'); }
      if (!r.ok){ const j = await r.text(); throw new Error(r.status+' '+j); }
      const ct = r.headers.get('content-type')||'';
      if (ct.includes('application/json')) return r.json();
      return r.text();
    };
  }

  // Provide go() if missing so views using it won't error
  if (!window.go) window.go = (fn)=>Promise.resolve().then(fn).catch(console.error);
})();
