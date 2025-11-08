#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
ROUT="$API/routers"
COMPOSE="$ROOT/docker-compose.yml"
TS="$(date +%F_%H-%M-%S)"
mkdir -p "$ROOT/.backups/router_syntax_$TS"
cp -a "$ROUT" "$ROOT/.backups/router_syntax_$TS/" 2>/dev/null || true

echo -e "${Y}• Rewriting routers with proper decorator lines…${N}"

# conf.py
cat > "$ROUT/conf.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/conf", tags=["conf"])

@router.get("/enums")
def enums():
    return {"countries": [], "mccmnc": [], "vendors": [], "tags": []}
PY

# settings.py
cat > "$ROUT/settings.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/settings", tags=["settings"])

@router.get("/imap")
def get_imap():
    return {}

@router.post("/imap")
def set_imap(cfg: dict):
    return {"ok": True, "saved": cfg}

@router.get("/scrape")
def get_scrape():
    return {}

@router.post("/scrape")
def set_scrape(cfg: dict):
    return {"ok": True, "saved": cfg}
PY

# metrics.py
cat > "$ROUT/metrics.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/metrics", tags=["metrics"])

@router.get("/trends")
def trends(d: str):
    return {"date": d, "series": []}
PY

# networks.py
cat > "$ROUT/networks.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/networks", tags=["networks"])

@router.get("/")
def list_networks():
    return []
PY

# parsers.py
cat > "$ROUT/parsers.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/parsers", tags=["parsers"])

@router.get("/")
def list_parsers():
    return []
PY

# offers.py
cat > "$ROUT/offers.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/offers", tags=["offers"])

@router.get("/")
def list_offers(limit: int = 50, offset: int = 0):
    return {"count": 0, "results": []}
PY

# health.py
cat > "$ROUT/health.py" <<'PY'
from fastapi import APIRouter
router = APIRouter(prefix="/health", tags=["health"])

@router.get("")
def health():
    return {"ok": True}
PY

echo -e "${Y}• Rebuilding API…${N}"
docker compose -f "$COMPOSE" build api
docker compose -f "$COMPOSE" up -d api

echo -e "${Y}• Tailing API logs (20 lines)…${N}"
docker compose -f "$COMPOSE" logs api --tail=20

# Quick end-to-end probe (needs a few seconds for startup)
sleep 3
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n▶ OPTIONS /users/login${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,20p'

echo -e "${Y}\n▶ POST /users/login (JSON)${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,40p'
