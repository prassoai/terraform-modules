output "readonly_role_arn" {
  description = "Set aws.readonly_role_arn before the read-family cutover. The role accepts read tokens from both the read issuer and the existing provisioning issuer."
  value       = aws_iam_role.readonly.arn
}
output "issuer_url" {
  description = "Tenant-specific read issuer."
  value       = local.issuer_url
}
