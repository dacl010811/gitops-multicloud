# AZURE — Secretos (Key Vault + CSI + Workload Identity) e Ingress (AGIC + Application Gateway): Plan de Sesión

> **Propósito:** gemelo exacto de las sesiones AWS ya validadas — [AWSSecretsSSM-CSI.md](AWSSecretsSSM-CSI.md)
> (secretos SSM + IRSA + CSI, 2026-10-05) y [AWSLoadBalancer-ControllerIRSA.md](AWSLoadBalancer-ControllerIRSA.md)
> (ALB + Ingress, 2026-10-03/04) — con los componentes homólogos de Azure. Con esta sesión las dos nubes
> quedan simétricas para la defensa: mismo patrón, almacén nativo por nube, cero secretos en Git.
>
> **Estado del documento:** PLAN previo a la sesión (redactado 2026-10-07 por la noche). Se convierte en
> runbook/registro al ejecutarse: cada fase se marca ✅ con la evidencia real.
>
> **Punto de partida:** clúster Azure destruido (2026-10-02, ensayo de cero a cero completado) · clúster AWS
> destruido hoy (FASE 10, cierre sin huérfanos) · plataforma permanente Azure intacta (ACR, backend, OIDC GitHub).
>
> **Reglas de sesión:** (1) el costo se reporta ANTES de cada acción cloud — tabla por fase; (2) el usuario
> ejecuta TODOS los comandos; el agente prepara archivos/edits y valida renders (`kubectl kustomize` + parse
> YAML antes de cada commit); (3) rama de trabajo `feature-patron-appOfapps` (ArgoCD la vigila).

---

## 0. Objetivo de defensa: la simetría completa

| Concepto | AWS (✅ validado en vivo) | Azure (esta sesión) |
|---|---|---|
| Almacén de secretos | SSM Parameter Store (SecureString) | Key Vault (RBAC) |
| Identidad del workload | IRSA: OIDC provider del clúster + rol IAM con trust por `sub` del SA | Workload Identity: federated credential (issuer OIDC + subject del SA) → Managed Identity |
| ServiceAccount | `eks.amazonaws.com/role-arn: <ARN rol>` | `azure.workload.identity/client-id: <clientId MI>` |
| Driver CSI | Secrets Store CSI + provider AWS vía Helm (script bootstrap) | Add-on gestionado `key_vault_secrets_provider` (Terraform) |
| SecretProviderClass | `provider: aws`, parámetros `/sri-facturacion/*` | `provider: azure`, `clientID` + `keyvaultName` |
| Sync a Secret K8s | `secretObjects` → `sri-facturacion-db` | idéntico (mismo mecanismo) |
| Controller de ingress | AWS Load Balancer Controller (Helm + IRSA) | AGIC add-on (greenfield) |
| Balanceador | ALB — nace DEL Ingress vía controller; muere con el prune | App Gateway v2 — nace DEL clúster (add-on); muere con el node RG |
| Address del Ingress | hostname DNS del ALB | IP pública del AppGW |
| Métricas HPA | metrics-server (instalación manual) | metrics-server (incluido en AKS) |

**Narrativa de cierre para el jurado:** *"En AWS demostré el patrón con SSM, IRSA y un ALB. Hoy lo materializo
en Azure con Key Vault, Workload Identity y Application Gateway. El diseño viaja; el proveedor no: la
portabilidad está en el patrón de consumo (SecretProviderClass CSI + ServiceAccount + identidad federada +
volumen montado), no en el vendor."* (Respaldado por ADR-003, pendiente de redactar en `docs/decisions/` —
esta sesión aporta la pata Azure que lo cierra.)

---

## 1. Decisiones de diseño (verificadas contra docs oficiales, sep-2026)

**D1 — Workload Identity Federation para el CSI driver** (docs: *Access Azure Key Vault with the CSI Driver
Identity Provider*, learn.microsoft.com). La mejor práctica actual de la industria: reemplaza al pod-identity
deprecado (oct-2022). Es el homólogo directo de IRSA: la SA del pod se **federa** a una Managed Identity
user-assigned mediante una credencial federada (issuer OIDC del clúster + subject
`system:serviceaccount:<ns>:<sa>`); el provider Azure canjea el token proyectado del pod por el token de la
MI y lee Key Vault. Mínimo privilegio por workload — la identidad NO depende del node pool.

**D2 — Key Vault con modelo RBAC** (`enable_rbac_authorization = true`): el modelo que Azure recomienda (las
access policies son el modelo legado). La MI recibe el rol **"Key Vault Secrets User"** a scope del vault.

**D3 — Key Vault + Managed Identity = PLATAFORMA PERMANENTE** (state propio `azure/key-vault.tfstate`,
`prevent_destroy`). Motivos, defendibles ante el jurado:
- Costo residual: ~$0.03/secreto/mes → ~$0.10/mes los 3 secretos. La MI es gratis.
- El nombre del Key Vault es **único global** y el soft-delete reserva el nombre 90 días: recrearlo por
  sesión invitaría al infierno del soft-delete (misma familia de lecciones que `StorageAccountAlreadyTaken`).
- **Contraste consciente con AWS**: en AWS el módulo `secrets-csi` entero es efímero porque SSM no tiene
  nombre global ni costo. La frontera permanente/efímero se ADAPTA a las restricciones de cada servicio; la
  arquitectura del patrón es la misma.

**D4 — Federated credential = EFÍMERO** (vive en el state del clúster, `iac/azure/main.tf`). El issuer OIDC
de AKS lleva un **UUID por clúster** (`https://<region>.oic.prod-aks.azure.com/<tenant>/<uuid>` — verificado
en docs *use-oidc-issuer*): cambia en cada recreate, exactamente como el OIDC provider de EKS. Nace y muere
con el clúster vía Terraform — homólogo del trust policy IRSA que vivía en `iac/aws/secrets-csi`.

**D5 — Driver CSI como add-on gestionado** (`key_vault_secrets_provider` en el módulo AKS): homólogo del
chart Helm del provider AWS instalado por `bootstrap-secrets-csi-eks.sh`, con menos superficie operativa
(lo opera Microsoft). Nota azurerm: el bloque **exige** `secret_rotation_enabled` explícito.

**D6 — AGIC add-on greenfield** (`ingress_application_gateway { gateway_name = "sri-appgw", subnet_cidr = "10.225.0.0/24" }` — azurerm v3 exige uno de `gateway_id`/`subnet_id`/`subnet_cidr`; con Azure CNI Overlay (default de AKS moderno) el add-on exige prefijo ≥ /24 — el /16 clásico falla con `IngressAppGwAddonConfigInvalidSubnetCIDR`, incidente real 2026-10-08): el Application Gateway
v2 lo crea el add-on en el node RG (MC_) al nacer el clúster, y **muere con él** — el RG MC_ se borra en el
destroy de AKS. **Cero huérfanos por diseño** (mejor que AWS, donde el ALB huérfano era el riesgo de la
sesión y motivó la regla de oro). Misma filosofía que LB Controller→ALB: la IaC declara el COMPORTAMIENTO
(el add-on) y el recurso data-plane nace del clúster. Factura desde el apply del clúster (~$0.02-0.05/h),
no desde el Ingress.

**D7 — Secretos sembrados por bootstrap humano idempotente** (script nuevo, espejo de
`bootstrap-acr-rbac-azure.sh`): asigna "Key Vault Secrets User" a la MI y "Key Vault Secrets Officer" al
humano, y siembra los 3 secretos demo SOLO si no existen (la contraseña nace en runtime con `openssl`, jamás
en Git). El SP `terraform-ci-azure` (Contributor) no puede crear role assignments ni tiene acceso data-plane
— least privilege, decisión registrada *"bootstrap privilegiado humano único vs operación recurrente SP"*.
Bonus sobre AWS: aquí **ni siquiera el state de Terraform contiene los secretos** (en AWS `random_password`
vivía en el tfstate, riesgo documentado).

**D8 — El overlay queda listo PARA SIEMPRE.** `clientID`, `tenantId` y `keyvaultName` son identificadores
públicos (no secretos — igual que el ARN del rol viajaba commiteado en AWS). Tras esta sesión, recrear el
clúster NO exige rellenar placeholders del overlay: solo `terraform apply` (la fedcred se actualiza sola).
Superioridad de reproducibilidad para la defensa.

---

## 2. Mapa permanente / efímero de Azure (resultante de esta sesión)

| Permanente (plataforma — nunca se destruye) | Efímero (nace y muere por sesión) |
|---|---|
| ACR `sriacrtfm23c5` (state `azure/registry.tfstate`, `prevent_destroy`) | Clúster AKS `sri-aks-cluster` (state `azure/terraform.tfstate`) |
| **Key Vault `sri-keyvault-23c5` + 3 secretos** (state `azure/key-vault.tfstate`, `prevent_destroy`) — NUEVO | **Federated credential `sri-facturacion-sa`** (en el state del clúster) — NUEVO |
| **Managed Identity `sri-facturacion-wi`** (en el state del key-vault) — NUEVO | **Application Gateway v2** (creado por AGIC add-on en el RG MC_) — NUEVO |
| Rol "Key Vault Secrets User" (MI→KV) — asignado una vez por bootstrap | ArgoCD + driver CSI + AGIC add-on (viven en el clúster) |
| Backend Terraform `sritfstate23c5` + OIDC GitHub | Pods, SPC, SA, Ingress (viven en el clúster vía ArgoCD) |
| Storage/ACR/KV/MI ≈ **$5.2/mes en total** | Clúster+AppGW ≈ **$0.17-0.25/h mientras viven** |

---

## 3. Costo de la sesión (presupuesto: igual que las sesiones AWS, ~$0.8-1.2)

| Fase | Acción cloud | Costo |
|---|---|---|
| 0 | Lecturas + `az provider register Microsoft.KeyVault` | $0 |
| 1 | Key Vault standard + MI (+3 secretos desde FASE 3) | **<$0.01** la sesión; permanente ~$0.10/mes |
| 2 | `terraform apply` clúster (3× D2s_v3 ≈ $0.15-0.20/h) + AppGW v2 (≈ $0.02-0.05/h) | **~$0.17-0.25/h desde aquí** (se verifica SKU real en vivo) |
| 3 | Role assignments + siembra secretos | $0 (≈9 operaciones KV ≈ $0.00003) |
| 4 | ArgoCD + Application (corren en nodos ya pagados) | $0 incremental |
| 5 | Overlay secretos (GitOps) | $0 incremental |
| 6 | Ingress + AGIC (AppGW ya factura desde FASE 2) | $0 incremental |
| 7 | HPA con hey (opcional, ~10 min de carga) | ~$0.02 |
| 8 | Destroys + verificaciones | $0 |

**Total estimado con ~4-5 h de clúster vivo: ~$0.75-1.15.** Al cierre: $0/h (solo la plataforma permanente
a ~$5.2/mes que ya existía más el KV a centavos).

---

## 4. FASES

> En todas: el agente prepara el archivo/edición y valida el render ANTES del commit; el usuario ejecuta.

### FASE 0 — Punto de partida y herramientas (10 min · $0)

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
git status && git branch --show-current && git pull
command -v az terraform kubectl helm jq hey || true

# Provider del Key Vault (no está en los 4 del bootstrap; registro idempotente, $0)
az provider register --namespace Microsoft.KeyVault
az provider show --namespace "Microsoft.KeyVault" --query registrationState -o tsv   # → Registered

# Plataforma permanente intacta (lecturas $0)
az group show -n sri-tfstate-rg --query name -o tsv
az acr show -n sriacrtfm23c5 --query name -o tsv
az aks list --query "[].name" -o tsv        # → [] (el clúster no existe: partimos de cero)
```

**⛔ Checkpoint de state (importante):** el destroy del 2026-10-02 se completó vía Cloud Shell y quedó
pendiente reconciliar el state de Terraform. Verificar ANTES de planear:

```bash
cd iac/azure && terraform init
terraform state list    # esperado: vacío (o solo recursos irrelevantes)
terraform plan          # esperado con el código actual: Plan: 2 to add (RG + AKS). El federated credential se suma en FASE 2
```

Si `state list` aún lista el clúster/RG muertos → `terraform state rm <recurso>` por cada uno (o
`terraform refresh` si el recurso llegó a borrarse por API con el mismo backend) hasta que el plan muestre
solo adds. No avanzar con state sucio.

### FASE 1 — Plataforma de secretos: módulo `iac/azure/key-vault` (15 min · <$0.01)

**[AGENTE PREPARA]** los 3 archivos de la sección 5.1.

```bash
cd iac/azure/key-vault
terraform init     # backend azurerm, key azure/key-vault.tfstate
terraform plan     # esperado: Plan: 2 to add (key_vault + user_assigned_identity)
terraform apply    # ~30 seg
terraform output   # ANOTAR: identity_client_id (se usa en FASE 5) y key_vault_name
```

**Salida esperada:** `Apply complete! Resources: 2 added` + outputs. Si el nombre `sri-keyvault-23c5`
estuviera tomado globalmente → cambiar el sufijo en `variables.tf` (p.ej. `sri-keyvault-tfm23c5`) y repetir
(misma lección de unicidad global que Storage Account/ACR).

### FASE 2 — El clúster nace COMPLETO: WI + CSI + AGIC (5 min cmd + ~6 min apply · arranca facturación)

**COSTO ANTES DE APLICAR:** desde el apply corren el clúster (~$0.15-0.20/h) **y el Application Gateway v2**
(~$0.02-0.05/h, creado ya por el add-on aunque el Ingress llegue en FASE 6). Reloj total: ~$0.17-0.25/h.

**[AGENTE PREPARA]** los edits de las secciones 5.2 y 5.3 (módulo del clúster + root `iac/azure`).

```bash
cd iac/azure
terraform plan     # esperado: Plan: 3 to add (RG, AKS con add-ons, federated credential)
terraform apply    # ~5-6 min (narrativa: módulo agnóstico, mismo patrón que EKS)
```

**Verificación del nacimiento completo:**

```bash
az aks get-credentials --resource-group sri-aks-rg --name sri-aks-cluster --overwrite-existing
kubectl get nodes                                  # 3 nodos Ready (Standard_D2s_v3)

# Driver CSI + provider Azure (add-on gestionado)
kubectl -n kube-system get pods -l app=secrets-store-csi-driver        # driver
# Ojo: el DaemonSet real es aks-secrets-store-provider-azure (SIN 'csi' en el
# nombre — el driver sí lo lleva). Grep verificado en vivo 2026-10-08.
kubectl -n kube-system get pods | grep -i provider-azure

# AGIC + Application Gateway (greenfield)
kubectl -n kube-system get pods | grep -i ingress-appgw
az network application-gateway list -o table       # el AppGW vive en el RG MC_* — ANOTAR SKU
az network application-gateway list --query "[].{name:name,sku:sku.name,capacity:sku.capacity}" -o table

# Issuer OIDC (debe coincidir con el de la fedcred creada por Terraform)
az aks show -g sri-aks-rg -n sri-aks-cluster --query oidcIssuerProfile.issuerUrl -o tsv
```

**Salida esperada:** 3 nodos Ready · pods del driver/provider/AGIC Running · tabla con 1 AppGW
(Standard_v2) · issuer `https://eastus.oic.prod-aks.azure.com/<tenant>/<uuid>`.

### FASE 3 — Bootstrap humano: RBAC + siembra de secretos (10 min · $0)

**[AGENTE PREPARA]** `scripts/bootstrap-keyvault-rbac-azure.sh` (sección 5.4).

```bash
az login    # identidad HUMANA en esta terminal (el script aborta si la sesión es un SP)
bash scripts/bootstrap-keyvault-rbac-azure.sh
```

El script (idempotente): (1) rol **Key Vault Secrets User** → MI `sri-facturacion-wi` a scope del KV;
(2) rol **Key Vault Secrets Officer** → humano firmado (Owner de suscripción puede asignar roles, pero ni
siquiera Owner escribe secretos en un KV RBAC sin rol data-plane — matiz que el jurado puede preguntar);
(3) siembra `db-username`/`db-password`/`db-host` SOLO si no existen (contraseña `openssl rand` en runtime);
(4) verificación final sin exponer valores.

**Incidente didáctico esperado:** propagación RBAC de 1-2 min (mismo fenómeno que el AcrPull del ensayo
2026-10-01). El script reintenta; y en FASE 5 el primer mount puede fallar un ciclo y recuperarse solo
(reintento del kubelet). Es el costo de la consistencia eventual de Entra ID — se explica, no se parchea.

### FASE 4 — kubeconfig + ArgoCD + Application (15 min · $0 incremental)

```bash
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-azure-aks.yaml
kubectl -n argocd get application sri-facturacion-azure-aks -w   # → Synced / Healthy
```

**Salida esperada:** 4 recursos gestionados (ConfigMap, Service, Deployment, HPA) · 3 pods `Running` con la
imagen `eebdb5c…` del ACR. Los secretos AÚN no participan (overlay intacto). Si aparece
`ImagePullBackOff` → re-ejecutar `bash scripts/bootstrap-acr-rbac-azure.sh` (incidente conocido kubelet
identity/AcrPull, ya guionizado en DEMO_AZURE_GITOPS_JURADO.md).

### FASE 5 — Overlay secretos ON → GitOps monta Key Vault (30-40 min · $0 incremental)

**[AGENTE PREPARA]** las reescrituras de la sección 5.5 con los valores REALES:
`clientID` = output `identity_client_id` de FASE 1 · `tenantId` = `0fc1436e-05f9-416b-9d88-a108f4a1133b` ·
`keyvaultName` = `sri-keyvault-23c5`. Incluye la corrección del **bug #7** (metadata.name y container name
del patch = `sri-facturacion-service-deployment`, el nombre REAL del base — misma lección que AWS).

**Validación ANTES del commit (ritual obligatorio):**

```bash
kubectl kustomize gitops/overlays/azure-aks | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); print(len(docs),'recursos')"
# esperado: 6 recursos (ConfigMap, Service, Deployment, HPA, SPC, ServiceAccount)
kubectl kustomize gitops/overlays/azure-aks | grep -A2 'clientID\|azure.workload.identity'
```

```bash
git add gitops/overlays/azure-aks/ && git commit -m "azure: secretos Key Vault via CSI + Workload Identity (simetria AWS)" && git push
kubectl -n argocd annotate application sri-facturacion-azure-aks argocd.argoproj.io/refresh=hard --overwrite
kubectl -n sri-facturacion rollout status deploy/sri-facturacion-service-deployment --timeout=300s
```

**Evidencia (el corazón de la defensa — misma secuencia que la sesión AWS):**

```bash
kubectl -n sri-facturacion get pods                                   # 3 Running (rollout RollingUpdate)

# 1) Archivos montados desde Key Vault
kubectl -n sri-facturacion exec deploy/sri-facturacion-service-deployment -- ls /mnt/secrets-store
# → db-username  db-password  db-host
kubectl -n sri-facturacion exec deploy/sri-facturacion-service-deployment -- cat /mnt/secrets-store/db-username
# → sri_demo_user   (nació en Key Vault vía bootstrap humano; NO está en Git)

# 2) Sync a Secret nativo (secretObjects) + consumo por envFrom
kubectl -n sri-facturacion get secret sri-facturacion-db -o jsonpath='{.data.DB_USER}' | base64 -d; echo
kubectl -n sri-facturacion exec deploy/sri-facturacion-service-deployment -- env | grep ^DB_

# 3) Cero secretos en el repo
grep -ri "sri_demo\|DB_PASSWORD" gitops/ iac/ | grep -v tfstate || echo "LIMPIO: nada en Git"
```

**Diagnóstico si el mount falla** (`kubectl -n sri-facturacion describe pod` → eventos "FailedMount"), en
orden de probabilidad: (1) propagación RBAC (< 2 min — esperar, el kubelet reintenta); (2) `clientID` mal
copiado en SPC/SA; (3) subject de la fedcred ≠ `system:serviceaccount:sri-facturacion:sri-facturacion-sa`;
(4) rol Secrets User ausente. Misma disciplina de las 3 capas de la sesión AWS.

### FASE 6 — Ingress ON → AGIC → Application Gateway responde (20-30 min · $0 incremental)

**[AGENTE PREPARA]** el uncomment de `ingress.yaml` en `kustomization.yaml` + 2 ajustes ESPEJO del fix AWS
(2026-10-03): (a) modo **catch-all** — regla sin `host` (la variante por dominio queda comentada): AGIC crea
el listener básico del AppGW y responde a cualquier Host, incluida la IP directa; (b) backend corregido a
`sri-facturacion-service-svc` (el nombre antiguo `sri-facturacion-service` no existe en bases/service.yml →
backend pool vacío y 502 eterno — el mismo bug del '404 eterno' del ALB).

```bash
kubectl kustomize gitops/overlays/azure-aks | python3 -c "import sys,yaml; print(len(list(yaml.safe_load_all(sys.stdin))),'recursos')"
# esperado: 7 (aparece el Ingress)
git add gitops/overlays/azure-aks && git commit -m "azure: Ingress AGIC + App Gateway (simetria AWS ALB)" && git push
kubectl -n argocd annotate application sri-facturacion-azure-aks argocd.argoproj.io/refresh=hard --overwrite

kubectl -n sri-facturacion get ingress   # ADDRESS = IP pública del AppGW (AGIC ya lo configuró)
```

**Prueba (espejo del fix AWS 2026-10-03 — catch-all: curl directo a la IP, sin header Host):**

```bash
GW_IP=$(kubectl -n sri-facturacion get ingress sri-facturacion-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://${GW_IP}/health"                                        # 200 directo (catch-all)
for i in $(seq 1 6); do curl -s "http://${GW_IP}/api/v1/version" | jq -r .hostname; done
# → hostnames de pods DISTINTOS: balanceo real (backend pool del AppGW apunta a las IPs de los pods)
```

Con catch-all no hace falta `/etc/hosts` ni header: `hey -z 90s -c 30 "http://${GW_IP}/health"` va directo
a la IP (recordatorio: **hey ignora `-H`**, cliente Go — si algún día se vuelve al modo por dominio, usar
`/etc/hosts` como en AWS, ver Apéndice D de DEMO_STACK_AWS_FINAL.md).

**Diferencia didáctica vs AWS:** el ADDRESS del Ingress es una **IP** (no hostname DNS como el ALB); con
catch-all ambas patas responden directo sin header Host (el mismo fix aplicado en las dos nubes).

### FASE 7 — (OPCIONAL) HPA en vivo con hey (20-30 min · ~$0.02)

Solo si el tiempo alcanza. **[AGENTE PREPARA]** `hpa-patch.yaml` espejo del de AWS (JSON6902, umbral
didáctico 5% sobre `/spec/metrics/0`) + su entrada en `kustomization.yaml`. metrics-server ya viene con AKS
(no hay que instalarlo — asimetría a favor, mencionarlo).

```bash
kubectl kustomize gitops/overlays/azure-aks | grep averageUtilization   # → 5 (el 70% real vive en bases/hpa.yml)
git add gitops/overlays/azure-aks && git commit -m "azure: umbral didactico HPA (demo)" && git push

hey -z 90s -c 30 http://${GW_IP}/health             # catch-all: directo a la IP, sin hosts ni -H
kubectl -n sri-facturacion get hpa -w                # 3 → N réplicas, CPU convergiendo
```

Al terminar: comentar el patch de vuelta y push (mismo ritual de revert que AWS — el umbral real 70% vive
en la base).

### FASE 8 — Cierre FinOps (30 min)

**Paso 1 — Ingress OFF + prune** (ritual simétrico; deja el repo en el punto de partida canónico):

```bash
# [AGENTE PREPARA] el comentado de ingress.yaml en kustomization.yaml + validación + commit/push
kubectl -n sri-facturacion get ingress    # → No resources found (prune de ArgoCD)
```

Nota didáctica: a diferencia de AWS (donde el prune borraba el ALB), aquí el AppGW sigue vivo hasta el
destroy — porque nació del CLÚSTER, no del Ingress. El AGIC solo desconfigura listeners/backend pools.

**Paso 2 — ⛔ CHECKPOINT anti-huérfano:**

```bash
az network application-gateway list -o table
# → DEBE mostrar SOLO el del RG MC_ (el que muere con el clúster). Si hubiera otro → investigar ANTES del destroy.
az network public-ip list --query "[].{name:name,rg:resourceGroup}" -o table
```

**Paso 3 — Destroy (solo el state del clúster; el key-vault tiene `prevent_destroy` y state aparte):**

```bash
cd iac/azure && terraform destroy     # fedcred + AKS + RG sri-aks-rg (~5-8 min)
# El node RG MC_* (con AppGW + IP pública) lo borra AKS asíncronamente: esperar 2-5 min
```

**Paso 4 — Verificación $0/h:**

```bash
az network application-gateway list -o table    # → vacío
az aks list --query "[].name" -o tsv            # → vacío
az group list --query "[?starts_with(name,'MC_')].name" -o tsv   # → vacío
```

**Paso 5 — Plataforma permanente intacta (la frontera):**

```bash
az keyvault show -g sri-tfstate-rg -n sri-keyvault-23c5 --query name -o tsv     # vivo
az identity show -g sri-tfstate-rg -n sri-facturacion-wi --query clientId -o tsv # viva (clientId estable)
az acr show -n sriacrtfm23c5 --query name -o tsv                                 # vivo
```

**Paso 6 — Estado final del repo:** overlay Azure con secretos ACTIVOS y valores permanentes commiteados.
La próxima sesión (o la defensa) es solo: `terraform apply` del clúster → ArgoCD → todo converge, sin editar
un solo manifiesto. Ese es el argumento de reproducibilidad más fuerte del TFM.

---

## 5. Archivos que prepara el agente (contenido completo)

### 5.1 `iac/azure/key-vault/` — NUEVO módulo permanente

**`main.tf`:**

```hcl
# ============================================
# Root Module: Azure Key Vault + Managed Identity del workload (PLATAFORMA)
# PERMANENTE: sobrevive al ciclo destroy/apply del clúster (state propio,
# key azure/key-vault.tfstate — patrón de iac/azure/registry/).
#
# Homólogo conceptual del almacén de secretos de AWS, con una diferencia
# deliberada y defendible: aquí el almacén y la identidad son de LARGA VIDA
# porque (a) su costo es residual (~$0.03/secreto/mes; la MI es gratis) y
# (b) el nombre del Key Vault es único GLOBAL con soft-delete de 90 días —
# recrearlo por sesión invitaría al infierno del soft-delete. En AWS todo el
# módulo secrets-csi es efímero porque SSM no tiene esas restricciones. La
# frontera permanente/efímero se adapta al servicio; el patrón es el mismo.
#
# LO QUE NO VIVE AQUÍ: el federated identity credential (issuer OIDC con
# UUID por clúster) vive en iac/azure/main.tf y muere con el clúster —
# homólogo del trust IRSA efímero de AWS.
#
# LOS SECRETOS NO NACEN EN TERRAFORM: azurerm_key_vault_secret exigiría rol
# data-plane (Key Vault Secrets Officer) para el SP terraform-ci, rompiendo
# el least-privilege. Se siembran UNA SOLA VEZ con el bootstrap humano
# (scripts/bootstrap-keyvault-rbac-azure.sh) — decisión registrada
# "bootstrap privilegiado humano único vs operación recurrente SP". Bonus:
# el state de Terraform NO contiene ningún valor secreto.
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "sri-tfstate-rg"
    storage_account_name = "sritfstate23c5"
    container_name       = "tfstate"
    key                  = "azure/key-vault.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# La casa de la plataforma: mismo RG del ACR y del backend (permanente).
data "azurerm_resource_group" "platform" {
  name = var.resource_group_name
}

resource "azurerm_key_vault" "main" {
  name                      = var.key_vault_name
  location                  = data.azurerm_resource_group.platform.location
  resource_group_name       = data.azurerm_resource_group.platform.name
  tenant_id                 = var.tenant_id
  sku_name                  = "standard"

  # Modelo RBAC (recomendado; las access policies son legado). La MI del
  # workload recibe "Key Vault Secrets User" vía bootstrap humano (el SP
  # Contributor no puede crear role assignments).
  enable_rbac_authorization = true

  # Sin purge protection: si algún día se elimina de verdad, permitir purge
  # manual del nombre (prevent_destroy ya protege en la capa Terraform).
  purge_protection_enabled = false

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Identidad del workload — homólogo del ROL IRSA de AWS. El SA del pod se
# federa a esta identidad (federated credential en iac/azure/main.tf).
# Su clientId es PÚBLICO (no secreto): viaja commiteado en el overlay
# (SPC clientID + anotación del SA), igual que el ARN del rol en AWS.
resource "azurerm_user_assigned_identity" "workload" {
  name                = var.identity_name
  location            = data.azurerm_resource_group.platform.location
  resource_group_name = data.azurerm_resource_group.platform.name

  tags = var.tags
}
```

**`variables.tf`:**

```hcl
# ============================================
# Variables: Root Module Azure Key Vault (plataforma)
# ============================================

variable "resource_group_name" {
  description = "RG de plataforma permanente (mismo del ACR y del backend de estado)"
  type        = string
  default     = "sri-tfstate-rg"
}

variable "key_vault_name" {
  description = "Nombre del Key Vault — ÚNICO GLOBAL (misma regla que storage/ACR; sufijo 23c5 de la suscripción)"
  type        = string
  default     = "sri-keyvault-23c5"
}

variable "identity_name" {
  description = "Managed Identity user-assigned del workload (homólogo del rol IRSA de AWS)"
  type        = string
  default     = "sri-facturacion-wi"
}

variable "tenant_id" {
  description = "Tenant Entra ID del vault (identificador público, no secreto)"
  type        = string
  default     = "0fc1436e-05f9-416b-9d88-a108f4a1133b"
}

variable "tags" {
  description = "Tags comunes"
  type        = map(string)
  default = {
    Project     = "SRI-GitOps-Multicloud"
    ManagedBy   = "Terraform"
    Environment = "production"
    Cloud       = "azure"
  }
}
```

**`outputs.tf`:**

```hcl
# ============================================
# Outputs: Root Module Azure Key Vault
# ============================================

output "key_vault_name" {
  description = "Nombre del vault (viaja en la SPC del overlay)"
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "URI del vault"
  value       = azurerm_key_vault.main.vault_uri
}

output "identity_client_id" {
  description = "clientId PÚBLICO de la MI — viaja en la SPC (clientID) y en la anotación del SA"
  value       = azurerm_user_assigned_identity.workload.client_id
}

output "identity_principal_id" {
  description = "principalId (objeto) — lo consume el bootstrap para el rol Secrets User"
  value       = azurerm_user_assigned_identity.workload.principal_id
}

output "identity_id" {
  description = "Id completo del recurso MI — parent de la federated credential (iac/azure)"
  value       = azurerm_user_assigned_identity.workload.id
}
```

### 5.2 Edit del submódulo del clúster — `iac/modules/kubernetes-cluster/azure/main.tf`

Dentro de `resource "azurerm_kubernetes_cluster" "main"`, después de `identity { … }`:

```hcl
  # ============================================
  # Sesión 2026-10-08: identidad de workload + add-ons CSI/AGIC
  # ============================================

  # Emisor OIDC + webhook de Workload Identity (homólogo del OIDC provider
  # de EKS que consumía IRSA): sin esto no existe la federación SA→MI.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Driver CSI de secretos como add-on GESTIONADO (homólogo del chart Helm
  # del provider AWS de bootstrap-secrets-csi-eks.sh; aquí lo opera MS).
  # Nota azurerm: el bloque exige secret_rotation_enabled explícito.
  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }

  # AGIC GREENFIELD: crea un Application Gateway v2 (gateway_name) en una
  # subnet nueva del VNet managed del clúster (10.225.0.0/24). INCIDENTE
  # REAL (2026-10-08): el clúster usa Azure CNI Overlay (default de AKS
  # moderno) y el add-on RECHAZA prefijos menores a /24 con
  # "IngressAppGwAddonConfigInvalidSubnetCIDR" — el /16 de los ejemplos
  # kubenet clásicos ya no aplica. El AppGW muere con el node RG MC_ en el
  # destroy → cero huérfanos por diseño. Homólogo de la cadena LB
  # Controller→ALB de AWS. Factura desde el apply (~$0.02-0.05/h), no
  # desde el Ingress.
  # Nota azurerm v3 (verificado en provider 3.117): exige UNO de
  # gateway_id / subnet_id / subnet_cidr — la versión original del plan
  # (enabled = true) es del esquema v2 y falla la validación en v3.
  ingress_application_gateway {
    gateway_name = "sri-appgw"
    subnet_cidr  = "10.225.0.0/24"
  }
```

**`iac/modules/kubernetes-cluster/azure/outputs.tf`** — agregar:

```hcl
output "oidc_issuer_url" {
  description = "Issuer OIDC del clúster (URL con UUID propio — cambia en cada recreate)"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}
```

### 5.3 Edit del root del clúster — `iac/azure/main.tf` (+ `variables.tf`)

Después del bloque `module "aks" { … }`:

```hcl
# ============================================
# Federación SA → Managed Identity (sesión 2026-10-08)
# Homólogo del trust policy IRSA de AWS (iac/aws/secrets-csi). El issuer
# OIDC de AKS lleva un UUID POR CLÚSTER → la credencial federada es EFÍMERA:
# vive en ESTE state y se recrea con cada clúster. La MI es PERMANENTE
# (iac/azure/key-vault); aquí solo se referencia vía data source (dirección
# segura de dependencia: lo efímero lee lo permanente).
# ============================================
data "azurerm_user_assigned_identity" "workload" {
  name                = var.workload_identity_name
  resource_group_name = var.platform_resource_group_name
}

resource "azurerm_federated_identity_credential" "workload" {
  name        = "sri-facturacion-sa"
  parent_id   = data.azurerm_user_assigned_identity.workload.id
  audience    = ["api://AzureADTokenExchange"]
  issuer      = module.aks.oidc_issuer_url
  subject     = "system:serviceaccount:sri-facturacion:sri-facturacion-sa"
}
```

**`iac/azure/variables.tf`** — agregar:

```hcl
variable "workload_identity_name" {
  description = "MI permanente del workload (creada por iac/azure/key-vault)"
  type        = string
  default     = "sri-facturacion-wi"
}

variable "platform_resource_group_name" {
  description = "RG de plataforma permanente (Key Vault, ACR, backend)"
  type        = string
  default     = "sri-tfstate-rg"
}
```

### 5.4 `scripts/bootstrap-keyvault-rbac-azure.sh` — NUEVO (bootstrap humano)

```bash
#!/usr/bin/env bash
# ============================================================
# Bootstrap humano único del Key Vault (plataforma de secretos Azure)
#   1. Rol "Key Vault Secrets User"   -> Managed Identity del workload
#   2. Rol "Key Vault Secrets Officer"-> identidad HUMANA firmada
#   3. Siembra idempotente de los 3 secretos demo (solo si NO existen)
#   4. Verificación final (sin exponer valores)
#
# Espejo del patrón bootstrap-acr-rbac-azure.sh: el RBAC es "bootstrap
# privilegiado humano" (el SP terraform-ci es Contributor: NO puede crear
# role assignments ni escribir secretos — least privilege por diseño).
# Matiz de Key Vault RBAC: ni Owner escribe secretos sin rol data-plane.
#
# Uso (requiere 'az login' HUMANO con Owner):
#   bash scripts/bootstrap-keyvault-rbac-azure.sh
# Idempotente: re-ejecutar no duplica roles ni sobrescribe secretos.
# ============================================================
set -euo pipefail

KV_NAME="${KV_NAME:-sri-keyvault-23c5}"
IDENTITY_NAME="${IDENTITY_NAME:-sri-facturacion-wi}"
RG="${PLATFORM_RG:-sri-tfstate-rg}"
DEMO_DB_USER="${DEMO_DB_USER:-sri_demo_user}"
DEMO_DB_HOST="${DEMO_DB_HOST:-sri-facturacion-demo.postgres.database.azure.com}"

echo ">> Key Vault: ${KV_NAME} (RG ${RG})"
echo ">> Identidad: ${IDENTITY_NAME}"
echo

# ----- Guards -----
command -v az >/dev/null || { echo "FALTA az CLI"; exit 1; }
if ! az ad signed-in-user show >/dev/null 2>&1; then
  echo "ERROR: esta sesión NO es una identidad humana (az ad signed-in-user falló)."
  echo "  El RBAC exige Owner humano: az login y re-ejecutar."
  exit 1
fi

KV_ID=$(az keyvault show --name "${KV_NAME}" --query id -o tsv)
MI_PRINCIPAL=$(az identity show -g "${RG}" -n "${IDENTITY_NAME}" --query principalId -o tsv)
MI_CLIENT_ID=$(az identity show -g "${RG}" -n "${IDENTITY_NAME}" --query clientId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
echo ">> KV id:    ${KV_ID}"
echo ">> MI (principal): ${MI_PRINCIPAL}"
echo ">> MI (clientId — va al overlay): ${MI_CLIENT_ID}"
echo

# ----- Helper idempotente de roles -----
role_exists() { # $1 object_id  $2 rol  $3 scope
  [ -n "$(az role assignment list --assignee-object-id "$1" --role "$2" --scope "$3" --query '[].id' -o tsv)" ]
}

ensure_role() { # $1 object_id  $2 principal-type  $3 rol  $4 scope
  if role_exists "$1" "$3" "$4"; then
    echo "[=] Rol '$3' ya asignado."
  else
    echo "[+] Asignando rol '$3'..."
    az role assignment create --role "$3" \
      --assignee-object-id "$1" --assignee-principal-type "$2" \
      --scope "$4" --output none
    echo "[+] Rol '$3' asignado."
  fi
}

# 1) La identidad del WORKLOAD lee secretos (la usa el pod via CSI)
ensure_role "${MI_PRINCIPAL}" ServicePrincipal "Key Vault Secrets User" "${KV_ID}"

# 2) El HUMANO puede escribir secretos (siembra una sola vez)
ensure_role "${ME}" User "Key Vault Secrets Officer" "${KV_ID}"

# ----- Siembra idempotente (nunca sobrescribe) -----
ensure_secret() { # $1 nombre  $2 valor
  if az keyvault secret show --vault-name "${KV_NAME}" --name "$1" >/dev/null 2>&1; then
    echo "[=] Secreto '$1' ya existe (no se sobrescribe)."
  else
    echo "[+] Sembrando secreto '$1'..."
    # Retry: la propagación del rol Officer puede tardar 1-2 min
    for i in 1 2 3 4 5 6; do
      if az keyvault secret set --vault-name "${KV_NAME}" --name "$1" --value "$2" >/dev/null 2>&1; then
        echo "[+] Secreto '$1' sembrado."
        return 0
      fi
      echo "    propagando RBAC (intento ${i}/6, 10s)..."
      sleep 10
    done
    echo "ERROR: no se pudo escribir '$1' (¿rol Officer propagado?)"; return 1
  fi
}

DB_PASSWORD=$(openssl rand -base64 18)
ensure_secret db-username "${DEMO_DB_USER}"
ensure_secret db-password "${DB_PASSWORD}"
ensure_secret db-host     "${DEMO_DB_HOST}"

# ----- Verificación final (nombres, no valores) -----
echo
az keyvault secret list --vault-name "${KV_NAME}" --query '[].name' -o table
echo
echo ">> Listo para la FASE 5. El clientId para el overlay ya se imprimió arriba"
echo "   (o: terraform -chdir=iac/azure/key-vault output -raw identity_client_id)."
```

### 5.5 Overlay `gitops/overlays/azure-aks/` — reescrituras

**`secrets-store-csi.yaml`** (modo Workload Identity — se rellena con el clientId REAL de FASE 1):

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: sri-facturacion-azure-secrets
  labels:
    app: sri-facturacion-service
spec:
  provider: azure
  parameters:
    # MODO WORKLOAD IDENTITY (mejor práctica actual — homólogo de IRSA):
    # el provider canjea el token proyectado del SA del pod (webhook de WI,
    # label azure.workload.identity/use) por el token de la Managed Identity
    # FEDERADA (iac/azure/main.tf). clientId PÚBLICO (no secreto), valor de:
    #   terraform -chdir=iac/azure/key-vault output -raw identity_client_id
    usePodIdentity: "false"
    clientID: "<MANAGED_IDENTITY_CLIENT_ID>"
    keyvaultName: "sri-keyvault-23c5"
    tenantId: "0fc1436e-05f9-416b-9d88-a108f4a1133b"
    # Secretos sembrados por bootstrap humano (runtime, jamás en Git)
    objects: |
      array:
        - |
          objectName: db-username
          objectType: secret
          objectAlias: DB_USER
        - |
          objectName: db-password
          objectType: secret
          objectAlias: DB_PASSWORD
        - |
          objectName: db-host
          objectType: secret
          objectAlias: DB_HOST
  # Sincroniza a un Secret nativo (idéntico mecanismo que en AWS)
  secretObjects:
    - secretName: sri-facturacion-db
      type: Opaque
      data:
        - objectName: DB_USER
          key: DB_USER
        - objectName: DB_PASSWORD
          key: DB_PASSWORD
        - objectName: DB_HOST
          key: DB_HOST
```

**`serviceaccount.yaml`** (NUEVO — espejo del de AWS con el ARN):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sri-facturacion-sa
  annotations:
    # IDENTIDAD DEL MONTAJE CSI (homólogo de eks.amazonaws.com/role-arn):
    # el webhook de Workload Identity inyecta al pod (label
    # azure.workload.identity/use) la proyección del token; el provider
    # Azure lo canjea por el de ESTA Managed Identity vía la federated
    # credential (subject system:serviceaccount:sri-facturacion:sri-facturacion-sa).
    # El clientId es un identificador PÚBLICO de recurso (no es secreto),
    # igual que el ARN del rol viajaba commiteado en AWS.
    azure.workload.identity/client-id: "<MANAGED_IDENTITY_CLIENT_ID>"
```

**`deployment-secrets-patch.yaml`** (reescrito — BUG #7 CORREGIDO + WI):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  # BUG #7 CORREGIDO (misma lección que AWS): metadata.name Y container name
  # apuntan al nombre REAL del base. El original decía
  # 'sri-facturacion-service' → el strategic merge creaba un Deployment
  # nuevo/segundo contenedor en vez de parchear el existente.
  name: sri-facturacion-service-deployment
spec:
  template:
    metadata:
      labels:
        # Activa el webhook de Workload Identity sobre ESTE pod (proyección
        # del token federado) — homólogo del SA anotado con el rol IRSA.
        azure.workload.identity/use: "true"
    spec:
      # SA dedicado anotado con el clientId (serviceaccount.yaml)
      serviceAccountName: sri-facturacion-sa
      containers:
        - name: sri-facturacion-service-deployment
          # envFrom se reemplaza por completo: ConfigMap base + Secret
          # sincronizado por secretObjects (DB_USER/DB_PASSWORD/DB_HOST)
          envFrom:
            - configMapRef:
                name: sri-facturacion-config
            - secretRef:
                name: sri-facturacion-db
          volumeMounts:
            - name: secrets-store
              mountPath: /mnt/secrets-store
              readOnly: true
      volumes:
        - name: secrets-store
          csi:
            # Nombre REAL del driver CSI (root cause incidente #4 en AWS:
            # es secrets-store.csi.k8s.io SIN "x-"; el x-k8s.io es el grupo
            # API del CRD SPC, no el nombre del driver). Fix preventivo.
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: sri-facturacion-azure-secrets
```

**`kustomization.yaml`** — estado tras la FASE 5 (los items con historia canónica):

```yaml
resources:
- ../../bases
# SESION SECRETOS (2026-10-08): ACTIVADO — requiere driver CSI + provider
# Azure (add-on key_vault_secrets_provider del módulo AKS), Key Vault
# sri-keyvault-23c5 + MI sri-facturacion-wi (iac/azure/key-vault, estado
# PERMANENTE) y fedcred (iac/azure). Valores públicos commiteados: tras esta
# sesión el overlay NO requiere edición en recreates del clúster.
- secrets-store-csi.yaml
- serviceaccount.yaml
#- ingress.yaml
# TEMPORAL (FASE 6 de la sesión 2026-10-08): AGIC add-on ya corre en el
# clúster (ingress_application_gateway del módulo AKS) y el AppGW v2 ya
# factura desde el apply — activarlo es solo quitar el comentario.

patches:
- path: configmap-patch.yaml
  target:
    kind: ConfigMap
    name: sri-facturacion-config
# SESION SECRETOS (2026-10-08): activado CON el fix del bug #7 —
# metadata.name y container name del patch = sri-facturacion-service-deployment
# (el nombre REAL del base; sin el fix del container name, el strategic merge
# añadiría un segundo contenedor en vez de parchear el existente).
- path: deployment-secrets-patch.yaml
  target:
    kind: Deployment
    name: sri-facturacion-service-deployment
```

(en la FASE 6 solo se descomenta `- ingress.yaml`; en la FASE 7 opcional se agrega el bloque del
`hpa-patch.yaml` con indentación canónica de 0 espacios — lección de la sesión AWS).

### 5.6 `hpa-patch.yaml` (opcional, FASE 7 — espejo del de AWS)

```yaml
# UMBRAL DIDÁCTICO (espejo de aws-eks/hpa-patch.yaml): baja el target de CPU
# del HPA de 70% a 5% para que la demo de carga escale con endpoints baratos
# (/health es async y no quema CPU). JSON6902: /spec/metrics/0 = CPU.
# REVERTIR al cerrar la sesión o al destruir el clúster.
- op: replace
  path: /spec/metrics/0/resource/target/averageUtilization
  value: 5
```

---

## 6. Riesgos conocidos e incidentes esperados

| # | Riesgo/incidente | Mitigación |
|---|---|---|
| 1 | Nombre del KV tomado globalmente | Fallback de sufijo en `variables.tf`; error claro de Azure al crear |
| 2 | Soft-delete del KV (90 días) reserva el nombre | KV es PERMANENTE (`prevent_destroy`); si algún día se elimina, purge manual permitido (purge protection off) |
| 3 | Propagación RBAC 1-2 min (rol MI y rol humano) | Retry en el script; el kubelet reintenta el mount — incidente didáctico, no bug |
| 4 | State del clúster sin reconciliar tras el destroy del 10-02 | ⛔ Checkpoint en FASE 0 (state list vacío antes de planear) |
| 5 | AppGW factura desde FASE 2 aunque el Ingress llegue en FASE 6 | Presupuestado (~$0.02-0.05/h); SKU verificado en vivo |
| 6 | Bug #7 (metadata.name del patch) | Corregido en el rewrite — misma lección que AWS |
| 7 | Indentación al descomentar items de secuencia en kustomization | Validación `kubectl kustomize` ANTES de cada commit (el pipeline NO valida `gitops/**` — hueco conocido) |
| 8 | hey ignora `-H "Host:…"` (cliente Go) | `/etc/hosts` + URL del dominio — lección AWS transferida |
| 9 | Issuer OIDC cambia por recreate (UUID) | Por diseño: fedcred en el state del clúster; Terraform la recrea en cada apply |
| 10 | ImagePullBackOff tras recreate (kubelet identity sin AcrPull) | Re-ejecutar `bootstrap-acr-rbac-azure.sh` (incidente ya guionizado) |
| 11 | **INCIDENTE REAL 2026-10-08**: con Azure CNI Overlay (default de AKS moderno), el add-on AGIC RECHAZA `subnet_cidr` con prefijo < /24 (`IngressAppGwAddonConfigInvalidSubnetCIDR`) | Fix: `subnet_cidr = "10.225.0.0/24"` — retry limpio del apply (el RG ya había quedado creado; el clúster no llegó a provisionarse) |

## 7. Preguntas probables del jurado (pata Azure)

**"¿Por qué Workload Identity y no la kubelet identity del clúster?"** — Mínimo privilegio por workload:
solo el SA `sri-facturacion-sa` puede federarse a esa MI; la identidad no depende del node pool y es
auditable (Activity Log). Homólogo exacto de IRSA en AWS. MS lo recomienda (pod-identity deprecado 2022).

**"¿Por qué el Application Gateway no es un recurso Terraform?"** — Misma filosofía que el ALB en AWS:
el recurso data-plane nace del operador del clúster (add-on AGIC) y muere con él (RG MC_) — la IaC declara
el comportamiento (bloque `ingress_application_gateway`) y Azure materializa el recurso. Resultado: cero
huérfanos por diseño, sin regla de oro que vigilar.

**"¿Diferencia entre ALB y Application Gateway?"** — Ambos L7. AppGW v2 añade WAF integrado, terminación
TLS, rewrites y routing avanzado. El PATRÓN (Ingress declarativo + controller que reconcilia) es idéntico:
eso es lo que demuestra la simetría.

**"¿Por qué el Key Vault es permanente si en AWS todo el módulo de secretos era efímero?"** — Las
restricciones de cada servicio mandan sobre la simetría literal: el nombre del KV es único global con
soft-delete de 90 días y su costo es residual. La arquitectura permanente/efímero se adapta; el patrón de
consumo no cambia.

**"¿Dónde está el secreto?"** — En ninguna parte del repo ni del state de Terraform: nace en runtime
(`openssl` → KV) y el pod lo consume montado. Mejora sobre AWS, donde `random_password` vivía en el tfstate
(riesgo documentado).

**"¿Qué pasa si recrean el clúster mañana?"** — `terraform apply` del clúster: fedcred nueva (issuer nuevo),
AppGW nuevo, ArgoCD converge, pods montan secretos del mismo KV permanente. Cero ediciones de manifiestos:
el overlay quedó listo para siempre (D8).

**"¿Costo de la plataforma permanente Azure?"** — ACR Basic ~$5/mes + KV ~$0.10/mes (3 secretos) + storage
del backend ~centavos + MI $0 ≈ **$5.2/mes**. GitHub Actions $0 (repo público, OIDC sin secretos).

## 8. Estado esperado al cierre de la sesión

- ✅ Secretos Key Vault montados por CSI vía Workload Identity (evidencia completa: archivos, Secret sync,
  envFrom, cero en Git)
- ✅ Ingress → AGIC → App Gateway respondiendo con balanceo real entre pods
- ✅ (Opcional) HPA escalando en vivo
- ✅ Destroy limpio: AppGW + IP + node RG verificados $0/h; plataforma permanente intacta
- ✅ Overlay Azure con valores permanentes → reproducibilidad total para la defensa
- 📝 Redactar ADR-003 (`docs/decisions/`) con la decisión nativos-por-nube, ya con AMBAS patas implementadas
- 📝 Actualizar este documento de PLAN → registro con evidencias, y DEMO_AZURE_GITOPS_JURADO.md con la
  nueva fase de secretos+ingress para el guion final

---

*Documento vivo: gemelo Azure de AWSSecretsSSM-CSI.md y AWSLoadBalancer-ControllerIRSA.md. Se actualiza al
ejecutar cada fase. Redactado 2026-10-07 (previo a la sesión del 2026-10-08).*
