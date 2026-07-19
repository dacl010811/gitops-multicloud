#!/usr/bin/env bash
# ============================================================
# Bootstrap del backend remoto de Terraform en AWS
# Crea el bucket S3 (estado) y la tabla DynamoDB (locking)
# que referencia iac/aws/main.tf.
#
# Uso (desde una EC2 con IAM Role o con 'aws configure'):
#   bash scripts/bootstrap-backend-aws.sh
#
# Idempotente: si el recurso ya existe, no falla.
# ============================================================
set -euo pipefail

# ----- Valores alineados con iac/aws/main.tf (backend "s3") -----
BUCKET="${TF_STATE_BUCKET:-sri-gitops-tfstate}"
DYNAMODB_TABLE="${TF_LOCK_TABLE:-sri-gitops-tflock}"
REGION="${AWS_REGION:-us-east-1}"

echo ">> Región:        ${REGION}"
echo ">> Bucket S3:     ${BUCKET}"
echo ">> Tabla DynamoDB:${DYNAMODB_TABLE}"
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

# ----- 3. Tabla DynamoDB para el locking -----
if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "[=] La tabla ${DYNAMODB_TABLE} ya existe."
else
  echo "[+] Creando tabla ${DYNAMODB_TABLE}..."
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"
  echo "[+] Esperando a que la tabla esté activa..."
  aws dynamodb wait table-exists --table-name "${DYNAMODB_TABLE}" --region "${REGION}"
fi

echo
echo ">> Backend AWS listo. Ahora puedes ejecutar:"
echo "   cd iac/aws && terraform init && terraform plan"
