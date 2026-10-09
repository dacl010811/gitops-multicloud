#!/usr/bin/env bash
# ============================================================
# Bootstrap humano único del Key Vault (plataforma de secretos Azure)
#   1. Rol "Key Vault Secrets User"   -> Managed Identity del workload
#   2. Rol "Key Vault Secrets Officer"-> identidad HUMANA firmada
#   3. Siembra idempotente de los 3 secretos demo (solo si NO existen)
#   4. Verificación final (sin exponer valores)
#
# Espejo del patrón bootstrap-acr-rbac-azure.sh: el RBAC es "bootstrap
# privilegiado humano" (el SP terraform-ci es Contributor: NO puede crear
# role assignments ni escribir secretos — least privilege por diseño).
# Matiz de Key Vault RBAC: ni Owner escribe secretos sin rol data-plane.
#
# Uso (requiere 'az login' HUMANO con Owner):
#   bash scripts/bootstrap-keyvault-rbac-azure.sh
# Idempotente: re-ejecutar no duplica roles ni sobrescribe secretos.
# ============================================================
set -euo pipefail

KV_NAME="${KV_NAME:-sri-keyvault-23c5}"
IDENTITY_NAME="${IDENTITY_NAME:-sri-facturacion-wi}"
RG="${PLATFORM_RG:-sri-tfstate-rg}"
DEMO_DB_USER="${DEMO_DB_USER:-sri_demo_user}"
DEMO_DB_HOST="${DEMO_DB_HOST:-sri-facturacion-demo.postgres.database.azure.com}"

echo ">> Key Vault: ${KV_NAME} (RG ${RG})"
echo ">> Identidad: ${IDENTITY_NAME}"
echo

# ----- Guards -----
command -v az >/dev/null || { echo "FALTA az CLI"; exit 1; }
if ! az ad signed-in-user show >/dev/null 2>&1; then
  echo "ERROR: esta sesión NO es una identidad humana (az ad signed-in-user falló)."
  echo "  El RBAC exige Owner humano: az login y re-ejecutar."
  exit 1
fi

KV_ID=$(az keyvault show --name "${KV_NAME}" --query id -o tsv)
MI_PRINCIPAL=$(az identity show -g "${RG}" -n "${IDENTITY_NAME}" --query principalId -o tsv)
MI_CLIENT_ID=$(az identity show -g "${RG}" -n "${IDENTITY_NAME}" --query clientId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
echo ">> KV id:    ${KV_ID}"
echo ">> MI (principal): ${MI_PRINCIPAL}"
echo ">> MI (clientId — va al overlay): ${MI_CLIENT_ID}"
echo

# ----- Helper idempotente de roles -----
role_exists() { # $1 object_id  $2 rol  $3 scope
  [ -n "$(az role assignment list --assignee-object-id "$1" --role "$2" --scope "$3" --query '[].id' -o tsv)" ]
}

ensure_role() { # $1 object_id  $2 principal-type  $3 rol  $4 scope
  if role_exists "$1" "$3" "$4"; then
    echo "[=] Rol '$3' ya asignado."
  else
    echo "[+] Asignando rol '$3'..."
    az role assignment create --role "$3" \
      --assignee-object-id "$1" --assignee-principal-type "$2" \
      --scope "$4" --output none
    echo "[+] Rol '$3' asignado."
  fi
}

# 1) La identidad del WORKLOAD lee secretos (la usa el pod via CSI)
ensure_role "${MI_PRINCIPAL}" ServicePrincipal "Key Vault Secrets User" "${KV_ID}"

# 2) El HUMANO puede escribir secretos (siembra una sola vez)
ensure_role "${ME}" User "Key Vault Secrets Officer" "${KV_ID}"

# ----- Siembra idempotente (nunca sobrescribe) -----
ensure_secret() { # $1 nombre  $2 valor
  if az keyvault secret show --vault-name "${KV_NAME}" --name "$1" >/dev/null 2>&1; then
    echo "[=] Secreto '$1' ya existe (no se sobrescribe)."
  else
    echo "[+] Sembrando secreto '$1'..."
    # Retry: la propagación del rol Officer puede tardar 1-2 min
    for i in 1 2 3 4 5 6; do
      if az keyvault secret set --vault-name "${KV_NAME}" --name "$1" --value "$2" >/dev/null 2>&1; then
        echo "[+] Secreto '$1' sembrado."
        return 0
      fi
      echo "    propagando RBAC (intento ${i}/6, 10s)..."
      sleep 10
    done
    echo "ERROR: no se pudo escribir '$1' (¿rol Officer propagado?)"; return 1
  fi
}

DB_PASSWORD=$(openssl rand -base64 18)
ensure_secret db-username "${DEMO_DB_USER}"
ensure_secret db-password "${DB_PASSWORD}"
ensure_secret db-host     "${DEMO_DB_HOST}"

# ----- Verificación final (nombres, no valores) -----
echo
az keyvault secret list --vault-name "${KV_NAME}" --query '[].name' -o table
echo
echo ">> Listo para la FASE 5. El clientId para el overlay ya se imprimió arriba"
echo "   (o: terraform -chdir=iac/azure/key-vault output -raw identity_client_id)."
