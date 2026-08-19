variable "function_name" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "table_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "log_group_name" {
  type    = string
  default = "/unicorn/lambda/get-booking"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "vpc_id" {
  type = string
}
