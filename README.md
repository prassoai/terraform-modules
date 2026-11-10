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

Modules are consumed via a **git source**, pinned to a release tag or immutable commit with
`?ref=<tag>` — this repo is **not** published to the Terraform Registry.

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/gcp-wif?ref=ad9876152452fb8d8905a26d768b9fadd1046bde"

  project_id = "acme-murmur-vms"
  tenant_id  = "github_app/12345678"
  vm_service_accounts = [
    "murmur-vm@acme-murmur-vms.iam.gserviceaccount.com",
  ]
}
```

```hcl
module "murmur_wif" {
  source = "git::https://github.com/prassoai/terraform-modules.git//modules/aws-wif?ref=ad9876152452fb8d8905a26d768b9fadd1046bde"

  tenant_id = "github_app/12345678"
}
```

Pin to a released tag or an immutable commit, never to a branch. The examples
use the tenant-issuer implementation commit; tags through `v0.3.0` use the old
root issuer and are incompatible with the new customer tokens. The double slash
(`//`) separates the repository from the module subdirectory.

> **Private-repo access.** While this repository is private, `terraform init`
> must be able to fetch it over git — configure a credential (e.g. an SSH key,
> or `git config --global url."https://<token>@github.com/".insteadOf
> "https://github.com/"`). Once the repo is public-readable this is no longer
> needed.

## Versioning

Releases are tagged `vMAJOR.MINOR.PATCH`. A module's public interface (its
input variables and outputs) is the contract; breaking changes to that contract
bump the major version. The tenant-specific issuer change requires the next
major release; publish it after the corresponding Murmur backend is deployed. Consumers pin to a tag and upgrade deliberately by
moving the `?ref=`.

## Modules

| Module | Cloud | Purpose |
|--------|-------|---------|
| [`gcp-wif`](modules/gcp-wif/) | GCP | Single-tenant WIF pool, provider, service accounts, and IAM that let exactly one Murmur tenant create VMs in the customer's project. |
| [`aws-wif`](modules/aws-wif/) | AWS | Single-tenant OIDC provider and IAM roles that let exactly one Murmur tenant manage EC2 instances in the customer's account. |
