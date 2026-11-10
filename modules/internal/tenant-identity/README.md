# Internal customer WIF tenant resolution

Implementation helper shared by `gcp-wif` and `aws-wif`, not a separate customer
configuration interface. Each cloud module accepts its established `tenant_id`
provider/login namespace and resolves it here using GitHub's public account API.
A `terraform_data` resource records the canonical `{provider, subject_id}`
pair in Terraform state and returns it as `identity`; cloud
modules record that pair in their `tenant_identity` output and use it for trust.
Numeric namespace segments remain logins and are always looked up.

GitHub credentials are not required. Unknown accounts, network/API errors,
rate limits, invalid IDs, and incompatible account types fail the plan. Only
`github_app` and `github_oauth` namespace providers are supported; unsupported
providers fail explicitly. This helper performs no membership authorization.

Run `terraform init -backend=false && terraform test` for mock-provider tests.
