#!/usr/bin/env bash

set -euo pipefail

#######################################
# Configuration
#######################################

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"

LOCATION="${AZURE_LOCATION:-centralindia}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-otel-azure-ref-arch}"

VNET_NAME="${AZURE_VNET_NAME:-vnet-otel-azure-ref-arch}"

ACA_SUBNET_NAME="${ACA_SUBNET_NAME:-snet-aca}"
APPGW_SUBNET_NAME="${APPGW_SUBNET_NAME:-snet-appgw}"

ACA_ENV_NAME="${AZURE_ACA_ENV_NAME:-acae-otel-azure-ref-arch}"

VNET_CIDR="${VNET_CIDR:-10.20.0.0/16}"

# Dedicated ACA infrastructure subnet.
#
# /23 gives us plenty of room for future scaling and revisions.
ACA_SUBNET_CIDR="${ACA_SUBNET_CIDR:-10.20.0.0/23}"

# Dedicated subnet for Application Gateway.
APPGW_SUBNET_CIDR="${APPGW_SUBNET_CIDR:-10.20.2.0/24}"

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
# Azure CLI validation
#######################################

log "Validating Azure CLI authentication"

az account show \
    --query "{subscriptionId:id,subscriptionName:name,tenantId:tenantId}" \
    --output table

#######################################
# Select subscription
#######################################

log "Selecting Azure subscription"

az account set \
    --subscription "$SUBSCRIPTION_ID"

#######################################
# Resource Group
#######################################

log "Creating resource group"

az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

#######################################
# VNet
#######################################

log "Creating VNet"

if az network vnet show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --output none 2>/dev/null; then

    echo "VNet already exists: $VNET_NAME"

else

    az network vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VNET_NAME" \
        --location "$LOCATION" \
        --address-prefixes "$VNET_CIDR" \
        --output none

fi

#######################################
# ACA subnet
#######################################

log "Creating ACA infrastructure subnet"

if az network vnet subnet show \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$ACA_SUBNET_NAME" \
    --output none 2>/dev/null; then

    echo "ACA subnet already exists: $ACA_SUBNET_NAME"

else

    az network vnet subnet create \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$ACA_SUBNET_NAME" \
        --address-prefixes "$ACA_SUBNET_CIDR" \
        --delegations Microsoft.App/environments \
        --output none

fi

#######################################
# Ensure ACA subnet delegation
#######################################

log "Ensuring ACA subnet delegation"

az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$ACA_SUBNET_NAME" \
    --delegations Microsoft.App/environments \
    --output none

#######################################
# Verify ACA subnet delegation
#######################################

ACA_DELEGATION="$(
    az network vnet subnet show \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$ACA_SUBNET_NAME" \
        --query "delegations[].serviceName" \
        --output tsv
)"

if [[ "$ACA_DELEGATION" != "Microsoft.App/environments" ]]; then
    echo "ERROR: ACA subnet is not delegated to Microsoft.App/environments"
    exit 1
fi

echo "ACA subnet delegation: $ACA_DELEGATION"

#######################################
# Application Gateway subnet
#######################################

log "Creating Application Gateway subnet"

if az network vnet subnet show \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$APPGW_SUBNET_NAME" \
    --output none 2>/dev/null; then

    echo "Application Gateway subnet already exists: $APPGW_SUBNET_NAME"

else

    az network vnet subnet create \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$APPGW_SUBNET_NAME" \
        --address-prefixes "$APPGW_SUBNET_CIDR" \
        --output none

fi

#######################################
# Get ACA subnet resource ID
#######################################

log "Resolving ACA subnet resource ID"

ACA_SUBNET_ID="$(
    az network vnet subnet show \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$ACA_SUBNET_NAME" \
        --query id \
        --output tsv
)"

echo "ACA subnet:"
echo "$ACA_SUBNET_ID"

#######################################
# Container Apps Environment
#######################################

log "Creating Container Apps environment"

if az containerapp env show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACA_ENV_NAME" \
    --output none 2>/dev/null; then

    echo "Container Apps environment already exists: $ACA_ENV_NAME"

else

    az containerapp env create \
        --name "$ACA_ENV_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --infrastructure-subnet-resource-id "$ACA_SUBNET_ID" \
        --output none

fi

#######################################
# Verify Container Apps Environment
#######################################

log "Verifying Container Apps environment"

az containerapp env show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACA_ENV_NAME" \
    --query '{
        name:name,
        location:location,
        provisioningState:properties.provisioningState,
        defaultDomain:properties.defaultDomain
    }' \
    --output yaml

#######################################
# Final network summary
#######################################

log "Network summary"

az network vnet subnet list \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --query "[].{
        name:name,
        addressPrefix:addressPrefix,
        delegations:delegations[].serviceName
    }" \
    --output table

#######################################
# Final output
#######################################

log "Foundation deployment complete"

cat <<EOF

Resource Group:
  $RESOURCE_GROUP

Location:
  $LOCATION

VNet:
  $VNET_NAME
  $VNET_CIDR

ACA Environment:
  $ACA_ENV_NAME

ACA Subnet:
  $ACA_SUBNET_NAME
  $ACA_SUBNET_CIDR
  Delegation: Microsoft.App/environments

Application Gateway Subnet:
  $APPGW_SUBNET_NAME
  $APPGW_SUBNET_CIDR

EOF

