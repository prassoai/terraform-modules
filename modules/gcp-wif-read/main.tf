# Add read-family trust beside the pinned provisioning module.
# This module owns no VM-creator resources or service-account permissions.
locals {
  issuer_url = "${var.issuer_base_url}/read/${var.tenant_id}"
}
resource "google_iam_workload_identity_pool" "murmur_read" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Murmur Read Pool"
  description               = "Read-only federation for one Murmur tenant"
}
resource "google_iam_workload_identity_pool_provider" "murmur_read" {
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
