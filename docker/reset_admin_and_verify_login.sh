#!/usr/bin/env bash
set -euo pipefail

API_CONT="docker-api-1"
API_BASE="http://localhost:8010"

echo "🔎 Checking API container..."
if ! docker ps --format '{{.Names}}' | grep -qx "$API_CONT"; then
  echo "❌ Container $API_CONT not running."
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  exit 1
fi

echo "👤 (Re)seeding admin user (admin / admin123)..."
docker exec -i "$API_CONT" python3 - <<'PY'
from app.core.database import SessionLocal, Base, engine
from app.models import models
from app.core.auth import get_password_hash

Base.metadata.create_all(bind=engine)
db = SessionLocal()
try:
    u = db.query(models.User).filter_by(username="admin").first()
    if not u:
        u = models.User(username="admin", password_hash=get_password_hash("admin123"), role="admin")
        db.add(u)
        msg = "✅ Admin created"
    else:
        u.password_hash = get_password_hash("admin123")
        msg = "🔁 Admin password reset"
    db.commit()
    print(msg)
finally:
    db.close()
PY

echo "🔐 Testing login (form-encoded)..."
HTTP_CODE=$(curl -s -o /tmp/login.out -w '%{http_code}' \
  -X POST "$API_BASE/users/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123")

echo "HTTP $HTTP_CODE"
cat /tmp/login.out; echo

if [ "$HTTP_CODE" != "200" ]; then
  echo "⚠️ Login still failing. Showing recent API logs:"
  docker logs "$API_CONT" --tail=120
  exit 2
fi

echo "✅ Login OK. You can now sign in from the Web UI."
