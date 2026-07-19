# ============================================
# Outputs: Root Module AWS EKS
# ============================================

output "cluster_name" {
  description = "Nombre del clúster EKS"
  value       = module.eks.cluster_name
}

output "cloud_provider" {
  description = "Proveedor cloud"
  value       = module.eks.cloud_provider
}

output "cluster_endpoint" {
  description = "Endpoint de la API de Kubernetes"
  value       = module.eks.endpoint
}

output "kubeconfig" {
  description = "Kubeconfig para conectarse al clúster EKS"
  value       = module.eks.kubeconfig
  sensitive   = true
}

output "node_group_name" {
  description = "Nombre del managed node group"
  value       = aws_eks_node_group.main.node_group_name
}
