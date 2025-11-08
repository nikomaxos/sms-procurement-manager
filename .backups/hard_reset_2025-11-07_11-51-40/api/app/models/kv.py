from sqlalchemy import Column, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.types import JSON
from app.core.database import Base

try:
    JSONType = JSONB
except Exception:
    JSONType = JSON  # fallback if not on Postgres

class KVSetting(Base):
    __tablename__ = "kv_settings"
    id = Column(Integer, primary_key=True)
    key = Column(String(128), nullable=False, unique=True)
    value = Column(JSONType, nullable=False, default={})
    __table_args__ = (UniqueConstraint('key', name='uq_kv_key'),)
