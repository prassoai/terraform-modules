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

Always pin to a tag (`?ref=<release-with-immutable-wif>`), never to a branch. The double slash
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
helper, not an additional customer module or input contract. No subject ID
transcription or extra resolver call is required in customer configuration.
Even a numeric namespace segment is a login and must be resolved.

Supported namespace providers are `github_app` and `github_oauth`. Unsupported
providers, failed account lookups, and invalid provider metadata fail the plan.
A rename keeps its ID: update `tenant_id` to the new login. A login reassigned
to another account resolves to a different ID and produces a visible recorded
identity/trust change. Review the `tenant_identity` output and IAM plan; apply
that change only when deliberately authorizing the other account. A
`terraform_data` record stores the canonical pair in Terraform state at apply;
a data lookup does not itself grant Murmur membership or cloud authority.

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
