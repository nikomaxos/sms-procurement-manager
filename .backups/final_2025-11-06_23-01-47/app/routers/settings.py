from fastapi import APIRouter
router = APIRouter(prefix="/settings", tags=["settings"])

@router.get("/imap")
def get_imap():
    return {}

@router.post("/imap")
def set_imap(cfg: dict):
    return {"ok": True, "saved": cfg}

@router.get("/scrape")
def get_scrape():
    return {}

@router.post("/scrape")
def set_scrape(cfg: dict):
    return {"ok": True, "saved": cfg}
