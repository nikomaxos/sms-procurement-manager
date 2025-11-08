from fastapi import APIRouter
router = APIRouter(prefix="/metrics", tags=["metrics"])

@router.get("/trends")
def trends(d: str):
    return {"date": d, "series": []}
