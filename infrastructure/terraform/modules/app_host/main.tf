# Billable when create = true: EC2 instance + Elastic IP (IAM role/profile are free but are
# also only created then, because IAM changes need approval).

data "aws_ami" "ubuntu" {
  count       = var.create && var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"] # application images are linux/amd64 only
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid       = "ReadDrRuntimeParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:${var.account_id}:parameter${var.ssm_parameter_prefix}*"]
  }
  statement {
    sid       = "DecryptViaSsmOnly"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  count              = var.create ? 1 : 0
  name               = "${var.name}-host"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "runtime" {
  count  = var.create ? 1 : 0
  name   = "runtime-parameters"
  role   = aws_iam_role.host[0].id
  policy = data.aws_iam_policy_document.runtime.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count      = var.create ? 1 : 0
  role       = aws_iam_role.host[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  count = var.create ? 1 : 0
  name  = "${var.name}-host"
  role  = aws_iam_role.host[0].name
}

resource "aws_instance" "host" {
  count                  = var.create ? 1 : 0
  ami                    = coalesce(var.ami_id, try(data.aws_ami.ubuntu[0].id, null))
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.host[0].name

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region               = var.region
    repo_url             = var.repo_url
    git_commit           = var.git_commit
    ssm_parameter_prefix = var.ssm_parameter_prefix
  })
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.name}-host" })

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{40}$", var.git_commit))
      error_message = "git_commit must be a full 40-character commit SHA (pinned, reproducible deployment)."
    }
  }
}

resource "aws_eip" "host" {
  count    = var.create ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.host[0].id
  tags     = merge(var.tags, { Name = "${var.name}-host" })
}
