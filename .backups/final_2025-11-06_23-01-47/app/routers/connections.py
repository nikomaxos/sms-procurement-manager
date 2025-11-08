from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/suppliers/{supplier_id}/connections", tags=["Connections"])

class ConnIn(BaseModel):
    connection_name: str
    username: Optional[str] = None
    kannel_smsc: Optional[str] = None
    per_delivered: Optional[bool] = False
    charge_model: Optional[str] = "Per Submitted"

class ConnOut(ConnIn):
    id: int
    supplier_id: int

@router.get("/", response_model=List[ConnOut])
def list_conns(supplier_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE supplier_id=:sid ORDER BY id
        """), dict(sid=supplier_id)).all()
    return [dict(id=r.id, supplier_id=r.supplier_id, connection_name=r.connection_name, username=r.username,
                 kannel_smsc=r.kannel_smsc, per_delivered=r.per_delivered, charge_model=r.charge_model) for r in rows]

@router.post("/", response_model=ConnOut)
def create_conn(supplier_id:int, body:ConnIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO supplier_connections(supplier_id,connection_name,username,kannel_smsc,per_delivered,charge_model)
            VALUES(:sid,:n,:u,:k,:p,:cm) RETURNING id
        """), dict(sid=supplier_id, n=body.connection_name, u=body.username, k=body.kannel_smsc,
                   p=bool(body.per_delivered), cm=body.charge_model)).fetchone()
    return {**body.model_dump(), "id": r.id, "supplier_id": supplier_id}

@router.put("/{conn_id}", response_model=ConnOut)
def update_conn(supplier_id:int, conn_id:int, body:ConnIn, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("""
            UPDATE supplier_connections
            SET connection_name=:n, username=:u, kannel_smsc=:k, per_delivered=:p, charge_model=:cm
            WHERE id=:cid AND supplier_id=:sid
        """), dict(cid=conn_id, sid=supplier_id, n=body.connection_name, u=body.username,
                   k=body.kannel_smsc, p=bool(body.per_delivered), cm=body.charge_model))
        r = c.execute(text("""
            SELECT id, supplier_id, connection_name, username, kannel_smsc, per_delivered, charge_model
            FROM supplier_connections WHERE id=:cid AND supplier_id=:sid
        """), dict(cid=conn_id, sid=supplier_id)).fetchone()
        if not r: raise HTTPException(404,"Not Found")
    return dict(id=r.id, supplier_id=r.supplier_id, connection_name=r.connection_name, username=r.username,
                kannel_smsc=r.kannel_smsc, per_delivered=r.per_delivered, charge_model=r.charge_model)

@router.delete("/{conn_id}")
def delete_conn(supplier_id:int, conn_id:int, current=Depends(get_current_user)):
    with engine.begin() as c:
        c.execute(text("DELETE FROM supplier_connections WHERE id=:cid AND supplier_id=:sid"),
                  dict(cid=conn_id, sid=supplier_id))
    return {"ok": True}
