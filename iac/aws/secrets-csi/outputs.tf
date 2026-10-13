output "secrets_csi_role_arn" {
  description = "ARN del rol IRSA (lo consume scripts/bootstrap-secrets-csi-eks.sh para anotar el SA del chart)"
  value       = aws_iam_role.secrets_csi.arn
}

output "oidc_provider_arn" {
  description = "ARN del OIDC provider del cluster (creado por este modulo)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "parameter_names" {
  description = "Nombres de los parametros SSM (NUNCA valores: el secreto vive solo en SSM y en el state cifrado)"
  value = [
    aws_ssm_parameter.db_user.name,
    aws_ssm_parameter.db_password.name,
    aws_ssm_parameter.db_host.name,
  ]
}
