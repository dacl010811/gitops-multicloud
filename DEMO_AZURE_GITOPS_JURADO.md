# DEMO Azure GitOps al Jurado — Guion y Runbook de Defensa

> **Propósito de este documento:** guion completo, comando a comando, con lo que se dice al jurado en cada pantalla, para demostrar la reproducibilidad total de la plataforma Azure: desde un cluster **destruido (cero)** hasta la aplicación respondiendo con un cambio de código viajando de Git a producción sin intervención humana.
>
> **Estado del ensayo (2026-10-01):** FASE 0 completada · FASE 1 en curso · Fases 2-7 planeadas (guion listo).

---

## 0. Narrativa de apertura (aprender de memoria, 30 segundos)

> *"Mi plataforma separa lo **permanente** de lo **efímero**. El registro de imágenes, el estado de Terraform y la federación de identidades GitHub↔Azure están protegidos con `prevent_destroy` y documentados — son plataforma. Lo efímero es el cluster. Voy a demostrar la reproducibilidad: **el cluster no existe**, y en los próximos 30 minutos lo reconstruyo completo con comandos en vivo, sin tocar la consola web, hasta tener la aplicación respondiendo — y luego un cambio de código viajando de Git a producción sin intervención humana."*

**Regla de oro que se repite durante toda la demo:** plataforma permanente (ACR, backend de estado, OIDC, repo) vs. infraestructura efímera (cluster, que solo se paga mientras se usa).

## 1. Plan general — 7 fases, ~35 minutos con narrativa

| Fase | Qué demuestras | Tiempo |
|---|---|---|
| 0. Punto de partida | El cluster está en cero, la plataforma permanente existe | 3 min |
| 1. Provisión IaC | Terraform + backend remoto + SP + módulo agnóstico | ~5 min cmd + 5 min espera |
| 2. Acceso al cluster | kubeconfig vía Entra ID | 2 min |
| 3. ArgoCD | Por qué `--server-side` (bug de las CRDs de 256KB) | 2 min + 2 min espera |
| 4. Application GitOps | **Git = fuente de verdad**: el cluster recién nacido converge solo | 3 min |
| 5. UI ArgoCD | La pantalla para el jurado | 2 min |
| 6. El bucle vivo (estrella) | Código → GitHub Actions con OIDC → build dual-cloud → bump → ArgoCD → app respondiendo | ~10 min |
| 7. Cierre FinOps | Destruir lo efímero, factura bajo control | 3 min |

**Costo total del ensayo/demo: ~$0.15-0.25** (AKS ~$0.10/h durante ~2h + centavos de ACR ya provisionado). Todo lo demás: $0 (GitHub Actions es gratis en repo público).

---

## 2. FASE 0 — Punto de partida (el "antes" fotografiado)

**Costo: $0** (solo lecturas).

Dramaturgia: *primero el repositorio (fuente de verdad), luego mi identidad, luego el vacío del cluster, y finalmente la plataforma permanente intacta. Cuatro pantallas, cuatro frases.*

### PASO 0.1 — El repositorio, origen de todo

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud
git status && git branch --show-current && git log --oneline -3
```

**Di al jurado:** *"Todo lo que verán nace de este repositorio: el código Python, los manifiestos Kubernetes y la infraestructura como código conviven en un monorepo. El commit más reciente lo firmó el propio pipeline — `github-actions[bot]` — actualizando la versión de la imagen. Git no solo guarda mi código: guarda el estado deseado de mi producción."*

**Salida esperada:** `nothing to commit` · rama `feature-patron-appOfapps` · commits `405b2b3` (bump del bot) y "Version en AKS + Image ACR Federado".

### PASO 0.2 — Autenticación con la identidad de automatización

```bash
read -s AZ_SECRET    # pega el client secret: NO se ve en pantalla, ni en la demo

az login --service-principal \
  --username "f50eded8-ffef-4864-8e08-b62ab0ed18bf" \
  --password "$AZ_SECRET" \
  --tenant "0fc1436e-05f9-416b-9d88-a108f4a1133b"
unset AZ_SECRET

az account show --query "{identidad:user.name, tipo:user.type, suscripcion:id}" -o table
```

**Di al jurado:** *"Me autentico como el Service Principal `terraform-ci-azure` — la identidad de automatización del proyecto, con permisos mínimos, sin intervención humana. Y fíjense en el detalle: el secret se pegó oculto, sin eco en pantalla. Esta misma identidad, en la nube, se autentica vía federación OIDC sin password alguno — se los demuestro en la Fase 6."*

**Salida esperada:** `tipo: servicePrincipal`.

**Nota técnica (si preguntan):** la sesión activa de `az` es la última que ganó en la caché global (`~/.azure/`); Terraform no usa esa sesión, usa `ARM_*`. Verificar siempre con `az account show --query user.type`.

### PASO 0.3 — La prueba del cero

```bash
az aks show -g sri-aks-rg -n sri-aks-cluster 2>&1 | head -3
```

**Di al jurado:** *"Verifiquen conmigo: el cluster de Kubernetes **no existe**. Lo destruí al cerrar la sesión anterior — la infraestructura efímera se paga solo mientras se usa. En los próximos 20 minutos lo reconstruyo completo desde código."*

**Salida esperada:** `(ResourceNotFoundError) Resource not found...` — **ese error es la evidencia estrella, no un fallo.**

### PASO 0.4 — La plataforma permanente intacta

```bash
az acr show -g sri-tfstate-rg -n sriacrtfm23c5 \
  --query "{login:loginServer, sku:sku.name}" -o table

az acr repository list -n sriacrtfm23c5 -o table

az acr repository show-tags -n sriacrtfm23c5 \
  --repository sri-facturacion-service -o table
```

**Di al jurado:** *"Pero el registro de contenedores persiste: está protegido con `prevent_destroy` en Terraform porque es plataforma, no efímero. Y aquí está la imagen que el pipeline construyó mediante federación OIDC — el cluster murió, el artefacto permanece. Esto es la separación permanente/efímero en acción."*

**Salida esperada:** `sriacrtfm23c5.azurecr.io` · SKU `Basic` · repositorio `sri-facturacion-service` · tags (sha `405b2b3...`, `latest`, `v1`).

**✅ Estado del ensayo:** FASE 0 COMPLETADA al 100% (2026-10-01).

---

## 3. FASE 1 — Provisión del AKS con Terraform (el cluster nace)

**Costo:** a partir del `apply` corre el cluster — **~$0.10/hora** (único costo de la demo). `init` y `plan` gratuitos.

### PASO 1.1 — Identidad para Terraform (`ARM_*`, independiente del `az login`)

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud/iac/azure

export ARM_CLIENT_ID="f50eded8-ffef-4864-8e08-b62ab0ed18bf"
export ARM_TENANT_ID="0fc1436e-05f9-416b-9d88-a108f4a1133b"
export ARM_SUBSCRIPTION_ID="23c5c742-7e58-48a5-8131-697efc71a366"
read -s ARM_CLIENT_SECRET    # el mismo secret, oculto; queda fijado SOLO en esta terminal
```

**Di al jurado:** *"Para Terraform exporto las credenciales del Service Principal en variables `ARM_*`. Detalle arquitectónico importante: el provider azurerm **no** usa mi sesión de Azure CLI — usa exclusivamente estas variables. Eso significa que este mismo apply funcionaría en cualquier runner del pipeline sin login interactivo: la identidad viaja con el proceso, no con la persona."*

### PASO 1.2 — Init: el estado que sobrevive a todo

```bash
terraform init
```

**Di al jurado:** *"`init` descarga providers y, lo esencial, conecta el backend remoto: mi estado vive en un Storage Account protegido, no en esta laptop. Cuando destruí el cluster, el estado quedó intacto — por eso hoy Terraform sabe exactamente qué existe y qué falta, y puede reconciliar."*

**Salida esperada:** backend `azurerm` con storage account `sritfstate23c5`, key `azure/terraform.tfstate` + `Success! Terraform has been successfully initialized!`

### PASO 1.3 — Plan: leer antes de ejecutar (ritual profesional)

```bash
terraform plan
```

**Di al jurado:** *"Nunca ejecuto un apply sin leer el plan — es el contrato de la infraestructura declarativa. Espero un plan quirúrgico."*

**Salida esperada (resumen final):** `Plan: 1 to add, 0 to change, 0 to destroy` — solo el clúster `sri-aks-cluster`. Los resource groups y el backend ya existen; nada se recrea.

### PASO 1.4 — Apply

```bash
terraform apply
```

Confirmar con `yes`. **Tarda ~4-5 min** — ventana de narrativa:

> *"Mientras se crea: esto es un módulo Terraform agnóstico por diseño. La misma intención declarativa —un cluster Kubernetes con 3 nodos y networking básico— se materializa con el provider de cada nube. En AWS el equivalente ya lo demostré con EKS. La IaC no porta el proveedor; porta el patrón."*
>
> *"Y fíjense en la autenticación: estas cuatro variables son todo lo que el pipeline necesita en su runner — el Service Principal es una identidad de Entra ID. El principio de mínimo privilegio: este SP solo puede tocar lo que la suscripción le permite."*

**Salida esperada:** `Apply complete! Resources: 1 added` + outputs (host, kube_config...).

**✅ Estado del ensayo:** FASE 1 COMPLETADA (2026-10-01) — `Apply complete! Resources: 1 added` con los outputs del clúster.

---

## 4. FASE 2 — Acceso al cluster (2 min)

```bash
az aks get-credentials --resource-group sri-aks-rg --name sri-aks-cluster --overwrite-existing
kubectl get nodes
```

**Di al jurado:** *"El kubeconfig lo obtengo con mi identidad de Entra ID — no hay certificados ni claves SSH repartidas. El cluster acaba de nacer con 3 nodos `Ready`."*

**Salida esperada:** 3 nodos `Standard_D2s_v3` en estado `Ready`.

---

## 5. FASE 3 — Instalación de ArgoCD (2 min + 2 min espera)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts
kubectl get pods -n argocd -w
```

**Di al jurado:** *"Instalo ArgoCD con `kubectl apply --server-side`. ¿Por qué server-side? Las CRDs de ApplicationSet superan los 256KB de la anotación `last-applied-configuration` y el apply cliente falla — el server-side apply gestiona el campo en el servidor. Es un detalle que aprendí destruyendo y reconstruyendo, y quedó documentado. ArgoCD es el operador GitOps: en lugar de empujar con `kubectl apply`, él **jala** desde Git y reconcilia el cluster contra el estado deseado — con auto-sync, prune y self-heal."*

**Salida esperada:** los 7 pods de ArgoCD pasando a `Running 1/1` (redis, dex, notifications, repo-server, application-controller, applicationset-controller, server).

---

## 6. FASE 4 — Registro de la Application GitOps (3 min)

```bash
kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application-azure-aks.yaml
kubectl get applications -n argocd -w
```

**Di al jurado:** *"Registro el AppProject y la Application. Y aquí está el momento clave de todo el TFM: este cluster recién nacido **converge solo** al estado deseado. ArgoCD lee el overlay `gitops/overlays/azure-aks` del repositorio y despliega la aplicación con la imagen exacta que el pipeline dejó en Git — el tag sha que ven en pantalla. Nadie ejecutó `kubectl` para desplegar la aplicación: Git es la fuente de verdad y el cluster se alinea con él. El namespace `sri-facturacion` ni siquiera existe todavía — la Application lo crea sola (`CreateNamespace=true`)."*

**Salida esperada:** la Application pasa a `Synced` / `Healthy` con 4 recursos (ConfigMap, Service, Deployment, HPA) y 3 pods `Running`.

### INCIDENTE DIDÁCTICO — `Synced` pero `Degraded` (ocurre en CADA recreate del cluster: ensayarlo no es opcional)

**Síntoma:** la Application llega a `Synced` pero los pods quedan en `ImagePullBackOff`; en los eventos: `failed to fetch anonymous token ... 401 Unauthorized` al pull del ACR.

**Causa raíz:** la kubelet identity nace con el cluster. El `AcrPull` se le asignó al cluster ANTERIOR (destruido). Lo permanente sobrevive (ACR con `prevent_destroy` + su `AcrPush` al SP); este permiso por-cluster es parte del bootstrap efímero. La respuesta NO es un hotfix manual: es re-ejecutar el script idempotente documentado.

**Di al jurado:** *"`Synced` pero `Degraded` — ArgoCD hizo su trabajo: los recursos existen exactamente como Git los describe. El problema es de identidad: este cluster recién nacido intenta pull de la imagen y el registro no lo conoce. Ayer le dimos permiso al cluster anterior, que destruí. Esto es la frontera permanente/efímero en su forma más literal. Y mi respuesta no es tocar nada a mano: es re-ejecutar el script de bootstrap documentado — la misma operación, idempotente, cada vez que un cluster nace. Las operaciones también son código."*

```bash
# PASO 4.4 — Evidencia del diagnóstico (la identidad que "nadie conoce" todavía en el ACR)
az aks show -g sri-aks-rg -n sri-aks-cluster \
  --query identityProfile.kubeletidentity.clientId -o tsv

# PASO 4.5 — Cambiar a identidad humana (el bootstrap exige Owner; aborta si la sesión es el SP)
az login    # cuenta humana interactiva

# PASO 4.6 — Re-ejecutar el bootstrap idempotente (costo $0; propagación 1-2 min)
bash scripts/bootstrap-acr-rbac-azure.sh
# Esperado: omite el AcrPush existente + CREA el AcrPull para la NUEVA kubelet identity

# PASO 4.7 — Ver la recuperación SIN tocar los pods (Kubernetes reintenta el pull solo)
kubectl get applications -n argocd -w        # Degraded → Healthy
kubectl -n sri-facturacion get pods -w     # ImagePullBackOff → Running 1/1
```

**Di al jurado (en 4.7):** *"No voy a borrar ni reiniciar nada: Kubernetes reintenta el pull con backoff; en cuanto la propagación del rol llegue, los tres pods se levantan solos y la Application vuelve a `Healthy`. Self-healing en dos niveles: Git corrige el estado deseado, y el runtime corrige su propia recuperación."*

#### NOTA PROFESIONAL — por qué este paso exige identidad HUMANA (pregunta probable de jurado)

1. **Qué permiso implica asignar AcrPull:** crear un `roleAssignment` requiere `Microsoft.Authorization/roleAssignments/write`. El rol **Contributor no lo incluye** (Azure lo excluye explícitamente); solo `Owner` o `User Access Administrator` pueden conceder permisos sobre un recurso.
2. **Por qué Azure lo diseñó así:** si el SP de CI pudiera asignar roles, podría **asignarse a sí mismo `Owner` de la suscripción**. Un actor que puede conceder permisos puede concederse cualquier cosa — es la frontera de seguridad fundamental del plano de gestión.
3. **Por qué no darle `User Access Administrator` al SP (alternativa rechazada en el diseño):** el token del SP vive en runners de GitHub Actions que **ejecutan código del repositorio**. Si pudiera asignar roles, cualquier corrida del pipeline —incluso un PR malicioso que altere el workflow— convertiría un token robado en el compromiso total de la suscripción. La superficie de ataque dejaría de ser proporcional a la función del pipeline.
4. **El patrón que implementa:** *la identidad humana con MFA gobierna una vez; las identidades de máquina operan siempre.* La asignación de roles es un acto de gobierno: se ejecuta una vez por ciclo de vida, queda auditada en el Activity Log con identidad humana, y desde entonces el 100% de la operación recurrente (pipeline, Terraform, pulls) funciona con identidades ya autorizadas de mínimo privilegio. El script **aborta si la sesión es un Service Principal** para blindar esa frontera en código. Es el mismo patrón que `bootstrap-github-oidc-aws.sh` (admin humano crea el rol federado una vez).

**Frase de oro para memorizar:**
> *"Asignar un rol es el acto más privilegiado del plano de gestión: implica `Microsoft.Authorization/roleAssignments/write`, que Azure reserva a Owner por diseño — porque un actor que puede conceder permisos puede concederse cualquier cosa. Si mi SP de CI pudiera asignar roles, un token robado del runner sería un compromiso total de la suscripción: escalada de privilegios por construcción. Por eso el modelo es: el humano gobierna una vez, con MFA y auditoría; las máquinas operan siempre dentro de los permisos ya concedidos. El mínimo privilegio no es solo qué permisos tienes: es **quién puede concederlos**."*

---

## 7. FASE 5 — UI de ArgoCD (2 min)

```bash
kubectl port-forward svc/argocd-server -n argocd 8082:443 &
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

Abrir `https://localhost:8082` (admin + password del comando anterior).

**Di al jurado:** *"Esta es la interfaz de ArgoCD: la aplicación `sri-facturacion-azure-aks` en verde — `Healthy` y `Synced` contra el commit exacto del repositorio. Fíjense en el árbol: ConfigMap, Service, Deployment, HPA y los tres pods. Cada recurso lleva su revisión. Esto es GitOps visible."*

---

## 8. FASE 6 — El bucle vivo (LA ESTRELLA, ~10 min)

### 8.1 El cambio de código

Editar `app/main.py` — subir la versión (en el ensayo real: `4.0.0` → `5.0.0`). Reglas del commit demo: tocar **solo** `app/main.py` (el trigger del pipeline es por `paths: app/**`) y que `pytest` siga en verde.

```bash
# opcional: validar local antes de gastar una corrida
python3 -m pytest app/tests -q

git add app/main.py
git commit -m "Demo jurado: version 5.0.0 en AKS via GitOps"
git push origin feature-patron-appOfapps
```

### 8.2 La corrida del pipeline (mostrar en vivo en GitHub Actions)

**Señalar 3 cosas, en este orden:**

1. **El step `azure/login@v2` autenticándose con OIDC federado** — *"sin ningún secreto de larga vida en el repositorio"* (abrir Settings → Secrets and variables → Actions del repo para mostrar que solo hay IDs: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ACR_NAME` — ninguna contraseña).
2. **El build de la imagen en ACR por el pipeline** — *"ni siquiera tengo Docker instalado en esta laptop — el build ocurre en la nube vía buildx; el runner federado obtiene un token de Entra ID, hace login al ACR con `az acr login` y publica la imagen con el tag sha del commit."*
3. **El commit del bot `[skip ci]`** — *"el job `update-manifests` ejecuta `kustomize edit set image` en ambos overlays (aws-eks y azure-aks) y commitea con `[skip ci]` para no re-dispararse. Git acaba de cambiar de versión: la fuente de verdad se actualizó."*

**Tiempos esperados (del ensayo real):** Test ~15s · Build aws ~25s + Build azure ~38s (matriz en paralelo) · Update manifests ~7s. **Total ~1 min** (objetivo del TFM: <15 min).

### 8.3 ArgoCD reacciona solo

En la UI (o `kubectl get applications -n argocd -w`): la Application pasa por `OutOfSync/Progressing` → `Synced/Healthy` con el nuevo tag. El rollout es RollingUpdate (`maxUnavailable: 0`) — los 3 pods nuevos suben antes de bajar los viejos.

### 8.4 La verificación final (curl)

```bash
kubectl -n sri-facturacion port-forward svc/sri-facturacion-service 5000:5000 &
curl -s localhost:5000/health
curl -s localhost:5000/api/v1/version
```

**Di al jurado:** *"La respuesta muestra la versión nueva y `cluster: sri-aks-cluster` — ese valor viene de un ConfigMap inyectado por Kustomize en el overlay azure-aks. Recapitulando lo que acaban de ver: edité un número en un archivo Python, hice push, y **nadie tocó el cluster**: el pipeline testeó, construyó la imagen en dos nubes, actualizó el manifiesto en Git, y ArgoCD desplegó. De Git a producción sin credenciales humanas en el camino."*

**Salida esperada:** `{"status":"ok"}` en `/health` y la versión nueva con `cluster: sri-aks-cluster` en `/api/v1/version`.

**RESULTADO DEL ENSAYO REAL (2026-10-01):** `curl /api/v1/version` devolvió `"version":"5.0.0"`, `"cloud":"azure"`, `"cluster":"sri-aks-cluster"` con hostname del **nuevo ReplicaSet `774488f6b8`** — evidencia del rollout completo sin downtime. Las Fases 0-6 se ejecutaron de punta a punta sin desviaciones del guion, incluido el incidente didáctico del AcrPull resuelto re-ejecutando el bootstrap.

---

## 9. FASE 7 — Cierre FinOps (3 min)

### 9.1 El destroy normal (cuando la red acompaña)

```bash
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud/iac/azure
terraform destroy
```

### 9.2 Variante de red inestable (ENSAYADA EN VIVO 2026-10-01 — incluir en el guion)

Si el `terraform destroy` cae en el polling con `dial tcp ...: connect: operation timed out` (timeout de RED LOCAL hacia management.azure.com — no es error de Azure ni de permisos; ya ocurrió dos veces seguidas en el ensayo): **no reintentar `terraform destroy`** — cada intento quema 15-20 minutos y cae en el mismo polling. El delete ya fue disparado y Azure borra de forma asíncrona.

```bash
# 1. Estado con UNA llamada corta (los polls cortos pasan aun con red intermitente)
az aks show -g sri-aks-rg -n sri-aks-cluster --query provisioningState -o tsv 2>&1 | head -2
# Deleting    → no lanzar nada; repetir la consulta cada 2-3 min hasta ResourceNotFoundError
# Succeeded   → el delete se abortó al romperse el polling; disparar:
#               az aks delete --resource-group sri-aks-rg --name sri-aks-cluster --yes --no-wait
# ResourceNotFoundError → el cluster murió; pasar al paso 2

# 2. Barrido final CORTO (sin cluster que esperar, Terraform solo barre RG/VNet en ~1-2 min)
cd ~/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud/iac/azure
terraform destroy
```

**Di al jurado:** *"Cuando la operación es larga y mi red es la que no coopera, cambio el instrumento: el delete lo lanza una única llamada asíncrona y el estado se consulta con polls cortos e independientes. Terraform queda para lo que hace mejor —reconciliar el estado declarativo restante— en una operación corta. La plataforma nunca depende de la estabilidad de mi laptop."*

**Costo del incidente:** el cluster en estado `Deleting` deja de facturar el control plane de inmediato; solo centavos de nodos mientras desaparecen.

### 9.3 Desenlace real del ensayo (2026-10-02) — red local caída de punta a punta

La Fase 7 se ejecutó con la red local del demo COMPLETAMENTE inestable (DNS roto incluido). Secuencia real, documentada como caso de estudio:

1. `terraform destroy` x2 → ambos cayeron en el polling a los 18+ min con `dial tcp ...: operation timed out` (timeout de RED LOCAL, no de Azure). Cluster oscilando `Failed → Succeeded → Failed` (aborto total en cada caída del cliente).
2. `az aks delete --no-wait` local → DNS roto: `Failed to resolve 'management.azure.com'`.
3. Portal web → tampoco pudo eliminar (misma red local).
4. **Cloud Shell del portal** (el cliente que no está en mi laptop) → `az aks delete --yes --no-wait` aceptado al instante.
5. Estado oscilando `Failed ↔ Deleting` durante ~30 min: reintentos internos del RP (el cluster llegó al delete con varias operaciones acumuladas de los intentos anteriores; el desmontaje tuvo que limpiarlas una a una).
6. Veredicto final: `az aks show` → **`ResourceGroupNotFound`** — cluster Y resource group desaparecidos. Gasto detenido.
7. Pendiente solo: `terraform destroy` en `iac/azure` para reconciliar el state (los recursos ya no existen; el refresh los marcará ausentes; puede ejecutarse cuando la red local se recupere — no cuesta nada).

**Moraleja del caso (respuesta a "¿por qué se demoró más este destroy?"):** *"Destruir infraestructura cloud no es borrar un registro: es un desmontaje orquestado con reintentos. Cada disparo impaciente desde mi laptop acumuló trabajo al RP; la demora fue el precio de esos reintentos. La lección operativa: se dispara una vez, con un cliente que no es punto de fallo, y se observa con paciencia profesional."*

**Lección de red:** con ISP/DNS local inestable, el timeout intermitente histórico del proyecto hacia `management.azure.com` se explica: la resolución DNS del router era el fallo. Fix durable: DNS públicos (`8.8.8.8` / `1.1.1.1`) en la configuración de red de la máquina demo.

**Di al jurado:** *"Cierro destruyendo lo efímero. ¿Y qué pasa con mi plataforma? El ACR sobrevive protegido por `prevent_destroy` con el state en un archivo separado (`azure/registry.tfstate`) — este destroy ni siquiera lo ve. El backend de estado, la federación OIDC y todo el conocimiento en Git permanecen. La próxima sesión, la reconstrucción completa toma 15 minutos — eso es el RTO de mi plataforma. Costo de toda esta demostración: menos de un dólar."*

---

## 10. Datos de plataforma (referencia rápida)

| Elemento | Valor |
|---|---|
| Suscripción Azure | `23c5c742-7e58-48a5-8131-697efc71a366` |
| Tenant | `0fc1436e-05f9-416b-9d88-a108f4a1133b` |
| Service Principal (appId) | `f50eded8-ffef-4864-8e08-b62ab0ed18bf` (`terraform-ci-azure`) |
| ACR | `sriacrtfm23c5` (SKU Basic, RG `sri-tfstate-rg`) → `sriacrtfm23c5.azurecr.io` |
| AKS | `sri-aks-cluster` (RG `sri-aks-rg`, eastus, 3× Standard_D2s_v3) |
| Backend Terraform | Storage account `sritfstate23c5`, key `azure/terraform.tfstate` (registry: `azure/registry.tfstate`) |
| Rama de trabajo | `feature-patron-appOfapps` |
| ArgoCD UI | `https://localhost:8082` (port-forward), usuario `admin` |
| App | puerto 5000: `/health`, `/ready`, `/api/v1/version` |

## 11. Preguntas probables del jurado (respuestas preparadas)

**"¿Por qué `--server-side --force-conflicts` en ArgoCD?"**
Las CRDs de ApplicationSet superan los 256KB de la anotación `kubectl.kubernetes.io/last-applied-configuration` con la que el apply cliente trata de anotar cada objeto; el server-side apply delega el control de campos al servidor y acepta conflictos de propiedad.

**"¿Qué pasa si el pipeline falla a mitad?"**
Git protege el estado deseado: el manifiesto solo cambia si los jobs `test` y `build-and-push` pasan (jobs encadenados). Si el bump nunca ocurre, ArgoCD sigue sirviendo la versión anterior — y con `selfHeal: true` repara cualquier desviación manual del cluster.

**"¿Dónde están las credenciales del pipeline?"**
En ninguna parte: GitHub Actions se autentica en Azure mediante federación OIDC — un `federated credential` en la App Registration con el `subject` exacto del repo y la rama (formato de IDs inmutables). El repo solo guarda IDs públicos (`AZURE_CLIENT_ID`, tenant, suscripción, nombre del ACR). En AWS el mismo patrón con el proveedor OIDC de IAM.

**"¿Por qué un Service Principal sin MFA para Terraform?"**
Es una identidad de automatización con permisos mínimos (Contributor sobre la suscripción), auditable en Entra ID. Los humanos usan cuentas con MFA para operaciones puntuales privilegiadas (bootstrap de RBAC), documentadas en scripts. La operación recurrente es 100% identidad de máquina.

**"¿Por qué no HashiCorp Vault para los secretos?"**
*(Respaldado por ADR-003 en docs/decisions/)*: Vault self-hosted añade un servidor HA que operar (unseal, backups, TLS) con un punto único de fallo que atraviesa ambas nubes y dependencia de red cross-cloud. Los almacenes nativos gestionados (SSM Parameter Store en AWS, Key Vault en Azure) cubren el requisito con costo residual, autenticación sin credenciales vía identidad de carga de trabajo, y disponibilidad independiente por nube. La portabilidad del diseño está en el **patrón** de consumo (SecretProviderClass CSI + ServiceAccount + identidad gestionada), no en el proveedor.

**"¿Cuánto cuesta esto en producción?"**
Cluster efímero: ~$0.10/h en Azure (~$73/mes si se dejara 24/7, por eso se destruye en pausas). ACR Basic ~$0.17/día (~$5/mes). Key Vault cuando se active: ~$0.03/mes por secreto. GitHub Actions: $0 en repo público.

**"¿Cómo portas esto a AWS?"**
La Fase 6 ya lo demuestra: la matriz `[aws, azure]` del workflow construye y publica en ECR y ACR en paralelo, y el overlay `aws-eks` consume la imagen de ECR con el mismo patrón. El módulo Terraform y los manifiestos base son compartidos; solo cambian overlays y providers.

---

*Documento vivo: se actualiza al cerrar cada fase del ensayo. Estado: Fases 0-7 COMPLETADAS — ensayo cerrado de cero a cero (Fase 7 ejecutada 2026-10-02 con red local caída: delete completado vía Cloud Shell, veredicto `ResourceGroupNotFound`; pendiente solo la reconciliación del state de Terraform cuando la red local se recupere). Última actualización: 2026-10-02.*
