# ADR 003: Deploy Azure Container Apps into a private, delegated VNet subnet

## Status
Accepted (inferred from current implementation).

## Context
Azure Container Apps can run in a default (Microsoft-managed) networking mode with public ingress, or in a **workload profile / VNet-injected** mode where the ACA Environment lives inside a customer-managed VNet subnet. Enterprises commonly require the latter for compliance/network-isolation reasons.

## Decision
Provision a dedicated VNet (`vnet-otel-azure-ref-arch`, `10.20.0.0/16`) with a subnet delegated to `Microsoft.App/environments` (`snet-aca`, `10.20.0.0/23`), and create every Container App with `--ingress internal` (no public endpoint). See [infra/deploy.sh](../../infra/deploy.sh) and [networking.md](../networking.md).

## Rationale
- Demonstrates the pattern most likely to be required in a real enterprise environment, rather than the simpler (but less representative) public-ACA default.
- A separate `snet-appgw` subnet (`10.20.2.0/24`) is reserved up front so that a future Application Gateway (or other approved ingress) can be added later without re-architecting the VNet.

## Consequences
- **No app is reachable from the public internet by default** — this is a deliberate, security-positive default, but it makes the "getting started" experience less immediately gratifying (you can't just open a browser to see the demo working; see [Running the Project](../../README.md#running-the-project)).
- The `snet-appgw` subnet reservation is **not accompanied by any script that actually deploys an Application Gateway or WAF** — a new maintainer should not assume public exposure is "almost done"; it requires net-new work.
- Subnet delegation to `Microsoft.App/environments` is re-asserted on every run of `infra/deploy.sh` (`az network vnet subnet update --delegations ...`) — if this delegation is ever manually removed via the Portal, the next `deploy.sh` run will silently repair it (idempotent by design), but any manual attempt to reuse that subnet for another purpose in the meantime will fail.
