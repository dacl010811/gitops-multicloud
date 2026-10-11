#!/bin/bash

# ============================================================
# MENÚ INTERACTIVO - AZURE AKS
# Gemelo de menuAprovisionamientoAWS.sh para el stack Azure.
# Cada fase sigue el runbook DEMO_STACK_AZURE_FINAL.md (Fases 0-7):
# plataforma base -> clúster AKS "nace completo" -> ArgoCD -> secretos
# (Key Vault + CSI + Workload Identity) -> Ingress AGIC + App Gateway
# -> carga HPA -> cierre FinOps a $0/h.
# Mismo patrón que el menú AWS: bucles acotados, puertas de render
# kustomize, git add selectivo y verificación post-destroy.
# ============================================================

# Colores ANSI - tema CIAN/MAGENTA para distinguirlo del menú AWS (AZUL).
# VERDE/AMARILLO/ROJO conservan su semántica (OK / advertencia / error).
ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
CIAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # Sin color

# ============================================================
# CONFIGURACIÓN GLOBAL
# ============================================================
# Valores canónicos de la plataforma Azure (runbook DEMO_STACK_AZURE_FINAL.md).
# La región (eastus) y los nombres de los recursos viven en iac/azure;
# aquí solo lo que necesitan los comandos az/kubectl del menú.
AZ_TENANT="0fc1436e-05f9-416b-9d88-a108f4a1133b"
AZ_RG="sri-aks-rg"                       # RG efímero del clúster (muere con el destroy)
AZ_CLUSTER="sri-aks-cluster"
AZ_TFRG="sri-tfstate-rg"                 # RG permanente ("la casa de la plataforma")
AZ_SA_STATE="sritfstate23c5"             # Storage Account del backend remoto de state
AZ_ACR="sriacrtfm23c5"
AZ_KV="sri-keyvault-23c5"
AZ_MI="sri-facturacion-wi"
NS_APP="sri-facturacion"
APP_ARGO="sri-facturacion-azure-aks"     # Application de ArgoCD del overlay azure-aks
BRANCH="main"                            # Rama que ArgoCD vigila (targetRevision)
DURACION_HEY="90s"                       # Runbook FASE 5: hey -z 90s -c 30
CONEXIONES_HEY="30"

# Raíz del repo (este script vive en <repo>/scripts)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Overlay GitOps de Azure (se edita manualmente en las Fases 4/5 y se
# auto-comenta en la Fase 7 - el modo demo se enciende/apaga con commits)
OVERLAY_AZ="$REPO_ROOT/gitops/overlays/azure-aks"
OVERLAY_KUST="$OVERLAY_AZ/kustomization.yaml"

# ============================================================
# FUNCIÓN: Verificar la sesión de Azure activa
# ============================================================
verificar_sesion_azure() {
    echo -e "\n${CIAN}[ Sesión Azure activa ]${NC}"
    if ! az account show --query "{suscripcion:name, tenant:tenantId, usuario:user.name, tipo:user.type}" -o table 2>/dev/null; then
        echo -e "${ROJO}No hay sesión de Azure activa.${NC} Ejecuta primero:"
        echo "  az login --service-principal -u <APP_ID> -p <PASSWORD> --tenant ${AZ_TENANT}"
        return 1
    fi
    local tipo
    tipo=$(az account show --query "user.type" -o tsv 2>/dev/null)
    if [ "$tipo" = "servicePrincipal" ]; then
        echo -e "${VERDE}Identidad: SP (terraform-ci-azure) — la esperada para Terraform y verificaciones.${NC}"
    else
        echo -e "${AMARILLO}Identidad HUMANA: correcta para los bootstraps RBAC (AcrPull/Key Vault),${NC}"
        echo -e "${AMARILLO}pero terraform corre con el SP (ARM_* o login SP). Ajusta según la fase.${NC}"
    fi
}

# ============================================================
# FUNCIÓN: Conectar el kubeconfig al clúster AKS (idempotente)
# ============================================================
conectar_aks() {
    if ! az aks show -g "$AZ_RG" -n "$AZ_CLUSTER" --query name -o tsv >/dev/null 2>&1; then
        echo -e "${ROJO}El clúster ${AZ_CLUSTER} no existe en ${AZ_RG}.${NC}"
        return 1
    fi
    az aks get-credentials --resource-group "$AZ_RG" --name "$AZ_CLUSTER" --overwrite-existing
}

# ============================================================
# FUNCIÓN: Esperar a que los nodos del clúster estén Ready
# ============================================================
esperar_nodos() {
    local esperados="${1:-3}" intentos=0 max=60
    while [ "$intentos" -lt "$max" ]; do
        local listos
        listos=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
        if [ "${listos:-0}" -ge "$esperados" ]; then
            echo -e "${VERDE}Nodos Ready: ${listos}/${esperados}${NC}"
            kubectl get nodes
            return 0
        fi
        intentos=$((intentos+1))
        [ $((intentos % 6)) -eq 0 ] && echo "  ... esperando nodos (${listos:-0}/${esperados}, $((intentos*10))s)"
        sleep 10
    done
    echo -e "${ROJO}Timeout esperando nodos (${max}x10s). Revisa: kubectl get nodes${NC}"
    return 1
}

# ============================================================
# FUNCIÓN: Esperar a que la Application de ArgoCD esté Synced/Healthy
# ============================================================
esperar_application() {
    local app="$1" intentos=0 max=30 estado
    while [ "$intentos" -lt "$max" ]; do
        estado=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
        echo "  estado: ${estado:-<creando>} (intento $((intentos+1))/$max)"
        if [ "$estado" = "Synced/Healthy" ]; then
            return 0
        fi
        intentos=$((intentos+1))
        sleep 10
    done
    return 1
}

# ============================================================
# FUNCIÓN: Pausa para lectura del usuario
# ============================================================
leer_enter() {
    read -r -p "Presiona Enter para continuar..."
}

# ============================================================
# FUNCIÓN: Confirmar la salida del menú
# ============================================================
confirmar_salida() {
    local respuesta
    read -p "¿Seguro que deseas salir? (s/n): " respuesta
    case "$respuesta" in
        [sS]|[sS][iI]) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# FUNCIÓN: Mostrar el menú
# ============================================================
mostrar_menu() {
    clear
    echo -e "${CIAN}========================================================================================================================${NC}"
    echo -e "${CIAN}                                              MENÚ DE AUTOMATIZACIÓN                                                    ${NC}"
    echo -e "${MAGENTA} Menu de Opciones : AZURE AKS - GitOps Multicloud.                                                                    ${NC}"
    echo -e "${MAGENTA} Directorio Trabajo : ./${REPO_ROOT##*/}                                                                            ${NC}"
    echo -e "${CIAN}========================================================================================================================${NC}"
    echo -e " ${VERDE}1.${NC} Fase 0 - [ Verificar - Plataforma base GO/NO-GO (SP, backend, ACR, KV+MI, secretos, imagen, state) --> \$0 ]"
    echo -e " ${VERDE}2.${NC} Fase 1 - [ Aprovisionar Cluster AKS 'nace completo' (RG, WI, CSI, AGIC + AppGW, fedcred) --> 3 Resources + AcrPull ]"
    echo -e " ${VERDE}3.${NC} Fase 2 - [ Aprovisionar - ArgoCD + Application azure-aks (metrics-server de fábrica en AKS) ]"
    echo -e " ${VERDE}4.${NC} Fase 3 - [ Verificar - Demo de la cadena Key Vault -> CSI -> Secret -> env ]"
    echo -e " ${VERDE}5.${NC} Fase 4 - [ Aprovisionar - Demo ON: commit/push Ingress AGIC + App Gateway y espera la IP ]"
    echo -e " ${VERDE}6.${NC} Fase 5 - [ Carga - Pruebas hey sobre App Gateway + HPA 5% + monitoreo en vivo ]"
    echo -e " ${VERDE}7.${NC} Fase 6 - [ Pendiente - bucle pipeline GitOps (ocurre en GitHub: push + Actions + ArgoCD) ]"
    echo -e " ${VERDE}8.${NC} Fase 7 - [ Cierre - Demo OFF ritual + checkpoint + destroy único (iac/azure) -> \$0/h ]"
    echo -e " ${AMARILLO}0.${NC} Salir"
    echo -e "${CIAN}========================================================================================================================${NC}"
}

# Funciones del menu principal

# ============================================================
# FASE 0 - Verificación de la plataforma base (GO / NO-GO)
# Todo son LECTURAS: $0, sin crear nada. La plataforma (SP, backend,
# ACR, OIDC GitHub, KV+MI+secretos) se aprovisiona UNA vez y sobrevive
# a todos los ciclos destroy/apply del clúster (runbook §0.9-0.10).
# ============================================================
opcion1() {
    echo -e "\n${CIAN}[ Ejecutando FASE 0 - Verificación plataforma base (GO/NO-GO) ]${NC}"
    echo -e "${MAGENTA}Todas las comprobaciones son de solo lectura: costo \$0.${NC}"

    # ---- 0.1 Tooling del equipo ----
    echo -e "\n${CIAN}[0/8] Tooling del equipo${NC}"
    local herramientas="az terraform kubectl git jq"
    local faltantes=0
    for t in $herramientas; do
        if command -v "$t" >/dev/null 2>&1; then
            echo -e "  ${VERDE}OK${NC}  $t"
        else
            echo -e "  ${ROJO}FALTA${NC}  $t"
            faltantes=$((faltantes+1))
        fi
    done
    if ! command -v hey >/dev/null 2>&1; then
        echo -e "  ${AMARILLO}AVISO${NC} hey no instalado (se necesita en la Fase 5): brew install hey"
    fi
    if [ "$faltantes" -gt 0 ]; then
        echo -e "${ROJO}Faltan herramientas críticas ($faltantes). Instálalas antes de continuar.${NC}"
        leer_enter; return 1
    fi

    # Provider del Key Vault (idempotente, $0): no viene registrado por defecto
    echo -e "\n${CIAN}[Provider] Registrando Microsoft.KeyVault (idempotente, \$0)...${NC}"
    az provider register --namespace Microsoft.KeyVault >/dev/null 2>&1 || true
    local prov_state
    prov_state=$(az provider show --namespace "Microsoft.KeyVault" --query registrationState -o tsv 2>/dev/null || true)
    echo "  Microsoft.KeyVault: ${prov_state:-<sin datos>} (Registered = listo)"

    # ---- Identidad activa ----
    verificar_sesion_azure || { leer_enter; return 1; }

    local fallos=0 avisos=0

    # ---- 0.3 Backend remoto de estado ----
    echo -e "\n${CIAN}[1/8] Backend de state (${AZ_TFRG} / ${AZ_SA_STATE})${NC}"
    if az group show -n "$AZ_TFRG" --query name -o tsv >/dev/null 2>&1 \
       && az storage account show -n "$AZ_SA_STATE" -g "$AZ_TFRG" --query name -o tsv >/dev/null 2>&1; then
        echo -e "  ${VERDE}OK${NC}  backend presente: RG + Storage Account + container tfstate"
    else
        echo -e "  ${ROJO}FALTA${NC}  backend -> bash scripts/bootstrap-backend-azure.sh"
        fallos=$((fallos+1))
    fi

    # ---- 0.4 Registry ACR ----
    echo -e "\n${CIAN}[2/8] Registry ACR (${AZ_ACR})${NC}"
    if az acr show -n "$AZ_ACR" --query "loginServer" -o tsv >/dev/null 2>&1; then
        local login_server
        login_server=$(az acr show -n "$AZ_ACR" --query loginServer -o tsv 2>/dev/null)
        echo -e "  ${VERDE}OK${NC}  ACR vivo: ${login_server}"
    else
        echo -e "  ${ROJO}FALTA${NC}  ACR -> cd iac/azure/registry && terraform apply"
        fallos=$((fallos+1))
    fi

    # ---- 0.6 Key Vault + Managed Identity (PERMANENTES) ----
    echo -e "\n${CIAN}[3/8] Key Vault + Managed Identity (permanentes)${NC}"
    if az keyvault show -n "$AZ_KV" --query name -o tsv >/dev/null 2>&1; then
        local rbac
        rbac=$(az keyvault show -n "$AZ_KV" --query properties.enableRbacAuthorization -o tsv 2>/dev/null)
        echo -e "  ${VERDE}OK${NC}  Key Vault ${AZ_KV} (rbac=${rbac})"
    else
        echo -e "  ${ROJO}FALTA${NC}  KV -> cd iac/azure/key-vault && terraform apply"
        fallos=$((fallos+1))
    fi
    local mi_client
    mi_client=$(az identity show -g "$AZ_TFRG" -n "$AZ_MI" --query clientId -o tsv 2>/dev/null || true)
    if [ -n "$mi_client" ]; then
        echo -e "  ${VERDE}OK${NC}  MI ${AZ_MI}: ${mi_client}"
    else
        echo -e "  ${ROJO}FALTA${NC}  MI -> cd iac/azure/key-vault && terraform apply"
        fallos=$((fallos+1))
    fi

    # ---- 0.7 Siembra de los 3 secretos (nombres, jamás valores) ----
    echo -e "\n${CIAN}[4/8] Siembra de secretos en el KV (solo nombres)${NC}"
    local n_secretos tipo_id nombre_id
    n_secretos=$(az keyvault secret list --vault-name "$AZ_KV" --query "length(@)" -o tsv 2>/dev/null || echo "?")
    if [ "$n_secretos" = "3" ]; then
        az keyvault secret list --vault-name "$AZ_KV" --query "[].name" -o table 2>/dev/null
        echo -e "  ${VERDE}OK${NC}  3 secretos sembrados"
    elif [ "$n_secretos" = "?" ]; then
        # No verificable con la identidad actual. Típico del SP terraform-ci-azure:
        # Contributor sin rol data-plane en el KV (least privilege por diseño);
        # NO implica que los secretos falten. Se continúa al paso 5/8.
        tipo_id=$(az account show --query "user.type" -o tsv 2>/dev/null || echo "?")
        nombre_id=$(az account show --query "user.name" -o tsv 2>/dev/null || echo "?")
        echo -e "  ${AMARILLO}AVISO${NC}  no verificable con esta identidad: ${nombre_id} (type=${tipo_id}) sin permiso de listado en el KV"
        echo "    Validación real con identidad HUMANA (rol Key Vault Secrets Officer):"
        echo -e "      ${AMARILLO}az logout && az login${NC}                                                    # humano"
        echo -e "      ${AMARILLO}az keyvault secret list --vault-name ${AZ_KV} --query '[].name' -o table  # esperado: db-host, db-password, db-username"${NC}
        echo -e "      ${AMARILLO}az logout && az login --service-principal -u \$ARM_CLIENT_ID -p \$ARM_CLIENT_SECRET --tenant \$ARM_TENANT_ID   # reconectar el SP"${NC}
        avisos=$((avisos+1))
    else
        echo -e "  ${ROJO}FALTA${NC}  secretos encontrados: ${n_secretos} -> bash scripts/bootstrap-keyvault-rbac-azure.sh como HUMANO"
        fallos=$((fallos+1))
    fi

    # ---- 0.8 Imagen en el ACR (advertencia: sin ella la Fase 2 cae en ImagePullBackOff) ----
    echo -e "\n${CIAN}[5/8] Imagen del microservicio en el ACR${NC}"
    if az acr repository show-tags -n "$AZ_ACR" --repository sri-facturacion-service --orderby time_desc -o table >/dev/null 2>&1; then
        local n_tags
        n_tags=$(az acr repository show-tags -n "$AZ_ACR" --repository sri-facturacion-service --query "length(@)" -o tsv 2>/dev/null || echo 0)
        if [ "${n_tags:-0}" -gt 0 ]; then
            echo -e "  ${VERDE}OK${NC}  ${n_tags} tag(s) en sri-facturacion-service (incluye el :<sha> del overlay y latest)"
        else
            echo -e "  ${AMARILLO}AVISO${NC} ACR sin tags: la Fase 2 terminará en ImagePullBackOff"
            avisos=$((avisos+1))
        fi
    else
        echo -e "  ${AMARILLO}AVISO${NC}  repositorio sri-facturacion-service no existe todavian (pipeline o az acr build)"
        avisos=$((avisos+1))
    fi

    # ---- Partida limpia: clúster ausente ----
    echo -e "\n${CIAN}[6/8] Clúster ausente (partida limpia)${NC}"
    local aks_vivos
    aks_vivos=$(az aks list --query "length(@)" -o tsv 2>/dev/null || echo "?")
    if [ "$aks_vivos" = "0" ]; then
        echo -e "  ${VERDE}OK${NC}  no hay clústeres: el reloj de facturación NO corre (\$0/h)"
    else
        echo -e "  ${AMARILLO}AVISO${NC}  ya existe(n) ${aks_vivos} clúster(es) -> el reloj YA corre. La Fase 1 hará apply sobre ellos."
        avisos=$((avisos+1))
    fi

    # ---- Checkpoint de state (lección CloudShell 2026-10-02: reconciliar antes de planear) ----
    echo -e "\n${CIAN}[7/8] Checkpoint del state de iac/azure (tras destroys vía CloudShell)${NC}"
    if ! az storage account show -n "$AZ_SA_STATE" -g "$AZ_TFRG" >/dev/null 2>&1; then
        echo -e "  ${AMARILLO}SALTO${NC}  sin backend no se puede leer el state (revisa [1/8])"
        avisos=$((avisos+1))
    elif ! terraform -chdir="$REPO_ROOT/iac/azure" init -input=false >/dev/null 2>&1; then
        echo -e "  ${AMARILLO}AVISO${NC}  terraform init falló (¿sesión con permisos sobre el backend?)"
        avisos=$((avisos+1))
    else
        local n_state
        n_state=$(terraform -chdir="$REPO_ROOT/iac/azure" state list 2>/dev/null | grep -c . || true)
        if [ "${n_state:-0}" -eq 0 ]; then
            echo -e "  ${VERDE}OK${NC}  state vacío (el plan de la Fase 1 mostrará '3 to add')"
        else
            echo -e "  ${AMARILLO}AVISO${NC}  state con ${n_state} recurso(s) (¿destroy previo sin reconciliar?)"
            terraform -chdir="$REPO_ROOT/iac/azure" state list 2>/dev/null | sed 's/^/    /'
            echo -e "  -> Reconcilia con 'terraform state rm <recurso>' hasta que el plan muestre solo adds (runbook §0.9). ${ROJO}No avanzar con state sucio.${NC}"
            avisos=$((avisos+1))
        fi
    fi

    # ---- 0.9 Veredicto GO / NO-GO ----
    echo ""
    echo -e "${CIAN}================================================================${NC}"
    echo -e "  Fallos críticos: ${ROJO}${fallos}${NC} · Advertencias: ${AMARILLO}${avisos}${NC}"
    if [ "$fallos" -gt 0 ]; then
        echo -e "${ROJO}NO-GO: la plataforma base está incompleta.${NC} Crea lo que falta  y repite esta fase."
    elif [ "$avisos" -gt 0 ]; then
        echo -e "${AMARILLO}GO con advertencias:${NC} revisa los avisos de arriba antes de la Fase 1."
    else
        echo -e "${VERDE}GO: plataforma base verificada. De aquí en más el reloj sigue detenido hasta la Fase 1.${NC}"
    fi
    echo -e "${CIAN}================================================================${NC}"
    leer_enter
}

# ============================================================
# FASE 1 - Clúster AKS "nace completo" (~6 min · arranca la facturación)
# Un solo apply materializa: RG + AKS con Workload Identity + add-on CSI
# de secretos + AGIC greenfield (que crea el AppGW v2 en el node RG MC_*)
# + la federated credential SA->MI. Asimetría con AWS: aquí NO hay fase
# de controller separada - el plano de identidad y el balanceador nacen
# CON el clúster.
# COSTO ANTES DE APLICAR: desde el apply corren clúster (~$0.15-0.20/h,
# 3x Standard_D2s_v3) Y el AppGW v2 (~$0.02-0.05/h). Total ~$0.17-0.25/h.
# ============================================================
opcion2() {
    echo -e "\n${CIAN}[ Ejecutando FASE 1 - Clúster AKS 'nace completo' ]${NC}"
    echo -e "${MAGENTA}Requiere: SP (§0.2) + backend (§0.3) + Key Vault/MI (§0.6) vivos (verifícalos en la Fase 0).${NC}"
    echo -e "${AMARILLO}COSTO: desde el apply corre el reloj (~\$0.17-0.25/h clúster + AppGW). Viven y mueren juntos.${NC}"
    read -p "¿Continuar con el apply? (s/n): " r
    case "$r" in
        [sS]|[sS][iI]) ;;
        *) echo "Fase cancelada. El reloj sigue detenido."; leer_enter; return 0 ;;
    esac

    # ---- Precondiciones ----
    verificar_sesion_azure || { leer_enter; return 1; }
    if ! az keyvault show -n "$AZ_KV" >/dev/null 2>&1 || [ -z "$(az identity show -g "$AZ_TFRG" -n "$AZ_MI" --query clientId -o tsv 2>/dev/null)" ]; then
        echo -e "${ROJO}Key Vault o Managed Identity ausentes: el apply referencia la MI por data source.${NC}"
        echo "Crea la plataforma primero (Fase 0 / runbook §0.6)."
        leer_enter; return 1
    fi

    # ---- Apply con reintentos (incidente real: IngressAppGwAddonConfigInvalidSubnetCIDR) ----
    # Con CNI Overlay el add-on AGIC exige prefijo >= /24; el módulo ya trae
    # subnet_cidr = "10.225.0.0/24". Si un apply falla a mitad (creó el RG),
    # el retry limpio suma "2 added" (RG ya en state) - eso es NORMAL.
    # Salida en vivo vía tee (UX: el usuario VE el progreso) y log completo
    # para el grep. tee sobrescribe el log en cada intento - eso es deseado.
    local log_apply="${TMPDIR:-/tmp}/tf_apply_azure_fase1.log"
    local aplico=0 intento
    for intento in 1 2 3; do
        echo -e "\n${CIAN}[Apply ${intento}/3] terraform init + apply en iac/azure${NC}"
        terraform -chdir="$REPO_ROOT/iac/azure" init -input=false || { echo -e "${ROJO}init falló (¿backend de §0.3 vivo?).${NC}"; break; }
        echo -e "${AMARILLO}Apply en curso: progreso en vivo abajo (log completo: ${log_apply})...${NC}"
        terraform -chdir="$REPO_ROOT/iac/azure" apply -auto-approve -input=false -lock-timeout=60s 2>&1 | tee "$log_apply"
        local rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ] && grep -q "Apply complete!" "$log_apply"; then
            local added
            added=$(grep -oE "[0-9]+ added" "$log_apply" | head -1)
            echo -e "${VERDE}Apply OK: ${added:-recursos creados}.${NC}"
            aplico=1
            break
        fi
        echo -e "${AMARILLO}Falló el apply (posible incidente conocido - Apéndice A). Reintento limpio...${NC}"
        sleep 15
    done
    if [ "$aplico" -ne 1 ]; then
        echo -e "${ROJO}Apply no completado tras 3 intentos. Revisa el log: ${log_apply}${NC}"
        leer_enter; return 1
    fi

    # ---- Credenciales + nodos ----
    echo -e "\n${CIAN}[1/4] Conectando kubeconfig y esperando 3 nodos Ready...${NC}"
    conectar_aks || { leer_enter; return 1; }
    esperar_nodos 3 || { leer_enter; return 1; }

    # ---- 1.2 Verificación del nacimiento completo ----
    echo -e "\n${CIAN}[2/4] Verificación del nacimiento (driver + provider + AGIC + AppGW + OIDC)${NC}"

    echo "-- Driver CSI de secretos (esperado 3/3):"
    kubectl -n kube-system get pods -l app=secrets-store-csi-driver 2>/dev/null | sed 's/^/   /'

    echo "-- Provider Azure (add-on key_vault_secrets_provider):"
    # ⚠️ El DaemonSet real es 'aks-secrets-store-provider-azure' (SIN 'csi' en
    # medio; el driver sí lo lleva). Grep 'csi-secrets-store-provider-azure'
    # devuelve vacío y NO es fallo (lección D8, incidente 2026-10-08).
    kubectl -n kube-system get pods 2>/dev/null | grep -i provider-azure | sed 's/^/   /'

    echo "-- AGIC (add-on ingress_application_gateway):"
    kubectl -n kube-system get pods 2>/dev/null | grep -i ingress-appgw | sed 's/^/   /'

    echo "-- Application Gateway v2 (greenfield: nació con el clúster, vive en MC_*):"
    az network application-gateway list --query "[].{name:name,rg:resourceGroup,sku:sku.name,capacity:sku.capacity}" -o table 2>/dev/null | sed 's/^/   /'

    echo "-- Issuer OIDC del clúster (el UUID CAMBIA en cada recreate):"
    local issuer
    issuer=$(az aks show -g "$AZ_RG" -n "$AZ_CLUSTER" --query oidcIssuerProfile.issuerUrl -o tsv 2>/dev/null || true)
    echo "   ${issuer:-<sin datos>}"

    echo "-- Cross-check de la federación (issuer idéntico al del clúster):"
    az identity federated-credential show --name sri-facturacion-sa \
        --identity-name "$AZ_MI" -g "$AZ_TFRG" \
        --query "{issuer:issuer, subject:subject}" -o table 2>/dev/null | sed 's/^/   /'

    # ---- 1.3 AcrPull de la kubelet identity (CADA recreate — incidente real ×2) ----
    # El pull de las imágenes lo hace la kubelet identity del NODO (no el
    # kubectl humano, no el SP). Esa identity es EFÍMERA: nace con el clúster
    # sin AcrPull y hay que asignárselo CADA recreate, siempre como HUMANO
    # (el script aborta si la sesión es un SP - Contributor no puede crear
    # role assignments: "el humano gobierna una vez; las máquinas operan siempre").
    echo -e "\n${CIAN}[3/4] AcrPull para la kubelet identity (obligatorio en cada recreate)${NC}"
    echo "-- kubelet identity (efímera, nueva en este clúster):"
    az aks show -g "$AZ_RG" -n "$AZ_CLUSTER" --query identityProfile.kubeletidentity.clientId -o tsv 2>/dev/null | sed 's/^/   /'
    local tipo_sesion
    tipo_sesion=$(az account show --query "user.type" -o tsv 2>/dev/null)
    if [ "$tipo_sesion" = "user" ]; then
        read -p "Sesión HUMANA: ¿ejecutar scripts/bootstrap-acr-rbac-azure.sh ahora? (s/n): " r
        case "$r" in
            [sS]|[sS][iI])
                bash "$REPO_ROOT/scripts/bootstrap-acr-rbac-azure.sh" \
                    && echo -e "${VERDE}AcrPull asignado.${NC}" \
                    || echo -e "${ROJO}El script falló.${NC}"
                ;;
            *)
                echo -e "${AMARILLO}OMITIDO: sin AcrPull la Fase 2 cae en ImagePullBackOff (401 anonymous) - incidente real 2026-10-01 y 2026-10-08.${NC}"
                ;;
        esac
    else
        echo -e "${AMARILLO}La sesión es un SP: el script tiene guard y abortaría.${NC}"
        echo "Ejecuta en OTRA terminal con identidad humana:"
        echo -e "  ${MAGENTA}az login && bash scripts/bootstrap-acr-rbac-azure.sh${NC}"
        echo "(idempotente: AcrPush -> SP del pipeline + AcrPull -> kubelet identity ACTUAL; costo \$0)"
        leer_enter
    fi

    # ---- Cierre de fase ----
    echo -e "\n${CIAN}[4/4] Estado de la fase${NC}"
    echo -e "${AMARILLO}Reloj corriendo: ~\$0.17-0.25/h (clúster + AppGW). El AppGW ya factura aunque el Ingress llegue en la Fase 4.${NC}"
    echo -e "${VERDE}Próximo paso: Fase 2 (ArgoCD + Application).${NC}"
    leer_enter
}

# ============================================================
# FASE 2 - ArgoCD + Application del overlay azure-aks (~8 min)
# ArgoCD se instala con --server-side (obligatorio: el CRD applicationsets
# supera los 256KB del last-applied - lección D9). Asimetría a favor de
# Azure: el metrics-server viene incluido con AKS, el HPA tendrá métricas
# reales desde el minuto uno (no hubo que instalarlo como en EKS).
# La app nace con el volumen CSI montado (los pods pasan unos segundos en
# ContainerCreating mientras el driver lee el Key Vault - es correcto).
# ============================================================
opcion3() {
    echo -e "\n${CIAN}[ Ejecutando FASE 2 - ArgoCD + Application azure-aks ]${NC}"
    echo -e "${MAGENTA}Requiere: Fase 1 completa (clúster + AcrPull de la kubelet identity).${NC}"

    conectar_aks || { leer_enter; return 1; }

    local project_file="$REPO_ROOT/gitops/argocd/project.yaml"
    local app_file="$REPO_ROOT/gitops/argocd/application-azure-aks.yaml"
    for f in "$project_file" "$app_file"; do
        if [ ! -f "$f" ]; then
            echo -e "${ROJO}No existe el manifiesto: ${f}${NC}"
            leer_enter; return 1
        fi
    done

    # ---- [1/4] Instalación de ArgoCD (idempotente) ----
    echo -e "\n${CIAN}[1/4] Instalando ArgoCD (--server-side)...${NC}"
    kubectl create namespace argocd 2>/dev/null || echo "  (namespace argocd ya existe)"
    kubectl apply --server-side --force-conflicts -n argocd \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    echo "  Esperando los 7 pods de ArgoCD (timeout 300s)..."
    if ! kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s; then
        echo -e "${ROJO}ArgoCD no llegó a Ready en 300s.${NC} Revisa: kubectl -n argocd get pods"
        leer_enter; return 1
    fi
    echo -e "${VERDE}ArgoCD: 7 pods Running.${NC}"

    # ---- [2/4] AppProject + Application ----
    echo -e "\n${CIAN}[2/4] Aplicando AppProject y Application (${APP_ARGO})...${NC}"
    kubectl apply -n argocd -f "$project_file"
    kubectl apply -n argocd -f "$app_file"

    # ---- [3/4] Espera Synced/Healthy ----
    echo -e "\n${CIAN}[3/4] Esperando Synced/Healthy de la Application (sync inicial ~2-3 min)...${NC}"
    if ! esperar_application "$APP_ARGO"; then
        echo -e "${ROJO}La Application no llegó a Synced/Healthy en 300s.${NC}"
        echo -e "${AMARILLO}Causa típica (incidente real ×2): AcrPull de la kubelet identity no re-asignado -> ImagePullBackOff con 401 anonymous.${NC}"
        echo "Diagnóstico:"
        echo "  kubectl -n ${NS_APP} get pods"
        echo "  kubectl -n argocd describe application ${APP_ARGO} | tail -20"
        echo -e "Fix: identidad HUMANA -> ${MAGENTA}bash scripts/bootstrap-acr-rbac-azure.sh${NC} + sleep 120 + kubectl -n ${NS_APP} delete pod --all"
        leer_enter; return 1
    fi
    kubectl -n argocd get applications
    echo -e "${VERDE}Application ${APP_ARGO}: Synced/Healthy.${NC}"

    # ---- [4/4] Verificación de la carga ----
    echo -e "\n${CIAN}[4/4] Verificación de la carga desplegada${NC}"
    echo "-- Pods (esperado 3/3 Running; nacieron con el secreto del Key Vault dentro):"
    kubectl -n "$NS_APP" get pods
    echo "-- HPA (métricas REALES desde el minuto uno: el metrics-server viene incluido en AKS):"
    kubectl -n "$NS_APP" get hpa
    echo -e "${VERDE}Próximo paso: Fase 3 (demo de la cadena de secretos).${NC}"
    leer_enter
}

# ============================================================
# FASE 3 - DEMO: secretos (objetivo #4 del TFM)
# La evidencia física de la cadena completa:
# Key Vault -> CSI add-on -> Workload Identity -> Secret nativo -> env
# Solo lecturas: jamás se muestran valores del vault (solo nombres).
# ============================================================
opcion4() {
    echo -e "\n${CIAN}[ Ejecutando FASE 3 - Demo de la cadena de secretos ]${NC}"
    conectar_aks || { leer_enter; return 1; }

    echo -e "\n${CIAN}[1/5] El montaje directo (los secretos del KV como archivos en el pod):${NC}"
    kubectl -n "$NS_APP" exec deploy/sri-facturacion-service-deployment -- ls -l /mnt/secrets-store/ 2>/dev/null \
        || echo -e "${ROJO}No se pudo ejecutar en el pod (¿la app está Running? Fase 2 completa).${NC}"

    echo -e "\n${CIAN}[2/5] El Secret nativo que sincronizó secretObjects (alimenta el envFrom):${NC}"
    kubectl -n "$NS_APP" get secret sri-facturacion-db 2>/dev/null \
        || echo -e "${ROJO}Secret sri-facturacion-db no encontrado.${NC}"

    echo -e "\n${CIAN}[3/5] La cadena hasta el proceso (para la demo SIN mostrar el password):${NC}"
    kubectl -n "$NS_APP" exec deploy/sri-facturacion-service-deployment -- env 2>/dev/null | grep -E 'DB_(USER|HOST)' \
        || echo -e "${AMARILLO}Sin DB_* visibles (¿el mount falló? describe pod para el evento exacto - pregunta P22).${NC}"

    echo -e "\n${CIAN}[4/5] La fuente de verdad (Key Vault - SOLO nombres, jamás valores):${NC}"
    az keyvault secret list --vault-name "$AZ_KV" --query "[].name" -o table 2>/dev/null \
        || echo -e "${ROJO}No se pudo listar el KV (¿sesión con rol adecuado?).${NC}"
    echo -e "${MAGENTA}Dato de oro para el jurado: el SP terraform-ci-azure NO puede leer estos secretos${NC}"
    echo -e "${MAGENTA}(Contributor sin rol data-plane); el único camino al texto claro es la identidad del pod (MI federada).${NC}"
    echo -e "${MAGENTA}Bonus sobre AWS: aquí ni el state de Terraform contiene el secreto (siembra vía bootstrap).${NC}"

    echo -e "\n${CIAN}[5/5] La app respondiendo (por port-forward, antes del Ingress):${NC}"
    echo "  kubectl -n ${NS_APP} port-forward svc/sri-facturacion-service-svc 5000:5000"
    echo "  curl -s localhost:5000/api/v1/version; echo"
    echo -e "${MAGENTA}Screenshot para el TFM: árbol de la Application en la UI de ArgoCD (port-forward 127.0.0.1:8082)${NC}"
    echo -e "${MAGENTA}- se ve el Secret sri-facturacion-db como relación del árbol, junto al Deployment y el HPA.${NC}"
    leer_enter
}

# ============================================================
# FASE 4 - DEMO ON: Ingress + Application Gateway (catch-all)
# Igual que en el menú AWS, el MODO DEMO se enciende con un commit: el
# usuario descomenta '- ingress.yaml' en el overlay (edición manual,
# didáctica - afianza el concepto GitOps) y esta opción valida, commitea
# y empuja. AGIC configura el AppGW (que ya facturaba desde la Fase 1):
# listeners + backend pools. Costo de la fase: $0 incremental.
# La regla activa NO declara host (catch-all): el listener básico del
# AppGW responde a la IP pelada, sin DNS ni /etc/hosts.
# ============================================================
opcion5() {
    echo -e "\n${CIAN}[ Ejecutando FASE 4 - Demo ON: Ingress AGIC + App Gateway ]${NC}"

    # ---- [1/5] Precondiciones Git ----
    echo -e "\n${CIAN}[1/5] Precondiciones Git${NC}"
    local rama
    rama=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [ "$rama" != "$BRANCH" ]; then
        echo -e "${ROJO}Estás en la rama ${rama} y ArgoCD vigila ${BRANCH}: el commit sería invisible (targetRevision).${NC}"
        echo "Cámbiate primero: git checkout ${BRANCH}"
        leer_enter; return 1
    fi
    
    echo -e "Rama: ${VERDE}${rama}${NC} (la que ArgoCD vigila)"
    
    if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$OVERLAY_AZ" 2>/dev/null)" ]; then
        echo -e "${ROJO}No hay cambios sin commitear en rama actual: ${rama}.${NC}"
        echo -e "${AMARILLO}Edita manualmente ${OVERLAY_KUST}: \ndescomenta '- ingress.yaml' (línea 21) y guarda.${NC}"
        leer_enter; return 1
    fi

    # ---- [2/5] Diff + confirmación del usuario ----
    echo -e "\n${CIAN}[2/5] Cambios pendientes del overlay:${NC}"
    git -C "$REPO_ROOT" --no-pager diff -- "$OVERLAY_KUST"
    local respuesta intentos=0
    while [ "$intentos" -lt 5 ]; do
        read -p "Revise los cambios del Ingress antes de continuar (s/n): " respuesta
        case "$respuesta" in
            [sS]|[sS][iI]) break ;;
            [nN]|[nN][oO]) echo "Fase cancelada. Corrige el overlay y vuelve a intentar."; leer_enter; return 0 ;;
            *) intentos=$((intentos+1)); echo "Entrada inválida ($intentos/5)." ;;
        esac
    done
    if [ "$intentos" -ge 5 ]; then echo "Demasiados intentos. Fase cancelada."; leer_enter; return 1; fi

    # ---- [3/5] Puerta de render (el pipeline NO valida gitops/**: hueco conocido) ----
    echo -e "\n${CIAN}[3/5] Validando el render de kustomize (puerta ANTES de commitear)...${NC}"
    local n_ing
    n_ing=$(kubectl kustomize "$OVERLAY_AZ" 2>/dev/null | grep -c "^kind: Ingress$" || true)
    if [ "${n_ing:-0}" -lt 1 ]; then
        echo -e "${ROJO}El render NO incluye Ingress: la línea '- ingress.yaml' sigue comentada (o el YAML quedó huérfano por indentación).${NC}"
        echo "Corrige el overlay y vuelve a intentar."
        leer_enter; return 1
    fi
    echo -e "${VERDE}Render OK: kind: Ingress presente.${NC}"

    # ---- [4/5] Precondiciones del clúster (fail-fast ANTES del push) ----
    echo -e "\n${CIAN}[4/5] Precondiciones del clúster${NC}"
    conectar_aks || { leer_enter; return 1; }
    if ! kubectl -n argocd get application "$APP_ARGO" >/dev/null 2>&1; then
        echo -e "${ROJO}La Application ${APP_ARGO} no existe: ejecuta primero la Fase 2.${NC}"
        leer_enter; return 1
    fi
    echo -e "${VERDE}Clúster y Application listos.${NC}"

    # ---- [5/5] Commit + push + espera de la IP del AppGW ----
    echo -e "\n${CIAN}[5/5] Commit + push (git add selectivo del overlay, nunca -A)${NC}"
    git -C "$REPO_ROOT" add -- "$OVERLAY_KUST"
    git -C "$REPO_ROOT" commit -m "azure: FASE 4 ON - Ingress AGIC + App Gateway (overlay azure-aks)"
    git -C "$REPO_ROOT" push

    echo -e "\n${CIAN}Forzando el refresh de ArgoCD y esperando la IP del AppGW (~1-3 min)...${NC}"
    kubectl -n argocd annotate application "$APP_ARGO" argocd.argoproj.io/refresh=hard --overwrite
    local gw_ip="" intentos=0
    while [ "$intentos" -lt 30 ]; do
        gw_ip=$(kubectl -n "$NS_APP" get ingress sri-facturacion-ingress \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        [ -n "$gw_ip" ] && break
        intentos=$((intentos+1))
        [ $((intentos % 3)) -eq 0 ] && echo "  ... esperando ADDRESS (${intentos}x10s)"
        sleep 10
    done
    if [ -z "$gw_ip" ]; then
        echo -e "${ROJO}La IP no apareció en 300s.${NC} Revisa: kubectl -n ${NS_APP} get ingress"
        leer_enter; return 1
    fi
    echo -e "${VERDE}ADDRESS del AppGW: ${gw_ip}${NC}"

    echo -e "\n${CIAN}Sonda HTTP (catch-all: a la IP pelada, SIN -H \"Host\"):${NC}"
    local codigo
    codigo=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://${gw_ip}/health" || true)
    echo "  GET http://${gw_ip}/health -> ${codigo}"
    if [ "$codigo" = "200" ]; then
        curl -s --max-time 15 "http://${gw_ip}/api/v1/version" | jq . 2>/dev/null || curl -s --max-time 15 "http://${gw_ip}/api/v1/version"
        echo "-- Balanceo entre pods (hostname distinto por request):"
        for i in 1 2 3 4 5 6; do curl -s --max-time 10 "http://${gw_ip}/api/v1/version" | jq -r .hostname 2>/dev/null || true; done
    else
        echo -e "${AMARILLO}Sonda != 200. Si es 502: backend pool vacío -> el Ingress debe apuntar al Service 'sri-facturacion-service-svc' (incidente real, fix espejo AWS).${NC}"
    fi
    echo -e "\n${MAGENTA}Browser (evidencia para el jurado): ventana de INCOGNITO con URL 'http://${gw_ip}/docs'${NC}"
    echo -e "${MAGENTA}(HTTPS-First de Chrome/Safari promueve a https:// y el AppGW solo escucha HTTP:80 - Apéndice A).${NC}"
    echo -e "${AMARILLO}Nota FinOps: \$0 incremental - el AppGW ya facturaba desde la Fase 1 (nació con el clúster).${NC}"
    leer_enter
}

# ============================================================
# FASE 5 - DEMO ON: umbral didáctico HPA 5% + pruebas de carga
# Ritual GitOps igual que la Fase 4: el usuario descomenta el bloque
# hpa-patch.yaml (guion a columna 0 - lección de indentación heredada
# de AWS), esta opción valida el render (averageUtilization: 5), commitea
# y empuja. Después: hey -z 90s -c 30 contra la IP del AppGW con
# monitoreo en vivo. Re-lanzable: log fijo truncado, hey huérfano limpiado
# y port-forward de ArgoCD reutilizado si ya existe (lecciones del menú AWS).
# Costo: ~$0.02 (CPU extra de las réplicas adicionales).
# ============================================================
opcion6() {
    echo -e "\n${CIAN}[ Ejecutando FASE 5 - HPA 5% + pruebas de carga ]${NC}"

    # ---- [1/6] Precondición: Ingress ONLINE ----
    echo -e "\n${CIAN}[1/6] Verificando que el Ingress del AppGW está ONLINE${NC}"
    conectar_aks || { leer_enter; return 1; }
    local gw_ip
    gw_ip=$(kubectl -n "$NS_APP" get ingress sri-facturacion-ingress \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -z "$gw_ip" ]; then
        echo -e "${ROJO}El Ingress no tiene ADDRESS: ejecuta primero la Fase 4.${NC}"
        leer_enter; return 1
    fi
    echo "AppGW IP: ${VERDE}${gw_ip}${NC}"
    local codigo
    codigo=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://${gw_ip}/health" || true)
    echo "  GET http://${gw_ip}/health -> ${codigo}"
    if [ "$codigo" != "200" ]; then
        echo -e "${ROJO}Sonda != 200: la app no responde por el AppGW. Corrige antes de cargar (502 = backend pool).${NC}"
        leer_enter; return 1
    fi
    if ! command -v hey >/dev/null 2>&1; then
        echo -e "${ROJO}hey no está instalado: brew install hey${NC}"
        leer_enter; return 1
    fi

    # ---- [2/6] HPA ON: diff + puerta de render + commit/push ----
    echo -e "\n${CIAN}[2/6] Activando el umbral didáctico del HPA (bloque hpa-patch.yaml)${NC}"
    local rama
    rama=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [ "$rama" != "$BRANCH" ]; then
        echo -e "${ROJO}Estás en la rama '${rama}' y ArgoCD vigila '${BRANCH}'.${NC}"
        leer_enter; return 1
    fi
    if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$OVERLAY_AZ" 2>/dev/null)" ]; then
        echo -e "${ROJO}No hay cambios sin commitear en el overlay.${NC}"
        echo "Edita manualmente ${OVERLAY_KUST}: descomenta el bloque 'hpa-patch.yaml' (líneas 40-43, guion a columna 0)."
        leer_enter; return 1
    fi
    git -C "$REPO_ROOT" --no-pager diff -- "$OVERLAY_KUST"
    local respuesta intentos=0
    while [ "$intentos" -lt 5 ]; do
        read -p "Revise los cambios del HPA antes de continuar (s/n): " respuesta
        case "$respuesta" in
            [sS]|[sS][iI]) break ;;
            [nN]|[nN][oO]) echo "Fase cancelada."; leer_enter; return 0 ;;
            *) intentos=$((intentos+1)); echo "Entrada inválida ($intentos/5)." ;;
        esac
    done
    if [ "$intentos" -ge 5 ]; then echo "Demasiados intentos. Fase cancelada."; leer_enter; return 1; fi
    if ! kubectl kustomize "$OVERLAY_AZ" 2>/dev/null | grep -q "averageUtilization: 5"; then
        echo -e "${ROJO}El render NO muestra averageUtilization: 5 (el bloque hpa-patch sigue comentado o mal indentado).${NC}"
        leer_enter; return 1
    fi
    echo -e "${VERDE}Render OK: umbral 5% presente (los 70/80 base quedan bajo el patch).${NC}"
    git -C "$REPO_ROOT" add -- "$OVERLAY_KUST"
    git -C "$REPO_ROOT" commit -m "azure: FASE 5 ON - umbral didactico HPA 5% (demo)"
    git -C "$REPO_ROOT" push
    kubectl -n argocd annotate application "$APP_ARGO" argocd.argoproj.io/refresh=hard --overwrite
    echo "-- HPA (esperado TARGETS cpu X%/5%):"
    sleep 5; kubectl -n "$NS_APP" get hpa

    # ---- [3/6] hey en segundo plano con log fijo (lección mktemp BSD: X al final; ruta fija + truncado) ----
    echo -e "\n${CIAN}[3/6] Lanzando hey -z ${DURACION_HEY} -c ${CONEXIONES_HEY} en segundo plano...${NC}"
    local hey_log="${TMPDIR:-/tmp}/hey_fase5_azure.log"
    : > "$hey_log" || { echo -e "${ROJO}No se pudo crear el log ${hey_log}${NC}"; leer_enter; return 1; }
    local hey_viejo
    hey_viejo=$(pgrep -f "hey -z .*${gw_ip}/health" 2>/dev/null || true)
    if [ -n "$hey_viejo" ]; then
        echo "  hey huérfano de una corrida anterior (PID ${hey_viejo}): se detiene antes de relanzar."
        kill $hey_viejo 2>/dev/null; sleep 2
    fi
    hey -z "$DURACION_HEY" -c "$CONEXIONES_HEY" "http://${gw_ip}/health" > "$hey_log" 2>&1 &
    local hey_pid=$!
    echo "  hey PID ${hey_pid} -> log: ${hey_log}"

    # ---- [4/6] Port-forward de ArgoCD (reutiliza uno existente; libera solo el PID propio al terminar) ----
    echo -e "\n${CIAN}[4/6] Port-forward de ArgoCD (http://localhost:8082 -> UI para el jurado)${NC}"
    local pf_existente="" pid8080
    for pid8080 in $(lsof -ti :8080 2>/dev/null || true); do
        if ps -p "$pid8080" -o command= 2>/dev/null | grep -q "kubectl.*port-forward.*argocd-server"; then
            pf_existente="$pid8080"; break
        fi
    done
    local argocd_pid=""
    if [ -n "$pf_existente" ]; then
        echo "  Ya existe un port-forward de ArgoCD (PID ${pf_existente}): se REUTILIZA y queda vivo tras esta fase."
    elif [ -n "$pid8080" ]; then
        echo -e "  ${AMARILLO}El puerto 8080 lo ocupa otra aplicación: se OMITE el port-forward.${NC}"
    else
        kubectl port-forward svc/argocd-server 8080:443 -n argocd &
        argocd_pid=$!
        echo "  port-forward propio (PID ${argocd_pid}): se libera al terminar esta fase."
        # Solo el PID que esta fase levanta se libera al retornar; el reusado no se toca.
        trap '[ -n "$argocd_pid" ] && kill "$argocd_pid" 2>/dev/null; trap - RETURN' RETURN
    fi
    echo "  Clave admin: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; echo"

    # ---- [5/6] Monitoreo en vivo (snapshots acotados: -w jamás devolvería el menú) ----
    echo -e "\n${CIAN}[5/6] Monitoreo en vivo (HPA escalando 3 -> hasta 10; ~${DURACION_HEY} + margen)${NC}"
    local dur_s="${DURACION_HEY%s}" fin=$((SECONDS + dur_s + 15))
    while [ "$SECONDS" -lt "$fin" ]; do
        if ! kill -0 "$hey_pid" 2>/dev/null; then echo "  hey terminó."; break; fi
        echo "===== snapshot ${SECONDS}s ====="
        kubectl -n "$NS_APP" get hpa 2>/dev/null
        kubectl -n "$NS_APP" get pods 2>/dev/null | head -12
        sleep 10
    done
    wait "$hey_pid" 2>/dev/null

    # ---- [6/6] Resultados ----
    echo -e "\n${CIAN}[6/6] Resultados de la carga${NC}"
    echo "-- hey:"
    tail -25 "$hey_log"
    echo "-- HPA final:"
    kubectl -n "$NS_APP" get hpa
    echo "-- Pods final:"
    kubectl -n "$NS_APP" get pods
    echo -e "${AMARILLO}Evidencia real (2026-10-08): el HPA llegó a 10 réplicas con este mismo test.${NC}"
    echo -e "${AMARILLO}Ritual del runbook §5.3: el umbral se revierte al cerrar - la Fase 7 (opción 8) lo apaga TODO con un commit.${NC}"
    leer_enter
}

# ============================================================
# FASE 6 - OPCIONAL: bucle completo del pipeline (ocurre en GitHub)
# No hay nada que aprovisionar desde aquí: el pipeline CI/CD corre en
# GitHub Actions (OIDC, matriz dual-cloud). Esta opción es el guion.
# ============================================================
opcion7() {
    echo -e "\n${CIAN}[ FASE 6 - Bucle del pipeline GitOps (ocurre en GitHub) ]${NC}"
    echo -e "${MAGENTA}Guion manual (referencia: DEMO_STACK_AZURE_FINAL.md FASE 6 y DEMO_AZURE_GITOPS_JURADO.md):${NC}"
    echo "  1. Edita app/main.py: version \"X\" -> \"X+1\""
    echo "  2. git commit -am 'feat: version X+1' && git push (rama ${BRANCH})"
    echo "  3. El pipeline corre (pytest -> build -> push ACR :<sha> -> bump del manifiesto [skip ci])"
    echo "  4. ArgoCD auto-sync (nuevo ReplicaSet, rollout sin downtime)"
    echo "  5. Verifica: curl -s http://<GW_IP>/api/v1/version | jq"
    echo "     -> version nueva, cloud=azure, cluster=${AZ_CLUSTER}, hostname del NUEVO ReplicaSet"
    echo ""
    echo -e "${MAGENTA}Preguntas del jurado cubiertas: P25 (pipeline punta a punta), P26 ([skip ci] anti-bucle),${NC}"
    echo -e "${MAGENTA}P27 (drift -> OutOfSync -> ArgoCD revierte).${NC}"
    leer_enter
}

# ============================================================
# HELPER: Destroy idempotente de un módulo Terraform (lección del menú
# AWS: verificar 'terraform state list == 0' para confirmar la
# eliminación; reintentar solo cuando != 0; omitir cuando == 0).
# ============================================================
destruir_modulo() {
    local dir="$1" nombre="$2"
    local log_destroy="${TMPDIR:-/tmp}/tf_destroy_$(basename "$dir").log"
    echo -e "\n${MAGENTA}== Destroy: ${nombre} (${dir}) ==${NC}"
    if ! terraform -chdir="$dir" init -input=false >/dev/null 2>&1; then
        echo -e "${AMARILLO}init falló en ${nombre}: se omite (¿backend de §0.3 caído?).${NC}"
        return 1
    fi
    local n
    n=$(terraform -chdir="$dir" state list 2>/dev/null | grep -c . || true)
    if [ "${n:-0}" -eq 0 ]; then
        echo "State vacío: ${nombre} ya está destruido (omitido, idempotente)."
        return 0
    fi
    echo "State con ${n} recurso(s). Destroy (puede tardar varios minutos)..."
    local i rc
    for i in 1 2 3; do
        terraform -chdir="$dir" destroy -auto-approve -input=false -lock-timeout=60s > "$log_destroy" 2>&1
        rc=$?
        tail -15 "$log_destroy"
        n=$(terraform -chdir="$dir" state list 2>/dev/null | grep -c . || true)
        if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 0 ]; then
            echo -e "${VERDE}${nombre}: destroy completo (state a cero).${NC}"
            return 0
        fi
        echo -e "${AMARILLO}intento $i/3: quedan ${n:-?} recurso(s).${NC}"
        echo -e "${AMARILLO}Si persiste: az aks show para el estado real / subir nivel a Cloud Shell (Apéndice A).${NC}"
        sleep 15
    done
    echo -e "${ROJO}${nombre}: NO quedó a cero tras 3 intentos. Estado real con 'az aks show' antes de seguir.${NC}"
    return 1
}

# ============================================================
# HELPER: Verificación final $0/h (3 checks efímeros vacíos + 5 checks
# permanentes vivos). Devuelve el número de hallazgos ROJOS.
# ============================================================
verificacion_final_azure() {
    local rojos=0
    echo -e "\n${CIAN}[ Verificación final - efímeros (esperado: vacío) ]${NC}"

    local n_appgw
    n_appgw=$(az network application-gateway list --query "length(@)" -o tsv 2>/dev/null || echo "?")
    if [ "$n_appgw" = "0" ]; then
        echo -e "  ${VERDE}OK${NC}  Application Gateways: 0"
    else
        echo -e "  ${ROJO}ROJO${NC} Application Gateways vivos: ${n_appgw}"
        az network application-gateway list --query "[].{name:name,rg:resourceGroup}" -o table 2>/dev/null
        rojos=$((rojos+1))
    fi

    local n_aks
    n_aks=$(az aks list --query "length(@)" -o tsv 2>/dev/null || echo "?")
    if [ "$n_aks" = "0" ]; then
        echo -e "  ${VERDE}OK${NC}  Clústeres AKS: 0"
    else
        echo -e "  ${ROJO}ROJO${NC} Clústeres AKS vivos: ${n_aks}"
        rojos=$((rojos+1))
    fi

    local n_mc
    n_mc=$(az group list --query "length([?starts_with(name, 'MC_')])" -o tsv 2>/dev/null || echo "?")
    if [ "$n_mc" = "0" ]; then
        echo -e "  ${VERDE}OK${NC}  Node RG MC_*: 0 (AppGW + IPs públicas eliminadas con el clúster)"
    else
        echo -e "  ${AMARILLO}AMBAR${NC} Node RG MC_* aún borrándose (asíncrono): ${n_mc}"
        echo -e "  -> AKs limpia el node RG ASINCRONAMENTE (2-5 min): vuelve a comprobar con:"
        echo "     az group list --query \"[?starts_with(name,'MC_')].name\" -o tsv"
    fi

    echo -e "\n${CIAN}[ Verificación final - plataforma permanente (esperado: viva, intacta) ]${NC}"
    if az keyvault show -g "$AZ_TFRG" -n "$AZ_KV" --query name -o tsv >/dev/null 2>&1; then
        echo -e "  ${VERDE}OK${NC}  Key Vault ${AZ_KV} vivo (3 capas: state separado + RG distinto + prevent_destroy)"
    else
        echo -e "  ${ROJO}ROJO${NC} Key Vault ${AZ_KV} NO encontrado"
        rojos=$((rojos+1))
    fi
    local n_sec
    n_sec=$(az keyvault secret list --vault-name "$AZ_KV" --query "length(@)" -o tsv 2>/dev/null || echo "?")
    if [ "$n_sec" = "3" ]; then
        echo -e "  ${VERDE}OK${NC}  Secretos intactos: 3"
    else
        echo -e "  ${ROJO}ROJO${NC} Secretos del KV: ${n_sec} (esperado 3)"
        rojos=$((rojos+1))
    fi
    if az identity show -g "$AZ_TFRG" -n "$AZ_MI" --query clientId -o tsv >/dev/null 2>&1; then
        echo -e "  ${VERDE}OK${NC}  Managed Identity ${AZ_MI} viva (clientId estable)"
    else
        echo -e "  ${ROJO}ROJO${NC} MI ${AZ_MI} NO encontrada"
        rojos=$((rojos+1))
    fi
    if az acr show -n "$AZ_ACR" --query name -o tsv >/dev/null 2>&1; then
        echo -e "  ${VERDE}OK${NC}  ACR ${AZ_ACR} vivo (prevent_destroy)"
    else
        echo -e "  ${ROJO}ROJO${NC} ACR ${AZ_ACR} NO encontrado"
        rojos=$((rojos+1))
    fi
    if az group show -n "$AZ_TFRG" --query name -o tsv >/dev/null 2>&1; then
        echo -e "  ${VERDE}OK${NC}  RG plataforma ${AZ_TFRG} vivo (la casa de la plataforma)"
    else
        echo -e "  ${ROJO}ROJO${NC} RG ${AZ_TFRG} NO encontrado"
        rojos=$((rojos+1))
    fi

    return "$rojos"
}

# ============================================================
# FASE 7 - CIERRE FINOPS (orden estricto -> $0/h)
# Más simple que el de AWS: UN SOLO destroy (iac/azure) en lugar de tres.
# Ritual GitOps simétrico: comentar ingress + hpa-patch -> commit/push ->
# prune (No resources found). Checkpoint anti-huérfano por disciplina
# (en Azure NO puede quedar huérfano: el AppGW vive en MC_* y muere con
# el clúster - a diferencia del ALB de AWS, que era el rescate #1).
# El Key Vault ni siquiera está en el state de iac/azure (state aparte +
# RG distinto + prevent_destroy = 3 capas de protección).
# ============================================================
opcion8() {
    echo -e "\n${CIAN}[ Ejecutando FASE 7 - Cierre FinOps -> \$0/h ]${NC}"
    echo -e "${MAGENTA}Orden: demo OFF (ritual) -> checkpoint anti-huérfano -> destroy único (iac/azure) -> verificación.${NC}"

    # ---- [1/6] Rama correcta (si habrá commit) ----
    local rama
    rama=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [ "$rama" != "$BRANCH" ]; then
        echo -e "${ROJO}Estás en la rama '${rama}' y ArgoCD vigila '${BRANCH}'.${NC}"
        leer_enter; return 1
    fi
    echo "Rama: ${VERDE}${rama}${NC}"

    # ---- ¿El clúster está vivo? (define modo: cierre completo o solo verificación) ----
    local cluster_vivo=0
    if az aks show -g "$AZ_RG" -n "$AZ_CLUSTER" --query name -o tsv >/dev/null 2>&1; then
        cluster_vivo=1
    fi

    if [ "$cluster_vivo" -eq 1 ]; then

        # ---- [2/6] Demo mode OFF (ritual simétrico, idempotente) ----
        echo -e "\n${CIAN}[2/6] Demo OFF: comentando ingress.yaml + hpa-patch.yaml en el overlay${NC}"
        local render
        render=$(kubectl kustomize "$OVERLAY_AZ" 2>/dev/null || true)
        local n_ing n_hpa5
        n_ing=$(printf '%s\n' "$render" | grep -c "^kind: Ingress$" || true)
        n_hpa5=$(printf '%s\n' "$render" | grep -c "averageUtilization: 5" || true)
        if [ "${n_ing:-0}" -eq 0 ] && [ "${n_hpa5:-0}" -eq 0 ]; then
            echo "  El render ya está OFF (ingress y hpa comentados): ritual de commit omitido (idempotente)."
        else
            # sed idempotentes: comentan SOLO si la línea no empieza ya con '#'
            sed -i '' -E 's|^[[:space:]]*- ingress\.yaml$|#- ingress.yaml|' "$OVERLAY_KUST"
            sed -i '' -E '/hpa-patch\.yaml/,/sri-facturacion-service-hpa/ { /^#/! s/^/#/; }' "$OVERLAY_KUST"
            local render2
            render2=$(kubectl kustomize "$OVERLAY_AZ" 2>/dev/null || true)
            local n_ing2 n_hpa52
            n_ing2=$(printf '%s\n' "$render2" | grep -c "^kind: Ingress$" || true)
            n_hpa52=$(printf '%s\n' "$render2" | grep -c "averageUtilization: 5" || true)
            if [ "${n_ing2:-0}" -ne 0 ] || [ "${n_hpa52:-0}" -ne 0 ]; then
                echo -e "${ROJO}La puerta de render inversa falló (siguen objetos ON): NO se commitea.${NC}"
                echo "Revisa manualmente ${OVERLAY_KUST} (indentación - lección del YAML huérfano)."
                leer_enter; return 1
            fi
            echo -e "${VERDE}Render OFF validado (sin Ingress, sin umbral 5%).${NC}"
            git -C "$REPO_ROOT" add -- "$OVERLAY_KUST"
            git -C "$REPO_ROOT" commit -m "azure: FASE 7 OFF - Ingress + HPA (cierre demo, repo a su punto canónico)"
            git -C "$REPO_ROOT" push
        fi

        # ---- [3/6] Annotate + espera del prune ----
        echo -e "\n${CIAN}[3/6] Refresh de ArgoCD + espera del prune (Ingress fuera del clúster)${NC}"
        conectar_aks || { leer_enter; return 1; }
        kubectl -n argocd annotate application "$APP_ARGO" argocd.argoproj.io/refresh=hard --overwrite
        local ing_out intentos=0
        while [ "$intentos" -lt 24 ]; do
            ing_out=$(kubectl -n "$NS_APP" get ingress 2>&1 || true)
            if printf '%s' "$ing_out" | grep -q "No resources found"; then
                echo -e "${VERDE}Prune confirmado: 'No resources found' en ingress.${NC}"
                break
            fi
            intentos=$((intentos+1))
            [ $((intentos % 3)) -eq 0 ] && echo "  ... esperando prune (${intentos}x10s)"
            sleep 10
        done
        if ! printf '%s' "$ing_out" | grep -q "No resources found"; then
            echo -e "${ROJO}El prune no se completó en 240s. NO se destruye nube con objetos vivos.${NC}"
            kubectl -n "$NS_APP" get ingress
            leer_enter; return 1
        fi
        echo -e "${AMARILLO}Nota didáctica: en AWS el prune BORRABA el ALB (rescate); aquí el AppGW SIGUE VIVO${NC}"
        echo -e "${AMARILLO}hasta el destroy - nació del clúster, no del Ingress. Ritual por simetría, no por riesgo (P30).${NC}"

        # ---- [4/6] Checkpoint anti-huérfano (por disciplina, no por riesgo) ----
        echo -e "\n${CIAN}[4/6] Checkpoint anti-huérfano (AppGW solo en MC_*)${NC}"
        local n_appgw
        n_appgw=$(az network application-gateway list --query "length(@)" -o tsv 2>/dev/null || echo "?")
        if [ "$n_appgw" = "1" ]; then
            local appgw_rg
            appgw_rg=$(az network application-gateway list --query "[0].resourceGroup" -o tsv 2>/dev/null)
            case "$appgw_rg" in
                MC_*)
                    echo -e "  ${VERDE}OK${NC}  único AppGW '${appgw_rg}' vive en el node RG MC_* (muere con el clúster)."
                    echo "  IPs públicas esperadas en MC_: 'sri-appgw-appgwpip' + una con nombre GUID (outbound NAT de AKS) - normales."
                    ;;
                *)
                    echo -e "${ROJO}El AppGW vive en '${appgw_rg}' (NO es un RG MC_*): investiga ANTES del destroy.${NC}"
                    leer_enter; return 1
                    ;;
            esac
        else
            echo -e "${ROJO}Application Gateways encontrados: ${n_appgw} (esperado 1 en MC_*). Investiga ANTES del destroy.${NC}"
            az network application-gateway list --query "[].{name:name,rg:resourceGroup}" -o table 2>/dev/null
            leer_enter; return 1
        fi

        # ---- [5/6] Destroy único de iac/azure ----
        echo -e "\n${CIAN}[5/6] Destroy del clúster (iac/azure: fedcred + AKS + RG ${AZ_RG})${NC}"
        echo -e "${AMARILLO}Avisos: (1) el destroy menciona 'key vault' por el add-on CSI - NO es el KV de Azure (3 capas lo protegen);${NC}"
        echo -e "${AMARILLO}(2) el node RG MC_* (con AppGW + IPs) lo borra AKS ASINCRONAMENTE (2-5 min);${NC}"
        echo -e "${AMARILLO}(3) si reporta timeout: NO reintentar en bucle - az aks show para el estado real / Cloud Shell (Apéndice A).${NC}"
        read -p "¿Destruir el clúster ahora? Esta acción DETIENE la facturación. (s/n): " r
        case "$r" in
            [sS]|[sS][iI]) ;;
            *) echo "Destroy cancelado. El reloj sigue corriendo."; leer_enter; return 0 ;;
        esac
        destruir_modulo "$REPO_ROOT/iac/azure" "Clúster AKS (RG ${AZ_RG} + AKS + federated credential)" || { leer_enter; return 1; }

        # El node RG MC_ se limpia asíncrono: espera acotada antes de la verificación
        echo -e "\n${CIAN}Esperando a que AKS elimine el node RG MC_* (asíncrono, 2-5 min)...${NC}"
        local n_mc=1 intento_mc=0
        while [ "$intento_mc" -lt 36 ]; do
            n_mc=$(az group list --query "length([?starts_with(name, 'MC_')])" -o tsv 2>/dev/null || echo "?")
            [ "$n_mc" = "0" ] && break
            intento_mc=$((intento_mc+1))
            [ $((intento_mc % 6)) -eq 0 ] && echo "  ... MC_ aún presente ($((intento_mc*10))s)"
            sleep 10
        done

    else
        echo -e "\n${AMARILLO}El clúster ya está ausente: MODO SOLO-VERIFICACIÓN (se omiten ritual y destroy).${NC}"
    fi

    # ---- [6/6] Verificación final + mapa efímero/permanente ----
    echo -e "\n${CIAN}[6/6] Verificación final${NC}"
    verificacion_final_azure
    local rojos=$?

    echo ""
    echo -e "${CIAN}== Mapa de cierre (qué murió / qué sobrevivió) ==${NC}"
    echo -e "${MAGENTA}Efímero (murió):${NC} clúster AKS + nodos · Application Gateway v2 + IPs (RG MC_) · federated credential · ArgoCD, driver CSI, AGIC, pods, Ingress"
    echo -e "${MAGENTA}Permanente (sobrevive, ~\$5.2/mes en centavos):${NC} Key Vault + 3 secretos (~\$0.10/mes) · Managed Identity (clientId estable) · ACR + imagen (~\$5/mes) · SP terraform-ci-azure, backend de state, OIDC GitHub"
    echo ""
    if [ "$rojos" -eq 0 ]; then
        echo -e "${VERDE}Suscripción a \$0/h: sin efímeros, plataforma intacta, estado final del repo canónico.${NC}"
        echo -e "${VERDE}Próxima sesión/defensa: Fase 1 (apply del clúster) -> Fase 2 -> todo converge SIN editar un solo manifiesto.${NC}"
    else
        echo -e "${ROJO}Verificación con ${rojos} hallazgo(s) ROJO(s): resuélvelos antes de dar por cerrada la sesión.${NC}"
    fi
    leer_enter
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
opcion=""
while true; do
    mostrar_menu
    read -r -p "Selecciona una opción [0-8]: " opcion || break
    case "$opcion" in
        1) opcion1 ;;
        2) opcion2 ;;
        3) opcion3 ;;
        4) opcion4 ;;
        5) opcion5 ;;
        6) opcion6 ;;
        7) opcion7 ;;
        8) opcion8 ;;
        0)
            if confirmar_salida; then
                echo -e "${VERDE}¡Hasta luego!${NC}"
                break
            fi
            ;;
        *)
            echo -e "${ROJO}Opción inválida. Intenta de nuevo.${NC}"
            leer_enter
            ;;
    esac
done
