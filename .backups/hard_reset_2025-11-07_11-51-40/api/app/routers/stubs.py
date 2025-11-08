from fastapi import APIRouter, Depends, Body
from sqlalchemy.orm import Session
from sqlalchemy import text
from typing import Any, Dict
from app.core.database import engine, get_db

router = APIRouter(tags=["stubs"])

def _bootstrap_kv():
    with engine.begin() as conn:
        conn.exec_driver_sql("""
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL DEFAULT '{}'::jsonb
        );
        """)
_bootstrap_kv()

def _get(conn, key: str) -> Dict[str, Any]:
    row = conn.exec_driver_sql("SELECT value FROM app_settings WHERE key=%s", (key,)).first()
    return (row[0] if row else {}) or {}

def _put(conn, key: str, value: Dict[str, Any]):
    conn.exec_driver_sql("INSERT INTO app_settings(key,value) VALUES (%s,%s) ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value", (key, value))

@router.get("/metrics/trends")
def trends(d: str = ""):
    # Return empty but valid series for UI
    return {"date": d, "series": []}

@router.get("/conf/enums")
def get_enums(db: Session = Depends(get_db)):
    with engine.begin() as conn:
        return _get(conn, "conf_enums")

@router.put("/conf/enums")
def put_enums(payload: Dict[str, Any] = Body(default={}), db: Session = Depends(get_db)):
    with engine.begin() as conn:
        _put(conn, "conf_enums", payload or {})
    return {"ok": True}

@router.get("/settings/imap")
def get_imap(db: Session = Depends(get_db)):
    with engine.begin() as conn:
        return _get(conn, "settings_imap")

@router.put("/settings/imap")
def put_imap(payload: Dict[str, Any] = Body(default={}), db: Session = Depends(get_db)):
    with engine.begin() as conn:
        _put(conn, "settings_imap", payload or {})
    return {"ok": True}

@router.get("/settings/scrape")
def get_scrape(db: Session = Depends(get_db)):
    with engine.begin() as conn:
        return _get(conn, "settings_scrape")

@router.put("/settings/scrape")
def put_scrape(payload: Dict[str, Any] = Body(default={}), db: Session = Depends(get_db)):
    with engine.begin() as conn:
        _put(conn, "settings_scrape", payload or {})
    return {"ok": True}
