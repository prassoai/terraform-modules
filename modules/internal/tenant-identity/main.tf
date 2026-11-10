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
}

resource "terraform_data" "identity" {
  input = {
    provider   = split("/", var.namespace)[0]
    subject_id = tostring(local.account.id)
  }
}

output "identity" {
  description = "Canonical provider and subject_id resolved from the namespace for cloud trust."
  value       = terraform_data.identity.input
  precondition {
    condition     = can(regex("^[1-9][0-9]*$", tostring(local.account.id))) && contains(["User", "Organization"], local.account.type) && (split("/", var.namespace)[0] != "github_oauth" || local.account.type == "User")
    error_message = "GitHub must return a positive immutable account ID and an account type valid for the tenant provider."
  }
}
