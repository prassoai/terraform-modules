# AWS read issuer trust

Adds a separate read-family OIDC provider, a new reader role and its four EC2
Describe permissions. Existing providers, roles, policies and instance profiles
remain owned by the pinned `aws-wif` module.

The new role accepts exactly `read:<immutable-tenant>` from both the new read
issuer and the existing tenant-specific provisioning issuer, so Murmur's reads
work with it before and after the read-family cutover (murmuration#14501) and
through a rollback of that cutover.
It accepts neither write subjects nor tenant wildcards. The existing provider
must belong to this account and have the expected issuer and audience.

```hcl
module "murmur_read" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif-read?ref=<reviewed-commit>"

  tenant_id                      = "github_app/123"
  provisioning_oidc_provider_arn = module.murmur_wif.oidc_provider_arn
  # Copy the existing custom audience and permissions boundary, if configured.
}

output "readonly_role_arn" {
  value = module.murmur_read.readonly_role_arn
}
```

Apply read trust, then set `aws.readonly_role_arn` on the existing placement
to this module's `readonly_role_arn`, preserving its other fields and grants.
Every AWS placement that needs reads must make this change before the cutover:
the existing reader role does not trust the read issuer. STS selects the read
provider from the token's issuer, so the placement records no provider. Do not
replace the provisioning provider or move the existing reader role into this module.
Use a unique `readonly_role_name` if the default is taken. Preserve customer
permissions boundaries and verify organization policies allow the new role.
The module grants the same four EC2 Describe operations as the existing reader,
with no instance, image or snapshot mutation.

These are additive read-trust modules for WIF read/write key separation.
Use them beside the existing pinned provisioning module. Do not change its
source, inputs, resource addresses, creator policies or runtime identities.

Prerequisites:

- Murmur has published the separate read-family keyset and tenant discovery.
  The module does not probe these endpoints; verify publication separately.
  A successful read with the old issuer does not verify the new read trust.
- The separately reviewed customer provisioning-issuer migration is complete.
  This module does not perform that migration.
- The reviewed Terraform plan shows only this new module's resources changing.
  Existing module addresses must be no-op. Apply first in nonproduction, then
  verify the placement's reads still succeed after switching its reader role.

Pin these modules to a reviewed release or immutable commit. The examples
deliberately require the operator to choose that pin. Like `aws-wif`, the
module reads the issuer's TLS chain during planning and pins only its CA
fingerprints, never the short-lived leaf certificate.

Keep old read trust during rollout: older pods and rollback still use it.
Remove the API's write-key authority only after every placement's read trust
is in place and the platform closure checks pass. Pointing the placement back
at the existing reader role works only until the cutover. After closure,
restore reads by repairing read trust.

The commands below validate configuration and use mocked cloud providers.
They do not create cloud resources or prove live STS exchange, effective IAM,
or customer organization-policy compatibility.

```sh
terraform init -backend=false
terraform validate
terraform test
```
