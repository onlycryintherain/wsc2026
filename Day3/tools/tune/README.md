# 20-minute measured tuner

`tools/tune.ps1`은 `user`, `product`, `stress`를 현재 live 설정 그대로 BASE 측정한 후, 가장 명확한 병목 하나만 one-delta candidate로 검증하는 production tuner입니다.

```powershell
pwsh ./tools/tune.ps1
```

## Production lifecycle

```text
immutable live snapshot
→ BASE: 240초 Python ramping-arrival-rate
→ steady HTTP result + 전체 구간 Kubernetes samples
→ validity/infrastructure check
→ one recommendation
→ Copy(BEST) + one logical delta
→ exact apply and live verification
→ fresh candidate measurement
→ KEEP or exact BEST rollback
→ measured BEST apply
→ optional FINAL_FRESH
→ final regression rollback
→ lifecycle.json
```

BASE 전에 Deployment replica/resources, HPA, behavior, topology, PDB, NodePool, Karpenter를 변경하지 않습니다. Resource candidate/rollback 시에는 stale high-load Pod와 불가능한 rolling surge를 제거하기 위해 대상 Deployment를 HPA min으로 축소한 뒤 resource template을 적용합니다. Candidate/FINAL 직전에는 세 앱을 measured HPA min으로 맞춰 같은 시작점에서 측정하고, 정상·오류 종료 때도 min으로 정리합니다. 이 replica 축소는 candidate 비교 축이 아니며 HPA spec은 measured config 그대로 유지됩니다. Production candidate가 변경할 수 있는 축은 다음뿐입니다.

- `HPA_MAX`
- `HPA_TARGET`
- `MIN_UP`
- `MIN_DOWN`
- `REQUEST_CONTROL_POINT` (`requests.cpu` + absolute HPA trigger compensation)

Placement, topology, PDB, NodePool은 변경하지 않습니다. `Insufficient CPU/memory`와 `NODEPOOL_LIMIT`은 중단 조건이 아니라 resource/HPA candidate를 만드는 병목 evidence입니다. CNI/PDB 이벤트는 **최신 sample에 실제로 남아 있는 동일 Pod**와 연관될 때만 unresolved로 판정합니다. 이미 Running으로 복구됐거나 현재 Pending 원인이 NodePool CPU인 경우 과거 `FailedCreatePodSandBox` 이벤트로 중단하지 않습니다. 미해결 CNI, PDB constraint, metrics 부재, local generator limit처럼 측정 자체가 무효인 경우에만 search/FINAL을 중단합니다.

## Recommendation order

```text
1. measurement validity(CNI/PDB/metrics/generator)
2. performance recovery
   A. NodePool limit + app Pending → bounded request -10% + absolute HPA trigger 보존
   B. HPA ceiling
   C. sustained HPA scale-up lag
   D. early burst failure followed by late recovery → min +1
3. stable-performance cost work
   A. min -1 only when calculated node floor can fall
   B. CPU request right-size with HPA absolute trigger preserved
```

Candidate는 항상 immutable measured BEST에서 복사합니다. REJECT 시 BEST를 적용한 후 live snapshot을 다시 읽으며 차이가 있으면 `ROLLBACK_DRIFT`로 종료합니다.

## Local Python load generator

`tools/tune/loadgen.py`는 Python 3.14와 사전 설치된 `aiohttp`를 사용합니다. 인터넷 설치는 하지 않습니다.

```powershell
py -3.14 -c "import aiohttp"
```

구조:

- single asyncio event loop
- shared `ClientSession`
- HTTP keep-alive
- bounded worker pool: 최대 64
- bounded connector: 최대 96
- bounded queue: 최대 256
- fixed scheduler tasks: phase당 app 수만큼
- k6 `ramping-arrival-rate`와 같은 linear start→target rate
- 20s warmup → 32s×5 ramp → 30s steady → 30s cooldown
- steady phase만 availability/performance 판정에 사용
- request timeout
- graceful process cleanup
- atomic JSON output

Queue가 가득 차면 task/backlog를 추가하지 않고 `dropped`를 증가시킵니다. Queue drop 또는 지속 scheduler lag가 있으면 `generator_limited=true`이며 PowerShell은 application candidate를 생성하지 않습니다. HTTP timeout 자체는 application performance evidence입니다.

JSON에는 aggregate/app/phase별 다음 evidence가 포함됩니다.

- scheduled/sent/completed/success/failure/timeout/dropped
- success rate, SLO success rate
- p50/p90/p95/p99
- generator limit reason
- workers/connections/queue/max active

## Kubernetes sample schema

5~10초 간격으로 다음을 수집합니다.

- HPA current/desired/min/max/current CPU/target CPU
- app Ready/Pending/restart delta
- Pod CPU total/per pod
- Pod memory total/per pod
- Ready node count
- allocatable CPU/memory
- all scheduled Pod requested CPU/memory
- app requested CPU/memory
- Pending reason
- FailedScheduling/Insufficient CPU/Insufficient memory/CNI/PDB evidence

## 20-minute deadline

20분은 목표 실행시간이나 최소 실행시간이 아니라 **hard maximum**입니다. 안전한 candidate가 없거나 terminal infrastructure/generator evidence가 있으면 더 일찍 종료합니다. Script parameter binding 직후 다음 absolute deadline을 한 번만 생성합니다.

```powershell
$script:StartTime = [datetime]::UtcNow
$script:HardDeadline = $script:StartTime.AddMinutes(20)
```

기본 budget:

```text
BASE measurement:       240s + sample overrun 10s = 250s
candidate apply:         120s
candidate measurement:  280s (fresh-start prep 30s 포함)
possible rollback:       120s
FINAL measurement:      280s (fresh-start prep 30s 포함)
candidate:               최대 1개
shutdown reserve:        120s
save reserve:            15s
worst-case planned:      1185s (19m45s)
```

Candidate 시작 전 다음을 비교합니다.

```text
remaining >= apply + measurement + rollback + FINAL + shutdown + save
```

부족하면 `NO_TIME_FOR_SAFE_CANDIDATE`로 search를 종료합니다. 모든 kubectl wait/profile/rollback은 같은 deadline을 사용합니다.

## Validation

실제 20분 EKS run 없이 다음만 실행합니다.

```powershell
pwsh -NoProfile -NonInteractive -File tools/tune.ps1 -SelfTestOnly
py -3.14 -m py_compile tools/tune/loadgen.py
py -3.14 -m unittest discover -s tools/tune -p "test_*.py" -v
```

Python localhost 테스트는 정상/500/timeout과 강제 queue overflow를 검증합니다. Overflow test는 workers/connections/queue를 각각 2로 제한하고 느린 mock server에 높은 RPS를 보내 `dropped>0`, `generator_limited=true`, `QUEUE_FULL`, `max_active<=2`를 확인합니다.
