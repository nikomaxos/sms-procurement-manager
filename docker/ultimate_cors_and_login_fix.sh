#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE_DIR="$API_DIR/core"
ROUT_DIR="$API_DIR/routers"
WEB_DIR="$ROOT/web/public"
MAIN_PY="$API_DIR/main.py"
USERS_PY="$ROUT_DIR/users.py"
COMPOSE="$ROOT/docker-compose.yml"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/ultimate_cors_and_login_fix_$TS"
mkdir -p "$BACK" "$CORE_DIR" "$ROUT_DIR"

echo -e "${Y}• Backing up to ${BACK}${N}"
[[ -f "$MAIN_PY"  ]] && cp -a "$MAIN_PY"  "$BACK/main.py.bak"  || true
[[ -f "$USERS_PY" ]] && cp -a "$USERS_PY" "$BACK/users.py.bak" || true

touch "$API_DIR/__init__.py" "$CORE_DIR/__init__.py" "$ROUT_DIR/__init__.py"

# 1) main.py with CORSMiddleware + unconditional CORS middleware + router mount
echo -e "${Y}• Writing main.py with unconditional CORS middleware…${N}"
cat > "$MAIN_PY" <<'PY'
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import PlainTextResponse
import importlib, pkgutil, sys

app = FastAPI(title="SMS Procurement Manager API")

# Standard CORSMiddleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

# Unconditional CORS headers for ALL responses (incl. errors & preflight)
@app.middleware("http")
async def _always_cors(request: Request, call_next):
    # Handle preflight for ANY path
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        resp = await call_next(request)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp

# Mount users router explicitly
try:
    from app.routers import users as _users
    app.include_router(_users.router)
except Exception as e:
    print("WARNING: users router failed to mount:", repr(e), file=sys.stderr)

# Auto-include other routers exposing `router`
try:
    import app.routers as _rpk
    for _m in pkgutil.iter_modules(_rpk.__path__):
        if _m.name == "users":
            continue
        try:
            _mod = importlib.import_module(f"app.routers.{_m.name}")
            if hasattr(_mod, "router"):
                app.include_router(_mod.router)
        except Exception as _e:
            print(f"Skipping router {_m.name}: {_e!r}", file=sys.stderr)
except Exception as e:
    print("Router autodiscovery failed:", repr(e), file=sys.stderr)

@app.get("/health")
def health():
    return {"ok": True}
PY

# 2) Ensure users router has explicit OPTIONS for /users/login (belt & suspenders)
if [[ -f "$USERS_PY" ]]; then
  if ! grep -q "@router.options(\"/login\")" "$USERS_PY"; then
    echo -e "${Y}• Adding explicit OPTIONS handler to users router…${N}"
    awk '
      BEGIN{added=0}
      {print}
      /@router.post\(\"\/login\"/ && added==0 {
        print "\n@router.options(\"/login\")\ndef login_options():\n    return {}\n"
        added=1
      }' "$USERS_PY" > "$USERS_PY.__new" && mv "$USERS_PY.__new" "$USERS_PY"
  fi
else
  echo -e "${R}✖ users.py not found; login endpoint must exist. If missing, re-run the earlier users router script.${N}"
fi

# 3) Rebuild + restart api
echo -e "${Y}• Rebuilding API…${N}"
docker compose -f "$COMPOSE" build api >/dev/null
echo -e "${Y}• Restarting API…${N}"
docker compose -f "$COMPOSE" up -d api >/dev/null
sleep 3

# 4) CORS probes
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}• Probe: OPTIONS /users/login (expect ACAO)${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,30p' || true

echo -e "${Y}• Probe: POST /users/login (JSON) expect 200 + token + ACAO${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,30p' || true

echo -e "${G}✔ Done. Hard refresh the UI (Ctrl/Cmd+Shift+R) and try again (admin/admin123).${N}"
