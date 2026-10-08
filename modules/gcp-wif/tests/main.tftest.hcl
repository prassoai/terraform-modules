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
    condition     = contains(google_project_iam_custom_role.vm_lifecycle.permissions, "compute.disks.create")
    error_message = "Hydration creates the scratch disk it later deletes."
  }
}
