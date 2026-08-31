# Prerequisites

This page lists what you need installed and access you need granted before you can build, run, or deploy any part of [otel-azure-ref-arch](../README.md).

## Local tooling

| Tool | Why | Verify |
|---|---|---|
| [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/) | Every `infra/*.sh` script shells out to `az` directly | `az version` |
| `containerapp` az extension | Required for all `az containerapp ...` commands | `az extension add --name containerapp --upgrade` (scripts also do this automatically in `infra/deploy-alloy.sh`) |
| [Podman](https://podman.io/) | `infra/build-*.sh` scripts use `podman build` / `podman push` | `podman --version` |
| Git | Image tags default to `git rev-parse --short HEAD`; several scripts require a git checkout | `git --version` |
| .NET SDK 10.0 | Build/run [otel-dotnet](../apps/otel-dotnet/README.md) outside a container | `dotnet --version` |
| Python 3.12+ and [`uv`](https://docs.astral.sh/uv/) | Build/run [otel-python](../apps/otel-python/README.md) outside a container | `uv --version` |
| Python 3.x | Run [traffic-generator](../apps/traffic-generator/README.md) locally (stdlib only, no `uv` needed) | `python3 --version` |
| Docker + Buildx | Only needed if you replace Podman locally, or to mirror what CI does | `docker buildx version` |

> **ARM hosts (e.g. Apple Silicon):** `infra/build-alloy.sh` explicitly fails if the built image is not `linux/amd64`. Ensure your container engine can cross-build/emulate `linux/amd64` before running any `infra/build-*.sh` script.

## Azure access

| Requirement | Why |
|---|---|
| Subscription-level access (Owner/Contributor + User Access Administrator, or equivalent) | `infra/deploy.sh` creates a resource group, VNet, subnets, and an ACA Environment; `infra/deploy-*.sh` scripts create managed identities and assign the `AcrPull` RBAC role, which requires role-assignment write permission |
| An existing Azure Container Registry (ACR) | **Not provisioned by any script in this repo.** Create it yourself before running any `build-*.sh`/`deploy-*.sh` script — see [Information Required](../README.md#information-required) in the root README |

## Grafana Cloud access

| Requirement | Why |
|---|---|
| A Grafana Cloud stack (or any OTLP/HTTP-with-basic-auth-compatible backend) | [otel-alloy](../otel-alloy/README.md) exports traces/metrics/logs there |
| Grafana Cloud Instance ID, API key, and OTLP endpoint URL | Required env vars for `infra/deploy-alloy.sh` — see [telemetry.md](telemetry.md#configuration) |

## CI/CD access (only if you plan to use GitHub Actions)

| Requirement | Why |
|---|---|
| An Azure AD App Registration / Service Principal | Used by the `azure/login` step in every workflow under [.github/workflows](../.github/workflows) |
| GitHub repository secrets: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `GRAFANA_CLOUD_INSTANCE_ID`, `GRAFANA_CLOUD_API_KEY`, `GRAFANA_CLOUD_OTLP_ENDPOINT` | Consumed via `secrets.*` in the workflows |
| GitHub repository/environment variables: `AZURE_RESOURCE_GROUP`, `AZURE_ACA_ENV_NAME`, `AZURE_ACR_NAME`, `AZURE_ALLOY_APP_NAME`, `DOTNET_APP_NAME`, `PYTHON_APP_NAME`, `TRAFFIC_GENERATOR_APP_NAME`, plus matching `*_IMAGE_NAME` variables | Consumed via `vars.*` in the workflows |

> **Known gap:** [buildAndDeployDotnet.yml](../.github/workflows/buildAndDeployDotnet.yml) declares `permissions: id-token: write` (suggesting OIDC federated login) but also passes `client-secret` to `azure/login`. Decide which auth model your App Registration actually uses before relying on this workflow — see [security.md](security.md#authentication).

Once these are satisfied, continue to the root README's [Installation](../README.md#installation) steps.
