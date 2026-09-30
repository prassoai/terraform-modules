variable "project_id" {
  description = "GCP project ID where VMs will be created."
  type        = string
}

variable "storage_namespaces" {
  description = "Storage namespaces of one Murmur tenant authorized to use this placement. Include both its current and reserved destination namespaces during migration; remove the old one only after its callers retire."
  type        = list(string)

  validation {
    condition     = length(var.storage_namespaces) > 0 && length(distinct(var.storage_namespaces)) == length(var.storage_namespaces) && alltrue([for namespace in var.storage_namespaces : can(regex("^[a-z_]+/[^/]+$", namespace))])
    error_message = "storage_namespaces must contain distinct, nonempty provider/name namespaces."
  }
}

variable "murmur_issuer_url" {
  description = "OIDC issuer URL. Override for staging/dev."
  type        = string
  default     = "https://oidc.murmur.dev"
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
