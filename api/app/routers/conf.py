from fastapi import APIRouter, HTTPException, Header
from typing import Optional, Dict, Any
from pathlib import Path
import json

from app.core.auth import verify_token

router = APIRouter(prefix="/conf", tags=["conf"])

DATA_FILE = Path("/app/data/conf_enums.json")

DEFAULT_ENUMS = {
    "countries": ["GR", "RO", "BG", "ES"],
    "mccmnc":   ["20201","22601","28401","21401"],
    "vendors":  ["VendorA","VendorB","VendorC"],
    "tags":     ["whitelist","blacklist","promo","otp"]
}

def _require_auth(authorization: Optional[str]) -> Dict[str, Any]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Unauthorized")
    token = authorization.split(" ", 1)[1]
    try:
        return verify_token(token)
    except Exception:
        raise HTTPException(status_code=401, detail="Unauthorized")

def _load() -> Dict[str, Any]:
    if DATA_FILE.exists():
        try:
            with DATA_FILE.open("r", encoding="utf-8") as f:
                data = json.load(f)
                # basic shape guard
                for k in DEFAULT_ENUMS:
                    if k not in data or not isinstance(data[k], list):
                        data[k] = DEFAULT_ENUMS[k]
                return data
        except Exception:
            pass
    # seed defaults if file missing/broken
    _save(DEFAULT_ENUMS)
    return DEFAULT_ENUMS

def _save(data: Dict[str, Any]) -> None:
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    with DATA_FILE.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

@router.get("/enums")
def get_enums(authorization: Optional[str] = Header(None)):
    _require_auth(authorization)
    return _load()

@router.post("/enums")
def set_enums(body: Dict[str, Any], authorization: Optional[str] = Header(None)):
    _require_auth(authorization)
    # sanitize payload
    cleaned = {}
    for k in ("countries","mccmnc","vendors","tags"):
        v = body.get(k, [])
        if isinstance(v, list):
            # coerce to strings and unique
            cleaned[k] = sorted({str(x).strip() for x in v if str(x).strip()})
        else:
            cleaned[k] = DEFAULT_ENUMS[k]
    _save(cleaned)
    return {"ok": True, "saved": cleaned}
