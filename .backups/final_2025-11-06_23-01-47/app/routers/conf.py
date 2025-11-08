from fastapi import APIRouter
router = APIRouter(prefix="/conf", tags=["conf"])

@router.get("/enums")
def enums():
    # Minimal stub to satisfy UI
    return {
      "countries": [],
      "mccmnc": [],
      "vendors": [],
      "tags": [],
    }
