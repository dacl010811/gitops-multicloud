
✅ Verificación
terraform fmt: mis archivos nuevos están correctamente formateados.
terraform validate: no se pudo completar porque el binario local es Terraform 1.5.7 y el proyecto exige >= 1.6.0. Para validar/desplegar necesitarás actualizar Terraform (recomendado >= 1.8 según los docs).
⚠️ Antes de terraform apply
Actualizar Terraform local a >= 1.8.
Crear el bucket S3 + tabla DynamoDB (AWS) y el Storage Account (Azure) para el estado, y sustituir los placeholders del backend.
Credenciales configuradas (aws configure / az login).
Comando: cd iac/aws && terraform init && terraform apply (ídem para azure).
Nota: los archivos del módulo preexistente (modules/kubernetes-cluster/*.tf) aparecen sin formatear en fmt -check. Puedo aplicar terraform fmt sobre ellos si quieres dejar todo el árbol IaC consistente.