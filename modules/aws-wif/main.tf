# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ CUSTOMER MODULE — SINGLE-TENANT OIDC FEDERATION                           │
# │                                                                           │
# │ This module creates a single-tenant OIDC federation for a customer's own  │
# │ AWS account. The IAM trust policy scopes access to exactly one murmur     │
# │ tenant via StringEquals on the sub claim. This is the cryptographic       │
# │ isolation boundary: only OIDC tokens with sub="write:{tenant_id}" or     │
# │ sub="read:{tenant_id}" can assume the respective roles.                  │
# └─────────────────────────────────────────────────────────────────────────────┘

locals {
  # Strip the scheme for IAM OIDC condition keys. AWS uses the bare host as
  # the condition key prefix (e.g. "oidc.murmur.dev:aud").
  oidc_host = replace(var.oidc_issuer_url, "https://", "")
}

# ─── OIDC Provider ───────────────────────────────────────────────────────────

# Auto-compute the TLS thumbprint of the OIDC issuer's certificate chain.
# AWS validates OIDC issuers via its trusted CA library for certs from
# recognized CAs (added 2023) — the thumbprint is a belt-and-suspenders
# fallback. See README for manual verification via openssl.
data "tls_certificate" "oidc" {
  url = var.oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "murmur" {
  url            = var.oidc_issuer_url
  client_id_list = [var.oidc_audience]

  # Pin the issuing CA fingerprints (intermediate + root), never the leaf.
  # The issuer serves short-lived (~90-day) Google Trust Services leaf certs,
  # so pinning the leaf churns thumbprint_list on every renewal — a recurring
  # in-place diff. The CA certs (e.g. the GTS WR3 intermediate) only rotate
  # when GTS rotates its CA, so filtering to is_ca yields a stable list.
  # Order-independent by design: tls_certificate returns the chain root-first,
  # but is_ca==false uniquely identifies the leaf regardless of position.
  thumbprint_list = [
    for cert in data.tls_certificate.oidc.certificates : cert.sha1_fingerprint
    if cert.is_ca
  ]

  tags = {
    ManagedBy = "terraform"
    Purpose   = "murmur-wif-customer"
  }
}

# ─── VM Creator Role ─────────────────────────────────────────────────────────

# Allow write-role tokens for this specific tenant to assume the VM creator
# role.
#
# AWS IAM trust policies can only condition on "sub" and "aud" — not custom
# claims like "role". Murmur encodes the role in the sub claim as
# "{role}:{tenant}" (e.g. "write:github_app/acme"). The trust uses
# StringEquals with the exact sub value for single-tenant + role scoping.
resource "aws_iam_role" "vm_creator" {
  name                 = var.role_name
  permissions_boundary = var.ec2_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.murmur.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = var.oidc_audience
          "${local.oidc_host}:sub" = "write:${var.tenant_id}"
        }
      }
    }]
  })

  tags = {
    ManagedBy = "terraform"
    Purpose   = "murmur-vm-creator"
  }
}

# ─── Read-Only Role ──────────────────────────────────────────────────────────

# Allow read-role tokens for this specific tenant to assume the read-only role.
# Same sub-encoding pattern: "read:{tenant}".
resource "aws_iam_role" "readonly" {
  name                 = var.readonly_role_name
  permissions_boundary = var.ec2_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.murmur.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = var.oidc_audience
          "${local.oidc_host}:sub" = "read:${var.tenant_id}"
        }
      }
    }]
  })

  tags = {
    ManagedBy = "terraform"
    Purpose   = "murmur-readonly"
  }
}

resource "aws_iam_role_policy" "readonly_ec2" {
  name = "ec2-readonly"
  role = aws_iam_role.readonly.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EC2ReadOnly"
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages",
        # An AMI's billed storage lives on its EBS snapshots, not on the AMI:
        # DescribeImages reports only each mapping's nominal volume size, so
        # murmur's image-storage accounting reads FullSnapshotSizeInBytes here.
        "ec2:DescribeSnapshots",
      ]
      Resource = "*"
    }]
  })
}

# EC2 permissions for VM lifecycle operations.
# Analog of GCP roles/compute.instanceAdmin.v1.
#
# Security boundaries:
# - RunInstances may reference only the configured placement subnets and
#   security group.
# - Lifecycle operations on existing resources are authorized by the
#   ec2:ResourceTag/murmur=true tag. That tag is the security boundary for
#   start, stop, terminate, and the other mutations below.
#
# Resources created by RunInstances/CreateImage/CreateSnapshot must carry
# aws:RequestTag/murmur=true at birth. Destructive actions on existing
# resources require ec2:ResourceTag/murmur=true. This confines the assumed
# credential to murmur's own resources — it cannot touch anything else in
# the customer's AWS account.
resource "aws_iam_role_policy" "ec2" {
  name = "ec2-vm-lifecycle"
  role = aws_iam_role.vm_creator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ── RunInstances: created resources (instance, volume, NIC) ────────
      # Ensures every new resource is born with murmur=true.
      {
        Sid    = "RunInstancesCreate"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:network-interface/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/murmur" = "true"
          }
        }
      },
      # ── RunInstances: placement network resources ─────────────────────
      # A launch may use only the subnets and security group declared in the
      # placement produced by this module.
      {
        Sid    = "RunInstancesNetworkRef"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = concat(
          [
            for subnet_id in var.placement_subnet_ids :
            "arn:aws:ec2:*:${local.placement_account_id}:subnet/${subnet_id}"
          ],
          [
            "arn:aws:ec2:*:${local.placement_account_id}:security-group/${var.placement_security_group_id}",
          ],
        )
      },
      # ── RunInstances: non-network references ───────────────────────────
      # AMIs and key pairs are not placement-network resources.
      {
        Sid    = "RunInstancesRef"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:*:*:key-pair/*",
          "arn:aws:ec2:*:*:image/*",
        ]
      },
      # ── Mutate existing murmur-tagged resources ────────────────────────
      # Confines destructive + create-from-source actions to resources
      # carrying ec2:ResourceTag/murmur=true. CreateImage and
      # CreateSnapshot appear here for the source instance/volume;
      # their output resources (image, snapshot) are authorized by
      # CreateImageSnapshotTag below.
      {
        Sid    = "MurmurResourceMutate"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:CreateImage",
          "ec2:CreateSnapshot",
          "ec2:DeregisterImage",
          "ec2:DeleteSnapshot",
        ]
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:image/*",
          "arn:aws:ec2:*:*:snapshot/*",
        ]
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/murmur" = "true"
          }
        }
      },
      # ── Create new images/snapshots with murmur tag ────────────────────
      # For the newly-created output resources of CreateImage (image +
      # snapshot) and CreateSnapshot (snapshot), require murmur=true in
      # the request tags.
      {
        Sid    = "CreateImageSnapshotTag"
        Effect = "Allow"
        Action = [
          "ec2:CreateImage",
          "ec2:CreateSnapshot",
        ]
        Resource = [
          "arn:aws:ec2:*:*:image/*",
          "arn:aws:ec2:*:*:snapshot/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/murmur" = "true"
          }
        }
      },
      # ── Tag resources during creation ──────────────────────────────────
      # RunInstances, CreateImage, and CreateSnapshot with
      # TagSpecifications require ec2:CreateTags. Scoped via
      # ec2:CreateAction so this cannot be used for standalone tagging
      # of arbitrary resources.
      {
        Sid    = "TagOnCreate"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:image/*",
          "arn:aws:ec2:*:*:snapshot/*",
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = ["RunInstances", "CreateImage", "CreateSnapshot"]
          }
        }
      },
      # ── Tag existing murmur resources ──────────────────────────────────
      # Post-creation tag updates Murmur makes to its own resources. Only
      # allows tagging resources already carrying murmur=true.
      {
        Sid      = "TagMurmurResources"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/murmur" = "true"
          }
        }
      },
      # ── Read-only (unconditioned) ──────────────────────────────────────
      {
        Sid    = "ReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          # An instance type's RAM sizes the hibernation swap volume a VM
          # cannot sleep without, and the snapshot-storage meter that bills it.
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeImages",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassVMRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.vm_runtime.arn
      },
    ]
  })
}

# Additional policies provided by the operator.
resource "aws_iam_role_policy_attachment" "extra" {
  for_each = toset(var.extra_policies)

  role       = aws_iam_role.vm_creator.name
  policy_arn = each.value
}

# ─── VM Runtime Role + Instance Profile ──────────────────────────────────────

# The role VMs assume at boot via the instance profile. Minimal — the
# role exists so that iam:PassRole works and VMs have an identity from
# day one. Per-environment policies (e.g. SSM for debugging) are attached
# by the customer, not here.
resource "aws_iam_role" "vm_runtime" {
  name                 = "${var.instance_profile_name}-role"
  permissions_boundary = var.ec2_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    ManagedBy = "terraform"
    Purpose   = "murmur-vm-runtime"
  }
}

resource "aws_iam_instance_profile" "vm" {
  name = var.instance_profile_name
  role = aws_iam_role.vm_runtime.name

  tags = {
    ManagedBy = "terraform"
    Purpose   = "murmur-vm-runtime"
  }
}
