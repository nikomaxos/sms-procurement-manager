#!/usr/bin/env bash
set -euo pipefail
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'

ROOT="$HOME/sms-procurement-manager"
API_DIR="$ROOT/api/app"
CORE_DIR="$API_DIR/core"
ROUTERS_DIR="$API_DIR/routers"
COMPOSE="$ROOT/docker-compose.yml"

AUTH_PY="$CORE_DIR/auth.py"
USERS_PY="$ROUTERS_DIR/users.py"
MAIN_PY="$API_DIR/main.py"

ts="$(date +%F_%H-%M-%S)"
mkdir -p "$ROOT/.backups" "$CORE_DIR" "$ROUTERS_DIR"

echo -e "${Y}• Backing up files…${N}"
[[ -f "$AUTH_PY"  ]] && cp -a "$AUTH_PY"  "$ROOT/.backups/auth.py.$ts.bak"  || true
[[ -f "$USERS_PY" ]] && cp -a "$USERS_PY" "$ROOT/.backups/users.py.$ts.bak" || true
[[ -f "$MAIN_PY"  ]] && cp -a "$MAIN_PY"  "$ROOT/.backups/main.py.$ts.bak"  || true

# 1) Provide a solid auth core with hashing + JWT creation
echo -e "${Y}• Writing core/auth.py (hashing + JWT)…${N}"
cat > "$AUTH_PY" <<'PY'
import os
from datetime import datetime, timedelta, timezone
from typing import Dict, Any, Optional
from jose import jwt
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "change-me-in-prod")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "1440"))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)

def create_access_token(data: Dict[str, Any], expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
PY

# 2) Create a robust users router that accepts JSON login and seeds admin if empty
echo -e "${Y}• Writing routers/users.py (login, me, admin create, change password)…${N}"
cat > "$USERS_PY" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, status, Body, Request
from pydantic import BaseModel, Field
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db, engine
from app.core.auth import verify_password, get_password_hash, create_access_token

router = APIRouter(prefix="/users", tags=["users"])

# Ensure table exists and seed admin if empty
def _ensure_users():
    create_sql = """
    CREATE TABLE IF NOT EXISTS users(
      id SERIAL PRIMARY KEY,
      username VARCHAR(150) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      role VARCHAR(32) DEFAULT 'user',
      is_active BOOLEAN DEFAULT TRUE
    );
    """
    with engine.begin() as c:
        c.execute(text(create_sql))
        # seed admin if table is empty
        cnt = c.execute(text("SELECT COUNT(*) FROM users")).scalar_one()
        if cnt == 0:
            c.execute(
                text("INSERT INTO users(username, password_hash, role, is_active) VALUES (:u,:p,:r,TRUE)"),
                {"u": "admin", "p": get_password_hash("admin123"), "r": "admin"}
            )

class LoginPayload(BaseModel):
    username: str
    password: str

class NewUserPayload(BaseModel):
    username: str = Field(min_length=3, max_length=150)
    password: str = Field(min_length=4, max_length=128)
    role: str = "user"
    is_active: bool = True

class PWChangePayload(BaseModel):
    current_password: str
    new_password: str = Field(min_length=4, max_length=128)

def _get_user_row(db: Session, username: str):
    return db.execute(
        text("SELECT id, username, password_hash, role, is_active FROM users WHERE username=:u"),
        {"u": username}
    ).fetchone()

@router.post("/login")
async def login(request: Request, db: Session = Depends(get_db)):
    """
    Accepts JSON: {"username":"...", "password":"..."}.
    Returns: {"access_token": "...", "token_type": "bearer"}
    """
    _ensure_users()
    # allow JSON or form fallback
    payload: Optional[LoginPayload] = None
    try:
        data = await request.json()
        payload = LoginPayload(**data)
    except Exception:
        form = await request.form()
        if "username" in form and "password" in form:
            payload = LoginPayload(username=form["username"], password=form["password"])
    if not payload:
        raise HTTPException(status_code=422, detail="username/password required")

    row = _get_user_row(db, payload.username)
    if not row or not verify_password(payload.password, row[2]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    token = create_access_token({"sub": row[1], "role": row[3]})
    return {"access_token": token, "token_type": "bearer"}

@router.get("/me")
def me(authorization: Optional[str] = None, db: Session = Depends(get_db)):
    """
    A light 'me' endpoint reading user from token (Bearer …).
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1]
    # minimal decode without full dependency – trust token 'sub'
    from jose import jwt, JWTError
    from app.core.auth import SECRET_KEY, ALGORITHM
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username = payload.get("sub")
        if not username:
            raise HTTPException(status_code=401, detail="Invalid token payload")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    row = _get_user_row(db, username)
    if not row:
        raise HTTPException(status_code=401, detail="User not found")
    return {"id": row[0], "username": row[1], "role": row[3], "is_active": row[4]}

@router.post("/")
def create_user(body: NewUserPayload, authorization: Optional[str] = None, db: Session = Depends(get_db)):
    """
    Admin-only: create a user.
    """
    # simple admin check using token (role in token)
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1]
    from jose import jwt, JWTError
    from app.core.auth import SECRET_KEY, ALGORITHM
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("role") != "admin":
            raise HTTPException(status_code=403, detail="Admin only")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    exists = db.execute(text("SELECT 1 FROM users WHERE username=:u"), {"u": body.username}).fetchone()
    if exists:
        raise HTTPException(status_code=409, detail="Username already exists")

    db.execute(
        text("INSERT INTO users(username, password_hash, role, is_active) VALUES (:u,:p,:r,:a)"),
        {"u": body.username, "p": get_password_hash(body.password), "r": body.role, "a": body.is_active}
    )
    db.commit()
    return {"ok": True}

@router.post("/change_password")
def change_password(body: PWChangePayload, authorization: Optional[str] = None, db: Session = Depends(get_db)):
    """
    Authenticated users can change their own password.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.split(" ", 1)[1]
    from jose import jwt, JWTError
    from app.core.auth import SECRET_KEY, ALGORITHM
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username = payload.get("sub")
        if not username:
            raise HTTPException(status_code=401, detail="Invalid token payload")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    row = _get_user_row(db, username)
    if not row or not verify_password(body.current_password, row[2]):
        raise HTTPException(status_code=401, detail="Wrong current password")

    db.execute(
        text("UPDATE users SET password_hash=:p WHERE id=:id"),
        {"p": get_password_hash(body.new_password), "id": row[0]}
    )
    db.commit()
    return {"ok": True}
PY

# 3) Rebuild API and start
echo -e "${Y}• Rebuilding API image…${N}"
docker compose -f "$COMPOSE" build api >/dev/null

echo -e "${Y}• Restarting API…${N}"
docker compose -f "$COMPOSE" up -d api >/dev/null

# 4) Quick smoke: show if users router is mounted now
sleep 3
IP=$(hostname -I | awk '{print $1}')
echo -e "${Y}• Checking endpoints…${N}"
curl -s "http://${IP}:8010/openapi.json" | grep -Eo '"/users/(login|me|change_password)"' | sort -u || true
echo
echo -e "${G}✔ If you see /users/login above, the router is live.${N}"
echo -e "${Y}Try logging in with:${N}  username: admin   password: admin123"
