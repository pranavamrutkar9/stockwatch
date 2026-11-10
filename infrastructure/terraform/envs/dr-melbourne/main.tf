data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  azs             = slice(sort(data.aws_availability_zones.available.names), 0, var.az_count)
  billable_wanted = var.create_app_host || var.db_mode != "none"
}

# Zero-cost guardrail: planning any billable resource requires allow_billable = true.
resource "terraform_data" "cost_guard" {
  input = local.billable_wanted

  lifecycle {
    precondition {
      condition     = !local.billable_wanted || var.allow_billable
      error_message = "Billable resources requested (create_app_host or db_mode != none) without allow_billable = true. Zero-cost policy: obtain approval first."
    }
  }
}

module "network" {
  source   = "../../modules/network"
  name     = var.name
  vpc_cidr = var.vpc_cidr
  azs      = local.azs
}

module "security" {
  source             = "../../modules/security"
  name               = var.name
  vpc_id             = module.network.vpc_id
  http_ingress_cidrs = var.http_ingress_cidrs
}

module "database" {
  source                 = "../../modules/database"
  name                   = var.name
  mode                   = var.allow_billable ? var.db_mode : "none"
  subnet_ids             = module.network.database_subnet_ids
  security_group_id      = module.security.db_security_group_id
  source_db_arn          = var.source_db_arn
  replicated_backups_arn = var.replicated_backups_arn
  kms_key_arn            = var.kms_key_arn
}

module "app_host" {
  source            = "../../modules/app_host"
  name              = var.name
  create            = var.allow_billable && var.create_app_host
  region            = var.region
  account_id        = data.aws_caller_identity.current.account_id
  subnet_id         = module.network.public_subnet_ids[0]
  security_group_id = module.security.app_security_group_id
  git_commit        = var.git_commit
}
