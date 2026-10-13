variable "cluster_name" {
  description = "Nombre del cluster EKS (debe existir: data source)"
  type        = string
  default     = "sri-eks-cluster"
}

variable "region" {
  description = "Region AWS del modulo"
  type        = string
  default     = "us-east-1"
}

variable "demo_db_user" {
  description = "Usuario de BD del demo (identificador, no credencial: seguro como default)"
  type        = string
  default     = "sri_app_user"
}

variable "demo_db_host" {
  description = "Host de BD del demo (endpoint ficticio: valida el patron, no hay RDS real)"
  type        = string
  default     = "sri-demo-db.cluster-demo1234.us-east-1.rds.amazonaws.com"
}

variable "tags" {
  description = "Tags aplicados a todos los recursos del modulo"
  type        = map(string)
  default = {
    Project   = "SRI-Facturacion-GitOps"
    ManagedBy = "Terraform"
    Module    = "secrets-csi"
  }
}
