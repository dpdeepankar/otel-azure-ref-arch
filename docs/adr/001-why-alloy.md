# ADR 001: Use Grafana Alloy as the OpenTelemetry Collector

## Status
Accepted (inferred from current implementation — no original decision record existed prior to this documentation pass).

## Context
The demo apps need somewhere to send OTLP data. The options considered by any OTel reference architecture are typically: (a) export directly from each app straight to the observability backend, (b) run the vanilla `otelcol` (OpenTelemetry Collector core/contrib) distribution, or (c) run a vendor-flavored distribution like Grafana Alloy.

## Decision
Use **Grafana Alloy** ([otel-alloy/config.alloy](../../otel-alloy/config.alloy)) as the single collector between the apps and Grafana Cloud, rather than exporting directly from each app or using the vanilla OpenTelemetry Collector.

## Rationale
- **Credential isolation** — apps only need to know Alloy's internal address (`http://otel-alloy:4317`); Grafana Cloud credentials live in exactly one place (see [ADR 004](004-centralized-telemetry.md)).
- **First-class Grafana Cloud integration** — Alloy ships with `otelcol.exporter.otlphttp` + `otelcol.auth.basic` components that map directly onto Grafana Cloud's ingestion model (Instance ID + API key over OTLP/HTTP), reducing collector-config boilerplate compared to hand-rolling the equivalent in vanilla `otelcol` YAML.
- **Single upgrade/config surface** — one container image and one config file ([config.alloy](../../otel-alloy/config.alloy)) to maintain, instead of duplicating exporter configuration across every app.

## Consequences
- Alloy becomes a **single point of failure** for telemetry (not for the apps themselves — they run independently of Alloy's health) — if Alloy is down or misconfigured, all telemetry is silently dropped until it's fixed.
- Swapping the observability backend later (e.g. away from Grafana Cloud) only requires editing [config.alloy](../../otel-alloy/config.alloy)'s exporter/auth blocks, not touching any application code — this was a deliberate design goal.
- Alloy's own image build/deploy scripts (`infra/build-alloy.sh`, `infra/deploy-alloy.sh`) are on the critical path for every other deploy script (see [ADR 004](004-centralized-telemetry.md) and [deployment.md](../deployment.md#deployment-flow)).
