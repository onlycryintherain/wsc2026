variable "distribution_comment" {
  type = string
}

variable "s3_bucket_id" {
  type = string
}

variable "s3_bucket_arn" {
  type = string
}

variable "alb_arn" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "waf_name" {
  type = string
}

variable "kms_key_arn" {
  description = "Platform CMK ARN in us-east-1 for WAF logs"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "alb_sg_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}
