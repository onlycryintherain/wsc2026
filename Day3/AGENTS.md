# AGENTS.md

## 역할

이 저장소는 AWS/EKS 기반 API, Terraform, WAF, ALB/CloudFront 및 부하 테스트 도구를 관리한다.
모든 변경은 재현 가능하고 대회 당일 재사용 가능해야 한다.

- 사용자를 반드시 `주인님`이라고 부른다.
- 답변은 한국어로 간결하게 작성한다.
- 작업 전 관련 파일과 현재 Kubernetes/Terraform 상태를 확인한다.
- 추측으로 AWS 리소스를 변경하지 말고, 변경 전후 상태를 확인한다.
- 기능/API/DB 구조를 임의로 변경하지 않는다.
- CloudFront Function 등 요청 변조 우회는 사용하지 않는다.

## 2026 전국기능경기대회 제3과제 기준

이 저장소는 클라우드컴퓨팅 직종 제3과제 `System operation`(경기시간 3시간)을 수행한다.
목표는 제공된 애플리케이션을 EKS에 배포하고, 서비스 수준을 만족하면서 장애를 빠르게 감지·대응하며, 가능한 최소 비용과 최소 리소스로 운영하는 것이다.

### 고정 제약

- 기본 리전은 별도 지시가 없으면 `ap-northeast-2`, 모든 시간은 KST(UTC+9)를 사용한다.
- 필수 스택은 VPC, EKS, EC2, ECR, RDS, S3이며 애플리케이션은 Golang/Gin 기반이다.
- ELB, API Gateway, CloudFront, Route 53, CloudWatch, WAF, Docker를 사용할 수 있다.
- 컨테이너 오케스트레이션은 EKS만 사용하며 ECS는 사용할 수 없다.
- 컴퓨팅은 EC2만 사용한다. Fargate와 Lambda는 어떠한 목적으로도 사용하지 않는다.
- 배포 전 과제지에서 허용한 트래픽 처리용 EC2 인스턴스 타입을 확인한다. 현재 과제지 기준은 `t3.medium`이지만 당일 `c5.large` 등으로 변경될 수 있다.
- 인스턴스 타입은 코드나 스크립트에 고정하지 않고 `terraform.tfvars`의 `eks_node_instance_type`을 단일 기준으로 사용한다. Managed NodeGroup과 Karpenter NodePool 모두 같은 값을 전달받아야 한다.
- 저장소 기본값은 `t3.medium`이며, 현재 리허설용 `terraform.tfvars` 값은 `c5.large`다. 당일 과제지와 `terraform.tfvars`가 다르면 적용 전에 `terraform.tfvars`를 수정하고 `terraform plan`으로 교체 범위와 노드 타입을 확인한다.
- 지정된 인스턴스 타입, CPU, 메모리, 대수를 준수하며 미사용 리소스도 감점 대상이므로 불필요한 EC2, VPC, 타 리전 리소스를 만들지 않는다.
- 계정에는 비용 제한이 있으므로 리소스 수와 비용을 변경 전후에 확인한다.
- 경기 종료 시 모든 부하 테스트를 종료한다.

### 데이터베이스 고정 조건

- DB identifier: `apdev-rds-instance`
- 엔진: MySQL Community 8.0
- 클래스: `db.t3.micro`
- 배포: Multi-AZ DB instance
- 스토리지: General Purpose SSD `gp3`
- DB 인스턴스는 최소 대수로 운영한다.
- 논리 DB 이름은 `dev`이며 user/product 애플리케이션 모두 읽기·쓰기가 가능해야 한다.
- `load_user.dump`를 적재하고, 적재된 데이터는 임의로 수정하거나 삭제하지 않는다.
- 트래픽 외 임의 데이터를 삽입하지 않는다.
- 테이블 재설계나 인덱스 변경은 실제 트래픽과 측정 근거가 있을 때만 수행하며 API 호환성을 깨지 않는다.
- 기본 테이블 구조는 다음과 같다.

```sql
CREATE TABLE user (
    id VARCHAR(255) NOT NULL,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_username (username)
);

CREATE TABLE product (
    id VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    price FLOAT(8) NOT NULL,
    image_path VARCHAR(500) DEFAULT NULL,
    PRIMARY KEY (id)
);
```

### 애플리케이션 고정 조건

- 제공 애플리케이션은 `user`, `product`, `stress` 3개다.
- 제공 binary는 Go 1.22.2, linux/amd64, Amazon Linux 2023 환경이며 TCP/8080에 바인딩된다.
- access log는 stdout/stderr로 출력된다.
- 정상 Request/Response를 변조하지 않는다. 채점 응답시간과 상태 코드는 클라이언트 도착 기준이다.
- 정상 요청에는 과제 형식에 맞는 `requestid`, `uuid`가 포함된다.
- user/product DB 환경변수 `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DBNAME`은 모두 필수다.
- `MYSQL_HOST`에는 읽기·쓰기가 가능한 IP 또는 DNS만 넣고 엔진명을 포함하지 않는다.

### 서비스 수준 목표

| 대상 | 최소 가용성 | 서비스 수준 목표 |
|---|---:|---:|
| user API | 5초 이하 | 0.2초 이하 |
| product API | 5초 이하 | 0.2초 이하 |
| stress API | 5초 이하 | 1초 이하 |
| 이미지 다운로드 | 5초 이하 | 5초 이하 |

- 응답시간, timeout, 5xx, Pod/노드 수, 비용을 함께 측정한다.
- 노드 증설로 얻는 처리 점수와 추가 리소스 감점을 함께 계산하고, 처리량만을 위해 과도하게 확장하지 않는다.
- 경기 시작 1시간 뒤부터 정상 트래픽, product 이미지 업로드, 이미지 다운로드 트래픽이 발생한다.

### 엔드포인트와 트래픽 판정

- 채점 플랫폼에는 프로토콜을 포함한 단일 엔드포인트만 입력하고 경로는 입력하지 않는다.
- 정상 형식은 `https://example.org`, 잘못된 형식은 `example.org` 또는 `https://example.org/v1/`이다.
- 제공된 실제 API 경로에 대한 악성 요청, 잘못된 메서드와 잘못된 형식은 `403`으로 차단한다.
- 제공하지 않는 경로는 요청 내용이 비정상이더라도 항상 `404`를 반환한다.
- 정상 요청과 응답을 프록시 계층에서 변조하여 성능이나 판정을 우회하지 않는다.

### S3 이미지 제공

- product 애플리케이션이 배포 리전의 S3 버킷에 이미지를 업로드할 수 있어야 한다.
- S3 객체는 애플리케이션과 같은 외부 엔드포인트의 `/images/<object path>`로 다운로드할 수 있어야 한다.
- 예: S3 객체 `/product50001.jpg`는 `<endpoint>/images/product50001.jpg`로 제공한다.
- 이미지 업로드 후 반환된 실제 객체 경로를 사용해 다운로드 200과 5초 SLO를 검증한다.

## API 및 HTTP 정책

외부 경로는 `scripts/bastion_setup.sh`의 Ingress 설정을 기준으로 한다.

| 메서드 | 경로 | 백엔드 | 정상 응답 |
|---|---|---|---|
| GET | `/healthcheck` | user | 200 |
| GET | `/v1/user` | user | 200 |
| GET | `/v1/product` | product | 200 |
| POST | `/v1/product` | product | 정상 생성 응답 |
| PUT | `/v1/product` | product | multipart 이미지 업로드 |
| POST | `/v1/stress` | stress | 201 |
| GET | `/images/*` | product/S3 | 이미지 200 |

- 존재하지 않는 경로는 항상 `404`다.
- 존재하는 API 경로의 잘못된 메서드, 형식 오류, 악성 요청은 WAF에서 `403`으로 차단한다.
- `/v1/user`, `/v1/product`, `/v1/stress` 외 `/v1/*` 경로는 존재하지 않는 경로다.
- PUT Product는 JSON이 아니라 `multipart/form-data`를 사용한다.
- Product PUT의 필수 multipart 필드는 `requestid`, `uuid`, `id`, `image`다.
- 이미지 다운로드는 PUT 응답의 `image_path`를 사용한다.

## 주요 리소스

- Terraform: `main.tf`, `modules/`
- 애플리케이션/Ingress: `scripts/bastion_setup.sh`
- 부하 도구: `tools/tune/`, `tools/tune.ps1`
- 복구 도구: `tools/stabilize.ps1`
- API/WAF 점검: `tools/check.ps1`
- WAF 탐지/복구: `tools/detect-waf-vulnerabilities.ps1`, `tools/waf-rollback.ps1`

## 운영 명령

```powershell
# Terraform 검증
terraform validate
terraform plan -var-file=terraform.tfvars

# 부하 후 기본 상태 복구: 모든 앱 Pod 1개, HPA min/max 1
.\tools\stabilize.ps1

# 부하 후 안정화 대기 시간 변경
.\tools\stabilize.ps1 -WaitSeconds 180

# API/WAF 점검은 복구 스크립트와 분리해서 실행
.\tools\check.ps1 -Api
```

`tools/stabilize.ps1`은 API 요청을 보내지 않는다. 부하로 늘어난 `user`, `product`, `stress` Deployment를 각각 1개 Pod로 줄이고 HPA를 `minReplicas=1`, `maxReplicas=1`로 고정한다. HPA가 다시 확장되는 것을 막기 위해 이 동작을 유지한다.

## 성능 운영 원칙

- 평상시에는 각 애플리케이션 Pod 1개로 유지한다.
- 부하 중에는 Stress가 User/Product와 CPU를 공유하므로 5xx, timeout, P95를 함께 관찰한다.
- 성능 채점 전에는 필요한 경우 User/Product 2개, Stress 3~4개를 pre-warm한다.
- 반응형 HPA만 믿지 않는다. 노드와 Pod 확장 지연으로 초기 timeout이 발생할 수 있다.
- Stress 전용 NodePool은 기본 설정으로 만들지 않는다. 비용/인스턴스 비율을 먼저 고려한다.
- WAF rate limit은 사용하지 않는다.
- 성능 변경 후 비용 영향과 Terraform 재생성 여부를 함께 확인한다.

## WAF 원칙

- AWS Managed Rules를 우선 사용하고 커스텀 규칙은 보완용으로만 추가한다.
- 정상 User/Product 요청과 Product multipart PUT을 차단하지 않는다.
- multipart PUT에 JSON Body 검사를 적용해 정상 이미지를 차단하지 않는다.
- WAF 로그에는 요청 Body가 직접 포함되지 않으므로 CloudWatch Logs Insights와 점검 스크립트로 판단한다.
- WAF 변경 후 정상 API는 200/201, 악성·비정상 실제 API는 403, unknown path는 404인지 확인한다.

## 변경 및 검증 규칙

- PowerShell 스크립트는 `tools/`에 둔다.
- 기존 스크립트의 목적을 바꾸기 전에 호출 위치와 사용법을 확인한다.
- 스크립트 변경 후 문법 검사와 dry-run 가능한 검증을 수행한다.
- Terraform 변경 후 반드시 `terraform validate`를 실행한다.
- Kubernetes 변경 후 rollout, Pod Ready, HPA 상태를 확인한다.
- 운영 리소스 삭제/축소 전 현재 부하가 종료됐는지 확인한다.
- 결과 파일과 부하 테스트 산출물은 임시 경로에 저장하며 저장소에 커밋하지 않는다.

---

## Git 워크플로 규칙

- **`tools/tune.ps1` 등 스크립트에 변경점이 생기면 그 작업이 끝날 때마다 즉시 커밋 + push** 한다 (대회 중 재현성 보장).
- commit message는 주인이 한눈에 이해하도록 한국어로 핵심 변경/이유를 요약한다.
- 작업 기록은 이 파일(AGENTS.md)에 로그로 남긴다.

## 최근 작업 로그

| 2026-08-22 | pending | cooldown PDB relax 함수가 `Invoke-Kubectl` 출력을 saved hashtable과 함께 반환해 restore 값이 배열로 오염되고 user/product PDB가 0으로 남는 버그 발견. active baseline을 중지하고 PDB 1 즉시 복구, relax/restore kubectl 출력을 `Out-Null` 처리. 구버전 tuner 종료 후 self-test 36/36·terraform validate 통과. |
| 2026-08-22 | pending | profile 시작 지연 개선: no-traffic cooldown에서 Ready 부하가 없고 HPA가 60초 이상 잔류하면 노드 수와 무관하게 `tune.ps1`이 scaleDown을 임시 0s/100%로 가속하고 min 도달 즉시 표준 300s/Min 정책을 복구. 이전 6~10분 stair-step 대기와 cooldown timeout 오염을 제거. user25 near-ceiling 증거로 다음 seed user target33→28 적용. parse/self-test 36/36·terraform validate 통과. |
| 2026-08-22 | pending | 기존 binary 재튜닝 seed user Max25 `run-1787408633`은 spike1에서 user24/25 near-ceiling, perf70.42%, 총점34까지 확인 후 1435s에 근거 종료. exact max/CPU>target만 요구해 online 전환하지 못한 조건을 보강하여, perf<75 + 최근3 sample desired≥90% Max + CPU≥90% target도 recovery signal로 인정하고 `HPA_TARGET_RECOVERY` user33→28 one-delta를 생성하도록 개선. 기존 binary 재배포 상태 유지, self-test 36/36·terraform validate 통과. |
| 2026-08-22 | pending | 기존 binary+t3 0.5x 2h `run-1787402745`는 4358s에 중지: 21.5/40(성능5.5·비용0), user/product/stress perf 23.96/97.52/78.94%, avg4.26, peak Ready7, spike1 Pending17, user20·stress12 HPA ceiling. 성능<30 이후 계속 관찰한 운영 오류를 인정하고 즉시 stop, 검증된 low binary(S3/ECR/rollout/API)와 최고 구성으로 복구. 단순 붕괴 stop 대신 `tune.ps1`이 10분 이후 perf<90 + 최근3 sample HPA ceiling/CPU>target을 감지하면 partial evidence를 보존하고 run을 조기 종료하여 outer lifecycle이 HPA Max one-delta를 생성·재시작하도록 개선. self-test 36/36·terraform validate 통과. |
| 2026-08-22 | pending | 사용자 요청에 따라 low 교체 전 기존 `application/binary`를 commit `f36dcbd`에서 복원하고 S3/ECR latest 재배포·rollout. 기존 digest user `d90e5791`, product `4deb5e02`, stress `2a843ac8` 사용 확인. t3.medium 2대에서 health/user/product 200, stress length128 201(652ms), warm API 49~100ms 정상. 동일 최고 HPA/resource 구성과 0.5x 2h-standard 재검증 준비. |
| 2026-08-22 | pending | t3.medium 2대 idle + low binary 최고 구성 0.5x `2h-standard` `run-1787395279` 완주: 39/40(가용성12·성능12·비용11), user/product/stress perf 92.47/112.42/98.78%, availability 99.94/100/99.96%, avg EC2 2.23, dropped0. baseline/spike1/valley는 40 유지, spike2에서 38→39 회복, peak Ready3 후 down1에서2로 복귀. tuner는 초반 PROFILE_RUN_CHANGED로 종료됐지만 injector 7199s 및 독립 observer/API score로 완주 검증. |
| 2026-08-22 | pending | 사용자 요청으로 `terraform.tfvars` 단일 기준을 c5.large→t3.medium으로 복귀. saved plan(2 add/2 change/1 destroy) 적용해 Managed NodeGroup 교체 후 bastion setup이 Karpenter default/stress 요구 타입도 t3.medium으로 동기화. PDB로 남은 c5 stress 노드는 cordon+stress rollout으로 t3 stress 노드를 먼저 Ready시킨 뒤 안전 종료. 현재 EKS running EC2는 t3.medium 2대뿐이며 최고 39점 구성(user/product70m, stress550m@60) `tune.ps1` fingerprint 복구, Pod/HPA min 및 API 200 확인. |
| 2026-08-22 | pending | shared user request 70m@33→50m@46 후보 `run-1787387744`는 36.5/40(성능9.5·비용11·avg2.47), user perf 77.69%로 39점 BEST보다 크게 회귀하여 REJECT. peak에서 default 노드가 여전히 생성되어 2노드 packing도 실패. tuner immutable rollback으로 user70m@33·stress550m@60 복구 및 rollout 확인 후 중복 fresh는 중지. 원인은 shared capacity에서 static system Pod request 누락으로, domain 모델이 shared에는 DaemonSet뿐 아니라 전체 `AvailableAppCPU` reserve를 사용하도록 교정하고 unsafe 후보 방지 self-test 35/35·terraform validate 통과. |
| 2026-08-22 | pending | 39→40 비용 후보를 위해 `Get-CostAwarePackingRecommendation`을 앱 단독 density뿐 아니라 live nodeSelector placement-domain 합산 경계로 확장. 동시 HPA desired의 CPU request·memory·Pod slot이 축소 노드에 fit하고 실측 aggregate CPU<80%인 경우에만 절대 HPA trigger 보존 request 후보를 생성하며, 같은 node saving이면 상대 request 감소가 가장 작은 안전 후보를 우선. 현재 evidence는 shared user20+product7~8의 2→1노드 경계에서 user70m@33→50m@46을 산출. self-test 35/35·terraform validate 통과. |
| 2026-08-22 | pending | low binary 공식 0.5x `순차증가`: BASE `run-1787380613` 38/40(성능12·비용10·avg2.90·peak4), stress request packing 600m@55→550m@60 후보 `run-1787382981` 39/40(성능12·비용11·avg2.50·peak3), FINAL_FRESH `run-1787385221` 39/40(가용성12·성능12·비용11, user/product/stress perf 90.63/113.70/99.23%, avg2.43, dropped0) 재현. 절대 HPA trigger330m 보존과 stress 3 Pod의 전용 노드 2→1 packing으로 1점 개선하여 KEEP. |
| 2026-08-22 | pending | `/api/load/start`가 user-scoped 강도를 저장 기본값 0.25로 되돌리는 동작을 짧은 calibration run으로 확인. active run에서 scoped meta를 0.5로 PUT하면 target이 2.3→4.7 RPS로 즉시 전환됨을 검증하여 `-ExternalLoadMultiplier`를 추가하고, 각 start/restart 직후 global+발견된 scoped multiplier를 원자 적용·GET 검증하도록 보강. 기본값0은 서버 설정 보존. self-test 34/34·terraform validate 통과. |
| 2026-08-22 | pending | low binary 첫 `run-1787378429`는 CloudFront 생성 직후 load server DNS 미전파로 앱 access log/HPA 트래픽 없이 2xx=0인 무효 run. 이어진 `run-1787380268`에서 DNS 정상화를 확인했지만 scoped multiplier가 0.25로 돌아가 88초에 중지. endpoint가 이미 같아도 meta PUT을 실행하면 서버가 user-scoped UI metadata를 refresh해 명시 강도를 덮는 원인으로 판단하여, `tune.ps1` endpoint 동기화를 GET-first·불일치할 때만 PUT하도록 수정. self-test 34/34·terraform validate 통과. |
| 2026-08-22 | pending | 0.5x fresh 순차 검증 전 `tune.ps1` 외부 load API 관측을 4회 지수 backoff retry로 보강. 이전 run에서 injector는 정상인데 skills-server 단발 연결 거부로 tuner만 종료된 재현성 문제를 방지하며, 중복 run 위험이 있는 `/api/load/start` POST는 retry하지 않고 GET 및 idempotent endpoint PUT만 retry. parse/self-test 34/34·terraform validate 통과. |
| 2026-08-22 | pending | 재생성 인프라 CloudFront `d3tum9m2cawjh9.cloudfront.net` Deployed 후 `Downloads/high_binary/low_binary`의 user/product/stress를 `application/binary`·S3·ECR latest에 반영하고 rollout 완료. 새 digest user `d17299b8`, product `97d8642c`, stress `240e5f97` 확인. 외부 health/user/product 200, stress 201, WAF 403/unknown 404 정상; 최초 CloudFront health 573ms는 warm 후 39~48ms. terraform validate 통과, plan은 종료된 bastion 재생성과 ALB SG drift 1 change가 있어 apply하지 않음. |
| 2026-08-22 | pending | 재생성 환경 endpoint 동기화 후 user Max40·8노드 ceiling 0.25x `순차증가` `run-1787356819`: 32.5/40(가용성12, 성능9.5, 비용7), user/product/stress 성능 81.25/108.10/88.33%, 평균 EC2 4.40, dropped=0. spike1은 성능12 유지, spike2 user33·product19·stress6/Ready peak7에서 게이트9→9.5 회복. 300s scale-down이 done 구간 6노드를 오래 유지해 비용이 기존 Max40 최고 run의 8→7로 하락. tuner는 skills-server 일시 연결 실패로 5분에 종료했으나 injector는 정상 완주해 별도 모니터 로그로 검증. Max32 기준보다 점수·비용이 낮아 REJECT하고 immutable fingerprint로 user Max32를 복구. |
| 2026-08-22 | pending | 인프라 재생성 후 새 CloudFront `do876irwkqghf.cloudfront.net`은 정상이나 load server persisted meta endpoint가 삭제된 `d3tmuvdlyjyjyk.cloudfront.net`에 남아 `run-1787356534`가 2xx=0/0점이 된 것을 탐지·즉시 중지. `tune.ps1`이 매 profile 시작 전에 `/api/config/meta` endpoint를 현재 발견한 CloudFront로 PUT·GET 검증한 후 `/api/load/start`에도 명시하도록 보강. self-test 34/34·terraform validate 통과. |
| 2026-08-22 | pending | HPA 300s scale-down 안정화 + user Max32 rollback 상태 fresh `run-1787339949`: 33/40, 가용성12, 성능9(게이트 통과), 비용8, user/product/stress 성능 76.62/105.40/88.26%, 평균 EC2 3.76. 스파이크 동안 user32·product17~19·stress4를 유지하고 가용성 99.99~100%, dropped/CNI 0. 성능 게이트가 꺼지지 않아 추가 코드 변이는 중단하고 300s 안정화 후 idle floor 복귀를 확인한다. |
| 2026-08-22 | pending | user Max40 후보는 1차 `run-1787335919` 34.5/40·성능10.5로 KEEP됐으나 FINAL_FRESH `run-1787337791`이 33.5/40·성능8.5로 게이트 off. live HPA scaleDown=0s/100%로 spike2 replica가 29~35 사이에서 흔들린 원인을 반영해 external sweep 시작 전 scaleUp=0s·scaleDown=300s/Min을 강제 검증하고, FINAL_FRESH dual gate 실패 시 직전 measured BEST 자동 롤백 및 rejected signature 기록을 추가. self-test 34/34 통과. |
| 2026-08-22 | pending | `tune.ps1`의 live Max 안전 상한을 측정 seed의 1.5배로 분리하고, aggregate 성능 게이트가 통과해도 개별 앱 성능<90%·실측 HPA ceiling·비용 게이트 통과 시 Max를 20~25% bounded one-delta로 확장하도록 개선. 0.25x 증거의 user 32/32·uncapped 41을 user Max 40 후보로 산출하며 self-test 32/32 통과. |
| 2026-08-22 | pending | 사용자 지정 0.25x `순차증가` 진단 `run-1787333608`: 33.5/40(가용성 12, 성능 9.5, 비용 8), user/product/stress 성능 84.16/109.47/86.27%, 평균 EC2 3.73·peak 6·dropped/CNI 0. user HPA 32 ceiling 15/48 sample과 spike2 steady user p95 222~256ms를 확인해 다음 단일 후보를 user Max 32→40으로 선정하되 아직 적용하지 않음. 공식 0.5x 결과와 직접 비교하지 않는다. |
| 2026-08-21 | pending | `tune.ps1 -PerformanceGateOnly`를 통해 HPA/request/limit을 스크립트로만 적용하고, CNI IP 할당 실패 대응으로 10.0.4.0/22·10.0.8.0/22 pod-capacity subnet을 추가. Node Type/RDS Instance Type은 유지. Default-spike2 10분 실측: 성능 11/12, user 89.39%, product 112.14%, stress 88.32%, 총 27/40(평균 EC2 9.45로 비용 0). | 
| 2026-08-21 | pending | 저트래픽 min=2, 빠른 HPA scale-up(15초), 5분 scale-down stabilization을 `tune.ps1`에 반영. 동일 프로필 Default/Default-spike2/순차증가를 수용하며, 리소스 소실 시 즉시 중지·JSON 기록하는 `RESOURCE_LOSS_STOP` guard 추가. Adaptive Default-spike2 15분: 성능 10.5/12, user 89.46%, product 111.88%, stress 85.64%, 총 26.5/40. |
| 2026-08-21 | pending | `skills-server:8003` 3개 프로필 실측 완료 — Default 28/40(성능 12/12, user 99.21%, stress 90.93%), Default-spike2 26/40(성능 10/12, user 90.19%, stress 80.56%), 순차증가 27/40(성능 11/12, user 88.12%, stress 87.85%). 리소스 소실 없음. `-ProfileSweepOnly`에 3개 프로필 순차 실행·조기중지 재시작·소실 기록을 추가. |
| 2026-08-21 | pending | `tune.ps1` production 유일 경로를 unknown-application 측정 lifecycle로 전환(legacy/app-fixture production 실행 차단) — Deployment/HPA 자동 발견, live config를 실행별 immutable BASE/BEST로 사용, 세 프로필 `min(TotalScore)` 우선 선택, min/request 분리 one-delta, request 변경 시 absolute HPA trigger 보존, 실제 3프로필 FINAL_FRESH 검증, CNI/Pending/generator/resource 소실 중지·JSON 기록. 현재 EKS API 소실로 live 검증은 중지하고 `%TEMP%/wsi-generic-no-resource/resource-loss-*.json` 기록. parse/terraform validate 및 self-test 19/19 통과. |
| 2026-08-21 | pending | 재생성 리소스 점검 — kubeconfig를 새 EKS endpoint로 갱신, c5.large 노드 2대 Ready, 앱 5 Pod/ALB target 정상, RDS db.t3.micro Multi-AZ gp3 available, CloudFront/WAF 정상 확인. 외부 부하 서버의 이전 run endpoint가 null인 문제를 발견해 모든 `/api/load/start` 요청에 현재 발견한 CloudFront endpoint를 명시하도록 수정. self-test 20/20 통과. Terraform plan은 최신 AMI에 의한 bastion 교체와 ALB SG drift가 있어 apply하지 않음. |
| 2026-08-21 | pending | live 범용 튜닝 시작 — 첫 실행이 profile 경로의 endpoint 초기화 누락으로 부하 시작 전에 종료되어 production profile 진입 전에 `Initialize-EndpointAndData`를 실행하도록 수정하고 non-resource 조기 종료 규칙에 따라 1회 재시작. BASE/Default run `run-1787272400` 동작 중이며 결과는 `%TEMP%/wsi-live-tune-20260821-0932`에 저장. |
| 2026-08-21 | pending | Default 실측 분석 — 초반 2노드 40/40에서 spike 후 user/product HPA 20/14, stress 3 및 총 4노드로 증가해 최종 35/40(user/stress tail+평균 노드 비용). Max는 저부하 제어가 아니라 고부하 ceiling이므로, 성능 guard 실패 시에만 max 증가, guard 통과 시 measured peak+20% headroom으로 미사용 max를 one-delta 축소하도록 변경. 프로필 사이에는 최대 360초 동안 최초 measured low-load node floor/HPA min 복귀를 기다려 이전 profile 노드가 다음 비용창을 오염시키지 않도록 추가. self-test 21/21 통과. |
| 2026-08-21 | pending | BASE 3프로필 후 최종 status의 순간 `sent_rps=4/target=4.6` 흔들림을 전체 run generator limit으로 오판해 candidate 탐색이 중단된 문제 수정 — 외부 엔진의 누적 `dropped>0`만 generator saturation 근거로 사용하고 정상 RPS jitter는 계속 탐색. self-test 22/22 통과. |
| 2026-08-21 | pending | 연속 iteration 재시작 시 직전 profile의 잔여 Ready 5대를 low-load floor로 잘못 캡처한 문제 수정 — floor를 현재 노드 수가 아니라 Ready managed node 수 + min>0 앱의 distinct nodeSelector domain 수로 계산해 현재 topology는 1+1=2대로 산정. 다음 profile/candidate는 2대 복귀 후 측정. |
| 2026-08-21 | pending | fresh BASE(Default 35.5, spike2 21.5, 순차 16.5) 병목 반영 — ceiling 후보를 앱별 최저 performance로 정렬하고 Max를 20% 증가(user 20→24 우선), 비-ceiling 지속 CPU guard deficit은 target -5, selection은 availability/타 profile 회귀 없이 guard deficit·worst profile 개선 시 KEEP. Guard 통과 뒤 live usable CPU density boundary request packing+absolute trigger 보존 추가. fingerprint 일치 immutable BASE resume 지원, self-test 25/25. |
| 2026-08-21 | pending | 저부하 3번째 노드가 10분 이상 유지된 원인을 user PDB minAvailable=3 > HPA min/current=2로 확인(Karpenter DisruptionBlocked). production tune lifecycle에서 이 수학적으로 불가능한 PDB 관계만 minAvailable=max(1,HPA min-1)로 교정하고 valid PDB는 유지하도록 prerequisite 추가. |
| 2026-08-21 | pending | fresh 고부하에서 `failed to assign an IP address` 266건 확인 — Terraform으로 CNI enhanced subnet discovery용 10.0.4.0/22·10.0.8.0/22(각 AZ, role/cni tag)와 route association을 targeted apply(4 add, 0 change/destroy). Cooldown 중 shared node에 같은 앱 Pod가 몰려 valid PDB도 consolidation을 막는 경우 no-traffic/HPA-min 동안만 shared PDB를 0으로 임시 완화하고 profile 시작 전 복구, dedicated PDB 유지. |
| 2026-08-21 | pending | `-WorkerNodeCeiling 6 -DiagnosticSweepOnly -SweepProfiles 순차증가` 지원 — managed node를 제외한 슬롯을 discovered NodePool별 HPA max CPU demand 비율로 배정하여 총 worker ceiling을 제한하고 단일 프로필 진단. stress isolation 유지 시 물리 idle floor는 2임을 명시. |
| 2026-08-21 | pending | 6노드 순차증가 진단 `run-1787294395`는 16.5/40(평균 EC2 4.73, stress availability 49.13%)이나 무효 인프라 측정: 추가 stress c5.large 3대가 NAT 없는 pod-capacity 10.0.8.0/22에 생성되어 NodeClaim Unknown/미등록 상태로 비용만 집계됨. EC2NodeClass의 cluster shared subnet selector가 CNI 전용 subnet까지 선택하는 것이 원인. 부하 종료 후 미등록 NodeClaim/EC2 정리, 원래 3개 Node Ready 및 앱 HPA min 건강 확인 후 사용자 요청에 따라 중지. |
| 2026-08-21 | pending | Karpenter EC2NodeClass subnet selector에 `kubernetes.io/role/elb=1`을 추가해 Public subnet 2개만 노드용으로 선택하도록 live/`bastion_setup.sh` 반영. 1200m stress probe로 신규 `stress-q6srz`가 37초 내 Ready, public subnet `subnet-0e7ef5168e828794d`/public IP 사용 확인 후 probe와 임시 NodeClaim/EC2 삭제, 기존 3노드 및 앱 건강 확인. |
| 2026-08-21 | pending | 단일 `DiagnosticSweepOnly`도 최적화 경로와 동일한 topology-derived low-load floor를 초기화하도록 공통 함수화. 기존 진단의 잘못된 floor=0 대기/timeout을 제거하고 stress isolation 기준 floor=2에서 순차증가 재측정 준비. |
| 2026-08-21 | pending | Public subnet 수정 후 순차증가 `run-1787298425`: 23/40, user/product/stress 가용성 99.97/99.98/99.33%, 성능 24.77/101.11/85.48%, 평균 EC2 4.53, nodes 3→6, dropped=0, CNI=0. stress 병목은 복구됐고 user HPA 20/20 ceiling(peak CPU 1496m)이 주 병목. 종료 후 추가 Karpenter capacity를 정리해 topology floor 2노드와 앱 Ready 확인. |
| 2026-08-21 | pending | 성능 게이트 복구 실험 전, 중단된 cooldown이 shared PDB를 0으로 남긴 상태를 startup에서 자동 복구하도록 보강. HPA min>1이고 PDB minAvailable=0이면 `max(1,min-1)`로 복구하여 저부하 노드 floor는 유지하면서 rollout/노드 disruption 가용성을 보호. |
| 2026-08-21 | pending | Karpenter 정상 확장 중 2개 sample에만 나타난 일시적 `Insufficient cpu` Pending을 영구 `NODE_CPU_CAPACITY`로 오분류하던 문제 수정. 전체 sample의 10%(최소 3개) 이상 지속될 때만 infra stop하며, 짧은 Pending 뒤 Ready 확장되면 user HPA ceiling 복구 후보를 계속 평가. self-test 26/26. |
| 2026-08-21 | pending | user HPA Max 20→24 one-delta `run-1787302469` REJECT: 22/40, avg EC2 4.50(cost 0), perf 6/12(user 25.09%, stress 81.54%)로 BASE 23/40/perf7보다 회귀, Max20 복구. 성능과 비용 dual guard를 별도 deficit으로 추적해 어느 한쪽 악화와 교환 금지, final은 둘 다 통과해야 acceptance. cost off이면 replica 추가 전 measured aggregate CPU 80% headroom + density boundary request packing 우선, self-test 28/28. |
| 2026-08-21 | pending | stress request/control point packing 600m@55→550m@60 one-delta fresh `run-1787305449`는 2노드 저부하 40/40 후 spike2에서 perf 5/12(user 28.26%, stress 66.29%)로 dual gate 위반하여 30분 전 즉시 중단/REJECT. immutable config fingerprint를 production restore mode로 적용해 600m@55 복구. evidence fingerprint rollback self-test 포함 29/29. |
| 2026-08-21 | pending | 재시작 간 immutable rejected signature 입력 지원. user Max20→24 및 stress packing550이 실패한 상태에서는 unrelated healthy product Max를 건드리지 않고, 같은 user 병목의 HPA target 33→28 조기 확장을 다음 one-delta로 선택. Min=2 및 peak ceiling=20은 유지해 저부하/최대 노드 비용을 늘리지 않음. self-test 30/30. |
| 2026-08-21 | pending | user HPA target 33→28 fresh `run-1787307750`은 2노드 저부하 39/40 후 spike1 32초에 perf 7/12(user 47.81%)로 gate off되어 즉시 중단/REJECT, fingerprint BASE 복구. rejected target 누적 시 BASE 불변으로 target 28→23→18→15 신호 강화 후보를 순차 생성하도록 보강, self-test 31/31. |
| 2026-08-21 | pending | 탄력 운영 저비용 기반 적용 — worker hard ceiling 6(managed1+default1+stress4), Karpenter consolidateAfter 1m, shared user/product의 preferred hostname spread 제거, dedicated stress spread 유지. 무부하 실제 2노드와 앱 Ready 확인. user/stress 조기 trigger 18%/35% 실험은 아래 실측 후 REJECT하여 33%/55% 복구. |
| 2026-08-21 | pending | 조기 trigger 18%/35% 순차증가 `run-1787311291`: 22.5/40, avg4.33, perf6.5(user22.85%, stress84.76%), cost0으로 BASE 23/40보다 개선 없음. spike1에서 5노드까지 prewarm했지만 spike2 steady user 병목은 해결되지 않아 HPA 33%/55% fingerprint 복구. 저부하 2노드/1분 consolidation/총6 ceiling 정책만 유지. |
| 2026-08-21 | pending | 비용 최소 1점을 허용한 성능우선 실험: total ceiling 7(managed1+default2+stress4), user Max24 `run-1787314521`은 23/40, perf7/12(user24.08%, stress85.61%), avg4.57/cost0. 6노드 BASE 대비 성능 개선 없이 비용 경계만 초과하여 REJECT, user Max20/total6 복구. 현재 binary는 노드/replica 추가로 성능12 달성 불가 근거 확보. |
| 2026-08-20 | superseded | 3대 프로필 실측 — stress 성능 4.69%, user 8.51%로 성능 게이트 실패. 600m stress 6개를 안정적으로 수용하려면 stress NodePool 3대분(CPU 6)이 필요함을 확인 |
| 2026-08-20 | pending | 안정 프로필로 전환 — default CPU 2, stress CPU 6(전용 3대), HPA user/product 2~20·stress 1~6, 저부하 consolidation 5m 유지 |
| 2026-08-20 | pending | spike2 결과 반영 — stress HPA 6개 중 3개만 Ready, stress 5xx 175건·P95 30초로 확인되어 NodePool stress 한도를 4 CPU(2대분)로 확대해 총 4대까지 허용하고 request 500m 기준을 소스에 반영 |
| 2026-08-20 | pending | `bastion_setup.sh` 성능 개선 — Karpenter default/stress를 각 2 CPU(각 1대분)로 조정해 총 3대 유지, stress 노드 1대 축소, ALB least-outstanding-requests와 앱 topology spread 반영 |
| 2026-08-20 | pending | `tune.ps1` 개선 — 38점 앱 세트 BASE seed를 live 오염 상태가 아닌 재현 구성(70m/70m/600m, HPA 33/29/55, min 2/2/1)으로 고정하고, 외부 부하 결과의 잘못된 EC2 telemetry(reported 1 vs actual 3)를 진단 import/경고하며 최종 적용 config를 BASE 결과에 저장 |

| 날짜 | 커밋 | 변경 요약 |
| 2026-08-18 | pending | `bastion_setup.sh`/EKS Launch Template에 38점 기준 반영 — CNI prefix+warm prefix, MNG/Karpenter maxPods=110, user/product 70m·256Mi, stress 600m·2CPU·dedicated NodePool, HPA 33/29/55 및 20/20/6 |
| 2026-08-18 | pending | `tools/apply-38point.ps1` 추가 — CNI prefix delegation, maxPods=110, user/product/stress 38점 리소스/HPA, stress dedicated NodePool/taint/selector를 재현하고 MNG Launch Template 갱신은 명시적 opt-in |
| 2026-08-18 | pending | tune BASE 분기 종료 시 GRADING_READY finalize 추가 — stress 전용 NodePool/selector 제거, shared placement, min replica warm(2/2/1), HPA max 유지, Karpenter 노드 예산 대기 |
| 2026-08-18 | pending | CNI precondition의 잘못된 속성명(`Enabled/MaxPods`)을 `PrefixDelegation/WarmPrefixTarget`으로 수정하고 unavailable/false를 구분 — live `true/1` 검증 |
| 2026-08-18 | e6950ac | `tools/tune.ps1` 기본 경로를 BASE-first로 고정하고 `-LegacyAdaptive`를 opt-in으로 제한, BASE(600m stress/isolated) → ONE DELTA → BEST verification 흐름 추가, main 오류에 line/position/stack trace 추가, self-test 11/11 통과 |
| 2026-08-18 | `e2df10a` | **progressive warm min**: Balanced/CalculatedFinal 측정에 직전 측정 기반 warm min 반영 — cold-start(stress min=1)이 stress SLO를 0%로 붕괴시키는 것을 실측으로 규명(노드당 stress ≈2.2~3.6rps, same-node pod 무증가, 8 warm pods/4노드=61.5% vs cold start=2.6%) → Competition 25/36 달성 (기존 21.5/36) |
| 2026-08-18 | `fb90289` | 최종 보고/저장 오류 시 적용 상태 유지(Save-Results/보고/요약 비파탈) + FINAL_WARM_NODE_BUDGET warning-only |
| 2026-08-18 | `4d5d621` | pipeline integrity: Build-HpaBudgetModel placementDomain source-of-truth(dedicated domain 생성, .Cpu null 크래시 제거), Apply-StressPlacement NodePool stdin 파이프 수정, No-Scale fill fallback |
| 2026-08-18 | `48b566e` | 측정 시작 상태=채점 시작 상태: 세션 시작 시 stress isolation artifact를 SHARED로 복귀 + Prepare-Test에서 k6 시작 전 min까지 warm prewarm |
| 2026-08-18 | `594ac78` | CPU limit 제거 JSON patch가 limit 부재 시 server-rejected로 롤백 전체가 깨지는 문제 no-op 처리 |
| 2026-08-18 | `abd2bfc` | self-test harness 동기화(stress cp=165m, Restore/Save 로드, ControlPointStateFile 초기화) |
| 2026-08-18 | `5356ba5` | **`tools/tune.ps1` P0 안정화 패치**: ① stress CPU limit `request*2` cap 제거, ② user/product CPU limit optional ($null) 설정 및 OP remove json patch, ③ `Get-IdleCapacity` 내 CPU/MEM typo 수정 및 shared/dedicated topology fit 정확화, ④ CostWindowSeconds 기반으로 `CostNodeSeconds` clamp 적분 및 `AverageTotalNodes` score source 통일, ⑤ apply 전후 fingerprint gate 추가 및 런타임에 따른 재측정/롤백, ⑥ `BaselineMinVector` snapshot 기반 No-Scale min fill 위반(Node 증가, Pending, Unschedulable) 시 rollback 로직 구축 |
| 2026-08-16 | `179ce1d` | HPA min optimizer crash fix: min=1 필수 floor가 min budget 초과 시 budget 확대(`HPA_MIN_BASELINE_BUDGET_INFEASIBLE` throw 제거), SPLIT 신호에 stress 자체 성능 추가(stress SLO<65% 또는 LOAD_GENERATOR_LIMIT+generated<80%면 SPLIT — foreground 무관) |
| 2026-08-16 | `tune.sh-bash` | **tools/tune.sh를 bash 순수 이식본으로 교체 (pwsh 불필요)** — Amazon Linux 2023 Bastion 전용: 공통 경계 score(50/70/82.5/90/95→1.0/1.5/3.0/3.5/4.0) + 평균 EC2 cost tier, 3단계 측정(Minimum/Balanced/CalculatedFinal, k6-load.js 재사용), placement domain min/max budget optimizer(warm min 우선), best profile 선택+verification 없이 적용, 측정 준비/최종에서 Karpenter drain 없음 + max 축소 없음(P0 반영), 20분 deadline 관리, node polling 기반 avg nodes cost score |
| 2026-08-17 | `hpa-model` | **HPA/PodDensity/Resource/Cost 모델 재설계 (38점 known-good reference를 empirical prior로)**: ① HPA Control Point 모델 — `T_abs=request×target/100` 보존/학습 (user 23.1m, product 20.3m, stress 330m prior; MEASURED_STABLE/SLO_RECOVERY 학습), request 변경 시 `target=100×cp/request` 재계산, bounds 15..90 clamp ② HardSafetyMax 앱별(20/20/12) — max는 capacity ceiling, node budget 무관 ③ Pod Density/VPC CNI 리포트 (maxPods/prefix delegation/slots/POD_SLOT_LIMIT) ④ user/product ELASTIC_DENSITY_REQUEST(70m prior) + CPU limit 제거 candidate, stress GUARANTEED+2CPU burst ⑤ FINAL CONFIG reference-vs-calculated 비교 표(실측 근거 필수) ⑥ self-tests 15건 (control point 공식, max 7/4/12 유지, warm fill 40% 초과 허용, placement rebuild, bounds) 전부 PASS |
| 2026-08-17 | `hpa-max-invariant` | **HPA MAX HARD INVARIANT 적용**: ① finalMax에서 budget bin-pack 제거 — `finalMax=min(MaxAutoReplicas, capacityMax)` (budgetedMax는 no-scale diagnostic만), ② `MinCpuBudgetUtilization 0.40→0.80` — No-Scale Min Fill이 실제 노드 capacity까지 (40% hard ceiling 제거), ③ SHARED 결정 시 빈 dedicated domain 제거(Build-HpaBudgetModel 재계산), ④ POD_STARTUP_DELAY 관측 앱은 LIMIT_SCALE_UP 금지, ⑤ final warm node > OperatingNodeBudget → throw. self-test: capacityMax 7/4/12 유지 + min 5/1/2(공유/격리) 유지 + dedicated 제거 검증 |
| 2026-08-16 | `ac9e060` | tune.ps1 대규모 개선 — HPA Node Budget Optimizer(CPU+Memory), Baseline/Warm min optimizer(dynamic minReplicas) + Node Cost Guard, Stress SPLIT persist + ISOLATED_DENSE/SPREAD(density-aware limit) + burst limit, 실측 기반 request right-sizing(Q75×adaptive headroom) + throttling+SLO 기반 limit tuning, REDUCE_CPU_LIMIT 안전 하한, HPA_CEILING 강화, RollingUpdate maxUnavailable=0, 평가 성적표 레이어, WAF(user POST 허용 복구 + JSON body SQLi 차단), aws-node/kube-proxy toleration 복구, wscmon 프로브 60s 제한, Calibration fallback 분리, Invoke-Kubectl 반환 버그 수정 |
