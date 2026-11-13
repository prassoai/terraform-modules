# A supplied identity must reach cloud trust with no dependency on GitHub.
mock_provider "http" {
  mock_data "http" {
    defaults = { status_code = 503, response_body = "{}" }
  }
}
mock_provider "aws" {
  mock_data "aws_subnet" {
    defaults = { arn = "arn:aws:ec2:us-east-1:111111111111:subnet/subnet-123" }
  }
  mock_data "aws_security_group" {
    defaults = { arn = "arn:aws:ec2:us-east-1:222222222222:security-group/sg-123" }
  }
}
mock_provider "tls" {}
override_resource {
  target = aws_iam_role.vm_creator
  values = { arn = "arn:aws:iam::222222222222:role/murmur-vm-creator" }
}
variables {
  tenant                      = { provider = "github_app", subject_id = "123" }
  placement_region            = "us-east-1"
  placement_subnet_ids        = ["subnet-123"]
  placement_security_group_id = "sg-123"
}
run "supplied_identity_reaches_cloud_trust" {
  command = apply
  assert {
    condition     = output.tenant_identity == var.tenant && output.issuer_url == "${var.issuer_base_url}/platform/github_app/123"
    error_message = "The supplied pair must determine both recorded identity and issuer without a successful lookup."
  }
  assert {
    condition = jsondecode(aws_iam_role.vm_creator.assume_role_policy).Statement[0].Condition.StringEquals == {
      "${replace(var.issuer_base_url, "https://", "")}/platform/github_app/123:aud" = "sts.amazonaws.com"
      "${replace(var.issuer_base_url, "https://", "")}/platform/github_app/123:sub" = "write:tenant:github_app/123"
      } && jsondecode(aws_iam_role.readonly.assume_role_policy).Statement[0].Condition.StringEquals == {
      "${replace(var.issuer_base_url, "https://", "")}/platform/github_app/123:aud" = "sts.amazonaws.com"
      "${replace(var.issuer_base_url, "https://", "")}/platform/github_app/123:sub" = "read:tenant:github_app/123"
    }
    error_message = "Supplied identities must preserve exact audience and read/write subjects."
  }
}

