# Offline plan tests: mock provider, no AWS credentials, no API calls, zero cost.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-southeast-4a", "ap-southeast-4b", "ap-southeast-4c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
}

variables {
  allowed_account_ids = ["111122223333"]
}

run "default_plan_is_zero_cost" {
  command = plan

  assert {
    condition     = output.billable_resource_count == 0
    error_message = "Default plan must contain no billable resources."
  }
  assert {
    condition     = module.network.vpc_cidr == "10.42.0.0/16"
    error_message = "Unexpected VPC CIDR."
  }
  assert {
    condition     = module.network.public_subnet_cidrs == ["10.42.0.0/24", "10.42.1.0/24"]
    error_message = "Unexpected public subnet layout."
  }
  assert {
    condition     = module.network.database_subnet_cidrs == ["10.42.10.0/24", "10.42.11.0/24"]
    error_message = "Unexpected database subnet layout."
  }
}

run "app_host_without_allow_billable_is_refused" {
  command = plan
  variables {
    create_app_host = true
  }
  expect_failures = [terraform_data.cost_guard]
}

run "replica_without_allow_billable_is_refused" {
  command = plan
  variables {
    db_mode       = "replica"
    source_db_arn = "arn:aws:rds:ap-southeast-2:111122223333:db:stockwatch-primary-db"
  }
  expect_failures = [terraform_data.cost_guard]
}

run "warm_standby_plan_with_explicit_opt_in" {
  command = plan
  variables {
    allow_billable  = true
    create_app_host = true
    db_mode         = "replica"
    source_db_arn   = "arn:aws:rds:ap-southeast-2:111122223333:db:stockwatch-primary-db"
    git_commit      = "0123456789abcdef0123456789abcdef01234567"
  }
  assert {
    condition     = output.billable_resource_count == 3 # replica + instance + EIP
    error_message = "Warm standby should plan exactly 3 billable resources."
  }
}

run "overlapping_vpc_cidr_is_rejected" {
  command = plan
  variables {
    vpc_cidr = "172.31.0.0/16"
  }
  expect_failures = [var.vpc_cidr]
}

run "other_region_is_rejected" {
  command = plan
  variables {
    region = "ap-southeast-2"
  }
  expect_failures = [var.region]
}
