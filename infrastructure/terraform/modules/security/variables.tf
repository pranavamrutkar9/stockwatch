variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "http_ingress_cidrs" {
  description = "CIDRs allowed to reach port 80 on the app host."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
