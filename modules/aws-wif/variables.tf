variable "tenant_id" {
  description = "Murmur tenant identity namespace (e.g. \"github_app/acme\"). The trust policy scopes access to exactly this tenant. Obtained from `murmur tenant whoami` or the dashboard."
  type        = string

  validation {
    condition     = length(var.tenant_id) > 0
    error_message = "tenant_id must not be empty."
  }
}

variable "role_name" {
  description = "Name of the IAM role for VM creation."
  type        = string
  default     = "murmur-vm-creator"
}

variable "readonly_role_name" {
  description = "Name of the IAM role for read-only API operations."
  type        = string
  default     = "murmur-readonly"
}

variable "instance_profile_name" {
  description = "Name of the IAM instance profile for VM runtime."
  type        = string
  default     = "murmur-vm"
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (e.g. \"https://oidc.murmur.dev\"). The OIDC provider trusts tokens from this issuer, and the role trust policy requires the aud claim to match oidc_audience."
  type        = string
  default     = "https://oidc.murmur.dev"
}

variable "oidc_audience" {
  description = "Expected aud claim in OIDC tokens. Must match the aud Murmur mints for AWS-bound tokens. Defaults to sts.amazonaws.com (standard AWS OIDC convention). See README for coordination notes."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "ec2_permissions_boundary_arn" {
  description = "Optional permissions boundary ARN to attach to all IAM roles. Some organizations require a boundary on every role."
  type        = string
  default     = null
}

variable "extra_policies" {
  description = "Additional IAM policy ARNs to attach to the VM creator role beyond the built-in EC2 lifecycle policy."
  type        = list(string)
  default     = []
}
