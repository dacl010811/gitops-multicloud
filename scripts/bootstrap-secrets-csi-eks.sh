#!/usr/bin/env bash
# ============================================
# bootstrap-secrets-csi-eks.sh
# Secrets Store CSI Driver + AWS provider para EKS (objetivo #4: secretos).
#
# Idempotente: se puede re-ejecutar sin efectos secundarios (helm upgrade
# --install + kubectl apply declarativo). Estilo del proyecto (bootstrap-
# lb-controller-eks.sh): guards + pasos numerados + verificacion final.
#
# Precauciones:
#   - Requiere cluster EKS vivo con kubeconfig apuntando a el (Bloque 1).
#   - Requiere el modulo iac/aws/secrets-csi APLICADO (lee el output del rol).
#   - NO crea recursos de pago: driver y provider corren como pods en los
#     nodos existentes ($0 adicional).
#
# Uso: bash scripts/bootstrap-secrets-csi-eks.sh
# ============================================
set -euo pipefail

REPO_ROOT="/Users/admin/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud"
DRIVER_NS="kube-system"
DRIVER_CHART_VERSION="1.4.8"   # pineado (leccion 2026-10-04: chart "latest" trajo drift politica/controller)

echo "==> PASO 0. Guards: cluster vivo, helm instalado, rol IRSA en el state"
kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: sin cluster accesible (kubectl get nodes fallo). Levanta el Bloque 1 primero."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm no instalado"; exit 1; }
ROLE_ARN=$(cd "$REPO_ROOT/iac/aws/secrets-csi" && terraform output -raw secrets_csi_role_arn)
echo "    Rol IRSA del driver: $ROLE_ARN"

echo "==> PASO 1. Repo Helm del driver (kubernetes-sigs)"
# INCIDENTE 2026-10-05: el Pages de kubernetes-sigs migro el repo helm al
# subpath /charts/ (la raiz da 404 en el index.yaml). --force-update re-registra
# la URL aunque ya exista (idempotente: arregla registros viejos fallidos).
helm repo add --force-update secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update secrets-store-csi-driver >/dev/null

# LECCION ROOT-CAUSE (2026-10-05, incidente #4): el nombre del driver CSI
# registrado es secrets-store.csi.k8s.io (SIN "x-"); el sufijo x-k8s.io es
# del GRUPO API del CRD SecretProviderClass (apiVersion de la SPC), NO del
# driver. El chart SI crea su CSIDriver y el registro nace sano (logs del
# node-driver-registrar: PluginRegistered:true). Aqui existia un "PASO 2"
# que creaba un CSIDriver fantasma secrets-store.csi.x-k8s.io — eliminado.
echo "==> PASO 2. Secrets Store CSI Driver v${DRIVER_CHART_VERSION}"
echo "    syncSecret.enabled=true  -> secretObjects (sincroniza a Secret nativo de k8s)"
echo "    anotacion IRSA en el SA del propio chart (no creamos SA custom)"
if ! helm upgrade --install secrets-store-csi-driver secrets-store-csi-driver/secrets-store-csi-driver \
      --namespace "$DRIVER_NS" \
      --version "$DRIVER_CHART_VERSION" \
      --set syncSecret.enabled=true \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"; then
  echo "ERROR: fallo el install. Verifica versiones disponibles:"
  helm search repo secrets-store-csi-driver/secrets-store-csi-driver --versions | head -5
  echo "Ajusta DRIVER_CHART_VERSION en este script (pineado por leccion de drift)."
  exit 1
fi

echo "==> PASO 2b. Anotacion IRSA explicita en el SA del chart"
# Leccion (estilo vpcId del 2026-10-04): el --set de anotaciones anidadas es
# fragil; el annotate de kubectl es determinista e idempotente. Sin esta
# anotacion el provider no tiene identidad (GetParameter -> AccessDenied).
kubectl annotate sa secrets-store-csi-driver -n kube-system "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite

echo "==> PASO 3. AWS provider (DaemonSet: inyecta el binario del provider en cada pod del driver)"
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

echo "==> PASO 4. Verificacion de rollout + registro CSI por nodo"
kubectl rollout status ds/secrets-store-csi-driver -n "$DRIVER_NS" --timeout=180s
kubectl rollout status ds/csi-secrets-store-provider-aws -n "$DRIVER_NS" --timeout=120s
kubectl get pods -n "$DRIVER_NS" | grep -E "secrets-store-csi-driver|provider-aws" || true
# LECCION (incidente #4): listar SIN nombre — el nombre REAL del driver y su
# CSIDiver aparecen aqui; buscar un nombre a ojo (x-k8s.io vs k8s.io) fue lo
# que costo la hora de diagnostico.
echo "--- CSIDrivers registrados en el cluster:"
kubectl get csidrivers

echo "OK: driver + provider listos. Anotacion IRSA del SA:"
kubectl get sa secrets-store-csi-driver -n "$DRIVER_NS" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' && echo

echo "--- Registro CSI por nodo (node-driver-registrar):"
# Registrar v2.x: el exito se ve como NotifyRegistrationStatus con
# PluginRegistered:true (el literal "Registered plugin" es de versiones
# antiguas del sidecar y aqui NO existe).
kubectl logs -n "$DRIVER_NS" -l app=secrets-store-csi-driver -c node-driver-registrar --tail=3 --prefix 2>/dev/null \
  | grep -E "Registration Server started|NotifyRegistrationStatus" | tail -3 \
  || echo "AVISO: sin lineas de registro aun; revisa: kubectl logs -n kube-system -l app=secrets-store-csi-driver -c node-driver-registrar"
