# aws-wif — Single-Tenant OIDC Federation for Customer AWS Accounts

This module creates a single-tenant OIDC federation for a customer's own
AWS account. It is the AWS counterpart to [`gcp-wif`](../gcp-wif/).

**The trust policy scopes access to exactly one murmur tenant.** The IAM
role's `Condition` block uses `StringEquals` on the OIDC `sub` claim
(`"write:{tenant_id}"` or `"read:{tenant_id}"`), so only tokens minted
for that tenant can assume the role. This is the cryptographic isolation
boundary for customer-hosted VMs — no other tenant can create, terminate,
or inspect instances in this account.

## Security boundaries

The VM-creator role applies two independent EC2 boundaries:

- `RunInstances` may reference only the configured
  `placement_subnet_ids` and `placement_security_group_id`. The module resolves
  their exact ARNs through AWS, including the distinct owners in a shared VPC.
- `murmur=true` is the authorization boundary for lifecycle operations on
  existing resources, including start, stop, and terminate. Instances keep
  their original subnet and security groups when restarted.

Every instance, volume, and network interface created by the role must carry
`murmur=true` from creation. The role cannot perform lifecycle operations on
customer resources that do not carry that tag.

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

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=main"

  tenant_id                   = "github_app/acme"
  placement_subnet_ids        = ["subnet-0aaa", "subnet-0bbb"]
  placement_security_group_id = "sg-0def456"
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
| `placement_subnet_ids` | Subnets the VM-creator role may reference in `RunInstances` | required |
| `placement_security_group_id` | Security group the VM-creator role may reference in `RunInstances` | required |

## Outputs

| Output | Description |
|--------|-------------|
| `role_arn` | VM creator role ARN for CustomerPlacement config |
| `readonly_role_arn` | Read-only role ARN for CustomerPlacement config |
| `instance_profile_arn` | VM runtime instance profile ARN for EC2 RunInstances |
| `vm_runtime_role_name` | VM runtime role name for per-environment policy attachments |
| `oidc_provider_arn` | OIDC provider ARN for audit/trust reference |
| `placement` | **Sync-ready** Murmur Placement (protojson). `null` until `placement_name` is set |

## Sync-ready placement

Instead of hand-copying the role/profile ARNs above into a Placement, set the
`placement_*` inputs and pipe the assembled `placement` output straight into the
CLI:

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=v0.2.0"

  tenant_id = "github_app/acme"
  # ... existing role/profile/oidc inputs ...

  placement_name              = "customer-aws-east"   # must not start with "murmur-"
  placement_region            = "us-east-1"
  placement_vpc_id            = "vpc-0abc123"
  placement_subnet_ids        = ["subnet-0aaa", "subnet-0bbb"]
  placement_security_group_id = "sg-0def456"
}
```

```sh
terraform output -json placement | murmur set placement customer-aws-east
```

`account_id` is derived from the VM-creator role ARN. The VPC and region are used
to build the placement output; subnet and security-group inputs also restrict the
VM-creator IAM policy. None are created by this module. The runtime
instance-profile binding confers exactly one permission —
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

Changing these inputs alters only the rendered `placement` output — no cloud IAM
resources change. Re-sync to apply:
`terraform output -json placement | murmur set placement <name>`.

## Out of scope

- **SSM policy** — For debugging access; attached per-environment by the
  customer, not in this module.
