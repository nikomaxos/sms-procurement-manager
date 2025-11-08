#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
COMPOSE="$ROOT/docker-compose.yml"
API_DF="$ROOT/api.Dockerfile"

TS="$(date +%F_%H-%M-%S)"
BACK="$ROOT/.backups/pin_bcrypt_$TS"
mkdir -p "$BACK"

echo -e "${Y}• Backing up api.Dockerfile to $BACK …${N}"
cp -a "$API_DF" "$BACK/api.Dockerfile.bak"

# Append a definitive pin so it wins even if earlier lines install different versions.
if ! grep -q 'passlib\[bcrypt\]==1.7.4' "$API_DF"; then
  cat >> "$API_DF" <<'DOCKER'

# --- bcrypt/passlib pin to avoid backend version mismatch ---
RUN pip install --no-cache-dir --upgrade --force-reinstall \
    "passlib[bcrypt]==1.7.4" "bcrypt==3.2.2"
# ------------------------------------------------------------
DOCKER
  echo -e "${G}✔ Appended bcrypt/passlib pin to api.Dockerfile${N}"
else
  echo -e "${G}✔ api.Dockerfile already contains the pin${N}"
fi

echo -e "${Y}• Rebuilding API image without cache…${N}"
docker compose -f "$COMPOSE" build --no-cache api

echo -e "${Y}• Restarting API…${N}"
docker compose -f "$COMPOSE" up -d api

echo -e "${Y}• Verifying versions inside the container…${N}"
docker compose -f "$COMPOSE" exec -T api python - <<'PY'
import bcrypt, passlib
print("bcrypt_has_about:", hasattr(bcrypt, "__about__"))
print("bcrypt_version:", getattr(getattr(bcrypt, "__about__", {}), "__dict__", {}).get("__version__", "n/a"))
print("passlib_version:", passlib.__version__)
from passlib.context import CryptContext
pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")
h = pwd.hash("admin123")
print("hash_ok:", pwd.verify("admin123", h))
PY

# Tiny pause for startup
sleep 2

IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}\n• Probing CORS preflight (OPTIONS) …${N}"
curl -s -i -X OPTIONS "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Access-Control-Request-Method: POST" | sed -n '1,20p'

echo -e "${Y}\n• Probing JSON login (admin/admin123) …${N}"
curl -s -i -X POST "http://${IP}:8010/users/login" \
  -H "Origin: http://${IP}:5183" \
  -H "Content-Type: application/json" \
  --data '{"username":"admin","password":"admin123"}' | sed -n '1,80p'

echo -e "${G}\n✔ Done. If POST shows 200 with a token, hard-refresh the UI and log in.${N}"
