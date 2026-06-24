# ── Sync-ready Murmur Placement output ────────────────────────────────────────
#
# Assembles a complete customer-managed Placement catalog resource from this
# module's WIF outputs plus the placement-shape inputs below, so you can pipe it
# straight into the CLI instead of hand-copying the WIF scalars into a Placement:
#
#   terraform output -json placement | murmur set placement <name>
#
# The value is the protojson form of murmur.api.v1.Placement. It uses snake_case
# field names, which protojson accepts (same names as the .proto). The output is
# null until placement_name is set, so this module still works for WIF-only setups.

variable "placement_name" {
  description = "Name for the generated Placement (DNS label: [a-z][a-z0-9-]{0,62}). Empty disables the placement output. Must NOT start with \"murmur-\" — that prefix is reserved for platform builtins and tenant writes of it are rejected."
  type        = string
  default     = ""
}

variable "placement_zones" {
  description = "GCE zones for the placement (one or more, all in the same region)."
  type        = list(string)
  default     = []
}

variable "placement_subnet" {
  description = "VPC subnet self-link or name for the placement."
  type        = string
  default     = ""
}

variable "placement_assign_public_ip" {
  description = "Give each agent VM an ephemeral external IPv4. Leave false if the project enforces constraints/compute.vmExternalIpAccess."
  type        = bool
  default     = false
}

variable "placement_description" {
  description = "Human-readable description shown in the Murmur dashboard."
  type        = string
  default     = ""
}

# Who may spawn agents under the VM-runtime service accounts. A runtime-SA binding
# confers exactly one permission — placement-sa.assume, the only meaningful verb on
# such a binding — so the module fixes the permission and callers choose only the
# principals (groups/users).

variable "default_spawn_grant" {
  description = "Principals allowed to spawn agents under the runtime SAs (granted placement-sa.assume). Applied to every SA in vm_service_accounts unless overridden in spawn_grants_by_sa. Defaults to all tenant members."
  type = object({
    groups = optional(list(string), ["murmur-all-members"])
    users  = optional(list(string), [])
  })
  default = {}
}

variable "spawn_grants_by_sa" {
  description = "Per-service-account override of default_spawn_grant, keyed by SA email. Use to scope a privileged runtime SA (e.g. an investigation SA) to named users while the rest stay on the default. An overridden SA does NOT inherit the default's groups — list exactly who may assume it."
  type = map(object({
    groups = optional(list(string), [])
    users  = optional(list(string), [])
  }))
  default = {}
}

locals {
  spawn_principals = {
    for sa in var.vm_service_accounts : sa => (
      contains(keys(var.spawn_grants_by_sa), sa) ? var.spawn_grants_by_sa[sa] : var.default_spawn_grant
    )
  }
}

output "placement" {
  description = "Sync-ready Murmur Placement (protojson). Pipe to `murmur set placement <name>`. Null until placement_name is set."
  value = var.placement_name == "" ? null : {
    name        = var.placement_name
    substrate   = "SUBSTRATE_GCP"
    description = var.placement_description
    gcp = {
      project                      = var.project_id
      zones                        = var.placement_zones
      subnet                       = var.placement_subnet
      network_project              = var.network_project
      wif_provider_resource_name   = google_iam_workload_identity_pool_provider.murmur.name
      wif_service_account          = google_service_account.murmur_vm_creator.email
      wif_readonly_service_account = google_service_account.murmur_readonly.email
      assign_public_ip             = var.placement_assign_public_ip
    }
    service_account_bindings = [
      for sa in var.vm_service_accounts : {
        gcp_service_account = sa
        grants = [{
          groups = local.spawn_principals[sa].groups
          users  = local.spawn_principals[sa].users
          inline = { permissions = ["placement-sa.assume"] }
        }]
      }
    ]
  }
}
