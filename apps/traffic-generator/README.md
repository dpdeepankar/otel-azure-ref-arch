# traffic-generator

A minimal, dependency-free Python script that continuously calls [otel-python](../otel-python/README.md) (or any configured target) so telemetry keeps flowing through the pipeline for demos, dashboards, and alert testing. See the [root README](../../README.md) for the full architecture picture.

## What it is

- A single stdlib-only script ([app.py](app.py)) — no `requirements.txt` dependencies are actually needed (the file exists but is empty).
- **Not itself instrumented with OpenTelemetry.** It prints structured request logs to stdout (`request method=GET path=... status=... duration=...s`) instead of emitting spans/metrics — its own health/performance is not observable through the pipeline it feeds.
- Picks a random endpoint from `/`, `/work`, `/call-external`, `/error` on every iteration and sleeps between requests.

## Running locally

```bash
python app.py
# or, against a locally-running otel-python instance:
TARGET_URL=http://localhost:8000 REQUEST_INTERVAL=2 python app.py
```

**Via container:**
```bash
podman build -t otel-traffic-generator:local .
podman run -e TARGET_URL=http://otel-python otel-traffic-generator:local
```

## Building and deploying

```bash
./../../infra/build-traffic-generator.sh    # podman build + push to ACR, tagged with the current git short SHA
./../../infra/deploy-traffic-generator.sh   # create/update the otel-traffic-generator Container App
```
Or trigger [deploy-traffic-generator.yml](../../.github/workflows/deploy-traffic-generator.yml) manually from GitHub Actions (`workflow_dispatch`).

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `TARGET_URL` | `http://otel-python` | Base URL of the service to poll. Point this at `http://otel-dotnet` to test the .NET app instead. |
| `REQUEST_INTERVAL` | `5` (seconds) | Delay between requests |
| `REQUEST_TIMEOUT` | `10` (seconds) | Per-request timeout before the call is treated as an error |

Deployed via `infra/deploy-traffic-generator.sh` with `--ingress internal` — this app has no need for any ingress at all (it only makes outbound calls), but ACA requires an ingress setting either way.

## Known limitations

- No automated tests.
- No OpenTelemetry instrumentation — if this script itself hangs or crashes, you won't see it in traces/metrics, only in its container logs (`az containerapp logs show`).
- `requirements.txt` exists but is empty; the script has no third-party dependencies today, so keep it that way unless you add one deliberately.
