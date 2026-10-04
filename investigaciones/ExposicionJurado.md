# ⛓️ Flujo Completo: Desde Terraform hasta la App en Vivo

```text
  PASO 1: IaC (Terraform)        PASO 2: CI (GitHub Actions)     PASO 3: GitOps (ArgoCD)        PASO 4: App Live
┌─────────────────────────┐    ┌─────────────────────────┐    ┌─────────────────────────┐    ┌─────────────────────────┐
│ 1. Bootstrap State      │    │ 1. git push app/        │    │ 1. Install ArgoCD       │    │ 1. Ingress Routing     │
│ 2. terraform apply AWS  │───►│ 2. Run Pytest           │───►│ 2. Apply Root-App       │───►│ 2. GET /api/v1/version │
│ 3. terraform apply Az   │    │ 3. Build & Push Docker  │    │ 3. Sync Kustomize       │    │ 3. Return Cloud Metadata│
└─────────────────────────┘    └─────────────────────────┘    └─────────────────────────┘    └─────────────────────────┘
```

---

## 📍 PASO 1: Aprovisionamiento de Infraestructura Base (IaC)

1. **Creación del Almacenamiento de Estado (Backend Bootstrapping):**
   * Corres los scripts `scripts/bootstrap-backend-aws.sh` y `scripts/bootstrap-backend-azure.sh`.
   * **Resultado:** Se crea un Bucket S3 + Tabla DynamoDB en AWS y una Storage Account en Azure para guardar el estado de Terraform de forma segura.

2. **Ejecución de Terraform para AWS:**
   * Entras a `iac/aws/` y ejecutas `terraform init` y `terraform apply`.
   * **¿Qué ocurre?** Terraform llama al módulo genérico `iac/modules/kubernetes-cluster`, crea la VPC, Subnets, IAM Roles y provisiona el clúster **Amazon EKS**.

3. **Ejecución de Terraform para Azure:**
   * Entras a `iac/azure/` y ejecutas `terraform init` y `terraform apply`.
   * **¿Qué ocurre?** Terraform llama al submódulo `iac/modules/kubernetes-cluster/azure`, crea el Resource Group y provisiona el clúster **Azure AKS**.

> **Punto clave para el jurado:** En este momento tienes dos clústeres de Kubernetes limpios y vacíos en dos nubes distintas.

---

## 📍 PASO 2: Compilación y Publicación de la Aplicación (CI Pipeline)

1. **Disparador (Trigger):** Haces un `git push` con cambios en la carpeta `app/`.
2. **GitHub Actions (`.github/workflows/ci-cd.yaml`):**
   * Ejecuta las pruebas unitarias con `pytest`.
   * Compila la imagen Docker del microservicio FastAPI (`Dockerfile`).
   * Sube la imagen empaquetada a los registros de contenedores (Amazon ECR / Azure ACR o Docker Hub) etiquetada con la versión (ej: `v1.0.0` o `sha-commit`).

---

## 📍 PASO 3: Despliegue Automatizado con GitOps (ArgoCD)

Aquí es donde ocurre la **magia del patrón GitOps**:

1. **Instalación Inicial de ArgoCD:**
   * Se instala el operador de ArgoCD dentro de los clústeres EKS y AKS (se puede automatizar mediante Helm o script post-Terraform).

2. **Patrón App-of-Apps (`root-app.yaml`):**
   * Aplica en el clúster el archivo `gitops/argocd/root-app.yaml` mediante `kubectl apply -f gitops/argocd/root-app.yaml`.
   * **¿Qué hace ArgoCD?** Lee este archivo raíz y detecta que debe desplegar dos aplicaciones secundarias leyendo la carpeta `gitops/`:
     * En AWS lee `gitops/overlays/aws-eks/`
     * En Azure lee `gitops/overlays/azure-aks/`

3. **Reconciliación de Kustomize (Base + Overlays):**
   * **Base (`gitops/bases/`):** ArgoCD lee la plantilla común (Deployment de FastAPI, Service en puerto 5000, HPA).
   * **Overlay AWS (`gitops/overlays/aws-eks/`):**
     * Parchea el Deployment inyectando la variable de entorno: `CLOUD_PROVIDER = "aws"`.
     * Activa la regla de **AWS ALB Ingress**.
   * **Overlay Azure (`gitops/overlays/azure-aks/`):**
     * Parchea el Deployment inyectando la variable de entorno: `CLOUD_PROVIDER = "azure"`.
     * Activa la regla de **Azure AGIC Ingress**.

4. **Sincronización:** ArgoCD crea los Pods, Servicios e Ingresses en ambos clústeres automáticamente sin ejecutar ningún `kubectl` de aplicación manual.

---

## 📍 PASO 4: Exposición y Validación en Vivo (El Resultado)

Cuando una petición HTTP golpea la URL de cada clúster:

1. **Tráfico en AWS:**
   * Usuario consulta: `http://<ALB-AWS-URL>/api/v1/version`
   * El Ingress de AWS enruta la petición al Pod de FastAPI.
   * La aplicación lee `os.getenv("CLOUD_PROVIDER")` que Kustomize inyectó como `"aws"`.
   * **Respuesta:**
     ```json
     {
       "version": "1.0.0",
       "cloud": "aws",
       "cluster": "sri-eks-cluster",
       "hostname": "sri-facturacion-aws-pod-864b"
     }
     ```

2. **Tráfico en Azure:**
   * Usuario consulta: `http://<AGIC-AZURE-URL>/api/v1/version`
   * El Ingress de Azure enruta la petición al Pod de FastAPI.
   * La aplicación lee `os.getenv("CLOUD_PROVIDER")` que Kustomize inyectó como `"azure"`.
   * **Respuesta:**
     ```json
     {
       "version": "1.0.0",
       "cloud": "azure",
       "cluster": "sri-aks-cluster",
       "hostname": "sri-facturacion-azure-pod-311a"
     }
     ```

---

# 💡 Resumen Ejecutivo (1 Minuto)

> *"El flujo es completamente automatizado de extremo a extremo: **Terraform** aprovisiona los clústeres de Kubernetes en AWS y Azure. **GitHub Actions** compila la imagen Docker del microservicio Python. **ArgoCD** detecta los manifiestos en Git y aplica la plantilla **Kustomize Base** común, sobrecargándola con **Overlays específicos** que inyectan variables de entorno de cada nube. Al consultar el endpoint `/api/v1/version`, es la **misma imagen de código** la que responde, reconociendo de forma dinámica si está ejecutándose en AWS EKS o en Azure AKS."*


---

# 📋 Plan de Validación Modular - SRI GitOps Multicloud

**Autor:** [Tu Nombre]
**Fecha:** [Fecha Actual]
**Versión:** 1.0.0

---

## 🎯 Objetivo General
Validar el proyecto **SRI GitOps Multicloud** de forma sistemática, siguiendo una estrategia **Bottom-Up Testing** que garantice:
- **Portabilidad real** entre AWS y Azure.
- **Automatización completa** desde IaC hasta GitOps.
- **Cero errores** en producción mediante pruebas por capas.

---

## 🗺️ Estrategia de Validación (Fases)

```mermaid
graph TD
    A[FASE 1: Aplicación Local] --> B[FASE 2: IaC Sintáctica]
    B --> C[FASE 3: State Remoto]
    C --> D[FASE 4: Infraestructura Real]
    D --> E[FASE 5: Kustomize Local]
    E --> F[FASE 6: GitOps (ArgoCD)] 
    F --> G[FASE 7: Integración Multicloud]
```


---

## 📌 FASE 1: Validación Local del Microservicio
**Objetivo:** Asegurar que el código Python, Docker y los endpoints funcionan en local sin dependencias externas.

### 🔧 Herramientas
- Python 3.11+
- Docker
- `pytest`

### ✅ Pasos de Validación

#### 1.1 Pruebas Unitarias
```bash
cd app
python -m venv venv && source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt
pytest
```
**Criterio de Éxito:**
✔️ Todos los tests pasan (100% coverage).

#### 1.2 Prueba de Endpoints con Variables de Entorno
```bash
# Simular AWS
CLOUD_PROVIDER=aws CLUSTER_NAME=local-eks uvicorn main:app --reload --port 5000
curl http://localhost:5000/api/v1/version  # Debe responder: {"cloud": "aws"}

# Simular Azure
CLOUD_PROVIDER=azure CLUSTER_NAME=local-aks uvicorn main:app --reload --port 5000
curl http://localhost:5000/api/v1/version  # Debe responder: {"cloud": "azure"}
```
**Criterio de Éxito:**
✔️ La aplicación responde dinámicamente según la variable `CLOUD_PROVIDER`.

#### 1.3 Construcción y Prueba de la Imagen Docker
```bash
docker build -t sri-facturacion:local .
docker run -d -p 5000:5000 -e CLOUD_PROVIDER=docker-local sri-facturacion:local
curl http://localhost:5000/health  # Debe responder: {"status": "healthy"}
docker logs <container_id>
docker rm -f <container_id>
```
**Criterio de Éxito:**
✔️ La imagen se construye sin errores y el contenedor responde en el puerto `5000`.

---

## 📌 FASE 2: Validación Sintáctica de IaC (Terraform Dry-Run)
**Objetivo:** Verificar que los módulos de Terraform son sintácticamente correctos y generan planes válidos.

### 🔧 Herramientas
- Terraform `>= 1.6.0`
- AWS CLI / Azure CLI

### ✅ Pasos de Validación

#### 2.1 Validar Módulo Genérico
```bash
cd iac/modules/kubernetes-cluster
terraform init -backend=false
terraform validate
terraform plan
```
**Criterio de Éxito:**
✔️ `validate` y `plan` finalizan sin errores.

#### 2.2 Validar Implementación AWS
```bash
cd ../../aws
terraform init -backend=false
terraform validate
terraform plan
```
**Criterio de Éxito:**
✔️ `validate` y `plan` finalizan sin errores.

#### 2.3 Validar Implementación Azure
```bash
cd ../azure
terraform init -backend=false
terraform validate
terraform plan
```
**Criterio de Éxito:**
✔️ `validate` y `plan` finalizan sin errores.

---

## 📌 FASE 3: Aprovisionamiento del State Remoto (Bootstrap)
**Objetivo:** Configurar el almacenamiento remoto para el estado de Terraform.

### 🔧 Herramientas
- AWS CLI / Azure CLI
- Scripts Bash (`scripts/bootstrap-backend-*.sh`)

### ✅ Pasos de Validación

#### 3.1 Ejecutar Scripts de Bootstrap
```bash
# AWS
chmod +x scripts/bootstrap-backend-aws.sh
./scripts/bootstrap-backend-aws.sh  # Crea S3 Bucket + DynamoDB Table

# Azure
chmod +x scripts/bootstrap-backend-azure.sh
./scripts/bootstrap-backend-azure.sh  # Crea Storage Account
```
**Criterio de Éxito:**
✔️ Los recursos de backend se crean sin errores y son accesibles en la consola de AWS/Azure.

---

## 📌 FASE 4: Despliegue de Infraestructura Real (EKS + AKS)
**Objetivo:** Aprovisionar los clústeres Kubernetes en AWS y Azure.

### 🔧 Herramientas
- Terraform
- `kubectl`
- AWS CLI / Azure CLI

### ✅ Pasos de Validación

#### 4.1 Despliegue en AWS (EKS)
```bash
cd iac/aws
terraform init
terraform apply -auto-approve
aws eks --region us-east-1 update-kubeconfig --name sri-eks-cluster
kubectl get nodes  # Verificar nodos en estado "Ready"
```
**Criterio de Éxito:**
✔️ El clúster EKS se crea sin errores y los nodos están en estado `Ready`.

#### 4.2 Despliegue en Azure (AKS)
```bash
cd ../azure
terraform init
terraform apply -auto-approve
az aks get-credentials --resource-group sri-aks-rg --name sri-aks-cluster
kubectl get nodes  # Verificar nodos en estado "Ready"
```
**Criterio de Éxito:**
✔️ El clúster AKS se crea sin errores y los nodos están en estado `Ready`.

---

## 📌 FASE 5: Validación Local de Kustomize
**Objetivo:** Asegurar que los manifiestos de Kubernetes se renderizan correctamente.

### 🔧 Herramientas
- `kustomize`
- `kubectl`

### ✅ Pasos de Validación

#### 5.1 Renderizar Manifiestos para AWS
```bash
cd gitops/overlays/aws-eks
kustomize build . > aws-manifests.yaml
cat aws-manifests.yaml | grep "CLOUD_PROVIDER"  # Debe mostrar "aws"
```
**Criterio de Éxito:**
✔️ Los manifiestos incluyen `CLOUD_PROVIDER: "aws"`.

#### 5.2 Renderizar Manifiestos para Azure
```bash
cd ../azure-aks
kustomize build . > azure-manifests.yaml
cat azure-manifests.yaml | grep "CLOUD_PROVIDER"  # Debe mostrar "azure"
```
**Criterio de Éxito:**
✔️ Los manifiestos incluyen `CLOUD_PROVIDER: "azure"`.

---

## 📌 FASE 6: Despliegue GitOps (ArgoCD)
**Objetivo:** Instalar ArgoCD y sincronizar los manifiestos desde Git.

### 🔧 Herramientas
- `kubectl`
- ArgoCD CLI (opcional)

### ✅ Pasos de Validación

#### 6.1 Instalar ArgoCD en Ambos Clústeres
```bash
# AWS EKS
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f gitops/argocd/root-app.yaml -n argocd

# Azure AKS (repetir los mismos comandos)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f gitops/argocd/root-app.yaml -n argocd
```

#### 6.2 Verificar Sincronización
```bash
kubectl get pods -n argocd  # Todos los pods deben estar "Running"
kubectl get applications -n argocd  # Debe mostrar "sri-facturacion-root" en estado "Synced"
```
**Criterio de Éxito:**
✔️ ArgoCD sincroniza automáticamente los manifiestos y los pods del microservicio están en estado `Running`.

---

## 📌 FASE 7: Pruebas de Integración Multicloud
**Objetivo:** Validar que el microservicio responde correctamente en ambas nubes.

### 🔧 Herramientas
- `curl`
- `kubectl`

### ✅ Pasos de Validación

#### 7.1 Obtener URLs de Ingress
```bash
# AWS EKS
kubectl get ingress -n default  # Copiar la URL del ALB

# Azure AKS
kubectl get ingress -n default  # Copiar la URL del AGIC
```

#### 7.2 Probar Endpoints
```bash
# AWS
curl http://<ALB_URL>/api/v1/version  # Debe responder: {"cloud": "aws"}

# Azure
curl http://<AGIC_URL>/api/v1/version  # Debe responder: {"cloud": "azure"}
```

#### 7.3 Prueba de Autosanación (Self-Healing)
```bash
kubectl delete pod -l app=sri-facturacion -n default  # Borrar un pod
kubectl get pods -n default  # Verificar que ArgoCD recrea el pod automáticamente
```
**Criterio de Éxito:**
✔️ El microservicio responde con la nube correcta en cada endpoint.
✔️ ArgoCD recrea los pods borrados en menos de 30 segundos.

---

## 📊 Resumen de Criterios de Éxito por Fase

| Fase | Criterio de Éxito |
|------|-------------------|
| 1 | Tests unitarios pasan, Docker funciona, endpoints responden con variables dinámicas. |
| 2 | `terraform validate` y `plan` sin errores en AWS y Azure. |
| 3 | Backend remoto (S3/DynamoDB y Blob Storage) creado y accesible. |
| 4 | Clústeres EKS y AKS creados con nodos en estado `Ready`. |
| 5 | Kustomize renderiza manifiestos con variables correctas para cada nube. |
| 6 | ArgoCD sincroniza manifiestos y pods están `Running`. |
| 7 | Endpoints responden con la nube correcta y autosanación funciona. |

---

## 🚀 Recomendaciones Finales
1. **Automatiza las pruebas:** Usa scripts Bash o GitHub Actions para validar cada fase automáticamente.
2. **Documenta cada paso:** Registra logs y outputs en un archivo `VALIDATION_LOG.md`.
3. **Usa variables de entorno:** Nunca hardcodees credenciales o nombres de recursos.
4. **Prueba la destrucción:** Ejecuta `terraform destroy` al final para evitar costos innecesarios.

---

## 📝 Notas Adicionales
- **Tiempo estimado por fase:**
  - FASE 1: 30 min
  - FASE 2: 20 min
  - FASE 3: 15 min
  - FASE 4: 20 min (AWS) + 20 min (Azure)
  - FASE 5: 10 min
  - FASE 6: 15 min
  - FASE 7: 10 min
- **Total estimado:** ~2 horas (sin contar tiempos de aprovisionamiento de clústeres).

---
**¡Listo para ejecutar!** ¿Por cuál fase quieres empezar? 🚀
```

---

### 📁 Dónde Guardarlo
Guarda este archivo en tu repositorio como:
```
docs/VALIDATION_PLAN.md