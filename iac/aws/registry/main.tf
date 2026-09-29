# ============================================
# Root Module: AWS ECR Registry (plataforma)
# Infraestructura de LARGA VIDA: sobrevive al ciclo destroy/apply del
# clúster (state separado, key aws/registry.tfstate). El clúster vive en
# iac/aws (key aws/terraform.tfstate) y se destruye frecuentemente (FinOps).
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Estado remoto en S3 con locking nativo (use_lockfile).
  # Requiere Terraform >= 1.10. El bucket debe existir antes de 'init'.
  # State DEDICADO: un destroy del clúster (iac/aws) jamás lo toca.
  backend "s3" {
    bucket       = "sri-gitops-tfstate"
    key          = "aws/registry.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

# ============================================
# Repositorio ECR (único recurso de plataforma)
# ============================================
resource "aws_ecr_repository" "main" {
  name = var.repository_name

  # El pipeline publica :latest (puntero flotante) + :<sha> (inmutable por
  # commit). MUTABLE es requisito para que :latest se pueda sobrescribir.
  # La trazabilidad real la da el tag sha, no la mutabilidad del repo.
  image_tag_mutability = "MUTABLE"

  # Escaneo de vulnerabilidades en cada push (sin costo adicional)
  image_scanning_configuration {
    scan_on_push = true
  }

  # Cifrado AES256 gestionado por AWS (default, sin costo de KMS)
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags

  # CAPA 1 (Terraform): bloquea cualquier 'terraform destroy' que incluya
  # este recurso. Eliminar el repo exige quitar este bloque en codigo
  # (commit deliberado) ANTES — nunca un descuido de sesion.
  lifecycle {
    prevent_destroy = true
  }
}

# ============================================
# Limpieza FinOps: expira imagenes SIN TAG a los N dias.
# ATENCION: esto NO es proteccion — proteccion = prevent_destroy + state
# separado + IAM sin ecr:DeleteRepository (ver policy terraform-ci).
# Las imagenes pineadas con tag (sha, latest) nunca caducan por esta regla.
# ============================================
resource "aws_ecr_lifecycle_policy" "untagged_cleanup" {
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expira imagenes sin tag despues de ${var.expire_untagged_days} dias (basura de builds)"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.expire_untagged_days
      }
      action = {
        type = "expire"
      }
    }]
  })
}
