# ============================================
# Módulo Genérico Kubernetes Cluster
# Crea EKS o AKS según el parámetro cloud_provider
# ============================================

terraform {
  required_version = ">= 1.6.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# ============================================
# RECURSOS CONDICIONALES: AWS EKS
# ============================================

resource "aws_eks_cluster" "main" {
  count = var.cloud_provider == "aws" ? 1 : 0
  
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster[0].arn
  version  = var.kubernetes_version
  
  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }
  
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  
  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks"
  })
}

# ============================================
# RECURSOS CONDICIONALES: Azure AKS
# ============================================

resource "azurerm_kubernetes_cluster" "main" {
  count = var.cloud_provider == "azure" ? 1 : 0
  
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
