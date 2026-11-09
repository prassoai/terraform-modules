# tenant-identity — resolve a GitHub tenant locator

Resolve a human-entered `github_app/acme` or `github_oauth/octocat` locator using
GitHub's public account API. No GitHub credential is required. Network failures,
rate limiting, unknown accounts, invalid IDs, and incompatible account types
fail the plan. The immutable `tenant_id` output feeds both customer WIF modules:

```hcl
module "tenant_identity" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/tenant-identity?ref=<release-with-immutable-wif>"
  tenant = "github_app/acme"
}

# In both gcp-wif and aws-wif module calls:
# tenant_id = module.tenant_identity.tenant_id
```

Review the resolved address before applying cloud trust. A rename retains the
same ID; update the locator to the new login. A reassigned login resolves to a
different ID and changes the trust plan: apply that only when intentionally
authorizing the other account. This lookup selects an account; it grants no
Murmur membership or cloud permissions by itself.

Only GitHub locators are supported by this resolver. Customers using another
identity provider pass their registered immutable Murmur tenant address directly
to the WIF modules. Never substitute a provider/login namespace for that address.

Validation: `terraform init -backend=false && terraform test`. Tests mock the
public API and never apply customer cloud resources.
