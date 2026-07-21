# ── Murmur Placement sync ─────────────────────────────────────────────────────
#
# Assembles a complete customer-managed Placement catalog resource from this
# module's IAM outputs plus the placement-shape inputs below, and manages it in
# the murmur catalog on `terraform apply`. Setting placement_name IS the sync:
# the module creates/updates the Placement via murmur_catalog_resource, so
# drift (grant edits, subnet changes, rotated ARNs) shows up in `terraform
# plan` and is pushed by apply. Empty placement_name disables the sync and the
# output, so this module still works for federation-only setups — no murmur
# provider block or credentials needed.
#
# The document is the protojson form of murmur.api.v1.Placement. It uses
# snake_case field names, which protojson accepts (same names as the .proto).
#
# The `placement` output remains as the document itself — for debugging, and as
# the escape hatch for callers without direct catalog write permission:
#
#   terraform output -json placement | murmur set placement <name> --propose --rationale ...
#
# account_id is derived from the VM-creator role ARN (the roles live in the
# customer's own account). The VPC/subnet/security-group/region are not created by
# this module, so they are taken as inputs and only used to assemble the document.

locals {
  placement_account_id = split(":", aws_iam_role.vm_creator.arn)[4]
}

variable "placement_name" {
  description = "Name for the generated Placement (DNS label: [a-z][a-z0-9-]{0,62}). Empty disables the placement sync and output. Must NOT start with \"murmur-\" — that prefix is reserved for platform builtins and tenant writes of it are rejected."
  type        = string
  default     = ""
  nullable    = false # an explicit null coerces to "" so the count guard on the sync resource is total
}

variable "placement_region" {
  description = "AWS region for the placement (e.g. \"us-east-1\")."
  type        = string
  default     = ""
}

variable "placement_vpc_id" {
  description = "VPC ID agent VMs run in."
  type        = string
  default     = ""
}

variable "placement_subnet_ids" {
  description = "Subnet IDs for agent VMs, one per AZ."
  type        = list(string)
  default     = []
}

variable "placement_security_group_id" {
  description = "Security group ID for agent VMs."
  type        = string
  default     = ""
}

variable "placement_description" {
  description = "Human-readable description shown in the Murmur dashboard."
  type        = string
  default     = ""
}

# Who may spawn agents under the VM-runtime instance profile. The binding confers
# exactly one permission — placement-sa.assume, the only meaningful verb on such a
# binding — so the module fixes the permission and callers choose only the
# principals (groups/users/service profiles). AWS placements have a single runtime
# instance profile, so there is one binding and no per-identity override.
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
  description = "Principals allowed to spawn agents under the runtime instance profile (granted placement-sa.assume). Defaults to all tenant members plus all service-profile controllers. Set service_profiles = [] to restrict the placement to human principals, or list bare profile names to scope it."
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

locals {
  # The service-profile: principal prefix appears exactly here and nowhere else;
  # callers only ever write bare profile names.
  service_profile_grants = length(var.default_spawn_grant.service_profiles) > 0 ? [{
    users  = [for p in var.default_spawn_grant.service_profiles : "service-profile:${p}"]
    inline = { permissions = ["placement-sa.assume"] }
  }] : []

  placement = var.placement_name == "" ? null : {
    name        = var.placement_name
    substrate   = "SUBSTRATE_AWS"
    description = var.placement_description
    aws = {
      account_id        = local.placement_account_id
      region            = var.placement_region
      vpc_id            = var.placement_vpc_id
      subnet_ids        = var.placement_subnet_ids
      role_arn          = aws_iam_role.vm_creator.arn
      oidc_provider_arn = aws_iam_openid_connect_provider.murmur.arn
      readonly_role_arn = aws_iam_role.readonly.arn
      security_group_id = var.placement_security_group_id
    }
    service_account_bindings = [
      {
        aws_instance_profile_arn = aws_iam_instance_profile.vm.arn
        grants = concat(
          # Omitted when both lists are empty: a grant must name at least one
          # group or user, so a profiles-only configuration renders just the
          # service-profile grant below.
          length(var.default_spawn_grant.groups) + length(var.default_spawn_grant.users) > 0 ? [{
            groups = var.default_spawn_grant.groups
            users  = var.default_spawn_grant.users
            inline = { permissions = ["placement-sa.assume"] }
          }] : [],
          local.service_profile_grants
        )
      }
    ]
  }
}

resource "murmur_catalog_resource" "placement" {
  count   = var.placement_name != "" ? 1 : 0
  kind    = "placement"
  name    = var.placement_name
  tenant  = var.tenant_id # assertion — must match the provider block's tenant
  payload = jsonencode(local.placement)
}

output "placement" {
  description = "The Murmur Placement document (protojson) this module syncs to the catalog. For debugging, or `murmur set placement <name> --propose` when you lack direct write permission. Null until placement_name is set."
  value       = local.placement

  precondition {
    condition     = var.placement_name == "" || length(var.default_spawn_grant.groups) + length(var.default_spawn_grant.users) + length(var.default_spawn_grant.service_profiles) > 0
    error_message = "The runtime instance profile needs at least one spawn principal: set groups, users, or service_profiles on default_spawn_grant."
  }
}
