# GITOPS V2 — Sesión Azure AKS: Primer Flujo GitOps End-to-End

**Fecha:** 22-23 de septiembre de 2026
**Rama de trabajo:** `feature-patron-appOfapps`
**Cluster:** `sri-aks-cluster` (AKS, eastus, k8s 1.37, 3× Standard_D2s_v3)
**Alcance elegido:** Solo flujo GitOps (imagen pública de prueba; sin ACR, sin Key Vault, sin AGIC)

---

## 1. Resumen ejecutivo

Se validó el **primer flujo GitOps completo** del proyecto sobre un cluster AKS real:

```
git push → GitHub → ArgoCD → Kustomize (overlay azure-aks) → AKS → pods Running
```

**Evidencia final:** el texto de respuesta de la app cambió de `v1` a `v2` **solo con un commit**, sin tocar `kubectl`. La Application quedó en `Synced / Healthy` con 4 recursos gestionados (ConfigMap, Service, Deployment, HPA).

Además del objetivo principal, la sesión dejó **6 bugs latentes corregidos** que habrían roto el demo ante el jurado, y lecciones de diagnóstico de Kubernetes en las 3 capas de fallo de pods.

---

## 2. Relanzamiento del cluster AKS

El storage del backend (`sritfstate23c5`) sobrevivió al destroy anterior, por lo que **no hubo bootstrap**: estado ya existente en `sri-tfstate-rg`.

```bash
# 1. Login del Service Principal (terminal nuevo)
az login --service-principal \
  --username "f50eded8-ffef-4864-8e08-b62ab0ed18bf" \
  --password "<PASSWORD>" \
  --tenant "0fc1436e-05f9-416b-9d88-a108f4a1133b"

# 2. Credenciales para Terraform (el provider azurerm las lee por convención)
export ARM_CLIENT_ID="f50eded8-ffef-4864-8e08-b62ab0ed18bf"
export ARM_CLIENT_SECRET="<PASSWORD>"
export ARM_TENANT_ID="0fc1436e-05f9-416b-9d88-a108f4a1133b"
export ARM_SUBSCRIPTION_ID="23c5c742-7e58-48a5-8131-697efc71a366"

# 3. Apply directo (el plan implícito del apply + confirmación "yes" es suficiente
#    cuando el cambio es solo de valores y la estructura ya fue validada)
cd iac/azure
terraform apply        # ~5 min — 1 recursos: AKS

# 4. Verificación
az aks get-credentials --resource-group sri-aks-rg --name sri-aks-cluster --overwrite-existing
kubectl get nodes      # 3× Ready, v1.37.0
```

**Hallazgo a favor:** AKS trae `metrics-server` instalado por defecto (2 réplicas Running) → el HPA quedó habilitado sin instalar nada. Se verificó con `kubectl top nodes` (6-9% CPU, ~1GB/8GB por nodo).

---

## 3. Preparación del repo — 3 bugs latentes de Kustomize

Antes de tocar el cluster, el overlay se validó localmente con `kubectl kustomize gitops/overlays/azure-aks` (render sin cluster). Aparecieron 3 defectos dormidos (el flujo nunca se había ejecutado end-to-end):

| # | Bug | Síntoma que habría causado | Fix aplicado |
|---|---|---|---|
| 1 | `bases/kustomization.yaml` referenciaba `deployment.yaml`/`service.yaml`/`hpa.yaml` pero los archivos reales son `.yml` | `kustomize build` falla de inmediato | Corregidas las extensiones en `resources:` |
| 2 | Overlay incluía `secrets-store-csi.yaml` (CRD inexistente sin CSI Driver) + placeholders `<ACR_NAME>`, `<MANAGED_IDENTITY_CLIENT_ID>` | Sync fallido / recursos rotos | Recurso y parche **pausados** con nota `TEMPORAL` (sesión dedicada a secretos los restaura) |
| 3 | `bases/deployment.yml` declaraba la imagen como URL completa (`ghcr.io/tu-usuario/...`) | El transformer `images:` de los overlays **nunca matcheaba** → la imagen real nunca se habría desplegado (afectaba también a `aws-eks`) | Imagen con **nombre lógico** `sri-facturacion-service:latest` en el base; cada overlay la redirige a su registry |

**Cambios de configuración del entorno:**

- `gitops/argocd/application-azure-aks.yaml`: `targetRevision: main` → `feature-patron-appOfapps` (main estaba 6+ commits atrás; al mergear el TFM, volver a `main`).
- Repo GitHub verificado **público** → ArgoCD clona sin credenciales.
- Imagen de prueba: `hashicorp/http-echo:latest` + nuevo parche `deployment-test-command-patch.yaml` (args `-listen=:5000 -text=...`).

Validación del render: 5 recursos (ConfigMap, Service, Deployment, HPA, Ingress), `image: hashicorp/http-echo:latest` ✅.

---

## 4. Instalación de ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**Error conocido:** `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes`.

- **Causa:** `kubectl apply` cliente guarda la anotación `last-applied-configuration`; el CRD de ApplicationSet la supera (256KB).
- **Fix:** server-side apply (el servidor gestiona el estado, sin anotación gigante):

```bash
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

(`--force-conflicts` necesario por el conflicto de field-managers con la primera corrida cliente.)

**Resultado:** 7 pods `Running` (application-controller, applicationset-controller, dex-server, notifications-controller, redis, repo-server, server).

---

## 5. Bootstrap GitOps

```bash
kubectl apply -f gitops/argocd/project.yaml              # AppProject sri-facturacion
kubectl apply -f gitops/argocd/application-azure-aks.yaml
```

Application arrancó `Synced` (ArgoCD clonó, renderizó y creó los recursos) pero `Degraded` — comenzó el debugging en vivo.

---

## 6. Debugging en vivo — las 3 capas de fallo de pods

La sesión regaló un catálogo completo de diagnóstico. Kubernetes falla en 3 capas distintas:

| Error | Capa | Significado | Bug de hoy |
|---|---|---|---|
| `CreateContainerConfigError` | Config (pre-arranque) | Falta ConfigMap/Secret/key referenciado | **Bug #4:** el Deployment pedía keys `environment`/`cloud_provider` (minúsculas) y el ConfigMap define `ENVIRONMENT`/`CLOUD_PROVIDER` (mayúsculas, lo que la app lee). Fix en `bases/deployment.yml` |
| `RunContainerError` | Runtime (arranque) | El ejecutable no existe / la imagen no arranca | **Bug #5:** el parche sobreescribía `command: ["/bin/http-echo"]` (ruta inexistente). Fix: **solo `args`** — la imagen trae su propio entrypoint |
| `CrashLoopBackOff` | App (post-arranque) | El contenedor arranca pero muere en loop | Apareció combinado con el #5 por reintentos del kubelet |

**Bug #6 — `Progressing` eterno de la Application:** el overlay incluía un Ingress con `ingressClassName: azure-application-gateway`, pero **no existe controller AGIC** en el cluster. ArgoCD marca un Ingress `Healthy` solo cuando recibe `status.loadBalancer`; sin controller, la columna `ADDRESS` queda vacía para siempre.

- **Fix:** Ingress pausado del overlay con nota `TEMPORAL` (AGIC + Application Gateway cuestan ~$20-25/mes — diferido conscientemente).
- **Bonus observado:** al quitar el recurso del repo, ArgoCD lo **eliminó del cluster automáticamente** → `prune: true` en acción.

**Resultado:** `Synced / Healthy` 🎯 con 4 recursos gestionados (ConfigMap, Service, Deployment, HPA).

---

## 7. Verificación funcional — 3 lecciones de diagnóstico

### 7.1 El wiring y los valores del ConfigMap

```bash
# El cableado (fix del bug #4 visible): keys en MAYÚSCULAS
kubectl get deploy -n sri-facturacion sri-facturacion-service-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env}'

# Los valores reales
kubectl get configmap -n sri-facturacion sri-facturacion-config \
  -o jsonpath='{.data.ENVIRONMENT}{" / "}{.data.CLOUD_PROVIDER}'
# → production / azure
```

### 7.2 Lección: no pipear jsonpath a `jq`

`jq` solo parsea JSON. La salida de `-o jsonpath='...'` es **texto plano** → `jq: parse error`. Regla: `-o json` lleva `| jq`; `-o jsonpath` no.

### 7.3 Lección: imágenes minimalistas no tienen shell

`kubectl exec ... -- env` falló con `executable file not found in $PATH`: `hashicorp/http-echo` es **distroless** — solo contiene el binario, sin `env`/`sh`/`cat`. Es buena práctica de seguridad (superficie de ataque mínima). La verificación se hace desde fuera del contenedor: el pod `1/1 Running` **ya es la prueba** de que las keys del ConfigMap resolvieron (si no, sería `CreateContainerConfigError`).

### 7.4 El misterio del JSON `{"status":"ok"}`

`curl http://localhost:8080/health` devolvía `{"status":"ok"}` en vez del texto del `-text`. Se descartaron proxies (`env | grep -i proxy` vacío, `curl --noproxy '*'`) y dueños de puerto (`lsof` → kubectl único).

**Causa real:** `hashicorp/http-echo` trae **endpoint `/health` nativo** que responde `{"status":"ok"}` por diseño (pensado para probes de Kubernetes). El `-text` solo se ve en la raíz:

| Path | Respuesta |
|---|---|
| `/` | `GitOps SRI OK - flujo validado en AKS` (el `-text`) |
| `/health` | `{"status":"ok"}` (endpoint nativo de la imagen) |

**Lección reutilizable:** un JSON inesperado en un path concreto NO implica cluster roto ni interceptor local — puede ser un endpoint nativo de la imagen. Diagnosticar por eliminación: dueño del puerto → bypass de proxy → **path raíz** → endpoints nativos de la imagen. Los pods estaban Ready precisamente porque los probes golpeaban ese endpoint nativo.

---

## 8. Demo GitOps pura — el commit mueve el cluster ⭐

Cambio de la app **solo vía Git**, cero kubectl:

```bash
# 1. Editar gitops/overlays/azure-aks/deployment-test-command-patch.yaml
#    -text=GitOps V2 Darwin Calle - flujo validado en AKS

git add gitops/overlays/azure-aks/deployment-test-command-patch.yaml
git commit -m "demo: GitOps v2 via repo (sin kubectl)"
git push origin feature-patron-appOfapps

# 2. Detección inmediata (o esperar el poll natural de ~3 min)
kubectl -n argocd annotate application sri-facturacion-azure-aks \
  argocd.argoproj.io/refresh=hard --overwrite

# 3. El rollout provocado SOLO por el commit
kubectl get pods -n sri-facturacion -w

# 4. Prueba de fuego (túnel: kubectl port-forward -n sri-facturacion \
#    svc/sri-facturacion-service-svc 8080:80)
curl http://localhost:8080
```

**Resultado:**

```
v1: GitOps SRI OK - flujo validado en AKS
v2: GitOps V2 Darwin Calle - flujo validado en AKS   ← solo un commit
```

---

## 9. Costos de la sesión

| Concepto | Monto |
|---|---|
| Cluster AKS (~3h de vida con todo el GitOps corriendo) | ~$1.20 |
| Storage backend `sritfstate23c5` (permanente, centavos) | ~$0.05/mes |
| ArgoCD, metrics-server, app (corren en los nodos ya pagados) | $0 |
| ACR / Application Gateway / Key Vault (diferidos, nunca creados) | $0 |
| **Total** | **~$1.25** |

---

## 10. Estado final y pendientes

**Validado:** IaC AKS reproducible · ArgoCD operativo · flujo GitOps end-to-end · prune y selfHeal observados · 6 bugs latentes corregidos.

**Pendiente (próximas sesiones):**

1. UI de ArgoCD (screenshots para el TFM): `kubectl port-forward svc/argocd-server -n argocd 8081:443`, admin + password de `argocd-initial-admin-secret`.
2. Imagen real del microservicio en ACR (~$5/mes) o ECR; restaurar el bloque `images:` y eliminar el parche de prueba.
3. Key Vault + Secrets Store CSI Driver + Managed Identity; restaurar `secrets-store-csi.yaml` y `deployment-secrets-patch.yaml`.
4. Ingress real con AGIC + Application Gateway (~$20-25/mes, decisión consciente de costo).
5. Replicar el flujo en EKS (overlay `aws-eks`, ya beneficiado por los fixes del base).
6. `terraform destroy` para cerrar factura (cuando termine la ventana de pruebas).
7. Merge final a `main` y `targetRevision` de las Applications de vuelta a `main`.

---

## 11. Runbook rápido (recrear todo desde cero)

```bash
# --- Infra ---
az login --service-principal --username <APP_ID> --password <PWD> --tenant <TENANT>
export ARM_CLIENT_ID=<APP_ID> ARM_CLIENT_SECRET=<PWD> ARM_TENANT_ID=<TENANT> ARM_SUBSCRIPTION_ID=<SUB_ID>
cd iac/azure && terraform apply        # ~5 min

# --- GitOps ---
az aks get-credentials -g sri-aks-rg -n sri-aks-cluster --overwrite-existing
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-azure-aks.yaml
kubectl get application -n argocd sri-facturacion-azure-aks -w   # → Synced/Healthy

# --- Cierre ---
cd iac/azure && terraform destroy
```
