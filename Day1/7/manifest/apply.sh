#!/bin/bash
set -x
export NUMBER=${number:-${NUMBER:-103}}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
WORKDIR=$(pwd)

# ============================================================
# apply.sh 자동으로:
# 1. book 이미지 빌드 & ECR push
# 2. ECR IMMUTABLE_WITH_EXCLUSION 설정
# 3. eksctl 클러스터 생성
# 4. EKS SG 허용 (CloudShell + VPC CIDR)
# 5. kubectl apply (namespace, SA, deployment, service, fluent-bit)
# 6. EC2 Name Tag 부여
# 7. Pod Identity Association
# 8. Pod restart + ALB Target 등록
# 9. helm install (Prometheus + Grafana)
# 10. Grafana ALB Target 등록
# 11. IAM 권한 설정
# ============================================================

# 0. cluster.yaml placeholder 치환
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[0].VpcId" --output text)
SUBNET_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-a --query "Subnets[0].SubnetId" --output text)
SUBNET_B=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-b --query "Subnets[0].SubnetId" --output text)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-c --query "Subnets[0].SubnetId" --output text)
KEY_ARN=$(aws kms describe-key --key-id alias/unicorn-kms-platform --query "KeyMetadata.Arn" --output text)
sed -i "s|VPC_ID|$VPC_ID|g; s|SUBNET_A|$SUBNET_A|g; s|SUBNET_B|$SUBNET_B|g; s|SUBNET_C|$SUBNET_C|g; s|KEY_ARN|$KEY_ARN|g" cluster.yaml

# helm 설치
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl 설치
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin

# --- 1. book 이미지 빌드 & ECR push ---
ECR_URL=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/unicorn-concert-app
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
mkdir -p /tmp/docker && cp book Dockerfile /tmp/docker/ && chmod +x /tmp/docker/book
cd /tmp/docker && docker build -t $ECR_URL:v1.0.0 -t $ECR_URL:latest . && docker push $ECR_URL:v1.0.0 && docker push $ECR_URL:latest
cd $WORKDIR

# --- 2. ECR IMMUTABLE_WITH_EXCLUSION ---
aws ecr put-image-tag-mutability --repository-name unicorn-concert-app \
  --image-tag-mutability IMMUTABLE_WITH_EXCLUSION \
  --image-tag-mutability-exclusion-filters "filterType=WILDCARD,filter=latest"

# --- 3. EKS 클러스터 생성 ---
eksctl create cluster -f cluster.yaml

# --- 4. EKS SG 허용 (CloudShell + VPC CIDR) ---
CLUSTER_SG=$(aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
CLOUDSHELL_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-mark-sg --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --source-group $CLOUDSHELL_SG 2>/dev/null
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --cidr 10.97.0.0/16 2>/dev/null
aws eks update-kubeconfig --name unicorn-eks-cluster --region $REGION
source kubectl-connect unicorn-eks-cluster
# Access Entry for current user
aws eks create-access-entry --cluster-name unicorn-eks-cluster --principal-arn arn:aws:iam::${ACCOUNT}:root --type STANDARD 2>/dev/null
aws eks associate-access-policy --cluster-name unicorn-eks-cluster --principal-arn arn:aws:iam::${ACCOUNT}:root --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster 2>/dev/null

# --- 5. kubectl apply ---
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" deployment.yaml
kubectl apply -f namespace.yaml
kubectl apply -f monitoring-ns.yaml
kubectl apply -f serviceaccount.yaml

# --- 5.5 Pod Identity Association (before deployment so pods get credentials on first boot) ---
aws eks create-pod-identity-association \
  --cluster-name unicorn-eks-cluster \
  --namespace unicorn \
  --service-account unicorn-book-app-sa \
  --role-arn arn:aws:iam::$ACCOUNT:role/unicorn-book-app-role 2>/dev/null

kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f fluent-bit.yaml
kubectl rollout status deployment/unicorn-book-app-deploy -n unicorn --timeout=120s

# --- 6. EC2 Name Tag ---
for id in $(kubectl get nodes -l unicorn=app -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources $id --tags Key=Name,Value=unicorn-k8snode-app-node
done
for id in $(kubectl get nodes -l unicorn=addon -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources $id --tags Key=Name,Value=unicorn-k8snode-addon-node
done

# --- 7. (moved to step 5.5) ---

# --- 8. ALB Target 등록 ---
TG_ARN=$(aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].TargetGroupArn" --output text)
for ip in $(kubectl get pods -n unicorn -l app=book -o jsonpath='{.items[*].status.podIP}'); do
  aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$ip,Port=8080
done

# --- 9. helm install (Prometheus + Grafana) ---
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm install unicorn-monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.nodeSelector.unicorn=addon \
  --set grafana.nodeSelector.unicorn=addon \
  --set grafana.adminUser="skills${NUMBER}" \
  --set grafana.adminPassword="HelloKrSkills!${NUMBER}@" \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set grafana.defaultDashboardsEnabled=false \
  --set alertmanager.alertmanagerSpec.nodeSelector.unicorn=addon \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeEtcd.enabled=false \
  --wait --timeout 600s

# --- 10. Grafana ALB Target 등록 ---
GTG_ARN=$(aws elbv2 describe-target-groups --names unicorn-grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)
for id in $(kubectl get nodes -l unicorn=addon -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws elbv2 register-targets --target-group-arn $GTG_ARN --targets Id=$id,Port=30300
done

# --- 11. IAM 권한 설정 ---
APP_NODE_ROLE=$(aws eks describe-nodegroup --cluster-name unicorn-eks-cluster --nodegroup-name app-ng --query "nodegroup.nodeRole" --output text | grep -oP 'role/\K.*')
ADDON_NODE_ROLE=$(aws eks describe-nodegroup --cluster-name unicorn-eks-cluster --nodegroup-name addon-ng --query "nodegroup.nodeRole" --output text | grep -oP 'role/\K.*')
aws iam attach-role-policy --role-name $APP_NODE_ROLE --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws iam attach-role-policy --role-name $ADDON_NODE_ROLE --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

# AllowAssumeAuditRole for current IAM user
CURRENT_USER=$(aws sts get-caller-identity --query "Arn" --output text | grep -oP 'user/\K.*')
if [ -z "$CURRENT_USER" ]; then
  CURRENT_USER="admin"
fi
aws iam put-user-policy --user-name $CURRENT_USER --policy-name AllowAssumeAuditRole \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"arn:aws:iam::${ACCOUNT}:role/unicorn-audit-role\"}]}"

# --- 12. Grafana Dashboard 생성 ---
GRAFANA_URL="http://$(aws elbv2 describe-load-balancers --names unicorn-grafana-alb --query 'LoadBalancers[0].DNSName' --output text)"
GRAFANA_CRED="skills${NUMBER}:HelloKrSkills!${NUMBER}@"

# Wait for Grafana to be ready
for i in $(seq 1 30); do
  if curl -sf -u "$GRAFANA_CRED" "$GRAFANA_URL/api/health" >/dev/null 2>&1; then break; fi
  sleep 5
done

# Add Prometheus datasource
curl -sf -u "$GRAFANA_CRED" -X POST "$GRAFANA_URL/api/datasources" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"Prometheus","type":"prometheus","access":"proxy",
    "url":"http://unicorn-monitoring-kube-pr-prometheus.monitoring.svc.cluster.local:9090",
    "isDefault":true
  }' 2>/dev/null

DS_UID=$(curl -sf -u "$GRAFANA_CRED" "$GRAFANA_URL/api/datasources/name/Prometheus" | grep -oP '"uid":"\K[^"]+')

# Create dashboard
curl -sf -u "$GRAFANA_CRED" -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Content-Type: application/json" \
  -d "{
  \"dashboard\": {
    \"title\": \"unicorn-grafana-dashboard\",
    \"panels\": [
      {
        \"id\": 1,
        \"title\": \"EKS Node CPU Usage (%)\",
        \"type\": \"timeseries\",
        \"gridPos\": {\"h\":10,\"w\":12,\"x\":0,\"y\":0},
        \"targets\": [{\"expr\":\"100 - (avg by(instance)(rate(node_cpu_seconds_total{mode=\\\"idle\\\"}[5m])) * 100)\",\"refId\":\"A\",\"legendFormat\":\"{{instance}}\"}],
        \"datasource\": {\"type\":\"prometheus\",\"uid\":\"$DS_UID\"},
        \"options\": {\"legend\":{\"displayMode\":\"table\",\"placement\":\"right\",\"calcs\":[\"mean\",\"max\",\"lastNotNull\"]}},
        \"fieldConfig\": {\"defaults\":{\"unit\":\"percent\",\"decimals\":1},\"overrides\":[]}
      },
      {
        \"id\": 2,
        \"title\": \"EKS Node Memory Usage (%)\",
        \"type\": \"timeseries\",
        \"gridPos\": {\"h\":10,\"w\":12,\"x\":12,\"y\":0},
        \"targets\": [{\"expr\":\"(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100\",\"refId\":\"A\",\"legendFormat\":\"{{instance}}\"}],
        \"datasource\": {\"type\":\"prometheus\",\"uid\":\"$DS_UID\"},
        \"options\": {\"legend\":{\"displayMode\":\"table\",\"placement\":\"right\",\"calcs\":[\"mean\",\"max\",\"lastNotNull\"]}},
        \"fieldConfig\": {\"defaults\":{\"unit\":\"percent\",\"decimals\":1},\"overrides\":[]}
      },
      {
        \"id\": 3,
        \"title\": \"unicorn Namespace Pod Status\",
        \"type\": \"stat\",
        \"gridPos\": {\"h\":8,\"w\":8,\"x\":0,\"y\":10},
        \"targets\": [
          {\"expr\":\"sum(kube_pod_status_phase{namespace=\\\"unicorn\\\", phase=\\\"Failed\\\"})\",\"refId\":\"A\",\"legendFormat\":\"Failed\"},
          {\"expr\":\"sum(kube_pod_status_phase{namespace=\\\"unicorn\\\", phase=\\\"Pending\\\"})\",\"refId\":\"B\",\"legendFormat\":\"Pending\"},
          {\"expr\":\"sum(kube_pod_status_phase{namespace=\\\"unicorn\\\", phase=\\\"Running\\\"})\",\"refId\":\"C\",\"legendFormat\":\"Running\"},
          {\"expr\":\"sum(kube_pod_status_phase{namespace=\\\"unicorn\\\", phase=\\\"Succeeded\\\"})\",\"refId\":\"D\",\"legendFormat\":\"Succeeded\"},
          {\"expr\":\"sum(kube_pod_status_phase{namespace=\\\"unicorn\\\", phase=\\\"Unknown\\\"})\",\"refId\":\"E\",\"legendFormat\":\"Unknown\"}
        ],
        \"datasource\": {\"type\":\"prometheus\",\"uid\":\"$DS_UID\"},
        \"options\": {\"graphMode\":\"area\",\"textMode\":\"value_and_name\"},
        \"fieldConfig\": {\"defaults\":{},\"overrides\":[]}
      },
      {
        \"id\": 4,
        \"title\": \"Book App Ready Pods\",
        \"type\": \"stat\",
        \"gridPos\": {\"h\":8,\"w\":4,\"x\":8,\"y\":10},
        \"targets\": [{\"expr\":\"count(kube_pod_status_ready{namespace=\\\"unicorn\\\", condition=\\\"true\\\", pod=~\\\"unicorn-book-app.*\\\"} == 1)\",\"refId\":\"A\",\"legendFormat\":\"ready\"}],
        \"datasource\": {\"type\":\"prometheus\",\"uid\":\"$DS_UID\"},
        \"options\": {\"graphMode\":\"none\",\"textMode\":\"value_and_name\"},
        \"fieldConfig\": {\"defaults\":{},\"overrides\":[]}
      },
      {
        \"id\": 5,
        \"title\": \"Book App HTTP Request Duration\",
        \"type\": \"timeseries\",
        \"gridPos\": {\"h\":10,\"w\":12,\"x\":12,\"y\":10},
        \"targets\": [
          {\"expr\":\"quantile(0.5, rate(container_cpu_usage_seconds_total{namespace=\\\"unicorn\\\", container=\\\"book\\\"}[5m])) * 1000\",\"refId\":\"A\",\"legendFormat\":\"p50\"},
          {\"expr\":\"quantile(0.95, rate(container_cpu_usage_seconds_total{namespace=\\\"unicorn\\\", container=\\\"book\\\"}[5m])) * 1000\",\"refId\":\"B\",\"legendFormat\":\"p95\"},
          {\"expr\":\"quantile(0.99, rate(container_cpu_usage_seconds_total{namespace=\\\"unicorn\\\", container=\\\"book\\\"}[5m])) * 1000\",\"refId\":\"C\",\"legendFormat\":\"p99\"}
        ],
        \"datasource\": {\"type\":\"prometheus\",\"uid\":\"$DS_UID\"},
        \"options\": {\"legend\":{\"displayMode\":\"table\",\"placement\":\"right\",\"calcs\":[\"mean\",\"max\",\"lastNotNull\"]}},
        \"fieldConfig\": {\"defaults\":{\"unit\":\"ms\",\"decimals\":3},\"overrides\":[]}
      }
    ],
    \"schemaVersion\": 39,
    \"version\": 0
  },
  \"overwrite\": true
}"

echo "===== All Done! ====="
