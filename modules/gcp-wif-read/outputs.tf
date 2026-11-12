output "wif_readonly_provider_resource_name" {
  description = "Set gcp.wif_readonly_provider_resource_name after applying read trust."
  value       = google_iam_workload_identity_pool_provider.murmur_read.name
}
output "issuer_url" {
  description = "Tenant-specific read issuer."
  value       = local.issuer_url
}
