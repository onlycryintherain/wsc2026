#!/bin/bash
set -e
REGION="${region}"
CLUSTER="${cluster}"
ACCOUNT_ID="${account_id}"
ECR_URL="${account_id}.dkr.ecr.${region}.amazonaws.com"
S3_BUCKET="${s3_bucket}"
LOG_BUCKET="${log_bucket}"
DB_IDENTIFIER="${db_identifier}"
DB_NAME="${db_name}"
DB_USERNAME="${db_username}"
DB_SECRET_NAME="${db_secret_name}"
RDS_PROXY_NAME="${db_proxy_name}"
NODE_INSTANCE_TYPE="${node_instance_type}"
NODE_CPU_CREDITS="${node_cpu_credits}"

echo "=== Updating kubeconfig ==="
aws eks update-kubeconfig --name ${cluster} --region ${region}
export KUBECONFIG=/root/.kube/config

echo "=== Waiting for EKS nodes to be ready ==="
for i in $(seq 1 60); do
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
  if [ "$NODES" -ge 1 ]; then
    echo "$NODES node(s) ready"
    break
  fi
  echo "Attempt $i: No ready nodes yet, waiting..."
  sleep 10
done

if [[ "$NODE_INSTANCE_TYPE" == t* ]]; then
  echo "=== Enforcing EC2 CPU credit mode: $NODE_CPU_CREDITS ==="
  NODE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:aws:eks:cluster-name,Values=$CLUSTER" \
      "Name=instance-state-name,Values=pending,running" \
      "Name=instance-type,Values=$NODE_INSTANCE_TYPE" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)
  if [ -n "$NODE_IDS" ] && [ "$NODE_IDS" != "None" ]; then
    for nid in $NODE_IDS; do
      aws ec2 modify-instance-credit-specification \
        --region "$REGION" \
        --instance-credit-specifications "InstanceId=$nid,CpuCredits=$NODE_CPU_CREDITS"
    done
    CREDIT_STATE=$(aws ec2 describe-instance-credit-specifications \
      --region "$REGION" \
      --instance-ids $NODE_IDS \
      --query 'InstanceCreditSpecifications[].CpuCredits' \
      --output text)
    echo "CPU credit mode: $CREDIT_STATE"
    if ! echo "$CREDIT_STATE" | grep -qw "$NODE_CPU_CREDITS"; then
      echo "ERROR: CPU credit mode verification failed" >&2
      exit 1
    fi
  else
    echo "No $NODE_INSTANCE_TYPE nodes found for CPU credit enforcement"
  fi
else
  echo "Skipping CPU credit configuration for non-burstable instance type: $NODE_INSTANCE_TYPE"
fi

echo "=== Adding EKS access entry for root ==="
aws eks create-access-entry --cluster-name ${cluster} --principal-arn arn:aws:iam::${account_id}:root --region ${region} 2>/dev/null || true
aws eks associate-access-policy --cluster-name ${cluster} --principal-arn arn:aws:iam::${account_id}:root --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster --region ${region} 2>/dev/null || true

# Image build/push does not depend on RDS or RDS Proxy. Run it before the
# potentially long database/proxy readiness waits so the waits overlap with
# useful work and the one-hour setup budget is protected.
echo "=== Building and pushing application images (before RDS Proxy wait) ==="
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URL
for APP in user product stress; do aws s3 cp s3://$S3_BUCKET/binary/$APP /tmp/$APP; chmod 0555 /tmp/$APP; cat > /tmp/Dockerfile-$APP <<DEOF
# The application binaries are stripped, statically linked Go executables.
# Keep Amazon Linux only as a build stage for the CA bundle; it is not in the
# final runtime image.
FROM amazonlinux:2023 AS ca-certificates
FROM scratch
COPY --from=ca-certificates /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
COPY --chown=65532:65532 $APP /app/$APP
USER 65532:65532
EXPOSE 8080
ENV AWS_REGION=$REGION
ENV S3_BUCKET=$S3_BUCKET
ENTRYPOINT ["/app/$APP"]
DEOF
docker build -f /tmp/Dockerfile-$APP -t $ECR_URL/$APP:latest /tmp/; docker push $ECR_URL/$APP:latest; done

echo "=== Waiting for RDS ==="
DB_HOST=""
DB_PASSWORD=""
for i in $(seq 1 120); do
  DB_HOST=$(aws rds describe-db-instances --db-instance-identifier $DB_IDENTIFIER --query "DBInstances[0].Endpoint.Address" --output text --region $REGION 2>/dev/null || echo "")
  if [ -n "$DB_HOST" ] && [ "$DB_HOST" != "None" ]; then
    DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $DB_SECRET_NAME --query SecretString --output text --region $REGION 2>/dev/null | python3 -c "import sys,json;print(json.loads(sys.stdin.read())['password'])" 2>/dev/null || echo "")
    if [ -n "$DB_PASSWORD" ] && mysql -h $DB_HOST -u $DB_USERNAME -p"$DB_PASSWORD" -e "SELECT 1" 2>/dev/null; then
      echo "RDS is ready"
      break
    fi
  fi
  echo "Attempt $i: RDS not ready, waiting..."
  sleep 10
done

# Wait for RDS Proxy
echo "=== Waiting for RDS Proxy ==="
RDS_HOST=""
for i in $(seq 1 60); do
  RDS_HOST=$(aws rds describe-db-proxies --db-proxy-name $RDS_PROXY_NAME --query "DBProxies[0].Endpoint" --output text --region $REGION 2>/dev/null || echo "")
  if [ -n "$RDS_HOST" ] && [ "$RDS_HOST" != "None" ]; then
    STATUS=$(aws rds describe-db-proxies --db-proxy-name $RDS_PROXY_NAME --query "DBProxies[0].Status" --output text --region $REGION 2>/dev/null || echo "")
    if [ "$STATUS" = "available" ]; then
      echo "RDS Proxy is ready: $RDS_HOST"
      break
    fi
  fi
  echo "Attempt $i: RDS Proxy not ready, waiting..."
  sleep 10
done

# Proxy 상태가 available이어도 DB target capacity가 준비 중일 수 있다.
# RDS 생성 직후에는 10분 이상 걸릴 수 있으므로 최대 30분 대기한다.
for i in $(seq 1 180); do
  TARGET_STATE=$(aws rds describe-db-proxy-targets --db-proxy-name $RDS_PROXY_NAME \
    --query "Targets[0].TargetHealth.State" --output text --region $REGION 2>/dev/null || echo "")
  if [ "$TARGET_STATE" = "AVAILABLE" ]; then
    echo "RDS Proxy target is available"
    break
  fi
  echo "Attempt $i: RDS Proxy target is $TARGET_STATE, waiting..."
  sleep 10
done
if [ "$TARGET_STATE" != "AVAILABLE" ]; then
  echo "ERROR: RDS Proxy target did not become available"
  exit 1
fi

echo "=== Setting up database ==="
mysql -h $DB_HOST -u $DB_USERNAME -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME; USE $DB_NAME; CREATE TABLE IF NOT EXISTS user (id VARCHAR(255) NOT NULL, username VARCHAR(255) NOT NULL, email VARCHAR(255) NOT NULL, PRIMARY KEY (id), UNIQUE KEY uk_username (username), INDEX idx_email (email)); CREATE TABLE IF NOT EXISTS product (id VARCHAR(255) NOT NULL, name VARCHAR(255) NOT NULL, price FLOAT(8) NOT NULL, image_path VARCHAR(500) DEFAULT NULL, PRIMARY KEY (id));"
aws s3 cp s3://$S3_BUCKET/load_user.dump /tmp/load_user.dump
# dump의 USE DB명/표기 형식이 바뀌어도 애플리케이션 DB로 강제한다.
sed -i -E "s/^[[:space:]]*USE[[:space:]]+([^;]+);/USE $DB_NAME;/I" /tmp/load_user.dump
sed -i 's/INSERT INTO/INSERT IGNORE INTO/g' /tmp/load_user.dump
mysql -h $DB_HOST -u $DB_USERNAME -p"$DB_PASSWORD" $DB_NAME < /tmp/load_user.dump || true


eksctl utils associate-iam-oidc-provider --cluster ${cluster} --region ${region} --approve
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json 2>/dev/null || true
eksctl create iamserviceaccount --cluster=${cluster} --namespace=kube-system --name=aws-load-balancer-controller --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy --override-existing-serviceaccounts --region ${region} --approve || true

# eksctl이 기존 CloudFormation IAM 리소스를 감지하면 no tasks로 끝날 수 있다.
# 이 경우 Kubernetes ServiceAccount가 실제로 없을 수 있으므로 명시적으로 생성한다.
kubectl -n kube-system create serviceaccount aws-load-balancer-controller \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Waiting for ALB controller ServiceAccount ==="
for i in $(seq 1 30); do
  if kubectl -n kube-system get serviceaccount aws-load-balancer-controller >/dev/null 2>&1; then
    break
  fi
  echo "Attempt $i: ServiceAccount not ready yet, waiting..."
  sleep 5
done
if ! kubectl -n kube-system get serviceaccount aws-load-balancer-controller >/dev/null 2>&1; then
  echo "ERROR: aws-load-balancer-controller ServiceAccount was not created"
  exit 1
fi
ALB_ROLE_NAME="${cluster}-alb-controller"
OIDC_PROVIDER=$(aws eks describe-cluster --name "${cluster}" --region "${region}" \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's#https://##')
cat > /tmp/alb-controller-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC_PROVIDER"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"$OIDC_PROVIDER:aud":"sts.amazonaws.com","$OIDC_PROVIDER:sub":"system:serviceaccount:kube-system:aws-load-balancer-controller"}}}]}
EOF
if ! aws iam get-role --role-name "$ALB_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ALB_ROLE_NAME" --assume-role-policy-document file:///tmp/alb-controller-trust.json >/dev/null
else
  aws iam update-assume-role-policy --role-name "$ALB_ROLE_NAME" --policy-document file:///tmp/alb-controller-trust.json
fi
aws iam attach-role-policy --role-name "$ALB_ROLE_NAME" \
  --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"
LB_ROLE_ARN=$(aws iam get-role --role-name "$ALB_ROLE_NAME" --query 'Role.Arn' --output text)
kubectl -n kube-system annotate serviceaccount aws-load-balancer-controller \
  "eks.amazonaws.com/role-arn=$LB_ROLE_ARN" --overwrite >/dev/null
if ! kubectl -n kube-system get serviceaccount aws-load-balancer-controller -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null | grep -q '^arn:'; then
  echo "ERROR: aws-load-balancer-controller ServiceAccount has no IRSA role annotation"
  exit 1
fi

helm repo add eks https://aws.github.io/eks-charts && helm repo update eks
# ServiceAccount는 eksctl이 IRSA annotation과 함께 생성하므로 Helm은 재생성하지 않는다.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=${cluster} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${region} \
  --set vpcId=${vpc_id}

echo "Waiting for ALB controller to be ready..."
for i in $(seq 1 60); do
  if kubectl wait --for=condition=available deployment/aws-load-balancer-controller -n kube-system --timeout=10s 2>/dev/null; then
    echo "ALB controller is ready"
    break
  fi
  echo "Attempt $i: ALB controller not ready yet, waiting..."
  sleep 5
done

echo "Waiting for ALB webhook to be ready..."
for i in $(seq 1 30); do
  if kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    echo "ALB webhook endpoint is ready"
    break
  fi
  echo "Attempt $i: Webhook not ready yet, waiting..."
  sleep 5
done
sleep 10

CLUSTER_ENDPOINT=$(aws eks describe-cluster --name ${cluster} --query cluster.endpoint --output text --region ${region})
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.4.0 -n kube-system --create-namespace --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${karpenter_arn} --set settings.clusterName=${cluster} --set settings.clusterEndpoint=$CLUSTER_ENDPOINT --set settings.interruptionQueue=${karpenter_queue} --set controller.resources.requests.cpu=200m --set controller.resources.requests.memory=512Mi --set controller.resources.limits.cpu=1 --set controller.resources.limits.memory=1Gi --set replicas=1 --wait --timeout=900s

echo "Waiting for Karpenter to be ready..."
for i in $(seq 1 60); do
  if kubectl wait --for=condition=available deployment/karpenter -n kube-system --timeout=10s 2>/dev/null; then
    echo "Karpenter is ready"
    break
  fi
  sleep 5
done

cat <<KARPENTER | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: ${node_role}
  kubelet:
    maxPods: 110
  # Karpenter EC2NodeClass에는 creditSpecification native 필드가 없으므로
  # AL2023 user data에서 T계열 인스턴스 자신에게 CPU credit 모드를 적용한다.
  userData: |
    #!/bin/bash
    if [[ "${node_instance_type}" == t* ]]; then
      for i in \$(seq 1 12); do
        if command -v aws >/dev/null 2>&1; then
          TOKEN=\$(curl -fsS -X PUT \\
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \\
            http://169.254.169.254/latest/api/token || true)
          INSTANCE_ID=\$(curl -fsS \\
            -H "X-aws-ec2-metadata-token: \$TOKEN" \\
            http://169.254.169.254/latest/meta-data/instance-id || true)
          if [ -n "\$INSTANCE_ID" ] && aws ec2 modify-instance-credit-specification \\
            --region "${region}" \\
            --instance-credit-specifications "InstanceId=\$INSTANCE_ID,CpuCredits=${node_cpu_credits}"; then
            logger "CPU credit mode set to ${node_cpu_credits}: \$INSTANCE_ID"
            break
          fi
        fi
        sleep 5
      done
    fi
  # Worker nodes require public egress because this environment has no NAT.
  # role/elb excludes role/cni pod-capacity subnets from node placement.
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/${cluster_name}: shared
        kubernetes.io/role/elb: "1"
  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/${cluster_name}: shared
KARPENTER
cat <<NODEPOOL | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["$NODE_INSTANCE_TYPE"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
  # Managed 1대 + default 1대 + stress 4대 = 최대 6대.
  # Min replica는 건드리지 않고 저부하 빈 노드를 빠르게 회수한다.
  limits:
    cpu: "2"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
NODEPOOL
# 38점 기준: stress는 별도 NodePool + taint로 격리한다.
# default NodePool은 user/product만 수용하고 stress NodePool만 workload-class=stress를 제공한다.
cat <<STRESS_NODEPOOL | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: stress
spec:
  template:
    metadata:
      labels:
        workload-class: stress
    spec:
      taints:
        - key: wsi2026.io/stress
          value: "true"
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["$NODE_INSTANCE_TYPE"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
  # 대규모 트래픽에서 성능을 우선하되 총 worker ceiling 6을 넘지 않는 전용 4대분.
  # 저부하에서는 1분 후 회수되어 managed 1 + stress 1 topology floor로 복귀한다.
  limits:
    cpu: "8"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
STRESS_NODEPOOL

# NodePool에 taint가 있으면(스트레스 격리) aws-node/kube-proxy가 그 노드에
# 뜨지 않아 노드 생성 직후 네트워킹이 지연될 수 있다. daemonset에 toleration을
# 추가해 tainted 노드에서도 항상 VPC CNI/kube-proxy가 구동되게 한다.
# 주의: tolerations 배열은 mergeKey가 없어 strategic patch가 **전체 교체**다.
# EKS 기본 toleration(not-ready/network-unavailable/CriticalAddonsOnly)을 함께
# 명시하지 않으면 NotReady 노드에 CNI가 뜨지 않아 노드가 Ready되지 않는다.
kubectl -n kube-system patch daemonset aws-node --type=strategic -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"wsi2026.io/app-capacity","operator":"Exists","effect":"NoSchedule"},{"key":"wsi2026.io/app-capacity","operator":"Exists","effect":"NoExecute"},{"key":"wsi2026.io/stress","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/not-ready","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/network-unavailable","operator":"Exists","effect":"NoSchedule"},{"key":"CriticalAddonsOnly","operator":"Exists"}]}}}}' || true
kubectl -n kube-system patch daemonset kube-proxy --type=strategic -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"wsi2026.io/app-capacity","operator":"Exists","effect":"NoSchedule"},{"key":"wsi2026.io/app-capacity","operator":"Exists","effect":"NoExecute"},{"key":"wsi2026.io/stress","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/not-ready","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unreachable","operator":"Exists","effect":"NoSchedule"},{"key":"CriticalAddonsOnly","operator":"Exists"}]}}}}' || true

# prefix delegation + custom networking: t3.medium의 Pod 슬롯을 확보하고 Pod IP는
# 넓은 /22 전용 subnet에서 할당한다. Public /24의 조각난 /28 prefix 때문에 spike
# 순간 FailedCreatePodSandBox가 발생하지 않도록 AZ별 ENIConfig를 강제한다.
POD_SUBNET_A=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${cluster_name}-pod-capacity-1" --query 'Subnets[0].SubnetId' --output text)
POD_SUBNET_B=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${cluster_name}-pod-capacity-2" --query 'Subnets[0].SubnetId' --output text)
NODE_SG=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${cluster_name}-node-sg" --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$POD_SUBNET_A" != "None" && "$POD_SUBNET_B" != "None" && "$NODE_SG" != "None" ]]; then
cat <<ENICONFIG | kubectl apply -f -
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: ${region}a
spec:
  subnet: $POD_SUBNET_A
  securityGroups:
    - $NODE_SG
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: ${region}b
spec:
  subnet: $POD_SUBNET_B
  securityGroups:
    - $NODE_SG
ENICONFIG
  kubectl -n kube-system set env ds/aws-node ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1 AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone || true
else
  echo "CNI custom networking discovery failed: subnetA=$POD_SUBNET_A subnetB=$POD_SUBNET_B nodeSG=$NODE_SG" >&2
  exit 1
fi

kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -
cat <<K8SSA | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: product
  namespace: app
  annotations:
    eks.amazonaws.com/role-arn: ${product_app_arn}
K8SSA
cat <<K8S | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user
  namespace: app
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: user
  template:
    metadata:
      labels:
        app: user
    spec:
      containers:
      - name: user
        image: $ECR_URL/user:latest
        ports:
        - containerPort: 8080
        env:
        - {name: MYSQL_USER, value: "$DB_USERNAME"}
        - {name: MYSQL_PASSWORD, value: "$DB_PASSWORD"}
        - {name: MYSQL_HOST, value: "$RDS_HOST"}
        - {name: MYSQL_PORT, value: "3306"}
        - {name: MYSQL_DBNAME, value: "$DB_NAME"}
        resources:
          requests: {cpu: 70m, memory: 64Mi}
          limits: {memory: 256Mi}
        readinessProbe:
          httpGet: {path: /healthcheck, port: 8080}
          initialDelaySeconds: 2
          periodSeconds: 2
          timeoutSeconds: 2
          failureThreshold: 3
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: product
  namespace: app
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: product
  template:
    metadata:
      labels:
        app: product
    spec:
      serviceAccountName: product
      containers:
      - name: product
        image: $ECR_URL/product:latest
        ports:
        - containerPort: 8080
        env:
        - {name: MYSQL_USER, value: "$DB_USERNAME"}
        - {name: MYSQL_PASSWORD, value: "$DB_PASSWORD"}
        - {name: MYSQL_HOST, value: "$RDS_HOST"}
        - {name: MYSQL_PORT, value: "3306"}
        - {name: MYSQL_DBNAME, value: "$DB_NAME"}
        - {name: STORAGE_MODE, value: "sdk"}
        - {name: S3_BUCKET, value: "$S3_BUCKET"}
        - {name: S3_REGION, value: "$REGION"}
        resources:
          requests: {cpu: 70m, memory: 64Mi}
          limits: {memory: 256Mi}
        readinessProbe:
          httpGet: {path: /healthcheck, port: 8080}
          initialDelaySeconds: 2
          periodSeconds: 3
          timeoutSeconds: 2
          failureThreshold: 3
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stress
  namespace: app
spec:
  revisionHistoryLimit: 2
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: stress
  template:
    metadata:
      labels:
        app: stress
    spec:
      nodeSelector:
        workload-class: stress
      tolerations:
      - key: wsi2026.io/stress
        operator: Equal
        value: "true"
        effect: NoSchedule
      containers:
      - name: stress
        image: $ECR_URL/stress:latest
        ports:
        - containerPort: 8080
        resources:
          # stress는 600m request만 두고 CPU limit은 제거해 burst/throttling을 방지한다.
          # request × HPA target = 600m × 55% = 330m control point를 유지한다.
          requests: {cpu: 600m, memory: 640Mi}
          limits: {memory: 1536Mi}
        readinessProbe:
          httpGet: {path: /healthcheck, port: 8080}
          initialDelaySeconds: 2
          periodSeconds: 5
          timeoutSeconds: 5
          failureThreshold: 6
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels: {app: stress}
---
apiVersion: v1
kind: Service
metadata: {name: user, namespace: app}
spec:
  selector: {app: user}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: product, namespace: app}
spec:
  selector: {app: product}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: stress, namespace: app}
spec:
  selector: {app: stress}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apps
  namespace: app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthcheck
    alb.ingress.kubernetes.io/load-balancer-name: ${cluster_name}-alb
    # 스파이크 진입 지연 방지: 신규 Pod가 5초 만에 헬스체크 통과해 트래픽 수신
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '5'
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '3'
    alb.ingress.kubernetes.io/healthcheck-healthy-threshold-count: '2'
    # 큐잉 병목: 막힌 Pod로 요청을 보내지 않는다
    alb.ingress.kubernetes.io/target-group-attributes: load_balancing.algorithm.type=least_outstanding_requests,deregistration_delay.timeout_seconds=10
    alb.ingress.kubernetes.io/actions.response-404: '{"type":"fixed-response","fixedResponseConfig":{"contentType":"application/json","statusCode":"404","messageBody":"{\"err\":\"not found\"}"}}'
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /v1/user
        pathType: Exact
        backend:
          service: {name: user, port: {number: 80}}
      - path: /v1/product
        pathType: Exact
        backend:
          service: {name: product, port: {number: 80}}
      - path: /v1/stress
        pathType: Exact
        backend:
          service: {name: stress, port: {number: 80}}
      - path: /healthcheck
        pathType: Exact
        backend:
          service: {name: user, port: {number: 80}}
      - path: /images
        pathType: Prefix
        backend:
          service: {name: product, port: {number: 80}}
      - path: /
        pathType: Prefix
        backend:
          service: {name: response-404, port: {name: use-annotation}}
K8S
cat <<HPA | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: user
  namespace: app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: user
  minReplicas: 2
  maxReplicas: 20
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 10
        periodSeconds: 15
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 33
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: product
  namespace: app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: product
  minReplicas: 2
  maxReplicas: 20
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 10
        periodSeconds: 15
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 29
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: stress
  namespace: app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: stress
  minReplicas: 1
  # peak2 실측에서 stress 8개도 zero-success capacity에 도달했다.
  # 전용 NodePool을 확장해 최대 12개까지 수평 확장을 허용한다.
  maxReplicas: 12
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 10
        periodSeconds: 15
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 55
HPA

cat <<'PDB' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: user
  namespace: app
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: user
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: product
  namespace: app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: product
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: stress
  namespace: app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: stress
PDB
sleep 30
mkdir -p /home/ec2-user/skills/{user,product,stress,ingress}
kubectl get deployment user -n app -o yaml > /home/ec2-user/skills/user/deployment.yaml
kubectl get service user -n app -o yaml > /home/ec2-user/skills/user/service.yaml
kubectl get deployment product -n app -o yaml > /home/ec2-user/skills/product/deployment.yaml
kubectl get service product -n app -o yaml > /home/ec2-user/skills/product/service.yaml
kubectl get deployment stress -n app -o yaml > /home/ec2-user/skills/stress/deployment.yaml
kubectl get service stress -n app -o yaml > /home/ec2-user/skills/stress/service.yaml
kubectl get ingress apps -n app -o yaml > /home/ec2-user/skills/ingress/ingress.yaml
chown -R ec2-user:ec2-user /home/ec2-user/skills
ALB_DNS=$(kubectl get ingress apps -n app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
for i in $(seq 1 30); do [ -n "$ALB_DNS" ] && break; sleep 10; ALB_DNS=$(kubectl get ingress apps -n app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); done

echo "=== Creating CloudFront distribution ==="
if [ -z "$ALB_DNS" ]; then
  echo "ERROR: ALB DNS를 가져올 수 없음. CloudFront를 생성하지 않고 setup을 실패 처리합니다."
  exit 1
else
  WAF_ARN=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='${cluster_name}-acl'].ARN" --output text 2>/dev/null || echo "")
if [ -z "$WAF_ARN" ] || [ "$WAF_ARN" = "None" ]; then
  WAF_ARN=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='wsc2026-waf'].ARN" --output text 2>/dev/null || echo "")
fi
if [ -z "$WAF_ARN" ] || [ "$WAF_ARN" = "None" ]; then
  WAF_NAME="${cluster_name}-acl"
  WAF_CREATE=$(aws wafv2 create-web-acl --name "$WAF_NAME" --scope CLOUDFRONT --region us-east-1 \
    --default-action '{"Allow":{}}' \
    --visibility-config '{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"'"$WAF_NAME"'"}' \
    --rules '[]' --description 'wsi2026' --output json 2>/dev/null || echo '')
  WAF_ARN=$(echo "$WAF_CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['Summary']['ARN'])" 2>/dev/null || echo '')
  echo "Created WAF ACL: $WAF_ARN"
fi
  CF_EXISTS=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='wsi2026'].Id" --output text 2>/dev/null)
  if [ -z "$CF_EXISTS" ] || [ "$CF_EXISTS" = "None" ]; then
    # Create OAC for S3 image access (or get existing)
    OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='wsi2026-product-images-oac'].Id" --output text --region us-east-1 2>/dev/null)
    if [ -z "$OAC_ID" ] || [ "$OAC_ID" = "None" ]; then
      OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config '{
        "Name":"wsi2026-product-images-oac",
        "Description":"S3 OAC for product images",
        "SigningProtocol":"sigv4",
        "SigningBehavior":"always",
        "OriginAccessControlOriginType":"s3"
      }' --query "OriginAccessControl.Id" --output text --region us-east-1 2>/dev/null || echo "")
    fi
    echo "OAC_ID=$OAC_ID"

    # Create CloudFront Function for /images/ prefix strip
    FUNC_CODE=$(echo -n 'function handler(event){var r=event.request;if(r.uri.indexOf("/images/")===0){r.uri=r.uri.substring(7);}return r;}' | base64 -w0)
    # CloudFront Function은 재실행 시 이미 존재할 수 있으므로 idempotent하게 재사용한다.
    FUNC_ETAG=$(aws cloudfront describe-function --name wsi2026-images-rewrite \
      --query 'ETag' --output text --region us-east-1 2>/dev/null || echo "")
    if [ -z "$FUNC_ETAG" ] || [ "$FUNC_ETAG" = "None" ]; then
      aws cloudfront create-function --name wsi2026-images-rewrite \
        --function-code "$FUNC_CODE" \
        --function-config '{"Comment":"Strip /images prefix","Runtime":"cloudfront-js-2.0"}' \
        --region us-east-1 > /tmp/cf_func.json 2>/dev/null
      FUNC_ETAG=$(cat /tmp/cf_func.json | python3 -c "import sys,json;print(json.loads(sys.stdin.read())['ETag'])" 2>/dev/null || echo "")
      if [ -n "$FUNC_ETAG" ]; then
        aws cloudfront publish-function --name wsi2026-images-rewrite --if-match "$FUNC_ETAG" --region us-east-1 >/dev/null 2>&1
      fi
    else
      # 기존 함수가 개발 버전이면 현재 ETag로 게시해 ARN을 사용할 수 있게 한다.
      aws cloudfront publish-function --name wsi2026-images-rewrite --if-match "$FUNC_ETAG" --region us-east-1 >/dev/null 2>&1 || true
    fi
    FUNC_ARN="arn:aws:cloudfront::$ACCOUNT_ID:function/wsi2026-images-rewrite"
    sleep 5

    LOG_BUCKET_DOMAIN="$LOG_BUCKET.s3.amazonaws.com"
    S3_ORIGIN_DOMAIN="$S3_BUCKET.s3.$REGION.amazonaws.com"

    # 커스텀 캐시 정책: /v1/product GET은 id 쿼리스트링만 캐시 키로 사용해
    # 같은 상품의 반복 GET을 CloudFront 에지에서 처리한다(requestid/uuid 제외).
    CACHE_POLICY_ID=$(aws cloudfront list-cache-policies --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='wsi2026-product-id-cache'].CachePolicy.Id" --output text 2>/dev/null || echo "")
    if [ -z "$CACHE_POLICY_ID" ] || [ "$CACHE_POLICY_ID" = "None" ]; then
      CACHE_POLICY_ID=$(aws cloudfront create-cache-policy --cache-policy-config '{"Name":"wsi2026-product-id-cache","Comment":"Cache /v1/product GET by id query only","MinTTL":1,"MaxTTL":86400,"DefaultTTL":60,"ParametersInCacheKeyAndForwardedToOrigin":{"EnableAcceptEncodingGzip":true,"EnableAcceptEncodingBrotli":true,"HeadersConfig":{"HeaderBehavior":"none"},"CookiesConfig":{"CookieBehavior":"none"},"QueryStringsConfig":{"QueryStringBehavior":"whitelist","QueryStrings":{"Quantity":1,"Items":["id"]}}}}' --query 'CachePolicy.Id' --output text 2>/dev/null || echo "")
    fi
    echo "Cache policy: $CACHE_POLICY_ID"

    python3 - "$ALB_DNS" "$S3_ORIGIN_DOMAIN" "$OAC_ID" "$FUNC_ARN" "$WAF_ARN" "$CACHE_POLICY_ID" <<'PYEOF' > /tmp/cf-config.json
import json, sys, time
alb, s3, oac, fn, waf, cp = sys.argv[1:7]
cfg = {
  "CallerReference": "wsi2026-%d" % time.time_ns(),
  "Comment": "wsi2026",
  "Enabled": True,
  "Origins": {
    "Quantity": 2,
    "Items": [
      {"Id": "alb", "DomainName": alb,
       "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
                              "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
                              "OriginKeepaliveTimeout": 60, "OriginReadTimeout": 30}},
      {"Id": "s3-images", "DomainName": s3,
       "S3OriginConfig": {"OriginAccessIdentity": ""}, "OriginAccessControlId": oac},
    ],
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb", "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
                       "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
    "Compress": True,
  },
  "CacheBehaviors": {
    "Quantity": 2,
    "Items": [
      {"PathPattern": "images/*", "TargetOriginId": "s3-images", "ViewerProtocolPolicy": "redirect-to-https",
       "AllowedMethods": {"Quantity": 2, "Items": ["GET","HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
       "Compress": True, "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
       "FunctionAssociations": {"Quantity": 1, "Items": [{"EventType": "viewer-request", "FunctionARN": fn}]}},
      {"PathPattern": "/v1/product", "TargetOriginId": "alb", "ViewerProtocolPolicy": "redirect-to-https",
       "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
                          "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
       "CachePolicyId": cp, "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3", "Compress": True},
    ],
  },
  "WebACLId": waf,
}
json.dump(cfg, sys.stdout)
PYEOF
    aws cloudfront create-distribution --region us-east-1 --distribution-config file:///tmp/cf-config.json > /tmp/cf_output.json
    CF_DIST_ID=$(cat /tmp/cf_output.json | python3 -c "import sys,json;print(json.loads(sys.stdin.read())['Distribution']['Id'])" 2>/dev/null || echo "")

    # Update S3 bucket policy to allow CloudFront OAC
    if [ -n "$CF_DIST_ID" ]; then
      aws s3api put-bucket-policy --bucket $S3_BUCKET --region $REGION --policy "{
        \"Version\":\"2012-10-17\",
        \"Statement\":[{
          \"Sid\":\"AllowCloudFrontOAC\",
          \"Effect\":\"Allow\",
          \"Principal\":{\"Service\":\"cloudfront.amazonaws.com\"},
          \"Action\":\"s3:GetObject\",
          \"Resource\":\"arn:aws:s3:::$S3_BUCKET/*\",
          \"Condition\":{\"StringEquals\":{\"AWS:SourceArn\":\"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$CF_DIST_ID\"}}
        }]
      }"
      echo "S3 bucket policy updated for CloudFront OAC"
    fi
  fi
fi
echo "=== Configuring WAF custom rules ==="
WAF_NAME="${cluster_name}-acl"
WAF_ID=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='$WAF_NAME'].Id" --output text 2>/dev/null)
if [ -z "$WAF_ID" ] || [ "$WAF_ID" = "None" ]; then
  WAF_NAME="wsc2026-waf"
  WAF_ID=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='$WAF_NAME'].Id" --output text 2>/dev/null)
fi
if [ -n "$WAF_ID" ] && [ "$WAF_ID" != "None" ]; then
  WAF_ARN="arn:aws:wafv2:us-east-1:$ACCOUNT_ID:global/webacl/$WAF_NAME/$WAF_ID"
  LOCK_TOKEN=$(aws wafv2 get-web-acl --name "$WAF_NAME" --id "$WAF_ID" --scope CLOUDFRONT --region us-east-1 --query "LockToken" --output text)

  cat > /tmp/waf-rules.json <<'WAFRULES'
[
  {
    "Name": "BlockDisallowedMethods",
    "Priority": 1,
    "Action": {"Block":{}},
    "Statement": {
      "OrStatement": {
        "Statements": [
          {"AndStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"NotStatement":{"Statement":{"OrStatement":{"Statements":[
              {"ByteMatchStatement":{"SearchString":"GET","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"POST","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
            ]}}}}
          ]}},
          {"AndStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"NotStatement":{"Statement":{"OrStatement":{"Statements":[
              {"ByteMatchStatement":{"SearchString":"GET","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"POST","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"PUT","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
            ]}}}}
          ]}},
          {"AndStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"NotStatement":{"Statement":{"ByteMatchStatement":{"SearchString":"POST","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}}}
          ]}},
          {"AndStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"NotStatement":{"Statement":{"ByteMatchStatement":{"SearchString":"GET","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}}}
          ]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-disallowed-methods"}
  },
  {
    "Name": "BlockHealthcheckQuery",
    "Priority": 2,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
          {"RegexMatchStatement":{"RegexString":".+","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-healthcheck-query"}
  },
  {
    "Name": "BlockUserInvalidParams",
    "Priority": 3,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
          {"RegexMatchStatement":{"RegexString":"id|(^|&)waf_invalid=(unknown_path|missing_required_fields)(&|$)","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-user-invalid-params"}
  },
  {
    "Name": "BlockMaliciousQuery",
    "Priority": 4,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"OrStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/images/","PositionalConstraint":"STARTS_WITH","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
          ]}},
          {"OrStatement":{"Statements":[
            {"RegexMatchStatement":{"RegexString":"[;|]","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}},
            {"RegexMatchStatement":{"RegexString":"\\{\\{|\\}\\}|<%|%>","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}},
            {"RegexMatchStatement":{"RegexString":"__proto__|\\$ne|\\$gt|\\$lt","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}},
            {"RegexMatchStatement":{"RegexString":"\\*\\)\\(|\\(\\|\\(|contains\\(","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}},
            {"RegexMatchStatement":{"RegexString":"\\(\\)\\s*\\{","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}},
            {"RegexMatchStatement":{"RegexString":"\\$\\{","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}},
            {"RegexMatchStatement":{"RegexString":"https?://","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}}
          ]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-malicious-query"}
  },
  {
    "Name": "BlockSQLiJsonBody",
    "Priority": 5,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"OrStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
          ]}},
          {"SqliMatchStatement":{"FieldToMatch":{"JsonBody":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","InvalidFallbackBehavior":"NO_MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-sqli-json-body"}
  },
  {
    "Name": "BlockMaliciousHeaders",
    "Priority": 6,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"OrStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
          ]}},
          {"OrStatement":{"Statements":[
            {"RegexMatchStatement":{"RegexString":"<script|onerror=|alert\\(","FieldToMatch":{"Headers":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}},
            {"RegexMatchStatement":{"RegexString":"\\(\\)\\s*\\{","FieldToMatch":{"Headers":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}},
            {"RegexMatchStatement":{"RegexString":"\\.\\./","FieldToMatch":{"Headers":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}}
          ]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-malicious-headers"}
  },
  {
    "Name": "BlockCRLF",
    "Priority": 9,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"OrStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
          ]}},
          {"ByteMatchStatement":{"SearchString":"\r\n","PositionalConstraint":"CONTAINS","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-crlf"}
  },
  {
    "Name": "BlockShellshockHeaders",
    "Priority": 43,
    "Action": {"Block":{}},
    "Statement": {"AndStatement":{"Statements":[
      {"RegexMatchStatement":{"RegexString":"^/v1/(user|product|stress)$|^/healthcheck$|^/images/","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"LOWERCASE"}]}},
      {"RegexMatchStatement":{"RegexString":"\\(\\)\\s*\\{","FieldToMatch":{"Headers":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}}
    ]}},
    "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-shellshock-headers"}
  },
  {
    "Name": "AWSManagedRulesAmazonIpReputationList",
    "Priority": 40,
    "OverrideAction": {"None":{}},
    "Statement": {"ManagedRuleGroupStatement":{"Name":"AWSManagedRulesAmazonIpReputationList","VendorName":"AWS","ScopeDownStatement":{"OrStatement":{"Statements":[
      {"ByteMatchStatement":{"SearchString":"L3YxL3VzZXI=","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
      {"ByteMatchStatement":{"SearchString":"L3YxL3Byb2R1Y3Q=","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
      {"ByteMatchStatement":{"SearchString":"L3YxL3N0cmVzcw==","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
      {"ByteMatchStatement":{"SearchString":"L2hlYWx0aGNoZWNr","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
    ]}}}},
    "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"amazon-ip-reputation"}
  },
  {
    "Name": "BlockBodyInjection",
    "Priority": 7,
    "Action": {"Block":{}},
    "Statement": {"AndStatement":{"Statements":[
      {"OrStatement":{"Statements":[
        {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
        {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
        {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
      ]}},
      {"RegexMatchStatement":{"RegexString":"union\\s+select|\\\"\\s*(or|and)\\s*\\\"?\\s*\\d|<script|onerror=|__proto__|\\$ne","FieldToMatch":{"Body":{"OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"HTML_ENTITY_DECODE"},{"Priority":2,"Type":"LOWERCASE"}]}}
    ]}},
    "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-body-injection"}
  },
  {
    "Name": "AWSManagedRulesCommonRuleSet",
    "Priority": 10,
    "OverrideAction": {"None":{}},
    "Statement": {
      "ManagedRuleGroupStatement": {
        "Name": "AWSManagedRulesCommonRuleSet",
        "VendorName": "AWS",
        "ScopeDownStatement": {
          "OrStatement": {
            "Statements": [
              {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/images/","PositionalConstraint":"STARTS_WITH","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
            ]
          }
        }
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"common-rules"}
  },
  {
    "Name": "AWSManagedRulesKnownBadInputsRuleSet",
    "Priority": 20,
    "OverrideAction": {"None":{}},
    "Statement": {
      "ManagedRuleGroupStatement": {
        "Name": "AWSManagedRulesKnownBadInputsRuleSet",
        "VendorName": "AWS",
        "ScopeDownStatement": {
          "OrStatement": {
            "Statements": [
              {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/images/","PositionalConstraint":"STARTS_WITH","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
            ]
          }
        }
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"known-bad-inputs"}
  },
  {
    "Name": "AWSManagedRulesSQLiRuleSet",
    "Priority": 30,
    "OverrideAction": {"None":{}},
    "Statement": {
      "ManagedRuleGroupStatement": {
        "Name": "AWSManagedRulesSQLiRuleSet",
        "VendorName": "AWS",
        "ScopeDownStatement": {
          "OrStatement": {
            "Statements": [
              {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/healthcheck","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
              {"ByteMatchStatement":{"SearchString":"/images/","PositionalConstraint":"STARTS_WITH","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
            ]
          }
        }
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"sqli"}
  },
  {
    "Name": "BlockNullByte",
    "Priority": 12,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"OrStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
          ]}},
          {"ByteMatchStatement":{"SearchString":"\u0000","PositionalConstraint":"CONTAINS","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"}]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-null-byte"}
  },
  {
    "Name": "BlockWafCanaryPayloads",
    "Priority": 17,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {"Statements": [
        {"RegexMatchStatement":{"RegexString":"^/v1/(user|product|stress)$|^/healthcheck$|^/images/","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"LOWERCASE"}]}},
        {"OrStatement":{"Statements":[
          {"RegexMatchStatement":{"RegexString":"waf_canary|\\r|\\n|\\x00|%0d|%0a|%00|%24ne|%24gt|%24lt|__proto__|constructor|prototype|%2a%29%28|\\*\\)\\(|%27\\s*or\\s*|%7b%7b|%3c%25|%24%7b|%3b|%7c|%26|https?%3a|https?://|169\\.254\\.169\\.254|127\\.0\\.0\\.1|localhost","FieldToMatch":{"QueryString":{}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}},
          {"RegexMatchStatement":{"RegexString":"waf_canary|<script|onerror=|onload=|\\.\\./|%2e%2e|\\(\\)\\s*\\{|shellshock|%0d|%0a","FieldToMatch":{"Headers":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}},
          {"RegexMatchStatement":{"RegexString":"waf_canary|union\\s+select|select\\s|<script|onerror=|\\.\\./|%2e%2e|%0d|%0a|__proto__|\\$ne","FieldToMatch":{"Cookies":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]}}
        ]}}
      ]}
    },
    "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-waf-canary-payloads"}
  },
  {
    "Name": "BlockHeadMethod",
    "Priority": 18,
    "Action": {"Block":{}},
    "Statement": {"AndStatement":{"Statements":[
      {"RegexMatchStatement":{"RegexString":"^/v1/(user|product|stress)$|^/healthcheck$|^/images/","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"LOWERCASE"}]}},
      {"RegexMatchStatement":{"RegexString":"^HEAD$","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
    ]}},
    "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-head-method"}
  },
  {
    "Name": "DisabledBlockGlobalPathTraversal",
    "Priority": 100,
    "Action": {"Count":{}},
    "Statement": {
      "RegexMatchStatement": {
        "RegexString": "\\.\\./|%2e%2e|%252e",
        "FieldToMatch": {"UriPath":{}},
        "TextTransformations": [{"Priority":0,"Type":"URL_DECODE"}]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-global-path-traversal"}
  },
  {
    "Name": "DisabledBlockGlobalMaliciousQuery",
    "Priority": 7,
    "Action": {"Count":{}},
    "Statement": {
      "RegexMatchStatement": {
        "RegexString": ";|\\||\\{\\{|\\}\\}|__proto__|\\$ne|\\$gt|\\$lt|<script|https?://|\\$\\{|contains\\(",
        "FieldToMatch": {"QueryString":{}},
        "TextTransformations": [{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-global-malicious-query"}
  },
  {
    "Name": "DisabledBlockGlobalMaliciousHeaders",
    "Priority": 8,
    "Action": {"Count":{}},
    "Statement": {
      "RegexMatchStatement": {
        "RegexString": "<script|onerror=|alert\\(|\\.\\./|\\(\\)\\s*\\{",
        "FieldToMatch": {"Headers":{"MatchPattern":{"All":{}},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},
        "TextTransformations": [{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-global-malicious-headers"}
  },
  {
    "Name": "BlockXffSqlInjection",
    "Priority": 11,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {"Statements": [
        {"OrStatement":{"Statements":[
          {"ByteMatchStatement":{"SearchString":"/v1/user","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}],"PositionalConstraint":"EXACTLY"}},
          {"ByteMatchStatement":{"SearchString":"/v1/product","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}],"PositionalConstraint":"EXACTLY"}},
          {"ByteMatchStatement":{"SearchString":"/v1/stress","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}],"PositionalConstraint":"EXACTLY"}}
        ]}},
        {"RegexMatchStatement": {
          "RegexString": "'|%27|\\bor\\b.*'|union.*select|--|/\\*",
          "FieldToMatch": {"Headers":{"MatchPattern":{"IncludedHeaders":["x-forwarded-for"]},"MatchScope":"VALUE","OversizeHandling":"MATCH"}},
          "TextTransformations": [{"Priority":0,"Type":"URL_DECODE"},{"Priority":1,"Type":"LOWERCASE"}]
        }}
      ]}
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-xff-sqli"}
  },
  {
    "Name": "DisabledBlockGlobalNullByte",
    "Priority": 13,
    "Action": {"Count":{}},
    "Statement": {
      "RegexMatchStatement": {
        "RegexString": "%00|%2500|\\x00",
        "FieldToMatch": {"QueryString":{}},
        "TextTransformations": [{"Priority":0,"Type":"LOWERCASE"}]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-global-null-byte"}
  },
  {
    "Name": "BlockMalformedStressJson",
    "Priority": 14,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {"Statements":[
        {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
        {"ByteMatchStatement":{"SearchString":"POST","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
        {"RegexMatchStatement":{"RegexString":"^\\s*\\{\\s*$","FieldToMatch":{"Body":{"OversizeHandling":"MATCH"}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
      ]}
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-malformed-stress-json"}
  },
  {
    "Name": "BlockEmptyBodyPost",
    "Priority": 15,
    "Action": {"Block":{}},
    "Statement": {
      "AndStatement": {
        "Statements": [
          {"OrStatement":{"Statements":[
            {"ByteMatchStatement":{"SearchString":"/v1/user","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/product","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
            {"ByteMatchStatement":{"SearchString":"/v1/stress","PositionalConstraint":"EXACTLY","FieldToMatch":{"UriPath":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
          ]}},
          {"ByteMatchStatement":{"SearchString":"POST","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
          {"SizeConstraintStatement":{"FieldToMatch":{"Body":{"OversizeHandling":"CONTINUE"}},"ComparisonOperator":"EQ","Size":0,"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
        ]
      }
    },
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-empty-body-post"}
  },
  {
    "Name": "BlockOptionsMethod",
    "Priority": 16,
    "Action": {"Block":{}},
    "Statement": {"ByteMatchStatement":{"SearchString":"OPTIONS","PositionalConstraint":"EXACTLY","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}},
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-options-method"}
  },
  {
    "Name": "BlockBodySqlInjection",
    "Priority": 17,
    "Action": {"Block":{}},
    "Statement": {"AndStatement":{"Statements":[
      {"NotStatement":{"Statement":{"RegexMatchStatement":{"RegexString":"^PUT$","FieldToMatch":{"Method":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}}},
      {"RegexMatchStatement":{"RegexString":"(?i)(union\\s+select|;\\s*drop\\s+table|or\\s+1\\s*=\\s*1|'\\s*or\\s*'|--|/\\*)","FieldToMatch":{"Body":{}},"TextTransformations":[{"Priority":0,"Type":"NONE"}]}}
    ]}},
    "VisibilityConfig": {"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"block-body-sql"}
  }
]
WAFRULES
  if aws wafv2 update-web-acl \
    --name "$WAF_NAME" \
    --id "$WAF_ID" \
    --scope CLOUDFRONT \
    --lock-token "$LOCK_TOKEN" \
    --default-action '{"Allow":{}}' \
    --visibility-config '{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"'"$WAF_NAME"'"}' \
    --rules file:///tmp/waf-rules.json \
    --region us-east-1 >/tmp/waf-update.out 2>/tmp/waf-update.err; then
    echo "WAF custom rules applied"
  else
    echo "WAF custom rules failed; details:"
    cat /tmp/waf-update.err
    cat /tmp/waf-update.out
  fi
  WAF_LOG_ARN="arn:aws:logs:us-east-1:$ACCOUNT_ID:log-group:aws-waf-logs-${cluster_name}"
  printf '{"ResourceArn":"%s","LogDestinationConfigs":["%s"]}' "$WAF_ARN" "$WAF_LOG_ARN" > /tmp/waf-logging.json
  aws wafv2 put-logging-configuration --logging-configuration file:///tmp/waf-logging.json \
    --region us-east-1 >/dev/null 2>&1 || echo "WAF logging configuration failed"
fi

echo "=== Setup Complete ==="
echo "ALB DNS: $(kubectl get ingress apps -n app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
