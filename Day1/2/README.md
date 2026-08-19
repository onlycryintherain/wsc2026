# 제1과제 Terraform
## 실행 

```bash
cd terraform/1과제
terraform init
terraform apply -auto-approve
```

Bastion EC2에 접속한 뒤 EKS와 애플리케이션 배포를 마무리합니다.

```bash
sudo bash setup.sh
```

실행 로그는 자동으로 `/home/cloudshell-user/wskorea26-setup-*.log`에 저장되고, 스크립트 종료 시 manifest bucket의 `logs/` 경로에도 업로드됩니다.

```bash
ls -lh /home/cloudshell-user/wskorea26-setup-*.log
tail -n 100 /home/cloudshell-user/wskorea26-setup-*.log
aws s3 ls s3://$(aws s3 ls | awk '/wskorea26-manifest-/ {print $3; exit}')/logs/
aws s3 cp s3://$(aws s3 ls | awk '/wskorea26-manifest-/ {print $3; exit}')/logs/<log-file-name> .
```


## AWS Load Balancer Controller Ingress 전환

기존 Terraform 수동 ALB 대신 AWS Load Balancer Controller가 ALB를 생성하도록 구성되어 있습니다.

구성 파일:

- `manifest/install-aws-load-balancer-controller.sh`: Controller IRSA와 Helm 설치
- `manifest/ingress.yaml`: Book/Grafana Ingress
- `manifest/setup.sh`: 수동 `register-targets` 대신 Ingress 적용

CloudFront Origin은 Controller가 생성한 ALB DNS를 알아야 하므로 Terraform을 두 번 적용합니다.

### 1단계: 수동 ALB 제거 및 EKS/Ingress 구성

```bash
terraform init
terraform apply -auto-approve \
  -var='pin_number=<PIN>' \
  -var='ingress_api_origin_enabled=false'
```

이 단계에서 Terraform이 기존 수동 Book/Grafana ALB와 IP Target Group을 제거합니다. Lambda Target Group은 GET `/book` Ingress action에서 사용하므로 유지됩니다.

Bastion에서 기존 방식과 동일하게 setup을 실행하면 AWS Load Balancer Controller와 Ingress가 구성됩니다.

```bash
sudo bash setup.sh
```

Ingress ALB 주소를 확인합니다.

```bash
kubectl get ingress book-ingress \
  -n wskorea26 \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

출력된 값을 다음 Terraform 변수에 사용합니다.

### 2단계: CloudFront Origin을 Ingress ALB로 연결

```bash
terraform apply -auto-approve \
  -var='pin_number=<PIN>' \
  -var='ingress_api_origin_enabled=true' \
  -var='ingress_api_origin_domain_name=<BOOK_INGRESS_ALB_DNS>'
```

CloudFront는 이후 다음 경로로 API 요청을 전달합니다.

```text
CloudFront
  ↓ X-Origin-Verify: wskorea26-cf
Book Ingress ALB
  ↓ POST /book
book-svc:80
  ↓
Book Pod:8080
```

Ingress Controller는 Pod IP를 자동으로 Target Group에 등록하므로 다음과 같은 수동 명령은 더 이상 사용하지 않습니다.

```bash
aws elbv2 register-targets ...
```

주의사항:

- 기존 수동 ALB의 이름은 `wskorea26-book-alb`, `wskorea26-grafana-alb`입니다.
- 새 Ingress ALB의 이름도 `wskorea26-book-alb`, `wskorea26-grafana-alb`로 기존 채점지 이름을 유지합니다.
- 기존 수동 ALB를 Terraform에서 제거하는 첫 번째 `apply`는 기존 ALB를 삭제하므로 서비스 단절이 발생할 수 있습니다.
- GET `/book`은 Ingress의 Lambda custom action을 통해 기존 Lambda Target Group으로 전달됩니다.
- Ingress ALB가 생성되기 전에는 CloudFront API Origin을 활성화하면 안 됩니다.

## 주의사항

- EKS Access Entry에 root user만 추가하고 있으므로, 본인이 대회 중 콘솔에서 사용하는 IAM User를 Access Entry에 등록해야 합니다. CloudShell에서 채점 스크립트를 진행하려면 필요합니다.
