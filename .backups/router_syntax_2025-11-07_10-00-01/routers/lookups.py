from fastapi import APIRouter, Query
from sqlalchemy import text
from app.core.database import engine

router = APIRouter()

@router.get("/suppliers")
def suppliers(q: str = Query("", description="search term")):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, organization_name FROM suppliers
            WHERE (:q = '' OR organization_name ILIKE '%'||:q||'%')
            ORDER BY organization_name LIMIT 50
        """), {"q": q}).mappings().all()
    return rows

@router.get("/connections")
def connections(supplier_id: int | None = None):
    if supplier_id is None:
        return []
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, connection_name FROM supplier_connections
            WHERE supplier_id=:sid ORDER BY connection_name
        """), {"sid": supplier_id}).mappings().all()
    return rows

@router.get("/countries")
def countries(q: str = ""):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT id, name, mcc, mcc2, mcc3 FROM countries
            WHERE (:q = '' OR name ILIKE '%'||:q||'%')
            ORDER BY name LIMIT 50
        """), {"q": q}).mappings().all()
    return rows

@router.get("/networks")
def networks(q: str = ""):
    with engine.begin() as c:
        rows = c.execute(text("""
            SELECT n.id, n.name, c.name AS country
            FROM networks n LEFT JOIN countries c ON c.id=n.country_id
            WHERE (:q = '' OR n.name ILIKE '%'||:q||'%')
            ORDER BY n.name LIMIT 50
        """), {"q": q}).mappings().all()
    return rows
