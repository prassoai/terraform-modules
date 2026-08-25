# Workload Identity Federation module for single-tenant GCP authorization.
#
# This is the customer module — designed for a customer running it in their
# own GCP project. It creates a WIF pool, OIDC provider, service account,
# and IAM bindings that allow exactly ONE Murmur tenant to create VMs in
# the target project. The principalSet binds to attribute.tenant/${tenant_id},
# so only OIDC tokens carrying the matching tenant claim can impersonate the
# service account.
#
# VM runtime identity: each VM runs as a GCE service account listed in
# var.vm_service_accounts. These SAs map to the service_account_bindings on
# your Murmur Placement — each binding carries grants controlling which users
# may spawn agents under that identity. The WIF SA needs
# roles/iam.serviceAccountUser on each runtime SA to attach it at VM
# creation time.
#
# Consume via git source pinned to a release tag — see the repo README.

resource "google_iam_workload_identity_pool" "murmur" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Murmur Agent Pool"
  description               = "Workload Identity Federation pool for murmur.dev agent provisioning"
}

resource "google_iam_workload_identity_pool_provider" "murmur" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.murmur.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "murmur.dev OIDC"

  attribute_mapping = {
    "google.subject"   = "assertion.sub"
    "attribute.tenant" = "assertion.tenant"
    "attribute.role"   = "assertion.role"
  }

  # Only accept tokens from the Murmur issuer that carry a role claim.
  attribute_condition = "assertion.iss == '${var.murmur_issuer_url}' && 'role' in assertion"

  oidc {
    issuer_uri = var.murmur_issuer_url
  }
}

resource "google_service_account" "murmur_vm_creator" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "Murmur VM Creator"
  description  = "Service account for murmur.dev to create agent VMs via WIF"
}

# Allow the specific Murmur tenant to impersonate this SA, restricted to
# tokens with role=write (VM creation only).
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.murmur_vm_creator.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.murmur.name}/attribute.tenant/${var.tenant_id}"

  condition {
    title       = "write-role-only"
    description = "Only allow tokens with role=write to impersonate the VM creator SA"
    expression  = "api.getAttribute('iam.googleapis.com/attribute.role', []).hasOnly(['write'])"
  }
}

# ── Read-only service account ─────────────────────────────────────────

resource "google_service_account" "murmur_readonly" {
  project      = var.project_id
  account_id   = var.readonly_service_account_id
  display_name = "Murmur Read-Only"
  description  = "Service account for murmur.dev to perform read-only operations via WIF"
}

# Allow impersonation only when role=read AND tenant matches.
resource "google_service_account_iam_member" "wif_readonly_binding" {
  service_account_id = google_service_account.murmur_readonly.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.murmur.name}/attribute.tenant/${var.tenant_id}"

  condition {
    title       = "read-role-only"
    description = "Only allow tokens with role=read to impersonate the read-only SA"
    expression  = "api.getAttribute('iam.googleapis.com/attribute.role', []).hasOnly(['read'])"
  }
}

# Read-only access to the customer project. Uses the built-in
# roles/compute.viewer for forward-compat — every new GCE resource type
# is automatically readable as Murmur's read needs grow. Customers
# who want a tighter policy can replace this binding with their own
# custom role; nothing in Murmur depends on the role being named.
resource "google_project_iam_member" "readonly" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.murmur_readonly.email}"
}

# Custom role with the minimum permissions Murmur needs to manage VM
# lifecycle and image baking in this project.
resource "google_project_iam_custom_role" "vm_lifecycle" {
  project     = var.project_id
  role_id     = "murmurVmCreator"
  title       = "Murmur VM Creator"
  description = "Minimum permissions for Murmur to manage VM lifecycle via WIF."
  permissions = [
    # Agent VM lifecycle
    "compute.disks.create",                # create the VM boot disk
    "compute.disks.get",                   # read bake VM boot disk source image identity
    "compute.disks.setLabels",             # label the boot disk (tenant tagging)
    "compute.images.useReadOnly",          # reference the source image
    "compute.instances.create",            # create the VM
    "compute.instances.delete",            # delete the VM
    "compute.instances.get",               # read VM state
    "compute.instances.list",              # list VMs (discovery + cleanup)
    "compute.machineTypes.get",            # read a machine shape's RAM (sizes the suspend snapshot Murmur bills)
    "compute.instances.setLabels",         # label the VM at creation
    "compute.instances.setMetadata",       # set VM metadata
    "compute.instances.setServiceAccount", # attach the runtime service account
    "compute.instances.setTags",           # set network tags at creation
    "compute.instances.resume",            # resume a suspended VM (wake)
    "compute.instances.start",             # start a stopped VM
    "compute.instances.stop",              # stop a VM before imaging
    "compute.instances.suspend",           # suspend a VM (sleep)
    "compute.subnetworks.use",             # attach the VM NIC to a subnetwork (same project; cross-project via network_user)
    "compute.zoneOperations.get",          # poll zonal operations

    # Image baking pipeline
    "compute.disks.createSnapshot",  # snapshot the boot disk
    "compute.globalOperations.get",  # poll global operations
    "compute.images.create",         # create a cached image
    "compute.images.delete",         # delete a cached image
    "compute.images.get",            # check for a cached image
    "compute.images.setLabels",      # label the image at creation
    "compute.snapshots.create",      # create a snapshot (transitive with disks.createSnapshot)
    "compute.snapshots.delete",      # delete the intermediate snapshot
    "compute.snapshots.get",         # read snapshot state (idempotency guard on retry)
    "compute.snapshots.setLabels",   # label the snapshot at creation
    "compute.snapshots.useReadOnly", # create an image from a snapshot
  ]
}

resource "google_project_iam_member" "vm_lifecycle" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_lifecycle.id
  member  = "serviceAccount:${google_service_account.murmur_vm_creator.email}"
}

# Additional roles beyond the custom role, for customers who need them.
resource "google_project_iam_member" "compute" {
  for_each = toset(var.compute_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.murmur_vm_creator.email}"
}

# Shared VPC: allow the WIF SA to attach VMs to subnetworks in the host project.
# Only needed when the VM project uses a shared VPC.
resource "google_project_iam_member" "network_user" {
  count = var.network_project != "" ? 1 : 0

  project = var.network_project
  role    = "roles/compute.networkUser"
  member  = "serviceAccount:${google_service_account.murmur_vm_creator.email}"
}

# Allow the WIF SA to attach each VM runtime SA to new instances
# (serviceAccountUser). GCE requires the caller to have actAs on the SA
# attached to the instance at creation time. Each SA here corresponds to
# a service_account_bindings entry on your Murmur Placement — grant-scoped
# access control governs which users may spawn agents under each identity.
resource "google_service_account_iam_member" "vm_sa_user" {
  for_each = toset(var.vm_service_accounts)

  service_account_id = "projects/-/serviceAccounts/${each.value}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.murmur_vm_creator.email}"
}
