mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/12345678\",\"jwks_uri\":\"https://oidc.murmur.dev/platform/.well-known/jwks.json\"}"
    }
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
  tenant_id                   = "github_app/12345678"
  placement_region            = "us-east-1"
  placement_subnet_ids        = ["subnet-123"]
  placement_security_group_id = "sg-123"
}

# ec2:ModifyInstanceAttribute is authorized against the instance alone; AWS
# never evaluates the security groups named by its --groups form. Any grant of
# it on a murmur instance lets the VM creator launch inside the placement
# network boundary RunInstances enforces and then swap the VM into any security
# group in the VPC. Murmur never calls it, so no Allow statement may match it,
# whether by name or by wildcard. IAM matches actions case-insensitively and
# expands both * and ?, so the check does too. Boot-disk resize uses ec2:ModifyVolume, which
# must survive any tightening here.
run "vm_creator_cannot_change_instance_security_groups" {
  command = apply

  assert {
    condition = !anytrue([
      for statement in jsondecode(aws_iam_role_policy.ec2.policy).Statement :
      statement.Effect == "Allow" && anytrue([
        for action in flatten([statement.Action]) :
        can(regex("^${replace(replace(lower(action), "*", ".*"), "?", ".")}$", "ec2:modifyinstanceattribute"))
      ])
    ])
    error_message = "No Allow statement may grant ec2:ModifyInstanceAttribute: it would let the VM creator move a VM out of its placement security group."
  }
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.ec2.policy).Statement :
      statement.Effect == "Allow" && contains([for action in flatten([statement.Action]) : lower(action)], "ec2:modifyvolume")
    ])
    error_message = "Boot-disk resize needs ec2:ModifyVolume."
  }
}

# AWS condition keys include the entire issuer path. Both roles must retain
# their audience and role-specific subject checks under that exact prefix.
run "tenant_specific_issuer" {
  command = apply

  assert {
    condition     = aws_iam_openid_connect_provider.murmur.url == "https://oidc.murmur.dev/platform/github_app/12345678"
    error_message = "The OIDC provider must trust the full tenant issuer."
  }
  assert {
    condition = jsondecode(aws_iam_role.vm_creator.assume_role_policy).Statement[0].Condition.StringEquals == {
      "oidc.murmur.dev/platform/github_app/12345678:aud" = "sts.amazonaws.com"
      "oidc.murmur.dev/platform/github_app/12345678:sub" = "write:github_app/12345678"
    }
    error_message = "The write trust policy must use the tenant path and immutable subject."
  }
  assert {
    condition = jsondecode(aws_iam_role.readonly.assume_role_policy).Statement[0].Condition.StringEquals == {
      "oidc.murmur.dev/platform/github_app/12345678:aud" = "sts.amazonaws.com"
      "oidc.murmur.dev/platform/github_app/12345678:sub" = "read:github_app/12345678"
    }
    error_message = "The read trust policy must use the tenant path and immutable subject."
  }
  assert {
    condition     = output.issuer_url == aws_iam_openid_connect_provider.murmur.url
    error_message = "The issuer output must match the provider."
  }
}

# Non-production changes only the origin, including in the IAM condition keys.
run "nonproduction_tenant_issuer" {
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.nonprod.murmur.dev/platform/github_app/87654321\",\"jwks_uri\":\"https://oidc.nonprod.murmur.dev/platform/.well-known/jwks.json\"}" }
  }

  command = apply
  variables {
    issuer_base_url = "https://oidc.nonprod.murmur.dev"
    tenant_id       = "github_app/87654321"
  }
  assert {
    condition     = aws_iam_openid_connect_provider.murmur.url == "https://oidc.nonprod.murmur.dev/platform/github_app/87654321"
    error_message = "An origin override must retain the tenant suffix."
  }
  assert {
    condition     = jsondecode(aws_iam_role.vm_creator.assume_role_policy).Statement[0].Condition.StringEquals["oidc.nonprod.murmur.dev/platform/github_app/87654321:sub"] == "write:github_app/87654321"
    error_message = "IAM condition keys must follow the overridden origin and tenant."
  }
}

# A mutable login must fail at plan time, not silently trust the wrong issuer.
run "reject_mutable_tenant_login" {
  command = plan
  variables { tenant_id = "github_app/acme" }
  expect_failures = [var.tenant_id]
}

# An origin containing a path would append a second tenant suffix.
run "reject_issuer_path" {
  command = plan
  variables { issuer_base_url = "https://oidc.murmur.dev/platform/github_app/12345678" }
  expect_failures = [var.issuer_base_url]
}

# Onboarding must stop before cloud trust is created if public discovery does
# not advertise this exact tenant and its provisioning-only keyset.
run "wrong_tenant_discovery" {
  command = plan
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/99999999\",\"jwks_uri\":\"https://oidc.murmur.dev/platform/.well-known/jwks.json\"}" }
  }
  expect_failures = [aws_iam_openid_connect_provider.murmur]
}

# Onboarding must stop before cloud trust is created if public discovery does
# not advertise this exact tenant and its provisioning-only keyset.
run "wrong_family_keyset" {
  command = plan
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "{\"issuer\":\"https://oidc.murmur.dev/platform/github_app/12345678\",\"jwks_uri\":\"https://oidc.murmur.dev/agents/.well-known/jwks.json\"}" }
  }
  expect_failures = [aws_iam_openid_connect_provider.murmur]
}

# Onboarding must stop before cloud trust is created if public discovery does
# not advertise this exact tenant and its provisioning-only keyset.
run "malformed_discovery" {
  command = plan
  override_data {
    target = data.http.discovery
    values = { status_code = 200, response_body = "not-json" }
  }
  expect_failures = [aws_iam_openid_connect_provider.murmur]
}
