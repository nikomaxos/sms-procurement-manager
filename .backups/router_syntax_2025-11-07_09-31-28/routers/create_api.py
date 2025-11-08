from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List
from sqlalchemy import text
from app.core.database import engine
# Prefer the existing auth guard. If missing, fallback to a no-op.
try:
    from app.core.auth import get_current_user as auth_guard
except Exception:
    def auth_guard():
        return True

router = APIRouter()

# --- DDL: run once at import (idempotent) ---
def _ddl():
    ddls = [
        # users (in case your earlier model didn't create it)
        """CREATE TABLE IF NOT EXISTS users(
             id SERIAL PRIMARY KEY,
             username VARCHAR UNIQUE,
             password_hash VARCHAR,
             role VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS suppliers(
             id SERIAL PRIMARY KEY,
             organization_name VARCHAR NOT NULL,
             per_delivered BOOLEAN DEFAULT FALSE
        )""",
        """CREATE TABLE IF NOT EXISTS supplier_connections(
             id SERIAL PRIMARY KEY,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
             connection_name VARCHAR,
             kannel_smsc VARCHAR,
             username VARCHAR,
             charge_model VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS countries(
             id SERIAL PRIMARY KEY,
             name VARCHAR,
             mcc VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS networks(
             id SERIAL PRIMARY KEY,
             country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
             name VARCHAR,
             mnc VARCHAR,
             mccmnc VARCHAR
        )""",
        """CREATE TABLE IF NOT EXISTS offers_current(
             id SERIAL PRIMARY KEY,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
             connection_id INTEGER REFERENCES supplier_connections(id) ON DELETE SET NULL,
             network_id INTEGER REFERENCES networks(id) ON DELETE SET NULL,
             price DOUBLE PRECISION,
             currency VARCHAR(8) DEFAULT 'EUR',
             effective_date TIMESTAMP DEFAULT NOW(),
             route_type VARCHAR(64),
             known_hops VARCHAR(32),
             sender_id_supported VARCHAR(128),
             registration_required VARCHAR(16),
             eta_days INTEGER,
             charge_model VARCHAR(32),
             is_exclusive VARCHAR(8),
             notes TEXT,
             updated_by VARCHAR(128),
             updated_at TIMESTAMP DEFAULT NOW()
        )""",
        """CREATE TABLE IF NOT EXISTS email_settings(
             id INTEGER PRIMARY KEY DEFAULT 1,
             host VARCHAR,
             username VARCHAR,
             password VARCHAR,
             folder VARCHAR,
             refresh_minutes INTEGER DEFAULT 5
        )""",
        """CREATE TABLE IF NOT EXISTS parser_templates(
             id SERIAL PRIMARY KEY,
             name VARCHAR NOT NULL,
             supplier_id INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
             conditions_json JSONB,
             extract_map_json JSONB,
             callback_url VARCHAR,
             add_attrs_json JSONB,
             enabled BOOLEAN DEFAULT TRUE
        )""",
        """CREATE TABLE IF NOT EXISTS scraper_settings(
             id INTEGER PRIMARY KEY DEFAULT 1,
             base_url VARCHAR,
             username VARCHAR,
             password VARCHAR,
             cookies_json JSONB,
             endpoints_json JSONB
        )""",
        """CREATE TABLE IF NOT EXISTS dropdown_configs(
             id INTEGER PRIMARY KEY DEFAULT 1,
             route_types JSONB,
             known_hops JSONB,
             sender_id_supported JSONB,
             registration_required JSONB,
             is_exclusive JSONB
        )""",
    ]
    with engine.begin() as conn:
        for d in ddls:
            conn.execute(text(d))

_ddl()

def _row(r):
    return dict(r._mapping) if hasattr(r, "_mapping") else dict(r)

# --------- Pydantic bodies ----------
class SupplierCreate(BaseModel):
    organization_name: str
    per_delivered: bool = False

class ConnectionCreate(BaseModel):
    supplier_id: int
    connection_name: str
    kannel_smsc: str
    username: str
    charge_model: str = "Per Submitted"

class OfferCreate(BaseModel):
    supplier_id: int
    connection_id: int
    network_id: int
    price: float
    currency: str = "EUR"
    effective_date: Optional[str] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[str] = None
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    charge_model: Optional[str] = None
    is_exclusive: Optional[str] = None
    notes: Optional[str] = None

class EmailSettings(BaseModel):
    host: str
    username: str
    password: str
    folder: str
    refresh_minutes: int = 5

class TemplateCreate(BaseModel):
    name: str
    supplier_id: Optional[int] = None
    conditions_json: Optional[dict] = None
    extract_map_json: Optional[dict] = None
    callback_url: Optional[str] = None
    add_attrs_json: Optional[dict] = None
    enabled: bool = True

class ScraperSettings(BaseModel):
    base_url: Optional[str] = None
    username: Optional[str] = None
    password: Optional[str] = None
    cookies_json: Optional[dict] = None
    endpoints_json: Optional[dict] = None

class DropdownsUpdate(BaseModel):
    route_types: List[str] = Field(default_factory=lambda: ["Direct","SS7","SIM","Local Bypass"])
    known_hops: List[str] = Field(default_factory=lambda: ["0-Hop","1-Hop","2-Hops","N-Hops"])
    sender_id_supported: List[str] = Field(default_factory=lambda: ["Dynamic Alphanumeric","Dynamic Numeric","Short code"])
    registration_required: List[str] = Field(default_factory=lambda: ["Yes","No"])
    is_exclusive: List[str] = Field(default_factory=lambda: ["Yes","No"])

# --------- Suppliers & Connections ----------
@router.get("/suppliers/")
def list_suppliers(user = Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text(
            "SELECT id, organization_name, COALESCE(per_delivered,false) per_delivered FROM suppliers ORDER BY id"
        )).fetchall()
    return [_row(r) for r in rows]

@router.post("/suppliers/")
def create_supplier(body: SupplierCreate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text(
            "INSERT INTO suppliers(organization_name, per_delivered) VALUES(:n,:p) RETURNING id, organization_name, COALESCE(per_delivered,false) per_delivered"
        ), {"n": body.organization_name, "p": body.per_delivered}).fetchone()
    return _row(r)

@router.get("/suppliers/{supplier_id}/connections")
def list_connections(supplier_id:int, user = Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text(
            "SELECT id, supplier_id, connection_name, kannel_smsc, username, charge_model FROM supplier_connections WHERE supplier_id=:sid ORDER BY id"
        ), {"sid": supplier_id}).fetchall()
    return [_row(r) for r in rows]

@router.post("/suppliers/{supplier_id}/connections")
def add_connection(supplier_id:int, body: ConnectionCreate, user = Depends(auth_guard)):
    if supplier_id != body.supplier_id:
        raise HTTPException(400, "supplier_id mismatch")
    with engine.begin() as conn:
        r = conn.execute(text(
            "INSERT INTO supplier_connections(supplier_id, connection_name, kannel_smsc, username, charge_model) "
            "VALUES(:sid,:cn,:ks,:un,:cm) RETURNING id, supplier_id, connection_name, kannel_smsc, username, charge_model"
        ), {"sid": body.supplier_id, "cn": body.connection_name, "ks": body.kannel_smsc, "un": body.username, "cm": body.charge_model}).fetchone()
    return _row(r)

# --------- Offers ----------
# NOTE: GET /offers/ likely exists already in your app; we only add POST.
@router.post("/offers/")
def add_offer(body: OfferCreate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO offers_current(
                supplier_id, connection_id, network_id, price, currency, effective_date,
                route_type, known_hops, sender_id_supported, registration_required,
                eta_days, charge_model, is_exclusive, notes, updated_by
            ) VALUES(
                :supplier_id, :connection_id, :network_id, :price, :currency,
                COALESCE(NULLIF(:effective_date,''), NOW())::timestamp,
                :route_type, :known_hops, :sender_id_supported, :registration_required,
                :eta_days, :charge_model, :is_exclusive, :notes, 'webui'
            ) RETURNING *
        """), body.__dict__).fetchone()
    return _row(r)

# --------- Email settings ----------
@router.get("/email/settings")
def get_email_settings(user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT id, host, username, folder, refresh_minutes FROM email_settings WHERE id=1")).fetchone()
    return _row(r) if r else {}

@router.post("/email/settings")
def set_email_settings(body: EmailSettings, user = Depends(auth_guard)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO email_settings(id, host, username, password, folder, refresh_minutes)
            VALUES(1, :host, :username, :password, :folder, :refresh)
            ON CONFLICT (id) DO UPDATE SET
               host=EXCLUDED.host, username=EXCLUDED.username, password=EXCLUDED.password,
               folder=EXCLUDED.folder, refresh_minutes=EXCLUDED.refresh_minutes
        """), {"host":body.host, "username":body.username, "password":body.password, "folder":body.folder, "refresh":body.refresh_minutes})
    return {"ok": True}

# --------- Parser templates ----------
@router.get("/templates/")
def list_templates(user = Depends(auth_guard)):
    with engine.begin() as conn:
        rows = conn.execute(text("SELECT id, name, supplier_id, enabled FROM parser_templates ORDER BY id")).fetchall()
    return [_row(r) for r in rows]

@router.post("/templates/")
def create_template(body: TemplateCreate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("""
            INSERT INTO parser_templates(name, supplier_id, conditions_json, extract_map_json, callback_url, add_attrs_json, enabled)
            VALUES(:name,:supplier_id, :conditions_json::jsonb, :extract_map_json::jsonb, :callback_url, :add_attrs_json::jsonb, :enabled)
            RETURNING id, name, supplier_id, enabled
        """), {
            "name": body.name,
            "supplier_id": body.supplier_id,
            "conditions_json": body.conditions_json or {},
            "extract_map_json": body.extract_map_json or {},
            "callback_url": body.callback_url,
            "add_attrs_json": body.add_attrs_json or {},
            "enabled": body.enabled
        }).fetchone()
    return _row(r)

# --------- Scraper settings ----------
@router.get("/scraper/settings")
def get_scraper_settings(user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT id, base_url, username FROM scraper_settings WHERE id=1")).fetchone()
    return _row(r) if r else {}

@router.post("/scraper/settings")
def set_scraper_settings(body: ScraperSettings, user = Depends(auth_guard)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO scraper_settings(id, base_url, username, password, cookies_json, endpoints_json)
            VALUES(1, :base_url, :username, :password, :cookies::jsonb, :endpoints::jsonb)
            ON CONFLICT (id) DO UPDATE SET
               base_url=EXCLUDED.base_url, username=EXCLUDED.username, password=EXCLUDED.password,
               cookies_json=EXCLUDED.cookies_json, endpoints_json=EXCLUDED.endpoints_json
        """), {
            "base_url": body.base_url, "username": body.username, "password": body.password,
            "cookies": body.cookies_json or {}, "endpoints": body.endpoints_json or {}
        })
    return {"ok": True}

# --------- Dropdown configs ----------
@router.get("/config/dropdowns")
def get_dropdowns(user = Depends(auth_guard)):
    with engine.begin() as conn:
        r = conn.execute(text("SELECT route_types, known_hops, sender_id_supported, registration_required, is_exclusive FROM dropdown_configs WHERE id=1")).fetchone()
    if r:
        d = _row(r)
        return {k: (d.get(k) or []) for k in ["route_types","known_hops","sender_id_supported","registration_required","is_exclusive"]}
    return {
        "route_types": ["Direct","SS7","SIM","Local Bypass"],
        "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
        "sender_id_supported": ["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
        "registration_required": ["Yes","No"],
        "is_exclusive": ["Yes","No"]
    }

@router.post("/config/dropdowns")
def set_dropdowns(body: DropdownsUpdate, user = Depends(auth_guard)):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO dropdown_configs(id, route_types, known_hops, sender_id_supported, registration_required, is_exclusive)
            VALUES(1, :rt::jsonb, :kh::jsonb, :sid::jsonb, :rr::jsonb, :ie::jsonb)
            ON CONFLICT (id) DO UPDATE SET
              route_types=EXCLUDED.route_types,
              known_hops=EXCLUDED.known_hops,
              sender_id_supported=EXCLUDED.sender_id_supported,
              registration_required=EXCLUDED.registration_required,
              is_exclusive=EXCLUDED.is_exclusive
        """), {
            "rt": body.route_types, "kh": body.known_hops, "sid": body.sender_id_supported,
            "rr": body.registration_required, "ie": body.is_exclusive
        })
    return {"ok": True}
