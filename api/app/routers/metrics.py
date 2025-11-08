from fastapi import APIRouter, HTTPException, Header
from typing import Optional
from app.core.auth import verify_token

router = APIRouter(prefix="/metrics", tags=["metrics"])

def _auth_ok(authorization: Optional[str]):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    verify_token(authorization.split(" ", 1)[1])

@router.get("/trends")
def trends(d: str, authorization: Optional[str] = Header(None)):
    _auth_ok(authorization)
    # Return an empty but valid series; UI will render it
    return {"date": d, "series": [{"name":"Submitted","values":[]},{"name":"Delivered","values":[]}]} 
