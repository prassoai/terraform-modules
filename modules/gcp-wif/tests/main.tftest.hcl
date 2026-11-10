mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/12345678\",\"jwks_uri\":\"https://oidc.murmur.dev/platform/.well-known/jwks.json\"}"
    }
  }
}

mock_provider "google" {}

run "placement_default_oauth_scopes" {
  command = plan
  variables {
    placement_name = "customer-gcp"
  }
  assert {
    condition     = output.placement.gcp.oauth_scopes == tolist(["https://www.googleapis.com/auth/cloud-platform"])
    error_message = "Customer placements must explicitly include the default cloud-platform scope."
  }
}

run "placement_custom_oauth_scopes" {
  command = plan
  variables {
    placement_name         = "customer-gcp"
    placement_oauth_scopes = ["https://www.googleapis.com/auth/devstorage.read_only"]
  }
  assert {
    condition     = output.placement.gcp.oauth_scopes == tolist(["https://www.googleapis.com/auth/devstorage.read_only"])
    error_message = "Placement scopes must preserve the caller's explicit list."
  }
}

run "placement_no_oauth_scopes" {
  command = plan
  variables {
    placement_name         = "customer-gcp"
    placement_oauth_scopes = []
  }
  assert {
    condition     = length(output.placement.gcp.oauth_scopes) == 0
    error_message = "An empty scope list must stay empty."
  }
}

variables {
  project_id          = "customer-vms"
  tenant_id           = "github_app/12345678"
  vm_service_accounts = ["murmur-vm@customer-vms.iam.gserviceaccount.com"]
}

# Murmur deletes exactly one kind of disk in a customer's project: the
# throwaway murmur-hydrate-<uuid> that image hydration creates and discards.
# Every other disk here is an agent's boot disk, so the grant that can destroy
# one must name what it may destroy. A project-wide compute.disks.delete would
# read as least privilege while being the one permission in this module that
# can take a live agent's disk with it.
run "deleting_a_disk_is_granted_only_over_hydration_disks" {
  command = plan

  assert {
    condition     = !contains(google_project_iam_custom_role.vm_lifecycle.permissions, "compute.disks.delete")
    error_message = "Disk deletion must not ride on the unconditioned VM lifecycle role."
  }
  assert {
    condition     = join(",", google_project_iam_custom_role.hydration_cleanup.permissions) == "compute.disks.delete"
    error_message = "The conditioned role must carry the disk delete and nothing else."
  }
  assert {
    condition     = can(regex("murmur-hydrate-", one(google_project_iam_member.hydration_cleanup.condition).expression))
    error_message = "The disk delete must be bound under a condition naming hydration disks."
  }
  # IAM conditions are restricted CEL, not CEL: resource.name offers
  # startsWith, endsWith, extract, == and !=, and a regex is rejected at apply
  # with "undeclared reference to 'matches'". A condition that cannot be applied
  # is not a tighter grant than an unconditioned one — it is no grant at all,
  # and it fails in the customer's own apply, where we cannot see it.
  assert {
    condition     = !can(regex("\\.matches\\(", one(google_project_iam_member.hydration_cleanup.condition).expression))
    error_message = "An IAM condition cannot use a regex; name the disks with extract().startsWith() instead."
  }
}

# Hydration reconciles against the disks already in the project, so the worker
# that resumes after one died has to be able to see the scratch disks the dead
# one left behind. Listing is safe to hold unconditionally — it reveals disk
# names, which the VM lifecycle role already writes.
run "hydration_can_find_abandoned_scratch_disks" {
  command = plan

  assert {
    condition     = contains(google_project_iam_custom_role.vm_lifecycle.permissions, "compute.disks.list")
    error_message = "Hydration cleanup needs compute.disks.list to find disks an interrupted bake left behind."
  }
  assert {
    condition     = contains(google_project_iam_custom_role.vm_lifecycle.permissions, "compute.disks.create")
    error_message = "Hydration creates the scratch disk it later deletes."
  }
}

# The provider must trust only the immutable tenant issuer, and retain tenant
# and role checks. Sharing public signing keys must not merge tenant trust.
run "tenant_specific_issuer" {
  # An unreachable issuer must fail promptly during planning.
  assert {
    condition     = data.http.discovery.request_timeout_ms == 10000
    error_message = "Discovery readiness must have a finite request timeout."
  }

  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.murmur.oidc[0].issuer_uri == "https://oidc.murmur.dev/platform/github_app/12345678"
    error_message = "The provider must use the full tenant issuer."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.murmur.attribute_condition == "assertion.iss == \"https://oidc.murmur.dev/platform/github_app/12345678\" && assertion.tenant == \"github_app/12345678\" && assertion.role in ['read', 'write']"
    error_message = "Trust must enforce the exact issuer, immutable tenant, and role."
  }
  assert {
    condition     = output.issuer_url == "https://oidc.murmur.dev/platform/github_app/12345678"
    error_message = "The issuer output must match the provider."
  }
}

# Non-production changes only the origin; it cannot omit tenant scoping.
run "nonproduction_tenant_issuer" {
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.nonprod.murmur.dev/platform/github_app/87654321\",\"jwks_uri\":\"https://oidc.nonprod.murmur.dev/platform/.well-known/jwks.json\"}" }
  }

  command = plan
  variables {
    issuer_base_url = "https://oidc.nonprod.murmur.dev"
    tenant_id       = "github_app/87654321"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.murmur.oidc[0].issuer_uri == "https://oidc.nonprod.murmur.dev/platform/github_app/87654321"
    error_message = "An origin override must retain the immutable tenant suffix."
  }
}

# A mutable login must fail at plan time, not silently trust the wrong issuer.
run "reject_mutable_tenant_login" {
  command = plan
  variables { tenant_id = "github_app/acme" }
  expect_failures = [var.tenant_id]
}

# An origin containing a path would append a second tenant suffix.
run "reject_issuer_path" {
  command = plan
  variables { issuer_base_url = "https://oidc.murmur.dev/platform/github_app/12345678" }
  expect_failures = [var.issuer_base_url]
}

# Onboarding must stop before cloud trust is created if public discovery does
# not advertise this exact tenant and its provisioning-only keyset.
run "wrong_tenant_discovery" {
  command = plan
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/99999999\",\"jwks_uri\":\"https://oidc.murmur.dev/platform/.well-known/jwks.json\"}" }
  }
  expect_failures = [google_iam_workload_identity_pool_provider.murmur]
}

# Onboarding must stop before cloud trust is created if public discovery does
# not advertise this exact tenant and its provisioning-only keyset.
run "wrong_family_keyset" {
  command = plan
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/12345678\",\"jwks_uri\":\"https://oidc.murmur.dev/agents/.well-known/jwks.json\"}" }
  }
  expect_failures = [google_iam_workload_identity_pool_provider.murmur]
}

# Onboarding must stop before cloud trust is created if public discovery does
# not advertise this exact tenant and its provisioning-only keyset.
run "malformed_discovery" {
  command = plan
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "not-json" }
  }
  expect_failures = [google_iam_workload_identity_pool_provider.murmur]
}
