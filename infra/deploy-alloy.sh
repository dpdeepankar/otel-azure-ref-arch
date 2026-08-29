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
# Managed Identity
#######################################

ALLOY_ACR_IDENTITY_NAME="${AZURE_ALLOY_ACR_IDENTITY_NAME:-id-otel-acr-pull}"

#######################################
# Alloy ports
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

command -v git >/dev/null 2>&1 || \
    fail "Git is required."

#######################################
# Verify containerapp extension
#######################################

log "Checking Azure Container Apps CLI extension"

if ! az extension show \
    --name containerapp \
    --output none 2>/dev/null; then

    echo "Container Apps extension not found. Installing..."

    az extension add \
        --name containerapp \
        --upgrade \
        --output none

else

    echo "Container Apps extension found."

    az extension update \
        --name containerapp \
        --output none
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

echo "ACA environment:"
echo "  $ACA_ENV_NAME"

#######################################
# Verify ACR
#######################################

log "Verifying Azure Container Registry"

ACR_RESOURCE_ID="$(
    az acr show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --query "id" \
        --output tsv
)"

[[ -n "$ACR_RESOURCE_ID" ]] || \
    fail "Could not resolve ACR resource ID."

echo "ACR:"
echo "  Name:   $ACR_NAME"
echo "  Server: $ACR_LOGIN_SERVER"

#######################################
# Verify ACR ARM authentication
#######################################

log "Checking ACR ARM token authentication"

ACR_ARM_AUTH="$(
    az acr config authentication-as-arm show \
        --registry "$ACR_NAME" \
        --query "status" \
        --output tsv
)"

if [[ "$ACR_ARM_AUTH" != "enabled" ]]; then

    echo "ACR ARM authentication is not enabled."
    echo "Enabling..."

    az acr config authentication-as-arm update \
        --registry "$ACR_NAME" \
        --status enabled \
        --output none
fi

echo "ACR ARM authentication: enabled"

#######################################
# Verify Alloy image
#######################################

log "Verifying Alloy image"

az acr repository show \
    --name "$ACR_NAME" \
    --image "${ALLOY_IMAGE_REPOSITORY}:${ALLOY_IMAGE_TAG}" \
    --output table

echo
echo "Image:"
echo "  $ALLOY_IMAGE"

#######################################
# Managed Identity
#######################################

log "Ensuring ACR pull managed identity"

if ! az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_ACR_IDENTITY_NAME" \
    --output none 2>/dev/null; then

    echo "Creating managed identity:"
    echo "  $ALLOY_ACR_IDENTITY_NAME"

    az identity create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --output none
else
    echo "Managed identity already exists."
fi

#######################################
# Identity details
#######################################

ALLOY_ACR_IDENTITY_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --query "id" \
        --output tsv
)"

ALLOY_ACR_IDENTITY_PRINCIPAL_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --query "principalId" \
        --output tsv
)"

ALLOY_ACR_IDENTITY_CLIENT_ID="$(
    az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_ACR_IDENTITY_NAME" \
        --query "clientId" \
        --output tsv
)"

#######################################
# AcrPull
#######################################

log "Ensuring AcrPull role assignment"

ACR_PULL_ROLE_ID="7f951dda-4ed3-4680-a7ca-43fe172d538d"

EXISTING_ROLE="$(
    az role assignment list \
        --assignee-object-id "$ALLOY_ACR_IDENTITY_PRINCIPAL_ID" \
        --scope "$ACR_RESOURCE_ID" \
        --role "$ACR_PULL_ROLE_ID" \
        --query "[0].id" \
        --output tsv
)"

if [[ -z "$EXISTING_ROLE" ]]; then

    echo "Creating AcrPull assignment..."

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
# Create / update Alloy
#######################################

if az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output none 2>/dev/null; then

    ###################################
    # Existing app
    ###################################

    log "Updating existing Alloy Container App"

    ###################################
    # Ensure managed identity attached
    ###################################

    az containerapp identity assign \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --user-assigned "$ALLOY_ACR_IDENTITY_ID" \
        --output none

    ###################################
    # Update secrets
    ###################################

    az containerapp secret set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --secrets \
            grafana-instance-id="$GRAFANA_CLOUD_INSTANCE_ID" \
            grafana-api-key="$GRAFANA_CLOUD_API_KEY" \
        --output none

    ###################################
    # Configure ACR registry
    ###################################

    az containerapp registry set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALLOY_APP_NAME" \
        --server "$ACR_LOGIN_SERVER" \
        --identity "$ALLOY_ACR_IDENTITY_ID" \
        --output none

    ###################################
    # Update image/env
    ###################################

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
    # New app
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
        --registry-server "$ACR_LOGIN_SERVER" \
        --registry-identity "$ALLOY_ACR_IDENTITY_ID" \
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
# Add OTLP gRPC additional TCP port
#######################################

log "Configuring OTLP gRPC additional TCP port"

ALLOY_YAML="$(mktemp)"

trap 'rm -f "$ALLOY_YAML"' EXIT

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output yaml > "$ALLOY_YAML"

python3 - "$ALLOY_YAML" "$ALLOY_OTLP_GRPC_PORT" <<'PY'
import sys
import yaml

path = sys.argv[1]
grpc_port = int(sys.argv[2])

with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)

ingress = (
    data
    .setdefault("properties", {})
    .setdefault("configuration", {})
    .setdefault("ingress", {})
)

existing = ingress.get("additionalPortMappings") or []

# Remove any existing mapping for this target port.
existing = [
    mapping
    for mapping in existing
    if mapping.get("targetPort") != grpc_port
]

existing.append({
    "exposedPort": grpc_port,
    "external": False,
    "targetPort": grpc_port,
})

ingress["additionalPortMappings"] = existing

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY

az containerapp update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --yaml "$ALLOY_YAML" \
    --output none

#######################################
# Verify ingress
#######################################

log "Verifying Alloy ingress"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --query 'properties.configuration.ingress' \
    --output yaml

#######################################
# Verify managed identity
#######################################

log "Verifying managed identity"

az containerapp identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --output yaml

#######################################
# Verify registry
#######################################

log "Verifying registry configuration"

az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ALLOY_APP_NAME" \
    --query 'properties.configuration.registries' \
    --output yaml

#######################################
# Verify app
#######################################

log "Verifying Alloy Container App"

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
# Revisions
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
# Final
#######################################

log "Alloy deployment complete"

cat <<EOF

Alloy Container App:
  $ALLOY_APP_NAME

ACA Environment:
  $ACA_ENV_NAME

Image:
  $ALLOY_IMAGE

ACR:
  $ACR_LOGIN_SERVER

ACR Pull Identity:
  $ALLOY_ACR_IDENTITY_NAME

OTLP gRPC:
  $ALLOY_OTLP_GRPC_PORT
  Internal TCP

OTLP HTTP:
  $ALLOY_OTLP_HTTP_PORT
  Internal HTTP

Grafana OTLP endpoint:
  $GRAFANA_CLOUD_OTLP_ENDPOINT

Ingress:
  INTERNAL

Credentials:
  Stored as ACA secrets

Next verification:

  python -c "
  import socket
  s = socket.create_connection(('${ALLOY_APP_NAME}', ${ALLOY_OTLP_GRPC_PORT}), timeout=5)
  print('Alloy OTLP gRPC: CONNECTED')
  s.close()
  "

EOF

