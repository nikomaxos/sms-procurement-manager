/* global helpers + warm theme + login panel */
(function(){
  if (window.__PRELUDE__) return; window.__PRELUDE__=true;
  const css=`
:root{
  --bg:#f7efe8; --card:#fff9f4; --text:#2a2623;
  --brand:#c26b2b; --brand-2:#8f4f1a; --ok:#2f855a; --warn:#b7791f; --err:#c53030;
}
*{box-sizing:border-box} body{margin:0;font-family:Inter,system-ui,Segoe UI,Roboto,Ubuntu,Arial,sans-serif;background:var(--bg);color:var(--text)}
.nav{display:flex;gap:.5rem;padding:.6rem .8rem;background:linear-gradient(180deg,#fff6,#fff0),var(--card);position:sticky;top:0;border-bottom:1px solid #0001}
.btn{padding:.55rem .9rem;border-radius:.6rem;border:0;cursor:pointer;margin:.15rem;background:var(--brand);color:#fff}
.btn.green{background:var(--ok)} .btn.yellow{background:#d69e2e} .btn.red{background:#e53e3e}
.card{max-width:520px;margin:8vh auto;background:var(--card);border-radius:12px;padding:20px;box-shadow:0 6px 28px rgba(0,0,0,.10);border:1px solid #0001}
label{display:block;margin:.55rem 0 .25rem;font-weight:600}
input{width:100%;padding:.55rem .6rem;border:1px solid #0002;border-radius:.5rem;background:#fff}
`;
  const st=document.createElement('style'); st.textContent=css; document.head.appendChild(st);

  window.$=(s)=>document.querySelector(s);
  window.$$=(s)=>Array.from(document.querySelectorAll(s));
  window.el=function(t,a,...k){const n=document.createElement(t);if(a)for(const [k2,v] of Object.entries(a)){if(k2==='class')n.className=v;else if(k2.startsWith('on')&&typeof v==='function')n.addEventListener(k2.slice(2),v);else n.setAttribute(k2,v)};for(const x of k)n.append(x&&x.nodeType?x:(x??''));return n};
  window.btn=(t,c,cb)=>{const b=el('button',{class:'btn '+(c||'')},t); if(cb)b.onclick=cb; return b;};
  window.go=(fn)=>Promise.resolve().then(fn).catch(console.error);

  window.authFetch=async (url,opts={})=>{
    const headers=opts.headers?{...opts.headers}:{};
    if(!headers['Content-Type'] && !(opts.body instanceof FormData)) headers['Content-Type']='application/json';
    const tok=localStorage.getItem('token'); if(tok) headers['Authorization']='Bearer '+tok;
    const res=await fetch(url,{...opts,headers});
    if(res.status===401){ localStorage.removeItem('token'); try{ window.showLogin(); }catch(_){}; throw new Error('401'); }
    if(!res.ok){ const txt=await res.text().catch(()=> ''); throw new Error(res.status+' '+txt); }
    const ct=res.headers.get('content-type')||''; return ct.includes('application/json')?res.json():res.text();
  };

  window.showLogin=function(){
    const app=document.getElementById('app')||document.body; app.innerHTML='';
    const p=el('div',{class:'card'},
      el('h2',null,'Login'),
      el('label',null,'Username'),
      el('input',{id:'loginUser',type:'text',placeholder:'admin'}),
      el('label',null,'Password'),
      el('input',{id:'loginPass',type:'password',placeholder:'••••••'}),
      btn('Login','green', async ()=>{
        const u=$('#loginUser')?.value?.trim(); const pw=$('#loginPass')?.value||'';
        if(!u||!pw){ alert('Enter username & password'); return; }
        const r=await window.authFetch((window.API_BASE||'')+'/users/login',{method:'POST',body:JSON.stringify({username:u,password:pw})});
        if(r && r.access_token){ localStorage.setItem('token',r.access_token); location.reload(); } else alert('Login failed');
      })
    );
    app.append(p);
    const pass=$('#loginPass'); if(pass){ pass.addEventListener('keydown',ev=>{ if(ev.key==='Enter') p.querySelector('button')?.click(); }); }
  };

  // auto-show login if no token
  if(!localStorage.getItem('token')) setTimeout(()=>window.showLogin(),0);
})();
