from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import engine
try:
    from app.core.auth import get_current_user as guard
except Exception:
    def guard(): return True

router = APIRouter()

@router.get("/config/dropdowns")
def get_dropdowns(user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("SELECT * FROM dropdown_configs WHERE id=1")).mappings().first()
    if not r:
        return {}
    out = dict(r)
    # remove id
    out.pop("id", None)
    return out

@router.post("/config/dropdowns")
def set_dropdowns(body: dict, user=Depends(guard)):
    keys = ["route_types","known_hops","sender_id_supported","registration_required","is_exclusive"]
    sets = []
    params = {}
    for k in keys:
        if k in body:
            sets.append(f"{k} = :{k}::jsonb")
            params[k] = body[k]
    if not sets:
        return {"ok": True}
    q = "UPDATE dropdown_configs SET " + ", ".join(sets) + " WHERE id=1"
    with engine.begin() as c:
        c.execute(text(q), params)
    return {"ok": True}

@router.get("/parser/settings")
def get_parser_settings(user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("SELECT * FROM parser_settings WHERE id=1")).mappings().first()
    return dict(r) if r else {}

@router.post("/parser/settings")
def set_parser_settings(body: dict, user=Depends(guard)):
    # upsert into single row
    keys = ["imap_host","imap_user","imap_password","imap_folder","imap_ssl","ingest_limit","refresh_minutes"]
    sets = []
    params = {}
    for k in keys:
        if k in body:
            sets.append(f"{k} = :{k}")
            params[k] = body[k]
    if sets:
        q = "UPDATE parser_settings SET " + ", ".join(sets) + " WHERE id=1"
        with engine.begin() as c:
            c.execute(text(q), params)
    return {"ok": True}

@router.get("/parser/templates")
def list_templates(user=Depends(guard)):
    with engine.begin() as c:
        rows = c.execute(text("SELECT id,name,supplier_name,connection_name,format,mapping FROM parser_templates ORDER BY name")).mappings().all()
    return [dict(r) for r in rows]

@router.post("/parser/templates")
def upsert_template(body: dict, user=Depends(guard)):
    with engine.begin() as c:
        r = c.execute(text("""
            INSERT INTO parser_templates(name,supplier_name,connection_name,format,mapping)
            VALUES (:name,:supplier,:conn,:fmt,:mapping::jsonb)
            ON CONFLICT (name) DO UPDATE SET
              supplier_name=EXCLUDED.supplier_name,
              connection_name=EXCLUDED.connection_name,
              format=EXCLUDED.format,
              mapping=EXCLUDED.mapping
            RETURNING id
        """), {
            "name": body.get("name"),
            "supplier": body.get("supplier_name"),
            "conn": body.get("connection_name"),
            "fmt": body.get("format","csv"),
            "mapping": body.get("mapping",{})
        }).first()
    return {"id": r[0] if r else None}
