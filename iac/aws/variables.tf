# ============================================
# Variables: Root Module AWS EKS
# ============================================

variable "region" {
  description = "Región de AWS donde se desplegará el clúster EKS"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nombre del clúster EKS"
  type        = string
  default     = "sri-eks-cluster"
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
  description = "Número de nodos workers (desired/min)"
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "Tipo de instancia EC2 para los nodos workers"
  type        = string
  default     = "t3.medium"
}

variable "cluster_role_arn" {
  description = "ARN de un rol IAM existente para el control plane de EKS. Vacío = crearlo. En AWS Academy usar el ARN de LabRole."
  type        = string
  default     = ""
}

variable "node_role_arn" {
  description = "ARN de un rol IAM existente para los nodos workers. Vacío = crearlo. En AWS Academy usar el ARN de LabRole."
  type        = string
  default     = ""
}

variable "api_access_cidrs" {
  description = "CIDRs autorizados a alcanzar el API server de EKS (kubectl) vía el Security Group del clúster. Vacío = usar automáticamente el CIDR de la VPC por defecto."
  type        = list(string)
  default     = []
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
