from fastapi import APIRouter
router = APIRouter(prefix="/offers", tags=["offers"])
@router.get("/") def list_offers(limit: int = 50, offset: int = 0): return {"count": 0, "results": []}
