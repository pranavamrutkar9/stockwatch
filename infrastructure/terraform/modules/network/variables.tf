variable "name" {
  type = string
}

variable "vpc_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid IPv4 CIDR of /16 or larger."
  }
}

variable "azs" {
  type = list(string)
  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two availability zones are required (RDS subnet groups need >= 2 AZs)."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
