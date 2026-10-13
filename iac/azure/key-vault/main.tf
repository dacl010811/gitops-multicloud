# ============================================
# Root Module: Azure Key Vault + Managed Identity del workload (PLATAFORMA)
# PERMANENTE: sobrevive al ciclo destroy/apply del clúster (state propio,
# key azure/key-vault.tfstate — patrón de iac/azure/registry/).
#
# Homólogo conceptual del almacén de secretos de AWS, con una diferencia
# deliberada y defendible: aquí el almacén y la identidad son de LARGA VIDA
# porque (a) su costo es residual (~$0.03/secreto/mes; la MI es gratis) y
# (b) el nombre del Key Vault es único GLOBAL con soft-delete de 90 días —
# recrearlo por sesión invitaría al infierno del soft-delete. En AWS todo el
# módulo secrets-csi es efímero porque SSM no tiene esas restricciones. La
# frontera permanente/efímero se adapta al servicio; el patrón es el mismo.
#
# LO QUE NO VIVE AQUÍ: el federated identity credential (issuer OIDC con
# UUID por clúster) vive en iac/azure/main.tf y muere con el clúster —
# homólogo del trust IRSA efímero de AWS.
#
# LOS SECRETOS NO NACEN EN TERRAFORM: azurerm_key_vault_secret exigiría rol
# data-plane (Key Vault Secrets Officer) para el SP terraform-ci, rompiendo
# el least-privilege. Se siembran UNA SOLA VEZ con el bootstrap humano
# (scripts/bootstrap-keyvault-rbac-azure.sh) — decisión registrada
# "bootstrap privilegiado humano único vs operación recurrente SP". Bonus:
# el state de Terraform NO contiene ningún valor secreto.
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "sri-tfstate-rg"
    storage_account_name = "sritfstate23c5"
    container_name       = "tfstate"
    key                  = "azure/key-vault.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# La casa de la plataforma: mismo RG del ACR y del backend (permanente).
data "azurerm_resource_group" "platform" {
  name = var.resource_group_name
}

resource "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  location            = data.azurerm_resource_group.platform.location
  resource_group_name = data.azurerm_resource_group.platform.name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # Modelo RBAC (recomendado; las access policies son legado). La MI del
  # workload recibe "Key Vault Secrets User" vía bootstrap humano (el SP
  # Contributor no puede crear role assignments).
  enable_rbac_authorization = true

  # Sin purge protection: si algún día se elimina de verdad, permitir purge
  # manual del nombre (prevent_destroy ya protege en la capa Terraform).
  purge_protection_enabled = false

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Identidad del workload — homólogo del ROL IRSA de AWS. El SA del pod se
# federa a esta identidad (federated credential en iac/azure/main.tf).
# Su clientId es PÚBLICO (no secreto): viaja commiteado en el overlay
# (SPC clientID + anotación del SA), igual que el ARN del rol en AWS.
resource "azurerm_user_assigned_identity" "workload" {
  name                = var.identity_name
  location            = data.azurerm_resource_group.platform.location
  resource_group_name = data.azurerm_resource_group.platform.name

  tags = var.tags
}
