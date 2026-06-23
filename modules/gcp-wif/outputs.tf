output "wif_provider_resource_name" {
  description = "Full resource name for the WIF provider. Use as wif_provider_resource_name in CustomerPlacement."
  value       = google_iam_workload_identity_pool_provider.murmur.name
}

output "service_account_email" {
  description = "Service account email for VM creation. Use as wif_service_account in the Placement."
  value       = google_service_account.murmur_vm_creator.email
}

output "readonly_service_account_email" {
  description = "Service account email for read-only operations. Use as wif_readonly_service_account in the Placement."
  value       = google_service_account.murmur_readonly.email
}

output "vm_service_accounts" {
  description = "VM runtime service account emails. Each maps to a ServiceAccountBinding on the Placement with grant-scoped access control."
  value       = var.vm_service_accounts
}
