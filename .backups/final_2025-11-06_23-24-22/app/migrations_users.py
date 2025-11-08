from sqlalchemy import text
from app.core.database import engine
from app.core.auth import hash_password

def ensure_users():
    stmts = [
        """
        CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY,
          username VARCHAR NOT NULL UNIQUE,
          password_hash VARCHAR NOT NULL,
          role VARCHAR(32) DEFAULT 'admin'
        );
        """,
        """
        INSERT INTO users (username, password_hash, role)
        SELECT 'admin', :ph, 'admin'
        WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='admin');
        """
    ]
    ph = hash_password("admin123")
    with engine.begin() as c:
        for s in stmts:
            c.execute(text(s), {"ph": ph})
