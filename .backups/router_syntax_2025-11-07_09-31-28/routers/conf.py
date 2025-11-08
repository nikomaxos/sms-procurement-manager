from fastapi import APIRouter
router = APIRouter(prefix="/conf", tags=["conf"])
@router.get("/enums") def enums(): return {"countries": [], "mccmnc": [], "vendors": [], "tags": []}
