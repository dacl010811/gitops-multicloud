# GITOPS V2 — Sesión AWS EKS: Simetría Multi-Nube del Flujo GitOps

**Fecha:** 23 de septiembre de 2026
**Rama de trabajo:** `feature-patron-appOfapps`
**Cluster:** `sri-eks-cluster` (EKS, us-east-1, k8s 1.31, 3× t3.medium)
**Cuenta:** AWS real 053044806920 (IAM user `terraform-ci`)
**Objetivo:** replicar el flujo GitOps validado en AKS sobre EKS — cerrar la simetría multi-nube del TFM
**Resultado:** `Synced / Healthy` a la primera + demo commit v1→v2

---

## 1. Resumen ejecutivo

| | Azure AKS (22 sep) | AWS EKS (23 sep) |
|---|---|---|
| Synced/Healthy | Tras 6 bugs y debugging largo | **A la primera** |
| Demo commit v1→v2 | ✅ | ✅ |
| Env vars | `production / azure` | `production / aws` |
| Evidencia UI | `diagramas/2_ArgoCD_Synced_Healthy_AKS.png` | `diagramas/3_ArgoCD_Synced_Healthy_EKS.png` |

**La moraleja del proyecto:** los 6 fixes de la sesión AKS se aplicaron en el `base/` compartido, y el overlay `aws-eks` los heredó — por eso EKS fue un paseo. *Corregir una vez en el base, heredar en todas las nubes.*

Bonus del día: el side-quest de la consola AWS derivó en dominar el **puente IAM↔RBAC de EKS** (3 capas de autorización), material fuerte para la defensa.

---

## 2. Preparación del repo (antes de tocar el cluster)

Validación mental previa: `kubectl kustomize gitops/overlays/aws-eks` (render local sin cluster).

| Archivo | Cambio | Razonamiento |
|---|---|---|
| `gitops/argocd/application-aws-eks.yaml` | `targetRevision: main` → `feature-patron-appOfapps` | La rama feature concentra los fixes; main está atrás |
| `gitops/overlays/aws-eks/kustomization.yaml` | Ingress ALB y `secrets-store-ssm.yaml` **pausados** (nota TEMPORAL) | Sin AWS Load Balancer Controller el ALB nunca se provisiona → `Progressing` eterno (misma lección que AGIC en Azure). Sin SSM CSI Driver, el SecretProviderClass rompe el sync |
| ↑ | `deployment-secrets-patch.yaml` pausado | Depende del CSI Driver. **Bug latente #7 detectado**: su target apuntaba a `sri-facturacion-service`, pero el Deployment real es `sri-facturacion-service-deployment` → jamás matchearía. Anotado para corregir al restaurarlo |
| ↑ | `images:` → `hashicorp/http-echo:latest` | Imagen pública de prueba; el nombre lógico matchea gracias al fix del transformer del día anterior |
| ↑ | Parche `deployment-test-command-patch.yaml` añadido | Imagen de prueba necesita args para servir texto en :5000 |
| `gitops/overlays/aws-eks/deployment-test-command-patch.yaml` | **Nuevo** — solo `args` | Lección AKS: un `command` sobreescribiría el entrypoint de la imagen → `RunContainerError` |

Commits realizados:
```bash
# Cierre de la fase Azure
git commit -m "docs: cierre fase Azure GitOps - documento sesion, screenshot evidencia, fix destroy RG"
# Preparación EKS
git commit -m "feat(gitops): prepara overlay aws-eks para primer flujo GitOps..."
git push origin feature-patron-appOfapps
```

---

## 3. Provisionamiento del cluster (terraform apply)

```bash
cd iac/aws
terraform apply        # ~15-20 min
```

**Las 5 fases del apply:**

| Fase | Recurso | Duración |
|---|---|---|
| 1 | IAM rol control plane + attachment `AmazonEKSClusterPolicy` | ~10-30 s |
| 2 | `aws_eks_cluster` — control plane | ~10-15 min (el tramo largo) |
| 3 | Regla SG 443 (`api_access_cidrs` = CIDR VPC por defecto) | instantáneo |
| 4 | IAM rol nodos + 3 policy attachments | ~30 s |
| 5 | `aws_eks_node_group` — 3× t3.medium | ~2-8 min |
| | **Total: `Apply complete! Resources: 9 added`** | |

**Comparativa operativa AKS vs EKS (pregunta de jurado segura):**

| | AKS | EKS |
|---|---|---|
| Duración apply | ~5 min | ~15-20 min (control plane + node group secuenciales) |
| Credenciales | Service Principal + `ARM_*` | IAM user keys (`~/.aws`) |
| Backend de estado | Storage Account (Azure) | S3 `sri-gitops-tfstate` + `use_lockfile` |
| kubeconfig | `az aks get-credentials` | `aws eks update-kubeconfig` |
| metrics-server | **Incluido** | **Manual** |
| Costo control plane | $0/h (free tier) | $0.10/h |
| Costo 3 nodos | ~$0.29/h (D2s_v3) | ~$0.13/h (t3.medium) |

**Verificación:**
```bash
aws eks update-kubeconfig --region us-east-1 --name sri-eks-cluster
kubectl get nodes
# 3× Ready   v1.31.14-eks-a887778
```

---

## 4. metrics-server — la diferencia operativa #1 de EKS

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server
kubectl top nodes     # CPU/memoria en vivo por nodo
```

**Nota de diseño:** en clusters autogestionados (kubeadm) metrics-server suele requerir `--kubelet-insecure-tls` (kubelets con certs autofirmados). En **clusters gestionados (EKS/AKS) NO hace falta** — los kubelet tienen certificados válidos. El manifiesto oficial funciona tal cual.

**Por qué importa:** el HPA del `base/` (`autoscaling/v2`, min 3 / max 10) consume métricas de CPU vía metrics-server. Sin este paso, el HPA existe pero no escala.

---

## 5. ⭐ El puente IAM↔RBAC de EKS (la lección estrella del día)

### 5.1 El síntoma

La consola web mostraba el cluster **Activo** y el node group, pero la pestaña **Informática** fallaba con `Unauthorized`. Paradoja: `kubectl get nodes` funcionaba perfecto desde la Mac.

### 5.2 El concepto: DOS planos de autorización independientes

| Plano | Controlado por | Qué veía la consola |
|---|---|---|
| **API de AWS** (metadatos del servicio) | IAM (policy de terraform-ci) | Cluster Activo, node group ✅ |
| **API de Kubernetes** (nodos, pods, recursos) | **RBAC dentro del cluster** | `Unauthorized` ❌ |

La consola no ejecuta kubectl por ti: las pestañas de recursos llaman al API server de Kubernetes con el ARN de tu identidad de consola. Si ese ARN no está mapeado en el mecanismo de autenticación del cluster, el API server rechaza — aunque tengas todos los permisos IAM del mundo.

### 5.3 ¿Por qué kubectl funcionaba?

El **principal que crea el cluster** recibe automáticamente una access entry con `AmazonEKSClusterAdminPolicy` (modo `API_AND_CONFIG_MAP`). `terraform-ci` creó el cluster → su entrada existe → kubectl entra como `system:masters`.

La consola, en cambio, estaba en sesión **root** (`dacl010812`) — identidad distinta, sin mapeo. **Diagnóstico clave:** comparar `aws sts get-caller-identity` (CLI) con la identidad de la esquina superior derecha de la consola.

### 5.4 Las 3 capas del fix (en orden de aparición)

| # | Error | Capa que faltaba | Solución |
|---|---|---|---|
| 1 | Consola `Unauthorized` | RBAC: root sin access entry | `create-access-entry` + `associate-access-policy` (root + `AmazonEKSClusterAdminPolicy`, scope cluster) |
| 2 | `AccessDenied: eks:CreateAccessEntry` | IAM: la policy least-privilege no tenía esas acciones | Statement `EKSRBACAccessEntries` en `terraform-ci-policy.json`. **Detalle fino:** el recurso es de tipo `access-entry` (ARN `arn:aws:eks:...:access-entry/<cluster>/<principal>//*`), distinto de `cluster/*` — un `eks:*` sobre cluster jamás lo cubriría |
| 3 | `InvalidRequestException: auth mode must be API or API_AND_CONFIG_MAP` | El cluster estaba en modo `CONFIG_MAP` (legacy aws-auth) | `aws eks update-cluster-config --name sri-eks-cluster --access-config authenticationMode=API_AND_CONFIG_MAP` (~5-10 min, sin downtime) + **formalizado en el módulo** (`access_config` en `aws_eks_cluster`) |

**Secuencia completa (después de las 3 capas resueltas):**
```bash
aws eks update-cluster-config --name sri-eks-cluster \
  --access-config authenticationMode=API_AND_CONFIG_MAP

aws eks create-access-entry --cluster-name sri-eks-cluster \
  --principal-arn arn:aws:iam::053044806920:root
aws eks associate-access-policy --cluster-name sri-eks-cluster \
  --principal-arn arn:aws:iam::053044806920:root \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

aws eks list-access-entries --cluster-name sri-eks-cluster
```

**El listado final muestra las 4 identidades del sistema:**
```
arn:aws:iam::...:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS  ← servicio
arn:aws:iam::...:role/sri-eks-cluster-eks-node-role                                   ← NODOS (así se autentican al unirse)
arn:aws:iam::...:root                                                                 ← consola (agregada hoy)
arn:aws:iam::...:user/terraform-ci                                                    ← creador (auto)
```

### 5.5 Demo pedagógica involuntaria

`aws iam get-user-policy --user-name terraform-ci ...` → `AccessDenied`. La credencial **no puede ni leer sus propios permisos**: least-privilege real — una credencial de CI comprometida no puede escalar privilegios ni inventariar sus alcances.

### 5.6 Nota de seguridad (para Security Considerations)

Trabajar como root en consola es anti-patrón. Arquitectura limpia documentada:

| Identidad | Rol | Uso |
|---|---|---|
| root | Emergencias únicamente | Cerrar sesión, olvidar |
| `terraform-ci` | Programática, least-privilege | Terraform/CLI, sin password de consola |
| `darwin-console` (pendiente crear) | Humana admin | Consola diaria + access entry |

Producción: formalizar `aws_eks_access_entry` + `aws_eks_access_policy_association` en Terraform (ya está formalizado el auth mode; las entradas quedan como mejora).

---

## 6. ArgoCD (instalación idéntica a AKS)

```bash
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w     # 7/7 Running (~2-3 min)
```

El apply cliente falla por el CRD `applicationsets` (>256KB de anotación `last-applied-configuration`) → server-side apply gestiona el estado en el servidor sin esa anotación; `--force-conflicts` resuelve el field-manager tras una instalación previa cliente.

*(El warning del finalizer `resources-finalizer.argocd.argoproj.io` es cosmético — finalizer propio de ArgoCD.)*

---

## 7. Bootstrap GitOps y el Synced/Healthy a la primera

```bash
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-aws-eks.yaml
kubectl get application -n argocd sri-facturacion-aws-eks -w
```

```
sri-facturacion-aws-eks   Synced   Degraded   ← pods arrancando (transitorio, segundos)
sri-facturacion-aws-eks   Synced   Healthy    🎯
```

**Por qué a la primera (vs 6 bugs en AKS):** los fixes del día anterior viven en el `base/` compartido — extensiones `.yml`, `configMapKeyRef` en MAYÚSCULAS, transformer `images:` con nombre lógico, args-only en la imagen de prueba — y el overlay `aws-eks` llegó ya inmunizado (ingress y secrets-store pausados, misma estrategia que AGIC/KeyVault).

---

## 8. Verificación funcional

```bash
kubectl get pods -n sri-facturacion        # 3× 1/1 Running
kubectl port-forward -n sri-facturacion svc/sri-facturacion-service-svc 8080:80

curl http://localhost:8080                 # → GitOps SRI OK - flujo validado en EKS  (¡la RAÍZ, no /health!)
kubectl get configmap -n sri-facturacion sri-facturacion-config \
  -o jsonpath='{.data.ENVIRONMENT}{" / "}{.data.CLOUD_PROVIDER}'   # → production / aws
```

**Lección reutilizada de AKS:** `http-echo` tiene endpoint `/health` NATIVO que responde `{"status":"ok"}` (diseñado para probes). El `-text` se sirve en la raíz `/`.

---

## 9. Demo GitOps pura — el commit mueve el cluster (v1→v2)

```bash
# 1. Editar gitops/overlays/aws-eks/deployment-test-command-patch.yaml
#    - "-text=GitOps desde AWS SRI OK V2 por Darwin Calle - flujo validado en EKS"

git add gitops/overlays/aws-eks/deployment-test-command-patch.yaml
git commit -m "demo: GitOps v2 en EKS via repo (sin kubectl)"
git push origin feature-patron-appOfapps

# 2. Refresh inmediato (o esperar el poll ~3 min de ArgoCD)
kubectl -n argocd annotate application sri-facturacion-aws-eks \
  argocd.argoproj.io/refresh=hard --overwrite

# 3. Prueba de fuego
curl http://localhost:8080
```

**Resultado:**
```
v1: GitOps SRI OK - flujo validado en EKS
v2: GitOps desde AWS SRI OK V2 por Darwin Calle - flujo validado en EKS   ← solo git push
```

---

## 10. Costos de la sesión

| Concepto | Monto |
|---|---|
| Control plane EKS (~2h) | ~$0.20 |
| 3× t3.medium (~2h) | ~$0.25 |
| EBS 3× 20 GB gp3 | ~$0.01 |
| CloudWatch Logs (5 tipos habilitados) | ~$0.02 |
| **Total sesión AWS** | **~$0.50** ✅ |
| metrics-server, ArgoCD, access entries, update-cluster-config | $0 (corren en lo ya pagado / sin cargo) |

**Lección FinOps acumulada:** Azure costó ~$5.00 (sesión de debugging larga, cluster ~13h vivo); AWS costó ~$0.50 (sesión express ~2h, fixes heredados). Mismo resultado, **10× menos costo** — la diferencia no fue la nube, fue la madurez del pipeline.

---

## 11. 🎓 Preguntas probables del jurado (y sus respuestas)

**P: "¿Por qué el flujo funcionó a la primera en AWS después de los problemas en Azure?"**
R: Los 6 bugs corregidos vivían en el `base/` compartido de Kustomize (extensiones de archivo, keys del ConfigMap, matching del transformer `images:`, args vs command de la imagen de prueba, ingress sin controller, secrets sin CSI). El overlay aws-eks los heredó al compartir ese base — demostración empírica del valor del diseño base/overlay.

**P: "¿Por qué la consola de AWS mostraba el cluster pero daba Unauthorized en los nodos?"**
R: EKS tiene dos planos de autorización: la API de AWS (IAM) y la API de Kubernetes (RBAC interno). Los metadatos del servicio usan IAM; las pestañas de recursos llaman al API server de Kubernetes, que exige un mapeo IAM→RBAC (access entry). IAM te deja llegar a la puerta; RBAC te deja entrar.

**P: "¿Qué diferencia hay entre aws-auth ConfigMap y access entries?"**
R: aws-auth es el mecanismo legacy (modo CONFIG_MAP); los access entries son el mecanismo moderno gestionado por la API de EKS (modos API / API_AND_CONFIG_MAP), auditables, y con AWS-managed policies como AmazonEKSClusterAdminPolicy. Requieren el modo de autenticación adecuado en el cluster — nuestro cluster nació en CONFIG_MAP y hubo que actualizarlo (update-cluster-config, un solo sentido).

**P: "Su usuario CI pudo modificar su propia policy, ¿no es eso un riesgo?"**
R: No pudo. Precisamente la demo del día: terraform-ci carece de iam:PutUserPolicy — ni siquiera puede LEER sus propios permisos (aws iam get-user-policy → AccessDenied). La policy solo la modifica root desde la consola. Una credencial CI comprometida no puede escalar privilegios.

**P: "¿Por qué metrics-server manual en EKS y no en AKS?"**
R: Es una decisión del proveedor: AKS lo preinstala (managed addon por defecto); EKS lo deja como componente opcional. Mismo repo, diferencia operativa por nube — absorbida documentándola en el runbook.

**P: "¿Qué pasa si dejan el cluster encendido una semana?"**
R: ~$0.24/h × 168h ≈ $40. Por eso el backend remoto de estado (S3 con lockfile) es crítico: permite `terraform destroy`/`apply` reproducibles en minutos, haciendo barato destruir en pausas y recrear. Además k8s 1.31 entra a soporte extendido el 25 nov 2026 (~$0.60/h extra por cluster) — hay que documentar el upgrade path.

**P: "¿Cómo harían esto en producción con 10 equipos?"**
R: Lo que hicimos manual (access entry por identidad) se formaliza en Terraform (aws_eks_access_entry + association) versionado en el mismo repo; ArgoCD con AppProjects por equipo, RBAC de ArgoCD por grupo, y las Applications hijas gestionadas por el patrón App-of-Apps (el root-app.yaml ya existe en el repo para el estado final).

---

## 12. Estado final y pendientes

**Validado tras esta sesión:** simetría multi-nube completa (EKS + AKS con GitOps end-to-end) · puente IAM↔RBAC dominado (3 capas) · métricas en consola · demo commit en ambas nubes.

**Pendiente:**
1. Screenshot UI ArgoCD EKS → `diagramas/3_ArgoCD_Synced_Healthy_EKS.png`
2. Commit: `terraform-ci-policy.json` (EKSRBACAccessEntries) + `main.tf` módulo (`access_config`) + overlay aws-eks (demo v2)
3. `terraform destroy` (cierre de factura)
4. Sesión siguiente (opciones): imagen real en ECR (~$0.10/mes en repos) · secretos SSM Parameter Store + Secrets Store CSI Driver + IRSA · AWS LB Controller para el ingress · patrón App-of-Apps completo con root-app.yaml
5. Crear usuario IAM dedicado para consola (reemplazar uso de root)
6. Merge final a `main` + `targetRevision` de vuelta

---

## 13. Runbook rápido (recrear la sesión desde cero)

```bash
# --- 0. Repo (rama feature con fixes) ---
git checkout feature-patron-appOfapps && git pull

# --- 1. Cluster ---
cd iac/aws && terraform apply            # ~20 min
aws eks update-kubeconfig --region us-east-1 --name sri-eks-cluster
kubectl get nodes                        # 3× Ready

# --- 2. Auth moderna (una sola vez por cluster) ---
aws eks update-cluster-config --name sri-eks-cluster \
  --access-config authenticationMode=API_AND_CONFIG_MAP
# ... esperar ACTIVE, luego (opcional, para consola):
aws eks create-access-entry --cluster-name sri-eks-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT>:root
aws eks associate-access-policy --cluster-name sri-eks-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT>:root \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

# --- 3. Componentes del cluster ---
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# --- 4. Bootstrap GitOps ---
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-aws-eks.yaml
kubectl get application -n argocd sri-facturacion-aws-eks -w   # → Synced/Healthy

# --- 5. Cierre ---
cd iac/aws && terraform destroy
```
