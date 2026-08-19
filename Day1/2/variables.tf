

variable "ingress_api_origin_enabled" {
  description = "Enable the CloudFront API origin after the AWS Load Balancer Controller Ingress ALB exists."
  type        = bool
  default     = false
}

variable "ingress_api_origin_domain_name" {
  description = "DNS name of the ALB created by the Book Ingress."
  type        = string
  default     = ""
}
