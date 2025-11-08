from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/networks", tags=["Networks"])

class NetworkIn(BaseModel):
    name: str
    country_id: Optional[int] = None
    mnc: Optional[str] = None
    mccmnc: Optional[str] = None

class NetworkOut(NetworkIn):
    id: int

@router.get("/", response_model=List[NetworkOut])
def list_networks(current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,country_id,mnc,mccmnc FROM networks ORDER BY name")).all()
    return [dict(id=r.id, name=r.name, country_id=r.country_id, mnc=r.mnc, mccmnc=r.mccmnc) for r in rows]

@router.post("/", response_model=NetworkOut)
def create_network(body: NetworkIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO networks(name,country_id,mnc,mccmnc)
            VALUES(:name,:country_id,:mnc,:mccmnc) RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}

@router.put("/{network_id}", response_model=NetworkOut)
def update_network(network_id:int, body:NetworkIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("""
            UPDATE networks SET name=:name,country_id=:country_id,mnc=:mnc,mccmnc=:mccmnc WHERE id=:id
        """), dict(id=network_id, **body.model_dump()))
        r = c.execute(text("SELECT id,name,country_id,mnc,mccmnc FROM networks WHERE id=:id"),
                      dict(id=network_id)).fetchone()
        if not r: raise HTTPException(404,"Not Found")
    return dict(id=r.id, name=r.name, country_id=r.country_id, mnc=r.mnc, mccmnc=r.mccmnc)

@router.delete("/{network_id}")
def delete_network(network_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM networks WHERE id=:id"), dict(id=network_id))
    return {"ok": True}
