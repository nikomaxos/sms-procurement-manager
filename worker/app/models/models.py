from sqlalchemy import Column, Integer, String, Boolean, Float, Text, TIMESTAMP, ForeignKey
from sqlalchemy.orm import relationship
from datetime import datetime
from app.db.db import Base

class Supplier(Base):
    __tablename__ = "suppliers"
    id = Column(Integer, primary_key=True)
    organization_name = Column(String, nullable=False)
    per_delivered = Column(Boolean, nullable=False, default=False)
    connections = relationship("SupplierConnection", backref="supplier")

class SupplierConnection(Base):
    __tablename__ = "supplier_connections"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer, ForeignKey("suppliers.id"))
    connection_name = Column(String)
    kannel_smsc = Column(String)
    username = Column(String)
    charge_model = Column(String)

class Country(Base):
    __tablename__ = "countries"
    id = Column(Integer, primary_key=True)
    name = Column(String)
    mcc = Column(String)

class Network(Base):
    __tablename__ = "networks"
    id = Column(Integer, primary_key=True)
    country_id = Column(Integer, ForeignKey("countries.id"))
    name = Column(String)
    mnc = Column(String)
    mccmnc = Column(String)

class OfferCurrent(Base):
    __tablename__ = "offers_current"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    network_id = Column(Integer)
    price = Column(Float)
    currency = Column(String(8), default="EUR")
    effective_date = Column(TIMESTAMP, default=datetime.utcnow)
    route_type = Column(String(64))
    known_hops = Column(String(32))
    sender_id_supported = Column(String(128))
    registration_required = Column(String(16))
    eta_days = Column(Integer)
    charge_model = Column(String(32))
    is_exclusive = Column(String(8))
    notes = Column(Text)
    updated_by = Column(String(64))
    updated_at = Column(TIMESTAMP, default=datetime.utcnow)

class OfferHistory(Base):
    __tablename__ = "offers_history"
    id = Column(Integer, primary_key=True)
    previous_id = Column(Integer)
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    network_id = Column(Integer)
    price = Column(Float)
    effective_date = Column(TIMESTAMP, default=datetime.utcnow)
    updated_at = Column(TIMESTAMP, default=datetime.utcnow)

class ParsingTemplate(Base):
    __tablename__ = "parsing_templates"
    id = Column(Integer, primary_key=True)
    supplier_id = Column(Integer)
    connection_id = Column(Integer)
    name = Column(String, nullable=False)
    enabled = Column(Boolean, default=True)
    conditions = Column(Text)  # JSON
    mapping = Column(Text)     # JSON
    options = Column(Text)     # JSON

class ParsingEvent(Base):
    __tablename__ = "parsing_events"
    id = Column(Integer, primary_key=True)
    template_id = Column(Integer)
    event_type = Column(String)
    message = Column(Text)
    created_at = Column(TIMESTAMP, default=datetime.utcnow)

class EmailAccount(Base):
    __tablename__ = "email_accounts"
    id = Column(Integer, primary_key=True)
    host = Column(String)
    user = Column(String)
    app_password = Column(String)
    folder = Column(String, default="INBOX")
    refresh_minutes = Column(Integer, default=5)
    use_ssl = Column(Boolean, default=True)
    enabled = Column(Boolean, default=True)

class ErrorRecipient(Base):
    __tablename__ = "error_recipients"
    id = Column(Integer, primary_key=True)
    email = Column(String)
