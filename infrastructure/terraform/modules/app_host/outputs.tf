output "instance_id" {
  value = one(aws_instance.host[*].id)
}

output "public_ip" {
  value = one(aws_eip.host[*].public_ip)
}

output "billable_resource_count" {
  value = length(aws_instance.host) + length(aws_eip.host)
}
