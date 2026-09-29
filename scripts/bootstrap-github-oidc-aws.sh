#!/bin/bash
# ============================================================
# Bootstrap: federación OIDC GitHub -> AWS + rol para GitHub Actions
#
# Crea (idempotente):
#   1. OIDC provider token.actions.githubusercontent.com
#   2. Rol IAM github-actions-ecr-push que solo GitHub Actions puede asumir
#      (trust: repo + ramas), con permiso inline de PUSH a ECR scoped al
#      repositorio del microservicio (sin permisos de borrado).
#
# Por qué existe: el pipeline .github/workflows/ci-cd.yaml autentica hacia
# AWS SIN claves de larga vida (aws-actions/configure-aws-credentials + OIDC).
# Es identidad de PLATAFORMA: se crea una vez y vive junto al backend S3 y
# al registry ECR (iac/aws/registry/), fuera del ciclo destroy del cluster.
#
# IMPORTANTE:
#   - Ejecutar COMO ROOT (consola web o credenciales root). La sesión CLI
#     habitual es :user/terraform-ci, que NO tiene iam:* suficiente.
#   - Al finalizar imprime el ARN del rol: ese valor va al secret
#     AWS_ROLE_ARN del repositorio GitHub.
# ============================================================
set -euo pipefail

ACCOUNT_ID="053044806920"
REGION="us-east-1"
REPO_NAME="sri-facturacion-service"
GITHUB_REPO="dacl010811/gitops-multicloud"
ROLE_NAME="github-actions-ecr-push"
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_AUDIENCE="sts.amazonaws.com"

REPO_ARN="arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REPO_NAME}"

echo "==> Verificando identidad (debe ser root)..."
CALLER=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "    Sesión actual: ${CALLER}"
if [[ "${CALLER}" != *":root"* ]]; then
  echo "ERROR: este bootstrap debe ejecutarse como root."
  echo "       Sesión actual = ${CALLER}"
  echo "       Usa la consola web de root (CloudShell) o credenciales root."
  exit 1
fi

# ------------------------------------------------------------
# 1. OIDC provider (idempotente)
# ------------------------------------------------------------
echo "==> OIDC provider ${OIDC_URL}..."
if aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text | grep -q "token.actions.githubusercontent.com"; then
  echo "    Ya existe (idempotente). OK."
else
  aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --client-id-list "${OIDC_AUDIENCE}" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
    --tags Key=Project,Value=SRI-GitOps-Multicloud Key=ManagedBy,Value=manual-bootstrap
  echo "    Creado."
fi

# ------------------------------------------------------------
# 2. Rol con trust policy federado (solo GitHub Actions del repo)
# ------------------------------------------------------------
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "${OIDC_AUDIENCE}"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:ref:refs/heads/*"
        }
      }
    }
  ]
}
EOF
)

ECR_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuthToken",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECRPushScopedToRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "${REPO_ARN}"
    }
  ]
}
EOF
)

echo "==> Rol IAM ${ROLE_NAME}..."
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    El rol ya existe. Actualizando trust policy y policy inline..."
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUST_POLICY}"
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Push a ECR desde GitHub Actions (OIDC, repo ${GITHUB_REPO})" \
    --tags Key=Project,Value=SRI-GitOps-Multicloud Key=ManagedBy,Value=manual-bootstrap
  echo "    Creado."
fi

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "ECRPushScopedToRepo" \
  --policy-document "${ECR_POLICY}"

# ------------------------------------------------------------
# 3. Espera de propagación IAM y resumen
# ------------------------------------------------------------
echo "==> Esperando ~30s la propagación IAM..."
sleep 30

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "============================================================"
echo "ROL LISTO"
echo "  ARN : ${ROLE_ARN}"
echo "  Repo: ${REPO_ARN}"
echo "------------------------------------------------------------"
echo "Siguiente paso: en GitHub -> Settings -> Secrets and variables"
echo "-> Actions -> New repository secret:"
echo "  AWS_ROLE_ARN = ${ROLE_ARN}"
echo "  AWS_REGION   = ${REGION}"
echo "Y en Settings -> Actions -> General -> Workflow permissions:"
echo "  Read and write permissions (el bump de tag hace push)."
echo "============================================================"
