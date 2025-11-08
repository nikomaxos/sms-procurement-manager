from fastapi import APIRouter, HTTPException, Header
from typing import Optional, Dict, Any, List
from pathlib import Path
import json, imaplib

from app.core.auth import verify_token

router = APIRouter(prefix="/settings", tags=["settings"])
DATA_FILE = Path("/app/data/settings.json")

DEFAULTS = {
    "imap": {
        "host": "", "port": 993, "username": "", "password": "",
        "ssl": True, "folder": "INBOX", "enabled": False, "selected_folders": []
    },
    "scrape": {
        "enabled": False, "interval_minutes": 30, "user_agent": "Mozilla/5.0",
        "max_concurrency": 4, "start_urls": [], "allow_domains": [],
        "block_domains": [], "render_js": False
    }
}

def _auth(auth: Optional[str]):
    if not auth or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    verify_token(auth.split(" ",1)[1])

def _load():
    if DATA_FILE.exists():
        try:
            data = json.loads(DATA_FILE.read_text("utf-8"))
            for k,v in DEFAULTS.items():
                if k not in data: data[k] = v
            return data
        except Exception: pass
    _save(DEFAULTS); return DEFAULTS

def _save(d):
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    DATA_FILE.write_text(json.dumps(d, indent=2), "utf-8")

@router.get("/imap")
def get_imap(authorization: Optional[str] = Header(None)):
    _auth(authorization)
    return _load()["imap"]

@router.post("/imap")
def set_imap(body: Dict[str, Any], authorization: Optional[str] = Header(None)):
    _auth(authorization)
    d = _load(); im = d["imap"]
    im.update({k:body.get(k,im[k]) for k in im})
    _save(d)
    return {"ok": True, "imap": im}

@router.post("/imap/test")
def imap_test(body: Dict[str, Any], authorization: Optional[str] = Header(None)):
    _auth(authorization)
    host = body.get("host",""); port = int(body.get("port",993))
    user = body.get("username",""); pwd = body.get("password","")
    use_ssl = body.get("ssl",True)
    if not host or not user:
        raise HTTPException(400,"Host and username required")
    try:
        M = imaplib.IMAP4_SSL(host,port) if use_ssl else imaplib.IMAP4(host,port)
        if pwd: M.login(user,pwd)
        greet = str(M.welcome)
        try: caps = M.capability()[1]
        except: caps=[]
        try: M.logout()
        except: pass
        return {"ok":True,"greeting":greet,"caps":caps}
    except Exception as e:
        raise HTTPException(400,f"IMAP test failed: {e}")

@router.post("/imap/folders")
def imap_folders(body: Dict[str, Any], authorization: Optional[str] = Header(None)):
    _auth(authorization)
    host=body.get("host",""); port=int(body.get("port",993))
    user=body.get("username",""); pwd=body.get("password","")
    use_ssl=body.get("ssl",True)
    if not host or not user:
        raise HTTPException(400,"Host and username required")
    try:
        M = imaplib.IMAP4_SSL(host,port) if use_ssl else imaplib.IMAP4(host,port)
        if pwd: M.login(user,pwd)
        typ, data = M.list()
        folders=[]
        for d in (data or []):
            s = d.decode("utf-8","ignore") if isinstance(d,(bytes,bytearray)) else str(d)
            name = s.split('"')[-2] if '"' in s else s.split()[-1]
            folders.append(name)
        M.logout()
        return {"ok":True,"folders":sorted(set(folders))}
    except Exception as e:
        raise HTTPException(400,f"IMAP list failed: {e}")
