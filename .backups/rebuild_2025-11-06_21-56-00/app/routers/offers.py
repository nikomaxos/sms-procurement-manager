from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/offers", tags=["Offers"])

class OfferIn(BaseModel):
    supplier_name: str
    connection_name: str
    country_name: Optional[str] = None
    network_name: Optional[str] = None
    mccmnc: Optional[str] = None
    price: float
    price_effective_date: Optional[str] = None
    previous_price: Optional[float] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[str] = None
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    charge_model: Optional[str] = None
    is_exclusive: Optional[bool] = False
    notes: Optional[str] = None
    updated_by: Optional[str] = None

class OfferOut(OfferIn):
    id: int

@router.get("/")
def list_offers(limit:int=50, offset:int=0, current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("""
        SELECT id,supplier_name,connection_name,country_name,network_name,mccmnc,price,price_effective_date,
               previous_price,route_type,known_hops,sender_id_supported,registration_required,eta_days,
               charge_model,is_exclusive,notes,updated_by
        FROM offers ORDER BY id DESC LIMIT :l OFFSET :o
        """), dict(l=limit,o=offset)).all()
    data = [dict(id=r.id, supplier_name=r.supplier_name, connection_name=r.connection_name,
                 country_name=r.country_name, network_name=r.network_name, mccmnc=r.mccmnc,
                 price=float(r.price), price_effective_date=str(r.price_effective_date) if r.price_effective_date else None,
                 previous_price=float(r.previous_price) if r.previous_price is not None else None,
                 route_type=r.route_type, known_hops=r.known_hops, sender_id_supported=r.sender_id_supported,
                 registration_required=r.registration_required, eta_days=r.eta_days,
                 charge_model=r.charge_model, is_exclusive=r.is_exclusive, notes=r.notes, updated_by=r.updated_by)
            for r in rows]
    return {"rows": data, "total": len(data)}

@router.post("/", response_model=OfferOut)
def create_offer(body:OfferIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
          INSERT INTO offers(supplier_name,connection_name,country_name,network_name,mccmnc,price,
                             price_effective_date,previous_price,route_type,known_hops,sender_id_supported,
                             registration_required,eta_days,charge_model,is_exclusive,notes,updated_by)
          VALUES(:supplier_name,:connection_name,:country_name,:network_name,:mccmnc,:price,
                 :price_effective_date,:previous_price,:route_type,:known_hops,:sender_id_supported,
                 :registration_required,:eta_days,:charge_model,:is_exclusive,:notes,:updated_by)
          RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}
