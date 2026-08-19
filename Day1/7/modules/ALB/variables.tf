variable "alb_name" {
  type = string
}

variable "tg_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "lambda_arn" {
  type = string
}

variable "lambda_invoke_arn" {
  type = string
}
