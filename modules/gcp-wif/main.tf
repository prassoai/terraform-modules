# Workload Identity Federation module for single-tenant GCP authorization.
#
# This is the customer module — designed for a customer running it in their
# own GCP project. It creates a WIF pool, OIDC provider, service account,
# and IAM bindings that allow exactly ONE Murmur tenant to create VMs in
# the target project. The provider accepts only OIDC tokens carrying the
# configured tenant claim, and service-account bindings select the required
# read or write role.
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

  # This pool belongs to one tenant. Reject other tenants before they can
  # exchange a subject token, and accept only the two roles this module binds.
  attribute_condition = "assertion.iss == ${jsonencode(var.murmur_issuer_url)} && assertion.tenant == ${jsonencode(var.tenant_id)} && assertion.role in ['read', 'write']"

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

# Allow write-role tokens accepted by this tenant's provider to impersonate
# the VM creator service account.
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.murmur_vm_creator.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.murmur.name}/attribute.role/write"
}

# ── Read-only service account ─────────────────────────────────────────

resource "google_service_account" "murmur_readonly" {
  project      = var.project_id
  account_id   = var.readonly_service_account_id
  display_name = "Murmur Read-Only"
  description  = "Service account for murmur.dev to perform read-only operations via WIF"
}

# Allow read-role tokens accepted by this tenant's provider to impersonate
# the read-only service account.
resource "google_service_account_iam_member" "wif_readonly_binding" {
  service_account_id = google_service_account.murmur_readonly.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.murmur.name}/attribute.role/read"
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

# Murmur's permissions in this project are split by what they can reach. The
# reads below hold project-wide, because the calls that need them are
# project-level (list, operation polling) or read images Murmur did not create
# (a base image the customer registered). Everything that creates, changes,
# boots or destroys a resource is in vm_lifecycle_scoped instead, bound under a
# condition that names Murmur's own resources.
#
# The vm_lifecycle_scoped binding is created first, so no apply has a moment
# where this role has already lost a permission the scoped binding does not
# grant yet.
resource "google_project_iam_custom_role" "vm_lifecycle" {
  project     = var.project_id
  role_id     = "murmurVmCreator"
  title       = "Murmur VM Creator"
  description = "Project-wide reads Murmur needs to manage VM lifecycle via WIF."
  permissions = [
    "compute.disks.get",            # read a bake VM boot disk's source image identity
    "compute.disks.list",           # find the hydration disks a dead worker abandoned
    "compute.globalOperations.get", # poll global operations
    "compute.images.get",           # check for a cached image; read a boot image's size
    "compute.images.list",          # enumerate the tenant's images by label when the tenant is deleted
    "compute.images.useReadOnly",   # boot from a base image, which need not be Murmur's
    "compute.instances.get",        # read VM state
    "compute.instances.list",       # list VMs (discovery + cleanup)
    "compute.machineTypes.get",     # read a machine shape's RAM (sizes the suspend snapshot Murmur bills)
    "compute.snapshots.get",        # read snapshot state (idempotency guard on retry; owner label before restoring a preserved disk)
    "compute.snapshots.list",       # enumerate the tenant's snapshots by label when the tenant is deleted
    "compute.subnetworks.use",      # attach the VM NIC to a subnetwork (same project; cross-project via network_user)
    "compute.zoneOperations.get",   # poll zonal operations
  ]

  depends_on = [google_project_iam_member.vm_lifecycle_scoped]
}

resource "google_project_iam_member" "vm_lifecycle" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_lifecycle.id
  member  = "serviceAccount:${google_service_account.murmur_vm_creator.email}"
}

# Every instance, disk, image and snapshot Murmur creates is named murmur-*:
# instances murmur-<8 hex>, boot disks after their instance, cached images
# murmur-<tenant>-<hash>, snapshots <image>-snap or <instance>-<hash>-recovery,
# hydration disks murmur-hydrate-<uuid>. A customer's own VMs, disks, images
# and snapshots are not. So the permissions that could run code on, destroy,
# re-tag, or read the data of a resource name the resources they may act on.
# For a create, the name checked is the name of the resource being created.
#
# The condition matches the last path segment, not the whole resource name:
# extract spans the zone, which a prefix cannot, and a name-wide prefix would
# also match every resource in a project whose own ID starts with murmur-.
locals {
  murmur_named_collections = {
    "compute.googleapis.com/Disk"     = "disks"
    "compute.googleapis.com/Image"    = "images"
    "compute.googleapis.com/Instance" = "instances"
    "compute.googleapis.com/Snapshot" = "snapshots"
  }
}

resource "google_project_iam_custom_role" "vm_lifecycle_scoped" {
  project     = var.project_id
  role_id     = "murmurVmCreatorScoped"
  title       = "Murmur VM Creator (Murmur-named resources)"
  description = "Create, change and delete Murmur's own instances, disks, images and snapshots, and nothing else."
  permissions = [
    # Agent VM lifecycle
    "compute.disks.create",                # create the VM boot disk; image hydration's scratch disk
    "compute.disks.resize",                # auto-expand: grow the boot disk past the base image floor
    "compute.disks.setLabels",             # label the boot disk (tenant tagging)
    "compute.instances.create",            # create the VM
    "compute.instances.delete",            # delete the VM
    "compute.instances.resume",            # resume a suspended VM (wake)
    "compute.instances.setLabels",         # label the VM at creation
    "compute.instances.setMetadata",       # set VM metadata
    "compute.instances.setServiceAccount", # attach the runtime service account
    "compute.instances.setTags",           # set network tags at creation
    "compute.instances.start",             # start a stopped VM
    "compute.instances.stop",              # stop a VM before imaging
    "compute.instances.suspend",           # suspend a VM (sleep)

    # Image baking and disk-preserving recovery
    "compute.disks.createSnapshot",  # snapshot the boot disk
    "compute.images.create",         # create a cached image
    "compute.images.delete",         # delete a cached image
    "compute.images.setLabels",      # label the image at creation
    "compute.snapshots.create",      # create a snapshot (transitive with disks.createSnapshot)
    "compute.snapshots.delete",      # delete the intermediate snapshot
    "compute.snapshots.setLabels",   # label the snapshot at creation
    "compute.snapshots.useReadOnly", # create an image, or boot a recovered VM, from a snapshot
  ]
}

resource "google_project_iam_member" "vm_lifecycle_scoped" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_lifecycle_scoped.id
  member  = "serviceAccount:${google_service_account.murmur_vm_creator.email}"

  condition {
    title      = "murmur_named_resources_only"
    expression = join(" || ", [for type, collection in local.murmur_named_collections : "(resource.type == '${type}' && resource.name.extract('/${collection}/{name}').startsWith('murmur-'))"])
  }
}

# After baking an image, Murmur pre-warms ("hydrates") it in each zone agents
# spawn in, so the first VM off a fresh image boots at full speed instead of
# streaming the image on demand. Hydration creates a throwaway disk named
# murmur-hydrate-<uuid> per zone and deletes it again.
#
# That is the only disk Murmur ever deletes — every other disk in this project
# is a live agent's boot disk. So the delete names what it may delete rather
# than being granted over the project, and it is a separate role because an IAM
# condition attaches to a binding, not to a permission. Without this role bakes
# still succeed; they lose the pre-warm and leave the scratch disks behind.
resource "google_project_iam_custom_role" "hydration_cleanup" {
  project     = var.project_id
  role_id     = "murmurVmCreatorHydrationCleanup"
  title       = "Murmur VM Creator hydration cleanup"
  description = "Delete the throwaway disks image hydration created, and nothing else."
  permissions = ["compute.disks.delete"]
}

resource "google_project_iam_member" "hydration_cleanup" {
  project = var.project_id
  role    = google_project_iam_custom_role.hydration_cleanup.id
  member  = "serviceAccount:${google_service_account.murmur_vm_creator.email}"

  # IAM conditions are restricted CEL: resource.name supports startsWith,
  # endsWith, extract, == and !=, and nothing else — a regex is rejected at
  # apply with "undeclared reference to 'matches'". extract is what spans the
  # zone, which a prefix cannot; the binding is already project-scoped, so the
  # name only has to say which disks within it.
  condition {
    title      = "hydration_disks_only"
    expression = "resource.type == 'compute.googleapis.com/Disk' && resource.name.extract('/disks/{disk}').startsWith('murmur-hydrate-')"
  }
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
