variable "name" {
  type = string
}

variable "create" {
  type    = bool
  default = false
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
  validation {
    condition     = !can(regex("^[a-z0-9]+g[a-z]*\\.", var.instance_type))
    error_message = "Graviton (arm64) types are not supported: application images are linux/amd64 only."
  }
}

variable "ami_id" {
  type    = string
  default = null
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "repo_url" {
  type    = string
  default = "https://github.com/pranavamrutkar9/stockwatch.git"
}

variable "git_commit" {
  type    = string
  default = ""
}

variable "ssm_parameter_prefix" {
  description = "SSM Parameter Store path holding DR runtime secrets (SecureString)."
  type        = string
  default     = "/stockwatch/dr/"
}

variable "tags" {
  type    = map(string)
  default = {}
}
