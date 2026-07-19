# ============================================
# Outputs del Módulo EKS (AWS)
# ============================================

output "cluster_name" {
  description = "Nombre del clúster Kubernetes"
  value       = var.cluster_name
}

output "cloud_provider" {
  description = "Proveedor cloud del clúster"
  value       = var.cloud_provider
}

output "kubernetes_version" {
  description = "Versión de Kubernetes desplegada"
  value       = var.kubernetes_version
}

output "endpoint" {
  description = "Endpoint de la API de Kubernetes"
  value       = aws_eks_cluster.main[0].endpoint
}

output "cluster_ca_certificate" {
  description = "Certificado CA del clúster (base64)"
  value       = aws_eks_cluster.main[0].certificate_authority[0].data
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig completo para conectarse al clúster"
  sensitive   = true
  value = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = var.cluster_name
      cluster = {
        server                     = aws_eks_cluster.main[0].endpoint
        certificate-authority-data = aws_eks_cluster.main[0].certificate_authority[0].data
      }
    }]
    contexts = [{
      name = var.cluster_name
      context = {
        cluster = var.cluster_name
        user    = var.cluster_name
      }
    }]
    current-context = var.cluster_name
    users = [{
      name = var.cluster_name
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "aws"
          args       = ["eks", "get-token", "--cluster-name", var.cluster_name]
        }
      }
    }]
  })
}
