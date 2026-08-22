# 과제별 Terraform 설정 예시
# 기본 region/password는 main.tf 기본값을 사용한다.
# 리소스 이름이나 클러스터명이 바뀌는 경우에만 수정한다.

cluster_name           = "wsi2026-cluster"
db_identifier          = "apdev-rds-instance"
db_name                = "dev"
db_username            = "admin"
db_proxy_name          = "apdev-proxy"
db_secret_name         = "apdev-rds-credentials"
db_instance_class      = "db.t3.micro"
eks_node_instance_type = "t3.medium"
