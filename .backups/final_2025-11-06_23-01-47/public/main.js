(function(){
  const $ = (s)=>document.querySelector(s);
  const api = ()=> window.API_BASE || location.origin.replace(':5183', ':8010');

  async function postJSON(url, body){
    const r = await fetch(url, {
      method:'POST',
      headers: {'Content-Type':'application/json','Accept':'application/json'},
      body: JSON.stringify(body||{})
    });
    const txt = await r.text(); let json={}; try{ json = txt? JSON.parse(txt):{}; }catch(e){}
    return {ok:r.ok, status:r.status, json, raw:r};
  }
  window.authFetch = async function(url, init={}){
    const t = localStorage.getItem('TOKEN');
    init.headers = Object.assign({'Accept':'application/json'}, init.headers||{});
    if(t) init.headers['Authorization'] = 'Bearer '+t;
    const r = await fetch(url, init);
    if(r.status===401){ localStorage.removeItem('TOKEN'); showLogin(); throw new Error('401 Unauthorized'); }
    if(!r.ok){ const b=await r.text(); throw new Error(r.status+' '+b); }
    const ct = r.headers.get('content-type')||''; return ct.includes('application/json')? r.json(): r.text();
  };

  function showLogin(){
    $('#login-panel').style.display='';
    $('#content').innerHTML='';
    $('#login-error').textContent='';
    $('#login-username')?.focus();
  }
  function showUser(u){
    $('#user-slot').textContent = u && u.username ? (u.username+' ('+(u.role||'')+')') : 'Guest';
  }

  window.doLogin = async function(){
    const u = $('#login-username')?.value?.trim();
    const p = $('#login-password')?.value||'';
    if(!u||!p){ $('#login-error').textContent='Type username & password'; return; }
    const {ok,status,json} = await postJSON(api()+'/users/login', {username:u, password:p});
    if(!ok || !json.access_token){ $('#login-error').textContent = (json?.detail||('Login failed '+status)); return; }
    localStorage.setItem('TOKEN', json.access_token);
    $('#login-panel').style.display='none';
    await init();
  };

  async function viewOffers(){
    const d = await authFetch(api()+'/offers/?limit=50&offset=0');
    $('#content').innerHTML = '<h2>Offers</h2><pre>'+JSON.stringify(d,null,2)+'</pre>';
  }
  async function viewNetworks(){
    const d = await authFetch(api()+'/networks/');
    $('#content').innerHTML = '<h2>Networks</h2><pre>'+JSON.stringify(d,null,2)+'</pre>';
  }
  async function viewParsers(){
    const d = await authFetch(api()+'/parsers/');
    $('#content').innerHTML = '<h2>Parsers</h2><pre>'+JSON.stringify(d,null,2)+'</pre>';
  }
  async function viewSettings(){
    const e = await authFetch(api()+'/conf/enums');
    const im = await authFetch(api()+'/settings/imap');
    const sc = await authFetch(api()+'/settings/scrape');
    $('#content').innerHTML =
      '<h2>Settings</h2>'+
      '<div class="grid two compact">'+
      '<fieldset><legend>Dropdown categories</legend>'+
        '<div class="row"><div>Vendors</div><input placeholder="add vendor"/></div>'+
        '<div class="row"><div>Tags</div><input placeholder="add tag"/></div>'+
      '</fieldset>'+
      '<fieldset><legend>IMAP</legend>'+
        '<div class="row"><div>Server</div><input placeholder="imap.example.com"/></div>'+
        '<div class="row"><div>User</div><input placeholder="user@example.com"/></div>'+
      '</fieldset>'+
      '<fieldset><legend>Scraping</legend>'+
        '<div class="row"><div>Interval</div><input placeholder="*/10 * * * *"/></div>'+
        '<div class="row"><div>Agent</div><input placeholder="Mozilla/5.0"/></div>'+
      '</fieldset>'+
      '</div>';
  }

  async function init(){
    // try get user (if token present)
    let u=null; try { u = await authFetch(api()+'/users/me'); } catch(e){ /* ignore */ }
    showUser(u);
    if(!localStorage.getItem('TOKEN')){ showLogin(); return; }
    // default view
    try { await viewOffers(); } catch(e){ $('#content').textContent = 'Ready.'; }
  }

  // nav wiring
  document.addEventListener('click', (e)=>{
    const v = e.target?.getAttribute?.('data-view');
    if(!v) return;
    e.preventDefault();
    if(v==='offers') return viewOffers();
    if(v==='networks') return viewNetworks();
    if(v==='parsers') return viewParsers();
    if(v==='settings') return viewSettings();
  });
  $('#login-btn')?.addEventListener('click', (e)=>{ e.preventDefault(); window.doLogin(); });
  $('#login-password')?.addEventListener('keydown', (e)=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); }});
  $('#logout')?.addEventListener('click', ()=>{ localStorage.removeItem('TOKEN'); showUser(null); showLogin(); });

  // start
  if(!localStorage.getItem('TOKEN')) showLogin();
  init();
})();
