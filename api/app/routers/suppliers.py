from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from app.core import auth
from app.crud import suppliers as crud

router = APIRouter(prefix="/suppliers", tags=["Suppliers"])

@router.get("/", dependencies=[Depends(auth.get_current_user)])
def list_suppliers(db: Session = Depends(auth.get_db)):
    return crud.get_suppliers(db)

@router.post("/", dependencies=[Depends(auth.get_current_user)])
def create_supplier(name: str, per_delivered: bool = False, db: Session = Depends(auth.get_db)):
    return crud.create_supplier(db, name, per_delivered)

@router.post("/{supplier_id}/connections", dependencies=[Depends(auth.get_current_user)])
def add_connection(supplier_id: int, name: str, smsc: str, username: str, charge_model: str = "Per Submitted", db: Session = Depends(auth.get_db)):
    return crud.create_connection(db, supplier_id, name, smsc, username, charge_model)
