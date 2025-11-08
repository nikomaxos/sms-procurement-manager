from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.models.kv import KVSetting

router = APIRouter(prefix="/conf", tags=["conf"])

ENUM_KEYS = ["countries","mccmnc","vendors","tags"]

def _get(db: Session, key: str):
    return db.query(KVSetting).filter(KVSetting.key==key).one_or_none()

@router.get("/enums")
def get_enums(db: Session = Depends(get_db)):
    out = {}
    for k in ENUM_KEYS:
        row = _get(db, f"enums.{k}")
        out[k] = (row.value if row else [])
    return out

@router.put("/enums")
def put_enums(payload: dict, db: Session = Depends(get_db)):
    # payload like {"countries":[...], "mccmnc":[...], ...}
    for k in ENUM_KEYS:
        lst = payload.get(k, [])
        if not isinstance(lst, list):
            raise HTTPException(400, f"{k} must be a list")
        row = _get(db, f"enums.{k}")
        if row is None:
            row = KVSetting(key=f"enums.{k}", value=lst)
            db.add(row)
        else:
            row.value = lst
    db.commit()
    return {"ok": True}
