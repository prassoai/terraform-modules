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
# principals (groups/users/service profiles).
#
# service_profiles takes bare profile names ("*" for all). Service-profile
# controllers — API keys, webhook- and schedule-driven automation — authorize as
# the profile principal and carry no group membership, so without an entry here
# they can never match a groups/users grant and cannot launch VMs on the
# placement. These principals match only the profile's controller credential,
# never agent VMs carrying a profile claim, so per-agent VM isolation is
# preserved. A human borrowing a profile (e.g. `murmur bake --service-profile`)
# authorizes as themselves and is covered by groups/users.

variable "default_spawn_grant" {
  description = "Principals allowed to spawn agents under the runtime SAs (granted placement-sa.assume). Applied to every SA in vm_service_accounts unless overridden in spawn_grants_by_sa. Defaults to all tenant members plus all service-profile controllers. Set service_profiles = [] to restrict the placement to human principals, or list bare profile names to scope it."
  type = object({
    groups           = optional(list(string), ["murmur-all-members"])
    users            = optional(list(string), [])
    service_profiles = optional(list(string), ["*"])
  })
  default = {}

  validation {
    condition     = alltrue([for p in var.default_spawn_grant.service_profiles : !startswith(p, "service-profile:")])
    error_message = "service_profiles takes bare profile names (or \"*\"), not service-profile:-prefixed principals."
  }

  validation {
    condition     = alltrue([for u in var.default_spawn_grant.users : !startswith(u, "service-profile:")])
    error_message = "users must not contain service-profile: principals — put bare profile names in service_profiles."
  }
}

variable "spawn_grants_by_sa" {
  description = "Per-service-account override of default_spawn_grant, keyed by SA email. Use to scope a privileged runtime SA (e.g. an investigation SA) to named users or profiles while the rest stay on the default. An overridden SA does NOT inherit the default's principals — list exactly who may assume it (service_profiles defaults to [] here, so scoped SAs stay scoped)."
  type = map(object({
    groups           = optional(list(string), [])
    users            = optional(list(string), [])
    service_profiles = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for g in values(var.spawn_grants_by_sa) : alltrue([for p in g.service_profiles : !startswith(p, "service-profile:")])])
    error_message = "service_profiles takes bare profile names (or \"*\"), not service-profile:-prefixed principals."
  }

  validation {
    condition     = alltrue([for g in values(var.spawn_grants_by_sa) : alltrue([for u in g.users : !startswith(u, "service-profile:")])])
    error_message = "users must not contain service-profile: principals — put bare profile names in service_profiles."
  }
}

locals {
  spawn_principals = {
    for sa in var.vm_service_accounts : sa => (
      contains(keys(var.spawn_grants_by_sa), sa) ? var.spawn_grants_by_sa[sa] : var.default_spawn_grant
    )
  }

  # The service-profile: principal prefix appears exactly here and nowhere else;
  # callers only ever write bare profile names.
  service_profile_grants = {
    for sa, g in local.spawn_principals : sa => {
      users  = [for p in g.service_profiles : "service-profile:${p}"]
      inline = { permissions = ["placement-sa.assume"] }
    } if length(g.service_profiles) > 0
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
        grants = concat(
          # Omitted when both lists are empty: a grant must name at least one
          # group or user, so a profiles-only override renders just the
          # service-profile grant below.
          length(local.spawn_principals[sa].groups) + length(local.spawn_principals[sa].users) > 0 ? [{
            groups = local.spawn_principals[sa].groups
            users  = local.spawn_principals[sa].users
            inline = { permissions = ["placement-sa.assume"] }
          }] : [],
          contains(keys(local.service_profile_grants), sa) ? [local.service_profile_grants[sa]] : []
        )
      }
    ]
  }

  precondition {
    condition = var.placement_name == "" || alltrue([
      for sa, g in local.spawn_principals : length(g.groups) + length(g.users) + length(g.service_profiles) > 0
    ])
    error_message = "Every runtime SA needs at least one spawn principal: set groups, users, or service_profiles (per SA in spawn_grants_by_sa, or via default_spawn_grant)."
  }
}
