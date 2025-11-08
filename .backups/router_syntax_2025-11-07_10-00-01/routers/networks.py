from fastapi import APIRouter
router = APIRouter(prefix="/networks", tags=["networks"])

@router.get("/")
def list_networks():
    return []
