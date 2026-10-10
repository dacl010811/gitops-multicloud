#!/bin/bash

# ============================================================
# MENÚ INTERACTIVO - BASE
# Para aprovisionar las infraestructuras en AWS en las distintas
# etapas del proyecto
# ============================================================

# Colores ANSI (opcional, para mejor presentación)
ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m' # Sin color

# ============================================================
# CONFIGURACIÓN GLOBAL
# ============================================================
# Región AWS por defecto para todo el menú. Cada fase que la usa
# pregunta al usuario si desea modificarla (ver configurar_region).
AWS_REGION="us-east-1"

# Raíz del repo (este script vive en <repo>/scripts)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================
# FUNCIÓN: Configurar la región AWS (global)
# ============================================================
configurar_region() {
    echo ""
    echo -e "Región AWS actual: ${AMARILLO}${AWS_REGION}${NC}"
    read -p "¿Deseas modificar la región? (s/n): " respuesta
    case "$respuesta" in
        [sS]|[sS][iI])
            read -p "Ingresa la nueva región (ej. us-east-1, us-west-2): " nueva_region
            if [ -n "$nueva_region" ]; then
                AWS_REGION="$nueva_region"
                echo -e "${VERDE}Región actualizada: ${AWS_REGION}${NC}"
            else
                echo -e "${AMARILLO}Entrada vacía: se mantiene ${AWS_REGION}${NC}"
            fi
            ;;
        *)
            echo -e "Se mantiene la región: ${AWS_REGION}"
            ;;
    esac
}

# ============================================================
# FUNCIÓN: Mostrar el menú
# ============================================================
mostrar_menu() {
    clear
    echo -e "${AZUL}========================================${NC}"
    echo -e "${AZUL}       MENÚ DE AUTOMATIZACIÓN           ${NC}"
    echo -e "${AZUL}========================================${NC}"
    echo -e " ${VERDE}1.${NC} Fase 1 - [ Aprovisionar Cluster Principal AWS iac/aws (VPC, SG, Roles, Control Plane, Node Group) --> 11 Resources ]"
    echo -e " ${VERDE}2.${NC} Fase 2 - [ Aprovisionar ArgoCD + METRICS SERVER ]"
    echo -e " ${VERDE}3.${NC} Fase 3 - [ Aprovisionar — Secretos SSM + CSI + IRSA ]"
    echo -e " ${VERDE}4.${NC} Fase 4 - [ Aprovisionar - LB Controller + IRSA (~5 min): Incluye el IMPORT del OIDC Provider ]"
    echo -e " ${VERDE}5.${NC} Fase 5 - [ Aprovisionar — GitOps: la aplicación con secretos (~3 min) ]"
    echo -e " ${AMARILLO}0.${NC} Salir"
    echo -e "${AZUL}========================================${NC}"
}

# ============================================================
# FUNCIONES DE CADA OPCIÓN (placeholders para que agregues tu lógica)
# ============================================================

opcion1() {
    echo -e "\n${VERDE}[ Ejecutando FASE 1 - Aprovisionando Cluster Principal ]${NC}"

    configurar_region

    # --- Parámetros de la Fase 1 (menú: "11 Resources") ---
    local RECURSOS_ESPERADOS=11     # Recursos gestionados del state (roles IAM, control plane, SG, node group, access entries)
    local MAX_INTENTOS=3            # Relanzamientos del apply si no están los 11 componentes
    local ESPERA_REINTENTO=20       # Segundos entre reintentos (propagación IAM -> node group)
    local TIMEOUT_NODOS=600         # Segundos máximos esperando nodos Ready

    local TF_DIR="$REPO_ROOT/iac/aws"

    # --- 0) Validaciones previas: herramientas y credenciales AWS ---
    local cmd
    for cmd in terraform aws kubectl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} Credenciales AWS inválidas o expiradas (revisa tu sesión)."
        leer_enter
        return 1
    fi

    if ! cd "$TF_DIR"; then
        echo -e "${ROJO}[ERROR]${NC} No existe el directorio $TF_DIR"
        leer_enter
        return 1
    fi

    # --- 1) terraform init: idempotente (solo prepara backend y providers) ---
    echo -e "\n${AZUL}[1/3] terraform init${NC}"
    if ! terraform init -input=false; then
        echo -e "${ROJO}[ERROR]${NC} terraform init falló."
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi

    # --- 2) apply idempotente con relanzamiento hasta completar los 11 recursos ---
    echo -e "\n${AZUL}[2/3] terraform apply (idempotente, hasta ${MAX_INTENTOS} intentos)${NC}"

    local intento=0 creados=0 rc_apply=0 rc_plan=0 plan_out
    while [ "$intento" -lt "$MAX_INTENTOS" ]; do
        intento=$((intento + 1))
        echo -e "\n${AMARILLO}--- Intento ${intento}/${MAX_INTENTOS} ---${NC}"

        # Plan informativo: exit 0 = sin cambios (ya aprovisionado), exit 2 = cambios pendientes
        plan_out=$(terraform plan -input=false -detailed-exitcode -lock-timeout=60s 2>&1)
        rc_plan=$?
        case $rc_plan in
            0) echo "Estado actual: infraestructura ya aprovisionada (sin cambios pendientes)." ;;
            2) echo "Estado actual: hay cambios pendientes; aplicando..." ;;
            *) echo -e "${ROJO}[WARN]${NC} terraform plan devolvió error (se intentará apply igualmente):"
               echo "$plan_out" | tail -n 15 ;;
        esac

        # Apply: crea solo lo que falta; si los 11 recursos ya existen no modifica
        # nada (idempotencia). No se aborta si falla: la verificación relanza.
        terraform apply -auto-approve -input=false -lock-timeout=60s
        rc_apply=$?

        # Verificación: recursos gestionados del state (excluye data sources)
        creados=$(terraform state list 2>/dev/null | grep -cv '^data\.')

        if [ "$creados" -ge "$RECURSOS_ESPERADOS" ]; then
            echo -e "${VERDE}[OK]${NC} ${creados}/${RECURSOS_ESPERADOS} recursos presentes en el state."
            break
        fi

        echo -e "${AMARILLO}[WARN]${NC} Solo ${creados}/${RECURSOS_ESPERADOS} recursos creados (apply rc=${rc_apply})."
        if [ "$intento" -lt "$MAX_INTENTOS" ]; then
            echo -e "${AMARILLO}Relanzando terraform apply en ${ESPERA_REINTENTO}s...${NC}"
            sleep "$ESPERA_REINTENTO"
        fi
    done

    if [ "$creados" -lt "$RECURSOS_ESPERADOS" ]; then
        echo -e "\n${ROJO}[ERROR]${NC} Fase 1 incompleta: ${creados}/${RECURSOS_ESPERADOS} recursos tras ${MAX_INTENTOS} intentos."
        echo -e "${ROJO}Revisa los errores de Terraform; vuelve a ejecutar la opción 1 (es idempotente: solo creará lo que falte).${NC}"
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi

    # --- 3) kubeconfig + espera de nodos Ready ---
    echo -e "\n${AZUL}[3/3] Configurando kubeconfig y verificando nodos${NC}"

    local cluster_name
    cluster_name=$(terraform output -raw cluster_name 2>/dev/null)
    cd "$REPO_ROOT" || return 1
    [ -z "$cluster_name" ] && cluster_name="sri-eks-cluster"

    if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name"; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo actualizar el kubeconfig del clúster '${cluster_name}'."
        leer_enter
        return 1
    fi

    # Espera acotada a que el node group registre nodos Ready. No es fatal:
    # si expira, se informa y se puede reintentar ejecutando la opción 1 de nuevo.
    local espera=0 nodos_ready=0
    while [ "$espera" -lt "$TIMEOUT_NODOS" ]; do
        if kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; then
            nodos_ready=1
            break
        fi
        sleep 15
        espera=$((espera + 15))
        echo -e "${AMARILLO}  Esperando nodos Ready... (${espera}s)${NC}"
    done

    kubectl get nodes   # Esperado: 3 nodos Ready (t3.medium)
    if [ "$nodos_ready" -eq 1 ]; then
        echo -e "\n${VERDE}Fase 1 completada: ${creados}/${RECURSOS_ESPERADOS} recursos y clúster accesible.${NC}"
    else
        echo -e "\n${AMARILLO}[WARN]${NC} Los nodos aún no reportan Ready tras ${TIMEOUT_NODOS}s; el node group puede tardar unos minutos más."
    fi

    leer_enter
    return 0
}

opcion2() {
    echo -e "\n${VERDE}[ Ejecutando FASE 2 - Aprovisionar ArgoCD + METRICS SERVER ]${NC}"

    configurar_region

    # --- Validaciones previas: herramientas ---
    local cmd
    for cmd in terraform aws kubectl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- kubeconfig apuntando al clúster de la Fase 1 ---
    local cluster_name
    cluster_name=$(terraform -chdir="$REPO_ROOT/iac/aws" output -raw cluster_name 2>/dev/null)
    [ -z "$cluster_name" ] && cluster_name="sri-eks-cluster"

    echo -e "\n${AZUL}[0/2] kubeconfig: ${cluster_name} (${AWS_REGION})${NC}"
    if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name"; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo actualizar el kubeconfig del clúster '${cluster_name}'."
        leer_enter
        return 1
    fi
    echo -e "Contexto actual: $(kubectl config current-context)"

    # --- 1) ArgoCD (server-side: las CRDs superan los 256KB del apply cliente) ---
    echo -e "\n${AZUL}[1/2] Instalando ArgoCD${NC}"
    # El apply del install.yaml (siguiente bloque) exige que el namespace exista.
    # Nota: en un pipe (a | b) el exit code es el del ULTIMO comando (kubectl
    # apply), que es justamente el que materializa el namespace en el cluster:
    # validar el pipe equivale a validar que argocd quedo creado.
    if ! kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo crear el namespace argocd (apply falló)."
        leer_enter
        return 1
    fi
    if ! kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side; then
        echo -e "${ROJO}[ERROR]${NC} Falló el apply del install.yaml de ArgoCD."
        leer_enter
        return 1
    fi

    local espera=0 pods_running=0
    while [ "$espera" -lt 300 ]; do
        pods_running=$(kubectl get pods -n argocd --no-headers 2>/dev/null | grep -c "Running" || true)
        [ "$pods_running" -ge 7 ] && break
        sleep 10
        espera=$((espera + 10))
        echo -e "${AMARILLO}  Esperando pods de ArgoCD... (${espera}s, ${pods_running}/7 Running)${NC}"
    done
    kubectl get pods -n argocd
    if [ "$pods_running" -ge 7 ]; then
        echo -e "\n${VERDE}ArgoCD instalado correctamente (${pods_running}/7 pods Running).${NC}"
    else
        echo -e "\n${AMARILLO}[WARN]${NC} Solo ${pods_running}/7 pods Running tras 300s; el resto puede terminar de arrancar en unos minutos más."
    fi

    # --- 2) metrics-server (EKS no lo trae; el HPA queda ciego sin él) ---
    echo -e "\n${AZUL}[2/2] Instalando metrics-server${NC}"
    if ! kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml; then
        echo -e "${ROJO}[ERROR]${NC} Falló el apply de metrics-server."
        leer_enter
        return 1
    fi

    espera=0
    local nodos_con_metricas=0
    while [ "$espera" -lt 180 ]; do
        nodos_con_metricas=$(kubectl top nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "$nodos_con_metricas" -ge 3 ] && break
        sleep 10
        espera=$((espera + 10))
        echo -e "${AMARILLO}  Esperando métricas de nodos... (${espera}s)${NC}"
    done
    kubectl top nodes
    if [ "$nodos_con_metricas" -ge 3 ]; then
        echo -e "\n${VERDE}Metrics-server operativo: ${nodos_con_metricas} nodos reportando métricas.${NC}"
    else
        echo -e "\n${AMARILLO}[WARN]${NC} kubectl top sin datos completos tras 180s; el primer scrape de metrics-server puede tardar unos minutos más."
    fi

    leer_enter
    return 0
}

opcion3() {
    echo -e "\n${VERDE}[ Ejecutando FASE 3 — Secretos SSM + CSI + IRSA ]${NC}"
    
    # --- Validaciones previas: herramientas (helm lo exige el bootstrap del driver) ---
    local cmd
    for cmd in terraform aws kubectl helm; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- Parámetros de la Fase 3 (módulo iac/aws/secrets-csi: 8 recursos en state) ---
    local TF_DIR="$REPO_ROOT/iac/aws/secrets-csi"
    local RECURSOS_ESPERADOS=8     # OIDC provider, rol IRSA + attachments, 3 parámetros SSM, random_password
    local MAX_INTENTOS=3           # Relanzamientos del apply si no están los 8 recursos
    local ESPERA_REINTENTO=20      # Segundos entre reintentos (propagación IAM)

    if ! cd "$TF_DIR"; then
        echo -e "${ROJO}[ERROR]${NC} No existe el directorio $TF_DIR"
        leer_enter
        return 1
    fi

    # --- 1) terraform init: idempotente (solo prepara backend y providers) ---
    echo -e "\n${AZUL}[1/3] terraform init${NC}"
    if ! terraform init -input=false; then
        echo -e "${ROJO}[ERROR]${NC} terraform init falló."
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi

    # --- 2) apply idempotente con relanzamiento hasta completar los 8 recursos ---
    echo -e "\n${AZUL}[2/3] terraform apply (idempotente, hasta ${MAX_INTENTOS} intentos)${NC}"

    local intento=0 creados=0 rc_apply=0 rc_plan=0 plan_out

    while [ "$intento" -lt "$MAX_INTENTOS" ]; do
        intento=$((intento + 1))
        echo -e "\n${AMARILLO}--- Intento ${intento}/${MAX_INTENTOS} ---${NC}"

        # Plan informativo: exit 0 = sin cambios (ya aprovisionado), exit 2 = cambios pendientes
        plan_out=$(terraform plan -input=false -detailed-exitcode -lock-timeout=60s 2>&1)
        rc_plan=$?
        case $rc_plan in
            0) echo "Estado actual: infraestructura ya aprovisionada (sin cambios pendientes)." ;;
            2) echo "Estado actual: hay cambios pendientes; aplicando..." ;;
            *) echo -e "${ROJO}[WARN]${NC} terraform plan devolvió error (se intentará apply igualmente):"
               echo "$plan_out" | tail -n 15 ;;
        esac

        # Apply: crea solo lo que falta; si los 11 recursos ya existen no modifica
        # nada (idempotencia). No se aborta si falla: la verificación relanza.
        terraform apply -auto-approve -input=false -lock-timeout=60s
        rc_apply=$?

        # Verificación: recursos gestionados del state (excluye data sources)
        creados=$(terraform state list 2>/dev/null | grep -cv '^data\.')

        if [ "$creados" -ge "$RECURSOS_ESPERADOS" ]; then
            echo -e "${VERDE}[OK]${NC} ${creados}/${RECURSOS_ESPERADOS} recursos presentes en el state."
            break
        fi

        echo -e "${AMARILLO}[WARN]${NC} Solo ${creados}/${RECURSOS_ESPERADOS} recursos creados (apply rc=${rc_apply})."
        if [ "$intento" -lt "$MAX_INTENTOS" ]; then
            echo -e "${AMARILLO}Relanzando terraform apply en ${ESPERA_REINTENTO}s...${NC}"
            sleep "$ESPERA_REINTENTO"
        fi
    done
    
    # --- 3) Verificación final del apply: sin esto se seguiría al bootstrap con
    #        infra a medias (rol IRSA inexistente => driver en CrashLoop) ---
    if [ "$creados" -lt "$RECURSOS_ESPERADOS" ]; then
        echo -e "\n${ROJO}[ERROR]${NC} Fase 3 incompleta: ${creados}/${RECURSOS_ESPERADOS} recursos tras ${MAX_INTENTOS} intentos."
        echo -e "${ROJO}Revisa los errores de Terraform; vuelve a ejecutar la opción 3 (es idempotente: solo creará lo que falte).${NC}"
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi

    # Outputs informativos (nombres confirmados en iac/aws/secrets-csi/outputs.tf).
    # -raw: sin comillas JSON y sin depender de jq (así lo lee el propio bootstrap).
    local secrets_csi_role_arn oidc_provider_arn
    secrets_csi_role_arn=$(terraform output -raw secrets_csi_role_arn 2>/dev/null)
    oidc_provider_arn=$(terraform output -raw oidc_provider_arn 2>/dev/null)

    echo "SECRETS_CSI_ROLE_ARN: ${secrets_csi_role_arn:-(vacío — revisa el apply)}"
    echo "OIDC_PROVIDER_ARN: ${oidc_provider_arn:-(vacío — revisa el apply)}"

    # --- 4) Bootstrap del driver: script portable (auto-detecta la raíz).
    #        Se invoca DESDE la raíz del repo, como indica su cabecera
    #        ("Uso: bash scripts/bootstrap-secrets-csi-eks.sh") ---
    cd "$REPO_ROOT" || return 1
    if ! bash scripts/bootstrap-secrets-csi-eks.sh; then
        echo -e "${ROJO}[ERROR]${NC} Falló la ejecución de bootstrap-secrets-csi-eks.sh"
        leer_enter
        return 1
    fi

    leer_enter
}

opcion4() {
    echo -e "\n${VERDE}[Ejecutando FASE 4 — LB Controller + IRSA: incluye el IMPORT del OIDC Provider]${NC}"

    configurar_region

    # --- Validaciones previas: herramientas (helm lo exige el bootstrap del controller) ---
    local cmd
    for cmd in terraform aws kubectl helm; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- Parámetros de la Fase 4 (módulo iac/aws/lb-controller: 4 recursos en state) ---
    local TF_DIR="$REPO_ROOT/iac/aws/lb-controller"
    local RECURSOS_ESPERADOS=3     # OIDC provider (importado) + rol IRSA + policy oficial + attachment
    local MAX_INTENTOS=3           # Relanzamientos del apply si no están los 4 recursos
    local ESPERA_REINTENTO=20      # Segundos entre reintentos (propagación IAM)

    if ! cd "$TF_DIR"; then
        echo -e "${ROJO}[ERROR]${NC} No existe el directorio $TF_DIR"
        leer_enter
        return 1
    fi

    # --- 0) Precondición: el OIDC provider lo creó la Fase 3 (módulo secrets-csi).
    #        Aquí solo lo "adoptamos" en el state de este módulo vía import. ---
    local OIDC_ARN
    OIDC_ARN=$(terraform -chdir="$REPO_ROOT/iac/aws/secrets-csi" output -raw oidc_provider_arn 2>/dev/null)
    if [ -z "$OIDC_ARN" ]; then
        echo -e "${ROJO}[ERROR]${NC} No se encontró el output 'oidc_provider_arn' del módulo secrets-csi."
        echo -e "${ROJO}Ejecuta primero la Fase 3 (opción 3): el OIDC provider que aquí se importa lo crea ese módulo.${NC}"
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi
    echo "OIDC provider a adoptar: $OIDC_ARN"

    # --- 1) terraform init: idempotente (solo prepara backend y providers) ---
    echo -e "\n${AZUL}[1/4] terraform init${NC}"
    if ! terraform init -input=false; then
        echo -e "${ROJO}[ERROR]${NC} terraform init falló."
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi

    # --- 2) Import del OIDC provider: SOLO si aún no está en el state.
    #        La guarda hace la opción reejecutable: sin ella, un segundo run
    #        moriría con "Resource already managed by Terraform". ---
    echo -e "\n${AZUL}[2/4] Import del OIDC provider (adopción del creado por secrets-csi)${NC}"
    if terraform state list 2>/dev/null | grep -qxF 'aws_iam_openid_connect_provider.eks'; then
        echo "OIDC provider ya gestionado en este state — import omitido (re-ejecución idempotente)."
    else
        if ! terraform import aws_iam_openid_connect_provider.eks "$OIDC_ARN"; then
            echo -e "${ROJO}[ERROR]${NC} El import falló. Causas típicas: el OIDC no existe en la cuenta"
            echo -e "${ROJO}(¿se destruyó secrets-csi? vuelve a correr la Fase 3) o el ARN no coincide.${NC}"
            cd "$REPO_ROOT" || return 1
            leer_enter
            return 1
        fi
        echo -e "${VERDE}[OK]${NC} OIDC provider importado en el state de lb-controller."
    fi

    # --- 3) apply idempotente con relanzamiento hasta completar los 4 recursos ---
    echo -e "\n${AZUL}[3/4] terraform apply (idempotente, hasta ${MAX_INTENTOS} intentos)${NC}"
    echo -e "${AMARILLO}Esperado en el plan: 3 to add (rol alb-controller + policy oficial + attachment); el OIDC ya llegó vía import.${NC}"

    local intento=0 creados=0 rc_apply=0 rc_plan=0 plan_out

    while [ "$intento" -lt "$MAX_INTENTOS" ]; do
        intento=$((intento + 1))
        echo -e "\n${AMARILLO}--- Intento ${intento}/${MAX_INTENTOS} ---${NC}"

        # Plan informativo: exit 0 = sin cambios (ya aprovisionado), exit 2 = cambios pendientes
        plan_out=$(terraform plan -input=false -detailed-exitcode -lock-timeout=60s 2>&1)
        rc_plan=$?
        case $rc_plan in
            0) echo "Estado actual: infraestructura ya aprovisionada (sin cambios pendientes)." ;;
            2) echo "Estado actual: hay cambios pendientes; aplicando..." ;;
            *) echo -e "${ROJO}[WARN]${NC} terraform plan devolvió error (se intentará apply igualmente):"
               echo "$plan_out" | tail -n 15 ;;
        esac

        # Apply: crea solo lo que falta; idempotente. No se aborta si falla:
        # la verificación por conteo de recursos relanza.
        terraform apply -auto-approve -input=false -lock-timeout=60s
        rc_apply=$?

        # Verificación: recursos gestionados del state (excluye data sources)
        creados=$(terraform state list 2>/dev/null | grep -cv '^data\.')

        if [ "$creados" -ge "$RECURSOS_ESPERADOS" ]; then
            echo -e "${VERDE}[OK]${NC} ${creados}/${RECURSOS_ESPERADOS} recursos presentes en el state."
            break
        fi

        echo -e "${AMARILLO}[WARN]${NC} Solo ${creados}/${RECURSOS_ESPERADOS} recursos creados (apply rc=${rc_apply})."
        if [ "$intento" -lt "$MAX_INTENTOS" ]; then
            echo -e "${AMARILLO}Relanzando terraform apply en ${ESPERA_REINTENTO}s...${NC}"
            sleep "$ESPERA_REINTENTO"
        fi
    done

    # --- Verificación final del apply: sin esto se seguiría al bootstrap con
    #        infra a medias (rol IRSA inexistente => controller sin identidad) ---
    if [ "$creados" -lt "$RECURSOS_ESPERADOS" ]; then
        echo -e "\n${ROJO}[ERROR]${NC} Fase 4 incompleta: ${creados}/${RECURSOS_ESPERADOS} recursos tras ${MAX_INTENTOS} intentos."
        echo -e "${ROJO}Revisa los errores de Terraform; vuelve a ejecutar la opción 4 (es idempotente: solo creará lo que falte).${NC}"
        cd "$REPO_ROOT" || return 1
        leer_enter
        return 1
    fi

    # Outputs informativos (nombres confirmados en iac/aws/lb-controller/outputs.tf)
    local irsa_role_arn policy_arn
    irsa_role_arn=$(terraform output -raw irsa_role_arn 2>/dev/null)
    policy_arn=$(terraform output -raw policy_arn 2>/dev/null)
    echo "IRSA_ROLE_ARN: ${irsa_role_arn:-(vacío — revisa el apply)}"
    echo "POLICY_ARN: ${policy_arn:-(vacío — revisa el apply)}"

    # --- 4) kubeconfig + bootstrap del controller (script portable; se invoca
    #        DESDE la raíz). El update-kubeconfig blinda la fase ante contextos
    #        viejos (lección del "no such host" del AKS destruido). ---
    echo -e "\n${AZUL}[4/4] kubeconfig + bootstrap del AWS Load Balancer Controller${NC}"
    cd "$REPO_ROOT" || return 1

    local cluster_name
    cluster_name=$(terraform -chdir="$REPO_ROOT/iac/aws" output -raw cluster_name 2>/dev/null)
    [ -z "$cluster_name" ] && cluster_name="sri-eks-cluster"

    if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name"; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo actualizar el kubeconfig del clúster '${cluster_name}'."
        leer_enter
        return 1
    fi
    echo -e "Contexto actual: $(kubectl config current-context)"

    if ! bash scripts/bootstrap-lb-controller-eks.sh; then
        echo -e "${ROJO}[ERROR]${NC} Falló la ejecución de bootstrap-lb-controller-eks.sh"
        leer_enter
        return 1
    fi

    leer_enter
    return 0
}

opcion5() {
    echo -e "\n${VERDE}[ Ejecutando FASE 5 — GitOps: la aplicación con secretos (~3 min) ]${NC}"

    configurar_region

    # --- Validaciones previas: herramientas (fase pura GitOps: solo kubectl/aws;
    #        helm/terraform no se usan aquí) ---
    local cmd
    for cmd in aws kubectl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- Parámetros de la Fase 5 (nombres confirmados en los manifiestos) ---
    local PROJECT_MANIFEST="$REPO_ROOT/gitops/argocd/project.yaml"         # AppProject sri-facturacion
    local APP_MANIFEST="$REPO_ROOT/gitops/argocd/application-aws-eks.yaml"  # Application sri-facturacion-aws-eks
    local APP_NAME="sri-facturacion-aws-eks"
    local DEPLOY_NAME="sri-facturacion-service-deployment"
    local NS_APP="sri-facturacion"
    local TIMEOUT_SYNC=300     # Esperado: Synced/Healthy (~2-3 min)
    local TIMEOUT_PODS=300     # Esperado: 3/3 Running

    # --- Validaciones previas: los manifiestos GitOps existen en el repo ---
    local manifest
    for manifest in "$PROJECT_MANIFEST" "$APP_MANIFEST"; do
        if [ ! -f "$manifest" ]; then
            echo -e "${ROJO}[ERROR]${NC} No existe el manifiesto: $manifest"
            leer_enter
            return 1
        fi
    done

    # --- [1/4] kubeconfig apuntando al clúster de la Fase 1 ---
    echo -e "\n${AZUL}[1/4] kubeconfig + preflight del clúster${NC}"
    # terraform se usa solo para leer el output 'cluster_name'; si no está
    # instalado, el fallback mantiene el nombre por defecto del proyecto.
    local cluster_name
    cluster_name=$(terraform -chdir="$REPO_ROOT/iac/aws" output -raw cluster_name 2>/dev/null)
    [ -z "$cluster_name" ] && cluster_name="sri-eks-cluster"

    if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name"; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo actualizar el kubeconfig del clúster '${cluster_name}'."
        leer_enter
        return 1
    fi
    echo -e "Contexto actual: $(kubectl config current-context)"

    # Precondición dura: ArgoCD instalado (CRD Applications; lo crea la Fase 2)
    if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} ArgoCD no está instalado en este clúster (no existe el CRD applications.argoproj.io)."
        echo -e "${ROJO}Ejecuta primero la Fase 2 (opción 2).${NC}"
        leer_enter
        return 1
    fi

    # Avisos suaves de fases previas: sin el driver CSI los pods quedan en
    # ContainerCreating (volumen secrets-store); sin LB controller, un
    # Ingress del overlay no generaría ALB.
    if ! kubectl get ds secrets-store-csi-driver -n kube-system >/dev/null 2>&1; then
        echo -e "${AMARILLO}[WARN]${NC} Secrets Store CSI Driver no detectado (Fase 3): los pods quedarán en ContainerCreating hasta instalarlo."
    fi
    if ! kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
        echo -e "${AMARILLO}[WARN]${NC} AWS Load Balancer Controller no detectado (Fase 4): sin él, un Ingress no creará el ALB."
    fi

    # --- [2/4] Apply secuencial y verificado del AppProject ---
    echo -e "\n${AZUL}[2/4] kubectl apply: gitops/argocd/project.yaml${NC}"
    if ! kubectl apply -n argocd -f "$PROJECT_MANIFEST"; then
        echo -e "${ROJO}[ERROR]${NC} Falló el apply de project.yaml (AppProject 'sri-facturacion')."
        leer_enter
        return 1
    fi
    if ! kubectl get appproject sri-facturacion -n argocd >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} El AppProject 'sri-facturacion' no existe tras el apply (kubectl reportó OK pero el objeto no está en el cluster)."
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} AppProject 'sri-facturacion' aplicado y verificado."

    # --- [3/4] Apply secuencial y verificado de la Application AWS EKS ---
    echo -e "\n${AZUL}[3/4] kubectl apply: gitops/argocd/application-aws-eks.yaml${NC}"
    if ! kubectl apply -n argocd -f "$APP_MANIFEST"; then
        echo -e "${ROJO}[ERROR]${NC} Falló el apply de application-aws-eks.yaml (Application '${APP_NAME}')."
        leer_enter
        return 1
    fi
    if ! kubectl get application "$APP_NAME" -n argocd >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} La Application '${APP_NAME}' no existe tras el apply (kubectl reportó OK pero el objeto no está en el cluster)."
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Application '${APP_NAME}' aplicada y verificada (syncPolicy.automated activo)."

    # --- [4/4] Espera acotada a Synced/Healthy y pods 3/3 Running ---
    # En vez de 'kubectl -n argocd get applications -w' (watch infinito, no apto
    # para automatización): sondeo con timeout para poder verificar el resultado.
    echo -e "\n${AZUL}[4/4] Esperando ArgoCD Synced/Healthy y pods Running${NC}"

    local espera=0 estado_app=""
    while [ "$espera" -lt "$TIMEOUT_SYNC" ]; do
        estado_app=$(kubectl get application "$APP_NAME" -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
        [ "$estado_app" = "Synced/Healthy" ] && break
        sleep 10
        espera=$((espera + 10))
        echo -e "${AMARILLO}  Estado de la Application: ${estado_app:-<sin estado>} (${espera}s)${NC}"
    done

    kubectl -n argocd get applications
    if [ "$estado_app" != "Synced/Healthy" ]; then
        echo -e "\n${ROJO}[ERROR]${NC} '${APP_NAME}' NO llegó a Synced/Healthy en ${TIMEOUT_SYNC}s (último estado: ${estado_app:-desconocido})."
        echo -e "${ROJO}Diagnóstico: kubectl -n argocd describe application ${APP_NAME}${NC}"
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Application ${estado_app}."

    # Pods del microservicio (destination.namespace del overlay aws-eks).
    # readyReplicas >= 3 tolera el escalado posterior del HPA.
    espera=0
    local pods_ready=0
    while [ "$espera" -lt "$TIMEOUT_PODS" ]; do
        pods_ready=$(kubectl -n "$NS_APP" get deployment "$DEPLOY_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        pods_ready=${pods_ready:-0}
        [ "$pods_ready" -ge 3 ] && break
        sleep 10
        espera=$((espera + 10))
        echo -e "${AMARILLO}  Pods ready: ${pods_ready}/3 (${espera}s)${NC}"
    done

    kubectl -n "$NS_APP" get pods   # Esperado: 3/3 Running
    if [ "$pods_ready" -ge 3 ]; then
        echo -e "\n${VERDE}Fase 5 completada: '${APP_NAME}' ${estado_app} y ${pods_ready}/3 pods Ready.${NC}"
    else
        echo -e "\n${AMARILLO}[WARN]${NC} Solo ${pods_ready}/3 pods ready tras ${TIMEOUT_PODS}s. Si siguen en ContainerCreating, revisa el driver CSI/IRSA (Fase 3):"
        echo -e "${AMARILLO}kubectl -n ${NS_APP} describe pod <pod> | grep -A5 Events${NC}"
    fi

    leer_enter
    return 0
}

opcion6() {
    echo -e "\n${VERDE}[ Ejecutando FASE 6 — GitOps: la aplicación sin secretos (~3 min) ]${NC}"
    configurar_region
}

# ============================================================
# FUNCIÓN AUXILIAR: Pausa para leer antes de volver al menú
# ============================================================
leer_enter() {
    echo ""
    read -p "Presiona [ENTER] para continuar..."
}

# ============================================================
# FUNCIÓN: Confirmar salida
# ============================================================
confirmar_salida() {
    echo ""
    read -p "¿Estás seguro que deseas salir? (s/n): " respuesta
    case "$respuesta" in
        [sS]|[sS][iI])
            echo -e "${ROJO}Saliendo del programa...${NC}"
            exit 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# BUCLE PRINCIPAL DEL MENÚ
# ============================================================
while true; do
    mostrar_menu
    read -p "Selecciona una opción [0-4]: " opcion

    case "$opcion" in
        1)
            opcion1
            ;;
        2)
            opcion2
            ;;
        3)
            opcion3
            ;;
        4)
            opcion4
            ;;
        5)
            opcion5
            ;;
        6)
            opcion6
            ;;
        0)
            if confirmar_salida; then
                break
            fi
            ;;
        *)
            echo -e "\n${ROJO}[ERROR]${NC} Opción inválida. Por favor, elige un número entre 0 y 4."
            sleep 2
            ;;
    esac
done
