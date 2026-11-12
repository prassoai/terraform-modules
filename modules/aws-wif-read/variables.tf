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

variable "validate_oidc_readiness" {
  description = "Check public tenant discovery and read JWKS during planning. Disabling requires explicit oidc_ca_thumbprints and skips all issuer network lookups."
  type        = bool
  default     = true
  nullable    = false
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


variable "oidc_ca_thumbprints" {
  description = "Optional stable CA SHA-1 thumbprints, not leaf fingerprints. When supplied, skip TLS certificate discovery. Required when validate_oidc_readiness is false."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(var.oidc_ca_thumbprints) <= 5 && alltrue([for fingerprint in var.oidc_ca_thumbprints : can(regex("^[0-9a-fA-F]{40}$", fingerprint))])
    error_message = "oidc_ca_thumbprints must contain at most five 40-character hexadecimal CA SHA-1 fingerprints."
  }
}
