# ============================================
# Outputs: IRSA para AWS Load Balancer Controller
# ============================================

output "irsa_role_arn" {
  description = "ARN del rol IAM para el ServiceAccount del LB Controller"
  value       = aws_iam_role.lb_controller.arn
}

output "oidc_provider_arn" {
  description = "ARN del OIDC provider IAM del cluster"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "policy_arn" {
  description = "ARN de la politica AWSLoadBalancerControllerIAMPolicy"
  value       = aws_iam_policy.lb_controller.arn
}
