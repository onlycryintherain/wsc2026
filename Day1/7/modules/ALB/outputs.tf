output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "tg_arn" {
  value = aws_lb_target_group.app.arn
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}
