#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE="$API_DIR/core"
ROUTERS="$API_DIR/routers"
COMPOSE="$ROOT/docker-compose.yml"

echo -e "${Y}🛠  Hotfix: stable API bootstrap, CORS, users/login, Postgres healthcheck${N}"

mkdir -p "$CORE" "$ROUTERS"

# ------------------------------
# 1) api.Dockerfile (idempotent)
# ------------------------------
if [[ ! -f "$ROOT/api.Dockerfile" ]]; then
  cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir \
      fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" \
      pydantic python-multipart python-jose[cryptography] \
      "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1"
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER
  echo -e "${G}✔ api.Dockerfile ready${N}"
fi

# ------------------------------
# 2) Core DB (psycopg v3 DSN)
# ------------------------------
cat > "$CORE/database.py" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

_raw = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")
if _raw.startswith("postgresql://"):
    _raw = _raw.replace("postgresql://", "postgresql+psycopg://", 1)

DB_URL = _raw
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, future=True)
Base = declarative_base()
PY
echo -e "${G}✔ core/database.py set (psycopg v3)${N}"

# ------------------------------
# 3) Core auth + JWT helpers
# ------------------------------
cat > "$CORE/auth.py" <<'PY'
import os, time
from datetime import datetime, timedelta, timezone
from typing import Optional
from jose import jwt, JWTError
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key-change-me")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "720"))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return pwd_context.verify(plain, hashed)
    except Exception:
        time.sleep(0.05)
        return False

def hash_password(plain: str) -> str:
    # Trim to 72 bytes for bcrypt safety
    b = plain.encode("utf-8")[:72]
    return pwd_context.hash(b)

def create_access_token(sub: str, expires_delta: Optional[timedelta] = None) -> str:
    expire = datetime.now(tz=timezone.utc) + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode = {"sub": sub, "exp": expire}
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
PY
echo -e "${G}✔ core/auth.py ready${N}"

# ------------------------------
# 4) Minimal users migration + seed
# ------------------------------
cat > "$API_DIR/migrations_users.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import hash_password

def ensure_users():
    stmts = [
        """
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR NOT NULL UNIQUE,
          password_hash VARCHAR NOT NULL,
          role VARCHAR(32) DEFAULT 'admin'
        );
        """,
        # insert admin only if missing
        """
        INSERT INTO users (username, password_hash, role)
        SELECT 'admin', :ph, 'admin'
        WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='admin');
        """
    ]
    ph = hash_password("admin123")
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s), {"ph": ph})
PY
echo -e "${G}✔ migrations_users.py ready (admin/admin123 will be ensured)${N}"

# ------------------------------
# 5) Users router (/users/login)
# ------------------------------
cat > "$ROUTERS/users.py" <<'PY'
from fastapi import APIRouter, HTTPException, Depends
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import verify_password, create_access_token

router = APIRouter()

@router.post("/login")
def login(form_data: OAuth2PasswordRequestForm = Depends()):
    q = text("SELECT id, username, password_hash, role FROM users WHERE username=:u")
    with engine.begin() as c:
        row = c.execute(q, {"u": form_data.username}).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    if not verify_password(form_data.password, row.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token(sub=row.username)
    return {"access_token": token, "token_type": "bearer", "username": row.username, "role": row.role}
PY
echo -e "${G}✔ routers/users.py ready${N}"

# ------------------------------
# 6) Health + safe metrics stub
# ------------------------------
cat > "$ROUTERS/health.py" <<'PY'
from fastapi import APIRouter
router = APIRouter()

@router.get("/health")
def health():
    return {"ok": True}
PY

cat > "$ROUTERS/metrics.py" <<'PY'
from fastapi import APIRouter, Query
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/metrics/trends")
def trends(d: str = Query(..., description="YYYY-MM-DD")):
    # Try a lightweight count from offers if it exists; otherwise return empty stats
    try:
        with engine.begin() as c:
            c.execute(text("SELECT 1 FROM offers LIMIT 1"))
        with engine.begin() as c:
            rows = c.execute(text("""
                SELECT COALESCE(route_type,'(none)') AS rt, COUNT(*) AS cnt
                FROM offers
                WHERE (price_effective_date = :d OR updated_at::date = :d OR created_at::date = :d)
                GROUP BY rt ORDER BY cnt DESC LIMIT 10
            """), {"d": d}).mappings().all()
        return {"date": d, "series": rows}
    except Exception:
        return {"date": d, "series": []}
PY
echo -e "${G}✔ routers/health.py & metrics stub ready${N}"

# ------------------------------
# 7) Safe main.py bootstrap
# ------------------------------
cat > "$API_DIR/main.py" <<'PY'
import time, logging
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from app.core.database import engine
from app.migrations_users import ensure_users

log = logging.getLogger("uvicorn")

def wait_for_db(max_tries: int = 60, delay: float = 1.0):
    for i in range(max_tries):
        try:
            with engine.connect() as c:
                c.execute(text("SELECT 1"))
            return
        except Exception as e:
            time.sleep(delay)
    # Don't crash app; just log. Routers that need DB will 500 until DB is up.
    log.error("DB not reachable after wait; continuing anyway")

app = FastAPI(title="SMS Procurement Manager")

# Permissive CORS (Bearer tokens, no cookies)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
def _startup():
    wait_for_db()
    try:
        ensure_users()
    except Exception as e:
        log.error("ensure_users() failed: %s", e)

# Include routers if available
try:
    from app.routers.health import router as health_router
    app.include_router(health_router, tags=["Health"])
except Exception as e:
    log.warning("health router missing: %s", e)

try:
    from app.routers.users import router as users_router
    app.include_router(users_router, prefix="/users", tags=["Users"])
except Exception as e:
    log.warning("users router missing: %s", e)

# Optional routers (best-effort; if code missing/broken, app still runs)
for _r in [
    ("conf", "/conf", "Config"),
    ("suppliers", "/suppliers", "Suppliers"),
    ("connections", "/connections", "Connections"),
    ("countries", "/countries", "Countries"),
    ("networks", "/networks", "Networks"),
    ("offers", "/offers", "Offers"),
    ("offers_plus", "/offers_plus", "Offers+"),
    ("lookups", "/lookups", "Lookups"),
    ("parsers", "/parsers", "Parsers"),
    ("metrics", "", "Metrics"),
]:
    mod, prefix, tag = _r
    try:
        modobj = __import__(f"app.routers.{mod}", fromlist=["router"])
        app.include_router(modobj.router, prefix=prefix, tags=[tag])
    except Exception as e:
        log.warning("%s router skipped: %s", mod, e)

@app.get("/")
def root():
    return {"app": "SMS Procurement Manager", "ok": True}
PY
echo -e "${G}✔ main.py installed (CORS + health + login + safe includes)${N}"

# ------------------------------
# 8) docker-compose with PG healthcheck
# ------------------------------
cp -a "$COMPOSE" "$COMPOSE.bak.$(date +%s)" 2>/dev/null || true
cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: smsdb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d smsdb || exit 1"]
      interval: 2s
      timeout: 2s
      retries: 30
      start_period: 2s
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [stack]

  api:
    build:
      context: .
      dockerfile: api.Dockerfile
    environment:
      - DB_URL=postgresql://postgres:postgres@postgres:5432/smsdb
      - SECRET_KEY=dev-secret-key-change-me
      - ACCESS_TOKEN_EXPIRE_MINUTES=720
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8010:8000"
    networks: [stack]

  web:
    build:
      context: .
      dockerfile: web.Dockerfile
    depends_on: [api]
    ports:
      - "5183:80"
    networks: [stack]

volumes:
  pgdata:

networks:
  stack:
YAML
echo -e "${G}✔ docker-compose.yml updated (PG healthcheck + depends_on)${N}"

# ------------------------------
# 9) Rebuild & start
# ------------------------------
echo -e "${Y}🐳 Rebuilding images…${N}"
docker compose -f "$COMPOSE" build

echo -e "${Y}🚀 Starting stack…${N}"
docker compose -f "$COMPOSE" down --remove-orphans || true
docker compose -f "$COMPOSE" up -d

# ------------------------------
# 10) Health checks
# ------------------------------
sleep 4
IP=$(hostname -I | awk '{print $1}')
API="http://${IP}:8010/openapi.json"
UI="http://${IP}:5183"

echo -e "${Y}🌐 Checking API: ${API}${N}"
if curl -s --max-time 10 "$API" | grep -q '"openapi"'; then
  echo -e "${G}✔ API reachable${N}"
else
  echo -e "${R}✖ API not reachable. Recent logs:${N}"
  docker compose -f "$COMPOSE" logs --no-color --tail=200 api || true
  exit 1
fi

echo -e "${Y}🌐 Checking UI: ${UI}${N}"
if curl -s --max-time 10 "$UI" | grep -qi '<!doctype html>'; then
  echo -e "${G}✔ UI reachable${N}"
else
  echo -e "${R}✖ UI not reachable. Nginx logs:${N}"
  docker compose -f "$COMPOSE" logs --no-color --tail=120 web || true
  exit 1
fi

echo -e "${G}✅ Done. You can log in at ${UI} (admin/admin123).${N}"
echo "If the frontend points to a wrong API, run in browser console:"
echo "  localStorage.setItem('API_BASE','http://${IP}:8010'); location.reload();"
