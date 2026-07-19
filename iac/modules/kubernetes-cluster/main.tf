# ============================================
# Módulo Genérico Kubernetes Cluster
# Crea EKS o AKS según el parámetro cloud_provider
# ============================================

terraform {
  required_version = ">= 1.6.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ============================================
# RECURSOS CONDICIONALES: AWS EKS
# ============================================

# IAM Role para el Control Plane de EKS (solo AWS y si no se pasa un ARN existente)
resource "aws_iam_role" "eks_cluster" {
  count = var.cloud_provider == "aws" && var.cluster_role_arn == "" ? 1 : 0
  name  = "${var.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  count      = var.cloud_provider == "aws" && var.cluster_role_arn == "" ? 1 : 0
  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  count = var.cloud_provider == "aws" ? 1 : 0
  
  name     = var.cluster_name
  role_arn = var.cluster_role_arn != "" ? var.cluster_role_arn : aws_iam_role.eks_cluster[0].arn
  version  = var.kubernetes_version
  
  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }
  
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  
  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks"
  })
}

# Regla de acceso al API server de EKS (443) desde CIDRs autorizados.
# Formaliza en Terraform lo que antes se añadía a mano al Security Group del
# clúster; necesario para que kubectl alcance el endpoint privado desde
# instancias dentro de la VPC. for_each vacío => no se crea ninguna regla.
resource "aws_vpc_security_group_ingress_rule" "eks_api" {
  for_each = var.cloud_provider == "aws" ? toset(var.api_access_cidrs) : toset([])

  security_group_id = aws_eks_cluster.main[0].vpc_config[0].cluster_security_group_id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description        = "Acceso HTTPS al API server de EKS (kubectl) desde ${each.value}"
}

# ============================================
# Nota: los recursos de Azure AKS viven en un módulo independiente
# (iac/modules/kubernetes-cluster/azure) usado por el root iac/azure.
# Este módulo es específico de AWS EKS para NO arrastrar el provider azurerm
# al grafo del root AWS (evita que azurerm intente autenticarse).
# ============================================
