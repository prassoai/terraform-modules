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

WIF-only — the module declares only the `google` provider (see
[Placement output](#placement-output) below to also emit a Placement):

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
| `placement` | Sync-ready Murmur Placement document (protojson). `null` until `placement_name` is set |

## Placement output

Setting `placement_name` makes the module assemble the full Placement from its
own WIF outputs plus the `placement_*` inputs and emit it as the `placement`
output. **The module does not write it to the murmur catalog** — it declares only
the `google` provider, and the catalog write is yours to make, either from
Terraform or from the CLI.

```hcl
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

### Managing it from Terraform

Pass the output into a `murmur_catalog_resource` in **your own** configuration.
Drift (a grant edit, a subnet change, a WIF scalar change) then shows up in
`terraform plan` as an in-place update and applies with everything else. The
provider and its `required_providers` entry are yours, not the module's:

```hcl
terraform {
  required_providers {
    murmur = { source = "prassoai/murmur", version = "~> 0.1" }
  }
}

provider "murmur" {
  tenant = "github_app/acme" # {provider}/{org} — same string as module tenant_id
}

resource "murmur_catalog_resource" "placement" {
  kind    = "placement"
  name    = module.murmur_wif.placement.name
  tenant  = "github_app/acme" # an assertion: must match the provider block's tenant
  payload = jsonencode(module.murmur_wif.placement)
}
```

`payload` takes the document as JSON and is compared semantically, so
`jsonencode` key ordering never plans a diff on its own. `tenant` is an
assertion, not a target — the RPC tenant always comes from the provider block,
and a mismatch fails before any RPC.

**Credentials**: the provider uses `MURMUR_API_KEY` from the environment if
non-empty, otherwise your local `gh auth token`. On a laptop there is nothing to
configure — `gh` is the credential. In CI, export a `mur_` service-profile API
key as `MURMUR_API_KEY`; you can additionally set `auth = "api_key"` in the
provider block as an optional hard pin so `gh` is never probed.

**Adopting a placement that already exists**: if it was created any other way,
the create fails with an instruction to import. Adopt it — no delete/recreate:

```sh
terraform import murmur_catalog_resource.placement placement/customer-gcp-east
```

### Managing it from the CLI

The output is the whole document, so you can pipe it to `murmur set` and skip the
provider entirely:

```sh
terraform output -json placement | murmur set placement customer-gcp-east
```

Add `--propose --rationale "..."` if you lack direct catalog write permission and
want a change request instead of a direct write.

**Pick one and stay with it.** A Terraform-managed placement is stamped
`managed_by = "terraform"`, and thereafter a bare `murmur set` on it is
**refused** — a hand edit declares no manager, and the server refuses any write
declaring something other than the stored marker. The refusal names the remedy;
`murmur set --force-ownership` writes anyway and *releases* the marker (clearing
it), which also means the next `terraform apply` sees the claim lost and plans a
write to re-claim it. Nothing is refused before the first Terraform apply, so the
CLI path on its own never hits this.

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
resources change. Whichever path you sync through carries the new document to the
catalog.

## Notes

- **`tenant_id`** comes from `murmur tenant whoami` or the dashboard.
- The `murmurVmCreator` custom role is intentionally tight. If a future Murmur
  release needs an additional compute permission, upgrade to the module version
  (`?ref=`) that includes it.

[wif]: https://cloud.google.com/iam/docs/workload-identity-federation
