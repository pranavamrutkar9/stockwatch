mock_provider "aws" {}

variables {
  name              = "stockwatch-dr"
  subnet_ids        = ["subnet-a", "subnet-b"]
  security_group_id = "sg-db"
}

run "mode_none_creates_no_instance" {
  command = plan
  assert {
    condition     = length(aws_db_instance.replica) == 0 && length(aws_db_instance.restored) == 0
    error_message = "mode = none must not create DB instances."
  }
  assert {
    condition     = one([for p in aws_db_parameter_group.this.parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "rds.force_ssl must be enabled."
  }
}

run "replica_is_private_protected_and_in_dr_network" {
  command = plan
  variables {
    mode          = "replica"
    source_db_arn = "arn:aws:rds:ap-southeast-2:111122223333:db:stockwatch-primary-db"
    kms_key_arn   = "arn:aws:kms:ap-southeast-4:111122223333:key/abcd"
  }
  assert {
    condition     = aws_db_instance.replica[0].publicly_accessible == false
    error_message = "Replica must not be publicly accessible."
  }
  assert {
    condition     = aws_db_instance.replica[0].deletion_protection == true
    error_message = "Replica must have deletion protection."
  }
  assert {
    condition     = aws_db_instance.replica[0].vpc_security_group_ids == toset(["sg-db"])
    error_message = "Replica must use the DR DB security group (not the default SG)."
  }
  assert {
    condition     = aws_db_instance.replica[0].storage_encrypted == true && aws_db_instance.replica[0].kms_key_id == "arn:aws:kms:ap-southeast-4:111122223333:key/abcd"
    error_message = "Encrypted replica must use the Melbourne KMS key."
  }
  assert {
    condition     = aws_db_instance.replica[0].instance_class == "db.t4g.micro"
    error_message = "Unexpected instance class."
  }
}

run "replica_source_must_be_sydney_primary" {
  command = plan
  variables {
    mode          = "replica"
    source_db_arn = "arn:aws:rds:us-east-1:111122223333:db:something-else"
  }
  expect_failures = [aws_db_instance.replica]
}

run "pitr_restore_requires_melbourne_backup_arn" {
  command = plan
  variables {
    mode = "pitr_restore"
  }
  expect_failures = [aws_db_instance.restored]
}

run "invalid_mode_rejected" {
  command = plan
  variables {
    mode = "multi-region-magic"
  }
  expect_failures = [var.mode]
}
