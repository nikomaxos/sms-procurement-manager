from typing import Dict, List, Any
from fastapi import APIRouter, Depends, HTTPException, Body
from sqlalchemy import text
import json
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/conf", tags=["Config"])

DEFAULT_ENUMS: Dict[str, List[str]] = {
    "route_type": ["Direct","SS7","SIM","Local Bypass"],
    "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
    "registration_required": ["Yes","No"]
}

def _ensure_table():
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """))

def _get_enums() -> Dict[str, Any]:
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key='enums';")).fetchone()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES ('enums', :v)"),
                      dict(v=json.dumps(DEFAULT_ENUMS)))
            return DEFAULT_ENUMS
        val = row.value
        if isinstance(val, str):
            try: val = json.loads(val)
            except Exception: val = {}
        return {**DEFAULT_ENUMS, **(val or {})}

@router.get("/enums")
def read_enums(current = Depends(get_current_user)):
    return _get_enums()

@router.put("/enums")
def write_enums(payload: Dict[str, Any] = Body(...), current = Depends(get_current_user)):
    # merge incoming keys (partial update supported)
    cur = _get_enums()
    for k,v in payload.items():
        cur[k] = v
    with engine.begin() as c:
        c.execute(text("UPDATE config_kv SET value=:v, updated_at=now() WHERE key='enums'"),
                  dict(v=json.dumps(cur)))
    return cur
