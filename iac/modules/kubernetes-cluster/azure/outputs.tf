output "host" {
  description = "Endpoint de la API del clúster AKS"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].host
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Certificado CA del clúster (base64)"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "client_certificate" {
  description = "Certificado cliente para autenticación kubeconfig"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Clave cliente para autenticación kubeconfig"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].client_key
  sensitive   = true
}
