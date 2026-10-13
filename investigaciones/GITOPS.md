# Memoria Técnica Principal: GitOps Multicloud
**Proyecto:** Trabajo Fin de Máster - UNIR MUDEVOPS OCT2025  
**Arquitecto Senior:** [Tu Nombre]  
**Fecha:** Julio 2026  

---

## Tabla de Contenidos
- [1. Análisis de la Arquitectura GitOps Multicloud](#1-análisis-de-la-arquitectura-gitops-multicloud)
  - [1.1 Paradigma Arquitectónico General](#11-paradigma-arquitectónico-general)
  - [1.2 Capa de Desarrollo y Repositorio Único (Monorepo GitHub)](#12-capa-de-desarrollo-y-repositorio-único-monorepo-github)
  - [1.3 Capa de Orquestación de Infraestructura (IaC Agnóstica)](#13-capa-de-orquestación-de-infraestructura-iac-agnóstica)
  - [1.4 Capa de Gestión de Secretos Multicloud (HashiCorp Vault)](#14-capa-de-gestión-de-secretos-multicloud-hashicorp-vault)
  - [1.5 Capa de Nubes Públicas (AWS y Azure)](#15-capa-de-nubes-públicas-aws-y-azure)
  - [1.6 Capa de GitOps y Orquestación de Aplicaciones (ArgoCD)](#16-capa-de-gitops-y-orquestación-de-aplicaciones-argocd)
- [2. Stack Tecnológico](#2-stack-tecnológico)
- [3. Guía Paso a Paso de Implementación](#3-guía-paso-a-paso-de-implementación)
  - [Paso 1: Estructurar el Repositorio (Monorepo)](#paso-1-estructurar-el-repositorio-monorepo)

---

## 1. Análisis de la Arquitectura GitOps Multicloud

### 1.1 Paradigma Arquitectónico General
La arquitectura propuesta implementa un **modelo GitOps Multicloud con Infraestructura como Código (IaC) agnóstica** para la portabilidad de microservicios entre AWS y Azure. Este enfoque se alinea con los estándares DORA (DevOps Research and Assessment) para alcanzar el nivel "High Performer" o "Elite Performer", garantizando:
- **Reproducibilidad total**: Todo (infraestructura, configuración, código) está versionado en Git.
- **Portabilidad**: Los microservicios se ejecutan indistintamente en Amazon EKS (AWS) y Azure AKS sin modificaciones significativas.
- **Observabilidad**: Stack de monitoreo integrado en ambos clusters.
- **Seguridad**: Gestión centralizada de secretos con HashiCorp Vault.

### 1.2 Capa de Desarrollo y Repositorio Único (Monorepo GitHub)
El repositorio único (monorepo) es la **fuente única de verdad (Single Source of Truth - SSOT)** para todo el proyecto, conteniendo tres bloques funcionales:

#### 1.2.1 Código de Aplicación (`app/`)
Microservicio desarrollado en **Python con FastAPI** (contexto de Servicio de Rentas Internas - SRI) con:
- `main.py`: Punto de entrada API REST
- `models/`: Definiciones de modelos de datos
- `sri-facturacion-service.py`: Lógica de negocio principal
- `docs/`: Documentación de la API
- `tests/`: Pruebas unitarias y de integración

#### 1.2.2 Configuración GitOps (`gitops/`)
Gestión de manifiestos Kubernetes con **Kustomize** para la abstracción de entornos:
- `bases/`: Manifiestos base (deployment.yaml, service.yaml, hpa.yaml, kustomization.yaml) comunes a todas las nubes
- `overlays/aws-eks/`: Sobrecargas específicas para AWS EKS (ingress.yaml, secrets-store-ssm.yaml, kustomization.yaml)
- `overlays/azure-aks/`: Sobrecargas específicas para Azure AKS (ingress.yaml, secrets-store-csi.yaml, kustomization.yaml)

#### 1.2.3 Infraestructura como Código (`iac/`)
Módulos Terraform reutilizables para aprovisionamiento agnóstico:
- `modules/kubernetes-cluster/`: Módulo genérico para crear clusters Kubernetes (abstracte EKS y AKS)
  - `main.tf`: Lógica principal del módulo
  - `variables.tf`: Parámetros de entrada
  - `outputs.tf`: Valores de salida
- `aws/main.tf`: Implementación del módulo para AWS
- `azure/main.tf`: Implementación del módulo para Azure

### 1.3 Capa de Orquestación de Infraestructura (IaC Agnóstica)
Flujo de trabajo de Terraform para aprovisionamiento seguro y reproducible:
1. **Terraform Plan/Apply**: Ejecutado manualmente o via Atlantis (opcional) para previsualizar y aplicar cambios
2. **Terraform Cloud/CLI**: Herramienta de ejecución
3. **Estado Remoto**: Almacenado en **S3 (AWS)** con **DynamoDB** para locking (previene conflictos de ejecución)
4. **Providers**: `aws` y `azurem` para interactuar con las APIs de las nubes públicas

### 1.4 Capa de Gestión de Secretos Multicloud (HashiCorp Vault)
HashiCorp Vault actúa como **abstracción de secretos** entre AWS y Azure:
- Almacena credenciales, API keys y contraseñas de forma centralizada
- Proporciona una interfaz uniforme para que los microservicios accedan a secretos, independientemente de la nube
- Integración con:
  - AWS Secrets Manager/Systems Manager Parameter Store (via `secrets-store-ssm.yaml`)
  - Azure Key Vault (via `secrets-store-csi.yaml` y Secrets Store CSI Driver)

### 1.5 Capa de Nubes Públicas (AWS y Azure)

#### 1.5.1 Nube AWS (Región `us-east-1`)
- **Amazon ECR**: Registro de imágenes Docker para el microservicio `sri-facturacion-service` (tag `v2.3`)
- **Amazon RDS PostgreSQL**: Base de datos relacional gestionada
- **Amazon EKS**: Cluster Kubernetes gestionado
  - **ArgoCD**: Controlador GitOps desplegado en el cluster
  - **app:sri-facturacion-service**: Microservicio principal (Deployment con 3 réplicas de Pods FastAPI :5000)
  - **app:monitor**: Servicio de observabilidad
  - **ALB Ingress Controller**: Balanceador de carga aplicación gestiona tráfico HTTP/HTTPS hacia el microservicio (endpoint: `api.sri.ec.gob.ec -> sri-facturacion-service:5000`)

#### 1.5.2 Nube Azure (Región `eastus`)
- **Azure ACR**: Registro de imágenes Docker para el microservicio `sri-facturacion-service` (tag `v2.3`)
- **Azure Database for PostgreSQL**: Base de datos relacional gestionada
- **Azure AKS**: Cluster Kubernetes gestionado
  - **ArgoCD**: Controlador GitOps desplegado en el cluster
  - **app:sri-facturacion-service**: Microservicio principal (Deployment con 3 réplicas de Pods FastAPI :5000)
  - **app:monitor**: Servicio de observabilidad
  - **AGIC (Application Gateway Ingress Controller)**: Balanceador de carga aplicación gestiona tráfico HTTP/HTTPS hacia el microservicio (endpoint: `api.sri.ec.gob.ec -> sri-facturacion-service:5000`)

### 1.6 Capa de GitOps y Orquestación de Aplicaciones (ArgoCD)
ArgoCD es el **controlador GitOps** que garantiza que el estado del cluster coincida con el estado deseado definido en Git:
- **Sincronización Automática**: Monitorea el repositorio GitHub y aplica cambios automáticamente (o manualmente, según política)
- **Multi-Cluster**: ArgoCD está desplegado en ambos clusters (EKS y AKS), cada uno sincronizando su overlay específico (`overlays/aws-eks/` y `overlays/azure-aks/`)
- **Rollback Automático**: Si un despliegue falla, ArgoCD revierte al último estado válido en Git

---

## 2. Stack Tecnológico

| Capa | Tecnología | Versión | Justificación Académica/Industrial |
|---|---|---|---|
| Control de Versiones | GitHub | - | Estándar de facto para alojamiento de repositorios Git y GitOps |
| Lenguaje de Aplicación | Python + FastAPI | ≥ 3.11 / ≥ 0.109 | Alto rendimiento, tipado estático, documentación automática (OpenAPI/Swagger) |
| IaC | Terraform | ≥ 1.8 | Agnóstico a nubes, estado remoto, módulos reutilizables |
| Orquestación de Contenedores | Kubernetes | ≥ 1.30 | Estándar de la industria para orquestación de microservicios |
| Kubernetes Managed (AWS) | Amazon EKS | ≥ 1.30 | Reduce overhead operativo del plano de control |
| Kubernetes Managed (Azure) | Azure AKS | ≥ 1.30 | Integración nativa con servicios Azure |
| GitOps | ArgoCD | ≥ 2.11 | Controlador declarativo, UI amigable, soporte multi-cluster |
| Gestión de Manifiestos K8s | Kustomize | ≥ 5.4 | Abstracción de entornos sin duplicación de código |
| Gestión de Secretos | HashiCorp Vault | ≥ 1.15 | Abstracción multicloud, rotación automática, auditoría |
| Ingress AWS | ALB Ingress Controller | ≥ 2.7 | Balanceador de capa 7 gestionado por AWS |
| Ingress Azure | AGIC | ≥ 2.7 | Balanceador de capa 7 gestionado por Azure |
| Registro de Imágenes (AWS) | Amazon ECR | - | Integrado con EKS y IAM |
| Registro de Imágenes (Azure) | Azure ACR | - | Integrado con AKS y AAD |
| Base de Datos | PostgreSQL | ≥ 15 | Motor relacional open source, compatible con ambas nubes |

---

## 3. Guía Paso a Paso de Implementación

### Paso 1: Estructurar el Repositorio (Monorepo)
El monorepo es la base de todo el proyecto, ya que concentra código, IaC y configuración GitOps.

#### Estructura Final del Repositorio