output "role_arn" {
  description = "ARN of the VM creator IAM role. Use as role_arn in CustomerPlacement config."
  value       = aws_iam_role.vm_creator.arn
}

output "readonly_role_arn" {
  description = "ARN of the read-only IAM role. Use as wif_readonly_role_arn in CustomerPlacement config."
  value       = aws_iam_role.readonly.arn
}

output "instance_profile_arn" {
  description = "ARN of the VM runtime instance profile. Pass to EC2 RunInstances as the instance profile."
  value       = aws_iam_instance_profile.vm.arn
}

output "vm_runtime_role_name" {
  description = "Name of the VM runtime IAM role. Use for per-environment policy attachments."
  value       = aws_iam_role.vm_runtime.name
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider. For audit and trust reference."
  value       = aws_iam_openid_connect_provider.murmur.arn
}
