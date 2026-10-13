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
  features {
    resource_group {
      # AKS crea recursos de Managed Prometheus (dataCollectionRules/Endpoints
      # + prometheusRuleGroups) de forma ASÍNCRONA al cluster. Si el cluster
      # vive lo suficiente, esos recursos quedan huérfanos en el RG y el
      # destroy falla ("Resource Group still contains Resources"). Este RG
      # existe únicamente para el cluster, así que el borrado en cascada
      # vía API de Azure es seguro y evita limpieza manual.
      prevent_deletion_if_contains_resources = false
    }
  }

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

# ============================================
# Federación SA → Managed Identity (sesión 2026-10-08)
# Homólogo del trust policy IRSA de AWS (iac/aws/secrets-csi). El issuer
# OIDC de AKS lleva un UUID POR CLÚSTER → la credencial federada es EFÍMERA:
# vive en ESTE state y se recrea con cada clúster. La MI es PERMANENTE
# (iac/azure/key-vault); aquí solo se referencia vía data source (dirección
# segura de dependencia: lo efímero lee lo permanente).
# ============================================
data "azurerm_user_assigned_identity" "workload" {
  name                = var.workload_identity_name
  resource_group_name = var.platform_resource_group_name
}

resource "azurerm_federated_identity_credential" "workload" {
  name                = "sri-facturacion-sa"
  resource_group_name = var.platform_resource_group_name
  parent_id           = data.azurerm_user_assigned_identity.workload.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  subject             = "system:serviceaccount:sri-facturacion:sri-facturacion-sa"
}
