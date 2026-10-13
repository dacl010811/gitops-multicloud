# ============================================
# Submódulo Azure AKS
# Aislado para que el provider azurerm solo se configure/autentique
# cuando este submódulo se instancia (count = 1 en el módulo padre).
# ============================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_instance_type
  }

  identity {
    type = "SystemAssigned"
  }

  # ============================================
  # Sesión 2026-10-08: identidad de workload + add-ons CSI/AGIC
  # ============================================

  # Emisor OIDC + webhook de Workload Identity (homólogo del OIDC provider
  # de EKS que consumía IRSA): sin esto no existe la federación SA→MI.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Driver CSI de secretos como add-on GESTIONADO (homólogo del chart Helm
  # del provider AWS de bootstrap-secrets-csi-eks.sh; aquí lo opera MS).
  # Nota azurerm (verificado en provider 3.117): el bloque exige
  # secret_rotation_enabled o secret_rotation_interval explícito.
  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }

  # AGIC GREENFIELD: crea un Application Gateway v2 (gateway_name) en una
  # subnet nueva del VNet managed del clúster (10.225.0.0/24). INCIDENTE
  # REAL (2026-10-08): el clúster usa Azure CNI Overlay (default de AKS
  # moderno) y el add-on RECHAZA prefijos menores a /24 con
  # "IngressAppGwAddonConfigInvalidSubnetCIDR: prefix length ... exceeds 24"
  # — el /16 de los ejemplos kubenet clásicos ya no aplica. El AppGW muere
  # con el node RG MC_ en el destroy → cero huérfanos por diseño. Homólogo
  # de la cadena LB Controller→ALB de AWS. Factura desde el apply
  # (~$0.02-0.05/h), no desde el Ingress.
  # Nota azurerm v3 (verificado en provider 3.117): exige UNO de
  # gateway_id / subnet_id / subnet_cidr (enabled=true es esquema v2).
  ingress_application_gateway {
    gateway_name = "sri-appgw"
    subnet_cidr  = "10.225.0.0/24"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aks"
  })
}
