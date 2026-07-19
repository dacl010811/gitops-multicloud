# ============================================
# Variables del Módulo Genérico Kubernetes Cluster
# ============================================

variable "cluster_name" {
  description = "Nombre del clúster Kubernetes"
  type        = string
  
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.cluster_name))
    error_message = "El nombre del clúster debe tener entre 3 y 25 caracteres, empezar con letra minúscula y solo contener letras minúsculas, números y guiones."
  }
}

variable "cloud_provider" {
  description = "Proveedor cloud: 'aws' o 'azure'"
  type        = string
  
  validation {
    condition     = contains(["aws", "azure"], var.cloud_provider)
    error_message = "El proveedor cloud debe ser 'aws' o 'azure'."
  }
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes a desplegar"
  type        = string
  default     = "1.28"
}

variable "environment" {
  description = "Ambiente (dev, staging, production)"
  type        = string
  default     = "production"
  
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "El ambiente debe ser 'dev', 'staging' o 'production'."
  }
}

variable "node_count" {
  description = "Número de nodos workers"
  type        = number
  default     = 3
  
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 10
    error_message = "El número de nodos debe estar entre 1 y 10."
  }
}

variable "node_instance_type" {
  description = "Tipo de instancia para nodos workers"
  type        = string
  default     = "default"
}

variable "tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default = {
    Project     = "SRI-GitOps-Multicloud"
    ManagedBy   = "Terraform"
    Environment = "production"
  }
}