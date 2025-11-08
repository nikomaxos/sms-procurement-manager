FROM python:3.12-slim

WORKDIR /app
COPY app /app/app

# system deps for psycopg2 & lxml speed
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev && rm -rf /var/lib/apt/lists/*

# pin auth deps to avoid bcrypt bugs
RUN pip install --no-cache-dir \
    fastapi==0.112.2 uvicorn[standard]==0.30.6 \
    "SQLAlchemy==2.0.32" "psycopg2-binary==2.9.9" \
    "passlib==1.7.4" "bcrypt==4.0.1" \
    "python-jose[cryptography]==3.3.0" \
    "python-multipart==0.0.9"

ENV PYTHONUNBUFFERED=1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
