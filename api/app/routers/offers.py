from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from app.models import models
from app.core import auth
from datetime import datetime

router = APIRouter(prefix="/offers", tags=["Offers"])

@router.get("/", dependencies=[Depends(auth.get_current_user)])
def list_offers(db: Session = Depends(auth.get_db)):
    return db.query(models.OfferCurrent).all()

@router.post("/", dependencies=[Depends(auth.get_current_user)])
def add_offer(supplier_id: int, connection_id: int, network_id: int, price: float, db: Session = Depends(auth.get_db)):
    o = models.OfferCurrent(
        supplier_id=supplier_id,
        connection_id=connection_id,
        network_id=network_id,
        price=price,
        updated_at=datetime.utcnow(),
    )
    db.add(o)
    db.commit()
    db.refresh(o)
    return o
