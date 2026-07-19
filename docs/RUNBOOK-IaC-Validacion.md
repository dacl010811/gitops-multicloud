# Runbook — Validación del módulo IaC en las nubes desde una EC2

Guía paso a paso para clonar el repositorio en una instancia EC2 y validar/desplegar
la infraestructura (EKS en AWS, AKS en Azure) de forma incremental.

---

## 0. Preparar la EC2 (máquina runner/bastión)

Requisitos de la instancia:

- **IAM Role** adjunto con permisos para EKS, EC2, IAM, VPC (así Terraform usa las
  credenciales del rol automáticamente, sin claves en disco).
- Herramientas:

```bash
# Terraform >= 1.8 (el módulo exige >= 1.6; los docs recomiendan >= 1.8)
terraform version

# AWS CLI (para AWS)
aws sts get-caller-identity      # verifica que el IAM Role funciona

# Azure CLI (para Azure)
az login                         # o exporta ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID

# kubectl (para validar los clusters tras crearlos)
kubectl version --client
```

Clonar el repositorio:

```bash
git clone https://github.com/dacl010811/gitops-multicloud.git
cd gitops-multicloud
```

---

## 1. Validación sintáctica (sin crear nada, gratis)

```bash
cd iac/aws
terraform fmt -check
terraform init -backend=false   # evita necesitar el backend solo para validar
terraform validate

cd ../azure
terraform fmt -check
terraform init -backend=false
terraform validate
```

> ⚠️ Si `validate` falla con *"Unsupported Terraform Core version"*, actualiza
> Terraform a **>= 1.8**.

---

## 2. Preparar el backend remoto (una sola vez)

Los root modules apuntan a un backend remoto que **aún no existe**. Dos caminos:

### Opción A — Backend remoto real (recomendado)

```bash
# AWS: crea bucket S3 + tabla DynamoDB
bash scripts/bootstrap-backend-aws.sh

# Azure: crea Resource Group + Storage Account + Container
bash scripts/bootstrap-backend-azure.sh
```

### Opción B — Estado local (pruebas rápidas y aisladas)

Comenta temporalmente el bloque `backend "..."` en `iac/aws/main.tf` o
`iac/azure/main.tf`. Terraform guardará el estado en `terraform.tfstate` local.

---

## 3. Plan (dry-run: muestra qué se crearía, no crea nada)

```bash
cd iac/aws
terraform init      # ahora sí, con el backend real
terraform plan

cd ../azure
terraform init
terraform plan
```

---

## 4. Apply (crea el cluster real) 💰

> **Atención**: EKS y AKS cobran por hora (control plane + nodos).

```bash
cd iac/aws
terraform apply     # revisa el plan y confirma con 'yes'

cd ../azure
terraform apply
```

---

## 5. Validar el cluster creado

```bash
# AWS EKS
aws eks update-kubeconfig --name sri-eks-cluster --region us-east-1
kubectl get nodes

# Azure AKS
az aks get-credentials --resource-group sri-aks-rg --name sri-aks-cluster
kubectl get nodes
```

Con los nodos `Ready`, el cluster está listo para instalar ArgoCD y aplicar los
manifiestos de `gitops/`.

---

## 6. Limpieza (evita costes) 🧹

```bash
cd iac/aws && terraform destroy
cd ../azure && terraform destroy
```

---

## Notas importantes

- **VPC por defecto (AWS)**: `iac/aws/main.tf` usa `data "aws_vpc" "default"`. Si tu
  cuenta no tiene VPC default (o la eliminaste), el `plan` fallará. Habría que pasar
  `subnet_ids` explícitas.
- **Nombre del Storage Account (Azure)**: `sritfstate` debe ser único a nivel global.
  Si está tomado, exporta uno único (`TF_STATE_SA=...`) y actualiza
  `storage_account_name` en `iac/azure/main.tf`.
- **Probar el módulo aislado**: el módulo `iac/modules/kubernetes-cluster/` no se
  invoca directo; se consume desde los root modules `iac/aws/` e `iac/azure/`, que
  son la forma real de probarlo.
