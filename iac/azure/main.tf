# ============================================
# Root Module: Azure AKS
# Invoca el módulo genérico kubernetes-cluster (provider = azure)
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  # Estado remoto en Azure Storage.
  # storage_account_name es único GLOBALMENTE en Azure: sritfstate ya estaba
  # tomado, se usa sritfstate23c5 (sufijo del subscription id para unicidad).
  backend "azurerm" {
    resource_group_name  = "sri-tfstate-rg"
    storage_account_name = "sritfstate23c5"
    container_name       = "tfstate"
    key                  = "azure/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}

  # Registro AUTOMÁTICO de resource providers (default). Con red estable,
  # Terraform registra solo lo necesario en el primer plan y los providers
  # quedan persistidos en la suscripción (una sola vez en su vida).
  # Fallback ante timeouts del ISP: scripts/bootstrap-backend-azure.sh
  # también pre-registra los 4 providers esenciales (paso idempotente).
}

# ============================================
# Resource Group contenedor del clúster
# ============================================
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ============================================
# Clúster AKS (vía módulo genérico)
# ============================================
module "aks" {
  source = "../modules/kubernetes-cluster/azure"

  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  node_count          = var.node_count
  node_instance_type  = var.node_instance_type
  tags                = var.tags
}
