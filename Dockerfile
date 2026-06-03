FROM python:3.12-slim

WORKDIR /app

# Install deps first for layer caching. We install the project (which pulls
# fastapi/uvicorn/httpx/pyyaml from pyproject) without dev extras.
COPY pyproject.toml ./
COPY src/ ./src/
RUN pip install --no-cache-dir .

# Defaults; override in compose. /config holds registry.yaml, /data holds state.
ENV WATCHDOG_REGISTRY=/config/registry.yaml \
    WATCHDOG_STATE=/data/state.json \
    WATCHDOG_HOST=0.0.0.0 \
    WATCHDOG_PORT=9099

EXPOSE 9099

# Container-level liveness: the app's own /healthz.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9099/healthz').status==200 else 1)"

CMD ["fleet-watchdog"]
