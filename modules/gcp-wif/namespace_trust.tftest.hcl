# A migration admits both reserved namespaces while keeping the provider's
# issuer and role checks in the rendered trust condition.
mock_provider "google" {}

variables {
  project_id          = "customer-prod-12345"
  vm_service_accounts = ["murmur-vm@customer-prod-12345.iam.gserviceaccount.com"]
  storage_namespaces  = ["github_app/acme", "github_app/12345678"]
}

run "migration_namespaces" {
  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.murmur.attribute_condition == "assertion.iss == \"https://oidc.murmur.dev\" && assertion.tenant in [\"github_app/acme\",\"github_app/12345678\"] && assertion.role in ['read', 'write']"
    error_message = "The provider must admit only the two named namespaces from the Murmur issuer for read and write roles."
  }
}

# Retirement removes the old principal from the provider condition.
run "retired_namespace" {
  command = plan

  variables {
    storage_namespaces = ["github_app/12345678"]
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.murmur.attribute_condition == "assertion.iss == \"https://oidc.murmur.dev\" && assertion.tenant in [\"github_app/12345678\"] && assertion.role in ['read', 'write']"
    error_message = "Retirement must leave only the destination namespace trusted."
  }
}
