#!/usr/bin/env bash
# ============================================================
# Bootstrap de ejemplo para crear usuarios humanos IAM que tengan acceso al cluster creado
# programaticamente (CLI o SDK) y que tengan acceso al cluster creado por consola web
#
# PRECAUCIÓN: ejecutar como root (o identidad con gestión IAM).
# terraform-ci NO tiene iam:CreateUser/CreateLoginProfile/CreatePolicy/
# AttachUserPolicy (least-privilege by design) => todo fallaría con AccessDenied.
# ============================================================
set -euo pipefail

# Guard: abortar si la sesión actual es terraform-ci
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Identidad actual: $CALLER_ARN"
if [[ "$CALLER_ARN" == *":user/terraform-ci" ]]; then
  echo "ERROR: estás como terraform-ci, que no tiene permisos de gestión IAM (by design)." >&2
  echo "       Ejecuta este script con credenciales de root (o admin)." >&2
  exit 1
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # portable: raiz del repo

# 1. Crear el usuario (SOLO consola: sin access keys)
aws iam create-user \
  --user-name k8sweb-admin \
  --tags Key=Project,Value=SRI-GitOps-Multicloud Key=ManagedBy,Value=manual-bootstrap

# 2. Password temporal (te obligará a cambiarlo en el primer login)
aws iam create-login-profile \
  --user-name k8sweb-admin \
  --password 'CambiaEsta#2026-Temporal' \
  --password-reset-required

# 3. Crear y adjuntar la policy de solo lectura de consola
aws iam create-policy \
  --policy-name sri-console-viewer \
  --description "Solo lectura: ver cluster EKS y recursos k8s en consola web" \
  --policy-document file://iac/aws/policies/console-viewer-policy.json

aws iam attach-user-policy \
  --user-name k8sweb-admin \
  --policy-arn arn:aws:iam::053044806920:policy/sri-console-viewer