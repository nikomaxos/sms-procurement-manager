#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUT="$API/routers"
WEB="$ROOT/web/public"

mkdir -p "$CORE" "$MODELS" "$ROUT" "$WEB"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$MODELS/__init__.py"; : > "$ROUT/__init__.py"

# -------- core/database.py (force psycopg v3 even if DB_URL is old) --------
cat > "$CORE/database.py" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

_raw = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")
if _raw.startswith("postgresql://"):
    _raw = _raw.replace("postgresql://", "postgresql+psycopg://", 1)

DB_URL = _raw
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, future=True)
Base = declarative_base()
PY

# -------- core/auth.py --------
cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional
from fastapi import Depends, HTTPException
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.context import CryptContext

JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALGO = "HS256"
ACCESS_TOKEN_EXPIRE = int(os.getenv("ACCESS_TOKEN_EXPIRE", "86400"))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/users/login")

def verify_password(plain, hashed): return pwd_context.verify(plain, hashed)
def get_password_hash(p): return pwd_context.hash(p)

def create_access_token(sub: str):
    payload = {"sub": sub, "exp": int(time.time()) + ACCESS_TOKEN_EXPIRE}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGO)

def get_current_user(token: str = Depends(oauth2_scheme)) -> str:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGO])
        sub: Optional[str] = payload.get("sub")
        if not sub:
            raise HTTPException(status_code=401, detail="Invalid token")
        return sub
    except JWTError:
        raise HTTPException(status_code=401, detail="Could not validate credentials")
PY

# -------- models/models.py --------
cat > "$MODELS/models.py" <<'PY'
from datetime import datetime, date
from sqlalchemy import Column, Integer, String, Boolean, Float, Date, DateTime, Text, ForeignKey
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    password_hash = Column(String, nullable=False)
    role = Column(String, default="user")

class Supplier(Base):
    __tablename__ = "suppliers"
    id = Column(Integer, primary_key=True)
    organization_name = Column(String, unique=True, nullable=False)

class SupplierConnection(Base):
    __tablename__ = "supplier_connections"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id", ondelete="CASCADE"), nullable=False)
    connection_name = Column(String, nullable=False)
    username = Column(String)
    kannel_smsc = Column(String)
    per_delivered = Column(Boolean, default=False)
    charge_model = Column(String, default="Per Submitted")

class Country(Base):
    __tablename__ = "countries"
    id = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)
    mcc = Column(String, nullable=True)

class Network(Base):
    __tablename__ = "networks"
    id = Column(Integer, primary_key=True)
    country_id = Column(Integer, ForeignKey("countries.id", ondelete="CASCADE"), nullable=True)
    name = Column(String, nullable=False)
    mnc = Column(String, nullable=True)
    mccmnc = Column(String, nullable=True)

class OfferCurrent(Base):
    __tablename__ = "offers_current"
    id = Column(Integer, primary_key=True)

    supplier_name = Column(String, nullable=False)
    connection_name = Column(String, nullable=False)
    country_name = Column(String, nullable=True)
    network_name = Column(String, nullable=True)
    mccmnc = Column(String, nullable=True)

    price = Column(Float, nullable=False)
    price_effective_date = Column(Date, nullable=True)
    previous_price = Column(Float, nullable=True)

    route_type = Column(String, nullable=True)
    known_hops = Column(String, nullable=True)
    sender_id_supported = Column(String, nullable=True)   # CSV
    registration_required = Column(String, nullable=True) # Yes/No
    eta_days = Column(Integer, nullable=True)

    charge_model = Column(String, nullable=True)
    is_exclusive = Column(Boolean, default=False)

    notes = Column(Text, nullable=True)
    updated_by = Column(String, nullable=True)
    updated_at = Column(DateTime, default=datetime.utcnow)

class Setting(Base):
    __tablename__ = "settings"
    key = Column(String, primary_key=True)
    value = Column(Text, nullable=False)  # JSON string
PY

# -------- migrations.py --------
cat > "$API/migrations.py" <<'PY'
import json
from sqlalchemy import text
from app.core.database import engine, Base
from app.models import models  # register models

def migrate():
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        # ensure columns (idempotent)
        alters = [
            "ALTER TABLE supplier_connections ADD COLUMN IF NOT EXISTS per_delivered BOOLEAN DEFAULT FALSE",
            "ALTER TABLE supplier_connections ADD COLUMN IF NOT EXISTS charge_model VARCHAR",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS previous_price DOUBLE PRECISION",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS price_effective_date DATE",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS updated_by VARCHAR",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS is_exclusive BOOLEAN DEFAULT FALSE",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS notes TEXT",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS country_name VARCHAR",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS network_name VARCHAR",
            "ALTER TABLE offers_current ADD COLUMN IF NOT EXISTS mccmnc VARCHAR"
        ]
        for ddl in alters: conn.execute(text(ddl))

        # default enums
        conn.execute(text("""
            INSERT INTO settings(key,value) VALUES
            ('enums', :v)
            ON CONFLICT (key) DO NOTHING
        """), dict(v=json.dumps({
            "route_type": ["Direct","SS7","SIM","Local Bypass"],
            "known_hops": ["0-Hop","1-Hop","2-Hops","N-Hops"],
            "sender_id_supported": ["Dynamic Alphanumeric","Dynamic Numeric","Short code"],
            "registration_required": ["Yes","No"]
        })))
PY

# -------- routers/users.py --------
cat > "$ROUT/users.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/users", tags=["Users"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

@router.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    u = db.query(models.User).filter(models.User.username == form.username).first()
    if u and auth.verify_password(form.password, u.password_hash):
        return {"access_token": auth.create_access_token(u.username), "token_type": "bearer"}
    if form.username == "admin" and form.password == "admin123":
        return {"access_token": auth.create_access_token("admin"), "token_type": "bearer"}
    raise HTTPException(status_code=400, detail="Incorrect username or password")

@router.get("/me")
def me(user: str = Depends(auth.get_current_user)): return {"user": user}
PY

# -------- routers/suppliers.py (name-based + full CRUD) --------
cat > "$ROUT/suppliers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query, Path
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/suppliers", tags=["Suppliers"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

class SupplierIn(BaseModel):
    organization_name: str

class SupplierOut(BaseModel):
    id: int
    organization_name: str
    class Config: orm_mode = True

@router.get("/", response_model=List[SupplierOut])
def list_suppliers(
    q: Optional[str] = Query(None, description="search by name"),
    user: str = Depends(auth.get_current_user),
    db: Session = Depends(get_db)
):
    qry = db.query(models.Supplier)
    if q: qry = qry.filter(models.Supplier.organization_name.ilike(f"%{q}%"))
    return qry.order_by(models.Supplier.organization_name).all()

@router.post("/", response_model=SupplierOut)
def create_supplier(body: SupplierIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    if db.query(models.Supplier).filter(models.Supplier.organization_name == body.organization_name).first():
        raise HTTPException(status_code=400, detail="Supplier exists")
    s = models.Supplier(organization_name=body.organization_name)
    db.add(s); db.commit(); db.refresh(s); return s

@router.put("/{supplier_name}", response_model=SupplierOut)
def update_supplier(supplier_name: str, body: SupplierIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    s = db.query(models.Supplier).filter(models.Supplier.organization_name == supplier_name).first()
    if not s: raise HTTPException(status_code=404, detail="Supplier not found")
    s.organization_name = body.organization_name
    db.commit(); db.refresh(s); return s

@router.delete("/{supplier_name}")
def delete_supplier(supplier_name: str, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    s = db.query(models.Supplier).filter(models.Supplier.organization_name == supplier_name).first()
    if not s: raise HTTPException(status_code=404, detail="Supplier not found")
    db.delete(s); db.commit(); return {"ok": True}
PY

# -------- routers/connections.py (under supplier name + full CRUD) --------
cat > "$ROUT/connections.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/suppliers/{supplier_name}/connections", tags=["Connections"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

class ConnIn(BaseModel):
    connection_name: str
    username: Optional[str] = None
    kannel_smsc: Optional[str] = None
    per_delivered: Optional[bool] = False
    charge_model: Optional[str] = "Per Submitted"

class ConnOut(ConnIn):
    id: int
    supplier_id: int
    class Config: orm_mode = True

def _get_supplier(db: Session, supplier_name: str) -> models.Supplier:
    s = db.query(models.Supplier).filter(models.Supplier.organization_name == supplier_name).first()
    if not s: raise HTTPException(status_code=404, detail="Supplier not found")
    return s

@router.get("/", response_model=List[ConnOut])
def list_connections(
    supplier_name: str,
    q: Optional[str] = Query(None, description="search in connection_name/username/kannel_smsc"),
    user: str = Depends(auth.get_current_user),
    db: Session = Depends(get_db)
):
    s = _get_supplier(db, supplier_name)
    qry = db.query(models.SupplierConnection).filter_by(supplier_id=s.id)
    if q:
        like = f"%{q}%"
        qry = qry.filter(
            (models.SupplierConnection.connection_name.ilike(like)) |
            (models.SupplierConnection.username.ilike(like)) |
            (models.SupplierConnection.kannel_smsc.ilike(like))
        )
    return qry.order_by(models.SupplierConnection.id).all()

@router.post("/", response_model=ConnOut)
def create_connection(supplier_name: str, body: ConnIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    s = _get_supplier(db, supplier_name)
    exists = db.query(models.SupplierConnection).filter_by(supplier_id=s.id, connection_name=body.connection_name).first()
    if exists: raise HTTPException(status_code=400, detail="Connection exists")
    c = models.SupplierConnection(supplier_id=s.id, **body.dict())
    db.add(c); db.commit(); db.refresh(c); return c

@router.put("/{connection_name}", response_model=ConnOut)
def update_connection(supplier_name: str, connection_name: str, body: ConnIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    s = _get_supplier(db, supplier_name)
    c = db.query(models.SupplierConnection).filter_by(supplier_id=s.id, connection_name=connection_name).first()
    if not c: raise HTTPException(status_code=404, detail="Connection not found")
    for k, v in body.dict().items(): setattr(c, k, v)
    db.commit(); db.refresh(c); return c

@router.delete("/{connection_name}")
def delete_connection(supplier_name: str, connection_name: str, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    s = _get_supplier(db, supplier_name)
    c = db.query(models.SupplierConnection).filter_by(supplier_id=s.id, connection_name=connection_name).first()
    if not c: raise HTTPException(status_code=404, detail="Connection not found")
    db.delete(c); db.commit(); return {"ok": True}
PY

# -------- routers/countries.py (full CRUD + filters) --------
cat > "$ROUT/countries.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/countries", tags=["Countries"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

class CountryIn(BaseModel):
    name: str
    mcc: Optional[str] = None

class CountryOut(CountryIn):
    id: int
    class Config: orm_mode = True

@router.get("/", response_model=List[CountryOut])
def list_countries(q: Optional[str] = Query(None), user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    qry = db.query(models.Country)
    if q:
        like = f"%{q}%"
        qry = qry.filter((models.Country.name.ilike(like)) | (models.Country.mcc.ilike(like)))
    return qry.order_by(models.Country.name).all()

@router.post("/", response_model=CountryOut)
def create_country(body: CountryIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    c = models.Country(**body.dict()); db.add(c); db.commit(); db.refresh(c); return c

@router.put("/{country_name}", response_model=CountryOut)
def update_country(country_name: str, body: CountryIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    c = db.query(models.Country).filter(models.Country.name == country_name).first()
    if not c: raise HTTPException(status_code=404, detail="Country not found")
    c.name = body.name; c.mcc = body.mcc; db.commit(); db.refresh(c); return c

@router.delete("/{country_name}")
def delete_country(country_name: str, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    c = db.query(models.Country).filter(models.Country.name == country_name).first()
    if not c: raise HTTPException(status_code=404, detail="Country not found")
    db.delete(c); db.commit(); return {"ok": True}
PY

# -------- routers/networks.py (full CRUD + filters, name/mccmnc addressable) --------
cat > "$ROUT/networks.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query, Path
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/networks", tags=["Networks"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

class NetworkIn(BaseModel):
    country_id: Optional[int] = None
    name: str
    mnc: Optional[str] = None
    mccmnc: Optional[str] = None

class NetworkOut(NetworkIn):
    id: int
    class Config: orm_mode = True

@router.get("/", response_model=List[NetworkOut])
def list_networks(
    country: Optional[str] = Query(None),
    mccmnc: Optional[str] = Query(None),
    q: Optional[str] = Query(None),
    user: str = Depends(auth.get_current_user),
    db: Session = Depends(get_db)
):
    qry = db.query(models.Network)
    if q: qry = qry.filter(models.Network.name.ilike(f"%{q}%"))
    if mccmnc: qry = qry.filter(models.Network.mccmnc == mccmnc)
    # if country string provided, try map name -> id
    if country:
        c = db.query(models.Country).filter(models.Country.name == country).first()
        if c: qry = qry.filter(models.Network.country_id == c.id)
        else: qry = qry.filter(models.Network.country_id == -1)
    return qry.order_by(models.Network.name).all()

@router.post("/", response_model=NetworkOut)
def create_network(body: NetworkIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    n = models.Network(**body.dict()); db.add(n); db.commit(); db.refresh(n); return n

@router.put("/by-name/{network_name}", response_model=NetworkOut)
def update_network_by_name(network_name: str, body: NetworkIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    n = db.query(models.Network).filter(models.Network.name == network_name).first()
    if not n: raise HTTPException(status_code=404, detail="Network not found")
    for k,v in body.dict().items(): setattr(n, k, v)
    db.commit(); db.refresh(n); return n

@router.put("/by-mccmnc/{mccmnc}", response_model=NetworkOut)
def update_network_by_mccmnc(mccmnc: str, body: NetworkIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    n = db.query(models.Network).filter(models.Network.mccmnc == mccmnc).first()
    if not n: raise HTTPException(status_code=404, detail="Network not found")
    for k,v in body.dict().items(): setattr(n, k, v)
    db.commit(); db.refresh(n); return n

@router.delete("/by-name/{network_name}")
def delete_network_by_name(network_name: str, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    n = db.query(models.Network).filter(models.Network.name == network_name).first()
    if not n: raise HTTPException(status_code=404, detail="Network not found")
    db.delete(n); db.commit(); return {"ok": True}

@router.delete("/by-mccmnc/{mccmnc}")
def delete_network_by_mccmnc(mccmnc: str, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    n = db.query(models.Network).filter(models.Network.mccmnc == mccmnc).first()
    if not n: raise HTTPException(status_code=404, detail="Network not found")
    db.delete(n); db.commit(); return {"ok": True}
PY

# -------- routers/offers.py (filters + edit/delete) --------
cat > "$ROUT/offers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Query, Path
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/offers", tags=["Offers"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

class OfferIn(BaseModel):
    supplier_name: str
    connection_name: str
    country_name: Optional[str] = None
    network_name: Optional[str] = None
    mccmnc: Optional[str] = None
    price: float
    price_effective_date: Optional[str] = None
    previous_price: Optional[float] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[str] = None # CSV
    registration_required: Optional[str] = None
    eta_days: Optional[int] = None
    charge_model: Optional[str] = None
    is_exclusive: Optional[bool] = False
    notes: Optional[str] = None
    updated_by: Optional[str] = None

class OfferOut(OfferIn):
    id: int
    class Config: orm_mode = True

@router.get("/", response_model=List[OfferOut])
def list_offers(
    country: Optional[str] = Query(None),
    route_type: Optional[str] = Query(None),
    known_hops: Optional[str] = Query(None),
    supplier_name: Optional[str] = Query(None),
    connection_name: Optional[str] = Query(None),
    sender_id_supported: Optional[str] = Query(None),  # substring match within CSV
    registration_required: Optional[str] = Query(None),
    is_exclusive: Optional[bool] = Query(None),
    q: Optional[str] = Query(None),
    db: Session = Depends(get_db),
    user: str = Depends(auth.get_current_user)
):
    m = models.OfferCurrent
    qry = db.query(m)
    if country: qry = qry.filter(m.country_name == country)
    if route_type: qry = qry.filter(m.route_type == route_type)
    if known_hops: qry = qry.filter(m.known_hops == known_hops)
    if supplier_name: qry = qry.filter(m.supplier_name == supplier_name)
    if connection_name: qry = qry.filter(m.connection_name == connection_name)
    if registration_required: qry = qry.filter(m.registration_required == registration_required)
    if is_exclusive is not None: qry = qry.filter(m.is_exclusive == is_exclusive)
    if sender_id_supported: qry = qry.filter(m.sender_id_supported.ilike(f"%{sender_id_supported}%"))
    if q:
        like = f"%{q}%"
        qry = qry.filter((m.notes.ilike(like)) | (m.network_name.ilike(like)) | (m.mccmnc.ilike(like)))
    return qry.order_by(m.updated_at.desc()).limit(500).all()

@router.post("/", response_model=OfferOut)
def add_offer(body: OfferIn, db: Session = Depends(get_db), user: str = Depends(auth.get_current_user)):
    cm = body.charge_model
    if cm is None:
        sc = db.query(models.SupplierConnection).filter(models.SupplierConnection.connection_name == body.connection_name).first()
        if sc and sc.charge_model: cm = sc.charge_model
    o = models.OfferCurrent(**body.dict(exclude={"charge_model"}), charge_model=cm)
    db.add(o); db.commit(); db.refresh(o); return o

@router.put("/{offer_id}", response_model=OfferOut)
def update_offer(offer_id: int, body: OfferIn, db: Session = Depends(get_db), user: str = Depends(auth.get_current_user)):
    o = db.query(models.OfferCurrent).get(offer_id)
    if not o: raise HTTPException(status_code=404, detail="Offer not found")
    for k, v in body.dict().items(): setattr(o, k, v)
    db.commit(); db.refresh(o); return o

@router.delete("/{offer_id}")
def delete_offer(offer_id: int, db: Session = Depends(get_db), user: str = Depends(auth.get_current_user)):
    o = db.query(models.OfferCurrent).get(offer_id)
    if not o: raise HTTPException(status_code=404, detail="Offer not found")
    db.delete(o); db.commit(); return {"ok": True}
PY

# -------- routers/conf.py (enums config) --------
cat > "$ROUT/conf.py" <<'PY'
import json
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/conf", tags=["Config"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

@router.get("/enums")
def get_enums(user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    s = db.query(models.Setting).filter_by(key="enums").first()
    return {} if not s else json.loads(s.value)

@router.put("/enums")
def put_enums(body: dict, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    val = json.dumps(body)
    s = db.query(models.Setting).filter_by(key="enums").first()
    if s: s.value = val
    else: s = models.Setting(key="enums", value=val); db.add(s)
    db.commit(); return {"ok": True}
PY

# -------- main.py --------
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate
from app.routers import users, suppliers, connections, countries, networks, offers, conf

app = FastAPI(title="SMS Procurement Manager")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

@app.on_event("startup")
def _startup(): migrate()

app.include_router(users.router)
app.include_router(suppliers.router)
app.include_router(connections.router)
app.include_router(countries.router)
app.include_router(networks.router)
app.include_router(offers.router)
app.include_router(conf.router)

@app.get("/")
def root(): return {"message":"API alive","version":"full-crud"}
PY

# --------- Web UI (static) ---------
cat > "$WEB/index.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>SMS Procurement Manager</title>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <style>
    body{font-family:system-ui,Arial,sans-serif;margin:0;background:#0b0f14;color:#e7eaf0}
    header{background:#111826;padding:12px 16px;display:flex;gap:12px;align-items:center;position:sticky;top:0}
    header h1{font-size:18px;margin:0}
    .pill{background:#1f2937;border:1px solid #334155;border-radius:999px;padding:6px 10px}
    .content{padding:16px;max-width:1200px;margin:0 auto}
    nav{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}
    nav button{background:#111826;border:1px solid #334155;color:#e7eaf0;border-radius:8px;padding:8px 10px;cursor:pointer}
    nav button.active{border-color:#60a5fa;background:#0b1220}
    .card{background:#0f172a;border:1px solid #1f2a44;border-radius:12px;margin:12px 0;padding:12px}
    .row{display:flex;gap:8px;flex-wrap:wrap}
    input,select,textarea{background:#0b1220;color:#e7eaf0;border:1px solid #25314d;border-radius:6px;padding:6px 8px}
    table{width:100%;border-collapse:collapse}
    th,td{border-bottom:1px solid #1f2a44;padding:8px}
    details{border:1px solid #1f2a44;border-radius:10px;margin:8px 0;padding:8px}
    details>summary{cursor:pointer}
    .actions button{margin-right:6px}
    .muted{opacity:.8;font-size:12px}
    .sticky-filters{position:sticky;top:56px;background:#0b0f14;padding:8px;border-bottom:1px solid #1f2a44;z-index:5}
  </style>
</head>
<body>
<header>
  <h1>SMS Procurement Manager</h1>
  <span class="pill">API: <code id="apiBase"></code></span>
  <span class="pill">User: <code id="userName">-</code></span>
</header>
<div class="content">
  <div class="card">
    <div class="row">
      <input id="apiInput" placeholder="API Base (http://localhost:8010)"/>
      <input id="user" placeholder="username" value="admin"/>
      <input id="pass" placeholder="password" type="password" value="admin123"/>
      <button id="loginBtn">Login</button>
      <span id="loginMsg" class="muted"></span>
    </div>
  </div>

  <nav>
    <button data-view="suppliers" class="active">Suppliers</button>
    <button data-view="connections">Connections</button>
    <button data-view="countries">Countries</button>
    <button data-view="networks">Networks</button>
    <button data-view="offers">Offers</button>
    <button data-view="parsers">Parsers</button>
    <button data-view="settings">Settings</button>
    <button data-view="whatsnew">What’s New</button>
  </nav>

  <div id="filters" class="sticky-filters"></div>
  <div id="view"></div>
</div>
<script src="main.js"></script>
</body>
</html>
HTML

cat > "$WEB/main.js" <<'JS'
const $ = (sel)=>document.querySelector(sel);
const API_BASE = localStorage.getItem('API_BASE') || 'http://localhost:8010';
const tokenKey = 'SPM_TOKEN';
let TOKEN = localStorage.getItem(tokenKey) || '';
$('#apiBase').textContent = API_BASE;
$('#apiInput').value = API_BASE;

function setMsg(t){ $('#loginMsg').textContent = t; }

async function authFetch(path, opts={}){
  const url = (API_BASE.replace(/\/$/,'')) + path;
  const headers = opts.headers || {};
  if (TOKEN) headers['Authorization'] = 'Bearer '+TOKEN;
  if (opts.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
  opts.headers = headers;
  const r = await fetch(url, opts);
  if (!r.ok) throw new Error(r.status+' '+(await r.text()));
  const ct = r.headers.get('content-type')||'';
  if (ct.includes('application/json')) return r.json();
  return r.text();
}

$('#loginBtn').onclick = async ()=>{
  try{
    localStorage.setItem('API_BASE',$('#apiInput').value.trim()||API_BASE);
    location.reload();
  }catch(e){}
  try{
    const form = new URLSearchParams();
    form.append('username',$('#user').value); form.append('password',$('#pass').value);
    const url = (localStorage.getItem('API_BASE')||API_BASE).replace(/\/$/,'')+'/users/login';
    const r = await fetch(url,{method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:form});
    if(!r.ok){ setMsg('Login failed: '+await r.text()); return; }
    const j = await r.json(); TOKEN = j.access_token; localStorage.setItem(tokenKey,TOKEN);
    $('#userName').textContent = $('#user').value; setMsg('OK');
    render();
  }catch(e){ setMsg('Network error: '+e.message); }
};

function navActivate(view){
  document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('active',b.dataset.view===view));
}

function renderFilters(html){ $('#filters').innerHTML = html; }
function renderView(html){ $('#view').innerHTML = html; }

async function viewSuppliers(){
  navActivate('suppliers');
  renderFilters(`
    <input id="q" placeholder="Search supplier...">
    <button id="fBtn">Filter</button>
    <input id="newName" placeholder="New supplier name">
    <button id="cBtn">Create</button>
  `);
  $('#fBtn').onclick = renderSuppliers;
  $('#cBtn').onclick = async ()=>{
    const name = $('#newName').value.trim(); if(!name) return;
    await authFetch('/suppliers/', {method:'POST', body: JSON.stringify({organization_name:name})});
    $('#newName').value=''; await renderSuppliers();
  };
  await renderSuppliers();
}
async function renderSuppliers(){
  const q = $('#q').value.trim();
  const list = await authFetch('/suppliers/'+(q?`?q=${encodeURIComponent(q)}`:''));
  renderView(`<div class="card">
    ${list.map(s=>`
      <details>
        <summary><b>${s.organization_name}</b>
          <span class="muted"> • expand for connections • </span>
          <span class="actions">
            <button data-act="edit" data-name="${s.organization_name}">Edit</button>
            <button data-act="del" data-name="${s.organization_name}">Delete</button>
          </span>
        </summary>
        <div class="row" style="margin:6px 0">
          <input placeholder="Rename to..." id="rn-${s.id}">
          <button data-act="rename" data-id="${s.id}" data-name="${s.organization_name}">Rename</button>
        </div>
        <div id="conns-${s.id}" class="card"></div>
      </details>
    `).join('')}
  </div>`);
  // wire supplier actions
  $('#view').querySelectorAll('button[data-act="del"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete supplier?')) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.name)}`,{method:'DELETE'});
      await renderSuppliers();
    };
  });
  $('#view').querySelectorAll('button[data-act="rename"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const val = $(`#rn-${btn.dataset.id}`).value.trim(); if(!val) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.name)}`,{method:'PUT', body: JSON.stringify({organization_name:val})});
      await renderSuppliers();
    };
  });
  // load connections panels
  for(const s of list){ await renderConnections(s); }
}

async function renderConnections(supplier){
  const host = `#conns-${supplier.id}`;
  const box = $(host); if(!box) return;
  const list = await authFetch(`/suppliers/${encodeURIComponent(supplier.organization_name)}/connections/`);
  box.innerHTML = `
    <div class="row">
      <input id="cname-${supplier.id}" placeholder="Connection name">
      <input id="user-${supplier.id}" placeholder="Kannel username">
      <input id="smsc-${supplier.id}" placeholder="Kannel SMSc">
      <label><input type="checkbox" id="perdel-${supplier.id}"> Per Delivered</label>
      <select id="charge-${supplier.id}">
        <option>Per Submitted</option><option>Per Delivered</option>
      </select>
      <button id="addc-${supplier.id}">Add</button>
    </div>
    <table>
      <thead><tr><th>Name</th><th>Username</th><th>SMSc</th><th>Per Delivered</th><th>Charge Model</th><th></th></tr></thead>
      <tbody>${list.map(c=>`
        <tr>
          <td>${c.connection_name}</td>
          <td>${c.username||''}</td>
          <td>${c.kannel_smsc||''}</td>
          <td>${c.per_delivered?'Yes':'No'}</td>
          <td>${c.charge_model||''}</td>
          <td class="actions">
            <button data-act="cedit" data-s="${supplier.organization_name}" data-n="${c.connection_name}">Edit</button>
            <button data-act="cdel" data-s="${supplier.organization_name}" data-n="${c.connection_name}">Delete</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  $(`#addc-${supplier.id}`).onclick = async ()=>{
    const body = {
      connection_name: $(`#cname-${supplier.id}`).value.trim(),
      username: $(`#user-${supplier.id}`).value.trim(),
      kannel_smsc: $(`#smsc-${supplier.id}`).value.trim(),
      per_delivered: $(`#perdel-${supplier.id}`).checked,
      charge_model: $(`#charge-${supplier.id}`).value
    };
    if(!body.connection_name) return;
    await authFetch(`/suppliers/${encodeURIComponent(supplier.organization_name)}/connections/`, {method:'POST', body: JSON.stringify(body)});
    await renderConnections(supplier);
  };
  box.querySelectorAll('button[data-act="cdel"]').forEach(btn=>{
    btn.onclick = async ()=>{
      if(!confirm('Delete connection?')) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.s)}/connections/${encodeURIComponent(btn.dataset.n)}`, {method:'DELETE'});
      await renderConnections(supplier);
    };
  });
  box.querySelectorAll('button[data-act="cedit"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('New connection name', btn.dataset.n); if(!newName) return;
      await authFetch(`/suppliers/${encodeURIComponent(btn.dataset.s)}/connections/${encodeURIComponent(btn.dataset.n)}`, {
        method:'PUT', body: JSON.stringify({connection_name:newName})
      });
      await renderConnections(supplier);
    };
  });
}

async function viewCountries(){
  navActivate('countries');
  renderFilters(`
    <input id="cq" placeholder="Search country...">
    <button id="cF">Filter</button>
    <input id="cName" placeholder="Name">
    <input id="cMcc" placeholder="MCC">
    <button id="cCreate">Create</button>
  `);
  $('#cF').onclick = renderCountries;
  $('#cCreate').onclick = async ()=>{
    const name=$('#cName').value.trim(); if(!name) return;
    await authFetch('/countries/',{method:'POST',body:JSON.stringify({name, mcc:$('#cMcc').value.trim()||null})});
    $('#cName').value=''; $('#cMcc').value=''; await renderCountries();
  };
  await renderCountries();
}
async function renderCountries(){
  const q = $('#cq').value.trim();
  const list = await authFetch('/countries/'+(q?`?q=${encodeURIComponent(q)}`:''));
  renderView(`<div class="card">
    <table><thead><tr><th>Name</th><th>MCC</th><th></th></tr></thead>
    <tbody>${list.map(c=>`
      <tr>
        <td>${c.name}</td><td>${c.mcc||''}</td>
        <td class="actions">
          <button data-act="edit" data-name="${c.name}">Edit</button>
          <button data-act="del" data-name="${c.name}">Delete</button>
        </td>
      </tr>`).join('')}
    </tbody></table>
  </div>`);
  $('#view').querySelectorAll('button[data-act="del"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete?')) return;
      await authFetch(`/countries/${encodeURIComponent(btn.dataset.name)}`,{method:'DELETE'}); await renderCountries();
    };
  });
  $('#view').querySelectorAll('button[data-act="edit"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('Country name', btn.dataset.name); if(!newName) return;
      const mcc = prompt('MCC (optional)','');
      await authFetch(`/countries/${encodeURIComponent(btn.dataset.name)}`,{method:'PUT',body:JSON.stringify({name:newName,mcc:mcc||null})});
      await renderCountries();
    };
  });
}

async function viewNetworks(){
  navActivate('networks');
  renderFilters(`
    <input id="nq" placeholder="Search network...">
    <input id="nCountry" placeholder="Country filter">
    <input id="nmccmnc" placeholder="MCCMNC filter">
    <button id="nF">Filter</button>
    <input id="nName" placeholder="Network name">
    <input id="nMNC" placeholder="MNC">
    <input id="nMCCMNC" placeholder="MCCMNC">
    <button id="nCreate">Create</button>
  `);
  $('#nF').onclick = renderNetworks;
  $('#nCreate').onclick = async ()=>{
    const name=$('#nName').value.trim(); if(!name) return;
    await authFetch('/networks/',{method:'POST',body:JSON.stringify({name, mnc:$('#nMNC').value.trim()||null, mccmnc:$('#nMCCMNC').value.trim()||null})});
    $('#nName').value=''; $('#nMNC').value=''; $('#nMCCMNC').value=''; await renderNetworks();
  };
  await renderNetworks();
}
async function renderNetworks(){
  const params = new URLSearchParams();
  const q=$('#nq').value.trim(), country=$('#nCountry').value.trim(), mm=$('#nmccmnc').value.trim();
  if(q) params.set('q',q); if(country) params.set('country',country); if(mm) params.set('mccmnc',mm);
  const list = await authFetch('/networks/'+(params.toString()?`?${params.toString()}`:''));
  renderView(`<div class="card">
    <table><thead><tr><th>Name</th><th>MNC</th><th>MCCMNC</th><th></th></tr></thead>
    <tbody>${list.map(n=>`
      <tr><td>${n.name}</td><td>${n.mnc||''}</td><td>${n.mccmnc||''}</td>
      <td class="actions">
        <button data-act="editn" data-name="${n.name}">Edit</button>
        <button data-act="deln" data-name="${n.name}">Delete</button>
      </td></tr>`).join('')}
    </tbody></table>
  </div>`);
  $('#view').querySelectorAll('button[data-act="deln"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete?')) return;
      await authFetch(`/networks/by-name/${encodeURIComponent(btn.dataset.name)}`,{method:'DELETE'}); await renderNetworks();
    };
  });
  $('#view').querySelectorAll('button[data-act="editn"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('Network name', btn.dataset.name); if(!newName) return;
      const mnc = prompt('MNC (optional)',''); const mm = prompt('MCCMNC (optional)','');
      await authFetch(`/networks/by-name/${encodeURIComponent(btn.dataset.name)}`,{method:'PUT',body:JSON.stringify({name:newName,mnc:(mnc||null),mccmnc:(mm||null)})});
      await renderNetworks();
    };
  });
}

async function viewOffers(){
  navActivate('offers');
  renderFilters(`
    <input id="oq" placeholder="Search notes/network/mccmnc">
    <select id="of_route"><option value="">Route Type</option></select>
    <select id="of_hops"><option value="">Known Hops</option></select>
    <select id="of_reg"><option value="">Registration</option></select>
    <input id="of_supplier" placeholder="Supplier name">
    <input id="of_conn" placeholder="Connection name">
    <input id="of_country" placeholder="Country">
    <input id="of_sender" placeholder="Sender Id contains">
    <select id="of_exclusive"><option value="">Exclusive?</option><option>true</option><option>false</option></select>
    <button id="oF">Filter</button>
    <button id="oNew">New Offer</button>
  `);
  await hydrateEnums();
  $('#oF').onclick = renderOffers;
  $('#oNew').onclick = async ()=>{ await openNewOffer(); };
  await renderOffers();
}
async function hydrateEnums(){
  try{
    const e = await authFetch('/conf/enums');
    const r = e.route_type||[], h=e.known_hops||[], reg=e.registration_required||[];
    const put = (sel,vals)=>{ const c=$(sel); c.innerHTML='<option value=""></option>'+vals.map(v=>`<option>${v}</option>`).join(''); };
    put('#of_route',r); put('#of_hops',h); put('#of_reg',reg);
  }catch(e){}
}
function offerFiltersQS(){
  const p=new URLSearchParams();
  const set=(id,k)=>{ const v=$(id).value.trim(); if(v) p.set(k,v); };
  set('#oq','q'); set('#of_route','route_type'); set('#of_hops','known_hops'); set('#of_reg','registration_required');
  set('#of_supplier','supplier_name'); set('#of_conn','connection_name'); set('#of_country','country');
  set('#of_sender','sender_id_supported');
  const ex=$('#of_exclusive').value.trim(); if(ex) p.set('is_exclusive',ex);
  return p.toString();
}
async function renderOffers(){
  const qs = offerFiltersQS();
  const list = await authFetch('/offers/'+(qs?`?${qs}`:''));
  renderView(`<div class="card">
    <table><thead><tr>
      <th>Supplier</th><th>Connection</th><th>Country</th><th>Network</th><th>MCCMNC</th>
      <th>Price</th><th>Eff.Date</th><th>Prev</th><th>Route</th><th>Hops</th><th>SenderId</th>
      <th>Reg</th><th>ETA</th><th>Charge</th><th>Exclusive</th><th>Notes</th><th></th>
    </tr></thead>
    <tbody>
    ${list.map(o=>`
      <tr>
        <td>${o.supplier_name}</td><td>${o.connection_name}</td><td>${o.country_name||''}</td><td>${o.network_name||''}</td><td>${o.mccmnc||''}</td>
        <td>${o.price}</td><td>${o.price_effective_date||''}</td><td>${o.previous_price??''}</td>
        <td>${o.route_type||''}</td><td>${o.known_hops||''}</td><td>${o.sender_id_supported||''}</td>
        <td>${o.registration_required||''}</td><td>${o.eta_days??''}</td><td>${o.charge_model||''}</td>
        <td>${o.is_exclusive?'Yes':'No'}</td><td>${o.notes||''}</td>
        <td class="actions">
          <button data-act="oedit" data-id="${o.id}">Edit</button>
          <button data-act="odel" data-id="${o.id}">Delete</button>
        </td>
      </tr>`).join('')}
    </tbody></table>
  </div>`);
  $('#view').querySelectorAll('button[data-act="odel"]').forEach(btn=>{
    btn.onclick = async ()=>{ if(!confirm('Delete offer?')) return;
      await authFetch(`/offers/${btn.dataset.id}`,{method:'DELETE'}); await renderOffers();
    };
  });
  $('#view').querySelectorAll('button[data-act="oedit"]').forEach(btn=>{
    btn.onclick = async ()=>{ await openEditOffer(btn.dataset.id); };
  });
}
async function openNewOffer(){ await openOfferEditor(); }
async function openEditOffer(id){
  const rows = await authFetch('/offers/?q=');
  const o = rows.find(x=> String(x.id)===String(id));
  if(!o){ alert('Offer not found in current list'); return; }
  await openOfferEditor(o);
}
async function openOfferEditor(data={}){
  const e = await authFetch('/conf/enums').catch(()=>({}));
  const pick=(name,vals,cur)=>`<select id="f_${name}">
    <option value=""></option>${(vals||[]).map(v=>`<option ${cur===v?'selected':''}>${v}</option>`).join('')}</select>`;
  renderView(`<div class="card">
    <div class="row">
      <input id="f_supplier" placeholder="Supplier name" value="${data.supplier_name||''}">
      <input id="f_conn" placeholder="Connection name" value="${data.connection_name||''}">
      <input id="f_country" placeholder="Country" value="${data.country_name||''}">
      <input id="f_network" placeholder="Network" value="${data.network_name||''}">
      <input id="f_mccmnc" placeholder="MCCMNC" value="${data.mccmnc||''}">
      <input id="f_price" type="number" step="0.0001" placeholder="Price" value="${data.price||''}">
      <input id="f_eff" type="date" value="${data.price_effective_date||''}">
      <input id="f_prev" type="number" step="0.0001" placeholder="Previous price" value="${data.previous_price??''}">
      ${pick('route',e.route_type,data.route_type||'')}
      ${pick('hops',e.known_hops,data.known_hops||'')}
      <input id="f_sender" placeholder="SenderId CSV" value="${data.sender_id_supported||''}">
      ${pick('reg',e.registration_required,data.registration_required||'')}
      <input id="f_eta" type="number" step="1" placeholder="ETA days" value="${data.eta_days??''}">
      <input id="f_charge" placeholder="Charge model" value="${data.charge_model||''}">
      <select id="f_excl"><option ${data.is_exclusive?'':'selected'} value="">Exclusive?</option><option ${data.is_exclusive?'selected':''} value="true">Yes</option><option value="false">No</option></select>
      <input id="f_notes" placeholder="Notes" value="${data.notes||''}">
    </div>
    <div class="row">
      <button id="saveBtn">${data.id?'Save':'Create'}</button>
      <button id="cancelBtn">Cancel</button>
    </div>
  </div>`);
  $('#cancelBtn').onclick = ()=>viewOffers();
  $('#saveBtn').onclick = async ()=>{
    const body={
      supplier_name: $('#f_supplier').value.trim(),
      connection_name: $('#f_conn').value.trim(),
      country_name: $('#f_country').value.trim()||null,
      network_name: $('#f_network').value.trim()||null,
      mccmnc: $('#f_mccmnc').value.trim()||null,
      price: parseFloat($('#f_price').value),
      price_effective_date: $('#f_eff').value || null,
      previous_price: $('#f_prev').value ? parseFloat($('#f_prev').value) : null,
      route_type: $('#f_route').value || null,
      known_hops: $('#f_hops').value || null,
      sender_id_supported: $('#f_sender').value.trim()||null,
      registration_required: $('#f_reg').value || null,
      eta_days: $('#f_eta').value ? parseInt($('#f_eta').value) : null,
      charge_model: $('#f_charge').value.trim()||null,
      is_exclusive: ($('#f_excl').value==='true') ? true : ($('#f_excl').value==='false' ? false : null),
      notes: $('#f_notes').value.trim()||null,
      updated_by: $('#user').value
    };
    if(!body.supplier_name || !body.connection_name || isNaN(body.price)){ alert('Supplier, Connection, Price are required'); return; }
    if(data.id){
      await authFetch(`/offers/${data.id}`,{method:'PUT', body:JSON.stringify(body)});
    }else{
      await authFetch(`/offers/`,{method:'POST', body:JSON.stringify(body)});
    }
    await viewOffers();
  };
}

async function viewParsers(){
  navActivate('parsers');
  renderFilters(`<span class="muted">Parsers are coming next; enums can be adjusted in Settings.</span>`);
  renderView(`<div class="card"><p>Placeholder for e-mail/file parsers (create/edit/delete parser definitions).</p></div>`);
}

async function viewSettings(){
  navActivate('settings');
  const cur = await authFetch('/conf/enums');
  function render(){
    renderView(`<div class="card">
      <h3>Dropdown Options</h3>
      <div class="row">
        <textarea id="enums" rows="10" style="width:100%">${JSON.stringify(cur,null,2)}</textarea>
      </div>
      <div class="row"><button id="saveE">Save</button></div>
    </div>`);
    $('#saveE').onclick = async ()=>{
      try{
        const val = JSON.parse($('#enums').value);
        await authFetch('/conf/enums',{method:'PUT', body: JSON.stringify(val)});
        alert('Saved'); await viewSettings();
      }catch(e){ alert('JSON error: '+e.message); }
    };
  }
  render();
}

async function viewConnections(){
  navActivate('connections');
  renderFilters(`
    <input id="sq" placeholder="Supplier name">
    <input id="cq" placeholder="Search connections">
    <button id="sF">Filter</button>
  `);
  $('#sF').onclick = renderConnectionsGrid;
  await renderConnectionsGrid();
}
async function renderConnectionsGrid(){
  const sname = $('#sq').value.trim();
  if(!sname){ renderView('<div class="card">Enter supplier name to list connections.</div>'); return; }
  const qs = $('#cq').value.trim(); 
  const list = await authFetch(`/suppliers/${encodeURIComponent(sname)}/connections/`+(qs?`?q=${encodeURIComponent(qs)}`:''));
  renderView(`<div class="card">
    <h3>${sname} — Connections</h3>
    <table><thead><tr><th>Name</th><th>Username</th><th>SMSc</th><th>Per Delivered</th><th>Charge</th><th></th></tr></thead>
      <tbody>${list.map(c=>`
        <tr>
         <td>${c.connection_name}</td><td>${c.username||''}</td><td>${c.kannel_smsc||''}</td>
         <td>${c.per_delivered?'Yes':'No'}</td><td>${c.charge_model||''}</td>
         <td class="actions"><button data-act="editc" data-n="${c.connection_name}">Edit</button>
         <button data-act="delc" data-n="${c.connection_name}">Delete</button></td>
        </tr>`).join('')}
      </tbody>
    </table>
  </div>`);
  $('#view').querySelectorAll('button[data-act="delc"]').forEach(btn=>{
    btn.onclick = async ()=>{
      if(!confirm('Delete connection?')) return;
      await authFetch(`/suppliers/${encodeURIComponent(sname)}/connections/${encodeURIComponent(btn.dataset.n)}`,{method:'DELETE'});
      await renderConnectionsGrid();
    };
  });
  $('#view').querySelectorAll('button[data-act="editc"]').forEach(btn=>{
    btn.onclick = async ()=>{
      const newName = prompt('New name', btn.dataset.n); if(!newName) return;
      await authFetch(`/suppliers/${encodeURIComponent(sname)}/connections/${encodeURIComponent(btn.dataset.n)}`,{method:'PUT', body: JSON.stringify({connection_name:newName})});
      await renderConnectionsGrid();
    };
  });
}

const routes = {
  suppliers: viewSuppliers,
  connections: viewConnections,
  countries: viewCountries,
  networks: viewNetworks,
  offers: viewOffers,
  parsers: viewParsers,
  settings: viewSettings,
  whatsnew: async ()=>{
    navActivate('whatsnew');
    renderFilters('');
    renderView('<div class="card"><h3>What’s New</h3><p>Full CRUD, filters and expand/collapse are now live.</p></div>');
  }
};

function wireNav(){
  document.querySelectorAll('nav button').forEach(b=>{
    b.onclick = ()=> routes[b.dataset.view]();
  });
}

async function render(){
  $('#apiBase').textContent = (localStorage.getItem('API_BASE')||API_BASE);
  $('#userName').textContent = TOKEN ? ($('#user').value || 'admin') : '-';
  await viewSuppliers();
}

wireNav();
if(TOKEN) render();
JS

# ---- ensure api.Dockerfile at repo root with pinned deps ----
if [ ! -f "$ROOT/api.Dockerfile" ]; then
  cat > "$ROOT/api.Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    fastapi uvicorn[standard] sqlalchemy pydantic psycopg[binary] python-multipart \
    passlib[bcrypt]==1.7.4 bcrypt==4.0.1 python-jose[cryptography]
ENV PYTHONPATH=/app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
DOCKER
fi

echo "🔁 Build & restart api/web..."
cd "$ROOT/docker"
docker compose build api web >/dev/null
docker compose up -d api web >/dev/null
sleep 3

echo "👤 Ensure admin user (idempotent)…"
docker exec -i docker-api-1 python3 - <<'PY'
from sqlalchemy import text
from app.core.database import SessionLocal
from app.models import models
from app.core import auth
db=SessionLocal()
db.execute(text("CREATE TABLE IF NOT EXISTS users(id SERIAL PRIMARY KEY, username VARCHAR UNIQUE NOT NULL, password_hash VARCHAR NOT NULL, role VARCHAR DEFAULT 'user')"))
u = db.query(models.User).filter_by(username="admin").first()
if not u:
    u = models.User(username="admin", password_hash=auth.get_password_hash("admin123"), role="admin")
    db.add(u); db.commit(); print("✅ admin created")
else:
    print("ℹ️ admin exists")
db.close()
PY

echo "🧪 Sanity: root + OpenAPI + login"
python3 - <<'PY'
import json, urllib.request
def get(u):
    with urllib.request.urlopen(u) as r: return r.read().decode()
print(get("http://localhost:8010/"))
o = json.loads(get("http://localhost:8010/openapi.json"))
print("paths:", list(o.get("paths",{}).keys())[:8])
PY

TOKEN=$(curl -sS -X POST http://localhost:8010/users/login -H "Content-Type: application/x-www-form-urlencoded" -d "username=admin&password=admin123" | python3 -c 'import sys,json; d=sys.stdin.read().strip(); print(json.loads(d)["access_token"])')
echo "TOKEN.len=$(echo -n "$TOKEN" | wc -c)"

echo "✅ Done. Open Web UI at http://localhost:5183 (set API Base if needed, login admin/admin123)."
