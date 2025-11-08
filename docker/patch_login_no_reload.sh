#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
WEB="$ROOT/web/public"
API_BASE_URL="${API_BASE_URL:-http://localhost:8010}"

# 1) Overwrite main.js with a safer login flow (no reload, clear messages, verify token)
cat > "$WEB/main.js" <<'JS'
const $ = (sel)=>document.querySelector(sel);
const tokenKey = 'SPM_TOKEN';
const apiKey = 'API_BASE';

let API_BASE = localStorage.getItem(apiKey) || 'http://localhost:8010';
let TOKEN    = localStorage.getItem(tokenKey) || '';

$('#apiBase').textContent = API_BASE;
$('#apiInput').value = API_BASE;

function setMsg(t){ $('#loginMsg').textContent = t; }
function navActivate(view){
  document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('active',b.dataset.view===view));
}
function renderFilters(html){ $('#filters').innerHTML = html; }
function renderView(html){ $('#view').innerHTML = html; }

async function authFetch(path, opts={}){
  const url = API_BASE.replace(/\/$/,'') + path;
  const headers = opts.headers || {};
  if (TOKEN) headers['Authorization'] = 'Bearer '+TOKEN;
  if (opts.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
  opts.headers = headers;
  const r = await fetch(url, opts);
  if (!r.ok) {
    const txt = await r.text().catch(()=>String(r.status));
    throw new Error(`${r.status} ${txt}`);
  }
  const ct = r.headers.get('content-type') || '';
  return ct.includes('application/json') ? r.json() : r.text();
}

async function verifyToken() {
  if (!TOKEN) return false;
  try {
    await authFetch('/users/me');
    return true;
  } catch (e) {
    localStorage.removeItem(tokenKey);
    TOKEN = '';
    return false;
  }
}

$('#loginBtn').onclick = async ()=>{
  // Never reload here; update API base if changed and try to login immediately
  API_BASE = ($('#apiInput').value.trim() || API_BASE);
  localStorage.setItem(apiKey, API_BASE);
  $('#apiBase').textContent = API_BASE;

  setMsg('Logging in…');
  try{
    const form = new URLSearchParams();
    form.append('username',$('#user').value);
    form.append('password',$('#pass').value);
    const r = await fetch(API_BASE.replace(/\/$/,'') + '/users/login', {
      method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body: form
    });
    if(!r.ok){
      const txt = await r.text();
      setMsg(`Login failed: ${txt}`);
      return;
    }
    const j = await r.json();
    TOKEN = j.access_token;
    localStorage.setItem(tokenKey, TOKEN);
    $('#userName').textContent = $('#user').value || 'admin';
    setMsg('OK');
    await render();  // go to default view
  }catch(e){
    setMsg('Network error: ' + e.message);
  }
};

async function firstMount(){
  $('#apiBase').textContent = API_BASE;
  if (await verifyToken()) {
    $('#userName').textContent = $('#user').value || 'admin';
    await render();
  } else {
    $('#userName').textContent = '-';
    setMsg('Not logged in');
  }
}

/* ====== VIEWS (same as before; full CRUD) ====== */
/* Suppliers + Connections (expand/collapse) */
async function viewSuppliers(){
  navActivate('suppliers');
  renderFilters(`
    <input id="q" placeholder="Search supplier...">
    <button id="fBtn">Filter</button>
    <input id="newName" placeholder="New supplier name">
    <button id="cBtn">Create</button>
  `);
  $('#fBtn').onclick = renderSuppliers;
  $('#cBtn').onclick = async ()=>{
    const name = $('#newName').value.trim(); if(!name) return;
    await authFetch('/suppliers/', {method:'POST', body: JSON.stringify({organization_name:name})});
    $('#newName').value=''; await renderSuppliers();
  };
  await renderSuppliers();
}
async function renderSuppliers(){
  const q = $('#q').value?.trim();
  const list = await authFetch('/suppliers/'+(q?`?q=${encodeURIComponent(q)}`:''));
  renderView(`<div class="card">
    ${list.map(s=>`
      <details>
        <summary><b>${s.organization_name}</b>
          <span class="muted"> • expand for connections • </span>
          <span class="actions">
            <button data-act="del" data-name="${s.organization_name}">Delete</button>
          </span>
        </summary>
        <div class="row" style="margin:6px 0">
          <input placeholder="Rename to..." id="rn-${s.id}">
          <button data-act="rename" data-id="${s.id}" data-name="${s.organization_name}">Rename</button>
        </div>
        <div id="conns-${s.id}" class="card"></div>
      </details>
    `).join('')}
  </div>`);
  // wire supplier actions
  $('#view').querySelectorAll('button[data-act="del"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete supplier?')) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.name)}`,{method:'DELETE'});
      await renderSuppliers();
    };
  });
  $('#view').querySelectorAll('button[data-act="rename"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const val = document.querySelector(`#rn-${btn.dataset.id}`).value.trim(); if(!val) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.name)}`,{method:'PUT', body: JSON.stringify({organization_name:val})});
      await renderSuppliers();
    };
  });
  // load connections panels
  for(const s of list){ await renderConnections(s); }
}

async function renderConnections(supplier){
  const host = `#conns-${supplier.id}`;
  const box = document.querySelector(host); if(!box) return;
  const list = await authFetch(`/suppliers/${encodeURIComponent(supplier.organization_name)}/connections/`);
  box.innerHTML = `
    <div class="row">
      <input id="cname-${supplier.id}" placeholder="Connection name">
      <input id="user-${supplier.id}" placeholder="Kannel username">
      <input id="smsc-${supplier.id}" placeholder="Kannel SMSc">
      <label><input type="checkbox" id="perdel-${supplier.id}"> Per Delivered</label>
      <select id="charge-${supplier.id}">
        <option>Per Submitted</option><option>Per Delivered</option>
      </select>
      <button id="addc-${supplier.id}">Add</button>
    </div>
    <table>
      <thead><tr><th>Name</th><th>Username</th><th>SMSc</th><th>Per Delivered</th><th>Charge Model</th><th></th></tr></thead>
      <tbody>${list.map(c=>`
        <tr>
          <td>${c.connection_name}</td>
          <td>${c.username||''}</td>
          <td>${c.kannel_smsc||''}</td>
          <td>${c.per_delivered?'Yes':'No'}</td>
          <td>${c.charge_model||''}</td>
          <td class="actions">
            <button data-act="cedit" data-s="${supplier.organization_name}" data-n="${c.connection_name}">Edit</button>
            <button data-act="cdel" data-s="${supplier.organization_name}" data-n="${c.connection_name}">Delete</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  document.querySelector(`#addc-${supplier.id}`).onclick = async ()=>{
    const body = {
      connection_name: document.querySelector(`#cname-${supplier.id}`).value.trim(),
      username:        document.querySelector(`#user-${supplier.id}`).value.trim(),
      kannel_smsc:     document.querySelector(`#smsc-${supplier.id}`).value.trim(),
      per_delivered:   document.querySelector(`#perdel-${supplier.id}`).checked,
      charge_model:    document.querySelector(`#charge-${supplier.id}`).value
    };
    if(!body.connection_name) return;
    await authFetch(`/suppliers/${encodeURIComponent(supplier.organization_name)}/connections/`, {method:'POST', body: JSON.stringify(body)});
    await renderConnections(supplier);
  };
  box.querySelectorAll('button[data-act="cdel"]').forEach(btn=>{
    btn.onclick = async ()=>{
      if(!confirm('Delete connection?')) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.s)}/connections/${encodeURIComponent(btn.dataset.n)}`, {method:'DELETE'});
      await renderConnections(supplier);
    };
  });
  box.querySelectorAll('button[data-act="cedit"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('New connection name', btn.dataset.n); if(!newName) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.s)}/connections/${encodeURIComponent(btn.dataset.n)}`, {
        method:'PUT', body: JSON.stringify({connection_name:newName})
      });
      await renderConnections(supplier);
    };
  });
}

/* Countries */
async function viewCountries(){
  navActivate('countries');
  renderFilters(`
    <input id="cq" placeholder="Search country...">
    <button id="cF">Filter</button>
    <input id="cName" placeholder="Name">
    <input id="cMcc" placeholder="MCC">
    <button id="cCreate">Create</button>
  `);
  document.querySelector('#cF').onclick = renderCountries;
  document.querySelector('#cCreate').onclick = async ()=>{
    const name=document.querySelector('#cName').value.trim(); if(!name) return;
    await authFetch('/countries/',{method:'POST',body:JSON.stringify({name, mcc:document.querySelector('#cMcc').value.trim()||null})});
    document.querySelector('#cName').value=''; document.querySelector('#cMcc').value=''; await renderCountries();
  };
  await renderCountries();
}
async function renderCountries(){
  const q = document.querySelector('#cq').value.trim();
  const list = await authFetch('/countries/'+(q?`?q=${encodeURIComponent(q)}`:''));
  renderView(`<div class="card">
    <table><thead><tr><th>Name</th><th>MCC</th><th></th></tr></thead>
    <tbody>${list.map(c=>`
      <tr>
        <td>${c.name}</td><td>${c.mcc||''}</td>
        <td class="actions">
          <button data-act="edit" data-name="${c.name}">Edit</button>
          <button data-act="del" data-name="${c.name}">Delete</button>
        </td>
      </tr>`).join('')}
    </tbody></table>
  </div>`);
  document.querySelectorAll('#view button[data-act="del"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete?')) return;
      await authFetch(`/countries/${encodeURIComponent(btn.dataset.name)}`,{method:'DELETE'}); await renderCountries();
    };
  });
  document.querySelectorAll('#view button[data-act="edit"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('Country name', btn.dataset.name); if(!newName) return;
      const mcc = prompt('MCC (optional)','');
      await authFetch(`/countries/${encodeURIComponent(btn.dataset.name)}`,{method:'PUT',body:JSON.stringify({name:newName,mcc:mcc||null})});
      await renderCountries();
    };
  });
}

/* Networks */
async function viewNetworks(){
  navActivate('networks');
  renderFilters(`
    <input id="nq" placeholder="Search network...">
    <input id="nCountry" placeholder="Country filter">
    <input id="nmccmnc" placeholder="MCCMNC filter">
    <button id="nF">Filter</button>
    <input id="nName" placeholder="Network name">
    <input id="nMNC" placeholder="MNC">
    <input id="nMCCMNC" placeholder="MCCMNC">
    <button id="nCreate">Create</button>
  `);
  document.querySelector('#nF').onclick = renderNetworks;
  document.querySelector('#nCreate').onclick = async ()=>{
    const name=document.querySelector('#nName').value.trim(); if(!name) return;
    await authFetch('/networks/',{method:'POST',body:JSON.stringify({name, mnc:document.querySelector('#nMNC').value.trim()||null, mccmnc:document.querySelector('#nMCCMNC').value.trim()||null})});
    document.querySelector('#nName').value=''; document.querySelector('#nMNC').value=''; document.querySelector('#nMCCMNC').value='';
    await renderNetworks();
  };
  await renderNetworks();
}
async function renderNetworks(){
  const params = new URLSearchParams();
  const q=document.querySelector('#nq').value.trim(), country=document.querySelector('#nCountry').value.trim(), mm=document.querySelector('#nmccmnc').value.trim();
  if(q) params.set('q',q); if(country) params.set('country',country); if(mm) params.set('mccmnc',mm);
  const list = await authFetch('/networks/'+(params.toString()?`?${params.toString()}`:''));
  renderView(`<div class="card">
    <table><thead><tr><th>Name</th><th>MNC</th><th>MCCMNC</th><th></th></tr></thead>
    <tbody>${list.map(n=>`
      <tr><td>${n.name}</td><td>${n.mnc||''}</td><td>${n.mccmnc||''}</td>
      <td class="actions">
        <button data-act="editn" data-name="${n.name}">Edit</button>
        <button data-act="deln" data-name="${n.name}">Delete</button>
      </td></tr>`).join('')}
    </tbody></table>
  </div>`);
  document.querySelectorAll('#view button[data-act="deln"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete?')) return;
      await authFetch(`/networks/by-name/${encodeURIComponent(btn.dataset.name)}`,{method:'DELETE'}); await renderNetworks();
    };
  });
  document.querySelectorAll('#view button[data-act="editn"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('Network name', btn.dataset.name); if(!newName) return;
      const mnc = prompt('MNC (optional)',''); const mm = prompt('MCCMNC (optional)','');
      await authFetch(`/networks/by-name/${encodeURIComponent(btn.dataset.name)}`,{method:'PUT',body:JSON.stringify({name:newName,mnc:(mnc||null),mccmnc:(mm||null)})});
      await renderNetworks();
    };
  });
}

/* Offers */
async function viewOffers(){
  navActivate('offers');
  renderFilters(`
    <input id="oq" placeholder="Search notes/network/mccmnc">
    <select id="of_route"><option value="">Route Type</option></select>
    <select id="of_hops"><option value="">Known Hops</option></select>
    <select id="of_reg"><option value="">Registration</option></select>
    <input id="of_supplier" placeholder="Supplier name">
    <input id="of_conn" placeholder="Connection name">
    <input id="of_country" placeholder="Country">
    <input id="of_sender" placeholder="Sender Id contains">
    <select id="of_exclusive"><option value="">Exclusive?</option><option>true</option><option>false</option></select>
    <button id="oF">Filter</button>
    <button id="oNew">New Offer</button>
  `);
  await hydrateEnums();
  document.querySelector('#oF').onclick = renderOffers;
  document.querySelector('#oNew').onclick = async ()=>{ await openNewOffer(); };
  await renderOffers();
}
async function hydrateEnums(){
  try{
    const e = await authFetch('/conf/enums');
    const r = e.route_type||[], h=e.known_hops||[], reg=e.registration_required||[];
    const put = (sel,vals)=>{ const c=document.querySelector(sel); c.innerHTML='<option value=""></option>'+vals.map(v=>`<option>${v}</option>`).join(''); };
    put('#of_route',r); put('#of_hops',h); put('#of_reg',reg);
  }catch(e){}
}
function offerFiltersQS(){
  const p=new URLSearchParams();
  const set=(id,k)=>{ const v=document.querySelector(id).value.trim(); if(v) p.set(k,v); };
  set('#oq','q'); set('#of_route','route_type'); set('#of_hops','known_hops'); set('#of_reg','registration_required');
  set('#of_supplier','supplier_name'); set('#of_conn','connection_name'); set('#of_country','country');
  set('#of_sender','sender_id_supported');
  const ex=document.querySelector('#of_exclusive').value.trim(); if(ex) p.set('is_exclusive',ex);
  return p.toString();
}
async function renderOffers(){
  const qs = offerFiltersQS();
  const list = await authFetch('/offers/'+(qs?`?${qs}`:''));
  renderView(`<div class="card">
    <table><thead><tr>
      <th>Supplier</th><th>Connection</th><th>Country</th><th>Network</th><th>MCCMNC</th>
      <th>Price</th><th>Eff.Date</th><th>Prev</th><th>Route</th><th>Hops</th><th>SenderId</th>
      <th>Reg</th><th>ETA</th><th>Charge</th><th>Exclusive</th><th>Notes</th><th></th>
    </tr></thead>
    <tbody>
    ${list.map(o=>`
      <tr>
        <td>${o.supplier_name}</td><td>${o.connection_name}</td><td>${o.country_name||''}</td><td>${o.network_name||''}</td><td>${o.mccmnc||''}</td>
        <td>${o.price}</td><td>${o.price_effective_date||''}</td><td>${o.previous_price??''}</td>
        <td>${o.route_type||''}</td><td>${o.known_hops||''}</td><td>${o.sender_id_supported||''}</td>
        <td>${o.registration_required||''}</td><td>${o.eta_days??''}</td><td>${o.charge_model||''}</td>
        <td>${o.is_exclusive?'Yes':'No'}</td><td>${o.notes||''}</td>
        <td class="actions">
          <button data-act="oedit" data-id="${o.id}">Edit</button>
          <button data-act="odel" data-id="${o.id}">Delete</button>
        </td>
      </tr>`).join('')}
    </tbody></table>
  </div>`);
  document.querySelectorAll('#view button[data-act="odel"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete offer?')) return;
      await authFetch(`/offers/${btn.dataset.id}`,{method:'DELETE'}); await renderOffers();
    };
  });
  document.querySelectorAll('#view button[data-act="oedit"]').forEach(btn=>{
    btn.onclick = async ()=>{ await openEditOffer(btn.dataset.id); };
  });
}
async function openNewOffer(){ await openOfferEditor(); }
async function openEditOffer(id){
  const rows = await authFetch('/offers/?q=');
  const o = rows.find(x=> String(x.id)===String(id));
  if(!o){ alert('Offer not found in current list'); return; }
  await openOfferEditor(o);
}
async function openOfferEditor(data={}){
  const e = await authFetch('/conf/enums').catch(()=>({}));
  const pick=(name,vals,cur)=>`<select id="f_${name}">
    <option value=""></option>${(vals||[]).map(v=>`<option ${cur===v?'selected':''}>${v}</option>`).join('')}</select>`;
  renderView(`<div class="card">
    <div class="row">
      <input id="f_supplier" placeholder="Supplier name" value="${data.supplier_name||''}">
      <input id="f_conn" placeholder="Connection name" value="${data.connection_name||''}">
      <input id="f_country" placeholder="Country" value="${data.country_name||''}">
      <input id="f_network" placeholder="Network" value="${data.network_name||''}">
      <input id="f_mccmnc" placeholder="MCCMNC" value="${data.mccmnc||''}">
      <input id="f_price" type="number" step="0.0001" placeholder="Price" value="${data.price||''}">
      <input id="f_eff" type="date" value="${data.price_effective_date||''}">
      <input id="f_prev" type="number" step="0.0001" placeholder="Previous price" value="${data.previous_price??''}">
      ${pick('route',e.route_type,data.route_type||'')}
      ${pick('hops',e.known_hops,data.known_hops||'')}
      <input id="f_sender" placeholder="SenderId CSV" value="${data.sender_id_supported||''}">
      ${pick('reg',e.registration_required,data.registration_required||'')}
      <input id="f_eta" type="number" step="1" placeholder="ETA days" value="${data.eta_days??''}">
      <input id="f_charge" placeholder="Charge model" value="${data.charge_model||''}">
      <select id="f_excl"><option ${data.is_exclusive?'':'selected'} value="">Exclusive?</option><option ${data.is_exclusive?'selected':''} value="true">Yes</option><option value="false">No</option></select>
      <input id="f_notes" placeholder="Notes" value="${data.notes||''}">
    </div>
    <div class="row">
      <button id="saveBtn">${data.id?'Save':'Create'}</button>
      <button id="cancelBtn">Cancel</button>
    </div>
  </div>`);
  document.querySelector('#cancelBtn').onclick = ()=>viewOffers();
  document.querySelector('#saveBtn').onclick = async ()=>{
    const body={
      supplier_name: document.querySelector('#f_supplier').value.trim(),
      connection_name: document.querySelector('#f_conn').value.trim(),
      country_name: document.querySelector('#f_country').value.trim()||null,
      network_name: document.querySelector('#f_network').value.trim()||null,
      mccmnc: document.querySelector('#f_mccmnc').value.trim()||null,
      price: parseFloat(document.querySelector('#f_price').value),
      price_effective_date: document.querySelector('#f_eff').value || null,
      previous_price: document.querySelector('#f_prev').value ? parseFloat(document.querySelector('#f_prev').value) : null,
      route_type: document.querySelector('#f_route').value || null,
      known_hops: document.querySelector('#f_hops').value || null,
      sender_id_supported: document.querySelector('#f_sender').value.trim()||null,
      registration_required: document.querySelector('#f_reg').value || null,
      eta_days: document.querySelector('#f_eta').value ? parseInt(document.querySelector('#f_eta').value) : null,
      charge_model: document.querySelector('#f_charge').value.trim()||null,
      is_exclusive: (document.querySelector('#f_excl').value==='true') ? true : (document.querySelector('#f_excl').value==='false' ? false : null),
      notes: document.querySelector('#f_notes').value.trim()||null,
      updated_by: document.querySelector('#user').value
    };
    if(!body.supplier_name || !body.connection_name || isNaN(body.price)){ alert('Supplier, Connection, Price are required'); return; }
    if(data.id){
      await authFetch(`/offers/${data.id}`,{method:'PUT', body:JSON.stringify(body)});
    }else{
      await authFetch(`/offers/`,{method:'POST', body:JSON.stringify(body)});
    }
    await viewOffers();
  };
}

/* Parsers (placeholder) */
async function viewParsers(){
  navActivate('parsers');
  renderFilters(`<span class="muted">Parsers are configurable next; enums already live in Settings.</span>`);
  renderView(`<div class="card"><p>Parser definitions (create/edit/delete) will appear here.</p></div>`);
}

/* Settings (enums) */
async function viewSettings(){
  navActivate('settings');
  const cur = await authFetch('/conf/enums');
  function render(){
    renderView(`<div class="card">
      <h3>Dropdown Options</h3>
      <div class="row">
        <textarea id="enums" rows="10" style="width:100%">${JSON.stringify(cur,null,2)}</textarea>
      </div>
      <div class="row"><button id="saveE">Save</button></div>
    </div>`);
    document.querySelector('#saveE').onclick = async ()=>{
      try{
        const val = JSON.parse(document.querySelector('#enums').value);
        await authFetch('/conf/enums',{method:'PUT', body: JSON.stringify(val)});
        alert('Saved'); await viewSettings();
      }catch(e){ alert('JSON error: '+e.message); }
    };
  }
  render();
}

/* Dedicated "Connections" top menu (search by supplier name) */
async function viewConnections(){
  navActivate('connections');
  renderFilters(`
    <input id="sq" placeholder="Supplier name">
    <input id="cq" placeholder="Search connections">
    <button id="sF">Filter</button>
  `);
  document.querySelector('#sF').onclick = renderConnectionsGrid;
  await renderConnectionsGrid();
}
async function renderConnectionsGrid(){
  const sname = document.querySelector('#sq').value.trim();
  if(!sname){ renderView('<div class="card">Enter supplier name to list connections.</div>'); return; }
  const qs = document.querySelector('#cq').value.trim(); 
  const list = await authFetch(`/suppliers/${encodeURIComponent(sname)}/connections/`+(qs?`?q=${encodeURIComponent(qs)}`:''));
  renderView(`<div class="card">
    <h3>${sname} — Connections</h3>
    <table><thead><tr><th>Name</th><th>Username</th><th>SMSc</th><th>Per Delivered</th><th>Charge</th><th></th></tr></thead>
      <tbody>${list.map(c=>`
        <tr>
         <td>${c.connection_name}</td><td>${c.username||''}</td><td>${c.kannel_smsc||''}</td>
         <td>${c.per_delivered?'Yes':'No'}</td><td>${c.charge_model||''}</td>
         <td class="actions"><button data-act="editc" data-n="${c.connection_name}">Edit</button>
         <button data-act="delc" data-n="${c.connection_name}">Delete</button></td>
        </tr>`).join('')}
      </tbody>
    </table>
  </div>`);
}

/* Navigation + entry */
const routes = {
  suppliers: viewSuppliers,
  connections: viewConnections,
  countries: viewCountries,
  networks: viewNetworks,
  offers: viewOffers,
  parsers: viewParsers,
  settings: viewSettings,
  whatsnew: async ()=>{
    navActivate('whatsnew');
    renderFilters('');
    renderView('<div class="card"><h3>What’s New</h3><p>Full CRUD, filters and expand/collapse are live. Login flow fixed.</p></div>');
  }
};
function wireNav(){
  document.querySelectorAll('nav button').forEach(b=>{
    b.onclick = ()=> routes[b.dataset.view]();
  });
}
async function render(){ await viewSuppliers(); }
wireNav();
firstMount();
JS

# 2) Rebuild & restart web
cd "$ROOT/docker"
docker compose build web >/dev/null
docker compose up -d web >/dev/null

# 3) Quick API sanity (root + login) to help user validate
echo "🩺 API root:" ; curl -sS http://localhost:8010/ ; echo
echo "🔐 Login test:" ; curl -sS -X POST http://localhost:8010/users/login -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=admin&password=admin123' ; echo

echo "✅ Patch applied. Open http://localhost:5183, set API Base if needed, click Login (no reload anymore)."
