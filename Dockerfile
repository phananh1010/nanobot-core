FROM python:3.11-slim AS builder

WORKDIR /build

RUN pip install --no-cache-dir uv

COPY pyproject.toml .
RUN uv pip install --system --no-cache-dir -e . 2>/dev/null || true
COPY . .
RUN uv pip install --system --no-cache-dir .


FROM python:3.11-slim

LABEL org.opencontainers.image.title="nanobot" \
      org.opencontainers.image.description="A lightweight personal AI assistant framework"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /build /app

WORKDIR /app

RUN useradd -m -u 1000 -s /bin/bash nanobot \
    && mkdir -p /data/nanobot \
    && chown nanobot:nanobot /data/nanobot

USER nanobot

ENV HOME=/home/nanobot \
    NANOBOT_AGENTS__DEFAULTS__WORKSPACE=/data/nanobot/workspace \
    PYTHONUNBUFFERED=1

VOLUME ["/data/nanobot"]

EXPOSE 18790

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:18790/health || exit 1

CMD ["python", "-m", "nanobot", "gateway", "--config", "/data/nanobot/config.json"]
