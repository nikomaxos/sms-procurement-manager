from sqlalchemy import text
from app.core.database import engine

def migrate_domain():
    stmts = [
        # suppliers
        """
        CREATE TABLE IF NOT EXISTS suppliers(
          id SERIAL PRIMARY KEY,
          organization_name VARCHAR NOT NULL UNIQUE
        );
        """,
        # supplier_connections
        """
        CREATE TABLE IF NOT EXISTS supplier_connections(
          id SERIAL PRIMARY KEY,
          supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
          connection_name VARCHAR NOT NULL,
          username VARCHAR,
          kannel_smsc VARCHAR,
          per_delivered BOOLEAN DEFAULT FALSE,
          charge_model VARCHAR(64) DEFAULT 'Per Submitted'
        );
        """,
        # countries with up to 3 MCCs
        """
        CREATE TABLE IF NOT EXISTS countries(
          id SERIAL PRIMARY KEY,
          name VARCHAR NOT NULL UNIQUE,
          mcc VARCHAR(4),
          mcc2 VARCHAR(4),
          mcc3 VARCHAR(4)
        );
        """,
        # networks
        """
        CREATE TABLE IF NOT EXISTS networks(
          id SERIAL PRIMARY KEY,
          country_id INTEGER REFERENCES countries(id) ON DELETE SET NULL,
          name VARCHAR NOT NULL,
          mnc VARCHAR(8),
          mccmnc VARCHAR(12)
        );
        """,
        # offers (flat, denormalized names ok for now)
        """
        CREATE TABLE IF NOT EXISTS offers(
          id SERIAL PRIMARY KEY,
          supplier_name VARCHAR NOT NULL,
          connection_name VARCHAR NOT NULL,
          country_name VARCHAR,
          network_name VARCHAR,
          mccmnc VARCHAR,
          price NUMERIC NOT NULL,
          price_effective_date DATE,
          previous_price NUMERIC,
          route_type VARCHAR,
          known_hops VARCHAR,
          sender_id_supported VARCHAR,
          registration_required VARCHAR,
          eta_days INTEGER,
          charge_model VARCHAR,
          is_exclusive BOOLEAN DEFAULT FALSE,
          notes TEXT,
          updated_by VARCHAR,
          created_at TIMESTAMPTZ DEFAULT now(),
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # config_kv for enums/settings
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
        """,
        # simple updated_at touch via SQL (avoid triggers)
        "CREATE INDEX IF NOT EXISTS idx_offers_updated_at ON offers(updated_at);",
        "CREATE INDEX IF NOT EXISTS idx_cfg_updated_at ON config_kv(updated_at);",
    ]
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
