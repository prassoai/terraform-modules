# aws-wif — Single-Tenant OIDC Federation for Customer AWS Accounts

This module creates a single-tenant OIDC federation for a customer's own
AWS account. It is the AWS counterpart to [`gcp-wif`](../gcp-wif/).

**The trust policy scopes access to exactly one murmur tenant.** The IAM
role's `Condition` block uses `StringEquals` on the OIDC `sub` claim
(`"write:{tenant_id}"` or `"read:{tenant_id}"`), so only tokens minted
for that tenant can assume the role. This is the cryptographic isolation
boundary for customer-hosted VMs — no other tenant can create, terminate,
or inspect instances in this account.

## What it creates

| Resource | Purpose |
|----------|---------|
| `aws_iam_openid_connect_provider` | Trusts the murmur OIDC issuer for web identity federation |
| `aws_iam_role` (creator) | Assumed via OIDC to manage EC2 instances — scoped to one tenant |
| `aws_iam_role` (readonly) | Assumed via OIDC for read-only EC2 operations — scoped to one tenant |
| `aws_iam_role_policy` (EC2 lifecycle) | EC2 permissions: run/terminate/start/stop/describe/tag/image/snapshot |
| `aws_iam_role_policy` (EC2 readonly) | EC2 read permissions: describe instances/status/images |
| `aws_iam_role` (runtime) | Assumed by VMs at boot (minimal, placeholder for future permissions) |
| `aws_iam_instance_profile` | Instance profile wrapping the runtime role |

## Thumbprint

AWS requires the SHA-1 fingerprint of the OIDC issuer's TLS certificate
chain when creating an OIDC provider. This module auto-computes it using
the `tls_certificate` data source at plan time — no hardcoded value needed.

It pins the **issuing CA** fingerprints (intermediate + root, `is_ca == true`),
never the leaf. The issuer serves short-lived (~90-day) Google Trust Services
leaf certs, so pinning the leaf would churn `thumbprint_list` on every renewal —
a recurring in-place `terraform plan` diff. The CA certs (e.g. the GTS WR3
intermediate) only rotate when GTS rotates its CA, so the pinned list stays
stable across leaf renewals.

AWS also validates OIDC issuers via its trusted CA library for certificates
from recognized CAs (added 2023). The thumbprint is a belt-and-suspenders
fallback. To verify the pinned CA thumbprint(s) manually:

```sh
openssl s_client -servername oidc.murmur.dev -showcerts \
  -connect oidc.murmur.dev:443 </dev/null 2>/dev/null |
  openssl x509 -fingerprint -sha1 -noout |
  sed 's/://g; s/sha1 Fingerprint=//i'
```

This prints the leaf fingerprint; the chain's `-showcerts` output also includes
the issuing CA cert(s) — those are what `thumbprint_list` pins. Compare against
the `thumbprint_list` in `terraform plan` output (it should not contain the
leaf fingerprint).

## Audience

The `oidc_audience` variable controls the expected `aud` claim in OIDC
tokens. It defaults to `sts.amazonaws.com` (the standard AWS convention
for web identity federation).

**The audience must match.** Murmur mints tokens with an `aud` claim, and
this value must equal it. The audience configured here and the audience in
the minted tokens must agree — a mismatch silently prevents
`AssumeRoleWithWebIdentity`.

## Usage

Federation-only — no murmur provider block or credentials needed (see
[Placement sync](#placement-sync) below to also manage the Placement):

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=v0.3.0"

  tenant_id = "github_app/acme"
}
```

## Inputs

| Variable | Description | Default |
|----------|-------------|---------|
| `tenant_id` | Murmur tenant identity namespace (required) | — |
| `role_name` | IAM role name for VM creation | `"murmur-vm-creator"` |
| `readonly_role_name` | IAM role name for read-only operations | `"murmur-readonly"` |
| `instance_profile_name` | Instance profile name for VM runtime | `"murmur-vm"` |
| `oidc_issuer_url` | OIDC issuer URL | `"https://oidc.murmur.dev"` |
| `oidc_audience` | Expected aud claim | `"sts.amazonaws.com"` |
| `ec2_permissions_boundary_arn` | Optional permissions boundary for all roles | `null` |
| `extra_policies` | Additional policy ARNs for the creator role | `[]` |

## Outputs

| Output | Description |
|--------|-------------|
| `role_arn` | VM creator role ARN for CustomerPlacement config |
| `readonly_role_arn` | Read-only role ARN for CustomerPlacement config |
| `instance_profile_arn` | VM runtime instance profile ARN for EC2 RunInstances |
| `vm_runtime_role_name` | VM runtime role name for per-environment policy attachments |
| `oidc_provider_arn` | OIDC provider ARN for audit/trust reference |
| `placement` | The Murmur Placement document (protojson) this module syncs. `null` until `placement_name` is set |

## Placement sync

Setting `placement_name` means the module **manages the Placement in the murmur
catalog on `terraform apply`** — it is created on the first apply and updated on
every subsequent one. There is no separate sync step: drift (a grant edit, a
subnet change, a rotated role ARN) shows up in `terraform plan` as an in-place
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
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=v0.3.0"

  tenant_id = "github_app/acme"
  # ... existing role/profile/oidc inputs ...

  placement_name              = "customer-aws-east"   # must not start with "murmur-"
  placement_region            = "us-east-1"
  placement_vpc_id            = "vpc-0abc123"
  placement_subnet_ids        = ["subnet-0aaa", "subnet-0bbb"]
  placement_security_group_id = "sg-0def456"
}
```

**Credentials**: the provider uses `MURMUR_API_KEY` from the environment if
non-empty, otherwise your local `gh auth token`. On a laptop there is nothing to
configure — `gh` is the credential. In CI, export a `mur_` service-profile API
key as `MURMUR_API_KEY`; you can additionally set `auth = "api_key"` in the
provider block as an optional hard pin so `gh` is never probed.

**Federation-only usage** (no `placement_name`) needs no `provider "murmur"`
block and no murmur credentials — the only cost is the provider download at
`terraform init`.

**Adopting an already-piped placement**: if the placement was previously synced
with `terraform output | murmur set` (or created any other way), the create
fails with an instruction to import. Adopt it — no delete/recreate:

```sh
terraform import 'module.murmur_wif.murmur_catalog_resource.placement[0]' placement/customer-aws-east
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
terraform output -json placement | murmur set placement customer-aws-east --propose --rationale "..."
```

`account_id` is derived from the VM-creator role ARN. The VPC/subnet/security-group/region
are not created by this module, so they are taken as inputs and used only to build
the document. The runtime instance-profile binding confers exactly one permission —
`placement-sa.assume` (the only meaningful binding verb) — so you choose only the
principals. By default every tenant member may spawn (`default_spawn_grant` ⇒ the
`murmur-all-members` group), and so may every service-profile controller
(`service_profiles` ⇒ `["*"]`); override `default_spawn_grant` to scope it.

### Service profiles

Service-profile controllers (API keys, webhook- and schedule-driven automation)
authorize as the profile principal and carry no group membership, so a placement
whose binding only grants groups/users can never launch VMs for them. The
`service_profiles` attribute takes **bare profile names** — the module renders the
`service-profile:` principals, so you never type the prefix (validation rejects
it, in `users` too):

| `service_profiles` value | Meaning |
| ------------------------ | ------- |
| omitted                  | all service-profile controllers may spawn (default) |
| `[]`                     | no service-profile controller may spawn |
| `["infra-bot", "ci"]`    | exactly these profiles' controllers may spawn |

These principals match only the profile's controller credential, never agent VMs
carrying a profile claim, so per-agent VM isolation is preserved. A human
borrowing a profile (e.g. `murmur bake --service-profile`) authorizes as
themselves and is covered by `groups`/`users`.

Changing these inputs alters only the rendered placement document — no cloud IAM
resources change. The plan shows the catalog update; `terraform apply` pushes it.

## Out of scope

- **SSM policy** — For debugging access; attached per-environment by the
  customer, not in this module.
