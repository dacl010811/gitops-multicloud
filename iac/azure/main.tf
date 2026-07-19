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
  # Reemplazar resource_group_name y storage_account_name por los recursos reales antes de 'init'.
  backend "azurerm" {
    resource_group_name  = "sri-tfstate-rg"
    storage_account_name = "sritfstate"
    container_name       = "tfstate"
    key                  = "azure/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
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
  source = "../modules/kubernetes-cluster"

  cloud_provider      = "azure"
  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  node_count          = var.node_count
  node_instance_type  = var.node_instance_type
  environment         = var.environment
  tags                = var.tags
}
