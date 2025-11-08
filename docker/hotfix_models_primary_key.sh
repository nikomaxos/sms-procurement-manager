#!/usr/bin/env bash
set -euo pipefail

MODELS="$HOME/sms-procurement-manager/api/app/models/models.py"

echo "🔧 Fixing 'primary key=' → 'primary_key=' in $MODELS ..."
# Fix both "primary key=" and accidental "primary_key=" (idempotent)
sed -i -E 's/primary[ _]?key=/primary_key=/g' "$MODELS"

echo "🔁 Rebuild & restart API ..."
cd "$HOME/sms-procurement-manager/docker"
docker compose build api
docker compose up -d api

echo "🧪 Wait a moment and show last logs ..."
sleep 2
docker logs docker-api-1 --tail=50 || true

echo "👤 Ensure admin user exists ..."
docker exec -i docker-api-1 python3 - <<'PY'
from app.core import auth
from app.models import models
from app.core.database import SessionLocal, Base, engine
Base.metadata.create_all(bind=engine)
db=SessionLocal()
u=db.query(models.User).filter_by(username="admin").first()
if not u:
    u=models.User(username="admin", password_hash=auth.get_password_hash("admin123"), role="admin")
    db.add(u); db.commit(); print("✅ Admin created")
else:
    print("ℹ️ Admin exists")
db.close()
PY

echo "🌐 Probe root & login ..."
curl -sS http://localhost:8010/ ; echo
TOKEN=$(curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
echo "🔑 Token length: ${#TOKEN}"

echo "📦 GET /offers"
curl -sS http://localhost:8010/offers -H "Authorization: Bearer $TOKEN" ; echo
