# ============================================
# Root Module: IRSA para Secrets Store CSI Driver + parametros SSM (demo)
# Se ejecuta DESPUES de crear el cluster (data source del issuer OIDC) y se
# destruye ANTES que el cluster (misma razon: el data source lo requiere vivo).
# Estado propio: aws/secrets-csi.tfstate (patron de iac/aws/lb-controller).
#
# El secreto demo nace en RUNTIME (random_password) y vive SOLO en SSM
# (SecureString, cifrado at-rest con la llave administrada aws/ssm):
# jamas en Git ni en tfvars (auditado en el guion AWSSecretsSSM-CSI.md).
# El state SI contiene el valor (cifrado en S3, encrypt=true) — riesgo
# documentado, aceptado y discutido en las preguntas de jurado.
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "sri-gitops-tfstate"
    key          = "aws/secrets-csi.tfstate"
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
# Hoy NO se levanta lb-controller, asi que ESTE modulo lo crea (mismo
# recurso, mismo Name). Recurso de cuenta asociado al cluster: muere con
# la sesion (destroy de este modulo ANTES que el destroy del cluster).
# ============================================
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks-oidc-provider"
  })
}

# ============================================
# Trust policy: solo el ServiceAccount kube-system/secrets-store-csi-driver
# (el que crea el chart del driver) puede asumir este rol.
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
      values   = ["system:serviceaccount:kube-system:secrets-store-csi-driver"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "secrets_csi" {
  name               = "${var.cluster_name}-secrets-csi"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-secrets-csi"
  })
}

# ============================================
# Politica de lectura SSM del driver.
# Versionada junto al modulo (leccion file() del 2026-10-04: se provisiona
# local y se commitea — el JSON es artefacto del proyecto, no upstream).
#
# Least privilege en tres capas:
#  - Solo GetParameter* (el driver jamas escribe) y SOLO bajo /sri-facturacion/*
#  - kms:Decrypt restringido por alias: solo la llave administrada aws/ssm
#    (en produccion: CMK propia con Resource = arn de la llave, ni Resource *)
#  - Sin DescribeParameters (no lo necesita el pod; el diagnostico CLI lo da
#    la politica de terraform-ci, PASO 5.0 del guion)
# ============================================
resource "aws_iam_policy" "secrets_csi" {
  name   = "${var.cluster_name}-secrets-csi"
  policy = file("${path.module}/iam_policy.json")

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "secrets_csi" {
  role       = aws_iam_role.secrets_csi.name
  policy_arn = aws_iam_policy.secrets_csi.arn
}

# ============================================
# Parametros SSM del demo (Standard tier: $0; SecureString: cifrado at-rest).
# La CONTRASEÑA nace en runtime via random_password: no hay defaults en Git
# ni tfvars que commitear. overwrite=true mantiene la re-ejecucion idempotente
# sin chocar con un parametro preexistente.
# ============================================
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "db_user" {
  name      = "/sri-facturacion/DB_USER"
  type      = "SecureString"
  value     = var.demo_db_user
  overwrite = true

  tags = var.tags
}

resource "aws_ssm_parameter" "db_password" {
  name      = "/sri-facturacion/DB_PASSWORD"
  type      = "SecureString"
  value     = random_password.db.result
  overwrite = true

  tags = var.tags
}

resource "aws_ssm_parameter" "db_host" {
  name      = "/sri-facturacion/DB_HOST"
  type      = "SecureString"
  value     = var.demo_db_host
  overwrite = true

  tags = var.tags
}
