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
    echo -e "${AZUL}========================================================================================================================${NC}"
    echo -e "${AZUL}                                              MENÚ DE AUTOMATIZACIÓN                                                    ${NC}"
    echo -e "${AMARILLO} Menu de Opciones : AWS EKS - GitOps Multicloud.                                                                    ${NC}"
    echo -e "${AMARILLO} Directorio Trabajo : ./${REPO_ROOT##*/}                                                                            ${NC}"
    echo -e "${AZUL}========================================================================================================================${NC}"
    echo -e " ${VERDE}1.${NC} Fase 1 - [ Aprovisionar Cluster Principal AWS iac/aws (VPC, SG, Roles, Control Plane, Node Group) --> 11 Resources ]"
    echo -e " ${VERDE}2.${NC} Fase 2 - [ Aprovisionar ArgoCD + METRICS SERVER ]"
    echo -e " ${VERDE}3.${NC} Fase 3 - [ Aprovisionar — Secretos SSM + CSI + IRSA ]"
    echo -e " ${VERDE}4.${NC} Fase 4 - [ Aprovisionar - LB Controller + IRSA (~5 min): Incluye el IMPORT del OIDC Provider ]"
    echo -e " ${VERDE}5.${NC} Fase 5 - [ Aprovisionar — GitOps: la aplicación con secretos  ]"
    echo -e " ${VERDE}6.${NC} Fase 6 - [ Verificar — Demo de la cadena SSM -> CSI -> env ]"
    echo -e " ${VERDE}7.${NC} Fase 7 - [ Aprovisionar - Demo ON: commit/push Ingress ALB + HPA 5% y espera el ADDRESS ]"
    echo -e " ${VERDE}8.${NC} Fase 8 - [ Carga - Pruebas hey sobre Ingress ALB + HPA 5% + monitoreo en vivo ]"
    echo -e " ${VERDE}9.${NC} Fase 9 - [ Pendiente - bucle pipeline GitOps (ocurre en GitHub: PR + merge + Actions + ArgoCD) ]"
    echo -e " ${VERDE}10.${NC} Fase 10 - [ Cierre - Demo OFF + prune ALB + destroys ordenados (lb-controller -> secrets-csi -> cluster) ]"
    echo -e " ${AMARILLO}0.${NC} Salir"
    echo -e "${AZUL}========================================================================================================================${NC}"
}

# Funciones del menu principal

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
    echo -e "\n${VERDE}[ Ejecutando FASE 6 — GitOps: Verificación de secretos (~3 min) ]${NC}"

    configurar_region

    # --- Parámetros de la Fase 6 (nombres confirmados en manifiestos y Fase 3) ---
    local NS_APP="sri-facturacion"
    local DEPLOY_NAME="sri-facturacion-service-deployment"
    # Secret nativo que sincroniza el driver CSI (secretObjects/syncSecret).
    # NOTA: es el 'orphaned resource' que ArgoCD reporta — lo crea el driver
    # en runtime, no vive en Git (por diseño).
    local SECRET_NAME="sri-facturacion-db"
    local MOUNT_PATH="/mnt/secrets-store"  # Volumen del driver CSI dentro del contenedor
    local TIMEOUT_READY=60                 # Segundos máximos esperando >=1 pod Ready

    # --- Validaciones previas: herramientas (fase de verificación: solo aws/kubectl) ---
    local cmd
    for cmd in aws kubectl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- Preflight: kubeconfig apuntando al clúster de la Fase 1 ---
    echo -e "\n${AZUL}[preflight] kubeconfig + estado del deployment${NC}"
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

    # Precondición dura: el deployment de la app existe (lo crea la Fase 5)
    if ! kubectl -n "$NS_APP" get deployment "$DEPLOY_NAME" >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} No existe el deployment '${DEPLOY_NAME}' en '${NS_APP}'."
        echo -e "${ROJO}Ejecuta primero la Fase 5 (opción 5).${NC}"
        leer_enter
        return 1
    fi

    # Al menos 1 pod Ready para poder hacer 'kubectl exec' (espera acotada)
    local espera=0 pods_ready=0
    while [ "$espera" -lt "$TIMEOUT_READY" ]; do
        pods_ready=$(kubectl -n "$NS_APP" get deployment "$DEPLOY_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        pods_ready=${pods_ready:-0}
        [ "$pods_ready" -ge 1 ] && break
        sleep 5
        espera=$((espera + 5))
    done
    if [ "$pods_ready" -lt 1 ]; then
        echo -e "${ROJO}[ERROR]${NC} El deployment no tiene pods Ready. Si están en ContainerCreating, revisa el driver CSI/IRSA (Fase 3)."
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Deployment con ${pods_ready} pod(s) Ready."

    # --- [1/4] Montaje directo: parámetros SSM como archivos (volumen CSI) ---
    echo -e "\n${AZUL}[1/4] Montaje directo: kubectl exec deploy/${DEPLOY_NAME} -- ls -l ${MOUNT_PATH}/${NC}"
    local mount_out
    mount_out=$(kubectl -n "$NS_APP" exec deploy/"$DEPLOY_NAME" -- ls -l "$MOUNT_PATH/" 2>&1)
    echo "$mount_out"

    # Esperado: DB_HOST  DB_PASSWORD  DB_USER (symlinks del driver)
    local clave faltantes=""
    for clave in DB_HOST DB_PASSWORD DB_USER; do
        echo "$mount_out" | grep -q "$clave" || faltantes="$faltantes $clave"
    done
    if [ -n "$faltantes" ]; then
        echo -e "${ROJO}[ERROR]${NC} Faltan archivos en el montaje:${faltantes}"
        echo -e "${ROJO}Diagnóstico: kubectl -n ${NS_APP} describe pod <pod> | grep -A5 Events${NC}"
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Los 3 archivos están montados (DB_HOST, DB_PASSWORD, DB_USER)."

    # --- [2/4] Secret nativo sincronizado por el driver (alimenta el envFrom) ---
    echo -e "\n${AZUL}[2/4] Secret nativo: kubectl get secret ${SECRET_NAME}${NC}"
    if ! kubectl -n "$NS_APP" get secret "$SECRET_NAME"; then
        echo -e "${ROJO}[ERROR]${NC} No existe el Secret '${SECRET_NAME}' (lo crea el driver CSI con secretObjects/syncSecret)."
        leer_enter
        return 1
    fi

    local secret_keys
    secret_keys=$(kubectl -n "$NS_APP" get secret "$SECRET_NAME" -o go-template='{{len .data}}' 2>/dev/null)
    secret_keys=${secret_keys:-0}
    if [ "$secret_keys" -ne 3 ]; then
        echo -e "${AMARILLO}[WARN]${NC} El Secret tiene ${secret_keys} clave(s) (esperado: 3 -> DB_HOST, DB_PASSWORD, DB_USER)."
    else
        echo -e "${VERDE}[OK]${NC} Secret con 3 claves (DB_HOST, DB_PASSWORD, DB_USER)."
    fi

    # --- [3/4] La cadena hasta el proceso: variables de entorno del contenedor ---
    # Demo sin exponer el password: se muestran solo DB_USER/DB_HOST y se
    # verifica la PRESENCIA de DB_PASSWORD (sin imprimir su valor).
    echo -e "\n${AZUL}[3/4] Cadena hasta el proceso: env | grep -E 'DB_(USER|HOST)'${NC}"
    local env_out
    env_out=$(kubectl -n "$NS_APP" exec deploy/"$DEPLOY_NAME" -- env 2>/dev/null)
    if [ -z "$env_out" ]; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo leer el entorno del pod (kubectl exec falló)."
        leer_enter
        return 1
    fi
    echo "$env_out" | grep -E '^DB_(USER|HOST)=' || true

    local env_faltantes=""
    for clave in DB_HOST DB_PASSWORD DB_USER; do
        echo "$env_out" | grep -q "^${clave}=" || env_faltantes="$env_faltantes $clave"
    done
    if [ -n "$env_faltantes" ]; then
        echo -e "${ROJO}[ERROR]${NC} Variables NO inyectadas al proceso:${env_faltantes}"
        echo -e "${ROJO}Revisa envFrom/secretKeyRef en el patch del deployment (Fases 3/5).${NC}"
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} DB_HOST y DB_USER visibles arriba; DB_PASSWORD presente (valor oculto por seguridad)."

    # --- [4/4] Fuente de verdad: SSM Parameter Store (sin exponer valores) ---
    echo -e "\n${AZUL}[4/4] Fuente de verdad: aws ssm describe-parameters (prefijo /sri-facturacion)${NC}"
    local ssm_out
    ssm_out=$(aws ssm describe-parameters --region "$AWS_REGION" \
        --parameter-filters "Key=Name,Option=BeginsWith,Values=/sri-facturacion" \
        --query "Parameters[].[Name,Type]" --output table 2>&1)
    echo "$ssm_out"

    local n_total n_secure
    n_total=$(echo "$ssm_out" | grep -c '/sri-facturacion/')
    n_secure=$(echo "$ssm_out" | grep -c 'SecureString')
    if [ "${n_total:-0}" -lt 3 ] || [ "${n_secure:-0}" -lt 3 ]; then
        echo -e "${ROJO}[ERROR]${NC} Se esperaban 3 parámetros SecureString bajo /sri-facturacion (encontrados: ${n_total:-0}, SecureString: ${n_secure:-0})."
        echo -e "${ROJO}Ejecuta la Fase 3 (opción 3): módulo iac/aws/secrets-csi.${NC}"
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} ${n_total} parámetros SSM, todos SecureString."

    echo -e "\n${VERDE}Fase 6 verificada: cadena completa SSM -> driver CSI -> Secret nativo -> env del pod.${NC}"
    leer_enter
    return 0
}

opcion7() {
    echo -e "\n${VERDE}[ Ejecutando FASE 7 — Demo ON: commit/push Ingress ALB + HPA 5% y espera el ADDRESS (~3 min) ]${NC}"

    configurar_region

    # --- Parámetros de la Fase 7 (nombres confirmados en manifiestos y fases previas) ---
    local OVERLAY_KUST="gitops/overlays/aws-eks/kustomization.yaml"   # relativo al repo (paths git)
    local OVERLAY_DIR="$REPO_ROOT/gitops/overlays/aws-eks"            # absoluto (kubectl kustomize)
    local APP_NAME="sri-facturacion-aws-eks"
    local NS_APP="sri-facturacion"
    local DEPLOY_LB="aws-load-balancer-controller"   # kube-system (Fase 4)
    local BRANCH_ESPERADA="main"                     # ArgoCD targetRevision + rama del pipeline
    local COMMIT_MSG="demo: FASE 7 ON - Ingress ALB + hpa-patch 5% (overlay aws-eks)"
    local TIMEOUT_ALB=300      # Esperado: ADDRESS aparece (~2-3 min)

    # --- Validaciones previas: herramientas (esta fase commitea: entra git) ---
    local cmd
    for cmd in git aws kubectl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- [1/6] Precondiciones Git: rama correcta + edición manual del overlay pendiente ---
    echo -e "\n${AZUL}[1/6] Precondiciones Git${NC}"
    local rama
    rama=$(git -C "$REPO_ROOT" branch --show-current)
    echo "Rama actual: ${rama:-(detached HEAD)}"
    if [ "$rama" != "$BRANCH_ESPERADA" ]; then
        echo -e "${ROJO}[ERROR]${NC} Debes estar en '${BRANCH_ESPERADA}': ArgoCD vigila targetRevision '${BRANCH_ESPERADA}'"
        echo -e "${ROJO}(un commit en otra rama sería invisible para el clúster) y el pipeline solo dispara con main.${NC}"
        leer_enter
        return 1
    fi

    # Debe existir AL MENOS una modificación sin commitear: la edición manual del overlay.
    if [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
        echo -e "${ROJO}[ERROR]${NC} No hay cambios sin commitear."
        echo -e "${ROJO}Primero edita MANUALMENTE ${OVERLAY_KUST}: descomenta '- ingress.yaml' (resources)${NC}"
        echo -e "${ROJO}y el patch 'hpa-patch.yaml' (patches) — FASE 7.1 del runbook. Luego vuelve a la opción 7.${NC}"
        echo -e "${AMARILLO}(Si ya commiteaste pero el push falló, haz 'git push' a mano.)${NC}"
        leer_enter
        return 1
    fi
    if ! git -C "$REPO_ROOT" status --porcelain | grep -q "$OVERLAY_KUST"; then
        echo -e "${ROJO}[ERROR]${NC} El cambio pendiente NO incluye ${OVERLAY_KUST}."
        echo -e "${ROJO}Esta fase solo commitea el overlay aws-eks; revisa qué estás haciendo.${NC}"
        leer_enter
        return 1
    fi
    # Aviso suave si hay OTROS archivos modificados: no entrarán en este commit.
    local otros
    otros=$(git -C "$REPO_ROOT" status --porcelain | grep -v "$OVERLAY_KUST" || true)
    if [ -n "$otros" ]; then
        echo -e "${AMARILLO}[WARN]${NC} Hay otros cambios sin commitear que NO entrarán en este commit:"
        echo "$otros"
    fi

    # --- [2/6] git diff en pantalla + confirmación (la pausa didáctica GitOps) ---
    echo -e "\n${AZUL}[2/6] git diff: el cambio que ArgoCD va a sincronizar${NC}"
    git -C "$REPO_ROOT" --no-pager diff -- "$OVERLAY_KUST"

    local respuesta="" intentos=0
    while [ "$intentos" -lt 5 ]; do
        read -p "Revise los cambios del Ingress+HPA antes de continuar (s/n): " respuesta
        case "$respuesta" in
            [sS]|[sS][iI])
                break
                ;;
            [nN]|[nN][oO])
                echo -e "${AMARILLO}Operación cancelada: corrige el archivo y vuelve a ejecutar la opción 7.${NC}"
                leer_enter
                return 0
                ;;
            *)
                echo -e "${AMARILLO}Responde s o n.${NC}"
                intentos=$((intentos + 1))
                ;;
        esac
    done
    if [ "$intentos" -ge 5 ]; then
        echo -e "${AMARILLO}Demasiados intentos inválidos: operación cancelada.${NC}"
        leer_enter
        return 0
    fi

    # --- [3/6] Puerta de seguridad del render: el commit SOLO sale si el overlay compila
    #     y trae el Ingress + el umbral didáctico 5% (lección del YAML huérfano) ---
    echo -e "\n${AZUL}[3/6] Validación del render Kustomize (antes de commitear)${NC}"
    local render
    if ! render=$(kubectl kustomize "$OVERLAY_DIR" 2>&1); then
        echo -e "${ROJO}[ERROR]${NC} El overlay NO compila (kubectl kustomize falló):"
        echo "$render" | tail -n 10
        echo -e "${ROJO}NO se commiteó nada. Los items descomentados deben quedar DENTRO de${NC}"
        echo -e "${ROJO}'resources:' / 'patches:' con guion a columna 0, target a 2 y kind/name a 4.${NC}"
        leer_enter
        return 1
    fi
    if ! echo "$render" | grep -q "^kind: Ingress$"; then
        echo -e "${ROJO}[ERROR]${NC} El render no contiene 'kind: Ingress': el descomentado no quedó efectivo. NO se commiteó nada."
        leer_enter
        return 1
    fi
    if ! echo "$render" | grep -q "averageUtilization: 5"; then
        echo -e "${ROJO}[ERROR]${NC} El render no trae el umbral didáctico 'averageUtilization: 5' (hpa-patch). NO se commiteó nada."
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Render válido: Ingress presente + HPA con umbral 5%."

    # --- [4/6] Precondiciones del clúster (fail-fast ANTES de publicar el commit) ---
    echo -e "\n${AZUL}[4/6] kubeconfig + preflight del clúster${NC}"
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

    if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} ArgoCD no está instalado (CRD applications.argoproj.io ausente). Ejecuta la Fase 2."
        leer_enter
        return 1
    fi
    if ! kubectl get application "$APP_NAME" -n argocd >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} La Application '${APP_NAME}' no existe. Ejecuta la Fase 5."
        leer_enter
        return 1
    fi
    # Precondición dura: sin controller el Ingress jamás recibe ADDRESS
    # (y la espera de abajo se quemaría entera).
    if ! kubectl get deployment "$DEPLOY_LB" -n kube-system >/dev/null 2>&1; then
        echo -e "${ROJO}[ERROR]${NC} AWS Load Balancer Controller no detectado (Fase 4): sin él el ALB no se crea."
        leer_enter
        return 1
    fi

    # --- [5/6] Commit + push automatizados (SOLO el overlay aws-eks) ---
    echo -e "\n${AZUL}[5/6] git add/commit/push (${OVERLAY_KUST})${NC}"
    if ! git -C "$REPO_ROOT" add -- "$OVERLAY_KUST"; then
        echo -e "${ROJO}[ERROR]${NC} git add falló."
        leer_enter
        return 1
    fi
    if ! git -C "$REPO_ROOT" commit -m "$COMMIT_MSG"; then
        echo -e "${ROJO}[ERROR]${NC} git commit falló."
        leer_enter
        return 1
    fi
    git -C "$REPO_ROOT" log --oneline -1
    if ! git -C "$REPO_ROOT" push; then
        echo -e "${ROJO}[ERROR]${NC} git push falló (¿origin/${BRANCH_ESPERADA} desactualizado? haz 'git pull --ff-only' y reintenta la opción 7)."
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Cambio publicado en origin/${BRANCH_ESPERADA}: ArgoCD lo sincronizará en segundos."

    # --- [6/6] Refresh duro de ArgoCD + espera acotada del ADDRESS del ALB ---
    # En vez de 'kubectl -n sri-facturacion get ingress -w' (watch infinito):
    # sondeo con timeout para poder verificar el resultado.
    echo -e "\n${AZUL}[6/6] Refresh=hard de ArgoCD + espera del ADDRESS del ALB${NC}"
    if ! kubectl -n argocd annotate application "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite; then
        echo -e "${ROJO}[ERROR]${NC} No se pudo anotar la Application (refresh=hard)."
        leer_enter
        return 1
    fi

    local espera=0 alb_dns=""
    while [ "$espera" -lt "$TIMEOUT_ALB" ]; do
        alb_dns=$(kubectl -n "$NS_APP" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        [ -n "$alb_dns" ] && break
        sleep 10
        espera=$((espera + 10))
        echo -e "${AMARILLO}  Esperando ADDRESS del ALB... (${espera}s)${NC}"
    done

    kubectl -n "$NS_APP" get ingress
    if [ -n "$alb_dns" ]; then
        echo -e "\n${VERDE}Fase 7 completada: ALB activo -> http://${alb_dns}${NC}"
        echo -e "${AMARILLO}El ALB factura desde ahora: Importante: La FASE 10 (opción 8) lo apaga ANTES de destruir el clúster principal.${NC}"
        echo -e "Prueba rápida: curl -s http://${alb_dns}/health"
    else
        echo -e "\n${ROJO}[ERROR]${NC} Sin ADDRESS tras ${TIMEOUT_ALB}s."
        echo -e "${ROJO}Diagnóstico: kubectl -n argocd describe application ${APP_NAME} | tail -n 20${NC}"
        leer_enter
        return 1
    fi

    leer_enter
    return 0
}

opcion8() {
    echo -e "\n${VERDE}[ Ejecutando FASE 8 — Pruebas de carga: hey contra el ALB + monitoreo HPA/pods en vivo (~3 min) ]${NC}"

    configurar_region

    # --- Parámetros de la Fase 8 ---
    local NS_APP="sri-facturacion"
    local DEPLOY_NAME="sri-facturacion-service-deployment"
    local DURACION="120s"      # hey -z: duración fija de la prueba
    local CONEXIONES=50        # hey -c: workers concurrentes
    local INTERVALO=10         # segundos entre snapshots de monitoreo
    local MARGEN=40            # colchón de seguridad tras la duración nominal

    # --- Validaciones previas: herramientas (hey se verifica con command -v:
    #     no tiene flag -version ni binarios oficiales publicados) ---
    local cmd
    for cmd in aws kubectl hey curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            if [ "$cmd" = "hey" ]; then
                echo -e "${ROJO}Instálalo con: go install github.com/rakyll/hey@latest (o brew install hey).${NC}"
            fi
            leer_enter
            return 1
        fi
    done

    # --- [1/4] Precondición dura: el ALB debe estar ONLINE (lo enciende la Fase 7) ---
    echo -e "\n${AZUL}[1/5] Precondición: Ingress con ADDRESS (Fase 7 ON)${NC}"
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

    local alb_dns
    alb_dns=$(kubectl -n "$NS_APP" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -z "$alb_dns" ]; then
        echo -e "${ROJO}[ERROR]${NC} No hay Ingress con ADDRESS en '${NS_APP}': el ALB no está ONLINE."
        echo -e "${ROJO}Ejecuta primero la Fase 7 (opción 7): edita el overlay, confirma el diff y espera el ADDRESS.${NC}"
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} ALB ONLINE: http://${alb_dns}"

    # Sonda HTTP previa: el overlay aws-eks es catch-all (sin regla host), así que
    # el DNS pelado debe responder 200; si responde 404, la regla host volvió a
    # activarse y hey necesitaría -host <host>.
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${alb_dns}/health")
    echo "Sonda HTTP previa: GET /health -> ${http_code}"
    if [ "$http_code" != "200" ]; then
        echo -e "${ROJO}[ERROR]${NC} La sonda no devolvió 200 (¿regla host activa en el Ingress?)."
        echo -e "${ROJO}Con regla host, hey necesita: hey -host <host> -z ${DURACION} -c ${CONEXIONES} http://${alb_dns}/health${NC}"
        leer_enter
        return 1
    fi

    # Aviso suave si el deployment no parte de 3 pods (el HPA escala desde ahí)
    local pods_ready
    pods_ready=$(kubectl -n "$NS_APP" get deployment "$DEPLOY_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    pods_ready=${pods_ready:-0}
    if [ "$pods_ready" -lt 3 ]; then
        echo -e "${AMARILLO}[WARN]${NC} El deployment tiene ${pods_ready}/3 pods ready (esperado 3 tras la Fase 5)."
    fi

    # --- [2/4] hey en SEGUNDO PLANO con log propio (se muestra al final limpio):
    #     si imprimiera en pantalla, su salida se entrelazaría con el monitoreo ---
    echo -e "\n${AZUL}[2/5] Lanzando hey: hey -z ${DURACION} -c ${CONEXIONES} http://${alb_dns}/health${NC}"
    local hey_log
    hey_log=$(mktemp "${TMPDIR:-/tmp}/hey_fase8.XXXXXX.log")
    hey -z "$DURACION" -c "$CONEXIONES" "http://${alb_dns}/health" > "$hey_log" 2>&1 &
    local hey_pid=$!
    echo -e "hey ejecutándose en segundo plano (PID ${hey_pid}); log temporal: ${hey_log}"
    echo -e "${AMARILLO}Si cancelas con Ctrl+C, hey también muere (mismo grupo de procesos); el log queda en disco.${NC}"

    # Port-Forwarding de ArgoCD para facilitar el acceso a la interfaz gráfica
    echo -e "\n${AZUL}[3/5] Port-Forwarding de ArgoCD para facilitar el acceso a la interfaz gráfica${NC}"
    clave_argocd=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode)
    
    kubectl port-forward svc/argocd-server 8080:443 -n argocd &
    local argocd_pid=$!
    echo -e "Port-Forwarding de ArgoCD ejecutándose en segundo plano (PID ${argocd_pid})"
    echo -e "${AMARILLO}Si cancelas con Ctrl+C, el Port-Forwarding también muere (mismo grupo de procesos).${NC}"
    
    echo -e "${AMARILLO}Accede a la interfaz gráfica de ArgoCD con: http://localhost:8080${NC}"
    echo -e "Clave de ArgoCD: ${clave_argocd}" 


    # --- [3/4] Monitoreo acotado: snapshots de HPA + pods cada ${INTERVALO}s ---
    # En vez de 'kubectl get hpa -w' / 'get pods -w' (watch infinito que nunca
    # devuelve el menú): sondeo acotado a la duración de hey + margen.
    echo -e "\n${AZUL}[4/5] Monitoreo en vivo: HPA y pods cada ${INTERVALO}s (esperado: 3 -> 5 -> 7 pods)${NC}"
    echo -e "${AZUL}--- t=0s (estado base) ---${NC}"
    kubectl -n "$NS_APP" get hpa
    kubectl -n "$NS_APP" get pods

    local limite=$(( ${DURACION%s} + MARGEN ))
    local espera=0
    while [ "$espera" -lt "$limite" ]; do
        kill -0 "$hey_pid" 2>/dev/null || break
        sleep "$INTERVALO"
        espera=$((espera + INTERVALO))
        echo -e "\n${AZUL}--- t=${espera}s ---${NC}"
        kubectl -n "$NS_APP" get hpa
        kubectl -n "$NS_APP" get pods
    done

    # --- [4/4] Resultados de hey + evidencia target-type ip ---
    echo -e "\n${AZUL}[5/5] Resultados de la prueba de carga${NC}"
    local hey_rc=""
    if kill -0 "$hey_pid" 2>/dev/null; then
        echo -e "${AMARILLO}[WARN]${NC} hey sigue corriendo tras ${limite}s (PID ${hey_pid}); sus resultados quedaron en ${hey_log}"
    else
        wait "$hey_pid" 2>/dev/null
        hey_rc=$?
        echo -e "${VERDE}[OK]${NC} hey finalizó (exit=${hey_rc}). Resultados:"
        echo "----------------------------------------------------------------"
        cat "$hey_log"
        echo "----------------------------------------------------------------"
    fi

    kubectl -n "$NS_APP" get hpa
    kubectl -n "$NS_APP" get pods

    # Joya de la fase (target-type ip): los targets del ALB son IPs de PODS,
    # no de nodos — el grupo de destino se actualiza solo al escalar.
    local lb_arn
    lb_arn=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?DNSName=='${alb_dns}'].LoadBalancerArn | [0]" --output text)
    if [ -n "$lb_arn" ] && [ "$lb_arn" != "None" ]; then
        echo -e "\n${AZUL}Target group del ALB (target-type ip: las IPs son de pods)${NC}"
        local tg
        for tg in $(aws elbv2 describe-target-groups --region "$AWS_REGION" --load-balancer-arn "$lb_arn" --query "TargetGroups[].TargetGroupArn" --output text); do
            aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$tg" \
                --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State]" --output table
        done
    fi

    echo -e "\n${VERDE}Fase 8 completada: carga aplicada y monitoreada.${NC}"
    echo -e "${AMARILLO}El HPA tarda ~5 min SIN carga en reducir réplicas (stabilization window): es normal verlo alto un rato.${NC}"
    echo -e "${AMARILLO}Costo: la prueba en sí es minima, no crea recursos nuevos. El ALB sigue corriendo hasta la Fase 10 (opción 10).${NC}"

    leer_enter
    return 0
}

opcion9(){
    echo -e "\n${AZUL}[9/10] Fase 9 (bucle pipeline GitOps) ocurre en GitHub: PR + merge a main + Actions + bump + ArgoCD sync.${NC}"
    echo -e "${AMARILLO}Sigue DEMO_STACK_AWS_FINAL.md FASE 9.${NC}"
    leer_enter
    return 0
}

# ============================================================
# FUNCIONES AUXILIARES FASE 10
# ============================================================
# Destroy idempotente de un módulo Terraform: destruye solo si el state
# tiene recursos; tras el destroy verifica 'terraform state list' y
# reintenta acotado si quedó residuo. Si ya es 0, lo omite sin tocar nada.
destruir_modulo() {
    local dir="$1" nombre="$2"
    local intentos_max=3 intento=1 n

    n=$(terraform -chdir="$dir" state list 2>/dev/null | grep -c .)
    n=${n:-0}
    if [ "$n" -eq 0 ]; then
        echo -e "${AMARILLO}[${nombre}] state list = 0: ya destruido, se omite (idempotente).${NC}"
        return 0
    fi
    echo -e "${AZUL}[${nombre}] ${n} recurso(s) en state -> terraform destroy...${NC}"

    while [ "$intento" -le "$intentos_max" ]; do
        if terraform -chdir="$dir" destroy -auto-approve -input=false -lock-timeout=60s; then
            n=$(terraform -chdir="$dir" state list 2>/dev/null | grep -c .)
            n=${n:-0}
            if [ "$n" -eq 0 ]; then
                echo -e "${VERDE}[OK]${NC} [${nombre}] state list = 0: destrucción confirmada."
                return 0
            fi
            echo -e "${AMARILLO}[WARN]${NC} [${nombre}] destroy OK pero quedan ${n} recurso(s) en state; reintento $((intento + 1))/${intentos_max}..."
        else
            echo -e "${ROJO}[ERROR]${NC} [${nombre}] terraform destroy falló (intento ${intento}/${intentos_max})."
        fi
        intento=$((intento + 1))
        [ "$intento" -le "$intentos_max" ] && sleep 15
    done

    n=$(terraform -chdir="$dir" state list 2>/dev/null | grep -c .)
    n=${n:-0}
    if [ "$n" -eq 0 ]; then
        return 0
    fi
    echo -e "${ROJO}[ERROR]${NC} [${nombre}] quedaron ${n} recurso(s) tras ${intentos_max} intentos. Revísalo a mano antes de continuar."
    return 1
}

# Verificación final del cierre: los tres states deben estar vacíos, el
# clúster debe dar ResourceNotFound y no debe quedar ningún ALB (huérfano).
# Devuelve el número de hallazgos en rojo (0 = cierre limpio).
verificacion_final() {
    local cluster_name="$1" fallos=0 n

    echo -e "\n${AZUL}[verificación final] States, clúster y ALB${NC}"
    local dir
    for dir in "$REPO_ROOT/iac/aws/lb-controller" "$REPO_ROOT/iac/aws/secrets-csi" "$REPO_ROOT/iac/aws"; do
        n=$(terraform -chdir="$dir" state list 2>/dev/null | grep -c .)
        n=${n:-0}
        if [ "$n" -eq 0 ]; then
            echo -e "  ${VERDE}[OK]${NC} ${dir#$REPO_ROOT/}: state vacío (0 recursos)"
        else
            echo -e "  ${ROJO}[X]${NC} ${dir#$REPO_ROOT/}: ${n} recurso(s) aún en state"
            fallos=$((fallos + 1))
        fi
    done

    if aws eks describe-cluster --region "$AWS_REGION" --name "$cluster_name" >/dev/null 2>&1; then
        echo -e "  ${ROJO}[X]${NC} eks describe-cluster: el clúster SIGUE EXISTIENDO"
        fallos=$((fallos + 1))
    else
        echo -e "  ${VERDE}[OK]${NC} eks describe-cluster: ResourceNotFound (clúster eliminado)"
    fi

    n=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --output text 2>/dev/null | grep -c .)
    n=${n:-0}
    if [ "$n" -eq 0 ]; then
        echo -e "  ${VERDE}[OK]${NC} elbv2: 0 load balancers (sin ALB huérfanos)"
    else
        echo -e "  ${ROJO}[X]${NC} elbv2: quedan registros (${n} línea(s)) — revisa ALB huérfanos"
        fallos=$((fallos + 1))
    fi

    return "$fallos"
}

opcion10() {
    echo -e "\n${VERDE}[ Ejecutando FASE 10 — Cierre FinOps: Demo OFF + prune del ALB + destroys ordenados (~10 min) ]${NC}"

    configurar_region

    # --- Parámetros de la Fase 10 ---
    local OVERLAY_KUST="gitops/overlays/aws-eks/kustomization.yaml"
    local OVERLAY_ABS="$REPO_ROOT/gitops/overlays/aws-eks/kustomization.yaml"
    local OVERLAY_DIR="$REPO_ROOT/gitops/overlays/aws-eks"
    local APP_NAME="sri-facturacion-aws-eks"
    local NS_APP="sri-facturacion"
    local BRANCH_ESPERADA="main"
    local COMMIT_MSG="demo: FASE 10 OFF - Ingress ALB + hpa-patch comentados (cierre FinOps)"
    local TIMEOUT_PRUNE=240     # Esperado: prune + borrado del ALB (~2-3 min)

    # --- Validaciones previas: herramientas (esta fase commitea y destruye: entra git) ---
    local cmd
    for cmd in git aws kubectl terraform; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${ROJO}[ERROR]${NC} '$cmd' no está instalado o no está en el PATH."
            leer_enter
            return 1
        fi
    done

    # --- Preflight: el clúster debe estar VIVO (el prune y el destroy de
    #     lb-controller lo requieren). Si ya está muerto: modo solo verificación. ---
    echo -e "\n${AZUL}[preflight] kubeconfig + estado del clúster${NC}"
    # terraform se usa solo para leer el output 'cluster_name'; si no está
    # instalado, el fallback mantiene el nombre por defecto del proyecto.
    local cluster_name
    cluster_name=$(terraform -chdir="$REPO_ROOT/iac/aws" output -raw cluster_name 2>/dev/null)
    [ -z "$cluster_name" ] && cluster_name="sri-eks-cluster"

    local cluster_vivo=1
    if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name"; then
        cluster_vivo=0
    fi
    if [ "$cluster_vivo" -eq 1 ] && ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
        cluster_vivo=0
    fi

    if [ "$cluster_vivo" -eq 0 ]; then
        echo -e "${AMARILLO}[WARN]${NC} El clúster '${cluster_name}' no responde: asumiendo cierre ya realizado."
        echo -e "${AMARILLO}Pasando a la verificación final de estados (sin destroys).${NC}"
        verificacion_final "$cluster_name"
        local rc=$?
        leer_enter
        return $rc
    fi
    echo -e "Contexto actual: $(kubectl config current-context)"

    # --- [1/6] Overlay aws-eks: apagar Ingress + hpa-patch (commit/push, idempotente) ---
    echo -e "\n${AZUL}[1/6] Overlay aws-eks: apagar Ingress + hpa-patch${NC}"
    local render
    if ! render=$(kubectl kustomize "$OVERLAY_DIR" 2>&1); then
        echo -e "${ROJO}[ERROR]${NC} El overlay NO compila ni en su estado actual:"
        echo "$render" | tail -n 10
        echo -e "${ROJO}Corrige el YAML a mano antes del cierre. NO se destruyó nada.${NC}"
        leer_enter
        return 1
    fi

    local overlay_on=0
    if echo "$render" | grep -q "^kind: Ingress$" && echo "$render" | grep -q "averageUtilization: 5"; then
        overlay_on=1
    fi

    if [ "$overlay_on" -eq 1 ]; then
        echo "Overlay ON (Ingress + umbral 5% activos) -> comentando automáticamente..."
        # Convención del repo: comentar = prefijo '#' a columna 0 de cada línea
        # del bloque (sed de macOS/BSD; la puerta de render de abajo valida el resultado).
        sed -i '' -E 's|^[[:space:]]*- ingress\.yaml$|#- ingress.yaml|' "$OVERLAY_ABS"
        sed -i '' -E '/^[[:space:]]*- path: hpa-patch\.yaml$/,/^[[:space:]]*name: sri-facturacion-service-hpa$/ s|^|#|' "$OVERLAY_ABS"

        # Puerta de seguridad inversa: el render debe quedar OFF antes de commitear
        if ! render=$(kubectl kustomize "$OVERLAY_DIR" 2>&1); then
            echo -e "${ROJO}[ERROR]${NC} El comentado automático rompió el overlay:"
            echo "$render" | tail -n 10
            echo -e "${ROJO}NO se commiteó nada. Restaura con: git checkout -- ${OVERLAY_KUST}${NC}"
            leer_enter
            return 1
        fi
        if echo "$render" | grep -q "^kind: Ingress$" || echo "$render" | grep -q "averageUtilization: 5"; then
            echo -e "${ROJO}[ERROR]${NC} Tras comentar, el render SIGUE teniendo Ingress/umbral 5%."
            echo -e "${ROJO}NO se commiteó nada. Comenta a mano siguiendo la convención del archivo.${NC}"
            leer_enter
            return 1
        fi
        echo -e "${VERDE}[OK]${NC} Render OFF validado (sin Ingress; HPA vuelve a umbrales base 70/80)."
    else
        echo -e "${AMARILLO}Overlay ya está OFF (sin Ingress ni umbral 5%): nada que comentar.${NC}"
    fi

    # Publicar SOLO si el overlay tiene cambios sin commitear (auto-comentado o manual previo)
    if git -C "$REPO_ROOT" status --porcelain | grep -q "$OVERLAY_KUST"; then
        local rama
        rama=$(git -C "$REPO_ROOT" branch --show-current)
        if [ "$rama" != "$BRANCH_ESPERADA" ]; then
            echo -e "${ROJO}[ERROR]${NC} Hay cambios del overlay sin commitear pero estás en '${rama:-(detached)}', no en '${BRANCH_ESPERADA}'."
            echo -e "${ROJO}Cámbiate a main para que ArgoCD vea el OFF. NO se destruyó nada.${NC}"
            leer_enter
            return 1
        fi
        if ! git -C "$REPO_ROOT" add -- "$OVERLAY_KUST"; then
            echo -e "${ROJO}[ERROR]${NC} git add falló."
            leer_enter
            return 1
        fi
        if ! git -C "$REPO_ROOT" commit -m "$COMMIT_MSG"; then
            echo -e "${ROJO}[ERROR]${NC} git commit falló."
            leer_enter
            return 1
        fi
        git -C "$REPO_ROOT" log --oneline -1
        if ! git -C "$REPO_ROOT" push; then
            echo -e "${ROJO}[ERROR]${NC} git push falló. El OFF no llegó a origin: ArgoCD no prunea. Resuélvelo antes de continuar."
            leer_enter
            return 1
        fi
        echo -e "${VERDE}[OK]${NC} OFF publicado en origin/${BRANCH_ESPERADA}."
    elif [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
        echo -e "${AMARILLO}[WARN]${NC} Hay cambios sin commitear en OTROS archivos (no se publican aquí):"
        git -C "$REPO_ROOT" status --porcelain
    fi

    # --- [2/6] Refresh=hard de ArgoCD para que prunee YA ---
    echo -e "\n${AZUL}[2/6] Refresh=hard de ArgoCD${NC}"
    if kubectl get application "$APP_NAME" -n argocd >/dev/null 2>&1; then
        if ! kubectl -n argocd annotate application "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite; then
            echo -e "${ROJO}[ERROR]${NC} No se pudo anotar la Application (refresh=hard)."
            leer_enter
            return 1
        fi
        echo -e "${VERDE}[OK]${NC} refresh=hard anotado: ArgoCD prunea el Ingress en su próximo ciclo."
    else
        echo -e "${AMARILLO}[WARN]${NC} La Application '${APP_NAME}' no existe: se asume que no hay Ingress que prunear."
    fi

    # --- [3/6] GATE FinOps: el Ingress y el ALB deben morir ANTES que el clúster ---
    echo -e "\n${AZUL}[3/6] GATE FinOps: esperando prune del Ingress y borrado del ALB${NC}"
    local espera=0 ing_ok=0 alb_ok=0 ing_out n_alb
    while [ "$espera" -lt "$TIMEOUT_PRUNE" ]; do
        ing_out=$(kubectl -n "$NS_APP" get ingress 2>&1)
        echo "$ing_out" | grep -q "No resources found" && ing_ok=1
        n_alb=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --output text 2>/dev/null | grep -c .)
        n_alb=${n_alb:-0}
        [ "$n_alb" -eq 0 ] && alb_ok=1
        [ "$ing_ok" -eq 1 ] && [ "$alb_ok" -eq 1 ] && break
        sleep 10
        espera=$((espera + 10))
        echo -e "  Esperando prune... (ingress_borrado=${ing_ok}, lineas_elbv2=${n_alb}, ${espera}s)"
    done

    if [ "$ing_ok" -ne 1 ] || [ "$alb_ok" -ne 1 ]; then
        echo -e "\n${ROJO}[ERROR]${NC} GATE FinOps: tras ${TIMEOUT_PRUNE}s -> ingress_borrado=${ing_ok}, alb_vacio=${alb_ok}."
        echo -e "${ROJO}REGLA DE ORO: el Ingress/ALB debe morir ANTES que el clúster (si no, el ALB queda huérfano facturando).${NC}"
        echo -e "${ROJO}NO se ejecutó NINGÚN destroy. Diagnóstico:${NC}"
        echo -e "${ROJO}  kubectl -n argocd describe application ${APP_NAME} | tail -n 20${NC}"
        leer_enter
        return 1
    fi
    echo -e "${VERDE}[OK]${NC} Prune confirmado: sin Ingress en el cluster y 0 load balancers."

    # --- [4/6] Destroy lb-controller (SU state lee data sources del clúster: primero SIEMPRE) ---
    echo -e "\n${AZUL}[4/6] Destroy lb-controller (4 recursos: rol + policy + attachment + OIDC importado)${NC}"
    if ! destruir_modulo "$REPO_ROOT/iac/aws/lb-controller" "lb-controller"; then
        leer_enter
        return 1
    fi

    # --- [5/6] Destroy secrets-csi (tolera OIDC ya borrado por el paso anterior) ---
    echo -e "\n${AZUL}[5/6] Destroy secrets-csi (8 recursos: OIDC provider + rol + policy + attachment + SSM x3 + ...)${NC}"
    if ! destruir_modulo "$REPO_ROOT/iac/aws/secrets-csi" "secrets-csi"; then
        leer_enter
        return 1
    fi

    # --- [6/6] Destroy cluster principal iac/aws (~4 min: VPC, SG, roles, control plane, node group) ---
    echo -e "\n${AZUL}[6/6] Destroy cluster principal iac/aws (11 recursos)${NC}"
    if ! destruir_modulo "$REPO_ROOT/iac/aws" "iac/aws"; then
        leer_enter
        return 1
    fi

    verificacion_final "$cluster_name"
    local rc_final=$?

    if [ "$rc_final" -eq 0 ]; then
        echo -e "\n${VERDE}Fase 10 completada: cierre FinOps ordenado, sin huérfanos.${NC}"
        echo -e "${VERDE}Permanente (no tocado): usuario terraform-ci + políticas, ECR, OIDC GitHub, rol github-actions-ecr-push.${NC}"
        echo -e "${AMARILLO}Costo a partir de ahora: \$0/h. El repo queda en el punto de partida del guion (100% reproducible).${NC}"
    else
        echo -e "\n${AMARILLO}[WARN]${NC} Destroys ejecutados pero la verificación final reporta ${rc_final} hallazgo(s) en rojo (arriba)."
    fi

    leer_enter
    return $rc_final
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
    read -p "Selecciona una opción [0-10]: " opcion || break

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
        7)
            opcion7
            ;;
        8)
            opcion8
            ;;
        9)
            opcion9
            ;;
        10)
            opcion10
            ;;
        0)
            if confirmar_salida; then
                break
            fi
            ;;
        *)
            echo -e "\n${ROJO}[ERROR]${NC} Opción inválida. Por favor, elige un número entre 0 y 10."
            sleep 2
            ;;
    esac
done
