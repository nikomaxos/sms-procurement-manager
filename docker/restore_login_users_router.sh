#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUTERS="$API/routers"

mkdir -p "$CORE" "$MODELS" "$ROUTERS"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$MODELS/__init__.py"; : > "$ROUTERS/__init__.py"

# --- core/auth.py ---
cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.context import CryptContext

JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALGO = "HS256"
ACCESS_TOKEN_EXPIRE = int(os.getenv("ACCESS_TOKEN_EXPIRE", "86400"))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")

def verify_password(plain, hashed): return pwd_context.verify(plain, hashed)
def get_password_hash(p): return pwd_context.hash(p)

def create_access_token(sub:str):
    payload = {"sub": sub, "exp": int(time.time()) + ACCESS_TOKEN_EXPIRE}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGO)

def get_current_user(token: str = Depends(oauth2_scheme)) -> str:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGO])
        sub: Optional[str] = payload.get("sub")
        if not sub: raise HTTPException(status_code=401, detail="Invalid token")
        return sub
    except JWTError:
        raise HTTPException(status_code=401, detail="Could not validate credentials")
PY

# --- models: add User (keeps your Supplier* already present) ---
# If your models.py exists, append User if missing; else create a minimal file.
if [ -f "$MODELS/models.py" ]; then
  python3 - "$MODELS/models.py" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "class User(" not in s:
    add = """
class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    password_hash = Column(String, nullable=False)
    role = Column(String, default="user")
"""
    # ensure imports exist
    if "from app.core.database import Base" not in s:
        s = "from app.core.database import Base\n" + s
    if "from sqlalchemy" not in s:
        s = "from sqlalchemy import Column, Integer, String\n" + s
    s += add
    p.write_text(s)
PY
else
  cat > "$MODELS/models.py" <<'PY'
from sqlalchemy import Column, Integer, String
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    password_hash = Column(String, nullable=False)
    role = Column(String, default="user")
PY
fi

# --- migrations: ensure users table exists (idempotent) ---
cat > "$API/migrations_users.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine

def migrate_users():
    stmts = [
        """
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR UNIQUE NOT NULL,
          password_hash VARCHAR NOT NULL,
          role VARCHAR DEFAULT 'user'
        )
        """
    ]
    with engine.begin() as conn:
        for s in stmts:
            conn.execute(text(s))
PY

# --- users router ---
cat > "$ROUTERS/users.py" <<'PY'
import os
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/users", tags=["Users"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    u = db.query(models.User).filter(models.User.username == form.username).first()
    if u and auth.verify_password(form.password, u.password_hash):
        return {"access_token": auth.create_access_token(u.username), "token_type": "bearer"}
    # fallback default admin if enabled (helps first boot)
    if os.getenv("ALLOW_DEFAULT_ADMIN", "1") == "1" and form.username=="admin" and form.password=="admin123":
        return {"access_token": auth.create_access_token("admin"), "token_type":"bearer"}
    raise HTTPException(status_code=400, detail="Incorrect username or password")

@router.get("/me")
def me(user: str = Depends(auth.get_current_user)):
    return {"user": user}
PY

# --- main.py: import users router + run migrate_users on startup, keep your suppliers router intact ---
if [ ! -f "$API/main.py" ]; then
  cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations_users import migrate_users
from app.routers import users

app = FastAPI(title="SMS Procurement Manager")

origins = ["http://localhost:5183","http://127.0.0.1:5183","*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins, allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

@app.on_event("startup")
def _startup():
    migrate_users()

app.include_router(users.router)

@app.get("/")
def root(): return {"message":"API alive","version":"login-restore"}
PY
else
  python3 - <<'PY'
from pathlib import Path
p = Path.home()/ "sms-procurement-manager/api/app/main.py"
s = p.read_text()
if "from app.migrations_users import migrate_users" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom app.migrations_users import migrate_users")
if "@app.on_event(\"startup\")" not in s or "migrate_users()" not in s:
    s = s.replace("app = FastAPI", 'app = FastAPI\n\n@app.on_event("startup")\ndef _startup():\n    migrate_users()\n')
if "from app.routers import users" not in s:
    s += "\nfrom app.routers import users\napp.include_router(users.router)\n"
# ensure CORS is present (won't duplicate)
if "CORSMiddleware" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.middleware.cors import CORSMiddleware")
    s = s.replace("app = FastAPI(title=", 
                  "app = FastAPI(title=\norigins=[\"http://localhost:5183\",\"http://127.0.0.1:5183\",\"*\"]\napp.add_middleware(CORSMiddleware,allow_origins=origins,allow_credentials=True,allow_methods=[\"*\"],allow_headers=[\"*\"]) \napp = FastAPI(title=")
p.write_text(s)
print("✅ Patched main.py")
PY
fi

# --- ensure api.Dockerfile installs auth deps ---
if ! grep -q "passlib" "$ROOT/api.Dockerfile"; then
  awk '
    /pip install/ && !done {
      print "RUN pip install --no-cache-dir fastapi uvicorn[standard] sqlalchemy pydantic psycopg[binary] python-multipart \\";
      print "    passlib[bcrypt]==1.7.4 bcrypt==4.0.1 python-jose[cryptography]";
      done=1; next
    }
    {print}
  ' "$ROOT/api.Dockerfile" > "$ROOT/api.Dockerfile.tmp" && mv "$ROOT/api.Dockerfile.tmp" "$ROOT/api.Dockerfile"
fi

echo "🔁 Rebuild & start API…"
cd "$ROOT/docker"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo "⏳ Wait 3s…"; sleep 3
echo "🧪 Check route exists:"
curl -sS http://localhost:8010/openapi.json | grep -A1 '"/users/login"' || echo "users/login NOT in openapi"

echo "👤 Seed admin in DB (safe if exists)…"
docker exec -i docker-api-1 python3 - <<'PY'
from app.core.database import SessionLocal
from app.models import models
from app.core import auth
from sqlalchemy import text
db=SessionLocal()
db.execute(text("CREATE TABLE IF NOT EXISTS users(id SERIAL PRIMARY KEY, username VARCHAR UNIQUE NOT NULL, password_hash VARCHAR NOT NULL, role VARCHAR DEFAULT 'user')"))
u = db.query(models.User).filter(models.User.username=="admin").first()
if not u:
    u = models.User(username="admin", password_hash=auth.get_password_hash("admin123"), role="admin")
    db.add(u); db.commit(); print("✅ Admin user created")
else:
    print("ℹ️ Admin already exists")
db.close()
PY

echo "🔐 Try login:"
curl -sS -X POST http://localhost:8010/users/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123" | sed -e $'s/,/,\n  /g'
