# terraform-modules

Shared Terraform modules that Murmur customers run in **their own cloud
accounts** to onboard onto Murmur. Today these are the Workload Identity
Federation (WIF) / VM-placement modules a customer applies to let Murmur
create and manage agent VMs in their GCP project or AWS account.

This repository is **private for now** and intended to become **public-readable**
soon, so everything here is written to be self-contained and safe to share —
just the resources you apply in your own account, with no secrets.

## Layout

Modules live under `modules/<name>`, one directory per module:

```
terraform-modules/
└── modules/
    ├── gcp-wif/   Single-tenant WIF for a customer's GCP project
    └── aws-wif/   Single-tenant OIDC federation for a customer's AWS account
```

## Consuming a module

Modules are consumed via a **git source**, pinned to a release tag with
`?ref=<tag>` — this repo is **not** published to the Terraform Registry.

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=<release-with-immutable-wif>"

  project_id = "acme-murmur-vms"
  tenant_id  = "github_app/acme"
  vm_service_accounts = [
    "murmur-vm@acme-murmur-vms.iam.gserviceaccount.com",
  ]
}
```

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=<release-with-immutable-wif>"

  tenant_id = "github_app/acme"
}
```

Pin to a released tag or immutable commit, never to a branch. The double slash
(`//`) separates the repository from the module subdirectory.

> **Private-repo access.** While this repository is private, `terraform init`
> must be able to fetch it over git — configure a credential (e.g. an SSH key,
> or `git config --global url."https://<token>@github.com/".insteadOf
> "https://github.com/"`). Once the repo is public-readable this is no longer
> needed.

## Versioning

Releases are tagged `vMAJOR.MINOR.PATCH`. A module's public interface (its
input variables and outputs) is the contract; breaking changes to that contract
bump the major version. Consumers pin to a tag and upgrade deliberately by
moving the `?ref=`.

## Modules

| Module | Cloud | Purpose |
|--------|-------|---------|
| [`gcp-wif`](modules/gcp-wif/) | GCP | Single-tenant WIF pool, provider, service accounts, and IAM that let exactly one Murmur tenant create VMs in the customer's project. |
| [`aws-wif`](modules/aws-wif/) | AWS | Single-tenant OIDC provider and IAM roles that let exactly one Murmur tenant manage EC2 instances in the customer's account. |

## Immutable tenant identity and rollout

Requires Terraform 1.4 or later for the canonical identity record.

`tenant_id` keeps its established provider/login namespace meaning, for example
`github_app/acme`. Each cloud module resolves that human-entered namespace at
its input boundary through GitHub's public account API, records the canonical
`{provider, subject_id}` pair in its `tenant_identity` output, and uses only
that identity for cloud trust. The shared resolver is an internal implementation
helper, not an additional customer module. No subject ID transcription or
extra resolver call is required for namespace input.
Even a numeric namespace segment is a login and must be resolved.

Alternatively, supply an identity explicitly to either cloud module:

```hcl
tenant = {
  provider   = "github_app"
  subject_id = "12345678"
}
```

Set exactly one of `tenant_id` or `tenant`; omit the other (or set it to `null`).
The typed `tenant` object is recorded exactly as supplied, without a GitHub
lookup, including during normal plan/refresh. Review its provider and canonical
positive numeric subject ID independently before applying. A supplied identity
is an assertion by the operator, not proof of account existence or membership.
Both forms expose the same pinned `tenant_identity` output and use the same
issuer, customer ownership, and read/write trust contract.

Supported namespace providers are `github_app` and `github_oauth`. Unsupported
providers, failed account lookups, and invalid provider metadata fail the plan.
The first binding records and pins the resolved or supplied provider/subject pair. Review
that identity against the intended Murmur tenant before its initial apply.
Ordinary refreshes compare the locator's current owner to the pin and fail
closed on a difference; they do not update trust. A rename is safe when the
updated `tenant_id` resolves to the same pinned account. A reassigned login,
changed locator, or provider change cannot redirect established trust. Direct
`tenant` edits also fail closed when they change the pinned provider or subject.
Switching between input forms is allowed when both identify the same pinned owner.

A different owner requires an explicit rebind. Pause operations, verify the
new intended owner independently, update the chosen `tenant_id` or `tenant`, and generate a reviewed
plan that explicitly replaces only the module's canonical identity record:

```sh
terraform plan -replace='module.murmur_wif.module.tenant_identity.terraform_data.identity' -out=customer-wif-rebind.tfplan
```

Substitute the actual cloud module address (`module.murmur_wif` here). For
both clouds, explicitly name both identity records with separate `-replace`
options. Authorized operators may apply that reviewed plan after approval.
Do not delete state or destroy IAM resources to bypass the pin. A normal
plan/apply that selects a different owner must fail for either input form.
Explicit replacement records the newly resolved or supplied owner.

Customer WIF encodes the pinned address as `tenant:provider/subject_id` in the
`tenant` claim and GCP subject, and `read:tenant:provider/subject_id` or
`write:tenant:provider/subject_id` in AWS subjects. The `tenant:` marker belongs
only to this WIF encoding; the recorded pair and canonical tenant addresses
remain unchanged. It separates new customer trust from legacy customer tokens
for numeric logins, which can otherwise spell a namespace identically to an
immutable address. This format overlap is verified; no affected customer
inventory has been established.

This is an intentional breaking change to customer placement trust. Existing
namespace-based customer trust is unsupported; no legacy/canonical dual trust
is installed. Operators must coordinate a maintenance window, pause customer
placement operations (including image accounting), upgrade both the Murmur
issuer and these modules, plan and apply the customer IAM changes, and resume
only after read and write federation succeed for the intended tenant. Tokens
issued before the issuer upgrade expire after one hour. Upgrade the module
source pin to a release containing this change; old release tags still use
namespace trust. Customers must explicitly authorize and run their own apply.
Platform WIF policies and authority are unchanged.

Customer issuer URLs are derived from the configured HTTPS origin and pinned
identity: `<origin>/platform/<provider>/<subject_id>`. The public issuer URL
inputs name the origin. Upgrading to tenant issuers changes the AWS OIDC provider
URL (and therefore its ARN); operators must review the replacement and matching
role trust updates together. GCP updates its provider issuer in place. Publish
and verify tenant discovery and the provisioning JWKS before applying trust.

Both customer cloud modules use `issuer_base_url` for the HTTPS origin and expose
`issuer_url` for the resulting tenant issuer. Rename earlier `murmur_issuer_url`
(GCP) or `oidc_issuer_url` (AWS) settings when upgrading. The `tenant_id`
provider/login contract and the recorded owner remain independent of the origin.
