variable "repository_name" {
  description = "ECR repository name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption"
  type        = string
}

variable "scan_on_push" {
  description = "Enable scan on push"
  type        = bool
  default     = true
}
