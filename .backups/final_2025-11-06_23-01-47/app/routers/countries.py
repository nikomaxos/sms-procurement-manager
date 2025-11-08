from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/countries", tags=["Countries"])

class CountryIn(BaseModel):
    name: str
    mcc: Optional[str] = None
    mcc2: Optional[str] = None
    mcc3: Optional[str] = None

class CountryOut(CountryIn):
    id: int

@router.get("/", response_model=List[CountryOut])
def list_countries(current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,mcc,mcc2,mcc3 FROM countries ORDER BY name")).all()
    return [dict(id=r.id, name=r.name, mcc=r.mcc, mcc2=r.mcc2, mcc3=r.mcc3) for r in rows]

@router.post("/", response_model=CountryOut)
def create_country(body: CountryIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO countries(name,mcc,mcc2,mcc3)
            VALUES(:name,:mcc,:mcc2,:mcc3) RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}

@router.put("/{country_id}", response_model=CountryOut)
def update_country(country_id: int, body: CountryIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("""
            UPDATE countries SET name=:name, mcc=:mcc, mcc2=:mcc2, mcc3=:mcc3 WHERE id=:id
        """), dict(id=country_id, **body.model_dump()))
        r = c.execute(text("SELECT id,name,mcc,mcc2,mcc3 FROM countries WHERE id=:id"),
                      dict(id=country_id)).fetchone()
        if not r: raise HTTPException(404, "Not Found")
    return dict(id=r.id, name=r.name, mcc=r.mcc, mcc2=r.mcc2, mcc3=r.mcc3)

@router.delete("/{country_id}")
def delete_country(country_id: int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM countries WHERE id=:id"), dict(id=country_id))
    return {"ok": True}
