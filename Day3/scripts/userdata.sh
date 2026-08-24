#!/bin/bash
set -euo pipefail

yum install -y mariadb105 docker git
systemctl start docker && systemctl enable docker
curl -LO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl" && chmod +x kubectl && mv kubectl /usr/local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" && tar -xzf eksctl_Linux_amd64.tar.gz && mv eksctl /usr/local/bin/

# Wait for IMDS-provided instance-role credentials. The role policy is attached
# before the instance starts, but IAM/IMDS propagation can still be delayed.
CREDENTIAL_READY=0
for i in $(seq 1 120); do
  ROLE_NAME=$(curl -fsS --max-time 3 \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
    -X PUT http://169.254.169.254/latest/api/token 2>/dev/null | \
    xargs -r -I{} curl -fsS --max-time 3 \
      -H "X-aws-ec2-metadata-token: {}" \
      http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || true)
  if [ -n "$ROLE_NAME" ] && aws sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS credential ready (attempt $i, role=$ROLE_NAME)"
    CREDENTIAL_READY=1
    break
  fi
  echo "Attempt $i: AWS credential not ready (role=$${ROLE_NAME:-none}), waiting..."
  sleep 5
done
if [ "$CREDENTIAL_READY" -ne 1 ]; then
  echo "ERROR: AWS credential not available after 600s" >&2
  echo "IMDS role endpoint:" >&2
  curl -fsS --max-time 5 http://169.254.169.254/latest/meta-data/iam/security-credentials/ >&2 || true
  exit 1
fi

# S3 다운로드 실패와 Windows CRLF 줄바꿈을 모두 방어한다.
for attempt in 1 2 3; do
  if aws s3 cp "s3://${s3_bucket}/scripts/bastion_setup.sh" /home/ec2-user/setup.sh; then
    break
  fi
  echo "bastion_setup.sh download failed (attempt $attempt), retrying..."
  sleep 10
done
[ -s /home/ec2-user/setup.sh ]
sed -i 's/\r$//' /home/ec2-user/setup.sh
chmod 0755 /home/ec2-user/setup.sh
chown ec2-user:ec2-user /home/ec2-user/setup.sh
if /bin/bash /home/ec2-user/setup.sh > /var/log/setup.log 2>&1; then
  echo "setup.sh 완료. EC2 종료..." >> /var/log/setup.log
  INSTANCE_ID=$(ec2-metadata -i | cut -d' ' -f2)
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region ap-northeast-2
else
  echo "setup.sh 실패. /var/log/setup.log를 확인하세요." >> /var/log/setup.log
  exit 1
fi
