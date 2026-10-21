mock_provider "google" {}

variables {
  project_id          = "customer-vms"
  tenant_id           = "github_app/acme"
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
    condition     = contains(google_project_iam_custom_role.vm_lifecycle_scoped.permissions, "compute.disks.create")
    error_message = "Hydration creates the scratch disk it later deletes."
  }
}

# The VM creator runs in the customer's own project, beside VMs, disks, images
# and snapshots that are not Murmur's. Whatever can run code on a resource
# (setMetadata is a startup script), destroy it, re-tag it into another
# firewall rule, or read its data (snapshots.useReadOnly) must reach only the
# resources Murmur created, all of which it names murmur-*. A name-wide prefix
# is not enough: a project whose own ID starts with murmur- would put every
# resource in it under murmur-.
#
# IAM evaluates the condition, so these assertions evaluate it: each probe is a
# resource name GCE would check, and the expression in the plan must allow it
# exactly when the probe says. The evaluator understands one form of clause,
# the one restricted CEL offers for this — resource.type == T &&
# resource.name.extract('/collection/{x}').startsWith(P) — and the expression
# must consist of nothing else, so a clause it cannot read fails the run rather
# than being skipped.
run "resource_mutations_reach_only_murmur_named_resources" {
  command = plan

  variables {
    murmur_named_probes = [
      { type = "compute.googleapis.com/Instance", name = "projects/customer-vms/zones/us-central1-a/instances/murmur-0a1b2c3d", allowed = true },
      { type = "compute.googleapis.com/Disk", name = "projects/customer-vms/zones/us-central1-a/disks/murmur-0a1b2c3d", allowed = true },
      { type = "compute.googleapis.com/Disk", name = "projects/customer-vms/zones/us-central1-b/disks/murmur-hydrate-6f1c0d2e-9a7b-4c3d-8e5f-0a1b2c3d4e5f", allowed = true },
      { type = "compute.googleapis.com/Image", name = "projects/customer-vms/global/images/murmur-abcdefghij-0123456789abcdef", allowed = true },
      { type = "compute.googleapis.com/Snapshot", name = "projects/customer-vms/global/snapshots/murmur-abcdefghij-0123456789abcdef-snap", allowed = true },
      { type = "compute.googleapis.com/Snapshot", name = "projects/customer-vms/global/snapshots/murmur-0a1b2c3d-0123456789ab-recovery", allowed = true },

      { type = "compute.googleapis.com/Instance", name = "projects/customer-vms/zones/us-central1-a/instances/payroll-db", allowed = false },
      { type = "compute.googleapis.com/Disk", name = "projects/customer-vms/zones/us-central1-a/disks/payroll-db", allowed = false },
      { type = "compute.googleapis.com/Image", name = "projects/customer-vms/global/images/golden-base", allowed = false },
      { type = "compute.googleapis.com/Snapshot", name = "projects/customer-vms/global/snapshots/payroll-db-nightly", allowed = false },
      { type = "compute.googleapis.com/Instance", name = "projects/murmur-customer/zones/us-central1-a/instances/payroll-db", allowed = false },
      { type = "compute.googleapis.com/Instance", name = "projects/customer-vms/zones/us-central1-a/instances/payroll-murmur-db", allowed = false },
      { type = "compute.googleapis.com/Firewall", name = "projects/customer-vms/global/firewalls/murmur-allow-all", allowed = false },
      { type = "compute.googleapis.com/Disk", name = "projects/customer-vms/zones/us-central1-a/instances/murmur-0a1b2c3d", allowed = false },
    ]
  }

  assert {
    condition = alltrue([
      for clause in split("||", one(google_project_iam_member.vm_lifecycle_scoped.condition).expression) :
      can(regex("^\\(resource\\.type == '[^']+' && resource\\.name\\.extract\\('/[a-z]+/\\{[a-z]+\\}'\\)\\.startsWith\\('[^']+'\\)\\)$", trimspace(clause)))
    ])
    error_message = "Every clause of the scoped condition must name a resource type and a name prefix; a clause of any other form cannot be checked here."
  }
  assert {
    condition = alltrue([
      for probe in var.murmur_named_probes :
      anytrue(flatten([
        for clause in split("||", one(google_project_iam_member.vm_lifecycle_scoped.condition).expression) : [
          for match in regexall("resource\\.type == '([^']+)' && resource\\.name\\.extract\\('/([a-z]+)/\\{[a-z]+\\}'\\)\\.startsWith\\('([^']+)'\\)", clause) :
          match[0] == probe.type && startswith(try(regex("/${match[1]}/([^/]+)$", probe.name)[0], ""), match[2])
        ]
      ])) == probe.allowed
    ])
    error_message = "The scoped condition must allow exactly the Murmur-named probes."
  }
}

# Each permission below acts on one named resource, so it must be granted under
# the scoped condition and not by the project-wide role: granting it there as
# well would make the condition decorative.
run "resource_mutations_are_not_granted_project_wide" {
  command = plan

  assert {
    condition = length(setintersection(google_project_iam_custom_role.vm_lifecycle.permissions, [
      "compute.disks.create", "compute.disks.createSnapshot", "compute.disks.delete", "compute.disks.resize", "compute.disks.setLabels",
      "compute.images.create", "compute.images.delete", "compute.images.setLabels",
      "compute.instances.create", "compute.instances.delete", "compute.instances.resume", "compute.instances.setLabels",
      "compute.instances.setMetadata", "compute.instances.setServiceAccount", "compute.instances.setTags",
      "compute.instances.start", "compute.instances.stop", "compute.instances.suspend",
      "compute.snapshots.create", "compute.snapshots.delete", "compute.snapshots.setLabels", "compute.snapshots.useReadOnly",
    ])) == 0
    error_message = "A permission that changes, boots, destroys or reads the data of a resource must not be granted project-wide."
  }
}

# Confinement must not take away anything provisioning, baking, suspend and
# resume, disk resize, recovery or tenant deletion calls. A permission dropped
# from both roles fails a bake or a spawn minutes in, with a 403 from GCE.
run "provisioning_keeps_every_permission_it_calls" {
  command = plan

  assert {
    condition = length(setsubtract([
      "compute.disks.create", "compute.disks.createSnapshot", "compute.disks.get", "compute.disks.list", "compute.disks.resize", "compute.disks.setLabels",
      "compute.globalOperations.get",
      "compute.images.create", "compute.images.delete", "compute.images.get", "compute.images.list", "compute.images.setLabels", "compute.images.useReadOnly",
      "compute.instances.create", "compute.instances.delete", "compute.instances.get", "compute.instances.list", "compute.instances.resume",
      "compute.instances.setLabels", "compute.instances.setMetadata", "compute.instances.setServiceAccount", "compute.instances.setTags",
      "compute.instances.start", "compute.instances.stop", "compute.instances.suspend",
      "compute.machineTypes.get",
      "compute.snapshots.create", "compute.snapshots.delete", "compute.snapshots.get", "compute.snapshots.list", "compute.snapshots.setLabels", "compute.snapshots.useReadOnly",
      "compute.subnetworks.use", "compute.zoneOperations.get",
    ], setunion(google_project_iam_custom_role.vm_lifecycle.permissions, google_project_iam_custom_role.vm_lifecycle_scoped.permissions))) == 0
    error_message = "Every permission Murmur's provisioner calls must be granted by the VM lifecycle role or its scoped sibling."
  }
}
