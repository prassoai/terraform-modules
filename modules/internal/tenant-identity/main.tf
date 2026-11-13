# Pin either a resolved locator or an explicitly supplied immutable identity.
terraform {
  required_version = ">= 1.4"
  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

variable "namespace" {
  description = "GitHub provider/login namespace to resolve at the customer WIF input boundary."
  type        = string
  default     = null
  validation {
    condition     = var.namespace == null || can(regex("^(github_app|github_oauth)/[A-Za-z0-9][A-Za-z0-9-]*$", var.namespace))
    error_message = "namespace must be a github_app/login or github_oauth/login locator."
  }
}

variable "tenant" {
  description = "Immutable tenant identity supplied directly, without a provider lookup."
  type = object({
    provider   = string
    subject_id = string
  })
  default = null
  validation {
    condition     = var.tenant == null ? true : contains(["github_app", "github_oauth"], var.tenant.provider) && can(regex("^[1-9][0-9]*$", var.tenant.subject_id))
    error_message = "tenant must contain a supported GitHub provider and a positive canonical numeric subject_id."
  }
}

data "http" "account" {
  count = var.namespace != null && var.tenant == null ? 1 : 0
  url   = "https://api.github.com/users/${split("/", var.namespace)[1]}"
  request_headers = {
    Accept = "application/vnd.github+json"
  }
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "GitHub tenant lookup failed; cloud trust requires a resolved account."
    }
  }
}

locals {
  account = length(data.http.account) == 0 ? null : jsondecode(data.http.account[0].response_body)
  selected_identity = var.tenant != null ? var.tenant : var.namespace == null ? null : {
    provider   = split("/", var.namespace)[0]
    subject_id = tostring(local.account.id)
  }
}

# The initial account remains authoritative until an operator explicitly replaces
# this record. Neither a locator refresh nor a supplied identity edit may redirect trust.
resource "terraform_data" "identity" {
  input = local.selected_identity
  lifecycle {
    precondition {
      condition     = (var.namespace != null) != (var.tenant != null)
      error_message = "Set exactly one of tenant_id (provider/login namespace) or tenant (provider/subject_id identity)."
    }
    ignore_changes = [input]
  }
}

output "identity" {
  description = "Pinned canonical provider and subject_id for cloud trust."
  value       = terraform_data.identity.input
  precondition {
    condition     = local.account == null ? true : can(regex("^[1-9][0-9]*$", tostring(local.account.id))) && contains(["User", "Organization"], local.account.type) && (split("/", var.namespace)[0] != "github_oauth" || local.account.type == "User")
    error_message = "GitHub must return a positive immutable account ID and an account type valid for the tenant provider."
  }
  precondition {
    condition     = terraform_data.identity.input == local.selected_identity
    error_message = "The selected identity differs from the pinned tenant owner. Restore the pinned identity or a locator for it, or explicitly replace the identity record to rebind trust."
  }
}
