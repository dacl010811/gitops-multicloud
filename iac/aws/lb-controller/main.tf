# ============================================
# Root Module: IRSA para AWS Load Balancer Controller
# Se ejecuta DESPUES de crear el cluster (data source del issuer OIDC) y se
# destruye ANTES que el cluster (misma razon: el data source lo requiere vivo).
# Estado propio: aws/lb-controller.tfstate (independiente del ensayo base).
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket       = "sri-gitops-tfstate"
    key          = "aws/lb-controller.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

# ============================================
# Data sources: el cluster ya existe (creado por iac/aws)
# ============================================
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# Certificado del emisor OIDC del cluster (para el thumbprint del provider)
data "tls_certificate" "eks" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ============================================
# OIDC provider IAM del cluster.
# NOTA: el modulo iac/modules/kubernetes-cluster NO lo crea (leccion de
# auditoria 2026-10-03); IRSA no funciona sin el. Es un recurso de cuenta
# asociado al cluster: se destruye junto a esta sesion.
# ============================================
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks-oidc-provider"
  })

  # Recurso de CUENTA compartido (unico por issuer): en el flujo normal lo
  # CREA iac/aws/secrets-csi y este modulo lo IMPORTA. Los tags los gobierna
  # el modulo creador; aqui se ignoran para evitar la pelea de tags entre
  # ambos states (incidente 2026-10-06: el apply intento untag -> AccessDenied
  # UntagOpenIDConnectProvider, permiso no otorgado por least-privilege).
  
  lifecycle {
    ignore_changes = [tags, tags_all]
  }

}

# ============================================
# Trust policy: solo el ServiceAccount kube-system/aws-load-balancer-controller
# puede asumir este rol (federacion OIDC + condiciones sub/aud).
# ============================================
data "aws_iam_policy_document" "irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-alb-controller"
  })
}

# ============================================
# Politica oficial del AWS Load Balancer Controller (v2.7.2).
# Se descarga con curl en la sesion (guion Fase 5); NO se versiona el JSON
# porque es artefacto upstream: la fuente de verdad es el repo del proyecto.
# ============================================
resource "aws_iam_policy" "lb_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/iam_policy.json")

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}
