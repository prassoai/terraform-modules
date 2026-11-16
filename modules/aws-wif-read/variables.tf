variable "tenant_id" {
  description = "Immutable Murmur tenant address (e.g. github_app/12345678), using the numeric GitHub account ID, never its login."
  type        = string

  validation {
    condition     = can(regex("^github_app/[1-9][0-9]*$", var.tenant_id))
    error_message = "tenant_id must be github_app/<numeric GitHub account ID>, not an organization login."
  }
}

variable "issuer_base_url" {
  description = "OIDC HTTPS origin. The module appends /read/<tenant_id>; override the origin for non-production."
  type        = string
  default     = "https://oidc.murmur.dev"

  validation {
    condition     = can(regex("^https://[^/?#@[:space:]]+$", var.issuer_base_url))
    error_message = "issuer_base_url must be an HTTPS origin without a path, query, fragment, or trailing slash."
  }
}

variable "provisioning_oidc_provider_arn" {
  description = "Existing tenant-specific provisioning OIDC provider ARN from aws-wif; read-only trust is retained for older readers and rollback."
  type        = string
}
variable "readonly_role_name" {
  description = "New read role name, distinct from the existing aws-wif read role."
  type        = string
  default     = "murmur-read-issuer"
}
variable "oidc_audience" {
  description = "Audience accepted by both read trusts; must match the existing aws-wif setting."
  type        = string
  default     = "sts.amazonaws.com"
}
variable "ec2_permissions_boundary_arn" {
  description = "Existing placement permissions boundary, if required by the customer account."
  type        = string
  default     = null
}
