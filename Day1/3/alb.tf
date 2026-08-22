data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "wsc2026-app-alb-sg"
  description = "ALB SG - CloudFront only"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-app-alb-sg" }
}

# Allow ALB to reach pods on port 8080 via cluster managed SG
resource "aws_security_group_rule" "alb_to_pods" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}

# Allow mark-sg (CloudShell) to reach EKS API via cluster managed SG
resource "aws_security_group_rule" "mark_to_eks" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.mark.id
  security_group_id        = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}


resource "aws_security_group" "mark" {
  name        = "mark-sg"
  description = "Mark SG - all open"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mark-sg" }
}