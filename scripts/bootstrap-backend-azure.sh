#!/usr/bin/env bash
# ============================================================
# Bootstrap del backend remoto de Terraform en Azure
# Crea el Resource Group, Storage Account y Container
# que referencia iac/azure/main.tf.
#
# Uso (tras 'az login' o con Service Principal exportado):
#   bash scripts/bootstrap-backend-azure.sh
#
# Idempotente: si el recurso ya existe, no falla.
# ============================================================
set -euo pipefail

# ----- Valores alineados con iac/azure/main.tf (backend "azurerm") -----
RESOURCE_GROUP="${TF_STATE_RG:-sri-tfstate-rg}"
STORAGE_ACCOUNT="${TF_STATE_SA:-sritfstate}"
CONTAINER="${TF_STATE_CONTAINER:-tfstate}"
LOCATION="${AZURE_LOCATION:-eastus}"

echo ">> Resource Group:  ${RESOURCE_GROUP}"
echo ">> Storage Account: ${STORAGE_ACCOUNT}"
echo ">> Container:       ${CONTAINER}"
echo ">> Location:        ${LOCATION}"
echo

# ----- 1. Resource Group -----
echo "[+] Creando/asegurando Resource Group..."
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

# ----- 2. Storage Account (el nombre debe ser único global, 3-24 minúsculas) -----
if az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
  echo "[=] El Storage Account ${STORAGE_ACCOUNT} ya existe."
else
  echo "[+] Creando Storage Account ${STORAGE_ACCOUNT}..."
  az storage account create \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --encryption-services blob \
    --min-tls-version TLS1_2 \
    --output none
fi

# ----- 3. Container para el estado -----
echo "[+] Creando/asegurando el container ${CONTAINER}..."
az storage container create \
  --name "${CONTAINER}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode login \
  --output none

echo
echo ">> Backend Azure listo. Ahora puedes ejecutar:"
echo "   cd iac/azure && terraform init && terraform plan"
echo
echo ">> Nota: si 'sritfstate' ya está tomado globalmente, exporta uno único:"
echo "   TF_STATE_SA=sritfstate\$RANDOM bash scripts/bootstrap-backend-azure.sh"
echo "   y actualiza storage_account_name en iac/azure/main.tf."
