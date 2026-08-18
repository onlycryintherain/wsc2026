# EKS CalculatedFinal tuner

`tools/tune.ps1`은 측정 신뢰도를 먼저 검증한 뒤 병목 원인에 해당하는 변수 하나만 조정한다. 부하 발생기 포화는 Kubernetes capacity 실패로 취급하지 않으며 동일 설정에서 VU만 늘려 재측정한다.

```text
Minimum 측정 → 신뢰도 검증 → 병목 분류 → 단일 변수 변경
→ Balanced 측정 → 단일 변수 변경 → CalculatedFinal 반복 검증
→ raw metric QualityScore 계산 → near-best(품질) 후보 비용 비교 → 적용
```

## 실행

```powershell
cd C:\Users\competitor\Documents\Github\wsc2026-d3\tools
.\tune.ps1

# 계산과 검증만 하고 원래 설정 복구
.\tune.ps1 -NoApply
```

전체 Hard runtime budget은 최대 20분이다. 마지막 120초는 후보 선택, 적용·원복, rollout과 결과 저장에 예약하므로 18분 이후에는 새 k6 측정을 시작하지 않는다. 각 측정은 예상 k6 시간에 기본 20초의 프로필 전환 오버헤드를 더해 시작 가능 여부를 미리 판단한다.

## Stress Length Calibration

실제 튜닝(Minimum 측정) 전에 Stress workload 난이도를 한 번만 캘리브레이션한다. **PASS 후보 중 가장 큰 length**를 고른 뒤, 이후 모든 k6 run(Minimum/Balanced/CalculatedFinal/VURetry/verification)에 `STRESS_LENGTH`으로 고정한다. 튜닝 중 SLO 결과를 보고 length를 다시 바꾸지 않는다.

**최종 확정 PASS 기준** (후보당 5회 분포):

```text
모든 응답 status == 201
AND median latency <= 800ms
AND 5회 중 4회 이상 <= 1000ms
AND max latency <= 1500ms
```

- **5회 분포 기반**: 단일 요청 1회 >1000ms(예: 1035)는 jitter로 허용하고 계속 측정한다. 2회 이상 >1000ms면 4/5 달성 불가로 판정된다.
- median 800ms = SLO(1000ms)의 80% headroom, 4/5 <=1000ms = 대부분 요청이 SLO 안, max 1500ms = 단일 작은 jitter 허용·과도한 spike 방지. (5초는 최소 가용성 기준이라 캘리브레이션 PASS에 사용하지 않는다)
- **early FAIL은 명백한 경우만**: status!=201, 명백한 timeout, latency>5000ms, 남은 요청으로 4/5 달성 불가(이미 2회 초과), max>1500ms 확정

```text
===== Stress Length Calibration =====
SLO: 1000ms

PASS:
  median <= 800ms
  <=1000ms >= 4/5
  max <= 1500ms

Samples: 5/candidate

[Phase 1]

length=96
  367 599 253 486 588
  median=486ms
  sloPass=5/5
  max=599ms
  → PASS

[Refinement]

length=96
  1035 420 388 510 602
  median=510ms
  sloPass=4/5
  max=1035ms
  → PASS

Phase 2 selected: 112

[Final Verification]

length=112
  681 712 890 1030 740
  median=740ms
  sloPass=4/5
  max=1030ms
  → PASS

Selected STRESS_LENGTH=112
=====================================
```

- **Phase 1**: adaptive search(128 시작, PASS면 +2 인덱스(192), FAIL이면 -1 인덱스(96), 이후 ±1 인접 이동)로 PASS한 최대 length 탐색(최대 3 후보)
- **Phase 2(Refinement)**: 1차 선택값의 lower/upper 중간값 `(lowerMid, selected, upperMid)`을 동일 기준으로 재측정(시간 충분 시 selected도 재측정, budget 부족 시 1차 측정 재사용)
- **Phase 3(Final Verification)**: Phase 2 winner를 **추가 5회 검증**해 재현성 확인. FAIL이면 다음 PASS 후보 검증(최대 2개), 전부 FAIL이면 Phase 1에서 가장 안정적으로 PASS한 후보 fallback + warning
- **45초 budget 유지**(전체 20분 deadline 불변): budget 부족 시 Final Verification 생략 → Phase 2 winner 사용 + warning
- PASS 후보가 없으면 측정 후보 중 max latency 최저 length 선택 + 경고, 데이터 0건이면 기본 `128` + 경고 (전체 tune은 계속)
- `-StressLength 160` 지정 시 캘리브레이션 생략

선택된 length는 각 k6 실행 로그(`Stress length=160`)와 최종 `calculated-final.json`의 `stressLength` 필드에 기록된다.

정상 종료 시 마지막에는 calibration/phase별 소요시간이 아니라 **tune.ps1 전체 wall-clock 시간**만 출력한다. 실패/예외 경로에서도 finally에서 동일하게 출력한다.

```text
====================================================
튜닝 완료
선택 후보: CalculatedFinal
Stress length: 144
총 실행 시간: 17:42 (1062.4초)
====================================================
```

## 순차 탐색

| 설정 | 기본값 | 의미 |
|---|---:|---|
| `MaxRuntimeMinutes` | 20 | rollout, 노드 정리, 검증과 적용을 포함한 실행 목표 시간 |
| `ShutdownReserveSeconds` | 120 | 신규 측정을 금지하고 최종화에 예약하는 시간 |
| `MeasurementOverheadSeconds` | 20 | 측정 전후 rollout·노드 정리 예상시간 |
| `ProbeDurationSec` | 180 | Minimum/Balanced 부하+cooldown 시간 |
| `FinalDurationSec` | 180 | CalculatedFinal 부하+cooldown 시간 |
| `CooldownDurationSec` | 30 | 부하 종료 후 Pod/Node 축소 관찰 시간 |
| `TargetRate` | 60 | 마지막 global RPS |
| `VUSafetyFactor` | 1.3 | `RequiredVU = ceil(rate × L_est × 1.3)` (사양 확정) |
| `MaxGeneratorVUs` | 512 | 자동 VU 증가의 절대 상한 |
| `WarmupDurationSec` | 20 | 저부하 준비 구간 |
| `SteadyDurationSec` | 30 | peak 고정 판정 구간 |
| `StressLength` | 0 (자동) | 0이면 전체 튜닝 전에 Stress 단일 요청 latency가 median≤800ms, max≤1000ms(PASS)인 가장 큰 length를 자동 캘리브레이션. 양수 지정 시 캘리브레이션 생략하고 고정 |
| `LatencyHeadroomRatio` | 0.85 | 안정 후보의 p95 운영 목표/SLO 비율 |
| `VerificationRuns` | 2 | 동일 최종 설정 최소 반복 검증 횟수 |
| `MaxNodes` | 6 | Managed를 포함한 생성 상한 계산 기준 |
| `ManagedNodes` | 1 | 유지하는 Managed Node 수 |
| `SafetyReservePercent` | 0 | Idle CPU 계산의 추가 예약 비율 |
| `SkipInstanceAwarePlacement` | false | Karpenter 앱 전용 배치 정책을 적용하지 않는 진단용 옵션 |

## SingleNode 모드 (채점용)

```powershell
# 튜닝 + 최종 적용 + 노드 1대 + pre-warm까지 한 줄로 완료
.\tune.ps1 -SingleNode -Finalize

# 계산만 확인 (원래 설정 복구)
.\tune.ps1 -SingleNode -NoApply
```

채점 부하가 처음 들어오는 시점의 노드 수를 1대(Managed)로 보장하는 모드다.

- `NodeBudget=0`: 부하 중 Karpenter 노드가 1대라도 생기면 hard failure로 판정한다.
- `Enforce-ClusterReplicaBudget(1)`: HPA max를 1노드 용량에 bin-packing한다. 스케줄링 request 하한(125m/50m/700m) 때문에 stress max는 1~2, user/product max는 잔여 용량으로 제한된다.
- `Set-KarpenterNodeLimit`이 `limits.cpu=1`로 패치되어 Karpenter가 추가 노드(c5.large 2 vCPU)를 만들 수 없다.
- `-Finalize`는 최종 적용 직후 `tools/finalize.ps1`을 자동 실행해 Karpenter 노드를 drain하고 pre-warm(user 2 / product 2 / stress 1)을 적용한다. 이후에는 인자 없이 `tools/finalize.ps1`만 다시 실행해도 된다(최신 튜닝 결과 자동 탐색).

## 공통 부하

모든 프로필은 같은 `tools/tune/k6-load.js`를 사용한다. 10 RPS warm-up 후 `20 → 30 → 40 → 50 → 60 RPS`로 ramp-up하고, 마지막 60 RPS를 30초간 고정해 steady-state를 측정한다. 이후 부하를 0으로 내려 cooldown의 Pod/Node 축소 시간을 측정한다.

- User: `GET /v1/user`, 30%
- Product: `GET /v1/product`, 30%
- Stress: `POST /v1/stress`, 40%
- 요청 timeout: 5초
- 앱별 독립 arrival-rate scenario/VU pool
- **VU 산정(API별 독립)**: `RequiredVU_i = ceil(rate_i × L_est_i × 1.3)`, `maxVUs_i = ceil(RequiredVU_i × 1.4) + 5`. `L_est`는 steady 성공 p95(샘플≥100) → 성공 p95(샘플≥20) → 1.5s fallback 순. Stress가 느리면 Stress VU가 훨씬 많아진다.
- **Global VU cap**: `min(192, logicalCPU × 8)`(읽기 실패 시 128). 요구 합이 cap 초과 시 비례 축소 + scenario당 최소 2 VU 보장.
- **Saturation 판정**: `generatedRatio ≥ 0.95 ∧ droppedPct ≤ 2%`가 아니면 LOAD_GENERATOR_LIMIT. 후보당 VU Retry는 최대 1회, Retry VU는 기존보다 낮추지 않는다(유지 또는 증가).
- **VU Retry warmup**: `clamp(5, 10, duration×0.05)`초를 0→저부하 선형 ramp로 추가하고, warmup 구간 요청은 본 평가 metric에서 제외한다(steady_* metric이 source of truth). VU 증가 <20% & retry gap <10s면 warmup 생략.
- Retry 후에도 saturation이면 추가 retry 없이 `Eligible` 유지 + G/R 감점 (Kubernetes 설정 변경으로 오판하지 않음)
- timeout WARN은 콘솔에 숨기지만 실패 상세(첫 5건)는 결과 디렉토리의 `*-k6.log` 파일에 기록하고, 실패 유형(`timeout`/`500`/`502`/`403` 등)은 `failure_breakdown` 카운터로 집계해 앱별 요약 라인에 표시한다. timeout은 status=0(클라이언트 5초 timeout), 5xx는 서버 오류, 4xx는 WAF/요청 형식으로 구분할 수 있다.
- `DIAGNOSE_FAILURES` 환경변수로 실패 상세 로그 건수를 조절한다(기본 5, 0이면 끔).

## 순차 탐색

### Minimum

- CPU request 시작값: User `150m`, Product `75m`, Stress `925m` (절대 하한 `125m/50m/700m`)
- Memory request 시작값: User/Product `64Mi`, Stress `640Mi` (절대 하한 `64Mi/64Mi/128Mi`)
- CPU limit 시작값: User `500m`, Product `250m`, Stress `1400m`; Memory limit은 `128Mi/512Mi/1536Mi`
- HPA max 시작값: User `6`, Product `4`, Stress `2`
- 기존 limit은 안정성을 위해 가능한 유지하되 Stress CPU limit은 request 2배 이하로 제한

### Balanced

Minimum 결과에서 측정 신뢰도와 병목을 분류한다. 앱별로 Memory limit, CPU limit, HPA max 중 원인에 대응하는 하나만 변경한다. Pending, startup delay, application latency 또는 metric 누락은 자동 resource 변경을 하지 않는다.

### CalculatedFinal

Balanced를 다시 측정하고 동일한 원인 기반 단일 변경을 한 번 더 적용한다. 동일 설정을 기본 2회 검증해 모든 실행이 reliable, timeout 0, p95/p99 SLO와 15% latency headroom을 만족하고 p95 변동이 20% 이하일 때만 최종 후보가 된다.

## CPU/HPA 정책

| App | CPU request 시작/최소 | HPA min | HPA max 시작값 |
|---|---:|---:|---:|
| user | 150m / 125m | 1 | 6 |
| product | 75m / 50m | 1 | 4 |
| stress | 925m / 700m | 1 | 2 |

HPA ceiling과 CPU pressure가 동시에 관측되면 `MaxAutoReplicas`까지 단계적으로 증가한다. Stress는 2 Pod 후보에서 시작하며 User/Product가 안정적이고 증설의 실제 점수 이득 가능성이 있을 때만 2→4처럼 확장 후보를 측정한다. CPU request와 HPA target은 같은 제어 루프에서 변경하지 않는다.

Stress CPU limit은 항상 request 이상, request 2배 이하다.

```text
scaleUp:   User Max/stabilization 0초, Stress Max/30초, Product Min/30초 (Percent 50/30초, Pods 2/30초)
scaleDown: stabilization 30초, Max(Percent 100/15초, Pods 4/15초)
```

## Idle 1-Node 보정

실제 Ready Managed Node의 instance type과 allocatable CPU/Memory/Pod 수를 읽고, kube-system/DaemonSet request를 제외한 가용량에 세 앱의 1 Pod가 들어가야 한다. 초과 시 CPU와 Memory를 `Stress → Product → User` 순서로 조정하며 CPU 하한 `125m/50m/700m`, Memory 하한 `64Mi/64Mi/128Mi`를 유지한다. Idle 보정은 HPA max를 변경하지 않는다.

Managed Node와 Karpenter NodePool의 instance type은 정확히 같아야 한다. Karpenter Node에는 앱 확장 전용 taint를 적용하고 세 앱에만 toleration을 추가한다. 최종 적용 시 consolidation을 `WhenEmptyOrUnderutilized/30s`로 바꿔 남은 앱 Pod를 자연스럽게 Managed Node로 재배치하며 최대 45초간 실제 1-Node 수렴을 관찰한다. 강제 drain은 하지 않는다. 실행 실패 또는 `-NoApply`에서는 기존 정책을 복구한다.

## 프로필 전환

1. 세 HPA를 임시 `1..1`로 고정한다.
2. 세 Deployment를 각각 1 Pod로 축소한다.
3. Managed Node는 유지한다.
4. Karpenter Node만 cordon/drain/delete한다.
5. Karpenter Ready Node 0대와 Managed 1 Node의 세 Deployment Available을 확인한다.
6. 다음 resources/HPA를 적용하고 부하를 실행한다.

Karpenter 상한과 scale-in 진단에는 `ReadyNodes`를 사용한다. 비용 점수와 후보 동점 비교에는 `TotalReadyNodes`, `PeakTotalReadyNodes`, `TotalNodeSeconds`를 사용해 Managed를 포함한 실제 EC2 전체를 계산한다.

## CalculatedFinal 적용과 QualityScore

최종 선택은 `CompetitionScore`나 기존 `HardFailure`가 아니라 실제 측정값으로 계산한 품질을 사용한다.

```text
Q(api) = min(1, (SLO / 성공 p95)^1.5)            (성공 응답 latency만 사용)
Q      = 0.6 * min(Qi) + 0.4 * geometricMean(Qi)  (worst-aware)
L(api) = min(1, 성공 p95 / 성공 p99)
L      = min_i L_i                                 (p99/p95=1.5 → 0.67)
T      = exp(-7 * worst timeout/error rate)        (0%→1.00, 10%→0.50, 30%→0.12)
G      = min(1, min_i generated_i / 0.90)          (90% 이상 정상)
R      = exp(-5 * worst dropped rate) * completeness
Score  = 100 * Q^0.30 * L^0.20 * T^0.25 * G^0.15 * R^0.10
```

가중치는 `$QualityWeights` 코드 상수로 분리했으며 합이 1인지 startup에서 검증한다. timeout ceiling(5001ms)은 절대 성공 latency로 쓰지 않는다. 성공 응답 p95/p99가 없으면(timeout 100% 등) Q는 0 기반으로 붕괴하고 L은 보수적 `0.80` fallback을 쓰며 `MeasurementIncomplete=True`로 남긴다. 필수 metric(성공 p95, generated, timeout) 누락은 R completeness `0.50`, optional(p99, dropped) 누락은 `0.92`다. `ScoreEpsilon=1e-6`은 ln(0) 방지용 내부 계산에만 사용하고 표시값은 실제 항을 쓴다. 같은 config의 base/verification은 성공 p95 median, 성공 p99 worst, timeout worst, generated minimum, dropped worst로 집계한다. runtime 때문에 verification을 실행하지 못한 것은 `NOT_EXECUTED_RUNTIME_BUDGET`이며 실패 run에 포함하지 않는다.

실제 적용 불가 상태인 rollout/apply 실패, 손상된 config, CrashLoopBackOff, 2회 이상 OOMKilled, 지속 NotReady, 파싱 불가능 측정만 `Eligible=False`다. SLO 실패, timeout, LOAD_GENERATOR_LIMIT, throttling, HPA ceiling과 startup delay는 raw 품질 penalty로 남고 후보에서 제거되지 않는다.

Eligible 후보 중 최고 QualityScore를 찾고, near-best는 `max(Best - 3, Best * 0.95)` 이상만 인정한다. near-best 안에서만 `NodeSec → CPU request → Memory request → Nodes → CompetitionScore(참고)` 순으로 비용을 비교한다. 절대 3점만 쓰면 낮은 점수 영역에서 모든 후보가 비용 경쟁에 들어가는 문제가 있어 relative 항이 함께 막는다. 비용은 품질 차이를 절대 역전시키지 않는다. 모두 저품질이어도 Eligible 후보가 하나 있으면 반드시 선택하며, 전부 ineligible일 때만 원래 설정을 유지한다. 측정하지 않은 CalculatedFinal은 점수표에 `NOT_MEASURED`로 표시하고 선택하지 않는다.

maxReplicas 하한은 user=6, product=4, stress=2다. Stress를 완전히 제거하지는 않지만, 반복 평가에서 max=4도 성공 0건이었던 만큼 2 Pod 저비용 후보를 먼저 측정하고 증설이 실제 총점을 높일 때만 더 큰 후보를 선택한다.

Stress 확장은 User/Product의 `SLOPass`, `LoadPass`, `AvailabilityPass`를 보호 조건으로 사용한다. 둘 중 하나라도 실패하면 Stress HPA/CPU 증액을 보류한다. 둘 다 통과하고 latency headroom도 있으면 Stress HPA를 최대 2배로 확장하며, SLO만 통과한 상태에서는 `+2 Pod`로 제한한다. User는 200ms tail latency를 보호하기 위해 HPA target 40%, scale-up `Max`, stabilization 0초를 사용한다. Product는 불필요한 노드 급증을 막기 위해 `Min`을 유지한다.

앱의 관측 처리 무게는 `stress > user > product`로 사용한다. SLO 보호는 `user > product > stress`, HPA 여유분 축소는 `product → user → stress`, Idle 1-Node request 축소는 `stress → product → user` 순서다. 따라서 무거운 Stress의 확장 가능성은 보존하되 request 여유분은 먼저 회수하고, User 성능은 가장 마지막까지 보호한다.

대회 API 점수는 로드 처리율과 SLO 시간 이내 응답률 각각에 누적 구간 점수를 적용한다. `90/87.5/85/82.5/80/70/50/30%`를 넘을 때마다 0.5점씩 받아 항목당 최대 4점이다. 따라서 57.59%는 1점, 79.1%는 1.5점, 90% 이상은 4점이다. 이 점수는 콘솔 참고용이며 최종 후보의 source of truth가 아니다. 생성률 metric 일부가 누락되면 0%나 100%로 보간하지 않고 `null`로 기록한다.

측정 재시도 결과는 실제 measurement 배열로 평탄화한다. 중첩 `List<object>`, `Attempts`, `Result` wrapper가 들어와도 컨테이너 자체를 후보로 점수화하지 않는다. kubectl mutation 성공 원문은 숨기고 Tune 단계 요약과 실패 메시지만 출력한다.

기본 콘솔 출력은 compact 모드다. 최종 후보·runtime·Idle/Cooldown·앱 설정·대회 점수·결과 파일만 한 번 출력하며 rollout 완료, 원본/중간 config, 전체 tie-breaker 근거는 숨긴다. 전체 진단 로그가 필요할 때만 `./tools/tune.ps1 -DetailedOutput`을 사용한다.

점수표 아래에는 튜너가 직접 측정한 `TUNING TOTAL: x/36`만 출력한다.

```text
finalConfig = highest-grade candidate, then lexicographically best candidate
Apply-Resources finalConfig
Apply-Hpa finalConfig
Scale apps to one
Read back Deployment/HPA and compare with selected finalConfig
```

적용 후 Deployment/HPA를 다시 읽어 CPU/Memory request·limit과 HPA min·max·target을 검증한다. `-NoApply`는 결과만 저장하고 원래 설정을 복구한다.

## 결과

기본 결과 경로는 `%TEMP%\wsi-k6-<PID>`다.

- `*-k6.json`: 프로필별 k6 summary
- `*-metrics.csv`: Kubernetes 메트릭
- `tuning-summary.csv`: 세 프로필 비교, Node-seconds, cooldown 축소 시간
- `calculated-final.json`: CalculatedFinal 설정, 검증, 점수, Idle/cooldown 결과

필요 도구는 `aws`, `kubectl`, `k6`, `curl.exe`다.

전체 EKS 실행 없이 알고리즘만 검증하거나 기존 결과를 재생할 수 있다.

```powershell
# 수학 self-test + 16개 이상의 mock selection 시나리오
.\tools\tune\test-algorithm.ps1

# 기존 tuning-summary.csv를 사용하며 Kubernetes/EKS에는 접속하지 않음
.\tools\tune\replay-selection.ps1 -ResultDir 'C:\Users\competitor\AppData\Local\Temp\wsi-k6-24176'

# 앱별 집계와 selection 객체까지 확인
.\tools\tune\replay-selection.ps1 -ResultDir 'C:\path\to\result' -DebugSelection
```

Replay 스크립트는 별도의 후보 선택 공식을 구현하지 않는다. 저장 CSV를 측정 객체로 변환한 뒤 `tune.ps1`의 `Select-QualityCandidate`, `Write-FinalScoreboard`, `Write-FinalSelection`, `Write-CandidateAppDetails` 함수 정의를 그대로 로드해 호출한다. 기본 출력에는 PowerShell selection 객체를 내보내지 않는다.

# Stress 단일 요청 진단 (풀런 전)

Stress가 201이 0건인 원인이 "요청 형식"인지 "서버 용량"인지 가장 빠르게 가르는 방법이다. EKS/k6 풀런을 돌리지 않고 단일 POST의 status와 실제 응답시간을 확인한다.

```powershell
.\tools\tune\diagnose-stress.ps1 -Endpoint 'https://<cloudfront-domain>' -Requests 3
```

- 전부 201 + 1초 미만 → k6/부하 조건(동시성·ramp) 문제를 의심
- 5초 이상·timeout·500/502/504 → Stress 애플리케이션/리소스 문제 (request/limit/HPA max 점검)
- 403 → WAF/요청 형식 문제
