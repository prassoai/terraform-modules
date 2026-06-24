# ── Sync-ready Murmur Placement output ────────────────────────────────────────
#
# Assembles a complete customer-managed Placement catalog resource from this
# module's IAM outputs plus the placement-shape inputs below, so you can pipe it
# straight into the CLI instead of hand-copying the role/profile ARNs into a
# Placement:
#
#   terraform output -json placement | murmur set placement <name>
#
# The value is the protojson form of murmur.api.v1.Placement. It uses snake_case
# field names, which protojson accepts (same names as the .proto). The output is
# null until placement_name is set, so this module still works for federation-only
# setups.
#
# account_id is derived from the VM-creator role ARN (the roles live in the
# customer's own account). The VPC/subnet/security-group/region are not created by
# this module, so they are taken as inputs and only used to assemble the output.

locals {
  placement_account_id = split(":", aws_iam_role.vm_creator.arn)[4]
}

variable "placement_name" {
  description = "Name for the generated Placement (DNS label: [a-z][a-z0-9-]{0,62}). Empty disables the placement output. Must NOT start with \"murmur-\" — that prefix is reserved for platform builtins and tenant writes of it are rejected."
  type        = string
  default     = ""
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
# principals (groups/users). AWS placements have a single runtime instance
# profile, so there is one binding and no per-identity override.

variable "default_spawn_grant" {
  description = "Principals allowed to spawn agents under the runtime instance profile (granted placement-sa.assume). Defaults to all tenant members."
  type = object({
    groups = optional(list(string), ["murmur-all-members"])
    users  = optional(list(string), [])
  })
  default = {}
}

output "placement" {
  description = "Sync-ready Murmur Placement (protojson). Pipe to `murmur set placement <name>`. Null until placement_name is set."
  value = var.placement_name == "" ? null : {
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
        grants = [{
          groups = var.default_spawn_grant.groups
          users  = var.default_spawn_grant.users
          inline = { permissions = ["placement-sa.assume"] }
        }]
      }
    ]
  }
}
