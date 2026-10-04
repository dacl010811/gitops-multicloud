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
helm repo add argo https://argoproj.github.io/argo-helm   # si no está
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --server-side
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
| `main.tf` | Backend `aws/secrets-csi.tfstate` · OIDC provider del cluster (mismo patrón que lb-controller) · rol `sri-eks-cluster-secrets-csi` con trust al SA `kube-system:secrets-store-csi-driver` · política desde `iam_policy.json` local (lección file() de ayer) · **3 parámetros SSM SecureString con `random_password`** |
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
| SPC | `secrets-store-ssm.yaml` | `secretsmanager` + jmesPath → **`ssmparameter` ×3** (`/sri-facturacion/DB_*`), secretObjects intactos |
| Overlay | `kustomization.yaml` | Descomentar `- secrets-store-ssm.yaml` + el patch (indentación a nivel 0 — **regla de oro de ayer**) |

> **Incidente didáctico #0 (2026-10-05, pre-sesión):** el propio asistente volvió a cometer el bug de indentación de ayer (nuevo item de secuencia con 2 espacios vs nivel 0) al descomentar el patch — pero esta vez el **render local lo capturó** (`yaml: line 39: did not find expected key`) **antes de cualquier commit**. Diferencia con ayer: cero commits rotos, cero `sync=Unknown`, cero minutos perdidos. La regla de oro funciona cuando se ejecuta SIEMPRE — incluido por quien la escribió. Lección reforzada: la validación `kubectl kustomize` es parte de la entrega, no un paso del operador.

## Fase 7.1 — Regla de oro: render local ANTES de commit ($0)

```bash
kubectl kustomize gitops/overlays/aws-eks > /tmp/render-aws.yaml
grep -c "SecretProviderClass" /tmp/render-aws.yaml   # Esperado: ≥1
grep -c "sri-facturacion-service-deployment" /tmp/render-aws.yaml   # ≥2 (deployment + container)
grep -c "kind: Deployment" /tmp/render-aws.yaml     # Esperado: 1 (¡NO 2! si saliera 2, el patch creó un recurso)
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
| Pod nace pero Secret `sri-facturacion-db` no aparece | syncSecret off o rotación no disparada | El Secret se crea al primer montaje del pod; recrear pods si el driver se instaló después |
| ArgoCD `sync=Unknown` tras commit | ¡La lección de AYER! Render roto | `kubectl kustomize` local ANTES de pushear, siempre |

# 7 preguntas de jurado (sección de preparación)

1. **¿Por qué SSM Parameter Store y no Secrets Manager?** Standard tier es $0 (Secrets Manager $0.40/secreto/mes); el patrón de consumo (CSI + IRSA) es idéntico para ambos — decisión FinOps sin renunciar al patrón. Si el proyecto necesitara rotación automática nativa o cross-account, Secrets Manager entra como upgrade documentado.
2. **¿Por qué no HashiCorp Vault?** (→ ADR-003) Los almacenes nativos gestionados + patrón unificado de consumo; Vault self-hosted sería un servidor más que operar (HA, unseal, backups) con SPOF cross-cloud, desproporcionado para 1 equipo y 2 nubes. La portabilidad está en el patrón (CSI + identidad gestionada), no en el vendor.
3. **¿Dónde nace la contraseña y dónde vive?** En runtime (`random_password` en el apply) → SSM SecureString (cifrada at-rest con KMS `aws/ssm`). En Git: NUNCA (auditado con grep en Fase 7.3d). El state la contiene también — cifrado en S3; riesgo documentado y mitigado con `encrypt=true`.
4. **¿Qué identidades participan y qué puede leer cada una?** El SA `secrets-store-csi-driver` asume el rol `sri-eks-cluster-secrets-csi` (IRSA) que solo puede `GetParameter*` sobre `/sri-facturacion/*`. `terraform-ci` puede además Put/Delete sobre ese path. Root queda para lo privilegiado (editar políticas).
5. **¿Cómo llega el secreto al proceso?** Dos vías simultáneas: (a) volumen CSI montado como archivos (kubelet→provider gRPC→SSM); (b) `secretObjects` sincroniza a un Secret nativo que el pod consume vía `envFrom`. Ambas audibles por CloudTrail (`GetParameter` firmado por el rol IRSA).
6. **¿Qué pasa si roto el parámetro en SSM?** El volumen refleja el cambio en el próximo re-montaje (pods nuevos); el Secret nativo se sincroniza con la rotación del driver. Los pods existentes mantienen el valor viejo hasta recrearse — patrón 12-factor: roto → rollout.
7. **¿Cómo escala esto cuando el HPA agrega 10 pods?** Cada pod nuevo monta su volumen y el provider hace `GetParameter` con el rol IRSA — no hay pre-carga niSidecar compartido: el patrón escala horizontal sin cambios.

# Backlog post-sesión

- Simetría Azure: Key Vault + Workload Identity con Managed Identity (mismo overlay, provider azure)
- Monitoring kube-prometheus-stack (objetivo #6): el app ya expone `/metrics` (annotations listas en el base)
- Merge final a main: ADR-003 (nativos sobre Vault) + job CI de `kustomize build` de ambos overlays (hueco detectado ayer) + pinear versiones de charts
