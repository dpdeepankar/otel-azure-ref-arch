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

APP_NAME="${DOTNET_APP_NAME:-otel-dotnet}"

IMAGE_NAME="${DOTNET_IMAGE_NAME:-otel-dotnet}"

IMAGE_TAG="${DOTNET_IMAGE_TAG:-$(git rev-parse --short HEAD)}"

CONTAINER_PORT="${DOTNET_CONTAINER_PORT:-8080}"

ALLOY_APP_NAME="${AZURE_ALLOY_APP_NAME:-otel-alloy}"

OTEL_SERVICE_NAME="${DOTNET_OTEL_SERVICE_NAME:-zero-code-dotnet-demo}"

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

if [[ "$ACA_ENV_STATE" != "Succeeded" ]]; then
    fail "ACA environment is not ready. Current state: $ACA_ENV_STATE"
fi

#######################################
# Verify Alloy
#######################################

log "Verifying Alloy Container App"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output none

#######################################
# Resolve ACR
#######################################

log "Resolving Azure Container Registry"

ACR_RESOURCE_ID="$(
    az acr show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --query id \
        --output tsv
)"

ACR_LOGIN_SERVER="$(
    az acr show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --query loginServer \
        --output tsv
)"

[[ -n "$ACR_RESOURCE_ID" ]] || \
    fail "Could not resolve ACR resource ID."

[[ -n "$ACR_LOGIN_SERVER" ]] || \
    fail "Could not resolve ACR login server."

IMAGE_REFERENCE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "Image:"
echo "  $IMAGE_REFERENCE"

#######################################
# Verify image
#######################################

log "Verifying .NET image"

az acr repository show \
    --name "$ACR_NAME" \
    --image "${IMAGE_NAME}:${IMAGE_TAG}" \
    --output table

#######################################
# Ensure managed identity
#######################################

log "Ensuring ACR pull managed identity"

if ! az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_IDENTITY_NAME" \
    --output none 2>/dev/null; then

    echo "Creating managed identity:"
    echo "  $ACR_IDENTITY_NAME"

    az identity create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --output none
else
    echo "Managed identity already exists."
fi

#######################################
# Identity details
#######################################

ACR_IDENTITY_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --query id \
        --output tsv
)"

ACR_IDENTITY_PRINCIPAL_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --query principalId \
        --output tsv
)"

#######################################
# AcrPull
#######################################

log "Ensuring AcrPull role assignment"

ACR_PULL_ROLE_ID="7f951dda-4ed3-4680-a7ca-43fe172d538d"

EXISTING_ROLE="$(
    az role assignment list \
        --assignee-object-id "$ACR_IDENTITY_PRINCIPAL_ID" \
        --scope "$ACR_RESOURCE_ID" \
        --role "$ACR_PULL_ROLE_ID" \
        --query "[0].id" \
        --output tsv
)"

if [[ -z "$EXISTING_ROLE" ]]; then

    az role assignment create \
        --assignee-object-id "$ACR_IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$ACR_PULL_ROLE_ID" \
        --scope "$ACR_RESOURCE_ID" \
        --output none

    echo "AcrPull assigned."

else

    echo "AcrPull already assigned."

fi

#######################################
# Create / update app
#######################################

if az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --output none 2>/dev/null; then

    ###################################
    # Update
    ###################################

    log "Updating existing .NET Container App"

    az containerapp identity assign \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --user-assigned "$ACR_IDENTITY_ID" \
        --output none

    az containerapp registry set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --server "$ACR_LOGIN_SERVER" \
        --identity "$ACR_IDENTITY_ID" \
        --output none

    az containerapp update \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --image "$IMAGE_REFERENCE" \
        --set-env-vars \
            OTEL_SERVICE_NAME="$OTEL_SERVICE_NAME" \
            OTEL_TRACES_EXPORTER=otlp \
            OTEL_METRICS_EXPORTER=otlp \
            OTEL_LOGS_EXPORTER=otlp \
            OTEL_EXPORTER_OTLP_ENDPOINT="http://${ALLOY_APP_NAME}:4317" \
            OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
            OTEL_METRIC_EXPORT_INTERVAL=5000 \
            OTEL_RESOURCE_ATTRIBUTES=deployment.environment=azure \
        --output none

else

    ###################################
    # Create
    ###################################

    log "Creating .NET Container App"

    az containerapp create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --environment "$ACA_ENV_NAME" \
        --image "$IMAGE_REFERENCE" \
        --cpu 0.5 \
        --memory 1.0Gi \
        --min-replicas 1 \
        --max-replicas 2 \
        --ingress internal \
        --target-port "$CONTAINER_PORT" \
        --transport http \
        --env-vars \
            OTEL_SERVICE_NAME="$OTEL_SERVICE_NAME" \
            OTEL_TRACES_EXPORTER=otlp \
            OTEL_METRICS_EXPORTER=otlp \
            OTEL_LOGS_EXPORTER=otlp \
            OTEL_EXPORTER_OTLP_ENDPOINT="http://${ALLOY_APP_NAME}:4317" \
            OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
            OTEL_METRIC_EXPORT_INTERVAL=5000 \
            OTEL_RESOURCE_ATTRIBUTES=deployment.environment=azure \
        --user-assigned "$ACR_IDENTITY_ID" \
        --registry-server "$ACR_LOGIN_SERVER" \
        --registry-identity "$ACR_IDENTITY_ID" \
        --output none

fi

#######################################
# Verify deployment
#######################################

log "Verifying .NET Container App"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --query '{
        name:name,
        provisioningState:properties.provisioningState,
        runningStatus:properties.runningStatus,
        image:properties.template.containers[0].image,
        fqdn:properties.configuration.ingress.fqdn
    }' \
    --output yaml

#######################################
# Revision status
#######################################

log "Checking .NET revisions"

az containerapp revision list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --query "[].{
        name:name,
        active:properties.active,
        health:properties.healthState,
        provisioning:properties.provisioningState,
        image:properties.template.containers[0].image
    }" \
    --output table

#######################################
# Complete
#######################################

log ".NET deployment complete"

cat <<EOF

Application:
  $APP_NAME

Image:
  $IMAGE_REFERENCE

Container port:
  $CONTAINER_PORT

Ingress:
  INTERNAL

Telemetry:
  OTLP/gRPC

Telemetry endpoint:
  http://${ALLOY_APP_NAME}:4317

Service name:
  $OTEL_SERVICE_NAME

Zero-code instrumentation:
  OpenTelemetry .NET AutoInstrumentation

Next:

  Use the traffic generator to call:

    curl http://${APP_NAME}/

    curl http://${APP_NAME}/work

    curl http://${APP_NAME}/call-external

    curl -i http://${APP_NAME}/error

EOF
