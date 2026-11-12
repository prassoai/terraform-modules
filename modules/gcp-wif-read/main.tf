# Add read-family trust beside the pinned provisioning module.
# This module owns no VM-creator resources or service-account permissions.
locals {
  issuer_url = "${var.issuer_base_url}/read/${var.tenant_id}"
}
# Refuse trust creation until the public tenant discovery contract is ready.
# This also catches a wrong environment or a document from the agents family.
data "http" "discovery" {
  count              = var.validate_oidc_readiness ? 1 : 0
  request_timeout_ms = 10000
  url                = "${local.issuer_url}/.well-known/openid-configuration"
  request_headers    = { Accept = "application/json" }
}

# Probe the known family URL, never an unvalidated discovery-supplied URL.
data "http" "jwks" {
  count              = var.validate_oidc_readiness ? 1 : 0
  request_timeout_ms = 10000
  url                = "${var.issuer_base_url}/read/.well-known/jwks.json"
  request_headers    = { Accept = "application/json" }
}

resource "google_iam_workload_identity_pool" "murmur_read" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Murmur Read Pool"
  description               = "Read-only federation for one Murmur tenant"
}
resource "google_iam_workload_identity_pool_provider" "murmur_read" {
  lifecycle {
    precondition {
      condition = !var.validate_oidc_readiness || try(
        data.http.discovery[0].status_code == 200 &&
        jsondecode(data.http.discovery[0].response_body).issuer == local.issuer_url &&
        jsondecode(data.http.discovery[0].response_body).jwks_uri == "${var.issuer_base_url}/read/.well-known/jwks.json" &&
        data.http.jwks[0].status_code == 200 &&
        length(jsondecode(data.http.jwks[0].response_body).keys) > 0 &&
        alltrue([for key in jsondecode(data.http.jwks[0].response_body).keys :
          key.kty == "RSA" && key.alg == "RS256" && key.use == "sig" &&
          length(key.kid) > 0 && length(key.n) > 0 && length(key.e) > 0
        ]),
        false,
      )
      error_message = "Tenant read OIDC is not ready. Discovery must name the exact issuer and read keyset, and JWKS must contain RS256 signing keys. Wait for Murmur publication before applying."
    }
  }

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.murmur_read.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  attribute_mapping = {
    "google.subject"   = "assertion.sub"
    "attribute.tenant" = "assertion.tenant"
    "attribute.role"   = "assertion.role"
  }
  attribute_condition = "assertion.iss == ${jsonencode(local.issuer_url)} && assertion.tenant == ${jsonencode(var.tenant_id)} && assertion.role == 'read'"
  oidc {
    issuer_uri = local.issuer_url
  }
}
resource "google_service_account_iam_member" "readonly" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.readonly_service_account_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.murmur_read.name}/attribute.role/read"
}
