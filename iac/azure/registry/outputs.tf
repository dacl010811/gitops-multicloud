# ============================================
# Outputs: Azure ACR Registry
# ============================================

output "registry_name" {
  description = "Nombre del Azure Container Registry"
  value       = azurerm_container_registry.main.name
}

output "login_server" {
  description = "FQDN del registry (usar en images.newName de los overlays)"
  value       = azurerm_container_registry.main.login_server
}
