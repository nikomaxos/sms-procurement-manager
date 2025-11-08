from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db, engine

router = APIRouter(prefix="/hot", tags=["hot"])

@router.get("/ping")
def ping():
    return {"ok": True}

def _count_offers(db: Session) -> int:
    # 1) Try OfferCurrent model (if present)
    try:
        from app.models.models import OfferCurrent  # type: ignore
        return db.query(OfferCurrent).count()
    except Exception:
        pass
    # 2) Try Offer model
    try:
        from app.models.models import Offer  # type: ignore
        return db.query(Offer).count()
    except Exception:
        pass
    # 3) Raw SQL fallbacks
    for t in ("offer_current", "offers", "offer", "offer_currents"):
        try:
            with engine.begin() as c:
                return c.execute(text(f"SELECT COUNT(*) FROM {t}")).scalar_one()
        except Exception:
            continue
    return 0

@router.get("/count")
def count(db: Session = Depends(get_db)):
    return {"offers": _count_offers(db)}
