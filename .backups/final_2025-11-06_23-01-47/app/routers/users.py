from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from sqlalchemy import text
from urllib.parse import parse_qs
import json
from jose import jwt, JWTError

from app.core.database import get_db, engine
from app.core.auth import verify_password, get_password_hash, create_access_token, SECRET_KEY, ALGORITHM

router = APIRouter(prefix="/users", tags=["users"])

def _bootstrap_users():
    ddl = """
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user'
    );
    """
    with engine.begin() as conn:
        conn.exec_driver_sql(ddl)
        cnt = conn.exec_driver_sql("SELECT COUNT(*) FROM users").scalar() or 0
        if cnt == 0:
            conn.exec_driver_sql(
                "INSERT INTO users (username, password_hash, role) VALUES (%s,%s,%s)",
                ("admin", get_password_hash("admin123"), "admin"),
            )
_bootstrap_users()

@router.options("/login")
def login_options():
    return JSONResponse({}, status_code=204)

@router.post("/login")
async def login(request: Request, db: Session = Depends(get_db)):
    username = None
    password = None

    # JSON
    raw = await request.body()
    txt = raw.decode("utf-8", "ignore") if raw else ""
    if txt:
        try:
            data = json.loads(txt)
            if isinstance(data, dict):
                username = data.get("username") or data.get("user") or data.get("email")
                password = data.get("password") or data.get("pass")
        except Exception:
            pass

    # Form (multipart/x-www-form-urlencoded)
    if not (username and password):
        try:
            form = await request.form()
            username = username or form.get("username") or form.get("user") or form.get("email")
            password = password or form.get("password") or form.get("pass")
        except Exception:
            pass

    # Raw urlencoded
    if not (username and password) and txt and "=" in txt:
        qs = parse_qs(txt)
        username = username or (qs.get("username") or qs.get("user") or qs.get("email") or [None])[0]
        password = password or (qs.get("password") or qs.get("pass") or [None])[0]

    # Query params
    if not (username and password):
        q = request.query_params
        username = username or q.get("username") or q.get("user") or q.get("email")
        password = password or q.get("password") or q.get("pass")

    if not (username and password):
        raise HTTPException(status_code=422, detail="username/password required")

    row = db.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), {"u": username}).first()
    if not row or not verify_password(password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": row.username, "role": row.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": row.username, "role": row.role}}

@router.get("/me")
def me(request: Request):
    # Very light auth: read Bearer token and decode; if invalid, anonymous
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        token = auth.split(" ", 1)[1]
        try:
            payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
            return {"username": payload.get("sub"), "role": payload.get("role")}
        except JWTError:
            pass
    return {"username": None, "role": None}
