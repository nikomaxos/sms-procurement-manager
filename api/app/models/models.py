from sqlalchemy import Column, Integer, String, Float, Boolean, DateTime, ForeignKey, JSON
from sqlalchemy.orm import relationship
from datetime import datetime
from app.core.database import Base

class Supplier(Base):
    __tablename__ = "suppliers"
    id = Column(Integer, primary_key=True, index=True)
    organization_name = Column(String, nullable=False)
    per_delivered = Column(Boolean, default=False)
    connections = relationship("SupplierConnection", back_populates="supplier")

class SupplierConnection(Base):
    __tablename__ = "supplier_connections"
    id = Column(Integer, primary_key=True, index=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id"))
    connection_name = Column(String)
    kannel_smsc = Column(String)
    username = Column(String)
    charge_model = Column(String)
    supplier = relationship("Supplier", back_populates="connections")

class Country(Base):
    __tablename__ = "countries"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String)
    mcc = Column(String)

class Network(Base):
    __tablename__ = "networks"
    id = Column(Integer, primary_key=True, index=True)
    country_id = Column(Integer, ForeignKey("countries.id"))
    name = Column(String)
    mnc = Column(String)
    mccmnc = Column(String)

class OfferCurrent(Base):
    __tablename__ = "offers_current"
    id = Column(Integer, primary_key=True, index=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id"))
    connection_id = Column(Integer, ForeignKey("supplier_connections.id"))
    network_id = Column(Integer, ForeignKey("networks.id"))
    price = Column(Float)
    currency = Column(String, default="EUR")
    effective_date = Column(DateTime, default=datetime.utcnow)
    route_type = Column(String)
    known_hops = Column(String)
    sender_id_supported = Column(String)
    registration_required = Column(String)
    eta_days = Column(Integer)
    charge_model = Column(String)
    is_exclusive = Column(String)
    notes = Column(String)
    updated_by = Column(String)
    updated_at = Column(DateTime, default=datetime.utcnow)

class OfferHistory(Base):
    __tablename__ = "offers_history"
    id = Column(Integer, primary_key=True)
    previous_id = Column(Integer)
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    network_id = Column(Integer)
    price = Column(Float)
    effective_date = Column(DateTime)
    updated_at = Column(DateTime, default=datetime.utcnow)

class EmailTemplate(Base):
    __tablename__ = "email_templates"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer)
    name = Column(String)
    conditions_json = Column(JSON)
    field_map_json = Column(JSON)
    callback_enabled = Column(Boolean, default=False)
    callback_url = Column(String)

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True)
    password_hash = Column(String)
    role = Column(String, default="user")
