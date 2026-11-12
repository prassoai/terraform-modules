variable "tenant_id" {
  description = "Murmur provider/login namespace (e.g. github_app/acme), resolved through GitHub to an immutable account for cloud trust. Numeric logins are looked up, never interpreted as subject IDs. Supports github_app and github_oauth."
  type        = string
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
  description = "HTTPS OIDC origin without a path or trailing slash. The module derives the customer issuer from the pinned immutable tenant identity."
  type        = string
  default     = "https://oidc.murmur.dev"
  validation {
    condition     = can(regex("^https://[^/?#@[:space:]]+$", var.issuer_base_url))
    error_message = "The OIDC origin must be HTTPS without a path, query, fragment, or user information."
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
