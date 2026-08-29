#!/usr/bin/env bash

set -euo pipefail

#######################################
# Configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

ACR_NAME="${AZURE_ACR_NAME:-otelazureacr}"

IMAGE_NAME="${PYTHON_IMAGE_NAME:-otel-python}"

IMAGE_TAG="${PYTHON_IMAGE_TAG:-$(git rev-parse --short HEAD)}"

DOCKERFILE="${PYTHON_DOCKERFILE:-apps/otel-python/Dockerfile}"

BUILD_CONTEXT="${PYTHON_BUILD_CONTEXT:-apps/otel-python}"

TARGET_PLATFORM="${PYTHON_TARGET_PLATFORM:-linux/amd64}"

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
echo "  Name:   $ACR_NAME"
echo "  Server: $ACR_LOGIN_SERVER"

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
echo "  $IMAGE_REFERENCE"

#######################################
# Build
#######################################

log "Building Python image"

podman build \
    --platform "$TARGET_PLATFORM" \
    --file "$DOCKERFILE" \
    --tag "$IMAGE_REFERENCE" \
    "$BUILD_CONTEXT"

#######################################
# Verify image architecture
#######################################

log "Verifying image architecture"

IMAGE_PLATFORM="$(
    podman image inspect "$IMAGE_REFERENCE" \
        --format '{{.Os}}/{{.Architecture}}'
)"

echo "Image platform:"
echo "  $IMAGE_PLATFORM"

if [[ "$IMAGE_PLATFORM" != "$TARGET_PLATFORM" ]]; then
    fail "Python image platform mismatch. Expected: $TARGET_PLATFORM, Found: $IMAGE_PLATFORM"
fi

#######################################
# Push
#######################################

log "Pushing Python image"

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

log "Python build complete"

cat <<EOF

Image successfully published:

  $IMAGE_REFERENCE


============================================================
==> Export commands for deployment
============================================================

export AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export AZURE_RESOURCE_GROUP="$RESOURCE_GROUP"
export AZURE_ACR_NAME="$ACR_NAME"

export PYTHON_IMAGE_NAME="$IMAGE_NAME"
export PYTHON_IMAGE_TAG="$IMAGE_TAG"
export AZURE_PYTHON_IMAGE="$IMAGE_REFERENCE"


============================================================
==> Next step
============================================================

Run:

  ./infra/deploy-python.sh

EOF
