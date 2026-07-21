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

WIF-only — no murmur provider block or credentials needed (see
[Placement sync](#placement-sync) below to also manage the Placement):

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=v0.3.0"

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
| `placement` | The Murmur Placement document (protojson) this module syncs. `null` until `placement_name` is set |

## Placement sync

Setting `placement_name` means the module **manages the Placement in the murmur
catalog on `terraform apply`** — it is created on the first apply and updated on
every subsequent one. There is no separate sync step: drift (a grant edit, a
subnet change, a WIF scalar change) shows up in `terraform plan` as an in-place
update to `murmur_catalog_resource.placement[0]` and applies with everything
else.

Syncing requires a `provider "murmur"` block — the `tenant` is the same
`{provider}/{org}` string as the module's `tenant_id`:

```hcl
terraform {
  required_providers {
    murmur = { source = "prassoai/murmur", version = "~> 0.1" }
  }
}

provider "murmur" {
  tenant = "github_app/acme" # {provider}/{org} — same string as module tenant_id
}

module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=v0.3.0"

  project_id          = "customer-prod-12345"
  tenant_id           = "github_app/acme"
  vm_service_accounts = ["murmur-vm@customer-prod-12345.iam.gserviceaccount.com"]

  placement_name   = "customer-gcp-east"   # must not start with "murmur-"
  placement_zones  = ["us-east1-b", "us-east1-c"]
  placement_subnet = "projects/customer-prod-12345/regions/us-east1/subnetworks/agents"
}
```

**Credentials**: the provider uses `MURMUR_API_KEY` from the environment if
non-empty, otherwise your local `gh auth token`. On a laptop there is nothing to
configure — `gh` is the credential. In CI, export a `mur_` service-profile API
key as `MURMUR_API_KEY`; you can additionally set `auth = "api_key"` in the
provider block as an optional hard pin so `gh` is never probed.

**WIF-only usage** (no `placement_name`) needs no `provider "murmur"` block and
no murmur credentials — the only cost is the provider download at
`terraform init`.

**Adopting an already-piped placement**: if the placement was previously synced
with `terraform output | murmur set` (or created any other way), the create
fails with an instruction to import. Adopt it — no delete/recreate:

```sh
terraform import 'module.murmur_wif.murmur_catalog_resource.placement[0]' placement/customer-gcp-east
```

**Stopping management without deleting** (demotion): clearing `placement_name`
removes the resource from configuration, and the plan for that is a *destroy* of
the catalog placement. To stop managing it from terraform but keep it in the
catalog, drop it from state first:

```sh
terraform state rm 'module.murmur_wif.murmur_catalog_resource.placement[0]'
```

then clear `placement_name`.

**No direct write permission?** The `placement` output is still the full
document. Propose it as a change request instead of writing directly:

```sh
terraform output -json placement | murmur set placement customer-gcp-east --propose --rationale "..."
```

Each runtime SA's binding confers exactly one permission — `placement-sa.assume`
(the only meaningful binding verb) — so you choose only the principals. By default
every tenant member may spawn (`default_spawn_grant` ⇒ the `murmur-all-members`
group), and so may every service-profile controller (`service_profiles` ⇒ `["*"]`).
Override `default_spawn_grant` for all SAs, or `spawn_grants_by_sa` (keyed by SA
email) to scope a privileged SA to named users or profiles while the rest stay on
the default. Additional placement inputs: `placement_assign_public_ip`,
`placement_description`, and `network_project` (shared from the WIF inputs).

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
  "murmur-vm-privileged@customer-prod-12345.iam.gserviceaccount.com" = {
    users            = ["alice"]
    service_profiles = ["forensics-bot"]
  }
}
```

Changing these inputs alters only the rendered placement document — no cloud IAM
resources change. The plan shows the catalog update; `terraform apply` pushes it.

## Notes

- **`tenant_id`** comes from `murmur tenant whoami` or the dashboard.
- The `murmurVmCreator` custom role is intentionally tight. If a future Murmur
  release needs an additional compute permission, upgrade to the module version
  (`?ref=`) that includes it.

[wif]: https://cloud.google.com/iam/docs/workload-identity-federation
