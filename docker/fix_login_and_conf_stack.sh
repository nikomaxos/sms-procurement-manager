#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUTERS="$API/routers"
DOCKER_DIR="$ROOT/docker"

mkdir -p "$CORE" "$MODELS" "$ROUTERS"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$MODELS/__init__.py"; : > "$ROUTERS/__init__.py"

########################################
# 0) Ensure api.Dockerfile (root-level)
########################################
if [ ! -f "$ROOT/api.Dockerfile" ]; then
  cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy pydantic \
    "psycopg[binary]" python-multipart \
    "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1" "python-jose[cryptography]"
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER
fi

########################################
# 1) DB core
########################################
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

########################################
# 2) Auth core (JWT + bcrypt)
########################################
cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import jwt, JWTError
from passlib.context import CryptContext

JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALG = "HS256"
ACCESS_TTL = int(os.getenv("ACCESS_TTL_SECONDS", "86400"))  # 1 day

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def get_password_hash(password: str) -> str:
    # avoid bcrypt 72-byte cap edge cases
    return pwd_context.hash(password[:72])

def create_access_token(sub: str) -> str:
    payload = {"sub": sub, "exp": int(time.time()) + ACCESS_TTL}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)

def get_current_user(token: str = Depends(oauth2_scheme)) -> dict:
    cred_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate":"Bearer"},
    )
    try:
        data = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
        sub = data.get("sub")
        if not sub:
            raise cred_exc
        return {"username": sub}
    except JWTError:
        raise cred_exc
PY

########################################
# 3) Models
########################################
cat > "$MODELS/models.py" <<'PY'
from sqlalchemy.orm import declarative_base
from sqlalchemy import Column, Integer, String, Boolean

from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String(64), unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    role = Column(String(16), default="admin")
PY

########################################
# 4) Migrations (users table + ensure admin)
########################################
cat > "$API/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine, SessionLocal
from app.core.auth import get_password_hash

def migrate_users():
    ddl = """
    CREATE TABLE IF NOT EXISTS users(
      id SERIAL PRIMARY KEY,
      username VARCHAR(64) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      role VARCHAR(16) DEFAULT 'admin'
    );
    """
    with engine.begin() as c:
        c.execute(text(ddl))

def ensure_admin():
    migrate_users()
    db = SessionLocal()
    try:
        row = db.execute(text("SELECT id FROM users WHERE username=:u"), {"u":"admin"}).first()
        if not row:
            db.execute(
                text("INSERT INTO users(username,password_hash,role) VALUES(:u,:p,:r)"),
                {"u":"admin","p":get_password_hash("admin123"),"r":"admin"}
            )
            db.commit()
        else:
            # keep existing; uncomment next line if you want to force reset:
            # db.execute(text("UPDATE users SET password_hash=:p WHERE username='admin'"),{"p":get_password_hash("admin123")}); db.commit()
            pass
    finally:
        db.close()
PY

########################################
# 5) Users router (login + me)
########################################
cat > "$ROUTERS/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import text
from app.core.database import SessionLocal
from app.core.auth import verify_password, create_access_token, get_current_user

router = APIRouter()

@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends()):
    db = SessionLocal()
    try:
        row = db.execute(text("SELECT username, password_hash, role FROM users WHERE username=:u"),
                         {"u": form.username}).first()
        if not row or not verify_password(form.password, row.password_hash):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
        token = create_access_token(row.username)
        return {"access_token": token, "token_type": "bearer"}
    finally:
        db.close()

@router.get("/me")
def me(user=Depends(get_current_user)):
    return {"username": user["username"]}
PY

########################################
# 6) Config router (/conf/enums GET/PUT)
########################################
cat > "$ROUTERS/conf.py" <<'PY'
from typing import Dict, List, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
import json
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct", "SS7", "SIM", "Local Bypass"],
    "known_hops": ["0-Hop", "1-Hop", "2-Hops", "N-Hops"],
    "registration_required": ["Yes", "No"],
    "sender_id_supported": ["Dynamic Alphanumeric", "Dynamic Numeric", "Short code"],
}

def _ensure_table() -> None:
    ddl = """
    CREATE TABLE IF NOT EXISTS config_kv(
      key TEXT PRIMARY KEY,
      value JSONB NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    """
    with engine.begin() as c:
        c.execute(text(ddl))

def _coerce_dict(stored: Any) -> Dict[str, Any]:
    if stored is None:
        return {}
    if isinstance(stored, (bytes, bytearray)):
        stored = stored.decode("utf-8", errors="ignore")
    if isinstance(stored, str):
        try:
            return json.loads(stored)
        except Exception:
            return {}
    if isinstance(stored, dict):
        return stored
    return {}

@router.get("/enums")
def get_enums(_: dict = Depends(get_current_user)):
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums'")).scalar()
    data = _coerce_dict(row)
    merged = dict(DEFAULT_ENUMS)
    for k, v in data.items():
        if isinstance(v, list) and all(isinstance(x, str) for x in v):
            merged[k] = v
    return merged

@router.put("/enums")
def put_enums(payload: Dict[str, List[str]] = Body(...), _: dict = Depends(get_current_user)):
    _ensure_table()
    clean: Dict[str, List[str]] = {}
    for k, v in payload.items():
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            raise HTTPException(status_code=422, detail=f"{k} must be an array of strings")
        clean[k] = v
    js = json.dumps(clean)
    upsert = text("""
      INSERT INTO config_kv (key, value, updated_at)
      VALUES ('enums', CAST(:js AS jsonb), now())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
    """)
    with engine.begin() as c:
        c.execute(upsert, {"js": js})
    merged = dict(DEFAULT_ENUMS); merged.update(clean)
    return merged
PY

########################################
# 7) Boot (single ASGI entrypoint)
########################################
cat > "$API/boot.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.migrations import migrate_users, ensure_admin

app = FastAPI(title="SMS Procurement Manager")

# CORS: permissive for LAN UI (Bearer tokens only)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# DB bootstrap
migrate_users()
ensure_admin()

# Routers
from app.routers import users as users_router
from app.routers import conf  as conf_router

app.include_router(users_router.router,  prefix="/users", tags=["Users"])
app.include_router(conf_router.router,   prefix="/conf",  tags=["Config"])

@app.get("/")
def root():
    return {"message":"OK","version":"boot","paths":["/users/login","/users/me","/conf/enums"]}
PY

# 8) main.py → always import from boot
cat > "$API/main.py" <<'PY'
from app.boot import app
PY

########################################
# 9) Build & start API, then verify
########################################
cd "$DOCKER_DIR"
docker compose up -d --build api
sleep 2

echo "== OpenAPI paths =="
curl -sS http://localhost:8010/openapi.json | python3 - <<'PY'
import sys, json
paths = json.load(sys.stdin).get("paths", {})
for k in sorted(paths.keys()):
    print(k)
PY

echo "== Try login =="
TOK="$(curl -sS -X POST http://localhost:8010/users/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin123' | python3 - <<'PY'
import sys,json
s=sys.stdin.read().strip()
print("" if not s else json.loads(s)["access_token"])
PY
)"
if [ -z "$TOK" ]; then echo "❌ login failed"; exit 1; else echo "✅ token ok (${#TOK} chars)"; fi

echo "== /users/me =="
curl -sS http://localhost:8010/users/me -H "Authorization: Bearer $TOK"; echo

echo "== /conf/enums (GET) =="
curl -sS http://localhost:8010/conf/enums -H "Authorization: Bearer $TOK"; echo
