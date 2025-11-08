import os, time
from typing import Dict, Any, Optional
from jose import jwt

SECRET_KEY = os.getenv("SECRET_KEY", "dev-change-me")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_SECONDS = int(os.getenv("ACCESS_TOKEN_EXPIRE_SECONDS", "86400"))

# Minimal in-memory user for dev
ADMIN_USER = {"username": "admin", "role": "admin", "password": "admin123"}

def create_access_token(payload: Dict[str, Any], ttl: Optional[int] = None) -> str:
    exp = int(time.time()) + (ttl or ACCESS_TOKEN_EXPIRE_SECONDS)
    to_encode = {**payload, "exp": exp}
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def verify_token(token: str) -> Dict[str, Any]:
    return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
