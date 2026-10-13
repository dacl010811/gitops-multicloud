# ============================================
# Root Module: Azure ACR Registry (plataforma)
# Infraestructura de LARGA VIDA: sobrevive al ciclo destroy/apply del
# cluster (state separado, key azure/registry.tfstate). El cluster vive en
# iac/azure (key azure/terraform.tfstate) y se destruye frecuentemente
# (FinOps). Espejo de iac/aws/registry/.
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  # Estado remoto en Azure Storage (misma cuenta que el state del cluster,
  # key DEDICADA: un destroy del cluster jamas toca este state).
  backend "azurerm" {
    resource_group_name  = "sri-tfstate-rg"
    storage_account_name = "sritfstate23c5"
    container_name       = "tfstate"
    key                  = "azure/registry.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# ============================================
# Azure Container Registry (recurso de plataforma)
# ============================================
# El nombre es UNICO GLOBAL en Azure (misma regla que el storage account):
# sufijo 23c5 tomado del subscription id, como sritfstate23c5.
resource "azurerm_container_registry" "main" {
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"

  # Sin usuario administrador: el push/pull se autentica con Entra ID
  # (el SP del pipeline via OIDC de GitHub; los nodos AKS via kubelet
  # identity cuando haya cluster). admin_enabled=true seria un acceso
  # de fallback fuera del modelo de identidad del proyecto.
  admin_enabled = false

  tags = var.tags

  # CAPA 1 (Terraform): bloquea cualquier 'terraform destroy' que incluya
  # este recurso. Eliminar el registry exige quitar este bloque en codigo
  # (commit deliberado) ANTES — nunca un descuido de sesion.
  lifecycle {
    prevent_destroy = true
  }
}
