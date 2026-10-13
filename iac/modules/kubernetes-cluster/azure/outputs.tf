output "cluster_name" {
  description = "Nombre del clúster AKS"
  value       = azurerm_kubernetes_cluster.main.name
}

output "endpoint" {
  description = "Endpoint de la API del clúster AKS"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].host
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig completo para conectarse al clúster AKS"
  sensitive   = true
  value = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = azurerm_kubernetes_cluster.main.name
      cluster = {
        server                     = azurerm_kubernetes_cluster.main.kube_config[0].host
        certificate-authority-data = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
      }
    }]
    contexts = [{
      name = azurerm_kubernetes_cluster.main.name
      context = {
        cluster = azurerm_kubernetes_cluster.main.name
        user    = azurerm_kubernetes_cluster.main.name
      }
    }]
    current-context = azurerm_kubernetes_cluster.main.name
    users = [{
      name = azurerm_kubernetes_cluster.main.name
      user = {
        client-certificate-data = azurerm_kubernetes_cluster.main.kube_config[0].client_certificate
        client-key-data         = azurerm_kubernetes_cluster.main.kube_config[0].client_key
      }
    }]
  })
}

output "oidc_issuer_url" {
  description = "Issuer OIDC del clúster (URL con UUID propio — cambia en cada recreate)"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}
