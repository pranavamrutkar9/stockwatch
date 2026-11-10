variable "name" {
  type = string
}

variable "mode" {
  description = "none (free resources only) | replica (warm standby) | pitr_restore (pilot light restore)."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "replica", "pitr_restore"], var.mode)
    error_message = "mode must be one of: none, replica, pitr_restore."
  }
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "source_db_arn" {
  description = "ARN of the Sydney primary (mode = replica)."
  type        = string
  default     = null
}

variable "replicated_backups_arn" {
  description = "ARN of the replicated automated backups in ap-southeast-4 (mode = pitr_restore)."
  type        = string
  default     = null
}

variable "restore_time" {
  description = "RFC3339 restore time for pitr_restore; null = latest restorable time."
  type        = string
  default     = null
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "kms_key_arn" {
  description = "KMS key in ap-southeast-4. Required if the source is encrypted; null = unencrypted (only valid for an unencrypted source)."
  type        = string
  default     = null
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "ca_cert_identifier" {
  type    = string
  default = "rds-ca-rsa2048-g1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
