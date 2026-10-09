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
# El nombre del Storage Account es único GLOBALMENTE: "sritfstate" estaba
# tomado, se usa "sritfstate23c5" (sufijo del subscription id para unicidad).
RESOURCE_GROUP="${TF_STATE_RG:-sri-tfstate-rg}"
STORAGE_ACCOUNT="${TF_STATE_SA:-sritfstate23c5}"
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
# auth-mode key: obtiene la access key del Storage Account vía management plane
# (suficiente con rol Contributor); evita el error AuthorizationPermissionMismatch
# que da --auth-mode login cuando la identidad no tiene rol de data-plane
# (Storage Blob Data Contributor).
echo "[+] Creando/asegurando el container ${CONTAINER}..."
az storage container create \
  --name "${CONTAINER}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode key \
  --output none

# ----- 4. Resource Providers esenciales para AKS (idempotente) -----
# Terraform también los registra automáticamente en su primer plan; este
# paso los pre-registra con 4 llamadas (vs ~30 del auto-registro) para
# reducir la ventana de timeouts del ISP. az provider register es seguro
# de repetir: devuelve al instante si ya está registrado/registrándose.
for PROVIDER in Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.ManagedIdentity; do
  echo "[+] Registrando Resource Provider ${PROVIDER}..."
  az provider register --namespace "${PROVIDER}" --output none
done

echo
echo ">> Backend Azure listo. Ahora puedes ejecutar:"
echo "   cd iac/azure && terraform init && terraform plan"
echo
echo ">> Nota: si el Storage Account por defecto está tomado globalmente, exporta uno único:"
echo "   TF_STATE_SA=<nuevo-nombre> bash scripts/bootstrap-backend-azure.sh"
echo "   y actualiza storage_account_name en iac/azure/main.tf."
