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

variable "vm_spawn_grants" {
  description = <<-EOT
    Authorization grants attached to the VM-runtime instance-profile binding in
    the generated placement. They control WHO may spawn agents that run as the
    runtime instance profile — checked at spawn via the placement-sa.assume
    permission.

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
