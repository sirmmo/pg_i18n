FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY pg_i18n_worker.py .
ENTRYPOINT ["python", "pg_i18n_worker.py"]
