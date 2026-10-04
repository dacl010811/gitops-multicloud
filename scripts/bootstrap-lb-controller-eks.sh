#!/usr/bin/env bash
# ============================================================
# Bootstrap idempotente del AWS Load Balancer Controller en el
# cluster EKS 'sri-eks-cluster' (us-east-1).
#
# Que hace, en un solo comando:
#   1. Verifica prerrequisitos (cluster alcanzable, helm, rol IRSA ya aplicado)
#   2. Crea/anota la ServiceAccount kube-system/aws-load-balancer-controller
#      con el ARN del rol IRSA (ciclo de vida: iac/aws/lb-controller)
#   3. Instala (o actualiza, reejecutable) el chart eks/aws-load-balancer-controller
#   4. Espera el rollout y muestra los pods
#
# PRECAUCIONES:
#   - Requiere el rol IRSA creado ANTES: terraform apply en iac/aws/lb-controller
#     (este script solo lo LEE via 'terraform output'; no crea nada en IAM).
#   - Requiere la politica de terraform-ci ampliada (statement IAMForIRSA)
#     solo para ese apply previo; este script en si opera 100% k8s + helm.
#   - Idempotente: se puede reejecutar las veces que haga falta.
#   - Costo: $0 (los pods del controller corren sobre los nodos existentes).
# ============================================================
set -euo pipefail

REPO_ROOT="/Users/admin/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud"
CLUSTER_NAME="sri-eks-cluster"
REGION="us-east-1"
SA_NAME="aws-load-balancer-controller"
SA_NAMESPACE="kube-system"

echo "== 0. Guards =="
# Cluster alcanzable (kubeconfig apuntando al cluster correcto)
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if ! kubectl get nodes > /dev/null 2>&1; then
  echo "ERROR: no alcanzo el cluster con el contexto actual ($CURRENT_CTX)." >&2
  echo "       Ejecuta primero: aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME" >&2
  exit 1
fi
echo "Contexto actual: $CURRENT_CTX"

# helm instalado
if ! command -v helm > /dev/null 2>&1; then
  echo "ERROR: helm no esta instalado. Ver guion (Fase 0): tarball oficial en /usr/local/bin." >&2
  exit 1
fi

# Rol IRSA ya aplicado (solo lectura del output; el CWD del usuario no cambia)
IRSA_ROLE_ARN=$(cd "$REPO_ROOT/iac/aws/lb-controller" && terraform output -raw irsa_role_arn) || {
  echo "ERROR: no pude leer 'irsa_role_arn' desde iac/aws/lb-controller." >&2
  echo "       Aplica primero: cd iac/aws/lb-controller && terraform init && terraform apply" >&2
  exit 1
}
echo "Rol IRSA: $IRSA_ROLE_ARN"

# VPC del cluster (decidido tras incidente v3.5.0: sin vpcId explicito el controller
# intenta auto-descubrirla via IMDS, que NO responde desde el pod -> CrashLoopBackOff)
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "VPC del cluster: $VPC_ID"

echo "== 1. ServiceAccount anotada con el rol IRSA =="
kubectl create serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" \
  "eks.amazonaws.com/role-arn=$IRSA_ROLE_ARN" --overwrite
kubectl get serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}'

echo "== 2. Helm repo eks-charts =="
helm repo list | grep -q '^eks' || helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

echo "== 3. helm upgrade --install (idempotente) =="
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n "$SA_NAMESPACE" \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$SA_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID"

echo "== 4. Verificacion =="
kubectl rollout status deployment/aws-load-balancer-controller -n "$SA_NAMESPACE" --timeout=180s
kubectl get pods -n "$SA_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller

echo
echo "OK: AWS Load Balancer Controller instalado. Logs si hiciera falta:"
echo "  kubectl logs -n $SA_NAMESPACE deployment/aws-load-balancer-controller | tail -20"
