# A supplied identity must reach cloud trust with no dependency on GitHub.
mock_provider "http" {
  mock_data "http" {
    defaults = { status_code = 503, response_body = "{}" }
  }
}
mock_provider "google" {}
variables {
  project_id          = "customer-vms"
  vm_service_accounts = ["murmur-vm@customer-vms.iam.gserviceaccount.com"]
  tenant              = { provider = "github_app", subject_id = "123" }
}
run "supplied_identity_reaches_cloud_trust" {
  command = plan
  assert {
    condition     = output.tenant_identity == var.tenant && output.issuer_url == "${var.issuer_base_url}/platform/github_app/123"
    error_message = "The supplied pair must determine both recorded identity and issuer without a successful lookup."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.murmur.attribute_condition == "assertion.iss == \"${var.issuer_base_url}/platform/github_app/123\" && assertion.tenant == \"tenant:github_app/123\" && assertion.infrastructure_owner == 'customer' && assertion.role in ['read', 'write']"
    error_message = "Supplied identities must use the same tenant, ownership and role trust contract."
  }
}

