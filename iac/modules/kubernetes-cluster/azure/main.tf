# ============================================
# Submódulo Azure AKS
# Aislado para que el provider azurerm solo se configure/autentique
# cuando este submódulo se instancia (count = 1 en el módulo padre).
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_instance_type
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aks"
  })
}
