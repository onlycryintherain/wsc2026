variable "vpc_name" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnets_cidr" { type = list(string) }
variable "isolated_subnets_cidr" { type = list(string) }
variable "availability_zones" { type = list(string) }
variable "public_subnet_names" { type = list(string) }
variable "isolated_subnet_names" { type = list(string) }
