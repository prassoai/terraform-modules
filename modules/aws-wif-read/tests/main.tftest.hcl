mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      url            = "oidc.murmur.dev/platform/github_app/123"
      client_id_list = ["sts.amazonaws.com"]
    }
  }
}
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [
        { is_ca = true, sha1_fingerprint = "0123456789012345678901234567890123456789" },
        { is_ca = false, sha1_fingerprint = "ffffffffffffffffffffffffffffffffffffffff" },
      ]
    }
  }
}
override_resource {
  target = aws_iam_openid_connect_provider.murmur_read
  values = { arn = "arn:aws:iam::111111111111:oidc-provider/oidc.murmur.dev/read/github_app/123" }
}
variables {
  tenant_id                      = "github_app/123"
  provisioning_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.murmur.dev/platform/github_app/123"
  ec2_permissions_boundary_arn   = "arn:aws:iam::111111111111:policy/customer-boundary"
}
run "both_reader_generations_keep_read_only_access" {
  command = apply
  assert {
    condition = jsondecode(aws_iam_role.readonly.assume_role_policy).Statement == [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = "arn:aws:iam::111111111111:oidc-provider/oidc.murmur.dev/read/github_app/123" }
        Condition = { StringEquals = {
          "oidc.murmur.dev/read/github_app/123:aud" = "sts.amazonaws.com"
          "oidc.murmur.dev/read/github_app/123:sub" = "read:github_app/123"
        } }
      },
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = "arn:aws:iam::111111111111:oidc-provider/oidc.murmur.dev/platform/github_app/123" }
        Condition = { StringEquals = {
          "oidc.murmur.dev/platform/github_app/123:aud" = "sts.amazonaws.com"
          "oidc.murmur.dev/platform/github_app/123:sub" = "read:github_app/123"
        } }
      }
    ]
    error_message = "Both issuers must require the exact read subject and audience, never write or a wildcard."
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.readonly_ec2.policy).Statement[0].Action) == toset([
      "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeImages", "ec2:DescribeSnapshots"
    ])
    error_message = "The new reader must retain exactly the existing four read operations."
  }
  assert {
    condition = (
      aws_iam_openid_connect_provider.murmur_read.url == "https://oidc.murmur.dev/read/github_app/123" &&
      aws_iam_openid_connect_provider.murmur_read.thumbprint_list == tolist(["0123456789012345678901234567890123456789"])
    )
    error_message = "Trust the tenant read issuer and pin only CA fingerprints, never the rotating leaf."
  }
  assert {
    condition     = aws_iam_role.readonly.permissions_boundary == var.ec2_permissions_boundary_arn
    error_message = "Retain the customer's required permissions boundary."
  }
}
run "unmigrated_root_provider_is_rejected" {
  command = plan
  variables { provisioning_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.murmur.dev" }
  expect_failures = [aws_iam_role.readonly]
}
run "another_account_provider_is_rejected" {
  command = plan
  variables { provisioning_oidc_provider_arn = "arn:aws:iam::222222222222:oidc-provider/oidc.murmur.dev/platform/github_app/123" }
  expect_failures = [aws_iam_role.readonly]
}
run "legacy_audience_mismatch_is_rejected" {
  command = plan
  override_data {
    target = data.aws_iam_openid_connect_provider.provisioning
    values = { url = "oidc.murmur.dev/platform/github_app/123", client_id_list = ["wrong-audience"] }
  }
  expect_failures = [aws_iam_role.readonly]
}
run "mutable_tenant_is_rejected" {
  command = plan
  variables { tenant_id = "github_app/acme" }
  expect_failures = [var.tenant_id]
}
