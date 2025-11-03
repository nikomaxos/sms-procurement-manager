from fastapi import APIRouter, Depends, HTTPException, Form
from sqlalchemy.orm import Session
from app.core import auth
from app.core.database import SessionLocal
from app.models import models

router = APIRouter(prefix="/users", tags=["Users"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

@router.post("/login")
def login(username: str = Form(...), password: str = Form(...), db: Session = Depends(get_db)):
    user = db.query(models.User).filter(models.User.username == username).first()
    if not user or not auth.verify_password(password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid username or password")
    token = auth.create_access_token({"sub": user.username})
    return {"access_token": token, "token_type": "bearer"}
