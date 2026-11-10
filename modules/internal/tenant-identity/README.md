# Internal customer WIF tenant resolution

Implementation helper shared by `gcp-wif` and `aws-wif`, not a separate customer
configuration interface. Each cloud module accepts its established `tenant_id`
provider/login namespace and resolves it here using GitHub's public account API.

A `terraform_data` record pins the first canonical `{provider, subject_id}` pair.
`ignore_changes` retains that input on ordinary refreshes, and an output
precondition rejects a refreshed lookup that names a different owner. Its
`identity` output exposes only the pinned pair to cloud trust. Numeric namespace
segments remain logins. A rename may select the same owner; a different login
or provider must not select another owner without explicit `-replace` of the
identity record. See the repository rollout/rebind instructions. Replacement
uses the newly resolved input and establishes the new authoritative pin.

GitHub credentials are not required. Unknown accounts, network/API errors,
rate limits, invalid IDs, and incompatible account types fail the plan. Only
`github_app` and `github_oauth` namespace providers are supported. This helper
performs no membership authorization and adds no WIF prefix to canonical IDs.

Run `terraform init -backend=false && terraform test` for mock-provider tests.
