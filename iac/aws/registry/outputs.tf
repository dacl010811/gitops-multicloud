# ============================================
# Outputs: Root Module AWS ECR Registry
# ============================================

output "repository_url" {
  description = "URL del repositorio (la consumen los overlays Kustomize como newName)"
  value       = aws_ecr_repository.main.repository_url
}

output "repository_arn" {
  description = "ARN del repositorio (referencia para policies IAM scoped)"
  value       = aws_ecr_repository.main.arn
}

output "registry_id" {
  description = "ID de la cuenta propietaria del registry"
  value       = aws_ecr_repository.main.registry_id
}
