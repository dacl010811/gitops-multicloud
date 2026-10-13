# ============================================
# Outputs: Root Module Azure Key Vault
# ============================================

output "key_vault_name" {
  description = "Nombre del vault (viaja en la SPC del overlay)"
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "URI del vault"
  value       = azurerm_key_vault.main.vault_uri
}

output "identity_client_id" {
  description = "clientId PÚBLICO de la MI — viaja en la SPC (clientID) y en la anotación del SA"
  value       = azurerm_user_assigned_identity.workload.client_id
}

output "identity_principal_id" {
  description = "principalId (objeto) — lo consume el bootstrap para el rol Secrets User"
  value       = azurerm_user_assigned_identity.workload.principal_id
}

output "identity_id" {
  description = "Id completo del recurso MI — parent de la federated credential (iac/azure)"
  value       = azurerm_user_assigned_identity.workload.id
}
