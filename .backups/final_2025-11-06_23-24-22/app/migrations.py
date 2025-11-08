from sqlalchemy import text
from app.core.database import engine

def migrate_all():
    stmts = [
        # config_kv for enums/settings
        """
        CREATE TABLE IF NOT EXISTS config_kv(
          key TEXT PRIMARY KEY,
          value JSONB NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT now()
        )
        """,
        # suppliers
        """
        CREATE TABLE IF NOT EXISTS suppliers(
          id SERIAL PRIMARY KEY,
          organization_name VARCHAR UNIQUE NOT NULL
        )
        """,
        # supplier_connections (per_delivered here)
        """
        CREATE TABLE IF NOT EXISTS supplier_connections(
          id SERIAL PRIMARY KEY,
          supplier_id INTEGER REFERENCES suppliers(id) ON DELETE CASCADE,
          connection_name VARCHAR NOT NULL,
          username VARCHAR,
          kannel_smsc VARCHAR,
          per_delivered BOOLEAN DEFAULT FALSE,
          charge_model VARCHAR(64) DEFAULT 'Per Submitted',
          UNIQUE(supplier_id, connection_name)
        )
        """,
        # countries (with extra MCCs)
        """
        CREATE TABLE IF NOT EXISTS countries(
          id SERIAL PRIMARY KEY,
          name VARCHAR UNIQUE NOT NULL,
          mcc VARCHAR(4),
          mcc2 VARCHAR(4),
          mcc3 VARCHAR(4)
        )
        """,
        # networks (name + country fk by name)
        """
        CREATE TABLE IF NOT EXISTS networks(
          id SERIAL PRIMARY KEY,
          name VARCHAR NOT NULL,
          country_name VARCHAR REFERENCES countries(name) ON UPDATE CASCADE ON DELETE SET NULL,
          mcc VARCHAR(4),
          mnc VARCHAR(4),
          mccmnc VARCHAR(8),
          UNIQUE(name, country_name)
        )
        """,
        # offers (name-based columns)
        """
        CREATE TABLE IF NOT EXISTS offers(
          id SERIAL PRIMARY KEY,
          supplier_name VARCHAR NOT NULL,
          connection_name VARCHAR NOT NULL,
          country_name VARCHAR,
          network_name VARCHAR,
          mccmnc VARCHAR(8),
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
        )
        """,
    ]
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s))
