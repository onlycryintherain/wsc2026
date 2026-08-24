# 20-minute measured tuner

`tools/tune.ps1`은 `user`, `product`, `stress`를 현재 live 설정 그대로 BASE 측정한 후, 가장 명확한 병목 하나만 one-delta candidate로 검증하는 production tuner입니다.

```powershell
pwsh ./tools/tune.ps1
```

## Production lifecycle

```text
immutable live snapshot
→ BASE: Default / Default-spike2 / Ramp
→ local HTTP result + Kubernetes samples
→ validity/infrastructure check
→ one recommendation
→ Copy(BEST) + one logical delta
→ exact apply and live verification
→ fresh candidate measurement
→ KEEP or exact BEST rollback
→ remaining-time check and repeat
→ measured BEST apply
→ optional FINAL_FRESH
→ final regression rollback
→ lifecycle.json
```

BASE 전에 Deployment replica/resources, HPA, behavior, topology, PDB, NodePool, Karpenter를 변경하지 않습니다. Production candidate가 변경할 수 있는 축은 다음뿐입니다.

- `HPA_MAX`
- `HPA_TARGET`
- `MIN_UP`
- `MIN_DOWN`
- `REQUEST_CONTROL_POINT` (`requests.cpu` + absolute HPA trigger compensation)

Placement, topology, PDB, NodePool은 변경하지 않습니다. 관련 장애는 `PDB_CONSTRAINT`, `SCHEDULER_PLACEMENT`, `NODE_CPU_CAPACITY`, `NODE_MEMORY_CAPACITY`, `CNI_UNRESOLVED`로 측정을 중단합니다.

## Recommendation order

```text
1. measurement validity
2. infrastructure validity
3. performance recovery
   A. HPA ceiling
   B. sustained HPA scale-up lag
   C. early burst failure followed by late recovery → min +1
4. stable-performance cost work
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

Script parameter binding 직후 다음 absolute deadline을 한 번만 생성합니다.

```powershell
$script:StartTime = [datetime]::UtcNow
$script:HardDeadline = $script:StartTime.AddMinutes(20)
```

기본 budget:

```text
profile:                40s × 3
measurement budget:    (40 + sample overrun 10)s × 3 = 150s
candidate apply:        45s
possible rollback:      45s
candidates:             최대 3
shutdown reserve:       120s
save reserve:           15s
worst-case planned:     1155s (19m15s)
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
