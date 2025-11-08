from fastapi import APIRouter, HTTPException, Header
from pydantic import BaseModel
from typing import Optional
from app.core.auth import ADMIN_USER, create_access_token, verify_token

router = APIRouter(prefix="/users", tags=["users"])

class LoginBody(BaseModel):
    username: str
    password: str

@router.post("/login")
def login(b: LoginBody):
    if b.username == ADMIN_USER["username"] and b.password == ADMIN_USER["password"]:
        token = create_access_token({"sub": ADMIN_USER["username"], "role": ADMIN_USER["role"]})
        return {"access_token": token, "token_type": "bearer", "user": {"username": ADMIN_USER["username"], "role": ADMIN_USER["role"]}}
    raise HTTPException(status_code=401, detail="Invalid credentials")

@router.get("/me")
def me(authorization: Optional[str] = Header(None)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.split(" ", 1)[1]
    try:
        claims = verify_token(token)
        return {"username": claims.get("sub", "unknown"), "role": claims.get("role", "user")}
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
