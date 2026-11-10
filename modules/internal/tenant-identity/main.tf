# Resolve the human-entered locator once, before constructing cloud trust.
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
  validation {
    condition     = can(regex("^(github_app|github_oauth)/[A-Za-z0-9][A-Za-z0-9-]*$", var.namespace))
    error_message = "namespace must be a github_app/login or github_oauth/login locator."
  }
}

data "http" "account" {
  url = "https://api.github.com/users/${split("/", var.namespace)[1]}"
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
  account = jsondecode(data.http.account.response_body)
  resolved_identity = {
    provider   = split("/", var.namespace)[0]
    subject_id = tostring(local.account.id)
  }
}

# The initial account remains authoritative until an operator explicitly replaces
# this record. A locator refresh must never update established cloud trust.
resource "terraform_data" "identity" {
  input = local.resolved_identity
  lifecycle {
    ignore_changes = [input]
  }
}

output "identity" {
  description = "Pinned canonical provider and subject_id for cloud trust."
  value       = terraform_data.identity.input
  precondition {
    condition     = can(regex("^[1-9][0-9]*$", tostring(local.account.id))) && contains(["User", "Organization"], local.account.type) && (split("/", var.namespace)[0] != "github_oauth" || local.account.type == "User")
    error_message = "GitHub must return a positive immutable account ID and an account type valid for the tenant provider."
  }
  precondition {
    condition     = terraform_data.identity.input == local.resolved_identity
    error_message = "The namespace resolves to a different owner than the pinned tenant identity. Restore a locator for the pinned account, or explicitly replace the identity record to rebind trust."
  }
}
