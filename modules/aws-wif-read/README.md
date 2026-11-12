# AWS read issuer trust

Adds a separate read-family OIDC provider, a new reader role and its four EC2
Describe permissions. Existing providers, roles, policies and instance profiles
remain owned by the pinned `aws-wif` module.

The new role accepts exactly `read:<immutable-tenant>` from both the new read
issuer and the existing tenant-specific provisioning issuer. This preserves old
readers, mixed pods and rollback after switching the placement's reader role.
It accepts neither write subjects nor tenant wildcards. The existing provider
must belong to this account and have the expected issuer and audience.

```hcl
module "murmur_read" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif-read?ref=<reviewed-commit>"

  tenant_id                      = "github_app/123"
  provisioning_oidc_provider_arn = module.murmur_wif.oidc_provider_arn
  # Copy the existing custom audience and permissions boundary, if configured.
}

output "readonly_oidc_provider_arn" {
  value = module.murmur_read.readonly_oidc_provider_arn
}

output "readonly_role_arn" {
  value = module.murmur_read.readonly_role_arn
}
```

Apply read trust and verify both reader generations, then sync both fields
together: set `aws.readonly_oidc_provider_arn` and `aws.readonly_role_arn` on the
existing placement from these outputs, preserving its other fields and grants. Do not replace
the provisioning provider or move the existing reader role into this module.
Use a unique `readonly_role_name` if the default is taken. Preserve customer
permissions boundaries and verify organization policies allow the new role.
The module grants the same four EC2 Describe operations as the existing reader,
with no instance, image or snapshot mutation.

These are additive read-trust modules for WIF read/write key separation.
Use them beside the existing pinned provisioning module. Do not change its
source, inputs, resource addresses, creator policies or runtime identities.

Prerequisites:

- Murmur has published the separate read-family keyset and tenant discovery.
- The separately reviewed customer provisioning-issuer migration is complete.
  This module does not perform that migration.
- The API supports per-placement read-family selection (murmuration #14494).
- The reviewed Terraform plan shows only this new module's resources changing.
  Existing module addresses must be no-op. Apply first in nonproduction, then
  verify old and new read tokens can inspect the same placement.

Pin these modules to a reviewed release or immutable commit. The examples
deliberately require the operator to choose that pin. Planning checks the exact
read issuer and family keyset with 10-second HTTP timeouts.
For outage maintenance, set `oidc_ca_thumbprints` to the existing verified CA
SHA-1 fingerprints, then set `validate_oidc_readiness = false`. Both HTTP
readiness checks and TLS certificate discovery are then skipped; the configured
fingerprints and exact issuer/subject/audience trust remain. Disabling readiness
without explicit fingerprints fails the plan. Pin CA fingerprints, never the
short-lived leaf certificate. The default still discovers CA fingerprints and
checks discovery/JWKS; supplying fingerprints alone skips only TLS discovery.

Keep old read trust during rollout: older pods and rollback still use it.
Remove the API's write-key authority only after all placements have migrated
and the platform closure checks pass. Reverting a placement's read fields is
safe only while the API's legacy reader remains available. After closure,
restore reads by repairing read trust.

The commands below validate configuration and use mocked cloud providers.
They do not create cloud resources or prove live STS exchange, effective IAM,
or customer organization-policy compatibility.

```sh
terraform init -backend=false
terraform validate
terraform test
```
