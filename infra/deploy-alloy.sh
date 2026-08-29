#!/usr/bin/env bash

set -euo pipefail

#######################################
# Required configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

ACA_ENV_NAME="${AZURE_ACA_ENV_NAME:-acae-otel-azure-ref-arch}"

ALLOY_APP_NAME="${AZURE_ALLOY_APP_NAME:-otel-alloy}"

#######################################
# Azure Container Registry
#######################################

ACR_NAME="${AZURE_ACR_NAME:?AZURE_ACR_NAME is required}"

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"

ALLOY_IMAGE_REPOSITORY="${AZURE_ALLOY_IMAGE_REPOSITORY:-otel-alloy}"

ALLOY_IMAGE_TAG="${AZURE_ALLOY_IMAGE_TAG:-latest}"

ALLOY_IMAGE="${AZURE_ALLOY_IMAGE:-${ACR_LOGIN_SERVER}/${ALLOY_IMAGE_REPOSITORY}:${ALLOY_IMAGE_TAG}}"

#######################################
# User Assigned Managed Identity
#######################################

ALLOY_ACR_IDENTITY_NAME="${AZURE_ALLOY_ACR_IDENTITY_NAME:-id-otel-acr-pull}"

#######################################
# OTLP ports
#######################################

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
# Verify resource group
#######################################

log "Verifying resource group"

if ! az group show \
    --name "$RESOURCE_GROUP" \
    --output none 2>/dev/null; then

    echo "ERROR: Resource group does not exist:"
    echo "$RESOURCE_GROUP"
    exit 1
fi

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
# Verify ACR
#######################################

log "Verifying Azure Container Registry"

ACR_RESOURCE_ID="$(
    az acr show \
        --name "$ACR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "id" \
        --output tsv
)"

if [[ -z "$ACR_RESOURCE_ID" ]]; then
    echo "ERROR: Azure Container Registry not found:"
    echo "$ACR_NAME"
    exit 1
fi

echo "ACR:"
echo "  Name:   $ACR_NAME"
echo "  Server: $ACR_LOGIN_SERVER"

#######################################
# Verify ACR ARM token authentication
#######################################

log "Checking ACR ARM token authentication"

ACR_ARM_AUTH="$(
    az acr config authentication-as-arm show \
        --registry "$ACR_NAME" \
        --query "status" \
        --output tsv
)"

if [[ "$ACR_ARM_AUTH" != "enabled" ]]; then

    echo "ACR ARM audience token authentication is not enabled."
    echo "Enabling it..."

    az acr config authentication-as-arm update \
        --registry "$ACR_NAME" \
        --status enabled \
        --output none
fi

echo "ACR ARM token authentication: enabled"

#######################################
# Verify Alloy image exists
#######################################

log "Verifying Alloy image"

if ! az acr repository show \
    --name "$ACR_NAME" \
    --image "${ALLOY_IMAGE_REPOSITORY}:${ALLOY_IMAGE_TAG}" \
    --output none 2>/dev/null; then

    echo "ERROR: Alloy image does not exist in ACR:"
    echo "$ALLOY_IMAGE"
    echo
    echo "Build/push the image before running this deployment."
    exit 1
fi

echo "Alloy image:"
echo "  $ALLOY_IMAGE"

#######################################
# User Assigned Managed Identity
#######################################

log "Ensuring Alloy ACR managed identity exists"

IDENTITY_EXISTS=false

if az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_ACR_IDENTITY_NAME" \
    --output none 2>/dev/null; then

    IDENTITY_EXISTS=true

    echo "Managed identity already exists:"
    echo "  $ALLOY_ACR_IDENTITY_NAME"

else

    echo "Creating managed identity:"
    echo "  $ALLOY_ACR_IDENTITY_NAME"

    az identity create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --output none
fi

#######################################
# Identity details
#######################################

log "Reading managed identity details"

ALLOY_ACR_IDENTITY_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --query "id" \
        --output tsv
)"

ALLOY_ACR_IDENTITY_CLIENT_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --query "clientId" \
        --output tsv
)"

ALLOY_ACR_IDENTITY_PRINCIPAL_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --query "principalId" \
        --output tsv
)"

echo "Managed identity:"
echo "  Name:         $ALLOY_ACR_IDENTITY_NAME"
echo "  Resource ID:  $ALLOY_ACR_IDENTITY_ID"
echo "  Client ID:    $ALLOY_ACR_IDENTITY_CLIENT_ID"
echo "  Principal ID:  $ALLOY_ACR_IDENTITY_PRINCIPAL_ID"

#######################################
# Assign AcrPull
#######################################

log "Ensuring AcrPull role assignment"

ACR_PULL_ROLE_ID="7f951dda-4ed3-4680-a7ca-43fe172d538d"

EXISTING_ROLE_ASSIGNMENT="$(
    az role assignment list \
        --assignee-object-id "$ALLOY_ACR_IDENTITY_PRINCIPAL_ID" \
        --scope "$ACR_RESOURCE_ID" \
        --role "$ACR_PULL_ROLE_ID" \
        --query "[0].id" \
        --output tsv
)"

if [[ -z "$EXISTING_ROLE_ASSIGNMENT" ]]; then

    echo "Creating AcrPull role assignment..."

    az role assignment create \
        --assignee-object-id "$ALLOY_ACR_IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$ACR_PULL_ROLE_ID" \
        --scope "$ACR_RESOURCE_ID" \
        --output none

    echo "AcrPull assigned."

else

    echo "AcrPull already assigned."

fi

#######################################
# Encode Alloy configuration
#######################################

log "Encoding Alloy configuration"

ALLOY_CONFIG_BASE64="$(
    base64 < "$ALLOY_CONFIG_FILE" | tr -d '\n'
)"

echo "Alloy configuration encoded."

#######################################
# Deploy / update Alloy
#######################################

if az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output none 2>/dev/null; then

    ###################################
    # Existing Container App
    ###################################

    log "Updating existing Alloy Container App"

    az containerapp identity assign \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --user-assigned "$ALLOY_ACR_IDENTITY_ID" \
        --output none

    az containerapp secret set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --secrets \
            grafana-instance-id="$GRAFANA_CLOUD_INSTANCE_ID" \
            grafana-api-key="$GRAFANA_CLOUD_API_KEY" \
        --output none

    az containerapp registry set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --server "$ACR_LOGIN_SERVER" \
        --identity "$ALLOY_ACR_IDENTITY_ID" \
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

    ###################################
    # New Container App
    ###################################

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
        --user-assigned "$ALLOY_ACR_IDENTITY_ID" \
        --registry-identity "$ALLOY_ACR_IDENTITY_ID" \
        --registry-server "$ACR_LOGIN_SERVER" \
        --secrets \
            grafana-instance-id="$GRAFANA_CLOUD_INSTANCE_ID" \
            grafana-api-key="$GRAFANA_CLOUD_API_KEY" \
        --env-vars \
            GRAFANA_CLOUD_INSTANCE_ID=secretref:grafana-instance-id \
            GRAFANA_CLOUD_API_KEY=secretref:grafana-api-key \
            GRAFANA_CLOUD_OTLP_ENDPOINT="$GRAFANA_CLOUD_OTLP_ENDPOINT" \
        --ingress internal \
        --target-port "$ALLOY_OTLP_HTTP_PORT" \
        --transport http \
        --allow-insecure true \
        --output none

fi

#######################################
# Explicitly configure registry
#######################################

log "Configuring ACR managed identity"

az containerapp registry set \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --server "$ACR_LOGIN_SERVER" \
    --identity "$ALLOY_ACR_IDENTITY_ID" \
    --output none

#######################################
# Verify Container App identity
#######################################

log "Checking Container App identity"

az containerapp identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output yaml

#######################################
# Verify registry configuration
#######################################

log "Checking registry configuration"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --query 'properties.configuration.registries' \
    --output yaml

#######################################
# Verify deployment
#######################################

log "Checking Alloy Container App"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
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

log "Checking Alloy revisions"

az containerapp revision list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --query "[].{
        name:name,
        active:properties.active,
        health:properties.healthState,
        provisioning:properties.provisioningState,
        image:properties.template.containers[0].image
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

ACR:
  $ACR_LOGIN_SERVER

Alloy Image:
  $ALLOY_IMAGE

ACR Pull Identity:
  $ALLOY_ACR_IDENTITY_NAME

Identity Client ID:
  $ALLOY_ACR_IDENTITY_CLIENT_ID

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
