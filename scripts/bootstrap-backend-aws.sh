#!/usr/bin/env bash
# ============================================================
# Bootstrap del backend remoto de Terraform en AWS
# Crea el bucket S3 (estado) que referencia iac/aws/main.tf.
#
# Uso (con IAM User terraform-ci o rol con permisos S3):
#   bash scripts/bootstrap-backend-aws.sh
#
# Idempotente: si el recurso ya existe, no falla.
#
# Nota: Terraform >= 1.10 usa locking nativo de S3 (use_lockfile),
# por lo que ya NO se requiere tabla DynamoDB.
# ============================================================
set -euo pipefail

# ----- Valores alineados con iac/aws/main.tf (backend "s3") -----
BUCKET="${TF_STATE_BUCKET:-sri-gitops-tfstate}"
REGION="${AWS_REGION:-us-east-1}"

echo ">> Región:    ${REGION}"
echo ">> Bucket S3: ${BUCKET}"
echo

# ----- 1. Bucket S3 para el estado -----
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "[=] El bucket ${BUCKET} ya existe."
else
  echo "[+] Creando bucket ${BUCKET}..."
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
fi

# ----- 2. Versionado + cifrado + bloqueo de acceso público -----
echo "[+] Habilitando versionado..."
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

echo "[+] Habilitando cifrado por defecto (AES256)..."
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "[+] Bloqueando acceso público..."
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo
echo ">> Backend AWS listo. Ahora puedes ejecutar:"
echo "   cd iac/aws && terraform init && terraform plan"
