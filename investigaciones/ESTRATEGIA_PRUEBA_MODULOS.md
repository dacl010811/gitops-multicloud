"# Estrategia de Prueba Modular para Aprovisionamiento de EKS y AKS

## 🎯 Objetivo
Probar cada módulo de Terraform de forma aislada para validar el aprovisionamiento automático de clusters EKS (AWS) y AKS (Azure) antes de integrarlos en el flujo GitOps completo.

## ⚠️ Prerrequisitos Críticos
1. **Actualizar Terraform**: Localmente debe ser >=1.8 (actual: 1.5.7 → bloquea validate/apply)
   ```bash
   # Ejemplo para macOS con Homebrew
   brew upgrade terraform
   # Verificar versión
   terraform version
   ```
2. **Credenciales de Nube Configuradas**:
   - AWS: `aws configure` (con permisos para EKS, IAM, VPC, EC2)
   - Azure: `az login` (con suscripción activa y permisos para AKS, Resource Groups)
3. **Recursos de Estado Previos** (para pruebas con backend remoto):
   - **AWS**: Bucket S3 + Tabla DynamoDB para locking
   - **Azure**: Storage Account + Container para estado de Terraform
   *(Alternativa para pruebas iniciales: usar backend local)*

## 📂 Estructura de Módulos a Probar
```
iac/
├── aws/                  # Configuración raíz para AWS
│   └── main.tf           # Llama a módulo kubernetes-cluster
├── azure/                # Configuración raíz para Azure
│   └── main.tf           # Llama a submódulo azure de kubernetes-cluster
└── modules/
    └── kubernetes-cluster/
        ├── main.tf       # Implementación AWS EKS (genérica pero AWS-specific)
        ├── variables.tf
        ├── outputs.tf
        └── azure/        # Submódulo Azure AKS aislado
            ├── main.tf
            ├── variables.tf
            └── outputs.tf
```

---

## 🔬 Fase 1: Prueba Aislada del Módulo AWS EKS

### Paso 1: Preparar Directorio de Prueba
```bash
cd iac/aws
```

### Paso 2: Configurar Backend Temporal (Local para Pruebas Rápidas)
*Editar `main.tf` temporalmente para usar backend local:*
```hcl
terraform {
  required_version = ">= 1.6.0"
  
  backend "local" {}  # <-- Cambiar de remoto a local para pruebas
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

### Paso 3: Definir Variables Mínimas Necesarias
*Crear `terraform.tfvars` (o usar `-var` en CLI):*
```hcl
cluster_name      = "test-eks-cluster"
cluster_role_arn  = ""  # Dejar vacío para que el módulo cree el IAM Role
kubernetes_version = "1.30"
subnet_ids        = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]  # <-- REEMPLazar con subnets reales de tu VPC
api_access_cidrs  = ["0.0.0.0/0"]  # <-- Para testing ONLY! En producción usar CIDRs específicos
tags              = {
  Environment = "test"
  Project     = "gitops-multicloud"
}
```

> 💡 **Nota**: Para obtener `subnet_ids` válidos:
> ```bash
> aws ec2 describe-subnets --filters "Name=vpc-id,Values=<tu-vpc-id>" --query 'Subnets[*].SubnetId' --output text
> ```

### Paso 4: Ejecutar Ciclo de Terraform
```bash
# Inicializar (descargar providers)
terraform init

# Formatear código
terraform fmt

# Validar configuración
terraform validate

# Planificar cambios (revisar cuidadosamente)
terraform plan -var-file=terraform.tfvars

# Aplicar (solo si el plan se ve correcto)
terraform apply -var-file=terraform.tfvars
```

### Paso 5: Verificar Recursos Creados
```bash
# Ver estado de recursos
terraform state list

# Obtener kubeconfig para kubectl
aws eks update-kubeconfig --name test-eks-cluster --region <tu-region>

# Verificar nodos
kubectl get nodes
```

### Paso 6: Limpieza (Después de Pruebas)
```bash
terraform destroy -var-file=terraform.tfvars
```

---

## 🔬 Fase 2: Prueba Aislada del Módulo Azure AKS

### Paso 1: Preparar Directorio de Prueba
```bash
cd iac/azure
```

### Paso 2: Configurar Backend Temporal (Local)
*Editar `main.tf` temporalmente:*
```hcl
terraform {
  required_version = ">= 1.6.0"
  
  backend "local" {}  # Backend local para pruebas
  
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}
```

### Paso 3: Definir Variables Mínimas Necesarias
*Crear `terraform.tfvars`:*
```hcl
cluster_name           = "test-aks-cluster"
location               = "eastus"
resource_group_name    = "test-rg-aks"  # <-- Debe existir o crear primero
kubernetes_version     = "1.30.0"
node_count             = 1
node_instance_type     = "Standard_B2s"
tags                   = {
  Environment = "test"
  Project     = "gitops-multicloud"
}
```

> 💡 **Nota**: Crear grupo de recursos si no existe:
> ```bash
> az group create --name test-rg-aks --location eastus
> ```

### Paso 4: Ejecutar Ciclo de Terraform
```bash
terraform init
terraform fmt
terraform validate
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars  # Confirmar con "yes"
```

### Paso 5: Verificar Recursos Creados
```bash
# Obtener credenciales de AKS
az aks get-credentials --resource-group test-rg-aks --name test-aks-cluster

# Verificar nodos
kubectl get nodes

# Ver estado de Terraform
terraform state list
```

### Paso 6: Limpieza
```bash
terraform destroy -var-file=terraform.tfvars
# Opcional: eliminar grupo de recursos
# az group delete --name test-rg-aks --yes --no-wait
```

---

## 🔗 Fase 3: Prueba de Integración (Después de Validar Ambos)

### Paso 1: Restaurar Backends Remotos
*En `iac/aws/main.tf` y `iac/azure/main.tf`, reemplazar el backend local por:*
```hcl
// AWS Backend (ejemplo)
terraform {
  backend "s3" {
    bucket         = "tu-terraform-state-bucket"
    key            = "aws/eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tu-tabla-dynamodb-lock"
    encrypt        = true
  }
  // ... resto de configuración
}

// Azure Backend (ejemplo)
terraform {
  backend "azurerm" {
    resource_group_name   = "tu-rg-terraform-state"
    storage_account_name  = "tucuentadealmacenamiento"
    container_name        = "tfstate"
    key                   = "aks/terraform.tfstate"
  }
  // ... resto de configuración
}
```

### Paso 2: Definir Variables de Producción
*Crear archivos `terraform.tfvars` específicos para cada entorno con valores reales:*
- IDs de cuenta, ARN de roles, IDs de identidad gestionada, etc.
- Referencias a recursos precreados (VPC, subnets, grupos de recursos)

### Paso 3: Ejecutar Flujo Completo
```bash
# En iac/aws/
terraform init
terraform apply -var-file=produccion.tfvars

# En iac/azure/
terraform init
terraform apply -var-file=produccion.tfvars
```

### Paso 4: Validar Multi-Cluster
```bash
# Contexto AWS
aws eks update-kubeconfig --name prod-eks-cluster --region us-east-1
kubectl get nodes
kubectl get pods -A  # Verificar ArgoCD, etc.

# Contexto Azure
az aks get-credentials --resource-group prod-rg-aks --name prod-aks-cluster
kubectl get nodes
kubectl get pods -A
```

---

## 🛡️ Mejores Prácticas para Pruebas

1. **Siempre revisar el `plan` antes del `apply`**
2. **Usar entornos de testing separados** (nombres de recursos con prefijo `test-`)
3. **Limpiar recursos después de probar** para evitar costos innecesarios
4. **Versionar los archivos `tfvars`** (pero nunca commitear secrets)
5. **Para pruebas de CI/CD simuladas**:
   - Después de `terraform apply`, ejecutar scripts que simulen el flujo GitOps
   - Verificar que ArgoCD pueda sincronizarse con los clusters creados

## 📋 Checklist de Validación por Módulo

| Componente | AWS EKS Verificación | Azure AKS Verificación |
|------------|----------------------|------------------------|
| **Cluster** | `aws eks describe-cluster` | `az aks show` |
| **Nodos** | `kubectl get nodes` (Estado Ready) | `kubectl get nodes` (Estado Ready) |
| **IAM/Identity** | Rol de EKS creado y asociado | Identity SystemAssigned habilitado |
| **Red** | Acceso al API server desde CIDRs configurados | AKS en VNet con subnets adecuadas |
| **Estado** | Archivo `.tfstate` actualizado localmente/remotamente | Idem |
| **Salida** | `cluster_endpoint`, `cluster_secure_server_endpoint` disponibles | `kube_config` y `kube_admin_config` generados |

## 🚨 Solución de Problemas Comunes

- **Error de credenciales**: Verificar `aws sts get-caller-identity` / `az account show`
- **Subnet/VPC no encontrada**: Revisar IDs y región coincidan con recursos existentes
- **Permisos insuficientes**: Asegurar políticas IAM/Role con permisos necesarios para EKS/AKS
- **Conflictos de nombre**: Usar nombres únicos con timestamp o ID de sesión
- **Timeout en creación**: Los clusters toman 10-15 minutos; aumentar `-timeout` si es necesario

---

## ✅ Próximos Pasos Después de Validar Módulos
1. Integrar módulos en el flujo GitOps completo (ArgoCD + CI/CD)
2. Aprovisionar bases de datos gestionadas (RDS/Azure DB)
3. Configurar secrets de monitoring (`grafana-admin`)
4. Reemplazar todos los placeholders y configurar secrets de GitHub Actions
5. Ejecutar despliegue end-to-end y validar portabilidad del microservicio

> **Importante**: Esta estrategia valida la capa de infraestructura. La portabilidad real del microservicio se valida después desplegando la misma aplicación en ambos clusters y verificando que responde correctamente en cada nube.

---\n*Estrategia diseñada para el Trabajo Fin de Máster - UNIR MUDEVOPS OCT2025*\n*Última actualización: Julio 2026*