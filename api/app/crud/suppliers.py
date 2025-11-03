from sqlalchemy.orm import Session
from app.models import models

def get_suppliers(db: Session):
    return db.query(models.Supplier).all()

def create_supplier(db: Session, name: str, per_delivered: bool):
    s = models.Supplier(organization_name=name, per_delivered=per_delivered)
    db.add(s)
    db.commit()
    db.refresh(s)
    return s

def create_connection(db: Session, supplier_id: int, name: str, smsc: str, username: str, charge_model: str):
    c = models.SupplierConnection(
        supplier_id=supplier_id,
        connection_name=name,
        kannel_smsc=smsc,
        username=username,
        charge_model=charge_model,
    )
    db.add(c)
    db.commit()
    db.refresh(c)
    return c
