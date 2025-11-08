from typing import Dict, Any
from fastapi import APIRouter, Depends, Body, HTTPException
from sqlalchemy import text
import json, imaplib, ssl
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/settings", tags=["Settings"])

def _ensure_table():
    with engine.begin() as c:
        c.execute(text("""
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );"""))

def _get(key:str, default:Dict[str,Any]):
    _ensure_table()
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key=:k"), dict(k=key)).fetchone()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES (:k,:v)"),
                      dict(k=key, v=json.dumps(default)))
            return default
        val = row.value
        if isinstance(val, str):
            try: val = json.loads(val)
            except Exception: val = default
        return {**default, **(val or {})}

def _set(key:str, value:Dict[str,Any]):
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value,updated_at) VALUES(:k,:v,now()) "
                       "ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()"),
                  dict(k=key, v=json.dumps(value)))

DEFAULT_IMAP = {"host":"", "port":993, "username":"", "password":"", "use_ssl":True, "folders":[]}

@router.get("/imap")
def read_imap(current=Depends(get_current_user)):
    return _get("imap", DEFAULT_IMAP)

@router.put("/imap")
def write_imap(payload: Dict[str,Any] = Body(...), current=Depends(get_current_user)):
    cur = _get("imap", DEFAULT_IMAP)
    cur.update({k: payload.get(k, cur.get(k)) for k in DEFAULT_IMAP.keys()})
    _set("imap", cur)
    return cur

@router.post("/imap/test")
def test_imap(payload: Dict[str,Any] = Body(None), current=Depends(get_current_user)):
    cfg = _get("imap", DEFAULT_IMAP)
    if payload: cfg.update({k: payload.get(k, cfg.get(k)) for k in DEFAULT_IMAP.keys()})
    host, port, user, pwd, use_ssl = cfg["host"], int(cfg["port"]), cfg["username"], cfg["password"], bool(cfg["use_ssl"])
    if not host or not user:
        raise HTTPException(400, "Host and Username are required")
    try:
        if use_ssl: M = imaplib.IMAP4_SSL(host, port)
        else:
            M = imaplib.IMAP4(host, port)
            M.starttls(ssl_context=ssl.create_default_context())
        typ, _ = M.login(user, pwd)
        if typ != "OK": raise HTTPException(401, "Login failed")
        typ, boxes = M.list()
        M.logout()
        folders = []
        if typ == "OK" and boxes:
            for line in boxes:
                name = line.decode(errors="ignore").split(' "/" ',1)[-1].strip().strip('"')
                if name: folders.append(name)
        return {"ok": True, "folders": folders[:100]}
    except imaplib.IMAP4.error as e:
        raise HTTPException(401, f"IMAP error: {e}")
    except Exception as e:
        raise HTTPException(500, f"IMAP connect failed: {e}")

DEFAULT_SCRAPE = {
    "enabled": False,
    "interval_seconds": 600,
    "concurrency": 2,
    "timeout_seconds": 20,
    "respect_robots": True,
    "rate_limit_per_domain": 2,
    "user_agent": "SPM-Scraper/1.0",
    "proxy_url": "",
    "allow_domains": [],
    "deny_domains": [],
    "base_urls": [],
    "headers": [],        # list of {"name":"Header-Name","value":"x"}
    "templates": []       # list of {"source":"ExampleSite","field_map":[{"field":"price","selector":".price"}]}
}

def _kv_get(key, default):
    with engine.begin() as c:
        row = c.execute(text("SELECT value FROM config_kv WHERE key=:k"), dict(k=key)).first()
        if not row:
            c.execute(text("INSERT INTO config_kv(key,value) VALUES (:k,:v)"),
                      dict(k=key, v=json.dumps(default)))
            return default
        v = row[0]
        if isinstance(v, str):
            import json as _json
            try: v = _json.loads(v)
            except Exception: v = default
        return v or default

def _kv_set(key, value):
    with engine.begin() as c:
        c.execute(text("INSERT INTO config_kv(key,value,updated_at) VALUES(:k,:v,now()) "
                       "ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()"),
                  dict(k=key, v=json.dumps(value)))

@router.get("/scrape")
def get_scrape(current=Depends(get_current_user)):
    # ensure table exists
    with engine.begin() as c:
        c.execute(text("""CREATE TABLE IF NOT EXISTS config_kv(
            key TEXT PRIMARY KEY, value JSONB NOT NULL, updated_at TIMESTAMPTZ DEFAULT now()
        )"""))
    return _kv_get("scrape", DEFAULT_SCRAPE)

@router.put("/scrape")
def put_scrape(payload: dict, current=Depends(get_current_user)):
    cur = _kv_get("scrape", DEFAULT_SCRAPE)
    # merge limited keys only
    for k in DEFAULT_SCRAPE.keys():
        if k in payload: cur[k] = payload[k]
    _kv_set("scrape", cur)
    return cur

@router.post("/scrape/test")
def test_scrape(payload: dict|None=None, current=Depends(get_current_user)):
    # lightweight validation only (we are not running the scraper here)
    cfg = _kv_get("scrape", DEFAULT_SCRAPE)
    if payload:
        for k in DEFAULT_SCRAPE.keys():
            if k in payload: cfg[k] = payload[k]
    if not isinstance(cfg.get("interval_seconds"), int) or cfg["interval_seconds"] < 30:
        return {"ok": False, "error": "interval_seconds should be >= 30"}
    if not isinstance(cfg.get("concurrency"), int) or cfg["concurrency"] < 1:
        return {"ok": False, "error": "concurrency should be >= 1"}
    return {"ok": True}
