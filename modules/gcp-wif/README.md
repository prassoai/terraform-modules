# gcp-wif — Single-Tenant WIF for Customer GCP Projects

This module creates a single-tenant [Workload Identity Federation][wif]
configuration in a customer's own GCP project. It is the GCP counterpart to
[`aws-wif`](../aws-wif/).

The provider accepts only the configured immutable tenant address and customer
infrastructure ownership. Separate role bindings grant read tokens access to
the read-only service account and write tokens access to the VM creator.

Set `tenant_id` to your provider/login namespace, such as `github_app/acme`.
The module resolves it at the input boundary and records the canonical
`{provider, subject_id}` pair as `tenant_identity` for cloud trust.

## Recommended: a dedicated project

Give murmur a GCP project of its own and pass it as `project_id`. The
VM-creator service account's roles are granted at project scope, so in a
project that holds only murmur's VMs, images, and disks, there is nothing of
yours for it to reach. Projects are cheap and quick to create, which makes this
the simplest isolation boundary GCP offers.

The dedicated project can still use your network: set `network_project` to
your shared-VPC host and point `placement_subnet` at one of its subnets.

On AWS a separate account is often impractical, so [`aws-wif`](../aws-wif/)
confines the VM-creator role to resources tagged `murmur=true` instead. On GCP,
the dedicated project is the recommended route.

## What it creates

| Resource | Purpose |
|----------|---------|
| `google_iam_workload_identity_pool` | Pool that trusts the Murmur OIDC issuer |
| `google_iam_workload_identity_pool_provider` | OIDC provider; maps `tenant` and `role` claims |
| `google_service_account` (creator) | Impersonated by `role=write` tokens to manage VMs |
| `google_service_account` (readonly) | Impersonated by `role=read` tokens for read-only operations |
| `google_project_iam_custom_role` (`murmurVmCreator`) | Minimum VM-lifecycle + image-bake permissions |
| `google_project_iam_custom_role` (`murmurVmCreatorHydrationCleanup`) | `compute.disks.delete`, bound under a condition limiting it to `murmur-hydrate-*` scratch disks |
| `google_project_iam_member` (readonly) | `roles/compute.viewer` for the read-only SA |
| `google_project_iam_member` (network_user) | `roles/compute.networkUser` on the shared-VPC host (optional) |
| `google_service_account_iam_member` (vm_sa_user) | `roles/iam.serviceAccountUser` on each VM runtime SA |

## Usage

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=<release-with-immutable-wif>"

  project_id = "acme-murmur-vms"
  tenant_id  = "github_app/acme"

  # VM runtime service accounts the WIF SA must be able to attach at create
  # time. List every SA referenced by the placement's service_account_bindings.
  vm_service_accounts = [
    "murmur-vm@acme-murmur-vms.iam.gserviceaccount.com",
  ]
}
```

## Inputs

| Variable | Description | Default |
|----------|-------------|---------|
| `project_id` | GCP project ID where VMs are created; use one [dedicated to murmur](#recommended-a-dedicated-project) (required) | — |
| `tenant_id` | Murmur provider/login namespace (required) | — |
| `vm_service_accounts` | VM runtime SA emails the WIF SA may attach (required) | — |
| `issuer_base_url` | HTTPS origin; the pinned identity determines the issuer path | `"https://oidc.murmur.dev"` |
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
| `issuer_url` | Exact tenant-specific provisioning issuer |
| `tenant_identity` | Pinned canonical `{provider, subject_id}` pair for cloud trust |
| `placement` | **Sync-ready** Murmur Placement (protojson). `null` until `placement_name` is set |

## Sync-ready placement

Instead of hand-copying the WIF scalars above into a Placement, set the
`placement_*` inputs and pipe the assembled `placement` output straight into the
CLI:

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=v0.2.0"

  project_id          = "acme-murmur-vms"
  tenant_id           = "github_app/acme"
  vm_service_accounts = ["murmur-vm@acme-murmur-vms.iam.gserviceaccount.com"]

  placement_name   = "customer-gcp-east"   # must not start with "murmur-"
  placement_zones  = ["us-east1-b", "us-east1-c"]
  placement_subnet = "projects/acme-murmur-vms/regions/us-east1/subnetworks/agents"
}
```

```sh
terraform output -json placement | murmur set placement customer-gcp-east
```

Each runtime SA's binding confers exactly one permission — `placement-sa.assume`
(the only meaningful binding verb) — so you choose only the principals. By default
every tenant member may spawn (`default_spawn_grant` ⇒ the `murmur-all-members`
group), and so may every service-profile controller (`service_profiles` ⇒ `["*"]`).
Override `default_spawn_grant` for all SAs, or `spawn_grants_by_sa` (keyed by SA
email) to scope a privileged SA to named users or profiles while the rest stay on
the default. Additional placement inputs: `placement_assign_public_ip`,
`placement_description`, `placement_oauth_scopes`, and `network_project` (shared
from the WIF inputs). `placement_oauth_scopes` defaults to
`["https://www.googleapis.com/auth/cloud-platform"]`; supply a different list to
limit scopes, or `[]` to attach no OAuth scopes. Scopes do not grant IAM
permissions. The placement output must be synced to a Murmur version supporting
`gcp.oauth_scopes`. Scope changes affect newly created VMs, not existing VMs.

### Service profiles

Service-profile controllers (API keys, webhook- and schedule-driven automation)
authorize as the profile principal and carry no group membership, so a placement
whose bindings only grant groups/users can never launch VMs for them. The
`service_profiles` attribute on both grant variables takes **bare profile names**
— the module renders the `service-profile:` principals, so you never type the
prefix (validation rejects it, in `users` too):

| `service_profiles` value | Meaning |
| ------------------------ | ------- |
| omitted (default grant)  | all service-profile controllers may spawn (default) |
| `[]`                     | no service-profile controller may spawn |
| `["infra-bot", "ci"]`    | exactly these profiles' controllers may spawn |

These principals match only the profile's controller credential, never agent VMs
carrying a profile claim, so per-agent VM isolation is preserved. A human
borrowing a profile (e.g. `murmur bake --service-profile`) authorizes as
themselves and is covered by `groups`/`users`. On `spawn_grants_by_sa` overrides,
`service_profiles` defaults to `[]` — a scoped SA stays scoped unless you opt it
in per profile:

```hcl
spawn_grants_by_sa = {
  "murmur-vm-privileged@acme-murmur-vms.iam.gserviceaccount.com" = {
    users            = ["alice"]
    service_profiles = ["forensics-bot"]
  }
}
```

Changing these inputs alters only the rendered `placement` output — no cloud IAM
resources change. Re-sync to apply:
`terraform output -json placement | murmur set placement <name>`.

## Notes

- **`tenant_id`** is your provider/login namespace, such as `github_app/acme`.
  `tenant_identity` records the immutable provider/subject pair resolved for trust.
- The `murmurVmCreator` custom role is intentionally tight. If a future Murmur
  release needs an additional compute permission, upgrade to the module version
  (`?ref=`) that includes it.

[wif]: https://cloud.google.com/iam/docs/workload-identity-federation

## Immutable tenant identity and rollout

Requires Terraform 1.4 or later to record the resolved identity with `terraform_data`.

`tenant_id` retains its provider/login namespace meaning. Supply a namespace
such as `github_app/acme`; the module resolves it and records the canonical
`{provider, subject_id}` pair in its `tenant_identity` output. The record pins
the first resolved owner; ordinary refreshes fail if the namespace resolves to
a different provider/subject pair. A different owner requires explicit record
replacement as described in the rollout instructions. Trust uses the WIF-only
`tenant:` prefix; the recorded identity itself has no prefix. A numeric namespace segment
is always looked up as a login, never interpreted as a subject ID.

See the repository [rollout instructions](../../README.md#immutable-tenant-identity-and-rollout)
for the intentional customer trust break and coordinated issuer/IAM upgrade.

The configured `issuer_base_url` is an HTTPS origin without a path. Rename
any earlier `murmur_issuer_url` setting to `issuer_base_url` when upgrading;
keep `tenant_id` as the provider/login locator. The `issuer_url` output names
the full tenant issuer derived from the pinned account. See the repository
[rollout and explicit rebind instructions](../../README.md#immutable-tenant-identity-and-rollout).
