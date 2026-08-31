# otel-dotnet

Zero-code, OpenTelemetry-instrumented ASP.NET Core (minimal API) demo service. See the [root README](../../README.md) for the full architecture and deployment picture — this file only covers what's specific to this app.

## What it is

- .NET 10 minimal API ([Program.cs](app/Program.cs), [app.csproj](app/app.csproj)).
- Instrumented with zero code changes: the [Dockerfile](Dockerfile) downloads and installs the [OpenTelemetry .NET Automatic Instrumentation](https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation) agent and starts the app via its `instrument.sh` wrapper (`ENTRYPOINT`). Running `dotnet run` directly on your host bypasses this agent entirely.

## Endpoints

| Route | Behavior |
|---|---|
| `GET /` | Returns `{"message": "hello from zero-code otel demo"}` |
| `GET /work` | Sleeps a random 0.05–0.4s, returns the simulated delay — useful for latency-variance demos |
| `GET /error` | Throws `InvalidOperationException`, producing an error span |
| `GET /call-external` | Makes an outbound `GET https://httpbin.org/get` call, demonstrating downstream span propagation |

## Running locally

**Without instrumentation (fastest inner loop, source-code changes only):**
```bash
cd app
dotnet run
```

**With instrumentation, as it runs in Azure (build the actual image):**
```bash
podman build -t otel-dotnet:local .
podman run -p 8080:8080 otel-dotnet:local
curl http://localhost:8080/
```
The container's default exporters are `console` (see `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` in the Dockerfile) — traces/metrics/logs print to stdout. In Azure, [infra/deploy-dotnet.sh](../../infra/deploy-dotnet.sh) overrides these to `otlp` and points `OTEL_EXPORTER_OTLP_ENDPOINT` at the Alloy Container App.

## Building and deploying

```bash
./../../infra/build-dotnet.sh    # podman build + push to ACR, tagged with the current git short SHA
./../../infra/deploy-dotnet.sh   # create/update the otel-dotnet Container App
```
Or trigger [buildAndDeployDotnet.yml](../../.github/workflows/buildAndDeployDotnet.yml) manually from GitHub Actions (`workflow_dispatch`).

## Configuration

| Variable | Set by | Default | Purpose |
|---|---|---|---|
| `OTEL_VERSION` (Docker build arg) | Dockerfile | `1.16.0` | Pinned version of the OTel .NET auto-instrumentation agent |
| `ASPNETCORE_URLS` | Dockerfile | `http://+:8080` | Listen address inside the container |
| `OTEL_SERVICE_NAME` | Dockerfile default / [infra/deploy-dotnet.sh](../../infra/deploy-dotnet.sh) | `otel-dotnet-demo` (image default) / `zero-code-dotnet-demo` (Azure) | Service name attached to telemetry |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | [infra/deploy-dotnet.sh](../../infra/deploy-dotnet.sh) | `http://otel-alloy:4317` | Where OTLP is sent once deployed to Azure |

See the root README's [Configuration](../../README.md#configuration) section for the full list of variables the deploy script sets.

## Known limitations

- No automated tests exist for this app (no `*.Tests.csproj`).
- No `/health` endpoint — Azure Container Apps has no way to probe this service's health beyond process liveness.
