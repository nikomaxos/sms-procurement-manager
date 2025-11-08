#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/sms-procurement-manager"
DB="$ROOT/api/app/core/database.py"

# Sanity
if [ ! -f "$DB" ]; then
  echo "❌ $DB not found (expected your FastAPI app under api/app)."
  exit 1
fi

# Patch database.py: force psycopg v3 driver and normalize any postgresql://
python3 - <<'PY'
from pathlib import Path
import re

p = Path.home() / "sms-procurement-manager/api/app/core/database.py"
s = p.read_text()

# 1) Default fallback URL -> postgresql+psycopg://...
s = re.sub(
    r'DB_URL\s*=\s*os\.getenv\("DB_URL",\s*"postgresql://',
    'DB_URL = os.getenv("DB_URL", "postgresql+psycopg://',
    s,
)

# 2) Add runtime normalizer (so if someone sets DB_URL=postgresql://… in env, it’s still OK)
if "def _normalize(" not in s:
    s = s.replace(
        "Base = declarative_base()",
        """Base = declarative_base()

def _normalize(url: str) -> str:
    if url.startswith("postgresql://"):
        return "postgresql+psycopg://" + url.split("://", 1)[1]
    return url

DB_URL = _normalize(DB_URL)""",
    )

p.write_text(s)
print("✅ Patched:", p)
PY

# Rebuild & restart API
cd "$ROOT/docker"
docker compose build api
docker compose up -d api

# Short wait then logs
sleep 2
docker logs docker-api-1 --tail=80 || true

# Probes
echo "🌐 Root probe:"
curl -sS http://localhost:8010/ ; echo

echo "🔐 Login probe:"
TOKEN=$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
echo "Token length: ${#TOKEN}"
