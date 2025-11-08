from fastapi import APIRouter, Depends
from app.core.auth import get_current_user
router = APIRouter(prefix="/parsers", tags=["Parsers"])

@router.get("/")
def list_parsers(current=Depends(get_current_user)):
    # Stub to satisfy UI
    return {"templates": [], "notes": "WYSIWYG to be implemented"}
