variable "bucket_name" {
  description = "S3 bucket name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption"
  type        = string
}

variable "versioning_status" {
  description = "Versioning status"
  type        = string
  default     = "Enabled"
}
