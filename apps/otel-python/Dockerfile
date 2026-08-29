FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

COPY pyproject.toml .
RUN uv sync --no-cache

RUN uv run opentelemetry-bootstrap -a requirements | xargs -I {} uv add --requirement - {}

RUN uv pip install "opentelemetry-instrumentation-system-metrics[instruments]"

COPY app/ ./app/

EXPOSE 8000

CMD ["uv", "run", "opentelemetry-instrument", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
