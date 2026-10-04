# AWS Load Balancer Controller + IRSA — Exposición al mundo y pruebas de carga

> **Sesión:** 2026-10-03 · **Nube:** AWS (us-east-1) · **Cuenta:** 053044806920
> **Objetivo:** exponer el servicio del EKS al mundo vía ALB (capa 7) instalando el AWS Load Balancer Controller con identidad IRSA, y demostrar autoscaling real del HPA bajo carga.
> **Estado:** Documento vivo — se actualiza al cerrar cada bloque.

---

## 0. Qué demuestra esta sesión (la narrativa para el jurado)

Las demos anteriores probaron el **bucle GitOps interno** (commit → pipeline → ECR/ACR → ArgoCD → rollout), siempre accediendo al servicio por `kubectl port-forward` o `curl` interno. Hoy se cierra el círculo:

1. **Exposición al mundo:** el Ingress que ya existía comentado en `gitops/overlays/aws-eks/ingress.yaml` cobra vida. El ALB se provisiona **solo** porque instalamos el AWS Load Balancer Controller, y el controller puede actuar en AWS **solo** porque le dimos identidad mediante **IRSA** (IAM Roles for Service Accounts) — cero credenciales hardcodeadas, cero secretos en etcd.
2. **Precalentamiento del objetivo #4 (secretos):** IRSA es *exactamente* el mismo mecanismo que usará el Secrets Store CSI Driver para leer SSM Parameter Store (ADR-003). Hoy se demuestra el patrón con un caso simple; la sesión de secretos solo cambia el consumidor del rol.
3. **Autoscaling demostrado con datos reales:** hey → ALB → pods → HPA escala 3→10 delante del jurado, y vuelve a 3 solo. La escena más visual de la defensa.
4. **Simetría multi-cloud documentada:** este guion tiene su gemelo Azure pendiente (NGINX Ingress / AGIC) — se hará en sesión dedicada, una factura a la vez.

**Regla de la sesión:** una nube a la vez, una factura a la vez, y cada acción cloud anunciada con su costo.

---

## 1. Plan del día (4 bloques, ~2.5–3.5 h, presupuesto ~$1.3)

| Bloque | Contenido | Tiempo | Costo |
|---|---|---|---|
| **1** | Restaurar laboratorio: Fases 0–4 del ensayo (cluster, ArgoCD, metrics-server, Application Healthy) | ~25 min | EKS ~$0.225/h desde el apply |
| **2** | IRSA + AWS Load Balancer Controller + habilitar Ingress → ALB público | ~45–60 min | IAM $0 · ALB $0.0225/h + ~$0.01 LCU |
| **3** | Pruebas de carga con HPA en vivo (hey + umbral didáctico vía GitOps) | ~30–45 min | $0 (los pods caben en los 3 nodos) |
| **4** | Cierre FinOps: revertir Ingress → ALB destruido por el controller → 2 destroys → $0/h | ~20 min | $0 |

**Costos en juego (cuenta pay-as-you-go, us-east-1):**

| Recurso | Tarifa | Cuándo corre |
|---|---|---|
| Control plane EKS | $0.10/h | Del apply (B1) al destroy (B4) |
| 3 × t3.medium | ~$0.0416/h c/u (~$0.125/h) | Igual. ArgoCD, controller y app viven *dentro*: $0 extra |
| ALB | $0.0225/h + LCU (~$0.008/LCU-h) | Solo desde Fase 7 hasta que el Ingress se borra (B4) |
| Escalado HPA 3→10 pods | **$0** | 10 pods × 250m = 2.5 vCPU de las 6 disponibles: no crea nodos |
| Pipeline GitHub Actions | $0 | Minutos dentro del free tier |
| Data transfer de pruebas | ~$0.03 | `/health` devuelve ~200 B; despreciable |

**Con todo encendido: ~$0.37/h.** Escenario cumplido: **~$1.0–1.3 total**. Cada hora que el cluster sobreviva al cierre: +$0.37.

---

## 1.1 Registro cronológico (se llena en vivo durante la sesión)

| Fase | Hora | Duración | Resultado | Observaciones |
|---|---|---|---|---|
| 0. Verificación | | | ✅ COMPLETADA | helm v3.19.2 (tarball oficial; brew falló en iMac Intel) + hey v0.1.5 (Homebrew tras `sudo chown` fish); ab plan B · cuenta 053044806920 ✅ · ResourceNotFoundException (cero absoluto) ✅ · rama feature-patron-appOfapps up to date ✅ · working tree = solo cambios Bloque 2, sin commit ✅ |
| 1. Cluster EKS | | | ✅ COMPLETADA | plan "11 to add" ✅ → apply: 11 added (node group 2m49s), endpoint gr7.us-east-1 ✅ |
| 2. Acceso + nodos | | | ✅ COMPLETADA | update-kubeconfig OK (context gr7.us-east-1) + 3 nodos Ready v1.35.8-eks-3b4a6ca (~7m50s) |
| 3. ArgoCD + 3.5 metrics-server | | | ✅ COMPLETADA | 7/7 pods ArgoCD Running (0 restarts, ~5m30s) + metrics-server OK (top nodes: 1% CPU / ~14-15% mem) — HPA ya no estará ciego |
| 4. Application Healthy | | | ✅ COMPLETADA | Synced/Healthy a la primera (sin incidente HPA, gracias al 3.5) · 3 pods Running del RS 67dcd9c6b (imagen 7.0.0 = cierre del ensayo) |
| 5. IRSA (OIDC + rol) | | | ✅ COMPLETADA | PASO 5.0 (política ampliada vía web como root, statement IAMForIRSA) ✅ → apply: 4 added. Rol sri-eks-cluster-alb-controller + OIDC provider (su id = id del endpoint del cluster) + policy oficial v2.7.2 |
| 6. Helm: LB Controller | | | ✅ COMPLETADA | 1ª pasada: CrashLoopBackOff (chart v3.5.0 sin vpcId → IMDS inalcanzable desde pod) → fix en script (VPC por API + --set vpcId) → re-ejecución: rollout OK, 2 pods Running 1/1, RS 7474987bc7 |
| 7. Ingress → ALB | | | ✅ COMPLETADA | Push → ArgoCD sync → ADDRESS vacío → FailedBuildModel (ec2:DescribeRouteTables — drift policy v2.7.2 vs controller v3.5.0) → fix versionado → ALB k8s-srifactu-srifactu-a08031345f-58486945.us-east-1.elb.amazonaws.com |
| 8. Carga + HPA en vivo | | | ✅ COMPLETADA | Umbral 5% (tras fix de indentación c0b0748): escalada 3→7→10 con +2/60s, CPU convergiendo 53→33→29%; target group con 9-10 IPs de PODS healthy (target-type ip registrando al vuelo; verificado vía nueva política ELBReadOnly) |
| 9. Cierre FinOps | | | ✅ COMPLETADA | Revert overlay (2bf1b84) → prune del Ingress → controller BORRA el ALB → destroy lb-controller (4) → destroy cluster (11, cluster 3m43s) → ResourceNotFoundException + elbv2 VACÍO = regla de oro cumplida (cero ALB huerfanos). Cuenta a $0/h |

**BLOQUE 4 — Resultado real (2026-10-04):** el cierre ejecutó la secuencia exacta del plan: revert → prune (ALB eliminado por el controller, verificado con la política ELBReadOnly recién creada) → `terraform destroy` en lb-controller (4 destroyed) → `terraform destroy` en iac/aws (**11 destroyed**, cluster en 3m43s, lock liberado limpio) → verificaciones finales: `ResourceNotFoundException` + `describe-load-balancers` **vacío**.

---

## SELLO FINOPS Y REPRODUCIBILIDAD DE LA SESIÓN

- **Factura estimada:** ~$1.0–1.1 (EKS ~4h15m ≈ $0.96 + ALB ~1.5h ≈ $0.04 + LCU céntimos) — dentro del presupuesto anunciado en la apertura ($1.0–1.3).
- **Estado final de la cuenta:** $0/h. Todo lo efímero destruido en orden correcto; todo lo permanente verificado (ECR, OIDC GitHub, usuario terraform-ci con política ampliada: IAMForIRSA + ELBReadOnlyForGitOps).
- **Repo 100% reproducible** (levantar tal cual mañana): commits `7209747` (módulo IRSA completo + script bootstrap + IAMForIRSA) → `325386f` (+ DescribeRouteTables + ELBReadOnlyForGitOps) → `c0b0748` (fix indentación) → `2bf1b84` (revert del cierre). El guion completo de la sesión (este documento) quedó versionado como runbook.
- **Incidentes del día (todos convertidos en lección y fix versionado):** file() evaluado en plan (iam_policy.json provisionado local); chart v3.5.0 sin vpcId → IMDS inalcanzable desde pod (VPC por API en el script); drift política v2.7.2 vs controller v3.5.0 (ec2:DescribeRouteTables, nueva versión de policy); indentación de secuencia patches (regla: validar `kubectl kustomize` ANTES de cada commit; hueco CI registrado como mejora: step de build de overlays).
- **Precalentamiento del objetivo #4 (secretos):** la sesión dejó el patrón IRSA operativo de punta a punta (OIDC provider + rol + SA anotada + credenciales temporales validadas en runtime por el propio FailedBuildModel) — la sesión SSM + Secrets Store CSI Driver lo reutiliza cambiando el sujeto del trust.

### PRÓXIMA SESIÓN ACORDADA (elección del operador, cierre 2026-10-04): Secretos SSM + Secrets Store CSI Driver (objetivo #4)

- **Decisiones ya tomadas:** SSM Parameter Store **Standard** (gratis; NO Secrets Manager a $0.40/secreto/mes — lección FinOps); módulo nuevo `iac/aws/secrets-csi/` con backend/state propio (mismo patrón que `lb-controller`); script idempotente `scripts/bootstrap-secrets-csi-eks.sh` (driver + provider AWS, guards + verificación como el de hoy); política terraform-ci ampliada vía consola como **root** (PASO X.0, patrón del PASO 5.0: `ssm:GetParameter*`/`DescribeParameters` scoped a `/sri-facturacion/*` + permisos de versionado de policy).
- **Fix planificado en vivo:** bug #7 — `deployment-secrets-patch.yaml` con target `sri-facturacion-service` → `sri-facturacion-service-deployment` (lección de diagnóstico ya sembrada en el overlay).
- **Presupuesto aprobado:** ~$0.45–0.70 (solo EKS ~2 h encendido; sin ALB — nada facturable en SSM Standard ni en el driver).
- **Backlog subsiguiente (orden sugerido):** sesión gemela Azure (requiere decisión previa AGIC/AppGW ~$0.07/h vs nginx+LB Standard ~$0.0225/h) → monitoring kube-prometheus-stack (objetivo #6) → merge final a main con el job de validación `kustomize build` en CI (hueco detectado hoy).

---

## BLOQUE 1 — Restaurar el laboratorio (Fases 0–4)

> Son las Fases 0–4 del ensayo `DEMO_AWS_GITOPS_JURADO.md`, condensadas. Si algo falla, el diagnóstico detallado vive ahí.

### FASE 0 — Verificación (5 min, $0)

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
git status && git branch --show-current
aws sts get-caller-identity --query "Account" --output text
aws eks describe-cluster --name sri-eks-cluster --region us-east-1 2>&1 | head -2
helm version --short 2>/dev/null || echo "HELM NO INSTALADO"
command -v hey >/dev/null 2>&1 && echo "HEY INSTALADO" || echo "HEY NO INSTALADO"   # hey NO tiene flag -version
```

**Esperado:** cuenta `053044806920` · `ResourceNotFoundException` (cero absoluto) · rama de trabajo con los cambios del Bloque 2 ya en working tree (ver §B2-PREVIO) · **sin commits todavía**.
**Si HELM NO INSTALADO:** tarball oficial del CDN de Helm (`get.helm.sh`, darwin-amd64) movido a `/usr/local/bin` — local, $0, sin sudo ni brew. **Si HEY NO INSTALADO:** Go + `go install github.com/rakyll/hey@latest` (local, $0) — o usamos `ab`, ya incluido en macOS.

**Resultado real (sesión 2026-10-03):** ambos NO instalados en la iMac → `brew install helm hey` **falló** (dirs `/usr/local/share/fish` no escribibles + Intel Tier 3 sin bottles). Resolución mixta, verificada en la máquina:

- **helm — sin brew:** tarball oficial v3.19.2 (darwin-amd64) → binario directo en `/usr/local/bin` (escribible sin sudo). Pineado v3 porque este guion usa sintaxis v3 (Helm ya va por v4).
- **hey — vía brew:** `sudo chown -R admin /usr/local/share/fish /usr/local/share/fish/vendor_completions.d` corrigió el bloqueo y el reintento completó: Cellar `hey 0.1.5`, `/usr/local/bin/hey` es symlink. hey no publica binarios en GitHub releases (el viejo jblabs devuelve 404): brew o Go son las únicas rutas.

```bash
# Verificación final (ojo: hey NO tiene flag -version — daría falso "NO INSTALADO")
helm version --short     # obtenido: v3.19.2+g8766e71
command -v hey           # obtenido: /usr/local/bin/hey (symlink → ../Cellar/hey/0.1.5/bin/hey)
hey 2>&1 | head -1       # obtenido: Usage: hey [options...] <url>
```

Local y sin costo. Plan B sin instalar nada: `ab -t 120 -c 50 -H "Host: api.sri.ec.gob.ec" "http://$ALB/health/"` (ApacheBench ya viene en macOS). Es la única pausa del Bloque 1.

**Confirmado en vivo (sesión 2026-10-03):** `aws sts get-caller-identity` → `053044806920` ✅ · `aws eks describe-cluster` → `ResourceNotFoundException: No cluster found for name: sri-eks-cluster` ✅ (cero absoluto, igual que los ensayos previos).

**git status confirmado (fase CERRADA ✅):** rama `feature-patron-appOfapps` (up to date con origin) · modified: `ingress.yaml` + `kustomization.yaml` · untracked: guion, `hpa-patch.yaml`, `iac/aws/lb-controller/` · **sin commits** y sin archivos sensibles en el árbol. Dato de sesión: el CWD ya era `iac/aws` (los paths salieron relativos `../../`), punto exacto donde arranca la Fase 1.

### FASE 1 — Provisión del EKS (~10 min, $0.225/h desde aquí)

```bash
cd iac/aws
terraform init
terraform plan      # Esperado: Plan: 11 to add
terraform apply
```

**Al jurado:** "Mismo módulo agnóstico que en Azure; el plan lo audito antes de aplicar."

**Resultado real (sesión 2026-10-03):** plan confirmado `Plan: 11 to add, 0 to change, 0 to destroy`. Apply: **`Apply complete! Resources: 11 added`** — node group en 2m49s (vs 1m58s del ensayo, misma magnitud), endpoint `https://46E8FD8C848441D915C2683B8D4D8074.gr7.us-east-1.eks.amazonaws.com`, outputs íntegros. Contador ~$0.225/h corriendo.

### FASE 2 — Acceso (2 min, $0)

```bash
aws eks update-kubeconfig --region us-east-1 --name sri-eks-cluster
kubectl get nodes   # 3 Ready
```

**Resultado real (sesión 2026-10-03):** `Updated context arn:aws:eks:us-east-1:053044806920:cluster/sri-eks-cluster in ~/.kube/config` ✅ · **3 nodos Ready** `v1.35.8-eks-3b4a6ca` (ip-172-31-0-21 / ip-172-31-40-156 / ip-172-31-85-33, ~7m50s) ✅ — terraform-ci entró por su access entry de creador (`bootstrap_cluster_creator_admin_permissions`), cero fricción.

### FASE 3 — ArgoCD + PASO 3.5 metrics-server (5 min, $0)

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd            # 7 Running (~3 min)

# PASO 3.5 — OBLIGATORIO en EKS (en AKS viene de fábrica; sin esto el HPA queda
# ciego (ScalingActive: False) y ArgoCD reporta Degraded con los pods sanos:
# incidente documentado en la demo AWS, §Fase 4)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top nodes                     # 3 nodos con CPU%/MEMORY%
```

**Resultado real (sesión 2026-10-03):** 7/7 pods ArgoCD `Running` con **0 restarts** (~5m30s; en el ensayo dex-server arrancó con restarts — esta vez limpio). metrics-server recolectando: `top nodes` muestra ~1% CPU / ~14–15% mem en los 3 nodos ✅. Con la API `metrics.k8s.io` viva, el HPA puede decidir y la Fase 4 no repetirá el incidente Degraded del ensayo.

### FASE 4 — Application Synced/Healthy (3 min, $0)

```bash
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-aws-eks.yaml
kubectl get application -n argocd
# Esperado: Synced / Healthy / revision del overlay aws-eks
```

**Resultado real (sesión 2026-10-03):** AppProject + Application creadas (los warnings de finalizer no domain-qualified son cosméticos de ArgoCD, inofensivos). Primera lectura `Synced/Progressing` → **segunda lectura `Synced/Healthy`** ✅ a la primera, sin incidente — el PASO 3.5 hizo su trabajo. 3 pods `Running` del ReplicaSet **`67dcd9c6b`**: el MISMO RS con que cerró el ensayo del 2026-10-02 (imagen 7.0.0 producida por el pipeline dual-cloud). *La app que despliega el cluster hoy nació del cierre de la demo Azure — la matriz dual-cloud en un `get pods`.* (Typo menor del operador: `- ` suelto dio NotFound; `-w` lo corrigió.)

**Nota:** el overlay sigue teniendo el `ingress.yaml` **comentado** hasta la Fase 7. Por eso Healthy llega sin controller instalado (la lección del comentario TEMPORAL del kustomization).

---

## BLOQUE 2 — IRSA + AWS Load Balancer Controller + ALB

### B2-PREVIO — Qué ya está preparado en el working tree (hecho por el asistente, $0)

Tres piezas, **sin commit** (el commit es parte de la Fase 7):

1. **`iac/aws/lb-controller/`** — root module Terraform nuevo, con su propio state (`aws/lb-controller.tfstate`): crea el **OIDC provider IAM** del cluster (el módulo del cluster no lo crea), el **rol IAM** `sri-eks-cluster-alb-controller` con trust policy de `sts:AssumeRoleWithWebIdentity` condicionada al ServiceAccount `kube-system/aws-load-balancer-controller`, y adjunta la política oficial del controller. Estado separado = destruible de forma independiente en el cierre.

   **Persistencia (pregunta de jurado probable):** el lb-controller es **EFÍMERO**, a diferencia del registry ECR. Regla: *"si su trust apunta al cluster, muere con el cluster"* — la raíz de este módulo es el OIDC provider cuyo emisor es propiedad del cluster; el registry ECR (`prevent_destroy = true`) es de cuenta y sobrevive porque el pipeline lo necesita sin cluster. El state separado no da persistencia, da **independencia de destrucción**. El OIDC de GitHub y el rol de push son permanentes porque su sujeto es GitHub Actions, no el cluster: *"permanente se verifica; efímero se reconstruye"*.
2. **Fix del BUG del Ingress** (`gitops/overlays/aws-eks/ingress.yaml`): el backend apuntaba a `sri-facturacion-service`, pero el Service real es **`sri-facturacion-service-svc`** — el ALB habría quedado con target group vacío (404 eterno). Misma familia del bug #7 (`deployment-secrets-patch.yaml` apuntaba a un Deployment inexistente). Además: `listen-ports` reducido a `[{"HTTP":80}]` — el 443 sin certificado ACM solo generaría un listener TLS con cert por defecto; HTTPS queda declarado como deuda documentada.
3. **`kustomization.yaml` del overlay**: `- ingress.yaml` **descomentado** (el comentario TEMPORAL se actualiza: hoy ES la sesión dedicada).

### FASE 5 — IRSA: OIDC provider + rol IAM (~10 min, $0)

**PASO 5.0 — Ampliación de la política least-privilege (previo, ~5 min, $0):** auditoría con grep a `iac/aws/policies/terraform-ci-policy.json` hecha ANTES del apply: `terraform-ci` tenía `CreateRole/AttachRolePolicy` pero faltaban `iam:CreateOpenIDConnectProvider` e `iam:CreatePolicy` — el apply habría caído en AccessDenied a los segundos (la política evoluciona por descubrimiento de flujos, misma lección que los access entries de 2026-09-27). Cambio ya aplicado en el repo (fuente de verdad): nuevo statement **`IAMForIRSA`** (OIDC provider scoped a `oidc.eks.us-east-1.amazonaws.com/*` + policy `AWSLoadBalancerControllerIAMPolicy` con su ciclo de versiones) y el rol `sri-eks-cluster-alb-controller` añadido al statement `IAMForEKS`. **Aplicación como root por consola IAM** (método probado en sesiones previas): IAM → Usuarios → `terraform-ci` → Permisos → `terraform-ci-policy` → Editar → pestaña JSON → pegar el contenido del archivo → Revisar política → Guardar cambios. Esperar ~30 s de propagación. Este cambio se commitea junto al de la Fase 7.

```bash
cd iac/aws/lb-controller
curl -fsSL -o iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
wc -l iam_policy.json    # ~240 líneas: la política OFICIAL del proyecto, no la inventamos

terraform init
terraform plan           # Esperado: 4 to add (oidc_provider, role, policy, attachment)
terraform apply
terraform output irsa_role_arn
```

**Incidente de secuencia (sesión 2026-10-03):** el primer `terraform plan` falló con `Invalid function argument ... no file exists at "./iam_policy.json"` — `file()` se evalúa durante el **plan** (no en el apply) y el `curl` no había dejado el archivo (salto de paso / red local en ese momento). Fix aplicado: el asistente provisionó `iam_policy.json` localmente con el contenido oficial v2.7.2 (243 líneas) y se verificó cruzado contra el repo upstream con `curl + diff` (idéntico). Lección: **todo archivo referenciado por `file()` debe existir ANTES del plan**; provisionar artefactos upstream con resiliencia, no en el momento crítico que depende de la red del operador. Confusión posterior del operador (mismo incidente): se creyó que `path.module` no funcionaba y se pegó una copia manual en `iac/aws/policies/` (eliminada) — lección: **`path.module` siempre apunta al directorio del módulo, y los artefactos referenciados por `file()` viven junto al `main.tf` que los usa** (cohesión local del módulo; un módulo Terraform debe ser autocontenido).

**Qué decir al jurado:** "IRSA es federación de identidades: el cluster expone un emisor OIDC; IAM confía en ese emisor *solo* para el ServiceAccount nombrado. El pod recibe credenciales temporales vía `AssumeRoleWithWebIdentity` — jamás hay Access Keys en el cluster. Este es el mismo patrón que usará el driver de secretos con SSM: hoy precalentamos el objetivo #4."

```bash
# Verificación de lectura ($0): el rol NO es asumible por usuarios, solo por el SA
aws iam get-role --role-name sri-eks-cluster-alb-controller \
  --query "Role.AssumeRolePolicyDocument.Statement[0]" --output json
```

**Resultado real (sesión 2026-10-03):** PASO 5.0 confirmado por el operador (política ampliada aplicada desde la consola web como root) — el statement `IAMForIRSA` funcionó, **cero AccessDenied**. Apply: **`4 added, 0 changed, 0 destroyed`**: OIDC provider (nota didáctica: su id `46E8FD8C848441D915C2683B8D4D8074` es el MISMO id del hostname del API endpoint del cluster — el emisor OIDC es el propio control plane), rol `sri-eks-cluster-alb-controller`, política `AWSLoadBalancerControllerIAMPolicy`. Costo: $0 (IAM es gratuito).

### FASE 6 — Helm: instalar el controller (~5 min, $0) — AUTOMATIZADA vía script

Todo el bloque manual vive ahora en `scripts/bootstrap-lb-controller-eks.sh` (idempotente, mismo patrón que los `bootstrap-*.sh` del proyecto: guards, pasos numerados, reejecutable). La Fase 6 entera es **un comando**:

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
bash scripts/bootstrap-lb-controller-eks.sh
```

Qué hace el script, bloque a bloque (la explicación antes de ejecutar):

| Bloque | Comando clave | Por qué |
|---|---|---|
| **0. Guards** | `kubectl get nodes` · `command -v helm` · `terraform output -raw irsa_role_arn` (en subshell: tu CWD no cambia) | Fallar rápido con mensaje claro antes de tocar nada: cluster alcanzable, helm presente, rol IRSA ya aplicado en `iac/aws/lb-controller` |
| **1. ServiceAccount** | `kubectl create sa --dry-run=client -o yaml \| kubectl apply -f -` + `kubectl annotate --overwrite` | Crea la SA si falta (idempotencia pura: render → apply) y anota el ARN del rol. `--overwrite` permite reejecutar |
| **2. Repo** | `helm repo list \| grep -q eks \|\| helm repo add` + `helm repo update` | Registra `eks-charts` solo si no estaba; refresca el índice |
| **3. Install** | `helm upgrade --install` | **La clave de la automatización**: instala si no existe, actualiza si existe — reejecutable sin errores |
| **4. Verificación** | `kubectl rollout status --timeout=180s` + `get pods` | Espera al Deployment sano y muestra las 2 réplicas (HA por defecto) |

**Por qué `serviceAccount.create=false`:** el chart NO crea la ServiceAccount — espera una ya existente, para no pisar la anotación de rol que controlamos nosotros. Por eso el script la crea y anota ANTES del helm.

**Esperado al final:** `deployment "aws-load-balancer-controller" successfully rolled out` + 2 pods Running. **Si los logs mostraran `WebIdentityErr`/`AccessDenied`:** propagación IAM pendiente → `kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system` y esperar 30 s.

**Incidente real (sesión 2026-10-03/04):** los 2 pods quedaron en `CrashLoopBackOff`. Logs: `unable to initialize AWS cloud: failed to get VPC ID ... ec2imds: GetMetadata ... context deadline exceeded`. Causa: el chart resolvió el controller **v3.5.0**, y sin `vpcId` explícito su auto-descubrimiento intenta leer la **EC2 Instance Metadata (IMDS)** — que **no responde desde dentro del pod** (timeout). Fix: el script obtiene la VPC por API (`aws eks describe-cluster --query cluster.resourcesVpcConfig.vpcId`, lectura $0) y la pasa como `--set vpcId` — determinista, sin IMDS. **Lección doble:** (1) para un componente que corre como pod, los values explícitos vencen al auto-descubrimiento basado en metadata de instancia; (2) re-ejecutar el script idempotente aplicó el fix con un simple `helm upgrade` — la automatización pagó su primera deuda en la misma sesión. Matiz para producción: el chart no está pineado (toma la última versión del repo); en el estado final del TFM se pinea `targetRevision` igual que las Applications de ArgoCD.

**Resultado real (Fase 6):** tras el fix `vpcId`, una sola re-ejecución del script → `successfully rolled out`, 2 pods Running 1/1 (RS 7474987bc7, 0 restarts). Dato para la Fase 7: el workflow CI **no se dispara** con este commit (trigger paths: `app/**` y el propio workflow únicamente) — solo ArgoCD reaccionará al Ingress.

**Decisión de diseño (pregunta de jurado probable):** ¿por qué el controller no vive bajo ArgoCD como el Ingress? Mismo criterio que ArgoCD mismo y metrics-server: el gestor y sus prerrequisitos de plataforma se bootstrapean (script idempotente versionado); lo que vive en Git son los **objetos deseados** (la app y su Ingress). El show GitOps del día es el ALB naciendo de un commit.

### FASE 7 — Habilitar el Ingress → el ALB nace (~10 min, ALB $0.0225/h desde aquí)

**Incidente real (sesión 2026-10-03/04) — el segundo mejor momento del día:** tras el push, el Ingress se sincronizó pero el ADDRESS no apareció. Los eventos del Ingress (`FailedBuildModel`) y los logs del controller mostraron: `couldn't auto-discover subnets ... UnauthorizedOperation ... User: arn:aws:sts::053044806920:assumed-role/sri-eks-cluster-alb-controller/... is not authorized to perform: ec2:DescribeRouteTables`. Dos joyas en un solo error: (1) el usuario del error es el **assumed-role IRSA** — la Fase 5 quedó validada de punta a punta por el propio runtime (OIDC → trust policy → credenciales temporales STS funcionando en producción); (2) causa raíz: **drift de versiones** — el chart "latest" resolvió controller v3.5.0 (ago-2026), que clasifica subnets públicas/privadas leyendo **route tables**, permiso que la política oficial v2.7.2 no traía porque esa generación de controller no lo usaba. Fix declarativo: `ec2:DescribeRouteTables` añadido a `iam_policy.json` + `terraform apply` en `iac/aws/lb-controller` (crea una **nueva versión** de la policy `AWSLoadBalancerControllerIAMPolicy` — exactamente para esto el PASO 5.0 ya incluía `iam:CreatePolicyVersion`). El controller reintenta el reconcile solo con su backoff exponencial: en ~1–3 min aparece el ADDRESS sin tocar nada más. **Lección de oro para el jurado:** en least-privilege, un AccessDenied es la especificación exacta del permiso que falta; y política IAM + versión de controller deben evolucionar **en conjunto** (en producción: chart pineado + política del mismo release).

**Resultado real (Fase 7):** tras el apply (1 changed: nueva versión de policy, sin re-attach — el attachment apunta a la policy, no a la versión) + `rollout restart` del controller, el ADDRESS apareció: **`k8s-srifactu-srifactu-a08031345f-58486945.us-east-1.elb.amazonaws.com`**. Verificación funcional: `/health` → `healthy` y `/api/v1/version` → `{"version":"7.0.0","cloud":"aws","cluster":"sri-eks-cluster"}`; repitiendo el curl, el `hostname` **alterna entre pods** (`-dvtdh` → `-5v6jj`) — el ALB balancea a las IPs de los pods directo (`target-type: ip`), y el fix del service name heredado quedó probado (sin él: 404 eternos). Gap detectado en el cross-check: terraform-ci carecía de `elasticloadbalancing:Describe*` (AccessDenied en `describe-load-balancers`) — tercera evolución least-privilege del día, fix preparado en `iac/aws/policies/terraform-ci-policy.json` (statement `ELBReadOnlyForGitOps`; Resource `*` obligatorio porque las Describe* de ELB no admiten resource-level permissions), a aplicar como root antes de la verificación de cierre del Bloque 4. **BLOQUE 2 COMPLETO: IRSA + controller + ALB en vivo, todo por GitOps.** El ALB factura $0.0225/h desde su nacimiento. Verificación post-fix de la tercera política: `aws elbv2 describe-load-balancers` (AccessDenied antes) → tabla con el ALB `application/active` — `ELBReadOnlyForGitOps` propagada a terraform-ci.

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
git add gitops/overlays/aws-eks/ iac/aws/lb-controller/ scripts/bootstrap-lb-controller-eks.sh iac/aws/policies/terraform-ci-policy.json
git status   # AUDITORÍA: NO terraform.tfstate.local (estado local) · SÍ iam_policy.json (artefacto versionado que exige file() — cohesión del módulo)
git commit -m "feat(aws-eks): habilita Ingress ALB — fix service name + IRSA para LB Controller"
git push
```

**Por qué UN solo commit:** el fix del bug + la habilitación + la IaC del rol viajan juntos por el mismo pipeline que ya usamos (el chart NO va al repo: es herramienta, no deseado — decisión documentada en §Preguntas).

```bash
# ArgoCD auto-sync lo aplica solo; observar el nacimiento del ALB:
kubectl get ingress sri-facturacion-ingress -n sri-facturacion -w
# Esperar hasta que ADDRESS aparezca (~1–2 min: el controller lo provisiona)

ALB=$(kubectl get ingress sri-facturacion-ingress -n sri-facturacion \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$ALB"    # k8s-srifacturacion-xxx.us-east-1.elb.amazonaws.com

# El Ingress define host: api.sri.ec.gob.ec. Sin DNS público real, simulamos el
# dominio con el header Host (el routing de capa 7 es idéntico al de producción):
curl -s -H "Host: api.sri.ec.gob.ec" "http://$ALB/health"
curl -s -H "Host: api.sri.ec.gob.ec" "http://$ALB/api/v1/version"
```

**Esperado:** JSON de `/health` con hostname de pod, y `/api/v1/version` con `"cloud": "aws"`, `"cluster": "sri-eks-cluster"` — **servido desde internet, por DNS público, con GitOps y cero kubectl sobre la app.**

**Frase para el jurado:** "En producción, ese DNS es un CNAME de `api.sri.ec.gob.ec` hacia el ALB, con cert ACM en el 443 que hoy declaramos como deuda. La ruta completa —internet → ALB → target group ip → pods— la creó un reconcile de ArgoCD."

**Verificación en consola AWS:** EC2 → Load Balancers: 1 ALB `k8s-srifacturacion...`, scheme internet-facing, 2 AZ. Target group: 3 targets healthy (target-type **ip**: los pods directos, sin salto por NodePort).

---

## BLOQUE 3 — Pruebas de carga con HPA en vivo (~30–45 min, $0 adicional)

**Incidente de secuencia (sesión 2026-10-04) — bug del asistente + regla de oro del render local:** al descomentar el `hpa-patch.yaml` en el kustomization, el asistente mantuvo la indentación de 2 espacios del bloque comentado (`  - path:`) mientras el item hermano `configmap-patch` vive a nivel 0 (`- path:`). YAML rechaza items de una misma secuencia con indentaciones distintas → `kubectl kustomize` falló con `yaml: line 29: did not find expected key`, el commit `325386f` subió el overlay roto y ArgoCD quedó en `sync=Unknown` con `rev` mostrando el branch sin SHA resuelto (no puede hacer build del render). Síntoma en vivo: el HPA seguía en 70% pese al push. Fix: reindentar el item a nivel 0. **Lecciones triples:** (1) *validar el render local (`kubectl kustomize <overlay>`) antes de CADA commit de manifiestos* — la convención existía y aquí se cumplió a la inversa: el error se descubrió después del push; (2) **hueco del pipeline**: el workflow CI solo valida `app/**` (pytest), así que un commit que rompe el render GitOps pasó sin job — mejora registrada para el merge final: step de `kustomize build` de ambos overlays; (3) el `sync=Unknown` de ArgoCD es la firma de "el render no compila": ante un Unknown, el primer comando es el build local, no el cluster.

### El problema honesto (por qué existe el PASO C.1)

La app solo expone endpoints `async` baratos (`/health`, `/api/v1/version`): su CPU por request es despreciable. Con el umbral del HPA al **70% de 250m**, ninguna carga de `hey` va a escalar los pods. Dos caminos:

- **Camino A (intento honesto):** carga agresiva `hey -z 120s -c 200`. Casi seguro no escala. Se intenta primero: demuestra criterio.
- **Camino B (PASO C.1, el didáctico):** bajar el umbral CPU a **5% vía GitOps** (patch JSON6902 en el overlay, commit → sync). Con carga modesta el HPA escala 3→10 delante del jurado, **y además demuestra el bucle GitOps operando sobre la infra de runtime**. Al cierre se revierte.

### Terminal 1 — la carga

```bash
ALB=$(kubectl get ingress sri-facturacion-ingress -n sri-facturacion \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
hey -z 120s -c 50 -H "Host: api.sri.ec.gob.ec" "http://$ALB/health"
# hey reporta al final: código 200 en todo, latencias, rps
```

### Terminal 2 — el HPA y los pods (la escena)

```bash
kubectl get hpa -n sri-facturacion -w
# TARGETS pasa de 2%/70% a >70%/70% bajo carga
kubectl get pods -n sri-facturacion -w
# 3 → 5 → 7 → 9 → 10 pods (+2 por minuto: behavior.scaleUp)
```

**Escalado esperado con PASO C.1:** 3→10 en ~4 min; **vuelta a 3:** ~7 min después de cortar la carga (scaleDown: 1 pod/2 min tras estabilización de 300s). Planificar la narrativa con esos tiempos.

### PASO C.1 — Umbral didáctico vía GitOps (solo si el Camino A no escaló)

El patch ya está diseñado en el working tree como `gitops/overlays/aws-eks/hpa-patch.yaml` + entrada en `patches:` del kustomization (JSON6902 sobre `/spec/metrics/0/resource/target/averageUtilization`: 70 → 5; índice 0 = CPU, orden de `hpa.yml` base):

```bash
git add gitops/overlays/aws-eks/hpa-patch.yaml gitops/overlays/aws-eks/kustomization.yaml
git commit -m "chore(aws-eks): umbral HPA didactico 70->5 para demo de carga [skip ci]"
git push        # dispara tests pero NO rebuild de imagen
kubectl get hpa -n sri-facturacion -w     # ArgoCD aplica el patch en <2 min
# Repetir hey: ahora TARGETS supera 5% y el HPA escala
```

**Qué decir al jurado:** "El ajuste de umbral no fue un `kubectl patch` que se pierde: fue un commit. GitOps también gobierna la configuración de autoscaling."

---

## BLOQUE 4 — Cierre FinOps (~20 min, vuelta a $0/h)

**Orden estricto (cada paso tiene una razón):**

1. **Revertir el umbral didáctico** (si se usó): commit que quita el patch o lo vuelve a 70.
2. **Deshabilitar el Ingress** (commit que vuelve a comentar `- ingress.yaml` en el kustomization, o revert del commit de la Fase 7). ArgoCD (prune) borra el Ingress → **el controller borra el ALB automáticamente** (~2 min). Es la regla de oro: *el ALB es propiedad del Ingress; el Ingress se va, el ALB se va.*
3. **Verificar ALB muerto:**
   ```bash
   aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text
   # VACÍO. Si algo apareciera: aws elbv2 delete-load-balancer --load-balancer-arn <arn>
   ```
4. **Destroy del lb-controller ANTES que el cluster** (el state lee el cluster como data source; sin cluster vivo el plan/destroy falla):
   ```bash
   cd iac/aws/lb-controller
   terraform destroy    # 4 destroyed: attachment, policy, role, oidc_provider
   ```
5. **Destroy del cluster:**
   ```bash
   cd ../aws
   terraform destroy    # 11 destroyed (~3–4 min según ensayo)
   ```
6. **Verificación final $0/h:**
   ```bash
   aws eks describe-cluster --name sri-eks-cluster --region us-east-1 2>&1 | head -1
   aws elbv2 describe-load-balancers --output text | wc -l    # 0
   aws iam list-open-id-connect-providers    # sin el del cluster
   ```

**Costo de este bloque: $0** (los destroys no cobran; el ALB cobra horas parciales ya consumidas ~$0.05).

---

## 2. Datos de plataforma de la sesión

| Dato | Valor |
|---|---|
| Cuenta / región | 053044806920 / us-east-1 |
| Cluster | `sri-eks-cluster` (k8s 1.35, 3 × t3.medium, VPC default) |
| Namespace app | `sri-facturacion` |
| Service | `sri-facturacion-service-svc` :80 → pods :5000 (puerto named `http`) |
| Ingress | `sri-facturacion-ingress` (ALB internet-facing, target-type ip) |
| Controller | `aws-load-balancer-controller` (Helm chart eks/aws-load-balancer-controller, ns kube-system) |
| Rol IRSA | `sri-eks-cluster-alb-controller` + política `AWSLoadBalancerControllerIAMPolicy` |
| State nuevo | S3 `sri-gitops-tfstate`, key `aws/lb-controller.tfstate` |
| HPA | min 3 / max 10 · CPU 70% (mem 80%) · +2 pods/min, −1 pod/2min |
| Umbral didáctico | CPU 5% (overlay AWS, revertido al cerrar) |

---

## 3. Preguntas de jurado (ensayadas)

1. **¿Por qué IRSA y no una Access Key en el cluster?** Las claves rotan, se filtran y habitan en etcd. IRSA da credenciales temporales de STS a un único ServiceAccount: least privilege sin secretos.
2. **¿Qué se federó exactamente?** IAM confía en el emisor OIDC del cluster (el OIDC provider que creamos hoy) condicionado al `sub` del ServiceAccount. Ni un pod de otro namespace, ni un usuario humano pueden asumir ese rol.
3. **¿Por qué `target-type: ip` y no `instance`?** Con ip, el target group apunta a los pods directamente (ruteo kube-proxy interno): balanceo fino, sin el salto extra del NodePort, y coherente con CNI nativo.
4. **¿El ALB muere si el controller muere?** No. El ALB es un recurso de ELB; el controller solo lo reconcilia. Matar los pods del controller no tumba el ALB (probarlo en vivo es un buen extra: `kubectl delete pod -n kube-system -l ...` y el curl sigue respondiendo).
5. **¿Cómo decide el HPA escalar y por qué tardó eso?** Resource metrics v2 (CPU/mem contra requests). El behavior fija ritmo: +2 pods/min para subir (anti-thrash), estabilización 300s y −1 pod/2min para bajar. Lo que el jurado vio en la curva son esas políticas, no caprichos.
6. **¿Por qué el ALB no quedó huérfano tras el destroy?** Porque destruimos en orden: primero el Ingress (su dueño), el controller borra el ALB, verificado con `describe-load-balancers` vacío. Destroy al revés = EIP/LB fantasma cobrando (anti-patrón FinOps).
7. **¿Qué tiene esto que ver con el objetivo #4 (secretos)?** Todo: el Secrets Store CSI Driver consumirá SSM con un rol IRSA idéntico. Hoy demostramos el mecanismo; la sesión de secretos solo cambia el cliente del rol.

---

## 4. Troubleshooting esperado

| Síntoma | Causa probable | Fix |
|---|---|---|
| `EntityAlreadyExists` en el apply de la Fase 5 | Política `AWSLoadBalancerControllerIAMPolicy` ya existe de un intento previo | `terraform import aws_iam_policy.lb_controller <arn>` o renombrar |
| El ADDRESS del Ingress no aparece | SA sin anotación de rol (logs del controller: `WebIdentityErr`) | Rehacer Fase 6: anotar SA + rollout restart |
| Curl al ALB devuelve 404 | Header `Host` no coincide con la regla (`api.sri.ec.gob.ec`) | `curl -H "Host: api.sri.ec.gob.ec" ...` — es la demostración, no un error |
| HPA no escala ni con PASO C.1 | ArgoCD no ha aplicado el patch aún | `kubectl get application -n argocd` · esperar sync (<2 min) |
| `targetgroupbinding` en logs: `unable to find...` | BUG del service name (apuntaba a `sri-facturacion-service`) | Ya corregido en working tree; confirmar el fix commiteado |

---

*Documento vivo: se actualiza al cerrar cada fase de la sesión. Estado: PREPARADO — Fases 0–9 pendientes.*
