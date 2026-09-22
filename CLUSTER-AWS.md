# 1. Verificar credenciales AWS
aws sts get-caller-identity
# Debe mostrar: "Arn": "arn:aws:iam::053044806920:user/terraform-ci"

# 2. Ir al directorio de IaC
cd /Users/admin/Documents/UNIR2025/MATERIAS-MASTER-2025/materias-master-devops2025/trabajofinalmaster2026/gitops-multicloud

# 3. (Solo si el bucket S3 no existe) Bootstrap del backend
bash scripts/bootstrap-backend-aws.sh

# 4. Inicializar Terraform
cd iac/aws
terraform init

# 5. Planificar
terraform plan

# 6. Crear el cluster (~15-20 min)
terraform apply
# Escribir "yes" cuando pregunte

# 7. Configurar kubectl
aws eks update-kubeconfig --name sri-eks-cluster --region us-east-1

# 8. Verificar
kubectl get nodes
# Debe mostrar 3 nodos en estado Ready


# Resumen visual


aws sts get-caller-identity  →  verifica credenciales ✅
         │
terraform init               →  conecta backend S3
         │
terraform apply              →  crea EKS + nodes (~15-20 min)
         │
aws eks update-kubeconfig    →  configura kubectl
         │
kubectl get nodes            →  3 nodos Ready ✅
         │
terraform destroy            →  limpia todo (~10 min)


Nota: El bucket S3 sri-gitops-tfstate ya existe de la vez anterior, así que el paso 3 probablemente no sea necesario — solo si lo borraste.

