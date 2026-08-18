output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_url" {
  value = local.oidc_url
}

output "node_role_name" {
  value = aws_iam_role.eks_node.name
}

output "node_role_arn" {
  value = aws_iam_role.eks_node.arn
}
