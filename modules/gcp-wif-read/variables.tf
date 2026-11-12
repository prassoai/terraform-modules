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
  description = "Check public tenant discovery and read JWKS during planning. Keep enabled for onboarding or issuer changes; disable for maintenance or teardown during an OIDC outage."
  type        = bool
  default     = true
  nullable    = false
}
variable "project_id" {
  description = "Project containing the existing read-only service account."
  type        = string
}
variable "readonly_service_account_email" {
  description = "Existing read-only service account from gcp-wif. Permissions and legacy trust remain owned by that module."
  type        = string
}
variable "pool_id" {
  description = "Separate read-only WIF pool ID, distinct from the provisioning pool."
  type        = string
  default     = "murmur-read-pool"
}
variable "provider_id" {
  description = "Provider ID inside the read pool."
  type        = string
  default     = "murmur-read-provider"
}
