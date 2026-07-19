# ============================================
# Outputs: Root Module Azure AKS
# ============================================

output "cluster_name" {
  description = "Nombre del clúster AKS"
  value       = module.aks.cluster_name
}

output "cloud_provider" {
  description = "Proveedor cloud"
  value       = "azure"
}

output "cluster_endpoint" {
  description = "Endpoint de la API de Kubernetes"
  value       = module.aks.endpoint
}

output "kubeconfig" {
  description = "Kubeconfig para conectarse al clúster AKS"
  value       = module.aks.kubeconfig
  sensitive   = true
}

output "resource_group_name" {
  description = "Nombre del Resource Group del clúster"
  value       = azurerm_resource_group.main.name
}
