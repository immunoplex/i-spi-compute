FROM python:3.11-slim

LABEL org.opencontainers.image.source=https://github.com/immunoplex/i-spi-compute
LABEL org.opencontainers.image.description="i-spi-compute — job API (FastAPI)"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
