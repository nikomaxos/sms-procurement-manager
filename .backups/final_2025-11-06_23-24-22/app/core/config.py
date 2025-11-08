import os

APP_NAME = "SMS Procurement Manager"
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")

DB_URL = os.getenv("DB_URL", "postgresql://postgres:postgres@postgres:5432/smsdb")

# CORS
CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "http://localhost:5183").split(",") if o.strip()]

# Auth
JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALGO = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "120"))
