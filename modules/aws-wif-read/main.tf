# Add a read issuer and new read-only role without editing the pinned
# provisioning module. Both reader generations can assume this role.
locals {
  issuer_url          = "${var.issuer_base_url}/read/${var.tenant_id}"
  oidc_host           = replace(local.issuer_url, "https://", "")
  provisioning_issuer = "${var.issuer_base_url}/platform/${var.tenant_id}"
  provisioning_host   = replace(local.provisioning_issuer, "https://", "")
}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_iam_openid_connect_provider" "provisioning" {
  arn = var.provisioning_oidc_provider_arn
}
# Pin the issuing CA fingerprints, never the short-lived leaf, as aws-wif does.
data "tls_certificate" "oidc" {
  url = local.issuer_url
}
resource "aws_iam_openid_connect_provider" "murmur_read" {
  url            = local.issuer_url
  client_id_list = [var.oidc_audience]
  thumbprint_list = [
    for cert in data.tls_certificate.oidc.certificates : cert.sha1_fingerprint
    if cert.is_ca
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
