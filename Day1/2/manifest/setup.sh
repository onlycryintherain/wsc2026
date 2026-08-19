#!/bin/bash
set -euo pipefail

export HOME=/root
export PATH=$PATH:/usr/local/bin

LOG_HOME="/home/${SUDO_USER:-cloudshell-user}"
if [ ! -d "$LOG_HOME" ]; then
  LOG_HOME="/home/cloudshell-user"
fi
if [ ! -d "$LOG_HOME" ]; then
  LOG_HOME="$HOME"
fi
LOG_FILE="${SETUP_LOG_FILE:-$LOG_HOME/wskorea26-setup-$(date -u +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

set -x
echo "Setup log: $LOG_FILE"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
ECR=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws configure set region $REGION
aws configure set cli_pager ""
export AWS_PAGER=""
grep -q AWS_PAGER ~/.bashrc || echo 'export AWS_PAGER=""' >> ~/.bashrc

BUCKET=$(aws s3 ls | awk '/wskorea26-manifest-/ {print $3; exit}')

upload_log() {
  local status=$?
  set +e
  echo "Setup exit code: $status"
  echo "Local log: $LOG_FILE"
  if [ -n "${BUCKET:-}" ]; then
    aws s3 cp "$LOG_FILE" "s3://$BUCKET/logs/$(basename "$LOG_FILE")" >/dev/null 2>&1
    echo "S3 log: s3://$BUCKET/logs/$(basename "$LOG_FILE")"
  fi
  exit $status
}
trap upload_log EXIT

mkdir -p /tmp/wskorea26 && cd /tmp/wskorea26
aws s3 cp s3://$BUCKET/ . --recursive

sudo yum install -y docker jq
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
  sudo systemctl enable --now docker
else
  sudo service docker start 2>/dev/null || true
fi

sudo usermod -aG docker ec2-user 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/eksctl

aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $ECR
chmod +x book
aws ecr batch-delete-image --repository-name wskorea26-book-repo --image-ids imageTag=stable 2>/dev/null || true
sudo docker build --no-cache -t $ECR/wskorea26-book-repo:stable .
sudo docker push $ECR/wskorea26-book-repo:stable
sudo docker image rm $ECR/wskorea26-book-repo:stable 2>/dev/null || true
sudo docker system prune -af 2>/dev/null || true

VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=wskorea26-vpc --query "Vpcs[0].VpcId" --output text)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=wskorea26-priv-subnet-c --query "Subnets[0].SubnetId" --output text)
SUBNET_D=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=wskorea26-priv-subnet-d --query "Subnets[0].SubnetId" --output text)
EKS_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-eks-key --query "KeyMetadata.Arn" --output text)
sed -i "s|VPC_ID|$VPC_ID|g; s|SUBNET_C|$SUBNET_C|g; s|SUBNET_D|$SUBNET_D|g; s|EKS_KEY_ARN|$EKS_KEY_ARN|g" cluster.yaml

eksctl create cluster -f cluster.yaml || true

aws eks wait cluster-active --name wskorea26-cluster
aws eks wait nodegroup-active --cluster-name wskorea26-cluster --nodegroup-name wskorea26-addon-ng
aws eks wait nodegroup-active --cluster-name wskorea26-cluster --nodegroup-name wskorea26-app-ng

CLUSTER_SG=$(aws eks describe-cluster --name wskorea26-cluster --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --cidr 0.0.0.0/0 2>/dev/null || true

BASTION_ROLE_ARN=$(aws sts get-caller-identity --query Arn --output text | sed 's|assumed-role/\(.*\)/.*|role/\1|; s|:sts::|:iam::|')
aws eks create-access-entry --cluster-name wskorea26-cluster --principal-arn $BASTION_ROLE_ARN --type STANDARD 2>/dev/null || true
aws eks associate-access-policy --cluster-name wskorea26-cluster --principal-arn $BASTION_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster 2>/dev/null || true
aws eks create-access-entry --cluster-name wskorea26-cluster --principal-arn arn:aws:iam::${ACCOUNT}:root --type STANDARD 2>/dev/null || true
aws eks associate-access-policy --cluster-name wskorea26-cluster --principal-arn arn:aws:iam::${ACCOUNT}:root \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster 2>/dev/null || true
rm -f ~/.kube/config
aws eks update-kubeconfig --name wskorea26-cluster --region $REGION

# Wait for access entry propagation
sleep 30

sed -i "s|ACCOUNT_ID|$ACCOUNT|g" deployment.yaml
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" grafana-values.yaml
# IRSA: Get OIDC provider info and update IAM roles
BOOK_APP_ROLE=$(aws iam list-roles --output json | jq -r '[.Roles[] | select(.RoleName | startswith("wskorea26-book-app-role-"))] | sort_by(.CreateDate) | last | .RoleName')
OIDC_ISSUER=$(aws eks describe-cluster --name wskorea26-cluster --query 'cluster.identity.oidc.issuer' --output text)
OIDC_ID=$(echo $OIDC_ISSUER | awk -F'/' '{print $NF}')
OIDC_PROVIDER="oidc.eks.ap-northeast-2.amazonaws.com/id/$OIDC_ID"

aws iam update-assume-role-policy --role-name $BOOK_APP_ROLE --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:wskorea26:book-sa\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}"

aws iam create-role --role-name wskorea26-fluentbit-role \
  --assume-role-policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:logging:fluentbit-sa\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}" 2>/dev/null || aws iam update-assume-role-policy --role-name wskorea26-fluentbit-role --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:logging:fluentbit-sa\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}"
aws iam put-role-policy --role-name wskorea26-fluentbit-role --policy-name logs-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource":"*"}]}'

aws iam create-role --role-name wskorea26-grafana-role \
  --assume-role-policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:monitoring:grafana\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}" 2>/dev/null || aws iam update-assume-role-policy --role-name wskorea26-grafana-role --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_PROVIDER}\" },
    \"Action\": \"sts:AssumeRoleWithWebIdentity\",
    \"Condition\": {
      \"StringEquals\": {
        \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:monitoring:grafana\",
        \"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
      }
    }
  }]
}"
aws iam put-role-policy --role-name wskorea26-grafana-role --policy-name cw-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:*","cloudwatch:*"],"Resource":"*"}]}'

chmod +x install-aws-load-balancer-controller.sh
bash install-aws-load-balancer-controller.sh

kubectl apply -f namespace.yaml
kubectl apply -f serviceaccount.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f fluentbit.yaml

# IRSA: Annotate ServiceAccounts with IAM role ARN
kubectl annotate serviceaccount book-sa -n wskorea26 \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT}:role/$BOOK_APP_ROLE --overwrite
kubectl annotate serviceaccount fluentbit-sa -n logging \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT}:role/wskorea26-fluentbit-role --overwrite

for id in $(kubectl get nodes -l node-type=addon -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources "$id" --tags Key=Name,Value=wskorea26-addon-node
done
for id in $(kubectl get nodes -l node-type=app -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources "$id" --tags Key=Name,Value=wskorea26-app-node
done

kubectl rollout restart deployment book-deploy -n wskorea26
kubectl rollout restart daemonset wskorea26-fluentbit -n logging
kubectl rollout status deployment/book-deploy -n wskorea26 --timeout=300s

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring --create-namespace \
  -f prometheus-values.yaml \
  --wait --timeout 300s

helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f grafana-values.yaml \
  --set service.type=ClusterIP \
  --set serviceAccount.create=true \
  --set serviceAccount.name=grafana \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=arn:aws:iam::${ACCOUNT}:role/wskorea26-grafana-role" \
  --wait --timeout 300s

kubectl rollout restart deployment grafana -n monitoring
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=180s

LAMBDA_TG_ARN=$(aws elbv2 describe-target-groups \
  --names wskorea26-book-lambda-tg \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)
sed -i "s|LAMBDA_TARGET_GROUP_ARN|$LAMBDA_TG_ARN|g" ingress.yaml
kubectl apply -f ingress.yaml

# ALB Controller versions may reconcile the rule before URL transforms are ready.
# Apply the required /book -> /v1/book transform after the Ingress rule exists.
BOOK_INGRESS_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names wskorea26-book-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
BOOK_INGRESS_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$BOOK_INGRESS_ALB_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text)
BOOK_POST_RULE_ARN=$(aws elbv2 describe-rules \
  --listener-arn "$BOOK_INGRESS_LISTENER_ARN" \
  --query "Rules[?Priority=='1'].RuleArn | [0]" \
  --output text)
aws elbv2 modify-rule \
  --rule-arn "$BOOK_POST_RULE_ARN" \
  --transforms '[{"Type":"url-rewrite","UrlRewriteConfig":{"Rewrites":[{"Regex":"^/book$","Replace":"/v1/book"}]}}]'

kubectl get ingress -A

echo "===== Setup Complete ====="

CF_DOMAIN=$(aws cloudfront list-distributions --query 'DistributionList.Items[?Comment==`wskorea26-concert-cf`].DomainName | [0]' --output text)
echo "CloudFront: $CF_DOMAIN"
echo "Book Ingress: $(kubectl get ingress book-ingress -n wskorea26 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Grafana Ingress: $(kubectl get ingress grafana-ingress -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
