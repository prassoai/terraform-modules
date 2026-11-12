output "readonly_oidc_provider_arn" {
  description = "Set aws.readonly_oidc_provider_arn after applying read trust."
  value       = aws_iam_openid_connect_provider.murmur_read.arn
}
output "readonly_role_arn" {
  description = "Set aws.readonly_role_arn together with readonly_oidc_provider_arn; this role also accepts existing provisioning-family read tokens."
  value       = aws_iam_role.readonly.arn
}
output "issuer_url" {
  description = "Tenant-specific read issuer."
  value       = local.issuer_url
}
