# WSC2026 Day 2 AWS 콘솔 구성 가이드

이 문서는 현재 저장소의 Terraform과 `day2-release-candidate-tp.pdf`를 기준으로 AWS 콘솔에서 Day 2 구성을 재현하는 절차입니다.

> **중요:** 이 문서는 AWS 리소스를 생성합니다. 생성 후 사용하지 않는 리소스는 반드시 삭제하세요. 특히 NAT Gateway, MSK, Managed Service for Apache Flink는 실행 시간에 따라 비용이 발생합니다.

## 0. 구성 및 리전

| 모듈 | 리전 | 핵심 구성 |
|---|---|---|
| Module 1 | `ap-southeast-1` (Singapore) | S3 → Lambda → Step Functions → DynamoDB |
| Module 2 | `ap-northeast-2` (Seoul) | Private EC2 → ALB → Kinesis → Flink Studio Notebook |
| Module 3 | `ap-northeast-1` (Tokyo) | MSK → Lambda consumers → DynamoDB/S3 |

이번 버전에서는 **기존 Module 3 Cloud Event Handling이 삭제되고, 기존 Module 4 MSK가 Module 3으로 변경**되었습니다. 따라서 Cloud Event Handling을 별도로 만들지 않습니다.

준비할 값:

- `<STUDENT_NUM>`: 비번호. 숫자만 사용
- `<ACCOUNT_ID>`: AWS 계정 ID
- `<CONTESTANT_NUMBER>`: Module 3 S3 버킷에 사용할 숫자 비번호
- AWS 콘솔 로그인 사용자에게 VPC, IAM, EC2, S3, Lambda, Step Functions, DynamoDB, Kinesis, Glue, Managed Service for Apache Flink, MSK 권한 필요

---

## 1. Module 1 - Workflow (`ap-southeast-1`)

### 1.1 S3 버킷과 폴더

리전을 `Asia Pacific (Singapore) ap-southeast-1`로 변경합니다.

1. S3 콘솔 → **Create bucket**
2. Bucket name: `wsc2026-student-score-bucket-<STUDENT_NUM>`
3. Object Ownership: 기본값 유지
4. 현재 Terraform과 동일하게 재현하려면 Block Public Access를 해제해야 하지만, 보안상 권장하지 않습니다. 이 과제의 Lambda는 버킷 공개가 필요하지 않으므로 **Block all public access를 유지하는 것을 권장**합니다.
5. 버킷 생성
6. 버킷 안에 다음 prefix를 생성합니다.
   - `input/`
   - `processed/`
   - `error/`
7. 저장소의 `module1/test.csv`를 `input/test.csv`로 업로드합니다.

S3 폴더는 실제 디렉터리가 아니라 prefix입니다. 빈 폴더를 콘솔에서 만들거나 첫 객체 업로드로 prefix를 만들 수 있습니다.

### 1.2 DynamoDB

DynamoDB 콘솔 → **Create table**:

- Table name: `wsc2026-student-score`
- Partition key: `studentId`, String
- Sort key: `examDate`, String
- Capacity: On-demand

### 1.3 Lambda 실행 역할

IAM 콘솔 → Roles → Create role:

- Trusted entity: AWS service
- Use case: Lambda
- Role name: `wsc2026-lambda-student-role`

Inline policy를 추가합니다. 콘솔 policy editor에서 다음 권한을 해당 리소스 ARN으로 제한하는 것이 좋습니다.

- S3: `GetObject`, `PutObject`, `DeleteObject`, `ListBucket`
- DynamoDB: `PutItem`, `GetItem` on `wsc2026-student-score`
- Step Functions: `StartExecution` on `wsc2026-student-score-workflow`
- CloudWatch Logs: `CreateLogGroup`, `CreateLogStream`, `PutLogEvents`

간단한 실습에서는 `AWSLambdaBasicExecutionRole`을 추가하고 S3/DynamoDB/Step Functions inline policy를 별도로 추가해도 됩니다.

### 1.4 Score Lambda

Lambda 콘솔에서 **Create function**:

- Function name: `wsc2026-student-score-function`
- Runtime: `Python 3.12`
- Execution role: 기존 role `wsc2026-lambda-student-role`
- Code source: Upload from → `.zip file`
- 업로드 파일: `module1/lambda_score.zip`
- Handler: `lambda_score.handler`
- Timeout: 60 seconds
- Environment variables:
  - `S3_BUCKET` = `wsc2026-student-score-bucket-<STUDENT_NUM>`
  - `DDB_TABLE` = `wsc2026-student-score`

이 ZIP은 `lambda_score.py`를 루트에 포함해야 합니다. 소스 파일만 업로드하지 말고 ZIP 파일을 업로드합니다.

### 1.5 Trigger Lambda

같은 실행 역할로 두 번째 함수를 생성합니다.

- Function name: `wsc2026-student-trigger-function`
- Runtime: `Python 3.12`
- ZIP: `module1/lambda_trigger.zip`
- Handler: `lambda_trigger.handler`
- Timeout: 30 seconds
- Environment variable:
  - `STATE_MACHINE_ARN` = 나중에 생성할 Step Functions ARN

Step Functions ARN을 먼저 알아야 환경 변수를 완성할 수 있으므로, 함수 생성 후 임시 값으로 두었다가 State Machine 생성 뒤 수정해도 됩니다.

### 1.6 Step Functions 역할과 State Machine

IAM에 다음 역할을 만듭니다.

- Role name: `wsc2026-stepfunction-student-role`
- Trusted entity: Step Functions (`states.amazonaws.com`)
- 권한:
  - `lambda:InvokeFunction` on `wsc2026-student-score-function`
  - S3 `HeadObject`, `GetObject`, `PutObject`, `DeleteObject`, `CopyObject` on the bucket and its objects

Step Functions 콘솔 → **Create state machine**:

- Workflow type: **Standard**
- Name: `wsc2026-student-score-workflow`
- Execution role: `wsc2026-stepfunction-student-role`

과제 PDF의 목표 흐름은 다음과 같습니다.

```text
Start
  -> CheckS3File
  -> ProcessStudentData (Lambda)
  -> CheckResult (Choice)
       statusCode == 200 -> MoveToProcessed -> Succeed
       otherwise         -> MoveToError     -> Fail
```

Lambda에 전달할 입력은 다음과 같이 구성합니다.

```json
{"key":"input/test.csv"}
```

`ProcessStudentData` Lambda는 성공 시 `statusCode: 200`, 처리 결과와 오류 건수를 반환합니다. `processed/`와 `error/` 객체는 현재 저장소의 `lambda_score.py`가 직접 기록하므로, 콘솔에서 별도의 Move 상태를 만들 경우 중복 객체가 생길 수 있습니다.

> **현재 Terraform과 PDF의 차이:** 현재 `module1/main.tf`의 State Machine 정의는 `ProcessStudentData` 단일 Lambda Task만 포함합니다. PDF의 `CheckS3File`, `CheckResult`, `MoveToProcessed`, `MoveToError` 전체 흐름이 필요하면 Workflow Studio에서 위 상태를 추가하거나 ASL 정의를 수정해야 합니다. 현재 Lambda 코드를 그대로 사용한다면 단일 Task 구성도 동작합니다.

State Machine 생성 후 ARN을 복사해 `wsc2026-student-trigger-function`의 `STATE_MACHINE_ARN` 환경 변수를 업데이트합니다.

### 1.7 S3 → Trigger Lambda 알림

S3 버킷 → Properties → Event notifications → Create event notification:

- Event name: `input-csv-to-trigger`
- Prefix: `input/`
- Suffix: `.csv`
- Event types: `All object create events`
- Destination: Lambda function
- Function: `wsc2026-student-trigger-function`

S3가 Lambda를 호출할 수 있도록 Lambda 콘솔의 Permissions에서 S3 invoke permission이 생성되었는지 확인합니다. 같은 prefix/suffix 조합의 중복 알림 설정은 만들지 않습니다.

### 1.8 Module 1 검증

1. `input/test.csv`를 다시 업로드하거나 새 이름의 CSV를 업로드합니다.
2. Lambda → Monitor → CloudWatch logs에서 trigger와 score 로그를 확인합니다.
3. Step Functions → State machines → `wsc2026-student-score-workflow` → Executions에서 성공 여부 확인
4. DynamoDB에서 `studentId`와 `examDate`로 항목 확인
5. S3에서 `processed/` 및 `error/` prefix 확인

---

## 2. Module 2 - Real-time Data Analytics (`ap-northeast-2`)

### 2.1 VPC와 네트워크

VPC 콘솔 → Create VPC:

- Name tag: `analytics-vpc`
- IPv4 CIDR: `10.20.0.0/16`
- DNS resolution/hostnames: enabled

Internet Gateway:

- Name: `analytics-igw`
- VPC: `analytics-vpc`

서브넷을 2개 AZ에 생성합니다. 콘솔에서 실제 AZ 이름을 확인하고 두 AZ를 일관되게 사용합니다.

| Name | CIDR | AZ | 용도 |
|---|---|---|---|
| `analytics-pub-a` | `10.20.0.0/24` | AZ-1 | ALB, NAT |
| `analytics-pub-b` | `10.20.1.0/24` | AZ-2 | ALB |
| `analytics-priv-a` | `10.20.100.0/24` | AZ-1 | EC2 |
| `analytics-priv-b` | `10.20.101.0/24` | AZ-2 | 예비/고가용성 |

Public route table:

- Name: `analytics-pub-rtb`
- Route `0.0.0.0/0` → `analytics-igw`
- `analytics-pub-a`, `analytics-pub-b` 연결

NAT Gateway:

1. Elastic IP를 VPC용으로 할당
2. Name: `analytics-ngw`
3. Subnet: `analytics-pub-a`
4. Connectivity type: Public

Private route tables:

- `analytics-priv-a-rtb`: `0.0.0.0/0` → `analytics-ngw`, `analytics-priv-a` 연결
- `analytics-priv-b-rtb`: `0.0.0.0/0` → `analytics-ngw`, `analytics-priv-b` 연결

Private EC2의 user data가 `dnf`와 `pip`로 패키지를 설치하므로 NAT Gateway가 없으면 초기화가 실패합니다.

### 2.2 IAM 역할

EC2 역할:

- Role: `wsc2026-analytics-ec2-role`
- Trusted service: EC2
- `AmazonSSMManagedInstanceCore` 추가
- `kinesis:PutRecord` on `wsc2026-order-stream` 추가
- Instance profile: `wsc2026-analytics-ec2-profile`

Flink 역할:

- Role: `wsc2026-analytics-flink-role`
- Trusted service: Managed Service for Apache Flink
- Kinesis read: `DescribeStream`, `DescribeStreamSummary`, `GetShardIterator`, `GetRecords`, `ListShards`
- Glue: `GetDatabase`, `GetTable`, `GetTables`
- CloudWatch Logs write permissions

### 2.3 Kinesis Data Stream

Kinesis 콘솔에서 리전을 서울로 확인하고 Create data stream:

- Name: `wsc2026-order-stream`
- Capacity mode: **On-demand**

### 2.4 Security Groups

ALB용 `wsc2026-analytics-alb-sg`:

- Inbound TCP 80 from `0.0.0.0/0`
- Outbound all

EC2용 `wsc2026-analytics-ec2-sg`:

- Inbound TCP 5000 from **ALB security group**만
- Outbound all
- SSH 22는 열지 않음. SSM을 사용합니다.

### 2.5 EC2 애플리케이션

EC2 콘솔 → Launch instance:

- Name tag: `wsc2026-analytics-ec2`
- AMI: Amazon Linux 2023 x86_64
- Instance type: `t3.small`
- Subnet: `analytics-priv-a`
- Auto-assign public IP: Disabled
- Security group: `wsc2026-analytics-ec2-sg`
- IAM instance profile: `wsc2026-analytics-ec2-profile`
- User data: `module2/main.tf`의 `aws_instance.main.user_data`에 들어 있는 셸 스크립트를 붙여 넣습니다. `<<-USERDATA`/`USERDATA` 같은 Terraform heredoc 표식과 Terraform 보간식은 제거하고, 실제 셸 스크립트만 사용합니다.

User data는 다음을 수행합니다.

- Python 3.11 및 pip 설치
- Flask 앱 설치
- Kinesis stream name을 `wsc2026-order-stream`으로 설정
- systemd 서비스 `app` 생성 및 enable/start

### 2.6 ALB

EC2 → Load Balancers → Create Application Load Balancer:

- Name: `wsc2026-analytics-alb`
- Scheme: Internet-facing
- IP type: IPv4
- VPC: `analytics-vpc`
- Subnets: `analytics-pub-a`, `analytics-pub-b`
- Security group: `wsc2026-analytics-alb-sg`

Target group:

- Name: `wsc2026-analytics-tg`
- Target type: Instances
- Protocol: HTTP
- Port: 5000
- VPC: `analytics-vpc`
- Health check path: `/health`
- EC2 `wsc2026-analytics-ec2` 등록, port 5000

Listener:

- HTTP 80
- Default action: forward to `wsc2026-analytics-tg`

ALB DNS 이름을 복사합니다.

### 2.7 Glue Catalog

Glue 콘솔 → Data Catalog → Databases:

- Database name: `wsc2026_analytics_flink`

`order_stream` 테이블은 Kinesis 스트림을 Flink Studio Notebook에서 읽기 위한 Catalog metadata입니다. 콘솔의 Glue table wizard가 Kinesis schema를 정확히 표현하지 못하면 Flink Studio Notebook에서 connector/source를 직접 정의합니다. Terraform과 동일하게 맞추려면 다음 메타데이터를 사용합니다.

- Table: `order_stream`
- Data type: JSON/Kinesis
- Region: `ap-northeast-2`
- Columns:
  - `event_time`: timestamp
  - `order_id`: string
  - `price`: double
  - `product_name`: string
  - `quantity`: bigint
- Rowtime: `event_time`
- Watermark: 5000 ms

### 2.8 Flink Studio Notebook

Managed Service for Apache Flink 콘솔에서 Studio notebook을 생성합니다. 콘솔 명칭은 시점에 따라 Managed Service for Apache Flink 또는 Kinesis Data Analytics로 표시될 수 있습니다.

- Application name: `wsc2026-analytics-flink`
- Runtime: `ZEPPELIN-FLINK-3_0`
- Mode: Interactive
- Service execution role: `wsc2026-analytics-flink-role`
- Glue database: `wsc2026_analytics_flink`
- Parallelism: 1
- Auto scaling: disabled
- Snapshots: disabled

Notebook에서 다음 SQL을 실행합니다.

```sql
SELECT COUNT(*) AS order_count
FROM order_stream
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '1' MINUTE;
```

```sql
SELECT product_name, SUM(price * quantity) AS total_revenue
FROM order_stream
GROUP BY product_name;
```

### 2.9 Module 2 검증

```text
curl http://<ALB_DNS>/health
curl -X POST http://<ALB_DNS>/order
curl -X POST http://<ALB_DNS>/orders/generate
```

정상 응답:

```json
{"status":"healthy"}
```

EC2 콘솔 → Systems Manager → Run Command에서 다음을 실행해 systemd 상태를 확인합니다.

```bash
systemctl is-active app
systemctl is-enabled app
```

둘 다 `active`, `enabled`여야 합니다. Kinesis 콘솔에서 `wsc2026-order-stream`이 `ACTIVE`, `ON_DEMAND`인지 확인합니다.

---

## 3. Module 3 - MSK (`ap-northeast-1`)

### 3.1 VPC와 네트워크

리전을 `Asia Pacific (Tokyo) ap-northeast-1`로 변경합니다.

VPC:

- Name: `msk-vpc`
- CIDR: `192.168.0.0/16`
- DNS support/hostnames: enabled

서브넷:

| Name | CIDR | AZ | 용도 |
|---|---|---|---|
| `msk-pub-a` | `192.168.0.0/24` | `ap-northeast-1a` | NAT |
| `msk-pub-d` | `192.168.1.0/24` | `ap-northeast-1d` | Public |
| `msk-priv-a` | `192.168.10.0/24` | `ap-northeast-1a` | MSK/Lambda/EC2 |
| `msk-priv-d` | `192.168.11.0/24` | `ap-northeast-1d` | MSK/Lambda |

Internet Gateway: `msk-igw`

Public route table `msk-pub-rtb`:

- `0.0.0.0/0` → IGW
- `msk-pub-a`, `msk-pub-d` 연결

NAT Gateway `msk-ngw`:

- Public subnet: `msk-pub-a`
- Elastic IP: VPC용

Private route tables:

- `msk-priv-a-rtb`: default route → `msk-ngw`, `msk-priv-a` 연결
- `msk-priv-d-rtb`: default route → `msk-ngw`, `msk-priv-d` 연결

### 3.2 Security Groups

`wsc2026-msk-producer-sg`:

- Inbound: 없음
- Outbound: all

`wsc2026-msk-lambda-sg`:

- Inbound: 없음
- Outbound: all

`wsc2026-msk-sg`:

- Inbound all protocols/ports from `wsc2026-msk-producer-sg`
- Inbound all protocols/ports from `wsc2026-msk-lambda-sg`
- Inbound all protocols/ports from itself
- Outbound all

> 실서비스에서는 필요한 MSK 포트와 source SG만 허용하세요. 위 설정은 현재 Terraform과 과제 실습 환경을 맞추기 위한 설정입니다.

### 3.3 MSK 클러스터

MSK 콘솔 → Clusters → Create cluster:

- Creation method: Provisioned
- Cluster name: `wsc2026-msk-cluster`
- Kafka version: `3.6.0`
- Broker type: `kafka.t3.small`
- Number of brokers: 2
- VPC: `msk-vpc`
- Client subnets: `msk-priv-a`, `msk-priv-d`
- Security group: `wsc2026-msk-sg`
- EBS storage per broker: 100 GiB
- Client authentication: IAM access control enabled
- Unauthenticated access: disabled
- Encryption in transit: TLS
- In-cluster encryption: enabled

클러스터가 `Active`가 될 때까지 기다립니다. IAM 인증을 사용하는 클라이언트에는 MSK IAM SASL 서명 토큰과 적절한 IAM data-plane 권한이 필요합니다.

### 3.4 IAM 역할

EC2 역할:

- Role: `wsc2026-msk-ec2-role`
- Trusted service: EC2
- `AmazonSSMManagedInstanceCore`
- 과제 파일에는 `AdministratorAccess`가 붙어 있으나 보안상 권장하지 않습니다.
- 최소 권한으로는 `kafka:ListClustersV2`, `kafka:GetBootstrapBrokers`, `kafka-cluster:Connect`, `DescribeCluster`, `CreateTopic`, `DescribeTopic`, `AlterTopic`, `WriteData`와 app S3 `GetObject`, `ListBucket`이 필요합니다.
- Instance profile name: `wsc2026-msk-ec2-role`

Lambda 역할:

- Role: `wsc2026-msk-lambda-role`
- Trusted service: Lambda
- `AWSLambdaBasicExecutionRole`
- `AWSLambdaMSKExecutionRole`
- `AWSLambdaVPCAccessExecutionRole`
- DynamoDB/S3/SNS 접근 정책
- MSK IAM data-plane 권한

현재 Terraform에는 DynamoDB/S3/SNS 관리형 full-access 정책과 `kafka-cluster:*`, `kafka:*`가 포함되어 있습니다. 과제 재현에는 동작하지만 운영 환경에서는 리소스별 최소 권한으로 줄이세요.

### 3.5 Producer 바이너리용 S3

S3 콘솔에서 버킷을 생성합니다.

- Name: `wsc2026-app-bucket-<ACCOUNT_ID>`
- Block Public Access: 유지
- 버킷에 저장소의 `module3/app` 파일을 업로드
- Object key가 정확히 `app`인지 확인

### 3.6 DynamoDB 및 Alert S3

DynamoDB:

- Table: `wsc2026-sensor-data`
- Partition key: `sensorId`, String
- Sort key: `timestamp`, String
- Capacity: On-demand

센서 alert S3:

- Bucket: `wsc2026-sensor-alert-bucket-<CONTESTANT_NUMBER>`
- Block Public Access: 모두 enabled
- 나머지 기본값

`temperature`, `humidity`, `location`, `status` 등은 DynamoDB non-key 속성이므로 테이블 생성 시 미리 등록하지 않습니다. Lambda가 PutItem할 때 생성됩니다.

### 3.7 Kafka Topic 생성

MSK 콘솔은 클러스터를 만드는 곳이며 Kafka topic 자체를 일반 S3 폴더처럼 만들지 않습니다. 클러스터가 Active가 된 뒤 producer EC2에서 Kafka CLI 또는 애플리케이션으로 생성합니다.

EC2를 다음과 같이 생성합니다.

- Name tag: `wsc2026-sensor-producer`
- AMI: Amazon Linux 2023 x86_64
- Instance type: `t3.small`
- Subnet: `msk-priv-a`
- Public IP: disabled
- Security group: `wsc2026-msk-producer-sg`
- Instance profile: `wsc2026-msk-ec2-role`
- User data: `module3/main.tf`의 `aws_instance.sensor_producer.user_data`에 들어 있는 셸 스크립트를 사용합니다. Terraform의 `<<-USERDATA`/`USERDATA` 표식은 제거하고, `${aws_s3_bucket.app_bucket.bucket}`은 실제 버킷 이름(`wsc2026-app-bucket-<ACCOUNT_ID>`)으로, `${aws_msk_cluster.sensor.bootstrap_brokers_sasl_iam}`은 MSK 콘솔의 IAM/TLS bootstrap broker 값으로 바꿔 넣습니다.

현재 user data는 S3에서 `app`을 내려받아 systemd 서비스 `wsc2026-sensor-producer`로 실행합니다. SSM이 `Online`이 될 때까지 기다립니다.

Topic 목표:

| Topic | Partitions | Replication factor |
|---|---:|---:|
| `wsc2026-sensor-raw` | 3 | 2 |
| `wsc2026-sensor-alert` | 1 | 2 |

토픽 생성은 MSK IAM 인증용 Kafka 도구 설정이 필요합니다. AWS 공식 MSK IAM client setup 문서의 `kafka_iam_auth.py` 및 `client.properties` 방법을 사용하거나, producer 애플리케이션이 raw topic을 생성하도록 합니다. Lambda alert consumer가 alert topic으로 publish하므로 **alert topic은 Lambda mapping을 활성화하기 전에 반드시 생성**합니다.

예시 명령의 개념은 다음과 같습니다. 실제 bootstrap broker 문자열은 MSK 콘솔의 **View client information**에서 IAM/TLS용 값을 복사합니다.

```bash
kafka-topics.sh --bootstrap-server <TLS_IAM_BOOTSTRAP_BROKERS> \
  --command-config client.properties \
  --create --topic wsc2026-sensor-raw \
  --partitions 3 --replication-factor 2

kafka-topics.sh --bootstrap-server <TLS_IAM_BOOTSTRAP_BROKERS> \
  --command-config client.properties \
  --create --topic wsc2026-sensor-alert \
  --partitions 1 --replication-factor 2
```

### 3.8 Lambda consumer 함수

`wsc2026-sensor-consumer`:

- Runtime: `Python 3.14`
- ZIP: `module3/lambda/sensor-consumer.zip`
- Handler: `wsc2026.consumer_handler`
- Memory: 256 MB
- Timeout: 60 seconds
- VPC: `msk-vpc`
- Subnets: `msk-priv-a`, `msk-priv-d`
- Security group: `wsc2026-msk-lambda-sg`
- Environment:
  - `BOOTSTRAP_SERVERS` = MSK IAM/TLS bootstrap broker string

`wsc2026-sensor-alert-consumer`:

- Runtime: `Python 3.14`
- ZIP: `module3/lambda/sensor-alert-consumer.zip`
- Handler: `wsc2026.consumer_handler`
- Memory: 128 MB
- Timeout: 30 seconds
- VPC: 동일한 private subnets와 Lambda SG
- Environment:
  - `S3_BUCKET` = `wsc2026-sensor-alert-bucket-<CONTESTANT_NUMBER>`

ZIP에는 외부 의존성이 포함되어 있어야 합니다. 저장소의 ZIP을 그대로 사용하고, 함수 코드 편집기에서 파일 하나만 복사해 붙여 넣지 않습니다.

### 3.9 MSK Lambda trigger

Lambda 함수 → Add trigger → MSK:

- MSK cluster: `wsc2026-msk-cluster`
- Authentication: IAM
- Topic:
  - raw function: `wsc2026-sensor-raw`
  - alert function: `wsc2026-sensor-alert`
- Starting position: LATEST
- Batch size: 100
- Enabled: true

MSK event source mapping을 만들 때 Lambda execution role에 MSK execution, VPC access, CloudWatch Logs 권한이 있어야 합니다. 두 mapping 모두 `Enabled` 상태를 확인합니다.

현재 코드의 처리 흐름:

1. raw consumer가 센서 JSON을 읽음
2. 온도/습도 임계값을 검사
3. `wsc2026-sensor-data`에 저장
4. ALERT이면 `wsc2026-sensor-alert` topic으로 재발행
5. alert consumer가 alert topic을 읽고 S3 `alert/<sensorId>/<date>/...json`에 저장

### 3.10 Module 3 검증

MSK 콘솔:

- Cluster: `ACTIVE`
- Kafka version: `3.6.0`
- Broker type: `kafka.t3.small`
- IAM authentication: enabled

Lambda 콘솔:

- 두 함수 Runtime: `python3.14`
- 두 MSK event source mapping: `Enabled`

DynamoDB:

- `wsc2026-sensor-data`에 `sensorId`, `timestamp`, `temperature`, `humidity`, `status` 항목 생성

S3:

- alert 버킷에 JSON 객체 생성

EC2 SSM:

```bash
systemctl is-active wsc2026-sensor-producer
systemctl is-enabled wsc2026-sensor-producer
```

---

## 4. AWS 공식 문서 교차검증

아래 AWS 공식 문서와 현재 구성 파일을 대조했습니다.

1. [Lambda와 Amazon MSK 사용](https://docs.aws.amazon.com/lambda/latest/dg/with-msk.html)
   - MSK event source mapping은 topic의 batch를 Lambda event로 전달합니다.
   - Lambda 함수의 VPC 연결 및 execution role 권한이 필요합니다.
2. [Provisioned MSK 클러스터 생성](https://docs.aws.amazon.com/msk/latest/developerguide/create-cluster.html)
   - Provisioned 선택, Kafka 버전, broker size, VPC/subnet/security group 설정 순서가 현재 Module 3과 일치합니다.
   - 클러스터가 `Active`가 된 뒤 클라이언트 연결이 가능합니다.
3. [MSK IAM access control](https://docs.aws.amazon.com/msk/latest/developerguide/iam-access-control.html)
   - IAM 인증은 인증과 권한 부여를 함께 처리하며, IAM client 설정과 data-plane 권한이 필요합니다.
4. [Lambda 런타임](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
   - 현재 AWS 문서 기준 `python3.14`가 지원 런타임 목록에 있습니다.
5. [S3 Event Notifications](https://docs.aws.amazon.com/AmazonS3/latest/userguide/NotificationHowTo.html)
   - prefix/suffix 필터와 Lambda destination을 지원합니다.
   - S3가 Lambda를 호출할 permission이 필요합니다.
6. [Kinesis Data Stream 생성](https://docs.aws.amazon.com/streams/latest/dev/how-do-i-create-a-stream.html)
   - 콘솔에서 On-demand capacity mode로 stream을 생성할 수 있습니다.
7. [Application Load Balancer 생성](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-application-load-balancer.html)
   - Internet-facing ALB는 두 AZ의 subnet, listener, target group 구성이 필요합니다.
8. [Managed Service for Apache Flink Studio notebook](https://docs.aws.amazon.com/managed-flink/latest/java/how-notebook.html)
   - Interactive Studio notebook과 Glue Catalog 연동 절차를 확인했습니다.
9. [Step Functions tutorials](https://docs.aws.amazon.com/step-functions/latest/dg/tutorials.html)
   - Standard workflow와 Lambda task를 콘솔 Workflow Studio에서 구성할 수 있습니다.

### 교차검증 결과와 현재 코드의 차이

- **Module 번호:** PDF의 Module 4 MSK를 현재 저장소에서는 Module 3으로 이동한 것이 맞습니다.
- **Module 1 workflow:** PDF는 여러 상태(`CheckS3File`, `Choice`, processed/error 이동)를 요구하지만 현재 Terraform State Machine은 Lambda Task 하나만 정의합니다.
- **Module 3 topics:** 현재 Terraform은 MSK cluster와 Lambda mappings를 만들지만 Kafka topics를 생성하는 리소스는 없습니다. `wsc2026-sensor-raw`와 `wsc2026-sensor-alert`를 별도로 생성해야 합니다.
- **권한:** 현재 Module 3에는 `AdministratorAccess`, Lambda/S3/DynamoDB/SNS FullAccess, `kafka:*`가 포함되어 있습니다. 과제 재현에는 편하지만 운영용 구성으로는 과도합니다.
- **가용성:** Module 2와 Module 3의 NAT Gateway는 각 모듈에 1개입니다. 과제 기준에는 맞지만 AZ 장애에 대한 고가용성 NAT 구조는 아닙니다.

---

## 5. 삭제 순서

비용 방지를 위해 다음 순서로 삭제합니다.

1. Module 3: Lambda event source mappings → Lambda → MSK cluster → producer EC2 → DynamoDB/S3 → NAT Gateway/EIP → VPC
2. Module 2: Flink application/notebook → Glue table/database → EC2/ALB → Kinesis → NAT Gateway/EIP → VPC
3. Module 1: S3 객체 및 버킷 → Step Functions → Lambda → DynamoDB → IAM roles

S3 버킷은 객체가 남아 있으면 삭제되지 않습니다. `force_destroy`는 Terraform 설정에만 해당하며, 콘솔 삭제에서는 먼저 모든 객체와 버전/삭제 마커를 제거해야 합니다.
