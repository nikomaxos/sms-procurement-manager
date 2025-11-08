from fastapi import APIRouter
router = APIRouter(prefix="/parsers", tags=["parsers"])
@router.get("/") def list_parsers(): return []
