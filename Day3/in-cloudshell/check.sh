#!/bin/bash
if [ -n "${1:-}" ]; then
  EP="${1%/}"
else
  echo "[check] CloudFront 엔드포인트 검색..."
  CF=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='wsi2026'].DomainName" --output text 2>/dev/null)
  [ -z "$CF" ] || [ "$CF" = "None" ] && CF=$(aws cloudfront list-distributions --query "DistributionList.Items[0].DomainName" --output text 2>/dev/null)
  if [ -z "$CF" ] || [ "$CF" = "None" ]; then
    echo "❌ CloudFront 못 찾음. ./tune.sh https://xxx.cloudfront.net"
    exit 1
  fi
  EP="https://$CF"
fi
[[ "$EP" =~ ^https?:// ]] || EP="https://$EP"
REGION="${AWS_REGION:-ap-northeast-2}"
DATA_FILE="${LOAD_USER_DUMP:-application/load_user.dump}"
PRODUCT_ID="${CHECK_PRODUCT_ID:-dbdump500001}"
read -r USER_ID USER_EMAIL < <(python3 - "$DATA_FILE" <<'PY'
import json, re, sys, csv
p=sys.argv[1]
try: raw=open(p, encoding='utf-8').read()
except Exception: raw=''
found=[]
def visit(x):
    if isinstance(x, dict):
        e=next((str(x[k]) for k in x if k.lower() in ('email','mail','e_mail') and '@' in str(x[k])),None)
        i=next((str(x[k]) for k in x if k.lower() in ('id','user_id','userid','username')),None)
        if e: found.append((i or '',e))
        for v in x.values(): visit(v)
    elif isinstance(x,list):
        for v in x: visit(v)
try: visit(json.loads(raw))
except Exception: pass
if not found:
    emails=re.findall(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}',raw)
    ids=re.findall(r'(?i)\b(?:dbdump|user)[A-Za-z0-9_-]*\d+\b',raw)
    if emails: found=[(ids[0] if ids else '', emails[0])]
if found: print(found[0][0], found[0][1])
else: print('dbdump1 dbdump1@example.org')
PY
)
USER_EMAIL="${USER_EMAIL:-dbdump1@example.org}"

FAIL=()

echo "=============================================="
echo " 2026 전국기능경기대회 Cloud 최종 점검"
echo "=============================================="
echo
source kubectl-connect wsi2026-cluster
aws eks update-kubeconfig \
--region $REGION \
--name wsi2026-cluster

###############################################
check_http () {

NAME="$1"
EXPECT="$2"
URL="$3"
BODY="$4"

if [ -z "$BODY" ]; then
    RESULT=$(curl -ks \
        -o /dev/null \
        -w "%{http_code} %{time_total}" \
        "$URL")
else
    RESULT=$(curl -ks \
        -H "Content-Type: application/json" \
        -d "$BODY" \
        -o /dev/null \
        -w "%{http_code} %{time_total}" \
        "$URL")
fi

CODE=$(echo $RESULT | awk '{print $1}')
TIME=$(echo $RESULT | awk '{print $2}')
MS=$(awk "BEGIN{printf \"%.0f\",$TIME*1000}")

printf "%-30s HTTP:%3s %5sms\n" "$NAME" "$CODE" "$MS"

if [ "$CODE" != "$EXPECT" ]; then
    FAIL+=("$NAME : HTTP $CODE (Expected $EXPECT)")
fi

# 응답시간 체크
if [ "$NAME" = "Healthcheck" ] && [ "$MS" -gt 200 ]; then
    FAIL+=("Healthcheck 응답시간 ${MS}ms (>200ms)")
fi

if [ "$NAME" = "User GET" ] && [ "$MS" -gt 200 ]; then
    FAIL+=("User GET 응답시간 ${MS}ms (>200ms)")
fi

if [ "$NAME" = "Product GET" ] && [ "$MS" -gt 200 ]; then
    FAIL+=("Product GET 응답시간 ${MS}ms (>200ms)")
fi

if [ "$NAME" = "Stress POST" ] && [ "$MS" -gt 1000 ]; then
    FAIL+=("Stress 응답시간 ${MS}ms (>1000ms)")
fi

if [ "$NAME" = "Image Download" ] && [ "$MS" -gt 5000 ]; then
    FAIL+=("Image Download 응답시간 ${MS}ms (>5000ms)")
fi

}

###############################################

echo "========== API =========="

check_http \
"Healthcheck" \
200 \
"${EP}/healthcheck"

check_http \
"User GET" \
200 \
"${EP}/v1/user?email=${USER_EMAIL}&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729"

check_http \
"Product GET" \
200 \
"${EP}/v1/product?id=${PRODUCT_ID}&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729"

check_http \
"Stress POST" \
201 \
"${EP}/v1/stress" \
'{"requestid":"999999999999","uuid":"7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729","length":256}'

echo

echo "========== Security =========="

check_http \
"DELETE /v1/user" \
403 \
"${EP}/v1/user"

check_http \
"Unknown API" \
404 \
"${EP}/v1/none"

echo

echo "========== Image =========="

check_http \
"Image Download" \
200 \
"${EP}/images/test.jpg"

echo
echo "========== Kubernetes =========="

kubectl get nodes
kubectl get pods -A

NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print}')

if [ -n "$NOTREADY" ]; then
    FAIL+=("Ready가 아닌 Node 존재")
fi

PODFAIL=$(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"{print}')

if [ -n "$PODFAIL" ]; then
    FAIL+=("Running 상태가 아닌 Pod 존재")
fi

echo
kubectl get deploy -A
kubectl get svc -A
kubectl get ingress -A
kubectl get hpa -A 2>/dev/null

echo
echo "========== EC2 =========="

aws ec2 describe-instances \
--region $REGION \
--query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,Type:InstanceType}' \
--output table

echo
echo "========== ALB =========="

aws elbv2 describe-load-balancers \
--region $REGION \
--query 'LoadBalancers[].{DNS:DNSName,State:State.Code}' \
--output table

ALB=$(aws elbv2 describe-load-balancers \
--region $REGION \
--query 'LoadBalancers[0].State.Code' \
--output text)

if [ "$ALB" != "active" ]; then
    FAIL+=("ALB 상태 : $ALB")
fi

echo
echo "========== RDS =========="

aws rds describe-db-instances \
--region $REGION \
--query 'DBInstances[].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ}' \
--output table

RDS=$(aws rds describe-db-instances \
--region $REGION \
--query 'DBInstances[0].DBInstanceStatus' \
--output text)

if [ "$RDS" != "available" ]; then
    FAIL+=("RDS 상태 : $RDS")
fi

echo
echo "========== S3 =========="

aws s3 ls

COUNT=$(aws s3 ls | wc -l)

if [ "$COUNT" -eq 0 ]; then
    FAIL+=("S3 Bucket 없음")
fi

echo
echo "========== ECR =========="

aws ecr describe-repositories \
--region $REGION \
--query 'repositories[].repositoryName' \
--output table

echo
echo "========== CloudWatch =========="

aws logs describe-log-groups \
--region $REGION \
--query 'logGroups[].logGroupName' \
--output table

echo
echo "========== Resource =========="

df -h
free -h

echo
echo "=============================================="
echo "               최종 결과"
echo "=============================================="

if [ ${#FAIL[@]} -eq 0 ]; then
    echo "✅ 모든 점검 통과"
    echo "🚀 제출 가능한 상태입니다."
else
    echo "❌ 미흡한 항목"

    for ITEM in "${FAIL[@]}"
    do
        echo " - $ITEM"
    done
fi

echo
echo "=============================================="
echo "                END"
echo "=============================================="