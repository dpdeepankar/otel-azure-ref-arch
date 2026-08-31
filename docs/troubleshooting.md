# Troubleshooting

For the master troubleshooting table, see the root README's [Troubleshooting section](../README.md#troubleshooting) — it is not duplicated here. This page adds deeper diagnostic steps for the most common failure classes.

## "ACA environment is not ready" / deploy script fails early

1. Check the environment's actual state:
   ```bash
   az containerapp env show --resource-group rg-otel-azure-ref-arch --name acae-otel-azure-ref-arch --query properties.provisioningState
   ```
2. If it's `null`/not found, `infra/deploy.sh` was never run (or ran against a different resource group/subscription than you're now targeting).
3. If it's stuck in `Provisioning` for an extended period, check the Activity Log in the Azure Portal for the resource group — subnet delegation conflicts are the most common cause.

## No telemetry in Grafana Cloud

Work through this in order (see also [telemetry.md](telemetry.md#verifying-telemetry-end-to-end)):

1. **Is Alloy running?** `az containerapp show --resource-group <rg> --name otel-alloy --query properties.runningStatus`
2. **Does Alloy have valid Grafana Cloud credentials?** `az containerapp show --resource-group <rg> --name otel-alloy --query properties.template.containers[0].env` — confirm `GRAFANA_CLOUD_INSTANCE_ID`/`GRAFANA_CLOUD_API_KEY`/`GRAFANA_CLOUD_OTLP_ENDPOINT` are all set and non-empty.
3. **Are the apps pointed at the right Alloy name?** Confirm `OTEL_EXPORTER_OTLP_ENDPOINT` on `otel-dotnet`/`otel-python` matches Alloy's actual Container App name (`http://<AZURE_ALLOY_APP_NAME>:4317`) — a rename of one without the other is a common self-inflicted break.
4. **Check Alloy's own logs** for export errors: `az containerapp logs show --resource-group <rg> --name otel-alloy --follow`. A `401`/`403` from the exporter usually means bad Grafana Cloud credentials; a connection error usually means a networking/DNS issue.
5. **Is traffic actually happening?** If `traffic-generator` isn't deployed and nobody is curling the apps, there's simply nothing to export.

## Image build/push failures

| Symptom | Check |
|---|---|
| `podman: command not found` | Install Podman — `infra/build-*.sh` scripts hard-require it and will not fall back to Docker |
| "Alloy image must be linux/amd64" | You're likely building on an ARM host without cross-platform emulation enabled |
| `az acr login` fails | Confirm `AZURE_ACR_NAME` matches an ACR that actually exists — no script in this repo creates one for you |
| Image pushes but Container App still runs the old version | Confirm you re-ran the matching `infra/deploy-*.sh` (or the CI `deploy` job) — building/pushing alone does not update the running Container App |

## GitHub Actions failures

| Symptom | Check |
|---|---|
| `azure/login` step fails | See the OIDC-vs-client-secret inconsistency noted in [security.md](security.md#authentication) for `buildAndDeployDotnet.yml` |
| `az acr show` / `az containerapp env show` fails inside a workflow | Confirm the repository/environment **variables** (`vars.AZURE_RESOURCE_GROUP`, `vars.AZURE_ACA_ENV_NAME`, `vars.AZURE_ACR_NAME`, etc.) are actually configured in GitHub repo settings — the workflows assume they exist and do not validate them upfront |
| Workflow succeeds but nothing changed in Azure | Confirm you triggered the right workflow for the component you changed — each of the four workflows only builds/deploys its own component |

## Escalation

If none of the above resolves it, capture: the failing script/workflow name, the exact error text, `az containerapp show` output for the affected app, and Alloy's recent logs — then see [Ownership and Support](../README.md#ownership-and-support) in the root README.
