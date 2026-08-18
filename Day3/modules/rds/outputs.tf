output "rds_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "rds_address" {
  value = aws_db_instance.this.address
}

output "rds_proxy_endpoint" {
  value = aws_db_proxy.this.endpoint
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}
