# GCP read issuer trust

Adds a separate WIF pool/provider and one `workloadIdentityUser` member on the
existing reader service account. It creates no service account, grants no project
permissions, and changes no legacy binding or VM-creator resource.

```hcl
module "murmur_read" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif-read?ref=<reviewed-commit>"

  tenant_id                      = "github_app/123"
  project_id                     = "customer-vms"
  readonly_service_account_email = module.murmur_wif.readonly_service_account_email
}

output "wif_readonly_provider_resource_name" {
  value = module.murmur_read.wif_readonly_provider_resource_name
}
```

Set `gcp.wif_readonly_provider_resource_name` on the existing placement from this
output, preserving its other fields and grants. Apply read trust before syncing
the output. Existing readers ignore the new field and use the unchanged
provider and reader account; new readers use the read provider and the same
account. Use distinct pool IDs if the default is taken. The account must be
the existing read-only account, never the creator or a runtime account.

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
`validate_oidc_readiness = false` permits maintenance or teardown during an
issuer outage without changing any trust condition.

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
