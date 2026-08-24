variable "cluster_name" {
  type = string
}

variable "source_path" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_url" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "karpenter_role_arn" {
  type = string
}

variable "karpenter_queue_name" {
  type = string
}

variable "node_role_name" {
  type = string
}

variable "log_bucket" {
  type = string
}

variable "db_identifier" { type = string }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "db_secret_name" { type = string }
variable "db_proxy_name" { type = string }
variable "node_instance_type" { type = string }

variable "node_cpu_credits" {
  type    = string
  default = "unlimited"

  validation {
    condition     = contains(["standard", "unlimited"], var.node_cpu_credits)
    error_message = "node_cpu_credits는 standard 또는 unlimited여야 합니다."
  }
}