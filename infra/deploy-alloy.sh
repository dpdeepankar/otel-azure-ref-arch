#!/usr/bin/env bash

set -euo pipefail

#######################################
# Required configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

ACA_ENV_NAME="${AZURE_ACA_ENV_NAME:-acae-otel-azure-ref-arch}"

ALLOY_APP_NAME="${AZURE_ALLOY_APP_NAME:-otel-alloy}"

ALLOY_IMAGE="${AZURE_ALLOY_IMAGE:-grafana/alloy:latest}"

ALLOY_OTLP_GRPC_PORT="${AZURE_ALLOY_OTLP_GRPC_PORT:-4317}"
ALLOY_OTLP_HTTP_PORT="${AZURE_ALLOY_OTLP_HTTP_PORT:-4318}"

#######################################
# Grafana configuration
#######################################

GRAFANA_CLOUD_INSTANCE_ID="${GRAFANA_CLOUD_INSTANCE_ID:?GRAFANA_CLOUD_INSTANCE_ID is required}"

GRAFANA_CLOUD_API_KEY="${GRAFANA_CLOUD_API_KEY:?GRAFANA_CLOUD_API_KEY is required}"

GRAFANA_CLOUD_OTLP_ENDPOINT="${GRAFANA_CLOUD_OTLP_ENDPOINT:?GRAFANA_CLOUD_OTLP_ENDPOINT is required}"

#######################################
# Alloy configuration
#######################################

ALLOY_CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../otel-alloy" && pwd)/config.alloy"

#######################################
# Helpers
#######################################

log() {
    echo
    echo "============================================================"
    echo "==> $1"
    echo "============================================================"
}

#######################################
# Validation
#######################################

log "Validating prerequisites"

command -v az >/dev/null 2>&1 || {
    echo "ERROR: Azure CLI (az) is required."
    exit 1
}

command -v base64 >/dev/null 2>&1 || {
    echo "ERROR: base64 is required."
    exit 1
}

if [[ ! -f "$ALLOY_CONFIG_FILE" ]]; then
    echo "ERROR: Alloy config not found:"
    echo "$ALLOY_CONFIG_FILE"
    exit 1
fi

#######################################
# Azure subscription
#######################################

log "Selecting Azure subscription"

az account set \
    --subscription "$SUBSCRIPTION_ID"

#######################################
# Verify ACA environment
#######################################

log "Verifying Container Apps environment"

ACA_ENV_STATE="$(
    az containerapp env show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACA_ENV_NAME" \
        --query "properties.provisioningState" \
        --output tsv
)"

if [[ "$ACA_ENV_STATE" != "Succeeded" ]]; then
    echo "ERROR: Container Apps environment is not ready."
    echo "Current state: $ACA_ENV_STATE"
    exit 1
fi

echo "ACA environment: $ACA_ENV_NAME"
echo "State: $ACA_ENV_STATE"

#######################################
# Encode Alloy configuration
#######################################

log "Encoding Alloy configuration"


#######################################
# Deploy / update Alloy
#######################################

if az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output none 2>/dev/null; then

    log "Updating existing Alloy Container App"

    az containerapp secret set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --secrets \
            grafana-instance-id="$GRAFANA_CLOUD_INSTANCE_ID" \
            grafana-api-key="$GRAFANA_CLOUD_API_KEY" \
        --output none

    az containerapp update \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --image "$ALLOY_IMAGE" \
        --set-env-vars \
            GRAFANA_CLOUD_INSTANCE_ID=secretref:grafana-instance-id \
            GRAFANA_CLOUD_API_KEY=secretref:grafana-api-key \
            GRAFANA_CLOUD_OTLP_ENDPOINT="$GRAFANA_CLOUD_OTLP_ENDPOINT" \
        --output none

else

    log "Creating Alloy Container App"

    az containerapp create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --environment "$ACA_ENV_NAME" \
        --image "$ALLOY_IMAGE" \
        --cpu 0.5 \
        --memory 1.0Gi \
        --min-replicas 1 \
        --max-replicas 2 \
        --secrets \
            grafana-instance-id="$GRAFANA_CLOUD_INSTANCE_ID" \
            grafana-api-key="$GRAFANA_CLOUD_API_KEY" \
        --env-vars \
            GRAFANA_CLOUD_INSTANCE_ID=secretref:grafana-instance-id \
            GRAFANA_CLOUD_API_KEY=secretref:grafana-api-key \
            GRAFANA_CLOUD_OTLP_ENDPOINT="$GRAFANA_CLOUD_OTLP_ENDPOINT" \
        --ingress internal \
        --target-port 4318 \
        --transport http \
        --allow-insecure true \
        --output none

fi

#######################################
# Verify
#######################################

log "Checking Alloy Container App"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --query '{
        name:name,
        provisioningState:properties.provisioningState,
        runningStatus:properties.runningStatus,
        fqdn:properties.configuration.ingress.fqdn
    }' \
    --output yaml

#######################################
# Revision status
#######################################

log "Checking Alloy revisions"

az containerapp revision list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --query "[].{
        name:name,
        active:properties.active,
        health:properties.healthState,
        provisioning:properties.provisioningState
    }" \
    --output table

#######################################
# Final output
#######################################

log "Alloy deployment complete"

cat <<EOF

Alloy Container App:
  $ALLOY_APP_NAME

ACA Environment:
  $ACA_ENV_NAME

OTLP gRPC:
  $ALLOY_OTLP_GRPC_PORT

OTLP HTTP:
  $ALLOY_OTLP_HTTP_PORT

Grafana OTLP endpoint:
  $GRAFANA_CLOUD_OTLP_ENDPOINT

Ingress:
  INTERNAL

Credentials:
  Stored as ACA secrets

EOF

