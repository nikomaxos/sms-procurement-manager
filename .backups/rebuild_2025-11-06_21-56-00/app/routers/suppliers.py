from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/suppliers", tags=["Suppliers"])

class SupplierIn(BaseModel):
    organization_name: str

class SupplierOut(SupplierIn):
    id: int

@router.get("/", response_model=List[SupplierOut])
def list_suppliers(current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,organization_name FROM suppliers ORDER BY organization_name")).all()
    return [dict(id=r.id, organization_name=r.organization_name) for r in rows]

@router.post("/", response_model=SupplierOut)
def create_supplier(body: SupplierIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO suppliers(organization_name) VALUES(:organization_name) RETURNING id
        """), body.model_dump()).fetchone()
    return {**body.model_dump(), "id": r.id}

@router.put("/{supplier_id}", response_model=SupplierOut)
def update_supplier(supplier_id:int, body:SupplierIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("UPDATE suppliers SET organization_name=:n WHERE id=:id"),
                  dict(id=supplier_id, n=body.organization_name))
        r = c.execute(text("SELECT id,organization_name FROM suppliers WHERE id=:id"),
                      dict(id=supplier_id)).fetchone()
        if not r: raise HTTPException(404,"Not Found")
    return dict(id=r.id, organization_name=r.organization_name)

@router.delete("/{supplier_id}")
def delete_supplier(supplier_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM suppliers WHERE id=:id"), dict(id=supplier_id))
    return {"ok": True}
