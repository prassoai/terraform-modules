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
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=v0.1.0"

  project_id = "customer-prod-12345"
  tenant_id  = "github_app/acme"
  vm_service_accounts = [
    "murmur-vm@customer-prod-12345.iam.gserviceaccount.com",
  ]
}
```

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=v0.1.0"

  tenant_id = "github_app/acme"
}
```

Always pin to a tag (`?ref=v0.1.0`), never to a branch. The double slash
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
