########################
# EKS IAM Roles
########################

resource "aws_iam_role" "eks_cluster" {
  name = "wsc2026-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_addon_node" {
  name = "wsc2026-addon-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "eks_workload_node" {
  name = "wsc2026-workload-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

locals {
  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
}

resource "aws_iam_role_policy_attachment" "addon_node" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.eks_addon_node.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "workload_node" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.eks_workload_node.name
  policy_arn = each.value
}

########################
# EKS Cluster
########################

resource "aws_security_group" "eks_cluster" {
  name        = "wsc2026-eks-cluster-sg"
  description = "EKS Cluster SG"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/16"]
  }

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-eks-cluster-sg" }
}

resource "aws_eks_cluster" "cluster" {
  name     = "wsc2026-eks-cluster"
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.app_a.id, aws_subnet.app_b.id]
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks.arn }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

########################
# Access Entries
########################

resource "aws_eks_access_entry" "root" {
  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = "arn:aws:iam::${local.account_id}:root"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "root" {
  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = "arn:aws:iam::${local.account_id}:root"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.root]
}

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.bastion]
}

########################
# Node Groups
########################

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "wsc2026-addon-nodegroup"
  node_role_arn   = aws_iam_role.eks_addon_node.arn
  subnet_ids      = [aws_subnet.app_a.id, aws_subnet.app_b.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = { "wsc2026/node" = "addon" }

  depends_on = [aws_iam_role_policy_attachment.addon_node]

  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
}

resource "aws_eks_node_group" "workload" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "wsc2026-workload-ng"
  node_role_arn   = aws_iam_role.eks_workload_node.arn
  subnet_ids      = [aws_subnet.app_a.id, aws_subnet.app_b.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = { "wsc2026/node" = "application" }

  depends_on = [aws_iam_role_policy_attachment.workload_node]

  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
}

########################
# Pod Identity for book app
########################

resource "aws_iam_role" "pod_identity" {
  name = "wsc2026-book-pod-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_policy" "pod_dynamodb" {
  name = "wsc2026-book-pod-dynamodb-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [aws_dynamodb_table.book.arn, "${aws_dynamodb_table.book.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.db.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "pod_dynamodb" {
  role       = aws_iam_role.pod_identity.name
  policy_arn = aws_iam_policy.pod_dynamodb.arn
}

resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.cluster.name
  namespace       = "wsc2026"
  service_account = "wsc2026-book-sa"
  role_arn        = aws_iam_role.pod_identity.arn
}
