from fastapi import APIRouter, Depends, HTTPException, status, Body, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db, engine
from app.core.auth import verify_password, get_password_hash, create_access_token

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

class LoginJSON(BaseModel):
    username: str
    password: str

@router.options("/login")
def login_options():
    return JSONResponse({}, status_code=204)

@router.post("/login")
def login(request: Request, payload: Optional[LoginJSON] = Body(None), db: Session = Depends(get_db)):
    username = None; password = None
    if payload and payload.username and payload.password:
        username, password = payload.username, payload.password
    else:
        # best-effort: read query params if a legacy form submit arrives without JSON
        q = request.query_params
        username = username or q.get("username")
        password = password or q.get("password")

    if not username or not password:
        raise HTTPException(status_code=422, detail="username/password required")

    row = db.execute(text("SELECT id, username, password_hash, role FROM users WHERE username=:u"), {"u": username}).first()
    if not row or not verify_password(password, row.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": row.username, "role": row.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": row.username, "role": row.role}}

@router.get("/me")
def me(request: Request):
    return {"ok": True}
