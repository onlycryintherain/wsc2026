variable "app_key_alias" {
  description = "Alias for App KMS key"
  type        = string
}

variable "data_key_alias" {
  description = "Alias for Data KMS key"
  type        = string
}

variable "platform_key_alias" {
  description = "Alias for Platform KMS key"
  type        = string
}

variable "rotation_period" {
  description = "Key rotation period in days"
  type        = number
  default     = 90
}
