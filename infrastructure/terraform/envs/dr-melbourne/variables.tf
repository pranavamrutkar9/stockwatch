variable "region" {
  type    = string
  default = "ap-southeast-4"
  validation {
    condition     = var.region == "ap-southeast-4"
    error_message = "This environment is the Melbourne DR environment (ap-southeast-4)."
  }
}

variable "allowed_account_ids" {
  description = "AWS account(s) this configuration may run against (set in terraform.tfvars, not committed)."
  type        = list(string)
}

variable "name" {
  type    = string
  default = "stockwatch-dr"
}

variable "vpc_cidr" {
  description = "Must not overlap the Sydney primary VPC (172.31.0.0/16)."
  type        = string
  default     = "10.42.0.0/16"
  validation {
    condition     = !(startswith(var.vpc_cidr, "172.31.") || var.vpc_cidr == "172.16.0.0/12")
    error_message = "vpc_cidr overlaps the primary VPC range 172.31.0.0/16."
  }
}

variable "az_count" {
  type    = number
  default = 2
}

variable "http_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

# ---- Billable features: every one is off by default and also requires allow_billable ----

variable "allow_billable" {
  description = "Explicit acknowledgement that billable resources may be planned. Requires approval."
  type        = bool
  default     = false
}

variable "create_app_host" {
  description = "BILLABLE: EC2 t3.small + Elastic IP."
  type        = bool
  default     = false
}

variable "db_mode" {
  description = "none (free) | replica (BILLABLE warm standby) | pitr_restore (BILLABLE restore)."
  type        = string
  default     = "none"
}

variable "source_db_arn" {
  type    = string
  default = null
}

variable "replicated_backups_arn" {
  type    = string
  default = null
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "git_commit" {
  description = "Pinned commit for the DR host bootstrap."
  type        = string
  default     = ""
}
