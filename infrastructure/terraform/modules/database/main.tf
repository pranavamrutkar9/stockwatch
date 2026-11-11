# Free: DB subnet group and parameter group.
# Billable (only when mode != "none"): one aws_db_instance, either a cross-region read
# replica of the Sydney primary or a point-in-time restore from replicated automated backups.

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-db"
  description = "StockWatch DR database subnets (no internet route)"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-postgres16"
  family      = "postgres16"
  description = "StockWatch DR PostgreSQL 16 parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = var.tags
}

locals {
  common = {
    instance_class        = var.instance_class
    storage_type          = "gp3"
    db_subnet_group_name  = aws_db_subnet_group.this.name
    parameter_group_name  = aws_db_parameter_group.this.name
    vpc_security_groups   = [var.security_group_id]
    publicly_accessible   = false
    deletion_protection   = var.deletion_protection
    ca_cert_identifier    = var.ca_cert_identifier
    backup_retention_days = var.backup_retention_days
  }
}

# Option B: warm standby. Promotion (aws rds promote-read-replica) is an operational step
# performed by dr-failover.sh, never by Terraform.
resource "aws_db_instance" "replica" {
  count = var.mode == "replica" ? 1 : 0

  identifier              = "${var.name}-replica"
  replicate_source_db     = var.source_db_arn
  instance_class          = local.common.instance_class
  storage_type            = local.common.storage_type
  db_subnet_group_name    = local.common.db_subnet_group_name
  parameter_group_name    = local.common.parameter_group_name
  vpc_security_group_ids  = local.common.vpc_security_groups
  publicly_accessible     = local.common.publicly_accessible
  deletion_protection     = local.common.deletion_protection
  ca_cert_identifier      = local.common.ca_cert_identifier
  storage_encrypted       = var.kms_key_arn != null
  kms_key_id              = var.kms_key_arn
  backup_retention_period = local.common.backup_retention_days
  skip_final_snapshot     = true # final snapshots are not supported for read replicas

  tags = merge(var.tags, { Role = "dr-replica" })

  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws:rds:ap-southeast-2:[0-9]{12}:db:", var.source_db_arn))
      error_message = "source_db_arn must be the ARN of the Sydney primary DB instance."
    }
    # After promotion the instance is standalone; never let Terraform re-attach replication.
    ignore_changes = [replicate_source_db]
  }
}

# Option A: pilot light. Restore from cross-region replicated automated backups.
resource "aws_db_instance" "restored" {
  count = var.mode == "pitr_restore" ? 1 : 0

  identifier                = "${var.name}-restored"
  instance_class            = local.common.instance_class
  storage_type              = local.common.storage_type
  db_subnet_group_name      = local.common.db_subnet_group_name
  parameter_group_name      = local.common.parameter_group_name
  vpc_security_group_ids    = local.common.vpc_security_groups
  publicly_accessible       = local.common.publicly_accessible
  deletion_protection       = local.common.deletion_protection
  ca_cert_identifier        = local.common.ca_cert_identifier
  storage_encrypted         = var.kms_key_arn != null
  kms_key_id                = var.kms_key_arn
  backup_retention_period   = local.common.backup_retention_days
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-restored-final"

  restore_to_point_in_time {
    source_db_instance_automated_backups_arn = var.replicated_backups_arn
    use_latest_restorable_time               = var.restore_time == null
    restore_time                             = var.restore_time
  }

  tags = merge(var.tags, { Role = "dr-restore" })

  lifecycle {
    precondition {
      condition     = var.replicated_backups_arn != null && can(regex("^arn:aws:rds:ap-southeast-4:[0-9]{12}:auto-backup:", var.replicated_backups_arn))
      error_message = "pitr_restore needs replicated_backups_arn (an ap-southeast-4 auto-backup ARN)."
    }
  }
}
