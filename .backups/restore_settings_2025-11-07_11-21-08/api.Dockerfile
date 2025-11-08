FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi uvicorn[standard] sqlalchemy "psycopg[binary]" pydantic python-multipart "python-jose[cryptography]" passlib "bcrypt"
ENV PYTHONUNBUFFERED=1
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]

# --- bcrypt/passlib pin to avoid backend version mismatch ---
RUN pip install --no-cache-dir --upgrade --force-reinstall \
    "passlib[bcrypt]==1.7.4" "bcrypt==3.2.2"
# ------------------------------------------------------------
