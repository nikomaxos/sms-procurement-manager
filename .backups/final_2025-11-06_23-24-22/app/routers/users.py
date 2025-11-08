from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session
from jose import jwt, JWTError

from app.core.database import get_db, SessionLocal
from app.core.auth import verify_password, get_password_hash, create_access_token, SECRET_KEY, ALGORITHM
from app.models.user import User

router = APIRouter(prefix="/users", tags=["users"])

def ensure_admin():
    with SessionLocal() as db:
        admin = db.execute(select(User).where(User.username=="admin")).scalar_one_or_none()
        if not admin:
            u = User(username="admin", password_hash=get_password_hash("admin123"), role="admin")
            db.add(u); db.commit()

@router.post("/login")
async def login(payload: dict, db: Session = Depends(get_db)):
    # JSON-only to keep it deterministic
    username = (payload or {}).get("username")
    password = (payload or {}).get("password")
    if not username or not password:
        raise HTTPException(status_code=422, detail="username/password required")

    user = db.execute(select(User).where(User.username==username)).scalar_one_or_none()
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")

    token = create_access_token({"sub": user.username, "role": user.role})
    return {"access_token": token, "token_type": "bearer", "user": {"username": user.username, "role": user.role}}

@router.get("/me")
def me(request: Request):
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        token = auth.split(" ", 1)[1]
        try:
            payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
            return {"username": payload.get("sub"), "role": payload.get("role")}
        except JWTError:
            pass
    return {"username": None, "role": None}
