# ============================================
# Variables: Azure ACR Registry
# ============================================

variable "registry_name" {
  description = "Nombre del Azure Container Registry. UNICO GLOBAL en Azure: solo minusculas y numeros. Sufijo 23c5 = fragmento del subscription id (misma regla que sritfstate23c5)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group contenedor del registry. Se reutiliza el RG de plataforma sri-tfstate-rg (longevo, sobrevive al ciclo del cluster)."
  type        = string
}

variable "location" {
  description = "Region de Azure"
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Tags de recursos"
  type        = map(string)
  default = {
    Project     = "sri-gitops-multicloud"
    Environment = "platform"
    ManagedBy   = "terraform"
  }
}
