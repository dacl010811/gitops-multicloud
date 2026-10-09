# ============================================
# Variables: Root Module Azure Key Vault (plataforma)
# ============================================

variable "resource_group_name" {
  description = "RG de plataforma permanente (mismo del ACR y del backend de estado)"
  type        = string
  default     = "sri-tfstate-rg"
}

variable "key_vault_name" {
  description = "Nombre del Key Vault — ÚNICO GLOBAL (misma regla que storage/ACR; sufijo 23c5 de la suscripción)"
  type        = string
  default     = "sri-keyvault-23c5"
}

variable "identity_name" {
  description = "Managed Identity user-assigned del workload (homólogo del rol IRSA de AWS)"
  type        = string
  default     = "sri-facturacion-wi"
}

variable "tenant_id" {
  description = "Tenant Entra ID del vault (identificador público, no secreto)"
  type        = string
  default     = "0fc1436e-05f9-416b-9d88-a108f4a1133b"
}

variable "tags" {
  description = "Tags comunes"
  type        = map(string)
  default = {
    Project     = "SRI-GitOps-Multicloud"
    ManagedBy   = "Terraform"
    Environment = "production"
    Cloud       = "azure"
  }
}
