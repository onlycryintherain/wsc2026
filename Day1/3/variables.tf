variable "bi_number" {
  description = "선수 비번호"
  type        = string
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
  numeric = false
}
