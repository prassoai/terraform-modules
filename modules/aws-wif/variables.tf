variable "tenant_id" {
  description = "Immutable Murmur tenant address (e.g. github_app/12345678), using the numeric GitHub account ID, never its login."
  type        = string

  validation {
    condition     = can(regex("^github_app/[1-9][0-9]*$", var.tenant_id))
    error_message = "tenant_id must be github_app/<numeric GitHub account ID>, not an organization login."
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

variable "issuer_base_url" {
  description = "OIDC HTTPS origin. The module appends /platform/<tenant_id>; override the origin for non-production."
  type        = string
  default     = "https://oidc.murmur.dev"

  validation {
    condition     = can(regex("^https://[^/?#@[:space:]]+$", var.issuer_base_url))
    error_message = "issuer_base_url must be an HTTPS origin without a path, query, fragment, or trailing slash."
  }
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
