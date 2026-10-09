# ============================================
# Variables: IRSA para AWS Load Balancer Controller
# ============================================

variable "region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nombre del cluster EKS (ya existente)"
  type        = string
  default     = "sri-eks-cluster"
}

variable "tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default = {
    Project     = "SRI-GitOps-Multicloud"
    ManagedBy   = "Terraform"
    Environment = "production"
    Cloud       = "aws"
  }
}
