# AWSSecretsSSM-CSI — Secretos nativos AWS: SSM Parameter Store + Secrets Store CSI Driver (Objetivo #4)

> **Sesión 2026-10-05** · Cuenta AWS real `053044806920` · `us-east-1` · Rama `feature-patron-appOfapps`
> Objetivo TFM #4: **cero secretos en Git** — credenciales que nacen en runtime (random_password → SSM SecureString), consumidas por el pod vía volumen CSI montado con identidad IRSA (patrón validado ayer con el LB Controller).
> Formato: igual que `AWSLoadBalancer-ControllerIRSA.md` (plan por bloques + registro cronológico §1.1 + troubleshooting + preguntas de jurado).

---

## Mapa de la cuenta antes de empezar (responde a "¿levanto todo lo de ayer?")

| Pieza | Estado | Hoy |
|---|---|---|
| Usuario `terraform-ci` + políticas (IAMForIRSA, ELBReadOnlyForGitOps) | **Permanente** | Solo verificar ($0). Se ampliará con statements SSM (PASO 5.0) |
| ECR (`sri-facturacion-service`), OIDC GitHub, rol `github-actions-ecr-push` | **Permanente** | Solo verificar ($0) |
| Cluster EKS (11 recursos) | Destruido ayer | **Reconstruir** (Fases 1–4) |
| OIDC provider del cluster + rol IRSA del LB Controller + ALB | Destruidos ayer | **NO se reconstruyen** (no hay Ingress hoy) |
| OIDC provider del cluster + rol IRSA para el **CSI driver** | No existe | **Nuevo módulo** `iac/aws/secrets-csi/` (el OIDC provider se crea aquí, patrón de ayer) |

## Costos del día (presupuesto aprobado: ~$0.45–0.70)

| Concepto | Tarifa | Hoy |
|---|---|---|
| EKS cluster | $0.225/h | ~2–2.5 h encendido ≈ $0.45–0.60 |
| SSM Parameter Store (Standard) | $0 (thousands gratis) | $0 |
| Secrets Store CSI Driver + AWS provider (pods en nodos) | $0 | $0 |
| Llamadas API (get/put parameters, CLI) | $0 (SSM tiered free) | $0 |
| ⛔ NO usar Secrets Manager | $0.40/secreto/mes | $0 (excluido por diseño) |

---

# BLOQUE 1 — Restaurar laboratorio (~25 min)

> Comandos idénticos al ensayo validado (`DEMO_AWS_GITOPS_JURADO.md`, Fases 0–4 + PASO 3.5). Aquí versión condensada.

## Fase 0 — Verificación permanente ($0)

```bash
aws sts get-caller-identity --query 'Arn' --output text
# → arn:aws:iam::053044806920:user/terraform-ci

aws ecr describe-repositories --repository-names sri-facturacion-service --query 'repositories[0].repositoryUri'
# → 053044806920.dkr.ecr.us-east-1.amazonaws.com/sri-facturacion-service

aws elbv2 describe-load-balancers --output text
# → VACÍO (ayer se cerró limpio; regla de oro verificada)

aws eks describe-cluster --name sri-eks-cluster --query 'cluster.status' --output text
# → ResourceNotFoundException (efímero muerto, listo para recrear)
```

## Fase 1 — Cluster (~8 min) 💰 $0.225/h desde aquí

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud/iac/aws
terraform init
terraform plan    # Esperado: 11 to add (siempre; state remoto vacío tras destroy)
terraform apply   # Esperado: 11 added (node group es lo lento, ~2-3 min)
```

## Fase 2 — kubeconfig + nodos ($0)

```bash
aws eks update-kubeconfig --name sri-eks-cluster --region us-east-1
kubectl get nodes    # Esperado: 3 Ready (t3.medium)
```

## Fase 3 — ArgoCD (~3 min, $0)

```bash
# Bootstrap MANUAL de plataforma (fuera de Terraform) — metodo de TODOS los
# guiones anteriores (DEMO_AWS_GITOPS_JURADO.md F3, GITOPS V2-AWS.md):
# manifold OFICIAL install.yaml, NO helm (corregido 2026-10-05: la version
# previa de este guion introdujo helm — desviacion del estandar del proyecto;
# la narrativa es bootstrap manual reproducible, sin releases helm flotantes).
# --server-side obligatorio: el CRD applicationsets supera los 256KB de la
# anotacion last-applied y el apply cliente falla.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl get pods -n argocd -w   # Esperado: 7 pods Running
```

## PASO 3.5 — metrics-server (obligatorio en EKS, $0; en AKS viene de fábrica)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get apiservice v1beta1.metrics.k8s.io   # Esperado: True (si no, esperar ~1 min)
```
> Lección del ensayo: sin esto, el HPA queda ciego y ArgoCD marca Degraded.

## Fase 4 — AppProject + Application (→ GitOps, $0)

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-aws-eks.yaml
# Verificar sync:
kubectl get application sri-facturacion-aws-eks -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'
# Esperado: Synced/Healthy (el overlay está en estado cierre: SIN Ingress — correcto, hoy no hay ALB)
curl -s localhost:5000/api/v1/version 2>/dev/null; kubectl port-forward -n sri-facturacion svc/sri-facturacion-service-svc 5000:5000 &
curl -s localhost:5000/api/v1/version
# → {"version":"7.0.0","cloud":"aws","cluster":"sri-eks-cluster",...}
```

---

# BLOQUE 2 — IRSA para el CSI driver + parámetros SSM (~45 min, $0)

## Fase 5 — Módulo `iac/aws/secrets-csi/` (material YA generado por el asistente)

| Archivo | Contenido |
|---|---|
| `main.tf` | Backend `aws/secrets-csi.tfstate` · OIDC provider del cluster (mismo patrón que lb-controller) · rol `sri-eks-cluster-secrets-csi` con **trust dual** (SA del pod `sri-facturacion-sa` + SA del driver como fallback — ver Bloque 3.5) · política desde `iam_policy.json` local (lección file() de ayer) · **3 parámetros SSM SecureString con `random_password`** |
| `variables.tf` | cluster_name, region, valores demo (DB_USER/DB_HOST con default no sensible; la contraseña **nace en runtime**) |
| `outputs.tf` | `secrets_csi_role_arn`, `oidc_provider_arn`, `parameter_names` (NUNCA valores) |
| `iam_policy.json` | `ssm:GetParameter(s)(ByPath)` scoped a `/sri-facturacion/*` + `kms:Decrypt` (llave administrada `aws/ssm`) |

**Decisión de diseño — el secreto nace en runtime:** `random_password` genera la contraseña en el apply → `aws_ssm_parameter` (SecureString) la guarda → el valor jamás pasa por Git. Único lugar donde existe además del SSM: el state (cifrado en S3 con `encrypt=true`).

## PASO 5.0 — Política terraform-ci ampliada (ROOT por consola web, patrón del PASO 5.0 de ayer) 💰 $0

> La policy no puede auto-editarse (el editor sería el editor de sí mismo). El JSON ya está actualizado en `iac/aws/policies/terraform-ci-policy.json` — copiar y pegar como nueva versión.

Statement nuevo (SSM para terraform-ci, con diagnóstico incluido):

```json
{
  "Sid": "SSMParametersForSecretsSession",
  "Effect": "Allow",
  "Action": [
    "ssm:PutParameter",
    "ssm:GetParameter",
    "ssm:GetParameters",
    "ssm:GetParametersByPath",
    "ssm:DescribeParameters",
    "ssm:DeleteParameter",
    "ssm:AddTagsToResource",
    "ssm:ListTagsForResource"
  ],
  "Resource": [
    "arn:aws:ssm:us-east-1:053044806920:parameter/sri-facturacion/*"
  ]
},
{
  "Sid": "SSMDiagnosticoGlobal",
  "Effect": "Allow",
  "Action": ["ssm:DescribeParameters"],
  "Resource": ["*"]
}
```
> Nota least-privilege: `PutParameter`/`DeleteParameter` admiten resource-level (scoped a `/sri-facturacion/*`); `DescribeParameters` NO → statement aparte con `Resource *`.

**Ruta en consola:** IAM → Policies → `terraform-ci-policy` → Permissions → Edit policy → JSON → pegar → **Save as new version** → marcar como default.

## Fase 5.1 — terraform apply del módulo (~2 min) 💰 $0

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud/iac/aws/secrets-csi
terraform init     # Esperado: backend aws/secrets-csi.tfstate + providers aws, tls, random
terraform plan     # Esperado: 7 to add (OIDC provider + rol + policy + attachment + 3 parámetros)
terraform apply    # Esperado: 7 added
terraform output -raw secrets_csi_role_arn   # → arn:...:role/sri-eks-cluster-secrets-csi
```

## Fase 6 — Driver + provider AWS vía script idempotente (mismo estilo que `bootstrap-lb-controller-eks.sh`) 💰 $0

```bash
bash scripts/bootstrap-secrets-csi-eks.sh
```
Qué hace (explicado antes de ejecutar — regla del operador):
1. **Guards**: `kubectl get nodes` (cluster vivo) · `command -v helm` · lee `role_arn` del state del módulo (output de Fase 5.1)
2. **Helm repo**: `secrets-store-csi-driver` (kubernetes-sigs)
3. **Driver**: `helm upgrade --install` con `syncSecret.enabled=true` (¡crítico para `secretObjects`!) y **anotación IRSA en el SA del propio chart** (`eks.amazonaws.com/role-arn`) — aquí no creamos SA custom: el chart gestiona el suyo
4. **Provider AWS**: manifest oficial `aws-provider-installer.yaml` (DaemonSet que inyecta el binario del provider en cada pod del driver)
5. **Verificación**: rollout del DaemonSet (3 pods = 3 nodos) + pods del driver

```bash
# Verificación manual posterior:
kubectl get ds -n kube-system   # secrets-store-csi-driver (3 desired) + csi-secrets-store-provider-aws
kubectl get pods -n kube-system | grep -E "secrets-store|provider-aws"
```

---

# BLOQUE 3 — El secreto real, montado en el pod (~30 min, $0)

## Fase 7.0 — Fixes del overlay (YA aplicados por el asistente)

| Fix | Archivo | Cambio |
|---|---|---|
| **#7a** | `deployment-secrets-patch.yaml` | `metadata.name` → `sri-facturacion-service-deployment` |
| **#7b (nuevo)** | ídem | **container** `name` → `sri-facturacion-service-deployment` (sin esto el SMP añadiría un 2º container) |
| **#7c (cierre #4-ter)** | `serviceaccount.yaml` **(nuevo)** + ídem patch | SA dedicado `sri-facturacion-sa` **anotado con el rol** (el provider lee ESA anotación — no la del driver) + `serviceAccountName` en el pod |
| SPC | `secrets-store-ssm.yaml` | `secretsmanager` + jmesPath → **`ssmparameter` ×3** (`/sri-facturacion/DB_*`), secretObjects intactos |
| Overlay | `kustomization.yaml` | Descomentar `- secrets-store-ssm.yaml` + el patch (indentación a nivel 0 — **regla de oro de ayer**) |

> **Incidente didáctico #0 (2026-10-05, pre-sesión):** el propio asistente volvió a cometer el bug de indentación de ayer (nuevo item de secuencia con 2 espacios vs nivel 0) al descomentar el patch — pero esta vez el **render local lo capturó** (`yaml: line 39: did not find expected key`) **antes de cualquier commit**. Diferencia con ayer: cero commits rotos, cero `sync=Unknown`, cero minutos perdidos. La regla de oro funciona cuando se ejecuta SIEMPRE — incluido por quien la escribió. Lección reforzada: la validación `kubectl kustomize` es parte de la entrega, no un paso del operador.

## Fase 7.1 — Regla de oro: render local ANTES de commit ($0)

```bash
kubectl kustomize gitops/overlays/aws-eks > /tmp/render-aws.yaml
grep -c "SecretProviderClass" /tmp/render-aws.yaml   # Esperado: ≥1
grep -c "sri-facturacion-service-deployment" /tmp/render-aws.yaml   # ≥2 (deployment + container)
grep -c "^kind: Deployment" /tmp/render-aws.yaml    # Esperado: 1 — ANCLADO a columna 0
# OJO: sin el ancla ^ da 2 y NO es bug (incidente didáctico 2026-10-05):
# el scaleTargetRef de hpa.yml contiene también la línea "    kind: Deployment"
# indentada (referencia al Deployment objetivo, no un recurso). El ancla valida
# además que no hay documentos extra (todos los kind reales van a columna 0).
```

## Fase 7.2 — Commit + push → ArgoCD sync

```bash
git add gitops/overlays/aws-eks/
git commit -m "feat(aws-eks): secretos SSM via CSI — fix bug #7 (names del patch) + SPC a ssmparameter"
git push
```

## Fase 7.3 — Verificación final (la demo del objetivo #4)

```bash
# (a) El Secret sincronizado por secretObjects:
kubectl get secret sri-facturacion-db -n sri-facturacion
# Esperado: Opaque con 3 claves

# (b) El volumen montado en el pod (trae archivos):
POD=$(kubectl get pods -n sri-facturacion -l app=sri-facturacion-service-deployment -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n sri-facturacion $POD -- ls /mnt/secrets-store/
# Esperado: DB_USER  DB_PASSWORD  DB_HOST

# (c) El env inyectado desde el Secret (envFrom → secretRef):
kubectl exec -n sri-facturacion $POD -- env | grep DB_
# Esperado: DB_USER, DB_PASSWORD, DB_HOST con los valores de SSM

# (d) AUDITORÍA — cero secretos en Git:
grep -ri "$(kubectl get secret sri-facturacion-db -n sri-facturacion -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" gitops/ app/ iac/ --include="*.y*ml" --include="*.tf" --include="*.py" || echo "LIMPIO: el secreto no existe en ningún archivo versionado"

# (e) La app sigue viva:
kubectl port-forward -n sri-facturacion svc/sri-facturacion-service-svc 5000:5000 &
curl -s localhost:5000/health
```

---

# BLOQUE 3.5 — SESIÓN 2: root cause del incidente #4-ter y cierre (💰 $0 sobre cluster vivo)

> **Root cause verificado (docs oficiales del provider AWS, installer v3.1.4):** el provider del CSI **no asume el rol con la identidad del driver**. Al montar, resuelve el rol leyendo la anotación `eks.amazonaws.com/role-arn` **del SA del POD que monta el volumen** (vía API de Kubernetes — el ClusterRole del installer da `get serviceaccounts` exactamente para eso) y lo asume con el **token proyectado de ese pod** (CSIDriver `tokenRequests`, aud `sts.amazonaws.com`) vía `sts:AssumeRoleWithWebIdentity`. El pod usaba el SA **`default` sin anotación** → rol irresoluble → `Failed to fetch parameters from all regions`. Evidencia: README oficial ("the provider lookups … the role ARN associated with the service account"), `ExampleDeployment-IRSA.yaml` (SA dedicado) y `ExampleSecretProviderClass-IRSA.yaml` (**sin `roleArn` en la SPC**).

## 3.5.1 — Fixes (aplicados en el repo antes de ejecutar)

| Fix | Archivo | Cambio |
|---|---|---|
| SA del pod | `gitops/overlays/aws-eks/serviceaccount.yaml` **(nuevo)** | SA dedicado `sri-facturacion-sa` anotado con `arn:aws:iam::053044806920:role/sri-eks-cluster-secrets-csi` |
| Pod → SA | `gitops/overlays/aws-eks/deployment-secrets-patch.yaml` | `serviceAccountName: sri-facturacion-sa` |
| Trust | `iac/aws/secrets-csi/main.tf` | sub del trust → `system:serviceaccount:sri-facturacion:sri-facturacion-sa` (+ driver como fallback legacy) |
| SPC | `gitops/overlays/aws-eks/secrets-store-ssm.yaml` | `region: "us-east-1"` explícita (recomendación oficial: fetch determinista) |
| Script | `scripts/bootstrap-secrets-csi-eks.sh` | 2ª audiencia `pods.eks.amazonaws.com` en tokenRequests (doc oficial; modo Pod Identity futuro) + comentarios de fallback |

## 3.5.2 — Ejecución (orden causal; el operador ejecuta)

```bash
# 0. Estado actual (solo lectura, $0): ¿cluster vivo? ¿módulo aplicado?
aws eks describe-cluster --name sri-eks-cluster --query 'cluster.status' --output text
aws ssm describe-parameters --query 'Parameters[?contains(Name, `sri-facturacion`)].Name' --output text
kubectl get pods -n sri-facturacion | head -6
cd iac/aws/secrets-csi && terraform plan    # Esperado: 1 to change (trust del rol)

# 1. Trust nuevo (si AccessDenied iam:UpdateAssumeRolePolicy persiste:
#    re-pegar la política del PASO 5.0 en consola, o terraform apply -replace="aws_iam_role.secrets_csi")
terraform apply

# 2. Overlay → render local (REGLA DE ORO) → commit → push (ArgoCD auto-sync + selfHeal)
cd ../../..   # volver a la raiz del repo (estabamos en iac/aws/secrets-csi)
kubectl kustomize gitops/overlays/aws-eks > /tmp/render-aws.yaml
grep -c "sri-facturacion-sa" /tmp/render-aws.yaml        # Esperado: ≥2 (SA + pod spec)
grep -c "kind: ServiceAccount" /tmp/render-aws.yaml      # Esperado: 1
grep -c "^kind: Deployment" /tmp/render-aws.yaml         # Esperado: 1 — anclado (sin ^: 2 por el scaleTargetRef del HPA)
git add gitops/overlays/aws-eks/ && git commit -m "fix(aws-eks): identidad del montaje CSI — SA dedicado anotado (root cause #4-ter)" && git push

# 3. ArgoCD sincroniza y el rollout reemplaza los pods atascados:
kubectl get pods -n sri-facturacion -w    # Esperado: nuevos pods → Running

# 4. Verificación Fase 7.3 (a)-(e) — el montaje ya debe completar
```

## 3.5.3 — Diagnóstico (si algo no cierra)

```bash
# Logs del provider (README oficial) y del driver (modo fusionado v3):
kubectl logs -n kube-system -l app=csi-secrets-store-provider-aws --tail=50
kubectl logs -n kube-system -l app=secrets-store-csi-driver -c secrets-store --tail=50
# Identidades en vivo:
kubectl get sa sri-facturacion-sa -n sri-facturacion -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
kubectl get pod -n sri-facturacion -o jsonpath='{.items[*].spec.serviceAccountName}'; echo
kubectl get csidriver secrets-store.csi.k8s.io -o jsonpath='{.spec.tokenRequests}'; echo
```

---

# BLOQUE 4 — Cierre FinOps (~15 min)

Orden (dependencias causales — regla de oro de ayer aplicada):

```bash
# 1. Revert overlay (SPC + patch vuelven a comentarse) → commit/push → ArgoCD prune
#    (asistente prepara el revert; los pods vuelven a la imagen sin volumen)
# 2. Destroy del módulo secrets-csi (requiere cluster vivo: data source del OIDC issuer)
cd iac/aws/secrets-csi && terraform destroy   # Esperado: 7 destroyed (incluye los 3 parámetros)
# 3. Destroy del cluster
cd ../ && terraform destroy                   # Esperado: 11 destroyed
# 4. Verificación de cierre ($0/h):
aws eks describe-cluster --name sri-eks-cluster --query 'cluster.status' --output text
# → ResourceNotFoundException
aws ssm describe-parameters --query 'Parameters[?contains(Name, `sri-facturacion`)].Name' --output text
# → vacío
```
> Los parámetros SSM no facturan ($0) — se destruyen por **reproducibilidad**, no por costo.

---

# §1.1 — Registro cronológico (se completa en vivo)

| # | Fase | Inicio | Fin | Estado | Notas / resultado real |
|---|---|---|---|---|---|
| 1. Fase 0 verificación | | | ⬜ | |
| 2. Fase 1 cluster | | | ⬜ | |
| 3. Fases 2-4 ArgoCD+app | | | ⬜ | |
| 4. PASO 5.0 política SSM (root) | | | ⬜ | |
| 5. Fase 5.1 módulo secrets-csi | | | ⬜ | |
| 6. Fase 6 driver+provider | | | ⬜ | |
| 7. Fase 7 overlay+commit | | | ⬜ | |
| 8. Fase 7.3 verificación secreto | | | ⬜ | |
| 9. Cierre FinOps | | | ⬜ | |

# Troubleshooting preventivo (incidentes probables de hoy)

| Síntoma | Causa probable | Fix |
|---|---|---|
| Pods en `ContainerCreating` eterno | Provider AWS no instalado o driver sin rollout completo | `kubectl describe pod` → eventos del volumen; verificar los 2 DaemonSets |
| `ls /mnt/secrets-store` vacío o error | `syncSecret.enabled=false` en el chart | Script usa `--set syncSecret.enabled=true`; verificar `kubectl get secretproviderclass` |
| `AccessDenied: ssm:GetParameter` en logs del provider | SA sin anotación IRSA o rol mal attachado | `kubectl describe sa secrets-store-csi-driver -n kube-system` → anotación `eks.amazonaws.com/role-arn` |
| `AccessDenied: kms:Decrypt` | Llave no administrada o permiso faltante | Verificar `aws ssm describe-parameters`; la key default `aws/ssm` cubierta por el statement KMS del módulo |
| `AccessDenied: ssm:ListTagsForResource` al crear parámetros | El provider reconcilia TAGS al crear `aws_ssm_parameter` — llamada invisible en el plan (incidente real Fase 5.1) | Añadir `ssm:ListTagsForResource` al statement SSM (ya en el repo) → re-aplicar PASO 5.0 → `terraform apply` de nuevo: solo crea lo faltante (los recursos IAM ya creados no se tocan) |
| `404 Not Found` al fetch del `index.yaml` del repo helm | El Pages de kubernetes-sigs migró el repo al subpath `/charts/` (incidente real Fase 6; `helm repo add` no valida la URL, el fallo salta en el update) | `helm repo add --force-update secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts` (fix ya en el script; v1.4.8 confirmada en el índice) |
| `AccessDenied: iam:UpdateAssumeRolePolicy` al cambiar el trust de un rol existente | Cambiar trust ≠ CreateRole: es una acción IAM aparte (incidente real Fase 5.1 bis) | Corto plazo: `terraform apply -replace="aws_iam_role.X"` (destruye y recrea con permisos existentes; mismo nombre → mismo ARN → anotaciones SA intactas). Largo plazo: `iam:UpdateAssumeRolePolicy` ya añadida al statement IAMForEKS del repo (aplicar en próxima pasada root) |
| `driver name ... not found in the list of registered CSI drivers` (FailedMount, ContainerCreating eterno) | **ROOT CAUSE REAL (incidente #4, resuelto): typo del NOMBRE del driver en el patch** — el driver registrado es `secrets-store.csi.k8s.io` (SIN `x-`); el sufijo `x-k8s.io` es del GRUPO API del CRD SPC, no del driver. El registro NUNCA estuvo roto: logs del node-driver-registrar mostraban `PluginRegistered:true` y el chart sí crea su CSIDriver. Todo el camino de recrear driver-pods/CSIDriver-manual persiguió el nombre equivocado | `driver: secrets-store.csi.k8s.io` en el volumen del patch (fix en aws Y azure) + borrar el CSIDriver fantasma `kubectl delete csidriver secrets-store.csi.x-k8s.io`. Lección: `kubectl get csidrivers` (SIN nombre) lista los drivers reales — lo habría revelado en 5s; los logs del registrar son el diagnóstico de 10s que era |
| `CSI token error: serviceAccount.tokens not provided - ensure tokenRequests is configured in CSIDriver spec` | **Capa federativa del mount (incidente #4-bis, 2026-10-05):** el CSIDriver default no pide tokens proyectados → el provider no recibe el token IRSA del SA del pod → no puede asumir el rol. El nombre del driver ya estaba resuelto (progreso de capa) | `helm upgrade --set tokenRequests[0].audience=sts.amazonaws.com --set tokenRequests[0].expirationSeconds=86400` (ya en el PASO 2 del script) → re-run del script (re-anota el SA) → recrear el pod atascado. Verificación: `kubectl get csidriver secrets-store.csi.k8s.io -o yaml | grep -A3 tokenRequests` |
| `Failed to fetch parameters from all regions` | **RESUELTO (incidente #4-ter; sesión 2 de cierre 2026-10-05): ROOT CAUSE = el provider AWS resuelve el rol leyendo la anotación `eks.amazonaws.com/role-arn` del SA DEL POD que monta el volumen (no del driver) vía API k8s, y lo asume con el token proyectado de ese pod. El pod usaba el SA `default` SIN anotación → rol irresoluble → AccessDenied en el fetch.** Evidencia: README oficial del provider ("the provider lookups … the role ARN associated with the service account"), ClusterRole del installer v3.1.4 con `get serviceaccounts`, y ejemplo IRSA oficial con SA dedicado + SPC SIN `roleArn` | Fix: SA dedicado `sri-facturacion-sa` anotado en el overlay + `serviceAccountName` en el patch del deployment + trust con su sub + `region` explícita en la SPC (ver Bloque 3.5). Diagnóstico: `kubectl logs -n kube-system -l app=csi-secrets-store-provider-aws --tail=50` (provider) y `-l app=secrets-store-csi-driver -c secrets-store` (driver/fusionado) |
| Pod nace pero Secret `sri-facturacion-db` no aparece | syncSecret off o rotación no disparada | El Secret se crea al primer montaje del pod; recrear pods si el driver se instaló después |
| ArgoCD `sync=Unknown` tras commit | ¡La lección de AYER! Render roto | `kubectl kustomize` local ANTES de pushear, siempre |

# 7 preguntas de jurado (sección de preparación)

1. **¿Por qué SSM Parameter Store y no Secrets Manager?** Standard tier es $0 (Secrets Manager $0.40/secreto/mes); el patrón de consumo (CSI + IRSA) es idéntico para ambos — decisión FinOps sin renunciar al patrón. Si el proyecto necesitara rotación automática nativa o cross-account, Secrets Manager entra como upgrade documentado.
2. **¿Por qué no HashiCorp Vault?** (→ ADR-003) Los almacenes nativos gestionados + patrón unificado de consumo; Vault self-hosted sería un servidor más que operar (HA, unseal, backups) con SPOF cross-cloud, desproporcionado para 1 equipo y 2 nubes. La portabilidad está en el patrón (CSI + identidad gestionada), no en el vendor.
3. **¿Dónde nace la contraseña y dónde vive?** En runtime (`random_password` en el apply) → SSM SecureString (cifrada at-rest con KMS `aws/ssm`). En Git: NUNCA (auditado con grep en Fase 7.3d). El state la contiene también — cifrado en S3; riesgo documentado y mitigado con `encrypt=true`.
4. **¿Qué identidades participan y qué puede leer cada una?** El SA **del pod de la app** (`sri-facturacion-sa`, anotado con el rol) es la identidad del montaje: el provider lee esa anotación vía API k8s y asume `sri-eks-cluster-secrets-csi` con el token proyectado del pod (IRSA + `tokenRequests`). El rol solo puede `GetParameter*` sobre `/sri-facturacion/*`. El SA del driver queda como fallback legacy. `terraform-ci` puede además Put/Delete sobre ese path. Root queda para lo privilegiado (editar políticas).
5. **¿Cómo llega el secreto al proceso?** Dos vías simultáneas: (a) volumen CSI montado como archivos (kubelet→provider gRPC→SSM); (b) `secretObjects` sincroniza a un Secret nativo que el pod consume vía `envFrom`. Ambas audibles por CloudTrail (`GetParameter` firmado por el rol IRSA).
6. **¿Qué pasa si roto el parámetro en SSM?** El volumen refleja el cambio en el próximo re-montaje (pods nuevos); el Secret nativo se sincroniza con la rotación del driver. Los pods existentes mantienen el valor viejo hasta recrearse — patrón 12-factor: roto → rollout.
7. **¿Cómo escala esto cuando el HPA agrega 10 pods?** Cada pod nuevo monta su volumen y el provider hace `GetParameter` con el rol IRSA — no hay pre-carga niSidecar compartido: el patrón escala horizontal sin cambios.

# Backlog post-sesión

- Simetría Azure: Key Vault + Workload Identity con Managed Identity (mismo overlay, provider azure)
- Monitoring kube-prometheus-stack (objetivo #6): el app ya expone `/metrics` (annotations listas en el base)
- Merge final a main: ADR-003 (nativos sobre Vault) + job CI de `kustomize build` de ambos overlays (hueco detectado ayer) + pinear versiones de charts
