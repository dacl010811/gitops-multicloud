# ============================================
# Root Module: AWS EKS
# Invoca el módulo genérico kubernetes-cluster (provider = aws)
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Estado remoto en S3 con locking en DynamoDB.
  # Reemplazar bucket y dynamodb_table por los recursos reales antes de 'init'.
  backend "s3" {
    bucket         = "sri-gitops-tfstate"
    key            = "aws/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sri-gitops-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

# ============================================
# Red: usa la VPC por defecto para simplificar el bootstrap
# ============================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================
# Control Plane EKS (vía módulo genérico)
# ============================================
module "eks" {
  source = "../modules/kubernetes-cluster"

  cloud_provider     = "aws"
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  subnet_ids         = data.aws_subnets.default.ids
  cluster_role_arn   = var.cluster_role_arn
  environment        = var.environment
  tags               = var.tags
}

# ============================================
# Managed Node Group (workers)
# El módulo crea el control plane; aquí se añaden los nodos.
# Los roles IAM solo se crean si no se pasa un ARN existente (var.node_role_arn).
# ============================================
resource "aws_iam_role" "eks_nodes" {
  count = var.node_role_arn == "" ? 1 : 0
  name  = "${var.cluster_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = var.node_role_arn == "" ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.eks_nodes[0].name
  policy_arn = each.value
}

resource "aws_eks_node_group" "main" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = var.node_role_arn != "" ? var.node_role_arn : aws_iam_role.eks_nodes[0].arn
  subnet_ids      = data.aws_subnets.default.ids

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count + 2
  }

  instance_types = [var.node_instance_type]

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.eks_nodes,
  ]

  tags = var.tags
}
