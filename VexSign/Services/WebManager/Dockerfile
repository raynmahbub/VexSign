# Python 3.12 is the interpreter CI validates (services.yml `python-version: '3.12'`).
# The base image was 3.15, so the pinned requirements were exercised on one minor
# version and shipped on another. Either direction is fine as long as both name the
# same version; test_runtime_policy.py enforces that.
FROM python:3.12-slim

WORKDIR /app

COPY Configuration/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Persist keys and the self-hosted source outside the container layer when /data
# is a mounted volume.
ENV VEXSIGN_DB=/data/vexsign.db
ENV REPO_STORE_DIR=/data/repo-store

# Unprivileged runtime. This process parses untrusted uploads (IPAs, profiles,
# feeds) and fetches user-supplied URLs, so a compromise should not start as
# root. A bind-mounted /data has to be writable by this uid; a named volume
# inherits the ownership set here.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin vexsign \
    && mkdir -p /data/repo-store \
    && chown -R 10001:10001 /data /app
USER 10001

# Uses /api/health through the standard library: the slim image has no curl.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/api/health' % os.environ.get('PORT', '8080'), timeout=2)"

CMD uvicorn --app-dir API main:app --host 0.0.0.0 --port ${PORT:-8080}
