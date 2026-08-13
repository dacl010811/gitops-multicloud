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