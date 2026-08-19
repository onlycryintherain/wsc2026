#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""
REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-wskorea26-cluster}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

ROLE_NAME="${AWS_LB_CONTROLLER_ROLE_NAME:-wskorea26-aws-lb-controller-role}"
POLICY_NAME="${AWS_LB_CONTROLLER_POLICY_NAME:-AWSLoadBalancerControllerIAMPolicy}"
CHART_VERSION="${AWS_LB_CONTROLLER_CHART_VERSION:-1.13.0}"
POLICY_VERSION="${AWS_LB_CONTROLLER_POLICY_VERSION:-2.13.0}"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"

# The controller requires an IAM OIDC provider. This is idempotent when it already exists.
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve

OIDC_ISSUER="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' \
  --output text)"
OIDC_ID="$(echo "$OIDC_ISSUER" | awk -F/ '{print $NF}')"
OIDC_PROVIDER="oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Download the pinned controller policy instead of embedding a large policy in the script.
curl --fail --silent --show-error --location \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${POLICY_VERSION}/docs/install/iam_policy.json" \
  --output "$TMP_DIR/iam_policy.json"

aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://${TMP_DIR}/iam_policy.json" \
  >/dev/null 2>&1 || true

cat > "$TMP_DIR/trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_PROVIDER_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://${TMP_DIR}/trust-policy.json" \
  --description "IRSA role for AWS Load Balancer Controller" \
  >/dev/null 2>&1 || \
aws iam update-assume-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-document "file://${TMP_DIR}/trust-policy.json"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

kubectl create namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create serviceaccount aws-load-balancer-controller \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl annotate serviceaccount aws-load-balancer-controller \
  --namespace kube-system \
  "eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}" \
  --overwrite

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "$CHART_VERSION" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait \
  --timeout 300s

kubectl rollout status deployment/aws-load-balancer-controller \
  --namespace kube-system \
  --timeout=300s

printf '\nAWS Load Balancer Controller is ready.\n'
kubectl get deployment,pod \
  --namespace kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller
