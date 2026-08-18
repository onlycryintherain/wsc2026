#!/bin/bash
set -euo pipefail

yum install -y mariadb105 docker git
systemctl start docker && systemctl enable docker
curl -LO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl" && chmod +x kubectl && mv kubectl /usr/local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" && tar -xzf eksctl_Linux_amd64.tar.gz && mv eksctl /usr/local/bin/

# IAM role 전파 지연 방어: role 생성 직후 EC2가 시작되면 metadata credential이
# 아직 준비되지 않아 aws CLI가 'Unable to locate credentials'로 실패할 수 있다.
# credential 사용 가능할 때까지 최대 ~90초 재시도한다.
for i in $(seq 1 18); do
  if aws sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS credential ready (attempt $i)"
    break
  fi
  if [ "$i" -eq 18 ]; then
    echo "AWS credential not available after 90s" >&2
    exit 1
  fi
  sleep 5
done

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
