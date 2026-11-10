output "subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "parameter_group_name" {
  value = aws_db_parameter_group.this.name
}

output "endpoint_address" {
  description = "DR database endpoint (null when mode = none)."
  value = one(concat(
    aws_db_instance.replica[*].address,
    aws_db_instance.restored[*].address,
  ))
}

output "billable_instance_count" {
  value = length(aws_db_instance.replica) + length(aws_db_instance.restored)
}
