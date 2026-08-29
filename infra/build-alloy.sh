#!/usr/bin/env bash

set -euo pipefail

#######################################
# Configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

ACR_NAME="${AZURE_ACR_NAME:-otelazureacr}"

IMAGE_NAME="${ALLOY_IMAGE_NAME:-otel-alloy}"

IMAGE_TAG="${ALLOY_IMAGE_TAG:-$(git rev-parse --short HEAD)}"

DOCKERFILE="${ALLOY_DOCKERFILE:-otel-alloy/Dockerfile}"

BUILD_CONTEXT="${ALLOY_BUILD_CONTEXT:-otel-alloy}"

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

command -v podman >/dev/null 2>&1 || \
    fail "Podman is required."

command -v git >/dev/null 2>&1 || \
    fail "Git is required."

[[ -f "$DOCKERFILE" ]] || \
    fail "Dockerfile not found: $DOCKERFILE"

[[ -f "$BUILD_CONTEXT/config.alloy" ]] || \
    fail "Alloy config not found: $BUILD_CONTEXT/config.alloy"

#######################################
# Azure subscription
#######################################

log "Selecting Azure subscription"

az account set \
    --subscription "$SUBSCRIPTION_ID"

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

echo "ACR:"
echo "$ACR_LOGIN_SERVER"

#######################################
# Login to ACR
#######################################

log "Logging into Azure Container Registry"

az acr login \
    --name "$ACR_NAME"

#######################################
# Image reference
#######################################

IMAGE_REFERENCE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "Image:"
echo "$IMAGE_REFERENCE"

#######################################
# Build
#######################################

log "Building Alloy image"

podman build \
    --file "$DOCKERFILE" \
    --tag "$IMAGE_REFERENCE" \
    "$BUILD_CONTEXT"

#######################################
# Push
#######################################

log "Pushing Alloy image"

podman push "$IMAGE_REFERENCE"

#######################################
# Verify image in ACR
#######################################

log "Verifying image in ACR"

az acr repository show \
    --name "$ACR_NAME" \
    --image "${IMAGE_NAME}:${IMAGE_TAG}" \
    --output table

#######################################
# Complete
#######################################

log "Alloy build complete"

cat <<EOF

Image successfully published:

  $IMAGE_REFERENCE

Next step:

  ./infra/deploy-alloy.sh

EOF

