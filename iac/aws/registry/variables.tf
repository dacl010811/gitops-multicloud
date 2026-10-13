# ============================================
# Variables: Root Module AWS ECR Registry
# ============================================

variable "region" {
  description = "Región de AWS donde vivirá el repositorio ECR"
  type        = string
  default     = "us-east-1"
}

variable "repository_name" {
  description = "Nombre del repositorio (debe coincidir con IMAGE_NAME del pipeline CI/CD)"
  type        = string
  default     = "sri-facturacion-service"
}

variable "expire_untagged_days" {
  description = "Días tras los cuales expiran las imágenes sin tag (limpieza FinOps)"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default = {
    Project     = "SRI-GitOps-Multicloud"
    ManagedBy   = "Terraform"
    Layer       = "platform"
    Cloud       = "aws"
    Environment = "production"
  }
}
