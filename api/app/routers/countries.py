from fastapi import APIRouter, HTTPException, Header
from pathlib import Path
import json
from typing import Optional, Dict, Any, List
from app.core.auth import verify_token

router=APIRouter(prefix="/countries",tags=["countries"])
F=Path("/app/data/countries.json")
def _auth(a): 
    if not a or not a.startswith("Bearer "): raise HTTPException(401)
    verify_token(a.split(" ",1)[1])
def _load():
    if F.exists():
        try: return json.loads(F.read_text("utf-8"))
        except: pass
    seed=[{"id":1,"code":"GR","name":"Greece"},{"id":2,"code":"RO","name":"Romania"}]
    _save(seed); return seed
def _save(x): F.write_text(json.dumps(x,indent=2),"utf-8")

@router.get("/")
def list_all(authorization: Optional[str]=Header(None)):
    _auth(authorization); return {"items":_load()}

@router.post("/")
def add(b:Dict[str,Any],authorization:Optional[str]=Header(None)):
    _auth(authorization); d=_load(); nid=(max([x["id"] for x in d])+1) if d else 1
    rec={"id":nid,"code":b.get("code","").upper(),"name":b.get("name","")}
    d.append(rec); _save(d); return {"ok":True,"item":rec}
