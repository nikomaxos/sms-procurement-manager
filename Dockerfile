FROM python:3.12-slim

WORKDIR /app
COPY worker/app /app/app

# deps for pandas/excel/imap
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libxml2-dev libxslt1-dev \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    imapclient pandas openpyxl xlrd lxml \
    sqlalchemy psycopg2-binary pydantic \
    tenacity email-validator chardet python-dateutil

ENV PYTHONUNBUFFERED=1
CMD ["python3","-u","app/runloop.py"]
