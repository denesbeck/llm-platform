data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_prefix = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/llm-platform"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# control plane
resource "aws_iam_role" "control_plane" {
  name               = "llm-platform-control-plane"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html
resource "aws_iam_role_policy_attachment" "control_plane_ssm" {
  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "control_plane" {
  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_prefix, "${local.ssm_prefix}/*"]
  }

  # AmazonSSMManagedInstanceCore allows ssm: GetParameter(s) on "*". Explicit deny overrides it.
  statement {
    sid           = "DenyOtherSecrets"
    effect        = "Deny"
    actions       = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    not_resources = [local.ssm_prefix, "${local.ssm_prefix}/*"]
  }

  #https://prometheus.io/docs/prometheus/latest/configuration/configuration/#ec2
  statement {
    sid       = "PrometheusDiscovery"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }

  statement {
    sid       = "BedrockFallback"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/qwen.qwen3-coder-30b-a3b-v1:0"]
  }
}

resource "aws_iam_role_policy" "control_plane" {
  name   = "llm-platform-control-plane"
  role   = aws_iam_role.control_plane.id
  policy = data.aws_iam_policy_document.control_plane.json
}

resource "aws_iam_instance_profile" "control_plane" {
  name = "llm-platform-control-plane"
  role = aws_iam_role.control_plane.name
}

# GPU instance
resource "aws_iam_role" "gpu_instance" {
  name               = "llm-platform-gpu-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "gpu_instance_ssm" {
  role       = aws_iam_role.gpu_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "gpu_instance" {
  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["${local.ssm_prefix}/gpu", "${local.ssm_prefix}/gpu/*"]
  }

  # AmazonSSMManagedInstanceCore allows ssm: GetParameter(s) on "*". Explicit deny overrides it.
  statement {
    sid           = "DenyOtherSecrets"
    effect        = "Deny"
    actions       = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    not_resources = ["${local.ssm_prefix}/gpu", "${local.ssm_prefix}/gpu/*"]
  }
}

resource "aws_iam_role_policy" "gpu_instance" {
  name   = "llm-platform-gpu-instance"
  role   = aws_iam_role.gpu_instance.id
  policy = data.aws_iam_policy_document.gpu_instance.json
}

resource "aws_iam_instance_profile" "gpu_instance" {
  name = "llm-platform-gpu-instance"
  role = aws_iam_role.gpu_instance.name
}
