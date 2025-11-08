from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.core.database import get_db
from app.models.kv import KVSetting
import ssl, imaplib

router = APIRouter(prefix="/settings", tags=["settings"])

def kv_get(db: Session, key: str, default):
    row = db.query(KVSetting).filter(KVSetting.key==key).one_or_none()
    return row.value if row else default

def kv_put(db: Session, key: str, value):
    row = db.query(KVSetting).filter(KVSetting.key==key).one_or_none()
    if row is None:
        row = KVSetting(key=key, value=value)
        db.add(row)
    else:
        row.value = value
    db.commit()

@router.get("/imap")
def get_imap(db: Session = Depends(get_db)):
    return kv_get(db, "imap", {
        "host": "", "port": 993, "username": "", "password": "",
        "ssl": True, "folder": "INBOX", "enabled": False
    })

@router.put("/imap")
def put_imap(cfg: dict, db: Session = Depends(get_db)):
    # minimal validation
    if not isinstance(cfg, dict): raise HTTPException(400, "Invalid IMAP config")
    cfg.setdefault("port", 993); cfg.setdefault("ssl", True)
    cfg.setdefault("folder","INBOX"); cfg.setdefault("enabled", False)
    kv_put(db, "imap", cfg)
    return {"ok": True}

@router.post("/imap/test")
def test_imap(db: Session = Depends(get_db)):
    cfg = kv_get(db, "imap", {})
    host = cfg.get("host"); port = int(cfg.get("port", 993))
    user = cfg.get("username"); pwd = cfg.get("password")
    use_ssl = bool(cfg.get("ssl", True))
    if not host or not user or not pwd:
        raise HTTPException(400, "Set host/username/password first")
    try:
        if use_ssl:
            ctx = ssl.create_default_context()
            with imaplib.IMAP4_SSL(host, port, ssl_context=ctx) as M:
                M.login(user, pwd)
                typ, _ = M.select(cfg.get("folder","INBOX"))
                return {"ok": typ=="OK"}
        else:
            with imaplib.IMAP4(host, port) as M:
                M.login(user, pwd)
                typ, _ = M.select(cfg.get("folder","INBOX"))
                return {"ok": typ=="OK"}
    except Exception as e:
        raise HTTPException(400, f"IMAP connect failed: {e}")

@router.get("/scrape")
def get_scrape(db: Session = Depends(get_db)):
    return kv_get(db, "scrape", {
        "enabled": False,
        "interval_minutes": 30,
        "user_agent": "Mozilla/5.0",
        "max_concurrency": 4,
        "start_urls": [],
        "allow_domains": [],
        "block_domains": [],
        "render_js": False
    })

@router.put("/scrape")
def put_scrape(cfg: dict, db: Session = Depends(get_db)):
    if not isinstance(cfg, dict): raise HTTPException(400, "Invalid scrape config")
    kv_put(db, "scrape", cfg)
    return {"ok": True}
