variable "project_id" {
  description = "GCP project ID where VMs will be created."
  type        = string
}

variable "tenant_id" {
  description = "Immutable Murmur tenant address (e.g. github_app/12345678), using the numeric GitHub account ID, never its login."
  type        = string

  validation {
    condition     = can(regex("^github_app/[1-9][0-9]*$", var.tenant_id))
    error_message = "tenant_id must be github_app/<numeric GitHub account ID>, not an organization login."
  }
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

variable "pool_id" {
  description = "WIF pool ID."
  type        = string
  default     = "murmur-pool"
}

variable "provider_id" {
  description = "WIF provider ID."
  type        = string
  default     = "murmur-provider"
}

variable "service_account_id" {
  description = "Service account ID for VM creation."
  type        = string
  default     = "murmur-vm-creator"
}

variable "readonly_service_account_id" {
  description = "Service account ID for read-only API operations."
  type        = string
  default     = "murmur-readonly"
}

variable "compute_roles" {
  description = "Additional IAM roles to grant the WIF service account beyond the built-in custom role. The custom role covers all permissions Murmur needs for VM lifecycle; use this only for exceptional cases."
  type        = list(string)
  default     = []
}

variable "network_project" {
  description = "Shared VPC host project ID. When set, grants roles/compute.networkUser so the WIF SA can use subnetworks from the shared VPC. Empty if the VM project owns its own network."
  type        = string
  default     = ""
}

variable "vm_service_accounts" {
  description = "VM runtime service account emails. Each SA maps to a service_account_bindings entry on your Murmur Placement — the WIF SA needs roles/iam.serviceAccountUser to attach it at VM creation time. List all SAs that appear in the placement's service_account_bindings."
  type        = list(string)
}


variable "validate_oidc_readiness" {
  description = "Check public tenant discovery and provisioning JWKS during planning. Keep enabled for onboarding or issuer changes; disable for maintenance or teardown during an OIDC outage."
  type        = bool
  default     = true
  nullable    = false
}
