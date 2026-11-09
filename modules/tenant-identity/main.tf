# Resolve the human-entered locator once, before constructing cloud trust.
terraform {
  required_version = ">= 1.0"
  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

variable "tenant" {
  description = "GitHub tenant locator, e.g. github_app/acme or github_oauth/octocat. Uses the public GitHub API; review the resolved tenant_id in the plan before applying trust changes."
  type        = string
  validation {
    condition     = can(regex("^(github_app|github_oauth)/[A-Za-z0-9][A-Za-z0-9-]*$", var.tenant))
    error_message = "tenant must be a github_app/login or github_oauth/login locator."
  }
}

data "http" "account" {
  url = "https://api.github.com/users/${split("/", var.tenant)[1]}"
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

output "tenant_id" {
  description = "Immutable tenant address for the customer WIF modules. A provider/login locator is never a trust identity."
  value       = "${split("/", var.tenant)[0]}/${local.account.id}"
  precondition {
    condition     = can(regex("^[1-9][0-9]*$", tostring(local.account.id))) && contains(["User", "Organization"], local.account.type) && (split("/", var.tenant)[0] != "github_oauth" || local.account.type == "User")
    error_message = "GitHub must return a positive immutable account ID and an account type valid for the tenant provider."
  }
}
