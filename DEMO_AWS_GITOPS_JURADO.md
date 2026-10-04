# DEMO AWS — GitOps de Cero a Producción ante el Jurado (EKS)

> Guion completo, comando a comando, de la demo **segunda nube**: AWS EKS.
> Mismo repositorio, mismo pipeline, mismo ArgoCD — solo cambia el provider y el overlay.
> Ensayado contra cuenta AWS real `${ACCOUNT_ID}` (us-east-1), pay-as-you-go.

---

## 0. Narrativa de apertura (30 segundos, textual)

*"En la demo anterior, Azure demostró el patrón: plataforma permanente, cluster efímero, GitOps en el centro. Ahora la misma demo en la segunda nube — sin cambiar el diseño. Mismo monorepo, mismo pipeline con matriz dual-cloud, mismo ArgoCD. Lo único que cambia: el provider de Terraform y el overlay de Kustomize. Esto es portabilidad de arquitectura: el patrón es el activo, el proveedor es un detalle."*

**Regla de oro de la sesión:** el jurado no ve una segunda demo distinta — ve que tu primera demo no fue suerte.

---

## 1. Plan general

| Fase | Qué pasa | Tiempo | Costo |
|---|---|---|---|
| 0 | Punto de partida (el "antes") | 3 min | $0 |
| 1 | Provisión del EKS con Terraform | ~10 min comandos+espera | ~$0.05 (provisionado al final) |
| 2 | Acceso al cluster | 2 min | — |
| 3 | Instalación de ArgoCD | 2 min + ~2 min espera | — |
| 4 | Application GitOps (overlay aws-eks) | 3 min | — |
| 5 | UI de ArgoCD | 2 min | — |
| 6 | El bucle vivo (LA ESTRELLA) | 5 min + pipeline ~1 min | — |
| 7 | Cierre FinOps (destroy) | 3 min + ~3 min espera | detiene todo |
| | **Total** | **~35 min** | **< $0.50** |

**Costo mientras el cluster vive:** control plane $0.10/h + 3 nodos ~$0.12/h ≈ **$0.22/h**. Por eso la Fase 7 es parte de la demo, no un trámite.

### 1.1 Registro cronológico del ensayo real (2026-10-02, cuenta ${ACCOUNT_ID})

| # | Fase/Paso | Resultado real |
|---|---|---|
| 0.1-0.2 | Repo + identidad | Rama `feature-patron-appOfapps`; `sts get-caller-identity` → `terraform-ci` (Account ${ACCOUNT_ID}) |
| 0.3 | Prueba del cero | `ResourceNotFoundException` para sri-eks-cluster — evidencia estrella |
| 0.4 | ECR permanente | Repo `sri-facturacion-service` con imagen `0188592df462...` + `latest` (producción de la pata AWS del pipeline dual-cloud) |
| 0.5 | OIDC permanente | Provider `token.actions.githubusercontent.com` + rol `github-actions-ecr-push` verificados (ejecutado retroactivo) |
| 1 | Terraform apply | `Apply complete! Resources: 11 added` — node group en 1m58s; endpoint `...gr7.us-east-1.eks.amazonaws.com` |
| 2 | Acceso | `update-kubeconfig` + 3 nodos Ready |
| 3 | ArgoCD | 7 pods Running en ~3 min (dex con 2 restarts normales de arranque) |
| 3.5 | metrics-server | `kubectl top nodes` con métricas reales de los 3 nodos |
| 4 | Application | `Synced/Degraded` → `Synced/Healthy` tras 3.5 — **INCIDENTE REAL: el HPA ciego** (ver sección 6) |
| 5 | UI ArgoCD | v3.5.3; screenshot `diagramas/6_ArgoCD_Synced_ImagenReal_EKS.png`; 7 Healthy. **JoyA narrativa:** la revision sincronizada es `9b34501`, author DarwinCalle, comment "DEMO AZURE FINAL" — la imagen que corre en EKS nació del cierre de la demo Azure: la matriz dual-cloud publicó en ambos registros en una sola corrida |
| 6 | Bucle vivo | ✅ COMPLETADO: 5.0.0→7.0.0 → pipeline dual-cloud → bump `[skip ci]` → auto-sync → nuevo RS `67dcd9c6b` → curl = 7.0.0/aws/sri-eks-cluster (misma cadena que Azure, cero kubectl) |
| 7 | Destroy | ✅ COMPLETADO: `Destroy complete! Resources: 11 destroyed` — cluster en 3m45s, roles IAM en 1s, state lock liberado limpio. Tercer destroy consecutivo limpio en AWS. Gasto: $0/h |

---

## 2. FASE 0 — Punto de partida (el "antes")

### PASO 0.1 — El repositorio (10 seg)

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
git status && git branch --show-current && git log --oneline -3
```

**Esperado:** rama `feature-patron-appOfapps`, working tree limpio (si `DEMO_AZURE_GITOPS_JURADO.md` aparece sin commitear, hazlo ahora: `git add DEMO_AZURE_GITOPS_JURADO.md && git commit -m "docs: guion demo jurado Azure validado" && git push`).

**Di al jurado:** *"Todo mi conocimiento vive en Git. La demo empieza en el repositorio, no en mi laptop."*

### PASO 0.2 — Autenticación con identidad de automatización (30 seg)

```bash
export AWS_REGION=us-east-1
export AWS_ACCESS_KEY_ID=<ACCESS_KEY_ID_del_usuario_IAM>
read -s AWS_SECRET_ACCESS_KEY && export AWS_SECRET_ACCESS_KEY   # pegar sin eco
aws sts get-caller-identity
```

**Esperado:** JSON con tu `Account: ${ACCOUNT_ID}` y el Arn del usuario IAM.

*(Nota: en Azure la identidad era un Service Principal con secret; en AWS es un usuario IAM con access keys. El pipeline en cambio NO usa estas keys: usa federación OIDC — pregunta del jurado preparada en sección 11.)*

### PASO 0.3 — La prueba del cero (el cluster no existe) (15 seg)

```bash
aws eks describe-cluster --name sri-eks-cluster --region us-east-1 2>&1 | head -3
```

**Esperado:** `ResourceNotFoundException: No cluster found for name: sri-eks-cluster.`

**Di al jurado:** *"Ese error es mi evidencia estrella: no existe. Todo lo que veremos a continuación se construye desde este punto, con código, ante sus ojos."*

### PASO 0.4 — La plataforma permanente intacta (30 seg)

```bash
aws ecr describe-repositories --query "repositories[].repositoryName" --output table
aws ecr describe-images --repository-name sri-facturacion-service \
  --query "sort_by(imageDetails,&imagePushedAt)[-3:].imageTags" --output table
```

**Esperado:** repo `sri-facturacion-service` con los tags `latest` y los shas de los pushes del pipeline.

**Di al jurado:** *"Mi registro de imágenes es plataforma permanente: sobrevive a todos los clusters, protegido con `prevent_destroy` y un state de Terraform separado (`aws/registry.tfstate`). El cluster puede nacer y morir — las imágenes permanecen."*

### PASO 0.5 — La plataforma permanente COMPLETA: federación OIDC (15 seg)

```bash
aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text
aws iam get-role --role-name github-actions-ecr-push --query "Role.Arn" --output text
```

**Esperado:** `arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com` y `arn:aws:iam::${ACCOUNT_ID}:role/github-actions-ecr-push`. **Costo: $0** (lecturas IAM gratis).

**NOTA — por qué este script NO se ejecuta en la demo (contraste con Azure):** `scripts/bootstrap-github-oidc-aws.sh` se ejecutó UNA sola vez (como root, bootstrap humano privilegiado) porque su sujeto —el rol que GitHub Actions asume— es permanente y ajeno al ciclo de vida del cluster: la demo solo lo VERIFICA. El script gemelo de Azure (`bootstrap-acr-rbac-azure.sh`) sí se re-ejecuta en cada recreate porque su sujeto —la kubelet identity— muere con el cluster (fue el incidente didáctico de la demo Azure). Dos scripts, dos ciclos de vida — y el guard del script AWS (aborta si la sesión no es root) hace que ejecutarlo en la demo fallara por diseño: la identidad de la demo es `terraform-ci`, no root.

**Di al jurado:** *"La federación OIDC también es plataforma permanente: la creó un script idempotente ejecutado una única vez con identidad privilegiada humana. Hoy solo la verifico — igual que el ECR y el bucket de estado. Permanente se verifica; efímero se reconstruye."*

---

## 3. FASE 1 — Provisión del EKS con Terraform (el cluster nace)

### PASO 1.1 — Init del backend remoto (30 seg)

```bash
cd iac/aws
terraform init
```

**Esperado:** `Successfully configured the backend "s3"!` — bucket `sri-gitops-tfstate`, key `aws/terraform.tfstate`, locking nativo con `use_lockfile` (sin DynamoDB — Terraform ≥ 1.10).

### PASO 1.2 — Plan: leer antes de ejecutar (30 seg)

```bash
terraform plan
```

**Esperado:** `Plan: 11 to add, 0 to change, 0 to destroy.`

**Di al jurado (mientras avanzan los recursos en pantalla):** *"11 recursos: el cluster, el node group, y el mínimo de IAM — dos roles con sus policies. El rol de los nodos incluye `AmazonEC2ContainerRegistryReadOnly` desde el código: ese será el equivalente exacto del permiso de pull que en Azure exigió un bootstrap humano. Aquí es declarativo — tenganlo presente."*

### PASO 1.3 — Apply (el cluster nace, ~8-10 min)

```bash
terraform apply
```

**Esperado:** la creación termina con el cluster `ACTIVE`. Si `terraform.tfvars` (gitignored) lleva `admin_principal_arns`, los access entries de los usuarios humanos se crean en el mismo apply — declarativos, no manuales.

**Di al jurado:** *"La infraestructura completa nació de un solo comando. El plan anterior me mostró exactamente qué iba a crear — nadie ejecuta a ciegas."*

---

## 4. FASE 2 — Acceso al cluster (2 min)

```bash
aws eks update-kubeconfig --name sri-eks-cluster --region us-east-1
kubectl get nodes -o wide
```

**Esperado:** 3 nodos `Ready` (~1-2 min para que terminen de unirse).

**Di al jurado:** *"El kubeconfig se genera con un comando y la autorización la dan los access entries del módulo — modo `API_AND_CONFIG_MAP`, el modo moderno de EKS. Ni un paso manual."*

---

## 5. FASE 3 — Instalación de ArgoCD (2 min de comandos + ~2 min de espera)

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl -n argocd get pods -w
```

**Esperado:** 7 pods `Running` (argocd-server, repo-server, application-controller, redis, dex, notificaciones, applicationset-controller).

**Di al jurado:** *"`--server-side --force-conflicts` porque las CRDs de ArgoCD superan el límite de anotación del apply cliente. Es el mismo comando exacto que usé en Azure — la herramienta de GitOps es agnóstica a la nube, como debe ser."*

### PASO 3.5 — Instalación de metrics-server (bootstrap propio de EKS) (1 min + ~1 min)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s
kubectl top nodes    # verificar tras ~1-2 min: 3 nodos con CPU%/MEMORY%
```

**Por qué:** el base declara un HPA (CPU 70%, memoria 80%) y el Deployment define requests/limits — el HPA necesita el API de métricas. **En AKS venía de fábrica; en EKS lo instalo yo**: misma plataforma Kubernetes, bootstraps distintos por nube.

**Costo: $0** (pod ligero ~50m CPU en nodos existentes).

**Di al jurado:** *"En Azure el metrics-server venía de fábrica; en EKS lo instalo como parte del bootstrap reproducible. Ahora el HPA de mi base escala por CPU y memoria reales en ambas nubes."*

---

## 6. FASE 4 — Registro de la Application GitOps (3 min)

```bash
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-aws-eks.yaml
kubectl get applications -n argocd
kubectl -n sri-facturacion get pods -w
```

**Esperado:** la Application `sri-facturacion-aws-eks` pasa a `Synced/Healthy` y los 3 pods de la app `Running` con la imagen `${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/sri-facturacion-service` del último bump del pipeline.

**Di al jurado:** *"La Application apunta al MISMO repositorio que la de Azure — misma rama, distinto path: `gitops/overlays/aws-eks`. El overlay inyecta `CLOUD_PROVIDER=aws` y `CLUSTER_NAME=sri-eks-cluster`. Ni una línea de código de la app cambió."*

### NOTA DIDÁCTICA PREVENTIVA — "¿Y el incidente del AcrPull?" (sección fija del guion)

*"En Azure, este momento produjo un ImagePullBackOff: la identidad del kubelet nace con el cluster y su permiso de pull murió con el cluster anterior — hubo que re-asignarlo con un bootstrap humano privilegiado. En AWS ese incidente NO OCURRE POR DISEÑO: el rol de los nodos ya lleva `AmazonEC2ContainerRegistryReadOnly` porque lo declara el propio módulo Terraform, ANTES de que el cluster exista. Mismo problema de seguridad — pull autorizado desde el registro — resuelto con dos modelos: Azure separa identidad de trabajo por-cluster (bootstrap humano), AWS ata el permiso al rol del nodo en IaC. Ninguno es 'mejor' en abstracto: son trade-offs, y mi módulo documenta el que toca a cada nube."*

*(Contingencia: si apareciera un ImagePullBackOff igual, verificar el policy attach del rol de nodos: `aws iam list-attached-role-policies --role-name <node-role>` — el fix es re-aplicar el módulo, no un permiso manual.)*

### INCIDENTE DIDÁCTICO REAL (2026-10-02) — "Degraded" sin pods enfermos: el HPA ciego

En el ensayo real, la Application se aplicó ANTES del metrics-server y mostró `Synced/Degraded` — con los 3 pods `Running` perfectos. Causa raíz:

1. ArgoCD no evalúa "la app": evalúa CADA recurso gestionado y agrega (Deployment, Service, ConfigMap, HPA).
2. Sin metrics-server, la API `metrics.k8s.io` no existe en EKS → el controlador del HPA no puede leer CPU/memoria → escribe `ScalingActive: False` (FailedGetResourceMetric) en su status.
3. El health check incorporado de ArgoCD para HPA traduce `ScalingActive: False` → `Degraded` → la Application entera se ve Degraded.
4. Tras instalar metrics-server (PASO 3.5), el HPA lee métricas reales → `ScalingActive: True` → `Synced/Healthy`. Los pods nunca estuvieron mal.

```bash
kubectl get hpa -n sri-facturacion          # antes: <unknown>/70% → después: p.ej. 3%/70%
kubectl describe hpa -n sri-facturacion | grep -A3 ScalingActive   # True / ValidMetricFound
kubectl -n sri-facturacion get pods         # 3/3 Running — nunca estuvieron mal
```

**Di al jurado:** *"Un `Degraded` no es sinónimo de pods caídos: ArgoCD agrega la salud de cada recurso, y el enfermo era mi HPA — ciego porque su fuente de métricas no existía. En AKS el metrics-server viene de fábrica; en EKS lo instalo yo en el bootstrap. En Azure el mismo síntoma tenía otra causa (permiso de pull del registro): el diagnóstico es siempre igual — describe del recurso enfermo, no del síntoma."*

---

## 7. FASE 5 — La UI de ArgoCD (2 min)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8082:443
```

Abrir `https://localhost:8082` → usuario `admin` + la contraseña impresa.

**Qué mostrar:** la Application `sri-facturacion-aws-eks` en verde, el Deployment con su imagen y tag del commit, la trazabilidad commit → imagen → pod.

**Screenshot de evidencia:** `diagramas/6_ArgoCD_Synced_ImagenReal_EKS.png` (completa la serie Azure 1→5 con la nube 2).

---

## 8. FASE 6 — El bucle vivo (LA ESTRELLA)

### PASO 6.1 — El cambio (60 seg)

Editar `app/main.py` — la versión actual `5.0.0` → nueva versión (en el ensayo real: **`7.0.0`**, elección del autor; son 3 apariciones: mensaje del raíz, `version` del raíz y `version` de `/api/v1/version`). SOLO ese archivo.

```bash
git add app/main.py
git commit -m "feat: bump app version 7.0.0 — demo AWS jurado"
git push origin feature-patron-appOfapps
```

### PASO 6.2 — El pipeline (señalar los 3 momentos en Actions)

1. **Test** → pytest verde
2. **build-and-push (matriz aws+azure)** → en el job `aws`: `configure-aws-credentials@v4` asumiendo `arn:aws:iam::${ACCOUNT_ID}:role/github-actions-ecr-push` por **federación OIDC** (cero credenciales de larga vida), buildx empuja a ECR el tag `=<commit-sha>`
3. **update-manifests** → `kustomize edit set image` + commit del bot `ci: bump image tag ... [skip ci]`

### PASO 6.3 — El re-deploy sin intervención

```bash
kubectl get applications -n argocd -w    # Synced con nueva revisión
kubectl -n sri-facturacion get pods -w   # nuevo ReplicaSet rodando
```

### PASO 6.4 — La prueba final

```bash
kubectl -n sri-facturacion port-forward svc/sri-facturacion-service 5000:5000
curl -s localhost:5000/health | head -3
curl -s localhost:5000/api/v1/version
```

**Esperado:** `{"version":"<nueva>","cloud":"aws","cluster":"sri-eks-cluster","hostname":"...-<nuevo-RS>..."}`

**RESULTADO DEL ENSAYO REAL (2026-10-02/03):**

```json
{
  "version": "7.0.0",
  "cloud": "aws",
  "cluster": "sri-eks-cluster",
  "hostname": "sri-facturacion-service-deployment-67dcd9c6b-q6zfw",
  "timestamp": "2026-10-03T04:34:04.189947"
}
```

Bucle completo validado en la segunda nube: cambio 5.0.0→7.0.0 en `app/main.py` → push → pipeline dual-cloud (pytest + buildx a ECR con OIDC + bump `[skip ci]` en ambos overlays) → ArgoCD auto-sync → nuevo ReplicaSet `67dcd9c6b` rodando sin downtime → curl verifica cada campo. Misma cadena exacta que la demo Azure (donde fue 4.0.0→5.0.0 con RS `774488f6b8`): **dos nubes, un bucle, cero kubectl en el camino**.

**Di al jurado:** *"De mi commit a producción: pipeline probó, construyó en la nube, publicó en ECR, y el bot actualizó Git. ArgoCD detectó el cambio y rodó la nueva versión sin downtime — yo no toqué el cluster ni una vez. Este bucle es idéntico al de Azure: el mismo código corriendo en dos nubes porque el patrón vive en Git, no en el proveedor."*

---

## 9. FASE 7 — Cierre FinOps (3 min)

```bash
cd iac/aws
terraform destroy
```

**Esperado:** `Destroy complete! Resources: 11 destroyed.` (~3 min; los access entries mueren antes que el cluster — dependencia declarativa). `Releasing state lock...` limpio (S3 use_lockfile).

**RESULTADO DEL ENSAYO REAL (2026-10-02):** `Destroy complete! Resources: 11 destroyed` — `aws_eks_cluster.main` en 3m45s, roles IAM en 1s, `Releasing state lock...` limpio. Gasto detenido: $0/h. Ensayo cerrado de cero a cero.

**Di al jurado:** *"Cierro destruyendo lo efímero. ¿Y qué sobrevive? El bucket de estado `sri-gitops-tfstate`, el repositorio ECR con `prevent_destroy` en su propio state (`aws/registry.tfstate`) — este destroy ni lo ve —, el rol OIDC de GitHub, y todo el conocimiento en Git. La próxima reconstrucción completa: un `terraform apply` de 10 minutos. Ese es el RTO de mi plataforma. Costo total de las dos demos: menos de un dólar."*

**Cierre final de la serie:** *"Azure y AWS, dos demos, un solo diseño. La prueba definitiva de que esto es arquitectura, no configuración."*

---

## 10. Datos de plataforma AWS (referencia rápida)

| Elemento | Valor |
|---|---|
| Cuenta AWS | `${ACCOUNT_ID}` |
| Región | `us-east-1` |
| Cluster | `sri-eks-cluster` (k8s 1.35, 3 nodos, VPC default) |
| ECR | `sri-facturacion-service` → `${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/sri-facturacion-service` (MUTABLE, prevent_destroy, state `aws/registry.tfstate`) |
| Backend Terraform | S3 bucket `sri-gitops-tfstate`, key `aws/terraform.tfstate`, `use_lockfile` |
| Rol OIDC pipeline | `arn:aws:iam::${ACCOUNT_ID}:role/github-actions-ecr-push` (secret GitHub: `AWS_ROLE_ARN`) |
| Workflow | `.github/workflows/ci-cd.yaml` — matriz `[aws, azure]` |
| Application ArgoCD | `sri-facturacion-aws-eks` → path `gitops/overlays/aws-eks`, rama `feature-patron-appOfapps` |
| App | puerto 5000: `/health`, `/ready`, `/metrics`, `/api/v1/version` (v5.0.0 → 6.0.0 en la demo) |
| Access entries | declarativas vía `admin_principal_arns` en `terraform.tfvars` (gitignored) |

---

## 11. Preguntas probables del jurado (respuestas preparadas)

**"¿En AWS también hay federación OIDC para GitHub Actions?"**
Sí, misma idea con piezas distintas: un OIDC provider de IAM (`token.actions.githubusercontent.com`) + rol `github-actions-ecr-push` con trust policy que valida `aud` y `sub` del repo (formato dual, viejo y nuevo con IDs inmutables). El workflow usa `configure-aws-credentials@v4` con `role-to-assume` y `id-token: write` — cero access keys en GitHub. En Azure era la federated credential de la App Registration; mismo patrón, distinta API.

**"En Azure hubo un incidente de permiso de pull. ¿Por qué aquí no?"**
Porque el modelo de identidad es distinto: en Azure el kubelet tiene una managed identity que nace con el cluster — su AcrPull exige un bootstrap humano posterior (privilegio de asignar roles). En AWS el permiso de pull está pegado al rol IAM del node group, que Terraform crea ANTES del cluster — declarativo desde el código. Documenté ambos trade-offs en el guion: es exactamente el tipo de decisión de diseño que quiero que se discuta.

**"¿Por qué el ingress está comentado en el overlay de AWS?"**
El overlay aws-eks no instala el AWS Load Balancer Controller. Es una decisión de alcance: la demo demuestra el bucle GitOps end-to-end con port-forward; el controller es un addon estándar (IRSA + Helm chart) que añadimos cuando expongamos público. En Azure el AGIC ya venía activo por el add-on del cluster.

**"¿IRSA? ¿Lo usas?"**
No en esta iteración: la app no consume servicios AWS aún. Cuando conecte S3/Secrets Manager, el patrón será IRSA (ServiceAccount anotado con el rol) — el equivalente exacto de la Managed Identity + CSI que ya tengo diseñado para Azure (deployment-secrets-patch comentado, SecretProviderClass preparada). Mismo diseño de secretos nativos por nube (ADR-003).

**"¿Por qué MUTABLE el repo de ECR?"**
El overlay consume el tag `latest` como imagen de desarrollo y el pipeline puebla `<commit-sha>` para trazabilidad. MUTABLE permite re-etiquetar `latest`; la trazabilidad real vive en los tags por-sha, no en `latest`. En producción se congelaría a IMMUTABLE.

**"¿Cuánto cuesta esto corriendo?"**
Cluster efímero ~$0.22/h (control plane + 3 nodos), destruido en cada pausa — por eso el destroy es parte de la demo. ECR ~centavos/mes por GB. El pipeline: $0 en repo público. En producción 24/7: ~$160/mes solo el EKS en 3 nodos t3 — y ahí la conversación es de FinOps real: autoscaling, spot, derechos de instancia.

**"¿Cómo difiere el backend de estado?"**
S3 con locking nativo `use_lockfile` (Terraform ≥ 1.10, sin DynamoDB) y cifrado AES256; en Azure, Storage Account con blob lease. Dos backends, un solo flujo: `init/plan/apply` idéntico. El bucket y el registro ECR son permanentes — tienen su propia cuenta de vida separada del cluster.

---

*Guion gemelo de DEMO_AZURE_GITOPS_JURADO.md. Estado: Fases 0-7 COMPLETADAS — ensayo cerrado de cero a cero en la cuenta AWS real ${ACCOUNT_ID} (2026-10-02), registro cronológico en §1.1. Última actualización: 2026-10-02.*
