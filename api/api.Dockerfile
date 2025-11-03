FROM python:3.12-slim
WORKDIR /app
COPY app /app/app
RUN apt-get update && apt-get install -y gcc && \
    pip install --no-cache-dir \
      fastapi uvicorn[standard] sqlalchemy psycopg2-binary pydantic \
      python-multipart python-jose[cryptography] \
      "passlib[bcrypt]==1.7.4" "bcrypt==4.0.1"

EXPOSE 8000
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
