mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{\"issuer\": \"https://oidc.murmur.dev/read/github_app/123\", \"jwks_uri\": \"https://oidc.murmur.dev/read/.well-known/jwks.json\", \"keys\": [{\"kty\": \"RSA\", \"alg\": \"RS256\", \"use\": \"sig\", \"kid\": \"read-test\", \"n\": \"test-modulus\", \"e\": \"AQAB\"}]}"
    }
  }
}
mock_provider "google" {}
variables {
  tenant_id                      = "github_app/123"
  project_id                     = "customer-vms"
  readonly_service_account_email = "murmur-readonly@customer-vms.iam.gserviceaccount.com"
}
override_resource {
  target = google_iam_workload_identity_pool.murmur_read
  values = { name = "projects/123/locations/global/workloadIdentityPools/murmur-read-pool" }
}
run "read_trust_is_separate_and_tenant_scoped" {
  command = apply
  assert {
    condition = (
      google_iam_workload_identity_pool_provider.murmur_read.oidc[0].issuer_uri == "https://oidc.murmur.dev/read/github_app/123" &&
      google_iam_workload_identity_pool_provider.murmur_read.attribute_condition == "assertion.iss == \"https://oidc.murmur.dev/read/github_app/123\" && assertion.tenant == \"github_app/123\" && assertion.role == 'read'"
    )
    error_message = "Only this tenant's read issuer and read claim may exchange."
  }
  assert {
    condition = (
      google_service_account_iam_member.readonly.service_account_id == "projects/customer-vms/serviceAccounts/murmur-readonly@customer-vms.iam.gserviceaccount.com" &&
      google_service_account_iam_member.readonly.role == "roles/iam.workloadIdentityUser" &&
      google_service_account_iam_member.readonly.member == "principalSet://iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/murmur-read-pool/attribute.role/read"
    )
    error_message = "Add only the separate read pool's binding on the existing reader account."
  }
}
run "wrong_family_discovery_is_rejected" {
  command = plan
  override_data {
    target = data.http.discovery[0]
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/123\",\"jwks_uri\":\"https://oidc.murmur.dev/platform/.well-known/jwks.json\"}" }
  }
  expect_failures = [google_iam_workload_identity_pool_provider.murmur_read]
}
run "empty_read_keyset_is_rejected" {
  command = plan
  override_data {
    target = data.http.jwks[0]
    values = { status_code = 200, response_body = "{\"keys\":[]}" }
  }
  expect_failures = [google_iam_workload_identity_pool_provider.murmur_read]
}
run "mutable_tenant_is_rejected" {
  command = plan
  variables { tenant_id = "github_app/acme" }
  expect_failures = [var.tenant_id]
}
run "maintenance_skips_public_http_without_widening_trust" {
  command = plan
  variables { validate_oidc_readiness = false }
  assert {
    condition     = length(data.http.discovery) == 0 && length(data.http.jwks) == 0
    error_message = "Maintenance must not need the unavailable issuer."
  }
  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.murmur_read.attribute_condition, "assertion.role == 'read'")
    error_message = "Maintenance must retain the exact read trust."
  }
}
