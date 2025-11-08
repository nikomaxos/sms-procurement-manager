#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/sms-procurement-manager"
API="$ROOT/api/app"
CORE="$API/core"
MODELS="$API/models"
ROUTERS="$API/routers"

mkdir -p "$CORE" "$MODELS" "$ROUTERS"
: > "$API/__init__.py"; : > "$CORE/__init__.py"; : > "$MODELS/__init__.py"; : > "$ROUTERS/__init__.py"

# ---------------- core/database.py ----------------
cat > "$CORE/database.py" <<'PY'
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

# Read env but force psycopg v3 driver even if old DSN is set
_raw = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")
if _raw.startswith("postgresql://"):
    _raw = _raw.replace("postgresql://", "postgresql+psycopg://", 1)

DB_URL = _raw
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, future=True)
Base = declarative_base()
PY

# ---------------- core/auth.py ----------------
cat > "$CORE/auth.py" <<'PY'
import os, time
from typing import Optional
from fastapi import Depends, HTTPException
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.context import CryptContext

JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALGO = "HS256"
ACCESS_TOKEN_EXPIRE = int(os.getenv("ACCESS_TOKEN_EXPIRE", "86400"))  # 1 day

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

# ---------------- models/models.py ----------------
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
    per_delivered = Column(Boolean, default=False)  # moved here (not on suppliers)
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
    """
    Name-based associations (no foreign keys), per your spec:
    supplier_name / connection_name / country_name / network_name / mccmnc
    """
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

    route_type = Column(String, nullable=True)            # Direct, SS7, SIM, Local Bypass
    known_hops = Column(String, nullable=True)            # 0-Hop, 1-Hop, 2-Hops, N-Hops
    sender_id_supported = Column(String, nullable=True)   # CSV of values
    registration_required = Column(String, nullable=True) # Yes/No
    eta_days = Column(Integer, nullable=True)

    charge_model = Column(String, nullable=True)          # inherited at insert from connection
    is_exclusive = Column(Boolean, default=False)

    notes = Column(Text, nullable=True)
    updated_by = Column(String, nullable=True)
    updated_at = Column(DateTime, default=datetime.utcnow)
PY

# ---------------- migrations.py ----------------
cat > "$API/migrations.py" <<'PY'
from sqlalchemy import text
from app.core.database import engine
from app.core.database import Base
from app.models import models  # noqa: F401 (import ensures models are registered)

def migrate():
    # Create tables if missing
    Base.metadata.create_all(bind=engine)

    # Idempotent column adds (safe on existing DBs)
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
    with engine.begin() as conn:
        for ddl in alters:
            conn.execute(text(ddl))
PY

# ---------------- routers/users.py ----------------
cat > "$ROUTERS/users.py" <<'PY'
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
    if form.username == "admin" and form.password == "admin123":  # bootstrap
        return {"access_token": auth.create_access_token("admin"), "token_type": "bearer"}
    raise HTTPException(status_code=400, detail="Incorrect username or password")

@router.get("/me")
def me(user: str = Depends(auth.get_current_user)):
    return {"user": user}
PY

# ---------------- routers/suppliers.py ----------------
cat > "$ROUTERS/suppliers.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from typing import List
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
def list_suppliers(user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    return db.query(models.Supplier).order_by(models.Supplier.id).all()

@router.post("/", response_model=SupplierOut)
def create_supplier(body: SupplierIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    if db.query(models.Supplier).filter(models.Supplier.organization_name == body.organization_name).first():
        raise HTTPException(status_code=400, detail="Supplier already exists")
    s = models.Supplier(organization_name=body.organization_name)
    db.add(s); db.commit(); db.refresh(s); return s
PY

# ---------------- routers/connections.py ----------------
cat > "$ROUTERS/connections.py" <<'PY'
from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.core import auth
from app.models import models

router = APIRouter(prefix="/suppliers/{supplier_id}/connections", tags=["Connections"])

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

@router.get("/", response_model=List[ConnOut])
def list_connections(supplier_id: int = Path(...), user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    return db.query(models.SupplierConnection).filter_by(supplier_id=supplier_id).order_by(models.SupplierConnection.id).all()

@router.post("/", response_model=ConnOut)
def create_connection(supplier_id: int, body: ConnIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    if not db.query(models.Supplier).filter_by(id=supplier_id).first():
        raise HTTPException(status_code=404, detail="Supplier not found")
    c = models.SupplierConnection(supplier_id=supplier_id, **body.dict())
    db.add(c); db.commit(); db.refresh(c); return c
PY

# ---------------- routers/countries.py ----------------
cat > "$ROUTERS/countries.py" <<'PY'
from fastapi import APIRouter, Depends
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
def list_countries(user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    return db.query(models.Country).order_by(models.Country.name).all()

@router.post("/", response_model=CountryOut)
def create_country(body: CountryIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    c = models.Country(**body.dict())
    db.add(c); db.commit(); db.refresh(c); return c
PY

# ---------------- routers/networks.py ----------------
cat > "$ROUTERS/networks.py" <<'PY'
from fastapi import APIRouter, Depends
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
def list_networks(user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    return db.query(models.Network).order_by(models.Network.name).all()

@router.post("/", response_model=NetworkOut)
def create_network(body: NetworkIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    n = models.Network(**body.dict())
    db.add(n); db.commit(); db.refresh(n); return n
PY

# ---------------- routers/offers.py ----------------
cat > "$ROUTERS/offers.py" <<'PY'
from fastapi import APIRouter, Depends
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
    price_effective_date: Optional[str] = None  # ISO date
    previous_price: Optional[float] = None
    route_type: Optional[str] = None
    known_hops: Optional[str] = None
    sender_id_supported: Optional[str] = None
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
def list_offers(user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    return db.query(models.OfferCurrent).order_by(models.OfferCurrent.updated_at.desc()).limit(200).all()

@router.post("/", response_model=OfferOut)
def add_offer(body: OfferIn, user: str = Depends(auth.get_current_user), db: Session = Depends(get_db)):
    # inherit charge_model from SupplierConnection if not provided
    cm = body.charge_model
    if cm is None:
        sc = db.query(models.SupplierConnection).filter(
            models.SupplierConnection.connection_name == body.connection_name
        ).first()
        if sc and sc.charge_model:
            cm = sc.charge_model
    o = models.OfferCurrent(**body.dict(exclude={"charge_model"}), charge_model=cm)
    db.add(o); db.commit(); db.refresh(o); return o
PY

# ---------------- main.py ----------------
cat > "$API/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate
from app.routers import users, suppliers, connections, countries, networks, offers

app = FastAPI(title="SMS Procurement Manager")

# wide-open CORS for local/LAN
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

@app.on_event("startup")
def _startup():
    migrate()

app.include_router(users.router)
app.include_router(suppliers.router)
app.include_router(connections.router)
app.include_router(countries.router)
app.include_router(networks.router)
app.include_router(offers.router)

@app.get("/")
def root():
    return {"message":"API alive","version":"stable-minimal"}
PY

# ---------------- ensure root-level api.Dockerfile pins deps ----------------
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

echo "🔁 Building & starting API…"
cd "$ROOT/docker"
docker compose build api >/dev/null
docker compose up -d api >/dev/null
sleep 3

echo "🧪 Sanity: root"
curl -sS http://localhost:8010/ | sed -e $'s/,/,\n  /g' || true

echo "🧪 OpenAPI has /users/login?"
curl -sS http://localhost:8010/openapi.json | grep -A1 '"/users/login"' || echo "users/login missing"

echo "👤 Seeding admin (idempotent)…"
docker exec -i docker-api-1 python3 - <<'PY'
from app.core.database import SessionLocal
from app.models import models
from app.core import auth
from sqlalchemy import text
db=SessionLocal()
db.execute(text("CREATE TABLE IF NOT EXISTS users(id SERIAL PRIMARY KEY, username VARCHAR UNIQUE NOT NULL, password_hash VARCHAR NOT NULL, role VARCHAR DEFAULT 'user')"))
u = db.query(models.User).filter(models.User.username=="admin").first()
if not u:
    u = models.User(username="admin", password_hash=auth.get_password_hash("admin123"), role="admin")
    db.add(u); db.commit(); print("✅ Admin user created")
else:
    print("ℹ️ Admin already exists")
db.close()
PY

echo "🔐 Try login:"
curl -sS -X POST http://localhost:8010/users/login -H "Content-Type: application/x-www-form-urlencoded" -d "username=admin&password=admin123" \
 | sed -e $'s/,/,\n  /g' || true
