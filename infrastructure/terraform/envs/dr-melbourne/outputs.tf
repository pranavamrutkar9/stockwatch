output "vpc_id" {
  value = module.network.vpc_id
}

output "app_security_group_id" {
  value = module.security.app_security_group_id
}

output "db_security_group_id" {
  value = module.security.db_security_group_id
}

output "db_subnet_group_name" {
  value = module.database.subnet_group_name
}

output "db_endpoint_address" {
  value = module.database.endpoint_address
}

output "app_public_ip" {
  value = module.app_host.public_ip
}

output "billable_resource_count" {
  description = "Number of billable resources in this configuration (0 by default)."
  value       = module.database.billable_instance_count + module.app_host.billable_resource_count
}
