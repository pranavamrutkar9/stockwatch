mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
}

variables {
  name              = "stockwatch-dr"
  region            = "ap-southeast-4"
  account_id        = "111122223333"
  subnet_id         = "subnet-a"
  security_group_id = "sg-app"
  git_commit        = "0123456789abcdef0123456789abcdef01234567"
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_instance.host) == 0 && length(aws_eip.host) == 0 && length(aws_iam_role.host) == 0
    error_message = "Nothing may be created unless create = true."
  }
}

run "hardened_host_when_enabled" {
  command = plan
  variables {
    create = true
  }
  assert {
    condition     = aws_instance.host[0].metadata_options[0].http_tokens == "required" && aws_instance.host[0].metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 with hop limit 1 is required."
  }
  assert {
    condition     = aws_instance.host[0].root_block_device[0].encrypted == true
    error_message = "Root volume must be encrypted."
  }
  assert {
    condition     = !strcontains(file("${path.module}/main.tf"), "key_name")
    error_message = "No SSH key pair may be configured: administration is via SSM Session Manager."
  }
  assert {
    condition     = aws_instance.host[0].iam_instance_profile == "stockwatch-dr-host" && aws_instance.host[0].instance_type == "t3.small"
    error_message = "Unexpected instance profile or type."
  }
  assert {
    condition     = strcontains(aws_instance.host[0].user_data, "checkout --detach \"0123456789abcdef0123456789abcdef01234567\"") && !strcontains(aws_instance.host[0].user_data, "PASSWORD")
    error_message = "User data must pin the commit and contain no secrets."
  }
}

run "arm64_instance_type_rejected" {
  command = plan
  variables {
    create        = true
    instance_type = "t4g.small"
  }
  expect_failures = [var.instance_type]
}

run "unpinned_commit_rejected" {
  command = plan
  variables {
    create     = true
    git_commit = "main"
  }
  expect_failures = [aws_instance.host]
}
