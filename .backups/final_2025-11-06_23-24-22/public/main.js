(function(){
  const $=s=>document.querySelector(s);
  const API=()=>window.API_BASE||location.origin.replace(':5183',':8010');

  async function postJSON(url, body){
    const r = await fetch(url,{method:'POST',headers:{'Content-Type':'application/json','Accept':'application/json'},body:JSON.stringify(body||{})});
    const txt = await r.text(); let js={}; try{js=txt?JSON.parse(txt):{};}catch(e){}
    return {ok:r.ok, status:r.status, json:js, raw:r};
  }

  window.authFetch = async function(url, init={}){
    const t = localStorage.getItem('TOKEN');
    init.headers = Object.assign({'Accept':'application/json'}, init.headers||{});
    if(t) init.headers['Authorization']='Bearer '+t;
    const r = await fetch(url, init);
    if(r.status===401){ localStorage.removeItem('TOKEN'); showLogin(); throw new Error('401'); }
    if(!r.ok){ throw new Error(r.status+' '+await r.text()); }
    return r.headers.get('content-type')?.includes('application/json')? r.json(): r.text();
  };

  function showLogin(){ $('#login-panel').style.display=''; $('#content').innerHTML=''; $('#login-error').textContent=''; }
  function showUser(u){ $('#user-slot').textContent = u&&u.username ? (u.username+' ('+(u.role||'')+')') : 'Guest'; }

  window.doLogin = async function(){
    const u=$('#login-username').value.trim(), p=$('#login-password').value;
    if(!u||!p){ $('#login-error').textContent='Type username & password'; return; }
    const {ok,status,json} = await postJSON(API()+'/users/login', {username:u,password:p});
    if(!ok || !json.access_token){ $('#login-error').textContent=(json?.detail||('Login failed '+status)); return; }
    localStorage.setItem('TOKEN', json.access_token); $('#login-panel').style.display='none'; await init();
  };

  async function viewOffers(){ $('#content').innerHTML='<h2>Offers</h2><pre>'+JSON.stringify(await authFetch(API()+'/offers/?limit=50&offset=0'),null,2)+'</pre>'; }
  async function viewNetworks(){ $('#content').innerHTML='<h2>Networks</h2><pre>'+JSON.stringify(await authFetch(API()+'/networks/'),null,2)+'</pre>'; }
  async function viewParsers(){ $('#content').innerHTML='<h2>Parsers</h2><pre>'+JSON.stringify(await authFetch(API()+'/parsers/'),null,2)+'</pre>'; }
  async function viewSettings(){
    const e=await authFetch(API()+'/conf/enums');
    const im=await authFetch(API()+'/settings/imap');
    const sc=await authFetch(API()+'/settings/scrape');
    $('#content').innerHTML='<h2>Settings</h2><pre>'+JSON.stringify({e,im,sc},null,2)+'</pre>';
  }

  async function init(){
    let u=null; try{ u=await authFetch(API()+'/users/me'); }catch(e){}
    showUser(u); if(!localStorage.getItem('TOKEN')){ showLogin(); return; }
    try{ await viewOffers(); }catch(e){ $('#content').textContent='Ready.'; }
  }

  document.addEventListener('click', (e)=>{ const v=e.target?.getAttribute?.('data-view'); if(!v) return;
    e.preventDefault(); if(v==='offers') return viewOffers(); if(v==='networks') return viewNetworks(); if(v==='parsers') return viewParsers(); if(v==='settings') return viewSettings();
  });
  $('#login-btn')?.addEventListener('click', (e)=>{ e.preventDefault(); window.doLogin(); });
  $('#login-password')?.addEventListener('keydown',(e)=>{ if(e.key==='Enter'){ e.preventDefault(); window.doLogin(); }});
  $('#logout')?.addEventListener('click', ()=>{ localStorage.removeItem('TOKEN'); showUser(null); showLogin(); });

  if(!localStorage.getItem('TOKEN')) showLogin(); init();
})();
