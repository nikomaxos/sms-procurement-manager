FROM python:3.12-slim
WORKDIR /app
COPY . /app
RUN pip install --no-cache-dir celery redis
CMD ["celery", "-A", "app.main", "worker", "--loglevel=info"]
