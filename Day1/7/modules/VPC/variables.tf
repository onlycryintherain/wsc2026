variable "vpc_name" {
  description = "VPC name"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "public_subnets_cidr" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnets_cidr" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability Zones"
  type        = list(string)
}

variable "public_subnet_names" {
  description = "Names for public subnets"
  type        = list(string)
}

variable "private_subnet_names" {
  description = "Names for private subnets"
  type        = list(string)
}

variable "igw_name" {
  description = "Internet Gateway name"
  type        = string
}

variable "nat_eip_names" {
  description = "NAT EIP names"
  type        = list(string)
}

variable "nat_gw_names" {
  description = "NAT Gateway names"
  type        = list(string)
}

variable "public_rt_name" {
  description = "Public route table name"
  type        = string
}

variable "private_rt_names" {
  description = "Private route table names"
  type        = list(string)
}

variable "flow_log_name" {
  description = "Flow log name"
  type        = string
}
