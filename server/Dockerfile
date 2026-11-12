FROM python:3.15-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Persist keys and the self-hosted source outside the container layer when /data
# is a mounted volume.
ENV VEXSIGN_DB=/data/vexsign.db
ENV REPO_STORE_DIR=/data/repo-store

CMD uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}
