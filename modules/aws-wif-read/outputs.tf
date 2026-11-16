output "readonly_oidc_provider_arn" {
  description = "Migration-only selector. Set aws.readonly_oidc_provider_arn with readonly_role_arn while Murmur runs mixed readers (murmuration#14482). The final reader (murmuration#14501) removes that placement field; keep this output until then."
  value       = aws_iam_openid_connect_provider.murmur_read.arn
}
output "readonly_role_arn" {
  description = "Set aws.readonly_role_arn. During migration set it together with readonly_oidc_provider_arn; final AWS reads need only this role. It also accepts existing provisioning-family read tokens."
  value       = aws_iam_role.readonly.arn
}
output "issuer_url" {
  description = "Tenant-specific read issuer."
  value       = local.issuer_url
}
