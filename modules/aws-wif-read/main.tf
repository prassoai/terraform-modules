# Add a read issuer and new read-only role without editing the pinned
# provisioning module. Both reader generations can assume this role.
locals {
  issuer_url          = "${var.issuer_base_url}/read/${var.tenant_id}"
  oidc_host           = replace(local.issuer_url, "https://", "")
  provisioning_issuer = "${var.issuer_base_url}/platform/${var.tenant_id}"
  provisioning_host   = replace(local.provisioning_issuer, "https://", "")
}
# Refuse trust creation until the public tenant discovery contract is ready.
# This also catches a wrong environment or a document from the agents family.
data "http" "discovery" {
  count              = var.validate_oidc_readiness ? 1 : 0
  request_timeout_ms = 10000
  url                = "${local.issuer_url}/.well-known/openid-configuration"
  request_headers    = { Accept = "application/json" }
}

# Probe the known family URL, never an unvalidated discovery-supplied URL.
data "http" "jwks" {
  count              = var.validate_oidc_readiness ? 1 : 0
  request_timeout_ms = 10000
  url                = "${var.issuer_base_url}/read/.well-known/jwks.json"
  request_headers    = { Accept = "application/json" }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_iam_openid_connect_provider" "provisioning" {
  arn = var.provisioning_oidc_provider_arn
}
data "tls_certificate" "oidc" {
  count = length(var.oidc_ca_thumbprints) == 0 && var.validate_oidc_readiness ? 1 : 0
  url   = local.issuer_url
}
resource "aws_iam_openid_connect_provider" "murmur_read" {
  lifecycle {
    precondition {
      condition     = var.validate_oidc_readiness || length(var.oidc_ca_thumbprints) > 0
      error_message = "Set oidc_ca_thumbprints to the existing verified CA fingerprints before disabling readiness checks; outage maintenance must not contact the issuer or silently remove its thumbprints."
    }

    precondition {
      condition = !var.validate_oidc_readiness || try(
        data.http.discovery[0].status_code == 200 &&
        jsondecode(data.http.discovery[0].response_body).issuer == local.issuer_url &&
        jsondecode(data.http.discovery[0].response_body).jwks_uri == "${var.issuer_base_url}/read/.well-known/jwks.json" &&
        data.http.jwks[0].status_code == 200 &&
        length(jsondecode(data.http.jwks[0].response_body).keys) > 0 &&
        alltrue([for key in jsondecode(data.http.jwks[0].response_body).keys :
          key.kty == "RSA" && key.alg == "RS256" && key.use == "sig" &&
          length(key.kid) > 0 && length(key.n) > 0 && length(key.e) > 0
        ]),
        false,
      )
      error_message = "Tenant read OIDC is not ready. Discovery must name the exact issuer and read keyset, and JWKS must contain RS256 signing keys. Wait for Murmur publication before applying."
    }
  }

  url            = local.issuer_url
  client_id_list = [var.oidc_audience]
  thumbprint_list = length(var.oidc_ca_thumbprints) > 0 ? var.oidc_ca_thumbprints : [
    for cert in flatten(data.tls_certificate.oidc[*].certificates) : cert.sha1_fingerprint if cert.is_ca
  ]
  tags = { ManagedBy = "terraform", Purpose = "murmur-read-customer" }
}
resource "aws_iam_role" "readonly" {
  name                 = var.readonly_role_name
  permissions_boundary = var.ec2_permissions_boundary_arn
  lifecycle {
    precondition {
      condition = (
        var.provisioning_oidc_provider_arn == "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.provisioning_host}" &&
        replace(data.aws_iam_openid_connect_provider.provisioning.url, "https://", "") == local.provisioning_host &&
        contains(data.aws_iam_openid_connect_provider.provisioning.client_id_list, var.oidc_audience)
      )
      error_message = "Provisioning trust must already name this account, tenant, origin and audience. Complete its separately reviewed migration before adding read trust."
    }
  }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for trust in [
        { arn = aws_iam_openid_connect_provider.murmur_read.arn, host = local.oidc_host },
        { arn = var.provisioning_oidc_provider_arn, host = local.provisioning_host }
        ] : {
        Effect    = "Allow"
        Principal = { Federated = trust.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${trust.host}:aud" = var.oidc_audience
            "${trust.host}:sub" = "read:${var.tenant_id}"
          }
        }
      }
    ]
  })
  tags = { ManagedBy = "terraform", Purpose = "murmur-readonly" }
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
        "ec2:DescribeInstances", "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages", "ec2:DescribeSnapshots",
      ]
      Resource = "*"
    }]
  })
}
