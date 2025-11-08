#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
MAIN="$ROOT/api/app/main.py"
DOCK="$ROOT/docker"

if [ ! -f "$MAIN" ]; then
  echo "❌ $MAIN not found"; exit 1
fi

python3 - <<'PY'
import re, os, io
p = os.path.expanduser("~/sms-procurement-manager/api/app/main.py")
src = io.open(p, "r", encoding="utf-8").read()

# Ensure import
if "from fastapi.middleware.cors import CORSMiddleware" not in src:
    src = src.replace("from fastapi import FastAPI",
                      "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")

# Ensure os import
if "\nimport os" not in src:
    src = src.replace("from fastapi import FastAPI", "from fastapi import FastAPI\nimport os")

# Remove any existing app.add_middleware(CORSMiddleware, ...) blocks (be strict but safe)
src = re.sub(
    r"\napp\.add_middleware\(\s*CORSMiddleware[^)]*\)\s*\n",
    "\n", src, flags=re.S
)

# Insert our CORS right after the first `app = FastAPI(`
m = re.search(r"app\s*=\s*FastAPI\([^)]*\)", src)
if not m:
    raise SystemExit("❌ Could not find `app = FastAPI(...)` in main.py")
insertion_point = m.end()

cors_block = """
# ---- unified CORS (no credentials + wildcard + all methods/headers) ----
origins = os.getenv("CORS_ORIGINS", "http://localhost:5183,http://127.0.0.1:5183,http://192.168.50.102:5183,*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,          # includes '*'
    allow_credentials=False,        # IMPORTANT: False so '*' is valid
    allow_methods=["*"],
    allow_headers=["*"],            # covers 'authorization', etc.
    expose_headers=["*"],
    max_age=600,
)
"""

src = src[:insertion_point] + cors_block + src[insertion_point:]
io.open(p, "w", encoding="utf-8").write(src)
print("✓ CORS block normalized")
PY

# Rebuild & restart API
cd "$DOCK"
docker compose up -d --build api

# Wait for API
echo "⏳ waiting API..."
for i in $(seq 1 40); do
  if curl -sf http://localhost:8010/openapi.json >/dev/null; then echo "✅ API up"; break; fi
  sleep 0.5
  if [ $i -eq 40 ]; then echo "❌ timeout"; docker logs docker-api-1 --tail=200; exit 1; fi
done

# Preflight sanity (Origin = Web UI)
ORIGIN="http://$(hostname -I | awk '{print $1}'):5183"
echo "🩺 Preflight check with Origin=$ORIGIN"
curl -i -s -X OPTIONS "http://localhost:8010/offers/?limit=1" \
  -H "Origin: $ORIGIN" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: authorization,content-type" \
  | sed -n '1,25p'

# Login to test authenticated GET
TOK="$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | python3 - <<'PY'
import sys, json
d = sys.stdin.read().strip()
print("" if not d else json.loads(d)["access_token"])
PY
)"
if [ -z "$TOK" ]; then echo "❌ login failed"; docker logs docker-api-1 --tail=200; exit 1; fi
echo "🔐 token ok (${#TOK} chars)"

# Auth GET sanity (should include Access-Control-Allow-Origin)
curl -i -s "http://localhost:8010/offers/?limit=1" \
  -H "Origin: $ORIGIN" \
  -H "Authorization: Bearer $TOK" \
  | sed -n '1,25p'
