#!/usr/bin/env bash

set -euo pipefail

#######################################
# Configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

ACA_ENV_NAME="${AZURE_ACA_ENV_NAME:-acae-otel-azure-ref-arch}"

ACR_NAME="${AZURE_ACR_NAME:-otelazureacr}"

ACR_IDENTITY_NAME="${AZURE_ACR_IDENTITY_NAME:-id-otel-acr-pull}"

APP_NAME="${TRAFFIC_GENERATOR_APP_NAME:-otel-traffic-generator}"

IMAGE_NAME="${TRAFFIC_GENERATOR_IMAGE_NAME:-otel-traffic-generator}"

IMAGE_TAG="${TRAFFIC_GENERATOR_IMAGE_TAG:-$(git rev-parse --short HEAD)}"

TARGET_URL="${TRAFFIC_GENERATOR_TARGET_URL:-http://otel-python}"

REQUEST_INTERVAL="${TRAFFIC_GENERATOR_REQUEST_INTERVAL:-5}"

REQUEST_TIMEOUT="${TRAFFIC_GENERATOR_REQUEST_TIMEOUT:-10}"

#######################################
# Helpers
#######################################

log() {
    echo
    echo "============================================================"
    echo "==> $1"
    echo "============================================================"
}

fail() {
    echo "ERROR: $1"
    exit 1
}

#######################################
# Validation
#######################################

log "Validating prerequisites"

command -v az >/dev/null 2>&1 || \
    fail "Azure CLI (az) is required."

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

[[ "$ACA_ENV_STATE" == "Succeeded" ]] || \
    fail "ACA environment is not ready. Current state: $ACA_ENV_STATE"

#######################################
# Resolve ACR
#######################################

log "Resolving Azure Container Registry"

ACR_LOGIN_SERVER="$(
    az acr show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --query loginServer \
        --output tsv
)"

[[ -n "$ACR_LOGIN_SERVER" ]] || \
    fail "Could not resolve ACR login server."

IMAGE_REFERENCE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "Image:"
echo "  $IMAGE_REFERENCE"

#######################################
# Resolve managed identity
#######################################

log "Resolving ACR pull identity"

ACR_IDENTITY_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --query id \
        --output tsv
)"

[[ -n "$ACR_IDENTITY_ID" ]] || \
    fail "Managed identity '$ACR_IDENTITY_NAME' was not found."

#######################################
# Verify image
#######################################

log "Verifying traffic generator image"

az acr repository show \
    --name "$ACR_NAME" \
    --image "${IMAGE_NAME}:${IMAGE_TAG}" \
    --output table

#######################################
# Deploy
#######################################

if az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --output none 2>/dev/null; then

    log "Updating existing traffic generator"

    az containerapp update \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --image "$IMAGE_REFERENCE" \
        --set-env-vars \
            TARGET_URL="$TARGET_URL" \
            REQUEST_INTERVAL="$REQUEST_INTERVAL" \
            REQUEST_TIMEOUT="$REQUEST_TIMEOUT" \
        --output none

else

    log "Creating traffic generator Container App"

    az containerapp create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --environment "$ACA_ENV_NAME" \
        --image "$IMAGE_REFERENCE" \
        --cpu 0.25 \
        --memory 0.5Gi \
        --min-replicas 1 \
        --max-replicas 1 \
        --ingress internal \
        --env-vars \
            TARGET_URL="$TARGET_URL" \
            REQUEST_INTERVAL="$REQUEST_INTERVAL" \
            REQUEST_TIMEOUT="$REQUEST_TIMEOUT" \
        --user-assigned "$ACR_IDENTITY_ID" \
        --registry-server "$ACR_LOGIN_SERVER" \
        --registry-identity "$ACR_IDENTITY_ID" \
        --output none

fi

#######################################
# Verify deployment
#######################################

log "Verifying traffic generator"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --query '{
        name:name,
        provisioningState:properties.provisioningState,
        runningStatus:properties.runningStatus,
        image:properties.template.containers[0].image
    }' \
    --output yaml

#######################################
# Revision status
#######################################

log "Checking traffic generator revisions"

az containerapp revision list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --query "[].{
        name:name,
        active:properties.active,
        health:properties.healthState,
        provisioning:properties.provisioningState
    }" \
    --output table

#######################################
# Complete
#######################################

log "Traffic generator deployment complete"

cat <<EOF

Container App:
  $APP_NAME

ACA Environment:
  $ACA_ENV_NAME

Image:
  $IMAGE_REFERENCE

Target:
  $TARGET_URL

Request interval:
  ${REQUEST_INTERVAL}s

Request timeout:
  ${REQUEST_TIMEOUT}s


============================================================
==> Interactive debugging
============================================================

Open a shell:

  az containerapp exec \\
    --resource-group "$RESOURCE_GROUP" \\
    --name "$APP_NAME" \\
    --command sh


Then test Python manually:

  curl -v "$TARGET_URL/"

  curl -v "$TARGET_URL/work"

  curl -v "$TARGET_URL/call-external"

  curl -v "$TARGET_URL/error"

EOF

