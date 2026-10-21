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
  tenant_id                   = "github_app/acme"
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
