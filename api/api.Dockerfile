FROM python:3.11-slim

LABEL org.opencontainers.image.source=https://github.com/immunoplex/immunoplex-batch-cal-api
LABEL org.opencontainers.image.description="Immunoplex Batch Runner — API"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
