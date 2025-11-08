#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
WEB="$ROOT/web/public"

echo "==> Laying minimal web (index.html + main.js)…"
mkdir -p "$WEB"
cat > "$WEB/index.html" <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>SMS Procurement Manager</title>
</head><body>
<div id="app"></div>
<script src="main.js"></script>
</body></html>
HTML

cat > "$WEB/main.js" <<'JS'
(()=>{const API=(location.origin.replace(':5183',':8010'));let tk=localStorage.getItem('tk')||'';
const app=document.getElementById('app');
const s=document.createElement('style');s.textContent=`body{margin:0;background:#0f0f10;color:#f5f5f7;font:14px/1.4 system-ui,Segoe UI,Roboto,sans-serif}
.card{background:#1a1b1e;border:1px solid #2a2b31;border-radius:14px;padding:12px;margin:12px}
input,button{padding:8px 12px;border-radius:10px;border:1px solid #333;background:#121315;color:#f5f5f7}
button{background:#67d2a4;color:#101114;border:0;cursor:pointer;margin-left:8px}`;document.head.appendChild(s);
async function me(){if(!tk) return null;const r=await fetch(`${API}/users/me`,{headers:{Authorization:'Bearer '+tk}});return r.ok? r.json():null;}
async function doLogin(u,p){
  const r=await fetch(`${API}/users/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})});
  if(!r.ok){alert('Login failed');return;}
  const j=await r.json(); tk=j.access_token; localStorage.setItem('tk',tk); settings();
}
function logout(){tk='';localStorage.removeItem('tk'); login();}
function settings(){app.innerHTML='';const c=document.createElement('div');c.className='card';
  c.innerHTML='<h2>Settings</h2><p>Protected area — logged in.</p><button id=lo>Logout</button>';app.appendChild(c);
  c.querySelector('#lo').onclick=logout;
}
function login(){app.innerHTML='';const c=document.createElement('div');c.className='card';
  c.innerHTML='<h2>Login</h2><input id=u placeholder=Username value=admin> <input id=p type=password placeholder=Password value=admin123> <button id=go>Login</button>';
  app.appendChild(c); c.querySelector('#go').onclick=()=>doLogin(c.querySelector('#u').value,c.querySelector('#p').value);
}
(async()=>{const m=await me(); if(m) settings(); else login();})();
})();
JS

echo "==> Web Dockerfile with a clean default.conf…"
cat > "$ROOT/web.Dockerfile" <<'DOCKER'
FROM nginx:alpine
# Clean, explicit default server
RUN rm -f /etc/nginx/conf.d/default.conf
COPY web/public /usr/share/nginx/html
RUN printf '%s\n' \
 'server {' \
 '  listen 80;' \
 '  server_name _;' \
 '  root /usr/share/nginx/html;' \
 '  index index.html;' \
 '  location / {' \
 '    try_files $uri /index.html;' \
 '  }' \
 '}' > /etc/nginx/conf.d/default.conf
DOCKER

echo "==> Minimal, robust API (auth only, no DB/bcrypt)…"
mkdir -p "$API"
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from jose import jwt, JWTError
from datetime import datetime, timedelta, timezone
import os

SECRET_KEY = os.getenv("SECRET_KEY","dev-change-me")
ALGORITHM = "HS256"
security = HTTPBearer(auto_error=False)

app = FastAPI(title="Auth-Only Baseline")
app.add_middleware(CORSMiddleware,
    allow_origins=["*"], allow_credentials=False,
    allow_methods=["*"], allow_headers=["*"])

USERS = {"admin":"admin123"}  # DEV ONLY

class Login(BaseModel):
    username: str
    password: str

def current_user(creds: HTTPAuthorizationCredentials = Depends(security)):
    if creds is None or creds.scheme.lower()!="bearer":
        raise HTTPException(401,"Not authenticated")
    try:
        payload = jwt.decode(creds.credentials, SECRET_KEY, algorithms=[ALGORITHM])
        sub = payload.get("sub")
        if not sub: raise HTTPException(401, "Invalid token")
        return {"username": sub, "role": payload.get("role","admin")}
    except JWTError:
        raise HTTPException(401,"Invalid token")

@app.get("/health")
def health(): return {"ok": True}

@app.post("/users/login")
def login(p: Login):
    if USERS.get(p.username) != p.password:
        raise HTTPException(401, "Invalid credentials")
    exp = datetime.now(timezone.utc) + timedelta(days=7)
    token = jwt.encode({"sub": p.username, "role": "admin", "exp": exp}, SECRET_KEY, algorithm=ALGORITHM)
    return {"access_token": token, "token_type":"bearer", "user":{"username":p.username,"role":"admin"}}

@app.get("/users/me")
def me(u=Depends(current_user)): return {"user": u}
PY

echo "==> API Dockerfile…"
cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN pip install --no-cache-dir fastapi uvicorn[standard] "python-jose[cryptography]" pydantic
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER

echo "==> Compose (api + web)…"
cat > "$ROOT/docker-compose.yml" <<'YML'
services:
  api:
    build:
      context: .
    # dockerfile defaults to api.Dockerfile because of context and filename
    dockerfile: api.Dockerfile
    environment:
      SECRET_KEY: dev-change-me
    restart: unless-stopped
    ports: ["8010:8000"]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    restart: unless-stopped
    depends_on: [api]
    ports: ["5183:80"]
YML

echo "==> Rebuild & start…"
cd "$ROOT"
docker compose up -d --build

echo "==> Wait for ports to open…"
# Busy-wait up to ~15s for each port
for i in $(seq 1 30); do nc -z localhost 8010 && break || sleep 0.5; done
for i in $(seq 1 30); do nc -z localhost 5183 && break || sleep 0.5; done

echo "==> Quick probes (localhost to avoid LAN routing issues)…"
set -x
curl -sS http://127.0.0.1:8010/health
curl -sS -X POST http://127.0.0.1:8010/users/login -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}'
set +x

echo "==> Done. Open http://127.0.0.1:5183 (or your host IP :5183). Login admin / admin123."
