# A migration admits both reserved namespaces under the exact write and read
# subjects while retaining the audience check in each rendered IAM policy.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/murmur-vm-creator"
    }
  }
}
mock_provider "tls" {}

variables {
  storage_namespaces          = ["github_app/acme", "github_app/12345678"]
  placement_region            = "us-east-1"
  placement_vpc_id            = "vpc-0abc123"
  placement_subnet_ids        = ["subnet-0aaa"]
  placement_security_group_id = "sg-0def456"
}

run "migration_namespaces" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.vm_creator.assume_role_policy).Statement[0].Condition.StringEquals["oidc.murmur.dev:sub"] == ["write:github_app/acme", "write:github_app/12345678"] && jsondecode(aws_iam_role.vm_creator.assume_role_policy).Statement[0].Condition.StringEquals["oidc.murmur.dev:aud"] == "sts.amazonaws.com"
    error_message = "The creator role must trust only both exact write subjects under the configured audience."
  }

  assert {
    condition     = jsondecode(aws_iam_role.readonly.assume_role_policy).Statement[0].Condition.StringEquals["oidc.murmur.dev:sub"] == ["read:github_app/acme", "read:github_app/12345678"] && jsondecode(aws_iam_role.readonly.assume_role_policy).Statement[0].Condition.StringEquals["oidc.murmur.dev:aud"] == "sts.amazonaws.com"
    error_message = "The read-only role must trust only both exact read subjects under the configured audience."
  }
}

# Retirement removes old read and write subjects from both roles.
run "retired_namespace" {
  command = apply

  variables {
    storage_namespaces = ["github_app/12345678"]
  }

  assert {
    condition     = jsondecode(aws_iam_role.vm_creator.assume_role_policy).Statement[0].Condition.StringEquals["oidc.murmur.dev:sub"] == ["write:github_app/12345678"]
    error_message = "Retirement must leave only the destination write subject trusted."
  }

  assert {
    condition     = jsondecode(aws_iam_role.readonly.assume_role_policy).Statement[0].Condition.StringEquals["oidc.murmur.dev:sub"] == ["read:github_app/12345678"]
    error_message = "Retirement must leave only the destination read subject trusted."
  }
}
