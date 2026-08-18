variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "identifier" { type = string }
variable "db_name" { type = string }
variable "username" { type = string }
variable "proxy_name" { type = string }
variable "secret_name" { type = string }
