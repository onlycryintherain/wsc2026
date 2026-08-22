=====1-1=====
192.168.0.0/16
192.168.10.0/24 wsc2026-skills-hub-sub-b
192.168.20.0/24 wsc2026-skills-app-sub-b
192.168.2.0/24  wsc2026-skills-app-sub-a
192.168.1.0/24  wsc2026-skills-hub-sub-a
=====1-2=====
IGW: igw-030fb0335c458083d
NAT-A: nat-013deb04b60f65336
NAT-B: nat-0a518124b5c647105
wsc2026-skills-app-rtb-a
ROUTE   0.0.0.0/0       nat-013deb04b60f65336   CreateRoute     active
wsc2026-skills-app-rtb-b
ROUTE   0.0.0.0/0       nat-0a518124b5c647105   CreateRoute     active
wsc2026-skills-hub-rtb
ROUTE   0.0.0.0/0       igw-030fb0335c458083d   CreateRoute     active
=====2-1=====
client_id       PAY_PER_REQUEST KMS     True    booking_id
ENABLED 35      ENABLED
  dynamodb:PutItem : wsc2026-book-pod-role
  dynamodb:Query : wsc2026-book-function-role
KMS wsc2026-db-kms: PASS

=====3-1=====
True    MUTABLE_WITH_EXCLUSION  v1*     KMS
v1.0.0
KMS wsc2026-ecr-kms: PASS

=====4-1=====
1.35    ACTIVE  False   True    True
SG: PASS
wsc2026.skills.local
KMS wsc2026-eks-kms: PASS

=====4-2=====
wsc2026-addon-nodegroup t3.medium wsc2026/node=addon
Addon Nodes: PASS (2)
wsc2026-workload-ng     t3.medium wsc2026/node=application
Workload Nodes: PASS (2)

=====4-3=====
Cluster Role: PASS
Addon Node Role: PASS
Workload Node Role: PASS

=====5-1=====
Deployment: PASS
Service: PASS
Ingress: PASS (wsc2026-app-alb-1542789974.ap-northeast-2.elb.amazonaws.com)
PDB: PASS

=====5-2=====
replicas:2 node:application topo:topology.kubernetes.io/zone cpu:250m mem:512Mi

=====5-3=====
startup:/health:8080 readiness:/health:8080 liveness:/health:8080
{"AWS_REGION":"ap-northeast-2","TABLE_NAME":"wsc2026-book-table"}

=====5-4=====
wsc2026-book-deploy-76455b9c75-5kj9k: PASS
wsc2026-book-deploy-76455b9c75-rxkgh: PASS

=====5-5=====
Pod Identity SA: FAIL ()
Pod Identity Role: FAIL

=====6-1=====
wsc2026-static-ttmf-101-bucket
True    True    True    True
True    aws:kms
static/index.html       static/main.jpeg
KMS wsc2026-bucket-kms: PASS
S3 Object KMS Check:
  static/index.html: PASS
  static/main.jpeg: PASS

=====7-1=====
{
    "Name": "wsc2026-book-get-function",
    "Runtime": "python3.12"
}
{
    "TABLE_NAME": "AQICAHgOOlQBVjWJfmKJoWa61gg975t+hIZQBM9jkCrwjd53qAE23ZkNwYCSrKfqZWWE7XpvAAAAcDBuBgkqhkiG9w0BBwagYTBfAgEAMFoGCSqGSIb3DQEHATAeBglghkgBZQMEAS4wEQQMYDH1oHBhpP+gGmRMAgEQgC32l+FQtv5VPff6RmvjMhwLAlZn+1+HYzOz/MAm2dnxptMIUvf8XFZxb4qVoIg=",
    "GSI_NAME": "wsc2026-booking-gsi"
}
KMS wsc2026-function-kms: PASS

=====7-2=====
wsc2026-book-function-role
wsc2026-book-function-policy    AWSLambdaBasicExecutionRole
Role: PASS
Policy: PASS

=====8-1=====
internet-facing
wsc2026-app-alb-sg
ALB direct: BLOCKED

=====9-1=====
d1c57eg3yad1r5.cloudfront.net : 200

=====9-2=====
S3: CachingOptimized
ALB/Lambda: CachingDisabled

=====9-3=====
POST booking_id: LM3T44R4
{"client_id": "MARK001", "username": "Marker", "email": "mark@test.com", "concert_name": "TestConcert", "created_at": "2026-07-13 23:45:23 KST"}

=====10-1=====
WAF Name: wsc2026-waf
SQLi: 403
XSS: 403
Rate: PASS (403)

=====11-1=====
fluent-bit: 4
prometheus: 8
grafana: 1

=====11-2=====
Datasources:
  alertmanager (alertmanager)
  cloudwatch (cloudwatch)
  prometheus (prometheus)
Dashboards:
  wsc2026-grafana-dashboard

=====11-3=====
수동 채점: 대시보드 구성 확인
접속: http://k8s-observab-grafana-f85c26fa08-0e5e459eb5404366.elb.ap-northeast-2.amazonaws.com (admin / Skills$#$@!)
대시보드: wsc2026-grafana-dashboard

Node 로우: CPU/Memory 시계열, Available Nodes 숫자
Pod 로우: CPU/Memory 시계열, Pending/Restarts 숫자
Application Pod 로우: CPU/Memory 시계열, Running/Restarts/Pending 숫자
Application Traffic 로우: RequestCount/ResponseTime/StatusCodes 시계열, Application Logs 패널
색상: CPU 80%↑ 빨강, 60~80% 노랑, 60%↓ 초록 / Restart 1↑ 경고

Application Logs 패널 로그 형식 예시:
info
{"level":"INFO","path":"/v1/book","status":"200","duration":"112.663323ms","method":"POST"}

=====11-4=====
수동 채점: Alert 확인
Alerts 로우에서 아래 5개가 빨간색(Firing)으로 표시되는지 확인
  PodHighCPU / PodHighMemory / PodNotReady / HighErrorRate / HighLatency
