variable "table_name" {
  description = "DynamoDB table name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption"
  type        = string
}

variable "hash_key" {
  description = "Hash key (partition key)"
  type        = string
  default     = "booking_id"
}

variable "gsi_name" {
  description = "GSI name"
  type        = string
  default     = "client-id-created-at-index"
}

variable "gsi_hash_key" {
  description = "GSI hash key"
  type        = string
  default     = "client_id"
}

variable "gsi_range_key" {
  description = "GSI range key"
  type        = string
  default     = "created_at"
}

variable "gsi_projection" {
  description = "GSI projection type"
  type        = string
  default     = "ALL"
}
