#!/usr/bin/env bash
# ============================================================
# Bootstrap: RBAC del Azure Container Registry
#
# Crea (idempotente) los role assignments de data-plane que el
# rol Contributor NO cubre (management != data plane, misma
# leccion que --auth-mode key en el Storage Account):
#   1. AcrPush -> SP terraform-ci-azure (pipeline + docker push)
#   2. AcrPull -> kubelet identity del AKS (pull de los pods)
#
# Por que existe: el pipeline .github/workflows/ci-cd.yaml hace
# push a ACR y el cluster hace pull. Es identidad de PLATAFORMA:
# se asigna una vez y vive junto al ACR (iac/azure/registry/),
# fuera del ciclo destroy del cluster.
#
# IMPORTANTE:
#   - Ejecutar con la cuenta HUMANA (Owner de la suscripcion).
#     El SP no puede asignarse roles a si mismo (evita privilege
#     escalation). Si la sesion activa es el SP, el script aborta.
#   - Si el cluster AKS no existe (ciclo FinOps destroy/apply),
#     la seccion 3 se omite con aviso: re-ejecutar tras recrearlo.
#   - La propagacion de RBAC puede tardar 1-2 minutos tras crear.
# ============================================================
set -euo pipefail

# ----- Valores alineados con iac/azure/registry y iac/azure -----
ACR_NAME="${ACR_NAME:-sriacrtfm23c5}"
ACR_RG="${ACR_RG:-sri-tfstate-rg}"
PIPELINE_SP_APP_ID="${AZURE_PIPELINE_SP_APP_ID:-f50eded8-ffef-4864-8e08-b62ab0ed18bf}"
AKS_RG="${AKS_RG:-sri-aks-rg}"
AKS_NAME="${AKS_NAME:-sri-aks-cluster}"

echo "==> Verificando identidad (debe ser cuenta humana con Owner/UAA)..."
USER_TYPE=$(az account show --query user.type --output tsv)
USER_NAME=$(az account show --query user.name --output tsv)
echo "    Sesion actual: ${USER_NAME} (${USER_TYPE})"
if [[ "${USER_TYPE}" == "servicePrincipal" ]]; then
  echo "ERROR: sesion activa = service principal ${USER_NAME}."
  echo "       Asignar roles exige Owner/User Access Administrator."
  echo "       Ejecuta 'az login' con tu cuenta humana y reintenta."
  echo "       Luego vuelve al SP para el flujo automatizado."
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id --output tsv)
ACR_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ACR_RG}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}"

echo ">> ACR:            ${ACR_NAME}"
echo ">> Scope:          ${ACR_SCOPE}"
echo ">> SP del pipeline: ${PIPELINE_SP_APP_ID}"
echo ">> Cluster AKS:    ${AKS_NAME} (RG ${AKS_RG})"
echo

# ------------------------------------------------------------
# 1. Verificar que el ACR existe (lo gestiona Terraform, no este script)
# ------------------------------------------------------------
echo "[+] Verificando existencia del ACR ${ACR_NAME}..."
if ! az acr show --name "${ACR_NAME}" --resource-group "${ACR_RG}" >/dev/null 2>&1; then
  echo "ERROR: el ACR ${ACR_NAME} no existe en ${ACR_RG}."
  echo "       Crearlo primero con: cd iac/azure/registry && terraform apply"
  exit 1
fi
echo "    OK."

# ------------------------------------------------------------
# 2. AcrPush al SP del pipeline (push de imagenes)
# ------------------------------------------------------------
echo "[+] Asignando AcrPush al SP ${PIPELINE_SP_APP_ID}..."
if az role assignment list \
     --assignee "${PIPELINE_SP_APP_ID}" \
     --role "AcrPush" \
     --scope "${ACR_SCOPE}" \
     --query "[0].id" --output tsv | grep -q .; then
  echo "[=] AcrPush ya asignado al SP. OK."
else
  az role assignment create \
    --assignee "${PIPELINE_SP_APP_ID}" \
    --role "AcrPush" \
    --scope "${ACR_SCOPE}" \
    --output none
  echo "    Creado."
fi

# ------------------------------------------------------------
# 3. AcrPull a la kubelet identity del AKS (pull de los pods)
# ------------------------------------------------------------
if az aks show --resource-group "${AKS_RG}" --name "${AKS_NAME}" >/dev/null 2>&1; then
  echo "[+] Asignando AcrPull a la kubelet identity de ${AKS_NAME}..."
  KUBELET_CLIENT_ID=$(az aks show \
    --resource-group "${AKS_RG}" \
    --name "${AKS_NAME}" \
    --query "identityProfile.kubeletidentity.clientId" \
    --output tsv)
  if az role assignment list \
       --assignee "${KUBELET_CLIENT_ID}" \
       --role "AcrPull" \
       --scope "${ACR_SCOPE}" \
       --query "[0].id" --output tsv | grep -q .; then
    echo "[=] AcrPull ya asignado a la kubelet identity. OK."
  else
    az role assignment create \
      --assignee "${KUBELET_CLIENT_ID}" \
      --role "AcrPull" \
      --scope "${ACR_SCOPE}" \
      --output none
    echo "    Creado."
  fi
else
  echo "[!] Cluster ${AKS_NAME} no existe (RG ${AKS_RG})."
  echo "    Se omite el AcrPull. Tras recrearlo con Terraform:"
  echo "    re-ejecuta este script (es idempotente)."
fi

# ------------------------------------------------------------
# 4. Resumen y siguientes pasos
# ------------------------------------------------------------
echo
echo "============================================================"
echo "RBAC DEL ACR LISTO"
echo "  ACR      : ${ACR_NAME} (${ACR_NAME}.azurecr.io)"
echo "  AcrPush  : SP ${PIPELINE_SP_APP_ID}"
echo "  AcrPull  : kubelet identity de ${AKS_NAME} (si existia)"
echo "------------------------------------------------------------"
echo "Siguientes pasos (ya con el SP en la sesion):"
echo "  az acr login --name ${ACR_NAME}"
echo "  docker tag <imagen> ${ACR_NAME}.azurecr.io/sri-facturacion:v1"
echo "  docker push ${ACR_NAME}.azurecr.io/sri-facturacion:v1"
echo "Nota: la propagacion RBAC puede tardar 1-2 minutos."
echo "Costo: los role assignments son gratuitos."
echo "============================================================"
