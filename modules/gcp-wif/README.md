# gcp-wif — Single-Tenant WIF for Customer GCP Projects

This module creates a single-tenant [Workload Identity Federation][wif]
configuration in a customer's own GCP project. It is the GCP counterpart to
[`aws-wif`](../aws-wif/).

**The principalSet binds the service account to exactly one Murmur tenant.**
The `roles/iam.workloadIdentityUser` binding targets
`principalSet://.../attribute.tenant/${tenant_id}`, so only OIDC tokens
carrying that tenant's claim can impersonate the VM-creator service account.
This is the cryptographic isolation boundary for customer-hosted VMs — no
other tenant can create, delete, or inspect instances in this project.

## What it creates

| Resource | Purpose |
|----------|---------|
| `google_iam_workload_identity_pool` | Pool that trusts the Murmur OIDC issuer |
| `google_iam_workload_identity_pool_provider` | OIDC provider; maps `tenant` and `role` claims |
| `google_service_account` (creator) | Impersonated by `role=write` tokens to manage VMs |
| `google_service_account` (readonly) | Impersonated by `role=read` tokens for read-only operations |
| `google_project_iam_custom_role` (`murmurVmCreator`) | Minimum VM-lifecycle + image-bake permissions |
| `google_project_iam_member` (readonly) | `roles/compute.viewer` for the read-only SA |
| `google_project_iam_member` (network_user) | `roles/compute.networkUser` on the shared-VPC host (optional) |
| `google_service_account_iam_member` (vm_sa_user) | `roles/iam.serviceAccountUser` on each VM runtime SA |

## Usage

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=v0.1.0"

  project_id = "customer-prod-12345"
  tenant_id  = "github_app/acme"

  # VM runtime service accounts the WIF SA must be able to attach at create
  # time. List every SA referenced by the placement's service_account_bindings.
  vm_service_accounts = [
    "murmur-vm@customer-prod-12345.iam.gserviceaccount.com",
  ]
}
```

## Inputs

| Variable | Description | Default |
|----------|-------------|---------|
| `project_id` | GCP project ID where VMs are created (required) | — |
| `tenant_id` | Murmur tenant identity namespace (required) | — |
| `vm_service_accounts` | VM runtime SA emails the WIF SA may attach (required) | — |
| `murmur_issuer_url` | OIDC issuer URL | `"https://oidc.murmur.dev"` |
| `pool_id` | WIF pool ID | `"murmur-pool"` |
| `provider_id` | WIF provider ID | `"murmur-provider"` |
| `service_account_id` | VM-creator service account ID | `"murmur-vm-creator"` |
| `readonly_service_account_id` | Read-only service account ID | `"murmur-readonly"` |
| `compute_roles` | Extra IAM roles for the VM-creator SA beyond the custom role | `[]` |
| `network_project` | Shared-VPC host project; grants `compute.networkUser` when set | `""` |

## Outputs

| Output | Description |
|--------|-------------|
| `wif_provider_resource_name` | WIF provider resource name — use as `wif_provider_resource_name` in the Placement |
| `service_account_email` | VM-creator SA email — use as `wif_service_account` in the Placement |
| `readonly_service_account_email` | Read-only SA email — use as `wif_readonly_service_account` in the Placement |
| `vm_service_accounts` | Echo of the runtime SA emails, each mapped to a ServiceAccountBinding |
| `placement` | **Sync-ready** Murmur Placement (protojson). `null` until `placement_name` is set |

## Sync-ready placement

Instead of hand-copying the WIF scalars above into a Placement, set the
`placement_*` inputs and pipe the assembled `placement` output straight into the
CLI:

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=v0.2.0"

  project_id          = "customer-prod-12345"
  tenant_id           = "github_app/acme"
  vm_service_accounts = ["murmur-vm@customer-prod-12345.iam.gserviceaccount.com"]

  placement_name   = "customer-gcp-east"   # must not start with "murmur-"
  placement_zones  = ["us-east1-b", "us-east1-c"]
  placement_subnet = "projects/customer-prod-12345/regions/us-east1/subnetworks/agents"
}
```

```sh
terraform output -json placement | murmur set placement customer-gcp-east
```

By default every tenant member may spawn under the runtime SA
(`murmur-all-members` granted `placement-sa.assume`). Override `vm_spawn_grants`
to scope it. Additional placement inputs: `placement_assign_public_ip`,
`placement_description`, and `network_project` (shared from the WIF inputs).

## Notes

- **`tenant_id`** comes from `murmur tenant whoami` or the dashboard.
- The `murmurVmCreator` custom role is intentionally tight. If a future Murmur
  release needs an additional compute permission, upgrade to the module version
  (`?ref=`) that includes it.

[wif]: https://cloud.google.com/iam/docs/workload-identity-federation
