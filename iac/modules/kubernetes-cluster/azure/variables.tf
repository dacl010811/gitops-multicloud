variable "cluster_name" {
  description = "Nombre del clúster AKS"
  type        = string
}

variable "location" {
  description = "Región de Azure"
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group contenedor del clúster"
  type        = string
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes"
  type        = string
}

variable "node_count" {
  description = "Número de nodos del default node pool"
  type        = number
}

variable "node_instance_type" {
  description = "Tamaño de VM de los nodos (vm_size)"
  type        = string
}

variable "tags" {
  description = "Etiquetas comunes"
  type        = map(string)
  default     = {}
}
