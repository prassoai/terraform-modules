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

variable "vm_spawn_grants" {
  description = <<-EOT
    Authorization grants attached to every VM-runtime service-account binding in
    the generated placement. They control WHO may spawn agents that run as the
    runtime SA — checked at spawn via the placement-sa.assume permission.

    Default: every tenant member may spawn (the murmur-all-members builtin group,
    granted placement-sa.assume). Override to scope to specific groups/users or a
    narrower role for least privilege. Each grant must set exactly one of `role`
    (a CatalogRole name) or `permissions` (inline verbs).
  EOT
  type = list(object({
    groups       = optional(list(string), [])
    users        = optional(list(string), [])
    role         = optional(string)
    permissions  = optional(list(string))
    name_pattern = optional(string)
  }))
  default = [{
    groups      = ["murmur-all-members"]
    permissions = ["placement-sa.assume"]
  }]
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
        grants = [
          for g in var.vm_spawn_grants : {
            groups       = g.groups
            users        = g.users
            name_pattern = g.name_pattern
            role         = g.role
            inline       = g.permissions == null ? null : { permissions = g.permissions }
          }
        ]
      }
    ]
  }
}
