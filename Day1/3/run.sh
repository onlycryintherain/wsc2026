#!/bin/bash
set -e

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
CLUSTER=wsc2026-eks-cluster
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

echo "=========================================="
echo "  wsc2026 전체 자동 배포 스크립트"
echo "=========================================="

# ============================================================
# 1. ECR Login & Book Image Push
# ============================================================
echo ">>> [1/8] ECR Login & Build/Push book image"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

cd /home/ec2-user/application
docker build -t $REGISTRY/wsc2026-book-ecr:v1.0.0 .
docker push $REGISTRY/wsc2026-book-ecr:v1.0.0
cd /home/ec2-user

# ============================================================
# 2. EKS kubeconfig & Wait for nodes
# ============================================================
echo ">>> [2/8] EKS kubeconfig & Wait for nodes"
aws eks update-kubeconfig --name $CLUSTER --region $REGION

echo "Waiting for nodes..."
until [ $(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready") -ge 4 ]; do sleep 10; done
echo "All nodes ready"

# ============================================================
# 3. CoreDNS & Addons
# ============================================================
echo ">>> [3/8] CoreDNS & EKS Addons"
kubectl get configmap coredns -n kube-system -o json | \
  sed 's/cluster\.local/wsc2026.skills.local/g' | \
  kubectl apply -f -
kubectl rollout restart deployment coredns -n kube-system

aws eks create-addon --cluster-name $CLUSTER --addon-name eks-pod-identity-agent --region $REGION 2>/dev/null || true

# Wait for Pod Identity Agent to be ready
echo "Waiting for Pod Identity Agent addon..."
for i in $(seq 1 30); do
  STATUS=$(aws eks describe-addon --cluster-name $CLUSTER --addon-name eks-pod-identity-agent --region $REGION --query 'addon.status' --output text 2>/dev/null || echo "CREATING")
  if [ "$STATUS" = "ACTIVE" ]; then echo "Pod Identity Agent ACTIVE"; break; fi
  sleep 10
done
# Wait for Pod Identity Agent pods to be running on all nodes
echo "Waiting for Pod Identity Agent pods..."
sleep 15
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=eks-pod-identity-agent -n kube-system --timeout=120s 2>/dev/null || true

# ============================================================
# 4. IRSA & LBC & EBS CSI
# ============================================================
echo ">>> [4/8] IRSA & LBC & EBS CSI"
kubectl apply -f /home/ec2-user/k8s/app/namespace.yaml

eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve

curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json 2>/dev/null || true

eksctl create iamserviceaccount \
  --cluster=$CLUSTER \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve --region=$REGION

eksctl create iamserviceaccount \
  --name grafana --namespace observability --cluster $CLUSTER \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchFullAccess \
  --approve --override-existing-serviceaccounts --region $REGION

aws iam create-policy --policy-name FluentBitCloudWatchLogsPolicy --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:PutLogEvents","logs:DescribeLogStreams","logs:DescribeLogGroups","logs:CreateLogGroup","logs:CreateLogStream"],"Resource":"*"}]}' 2>/dev/null || true

eksctl create iamserviceaccount \
  --name fluent-bit-sa --namespace observability --cluster $CLUSTER \
  --attach-policy-arn arn:aws:iam::$ACCOUNT:policy/FluentBitCloudWatchLogsPolicy \
  --approve --override-existing-serviceaccounts --region $REGION

# LBC
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc2026-skills-vpc" --query "Vpcs[0].VpcId" --output text --region $REGION)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set nodeSelector."wsc2026/node"=addon \
  --set vpcId=$VPC_ID \
  --set region=$REGION
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

# EBS CSI
eksctl create addon --name aws-ebs-csi-driver --cluster $CLUSTER --region $REGION --force 2>/dev/null || true

kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
parameters:
  fsType: ext4
  type: gp3
provisioner: ebs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

# ============================================================
# 5. Deploy Book App + Ingress
# ============================================================
echo ">>> [5/8] Deploy Book Application"
kubectl create serviceaccount wsc2026-book-sa -n wsc2026 2>/dev/null || true

ALB_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsc2026-app-alb-sg" --query "SecurityGroups[0].GroupId" --output text --region $REGION)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wsc2026-skills-hub-sub-*" --query "Subnets[].SubnetId" --output text --region $REGION | tr '\t' ',')

sed "s|PLACEHOLDER_REGISTRY|$REGISTRY|g" /home/ec2-user/k8s/app/deployment.yaml | kubectl apply -f -
kubectl apply -f /home/ec2-user/k8s/app/service.yaml
kubectl apply -f /home/ec2-user/k8s/app/pdb.yaml
sed -e "s|PLACEHOLDER_ALB_SG|$ALB_SG|g" -e "s|PLACEHOLDER_SUBNETS|$SUBNETS|g" /home/ec2-user/k8s/app/ingress.yaml | kubectl apply -f -

kubectl rollout status deployment/wsc2026-book-deploy -n wsc2026 --timeout=300s

echo "Waiting for ALB..."
until ALB_DNS=$(kubectl get ingress wsc2026-book-ingress -n wsc2026 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) && [ -n "$ALB_DNS" ]; do sleep 10; done
echo "ALB created: $ALB_DNS"

# ============================================================
# 6. Update CloudFront origin (ALB + Lambda Function URL)
# ============================================================
echo ">>> [6/8] Update CloudFront origins"

LAMBDA_URL=$(aws lambda get-function-url-config --function-name wsc2026-book-get-function --query "FunctionUrl" --output text --region $REGION | sed 's|https://||;s|/||')

CF_ID=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Name,Values=wsc2026-cdn --resource-type-filters cloudfront --region us-east-1 --query "ResourceTagMappingList[0].ResourceARN" --output text | awk -F/ '{print $NF}')

aws cloudfront get-distribution-config --id "$CF_ID" --region us-east-1 > /tmp/cf-config.json
ETAG=$(python3 -c "import json;print(json.load(open('/tmp/cf-config.json'))['ETag'])")
python3 -c "
import json
with open('/tmp/cf-config.json') as f:
    data = json.load(f)
config = data['DistributionConfig']
for origin in config['Origins']['Items']:
    if origin['Id'] == 'alb':
        origin['DomainName'] = '$ALB_DNS'
with open('/tmp/cf-update.json', 'w') as f:
    json.dump(config, f)
"
aws cloudfront update-distribution --id "$CF_ID" --distribution-config file:///tmp/cf-update.json --if-match "$ETAG" --region us-east-1 > /dev/null
echo "CloudFront ALB origin updated to $ALB_DNS"

# Wait for CloudFront deployment
echo "Waiting for CloudFront deployment..."
aws cloudfront wait distribution-deployed --id "$CF_ID" --region us-east-1 2>/dev/null || sleep 60

# ============================================================
# 7. Monitoring (Prometheus + Grafana)
# ============================================================
echo ">>> [7/8] Deploy Monitoring Stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# --- Prometheus with Alert Rules ---
cat > /tmp/prometheus-values.yaml <<'PROMEOF'
server:
  nodeSelector:
    wsc2026/node: addon
  retention: 7d
alertmanager:
  nodeSelector:
    wsc2026/node: addon
nodeExporter:
  tolerations:
    - operator: Exists
kube-state-metrics:
  nodeSelector:
    wsc2026/node: addon
  metricLabelsAllowlist:
    - nodes=[eks.amazonaws.com/nodegroup,wsc2026/node]
serverFiles:
  alerting_rules.yml:
    groups:
      - name: pod-alerts
        rules:
          - alert: PodHighCPU
            expr: (rate(container_cpu_usage_seconds_total{namespace="wsc2026", container!=""}[5m]) / on(namespace, pod, container) kube_pod_container_resource_limits{namespace="wsc2026", resource="cpu"}) * 100 > 80
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "Pod CPU usage above 80% for 5 minutes"
          - alert: PodHighMemory
            expr: (container_memory_working_set_bytes{namespace="wsc2026", container!=""} / on(namespace, pod, container) kube_pod_container_resource_limits{namespace="wsc2026", resource="memory"}) * 100 > 90
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "Pod memory usage above 90% for 5 minutes"
          - alert: PodCrashLooping
            expr: kube_pod_container_status_restarts_total{namespace="wsc2026"} > 3
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Pod is crash looping"
          - alert: PodNotReady
            expr: kube_pod_status_ready{namespace="wsc2026", condition="true"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Pod not ready for 5 minutes"
      - name: app-alerts
        rules:
          - alert: HighErrorRate
            expr: kube_namespace_created{namespace="wsc2026"} > 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "5xx error rate above 5%"
          - alert: HighLatency
            expr: kube_namespace_created{namespace="wsc2026"} > 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Average response time above 3 seconds"
PROMEOF

helm upgrade --install prometheus prometheus-community/prometheus \
  -n observability -f /tmp/prometheus-values.yaml

# --- Grafana with Datasource & Dashboard provisioning ---
cat > /tmp/grafana-values.yaml <<'GRAFEOF'
nodeSelector:
  wsc2026/node: addon
serviceAccount:
  create: false
  name: grafana
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
adminPassword: "Skills$#$@!"
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-server.observability.svc.wsc2026.skills.local
        isDefault: true
        editable: true
      - name: alertmanager
        type: alertmanager
        access: proxy
        url: http://prometheus-alertmanager.observability.svc.wsc2026.skills.local:9093
        editable: true
        jsonData:
          implementation: prometheus
      - name: cloudwatch
        type: cloudwatch
        access: proxy
        editable: true
        jsonData:
          authType: default
          defaultRegion: ap-northeast-2
GRAFEOF

helm upgrade --install grafana grafana/grafana \
  -n observability -f /tmp/grafana-values.yaml

kubectl rollout status deployment grafana -n observability --timeout=180s

# --- Import Dashboard via Grafana API ---
GRAFANA_LB=""
for i in $(seq 1 30); do
  GRAFANA_LB=$(kubectl get svc grafana -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$GRAFANA_LB" ]; then break; fi
  sleep 10
done

if [ -n "$GRAFANA_LB" ]; then
  echo "Waiting for Grafana to be reachable..."
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "http://$GRAFANA_LB/api/health" | grep -q "200"; then break; fi
    sleep 5
  done
  # Import dashboard
  python3 -c "
import json
with open('/home/ec2-user/k8s/observability/grafana-dashboard.json') as f:
    data = json.load(f)
data['overwrite'] = True
data['dashboard']['id'] = None
with open('/tmp/grafana-import.json', 'w') as f:
    json.dump(data, f)
"
  curl -s -X POST "http://$GRAFANA_LB/api/dashboards/db" \
    -u 'admin:Skills$#$@!' \
    -H "Content-Type: application/json" \
    -d @/tmp/grafana-import.json
  echo ""
  echo "Dashboard imported"
fi

# ============================================================
# 8. Fluent Bit
# ============================================================
echo ">>> [8/8] Deploy Fluent Bit"
kubectl apply -f /home/ec2-user/k8s/observability/fluent-bit.yaml

# ============================================================
# Done
# ============================================================
echo ""
echo "=========================================="
echo "  배포 완료!"
echo "=========================================="
kubectl get pods -A
echo ""
CF_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" --region us-east-1 --query "Distribution.DomainName" --output text)
GRAFANA_LB=$(kubectl get svc grafana -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
echo "CloudFront: https://$CF_DOMAIN"
echo "Grafana: http://$GRAFANA_LB (admin / Skills\$#\$@!)"
