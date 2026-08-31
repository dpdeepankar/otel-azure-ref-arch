# otel-python

Zero-code, OpenTelemetry-instrumented FastAPI demo service — the Python counterpart to [otel-dotnet](../otel-dotnet/README.md), exposing the same endpoint shape for side-by-side comparison. See the [root README](../../README.md) for the full architecture and deployment picture.

## What it is

- FastAPI app ([app/main.py](app/main.py)), dependencies declared in [pyproject.toml](pyproject.toml), managed with [`uv`](https://docs.astral.sh/uv/).
- Instrumented with zero code changes: the [Dockerfile](Dockerfile) runs `opentelemetry-bootstrap` to auto-install instrumentation packages matching the app's actual dependencies, then launches via `opentelemetry-instrument uvicorn ...` (`CMD`). Running `uvicorn` directly bypasses this wrapper entirely.

## Endpoints

| Route | Behavior |
|---|---|
| `GET /` | Returns `{"message": "hello from zero-code otel demo"}` |
| `GET /work` | Sleeps a random 0.05–0.4s (blocking `time.sleep`), returns the simulated delay |
| `GET /error` | Raises `HTTPException(500)`, producing an error span |
| `GET /call-external` | Makes an outbound `GET https://httpbin.org/get` call via `httpx`, demonstrating downstream span propagation |

## Running locally

**Without instrumentation (fastest inner loop, source-code changes only):**
```bash
uv sync
uv run uvicorn app.main:app --reload
```

**With instrumentation, as it runs in Azure (build the actual image):**
```bash
podman build -t otel-python:local .
podman run -p 8000:8000 otel-python:local
curl http://localhost:8000/
```
The image doesn't set OTLP exporter env vars by default, so with no `OTEL_EXPORTER_OTLP_ENDPOINT` configured, the SDK falls back to its default behavior (attempting `localhost:4317`) and will log connection errors — that's expected when running standalone. In Azure, [infra/deploy-python.sh](../../infra/deploy-python.sh) sets `OTEL_EXPORTER_OTLP_ENDPOINT` to the Alloy Container App.

## Building and deploying

```bash
./../../infra/build-python.sh    # podman build + push to ACR, tagged with the current git short SHA
./../../infra/deploy-python.sh   # create/update the otel-python Container App (requires Alloy to already be deployed)
```
Or trigger [deploy-python.yml](../../.github/workflows/deploy-python.yml) manually from GitHub Actions (`workflow_dispatch`).

## Configuration

| Variable | Set by | Default | Purpose |
|---|---|---|---|
| `OTEL_SERVICE_NAME` | [infra/deploy-python.sh](../../infra/deploy-python.sh) | `zero-code-python-demo` | Service name attached to telemetry |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | [infra/deploy-python.sh](../../infra/deploy-python.sh) | `http://otel-alloy:4317` | Where OTLP is sent once deployed to Azure |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | [infra/deploy-python.sh](../../infra/deploy-python.sh) | `grpc` | Must match Alloy's `otelcol.receiver.otlp` `grpc` block |

See the root README's [Configuration](../../README.md#configuration) section for the full list of variables the deploy script sets.

## Known limitations

- No automated tests exist for this app (no `pytest`/`tests/` directory).
- No `/health` endpoint — Azure Container Apps has no way to probe this service's health beyond process liveness.
- `uv` is pulled from the `ghcr.io/astral-sh/uv:latest` image tag in the Dockerfile (not pinned), so builds are not fully reproducible.
