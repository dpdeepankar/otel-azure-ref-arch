#!/usr/bin/env bash

set -euo pipefail

#######################################
# Configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

AZURE_LOCATION="${AZURE_LOCATION:-centralindia}"

ACA_ENV_NAME="${AZURE_ACA_ENV_NAME:-acae-otel-azure-ref-arch}"

ACR_NAME="${AZURE_ACR_NAME:-otelazureacr}"

ACR_IDENTITY_NAME="${AZURE_ACR_IDENTITY_NAME:-id-otel-acr-pull}"

APP_NAME="${PYTHON_APP_NAME:-otel-python}"

IMAGE_NAME="${PYTHON_IMAGE_NAME:-otel-python}"

IMAGE_TAG="${PYTHON_IMAGE_TAG:-$(git rev-parse --short HEAD)}"

CONTAINER_PORT="${PYTHON_CONTAINER_PORT:-8000}"

ALLOY_APP_NAME="${AZURE_ALLOY_APP_NAME:-otel-alloy}"

OTEL_SERVICE_NAME="${PYTHON_OTEL_SERVICE_NAME:-zero-code-python-demo}"

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
# Validate prerequisites
#######################################

log "Validating prerequisites"

command -v az >/dev/null 2>&1 || \
    fail "Azure CLI (az) is required."

command -v git >/dev/null 2>&1 || \
    fail "Git is required."

#######################################
# Azure subscription
#######################################

log "Selecting Azure subscription"

az account set \
    --subscription "$SUBSCRIPTION_ID"

#######################################
# Verify resource group
#######################################

log "Verifying resource group"

az group show \
    --name "$RESOURCE_GROUP" \
    --output none

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
# Verify ACR
#######################################

log "Verifying Azure Container Registry"

ACR_LOGIN_SERVER="$(
    az acr show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --query loginServer \
        --output tsv
)"

[[ -n "$ACR_LOGIN_SERVER" ]] || \
    fail "Could not resolve ACR login server."

ACR_ID="$(
    az acr show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --query id \
        --output tsv
)"

echo "ACR:"
echo "  Name:        $ACR_NAME"
echo "  Login server: $ACR_LOGIN_SERVER"

#######################################
# Verify Alloy
#######################################

log "Verifying Alloy Container App"

if ! az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output none 2>/dev/null; then

    fail "Alloy Container App '$ALLOY_APP_NAME' was not found. Deploy Alloy before deploying Python."

fi

echo "Alloy Container App found: $ALLOY_APP_NAME"

#######################################
# Ensure ACR pull managed identity
#######################################

log "Ensuring ACR pull managed identity"

if az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_IDENTITY_NAME" \
    --output none 2>/dev/null; then

    echo "Managed identity already exists:"
    echo "  $ACR_IDENTITY_NAME"

else

    echo "Creating managed identity:"
    echo "  $ACR_IDENTITY_NAME"

    az identity create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --location "$AZURE_LOCATION" \
        --output none

fi

#######################################
# Resolve managed identity
#######################################

IDENTITY_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --query id \
        --output tsv
)"

IDENTITY_PRINCIPAL_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_IDENTITY_NAME" \
        --query principalId \
        --output tsv
)"

[[ -n "$IDENTITY_ID" ]] || \
    fail "Could not resolve managed identity resource ID."

[[ -n "$IDENTITY_PRINCIPAL_ID" ]] || \
    fail "Could not resolve managed identity principal ID."

echo "Managed identity:"
echo "  Name:        $ACR_IDENTITY_NAME"
echo "  Resource ID: $IDENTITY_ID"
echo "  Principal ID: $IDENTITY_PRINCIPAL_ID"

#######################################
# Ensure AcrPull role assignment
#######################################

log "Ensuring AcrPull role assignment"

ACR_PULL_ASSIGNMENT_COUNT="$(
    az role assignment list \
        --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
        --scope "$ACR_ID" \
        --query "[?roleDefinitionName=='AcrPull'] | length(@)" \
        --output tsv
)"

if [[ "$ACR_PULL_ASSIGNMENT_COUNT" == "0" ]]; then

    echo "Assigning AcrPull to managed identity"

    az role assignment create \
        --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role AcrPull \
        --scope "$ACR_ID" \
        --output none

    echo "AcrPull assignment created."

else

    echo "AcrPull assignment already exists."

fi

#######################################
# Verify Python image
#######################################

IMAGE_REFERENCE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

log "Verifying Python image"

echo "Image:"
echo "  $IMAGE_REFERENCE"

az acr repository show \
    --name "$ACR_NAME" \
    --image "${IMAGE_NAME}:${IMAGE_TAG}" \
    --output table

#######################################
# Deploy Python Container App
#######################################

if az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --output none 2>/dev/null; then

    ###################################
    # Update existing application
    ###################################

    log "Updating existing Python Container App"

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
    # Create new application
    ###################################

    log "Creating Python Container App"

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
        --user-assigned "$IDENTITY_ID" \
        --registry-server "$ACR_LOGIN_SERVER" \
        --registry-identity "$IDENTITY_ID" \
        --output none

fi

#######################################
# Verify deployment
#######################################

log "Verifying Python Container App"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APP_NAME" \
    --query '{
        name:name,
        provisioningState:properties.provisioningState,
        runningStatus:properties.runningStatus,
        fqdn:properties.configuration.ingress.fqdn,
        image:properties.template.containers[0].image
    }' \
    --output yaml

#######################################
# Revision status
#######################################

log "Checking Python revisions"

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

log "Python deployment complete"

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

ACR:
  $ACR_LOGIN_SERVER

ACR pull identity:
  $ACR_IDENTITY_NAME

EOF
