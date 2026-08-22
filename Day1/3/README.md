# Terraform 사용법

## 실행

```bash
terraform init
terraform apply --auto-approve"
비번호 입력
```

## 생성 후 EC2에서

```bash
bash setup.sh
```

setup.sh가 자동으로:
1. book 이미지 빌드 & ECR push
2. grafana, fluent-bit, LBC 이미지 ECR push
3. kubectl apply (namespace, book, TGB, network-policy)
4. helm install (LBC, grafana)
5. fluent-bit daemonset 배포
