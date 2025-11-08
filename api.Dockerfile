FROM python:3.12-slim
WORKDIR /app
COPY api/app /app/app
RUN pip install --no-cache-dir fastapi uvicorn[standard] "python-jose[cryptography]" pydantic
ENV DATA_DIR=/app/data
RUN mkdir -p /app/data
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
