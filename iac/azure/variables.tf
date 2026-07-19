# ============================================
# Variables: Root Module Azure AKS
# ============================================

variable "location" {
  description = "Región de Azure donde se desplegará el clúster AKS"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Nombre del Resource Group para el clúster AKS"
  type        = string
  default     = "sri-aks-rg"
}

variable "cluster_name" {
  description = "Nombre del clúster AKS"
  type        = string
  default     = "sri-aks-cluster"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes"
  type        = string
  default     = "1.30"
}

variable "environment" {
  description = "Ambiente (dev, staging, production)"
  type        = string
  default     = "production"
}

variable "node_count" {
  description = "Número de nodos del default node pool"
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "Tamaño de VM para los nodos del clúster AKS"
  type        = string
  default     = "Standard_DS2_v2"
}

variable "tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default = {
    Project     = "SRI-GitOps-Multicloud"
    ManagedBy   = "Terraform"
    Environment = "production"
    Cloud       = "azure"
  }
}
