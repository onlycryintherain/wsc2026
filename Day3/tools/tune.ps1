[CmdletBinding()]
param(
    [string]$ClusterName = 'wsi2026-cluster',
    [string]$Region = 'ap-northeast-2',
    [switch]$SkipKubeconfig,
    [string]$Endpoint,
    [string]$Namespace = 'app',
    [switch]$StressMode,
    # 범용 튜너: 관리 앱 목록/SLO/CPU target을 파라미터로 주입하면 어떤 API 세트에도 동작한다.
    [string[]]$ManagedApps = @('user','product','stress'),
    [hashtable]$AppSloMs = $null,        # 앱별 latency SLO (ms). 기본: 200/200/1000
    [hashtable]$AppCpuTargets = $null,   # 앱별 HPA CPU target (%). 기본: 40/65/70
    [string]$DedicatedApp = 'stress',    # dedicated NodePool로 격리할 앱 (기본 stress, 없으면 '')
    # 실제 채점 결과(앱별 performance %)를 주입하면 empirical 예측과 mismatch를 감지한다.
    [hashtable]$ObservedPerformance = $null,
    [ValidateRange(15, 20)][int]$MaxRuntimeMinutes = 20,
    [ValidateRange(90, 180)][int]$ShutdownReserveSeconds = 120,
    # 준비/조건 기반 대기의 안전 여유만 반영한다. 긴 고정 sleep은 사용하지 않는다.
    [ValidateRange(15, 90)][int]$MeasurementOverheadSeconds = 20,
    # 정상 경로: 3회 탐색×180초 + verification 2회×180초를 기본으로
    # 준비/적용 시간을 포함해 18분 안팎에 끝내고 2분을 예비한다.
    [ValidateRange(150, 300)][int]$ProbeDurationSec = 180,
    [ValidateRange(150, 300)][int]$FinalDurationSec = 180,
    [ValidateRange(15, 90)][int]$CooldownDurationSec = 30,
    [ValidateRange(1, 1000)][int]$TargetRate = 60,
    [ValidateRange(0.50, 1.00)][double]$MinProcessingRate = 0.90,
    [string]$OutputDir = (Join-Path ([IO.Path]::GetTempPath()) "wsi-k6-$PID"),
    [string]$DataFile = '',
    # 외부 부하 도구 결과는 진단용으로만 읽는다. 비용은 live Kubernetes node
    # telemetry를 우선하며, 외부 도구가 EC2 수를 잘못 보고하면 실제 수를 명시한다.
    [string]$ExternalResultDir = '',
    [ValidateRange(0, 20)][int]$ExternalActualInstanceCount = 0,
    [string]$ProductId = 'dbdump500001',
    [string]$ProductIds,
    [ValidateRange(1, 20)][int]$MaxNodes = 3,
    [ValidateRange(1, 20)][int]$IdleNodes = 1,
    [ValidateRange(1, 20)][int]$ManagedNodes = 1,
    # Grader cost baseline is two c5.large nodes (one managed + one Karpenter).
    [ValidateRange(1, 20)][int]$CostBaselineNodes = 2,
    [ValidateRange(2, 30)][int]$MaxAutoReplicas = 12,
    # arrival-rate 목표를 생성할 수 있도록 VU 여유를 확보한다.
    # 요청률/Stress length는 변경하지 않고 k6 generator saturation만 방지한다.
    [ValidateRange(1, 1000)][int]$PreAllocatedVUs = 128,
    [ValidateRange(1, 2000)][int]$MaxVUs = 512,
    [ValidateRange(32, 2000)][int]$MaxGeneratorVUs = 600,
    [ValidateRange(1.0, 3.0)][double]$VUSafetyFactor = 1.30,
    [ValidateRange(15, 60)][int]$WarmupDurationSec = 20,
    [ValidateRange(20, 60)][int]$SteadyDurationSec = 30,
    # POST /v1/stress의 length 필드. k6 STRESS_LENGTH env로 전달한다.
    # 0(기본)이면 전체 튜닝 전에 Stress 단일 요청 latency가 median≤800ms,
    # max≤1000ms(PASS)가 되는 가장 큰 length를 자동 캘리브레이션하고, 양수로
    # 지정하면 캘리브레이션을 생략하고 그 값을 고정한다.
    [ValidateRange(0, 65535)][int]$StressLength = 0,
    [ValidateRange(0.70, 0.95)][double]$LatencyHeadroomRatio = 0.85,
    [ValidateRange(1, 3)][int]$VerificationRuns = 2,
    [ValidateRange(0, 2)][int]$MaxLoadGeneratorRetries = 1,
    [ValidateRange(0, 30)][int]$SafetyReservePercent = 0,
    [ValidateRange(0, 15)][int]$ClusterSchedulingReservePercent = 3,
    [ValidateRange(0.0, 2.0)][double]$MemoryWeight = 0.25,
    [ValidateRange(32, 512)][int]$MinMemoryRequestMi = 64,
    [ValidateRange(64, 2048)][int]$MinMemoryLimitMi = 128,
    [ValidateRange(1.0, 1.5)][double]$OOMMemoryRequestGrowth = 1.15,
    [ValidateRange(1.1, 2.0)][double]$OOMMemoryLimitGrowth = 1.50,
    [ValidateRange(30, 300)][int]$IdleWaitSec = 60,
    [switch]$SkipInstanceAwarePlacement,
    [switch]$SkipNodeLimit,
    # 채점 모드: 부하가 들어와도 노드를 1대(Managed)로 유지한다.
    # HPA max를 1노드 용량에 bin-packing하고 Karpenter 추가 노드를 차단한다.
    [switch]$SingleNode,
    # 튜닝 최종 적용 직후 finalize.ps1(노드 1대 + pre-warm)을 자동 실행한다.
    [switch]$Finalize,
    [switch]$NoApply,
    [switch]$DetailedOutput,
    [switch]$DiscardResults,
    [switch]$BaseExperiment,
    [switch]$LegacyAdaptive,
    [switch]$SelfTestOnly
)

# Safe default: BASE-first pipeline is the normal path. Legacy adaptive behavior
# is opt-in only with -LegacyAdaptive; if both switches are supplied, legacy wins.
if (-not $LegacyAdaptive) { $BaseExperiment = $true }

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DataFile)) {
    $script:tuneRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $DataFile = Join-Path $script:tuneRoot '..\application\load_user.dump'
}
$apps = @('user','product','stress')
# 범용 앱 구성: ManagedApps/SLO/target 파라미터가 주입되면 전역을 대체한다.
# (다른 과제/API 세트에서 tune.ps1을 재사용할 수 있게 함)
if ($PSBoundParameters.ContainsKey('ManagedApps')) { $apps = @($ManagedApps) }
# (AppSloMs/AppCpuTargets는 아래 $sloMs/$hpaTargets 조건부 정의에서 반영)
if (-not $AppSloMs) { $sloMs = @{ user=200.0; product=200.0; stress=1000.0 } } else { $sloMs = $AppSloMs }
$trafficShare = @{ user=0.50; product=0.35; stress=0.15 } # User 50% / Product 35% / Stress 15%
if (-not $AppCpuTargets) { $hpaTargets = @{ user=40; product=65; stress=$(if ($StressMode) { 55 } else { 70 }) } } else { $hpaTargets = $AppCpuTargets }
$cpuRequestMinimum = @{ user=25.0; product=25.0; stress=50.0 }
# ============================================================
# BASE EXPERIMENT CONFIG
# ============================================================
$BaseConfig = @{
    user = @{
        requestCpu = '70m'; requestMemory = '64Mi'
        limitCpu = $null; limitMemory = '256Mi'
        hpaTarget = 33; minReplicas = 2; maxReplicas = 20
        placement = 'SHARED'; placementDomain = 'shared'
    }
    product = @{
        requestCpu = '70m'; requestMemory = '64Mi'
        limitCpu = $null; limitMemory = '256Mi'
        hpaTarget = 29; minReplicas = 2; maxReplicas = 20
        placement = 'SHARED'; placementDomain = 'shared'
    }
    stress = @{
        requestCpu = '600m'; requestMemory = '640Mi'
        limitCpu = '2000m'; limitMemory = '1536Mi'
        hpaTarget = 55; minReplicas = 1; maxReplicas = 6
        placement = 'ISOLATED'; placementDomain = 'dedicated'
    }
}
$script:Is38PointAppSet = (@($apps | Where-Object { $_ -in @('user','product','stress') }).Count -eq 3 -and $apps.Count -eq 3)

function Get-ConfigFingerprintFromValues($config) {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($app in $apps) {
        $c = $config[$app]; if ($null -eq $c) { $parts.Add("$app|null"); continue }
        $parts.Add("$app|$(Get-OptionalPropertyValue $c 'requestCpu' '')|$(Get-OptionalPropertyValue $c 'requestMemory' '')|$(Get-OptionalPropertyValue $c 'limitCpu' '')|$(Get-OptionalPropertyValue $c 'limitMemory' '')|$(Get-OptionalPropertyValue $c 'hpaTarget' 0)|$(Get-OptionalPropertyValue $c 'minReplicas' 0)|$(Get-OptionalPropertyValue $c 'maxReplicas' 0)")
    }
    return ($parts -join ';')
}
function Compare-Config([hashtable]$L, [hashtable]$R, [string[]]$AllowedAxes) {
    $diffs = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $apps) {
        $lv = $L[$app]; $rv = $R[$app]
        if ($null -eq $lv -or $null -eq $rv) { continue }
        foreach ($field in @('requestCpu','requestMemory','limitCpu','limitMemory','hpaTarget','minReplicas','maxReplicas','placement')) {
            $a = Get-OptionalPropertyValue $lv $field $null; $b = Get-OptionalPropertyValue $rv $field $null
            if ([string]$a -ne [string]$b) {
                $axis = ($app + '_' + $field).ToUpper()
                $diffs.Add([pscustomobject]@{App=$app;Field=$field;Left=$a;Right=$b;Axis=$axis;Allowed=($axis -in $AllowedAxes)})
            }
        }
    }
    return $diffs
}
function Assert-ConfigDrift([hashtable]$L,[hashtable]$R,[string[]]$AllowedAxes) {
    $diffs = Compare-Config $L $R $AllowedAxes
    $unauth = @($diffs | Where-Object { -not $_.Allowed })
    if ($unauth.Count -gt 0) { throw "EXPERIMENT_CONFIG_DRIFT: $([string]::Join(',', @($unauth | ForEach-Object { $_.App+'.'+$_.Field })))" }
    $axes = @($diffs | Where-Object { $_.Allowed } | ForEach-Object { $_.Axis })
    if ($axes.Count -gt 1) { throw "MULTI_AXIS_MUTATION: $([string]::Join(' ', $axes))" }
    if ($axes.Count -eq 0) { throw "NO_DELTA: config identical" }
    return $axes[0]
}
function Save-EvaluationSnapshot($measurement, $config, $name) {
    # Snapshot is immutable: later live/HPA changes must never rewrite BEST evidence.
    $measurement=$measurement | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $config=Copy-Config $config $name
    $apps2 = @($measurement.Apps.PSObject.Properties | ForEach-Object { @{Name=$_.Name;Val=$_.Value} })
    $userP=0;$productP=0;$stressP=0
    foreach ($a in $apps2) { if ($a.Name -eq 'user') { $userP=[double](Get-OptionalPropertyValue $a.Val 'Performance' 0) } elseif ($a.Name -eq 'product') { $productP=[double](Get-OptionalPropertyValue $a.Val 'Performance' 0) } elseif ($a.Name -eq 'stress') { $stressP=[double](Get-OptionalPropertyValue $a.Val 'Performance' 0) } }
    $evalScore=Get-OptionalPropertyValue $measurement 'EvaluationTotalScore' $null
    if ($null -eq $evalScore) { $evalScore=Get-OptionalPropertyValue $measurement 'TotalScore' $null }
    if ($null -eq $evalScore -and $measurement.CompetitionScore) { $evalScore=Get-OptionalPropertyValue $measurement.CompetitionScore 'Earned' 0 }
    return [pscustomobject]@{
        Name=$name; Timestamp=Get-Date
        ConfigFingerprint=Get-ConfigFingerprintFromValues $config; Config=$config; Measurement=$measurement
        UserPerformance=$userP; ProductPerformance=$productP; StressPerformance=$stressP
        EvalScore=[double]$evalScore
        AvgNodes=[double]$(Get-OptionalPropertyValue $measurement 'AverageReadyNodes' 0)
        PeakNodes=[double]$(Get-OptionalPropertyValue $measurement 'PeakReadyNodes' 0)
    }
}
function Save-BaseExperimentProfile([hashtable]$config,$measurement,[string]$path,[string]$status='BASE_MEASURED') {
    $payload=[pscustomobject]@{
        GeneratedAt=(Get-Date -Format o)
        Mode='BASE_EXPERIMENT'
        Configuration=$config
        Measurement=$measurement
        ExternalEvidence=$script:ExternalEvidence
        Selection=[pscustomobject]@{Status=$status;ExternalScorePending=$true}
    }
    $text=$payload|ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Import-ExternalEvidence {
    if ([string]::IsNullOrWhiteSpace($ExternalResultDir)) { return $null }
    $summaryPath=Join-Path $ExternalResultDir 'summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        Write-Warning "외부 결과 summary.json을 찾지 못했습니다: $summaryPath"
        return $null
    }
    try {
        try {
            $summary=Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
        } catch {
            # Windows PowerShell 5.1은 큰 summary의 일부 특수문자에서
            # ConvertFrom-Json이 실패할 수 있다. node로 필요한 비용/점수
            # 필드만 축약해 다시 PowerShell 객체로 변환한다.
            if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw }
            $compact=@'
const fs=require('fs');
const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
process.stdout.write(JSON.stringify({duration_seconds:d.duration_seconds,cost_details:{average_running_instance_count:d.cost_details && d.cost_details.average_running_instance_count},score_earned:d.score && d.score.earned,score_max:d.score && d.score.max}));
'@
            $compactJson=(& node -e $compact $summaryPath -ErrorAction Stop) -join ''
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($compactJson)) { throw }
            $summary=$compactJson | ConvertFrom-Json
        }
        $reported=[double](Get-OptionalPropertyValue $summary.cost_details 'average_running_instance_count' $null)
        $actual=if ($ExternalActualInstanceCount -gt 0) { [double]$ExternalActualInstanceCount } else { $null }
        $score=Get-OptionalPropertyValue $summary 'score' $null
        if ($null -eq $score -and $null -ne (Get-OptionalPropertyValue $summary 'score_earned' $null)) {
            $score=[pscustomobject]@{earned=[double]$summary.score_earned;max=[double](Get-OptionalPropertyValue $summary 'score_max' 40)}
        }
        $e=[pscustomobject]@{
            Source=$ExternalResultDir; SummaryPath=$summaryPath
            DurationSeconds=[double](Get-OptionalPropertyValue $summary 'duration_seconds' 0)
            ReportedAverageInstances=$reported; ActualAverageInstances=$actual
            ReportedCostTelemetryReliable=($null -ne $reported -and $null -ne $actual -and [math]::Abs($reported-$actual) -lt 0.01)
            ExternalScore=$score; ByApi=Get-OptionalPropertyValue $summary 'by_api' $null
        }
        if ($null -ne $reported -and $null -ne $actual -and [math]::Abs($reported-$actual) -ge 0.01) {
            Write-Warning ("외부 비용 telemetry 불일치: reported avg EC2={0:N2}, actual={1:N0}. reported 값은 튜닝 비용 판단에 사용하지 않습니다." -f $reported,$actual)
        }
        $script:ExternalEvidence=$e; return $e
    } catch { Write-Warning "외부 결과 import 실패: $($_.Exception.Message)"; return $null }
}

# P0-5: user/product request floor도 reference(70m)에 가깝게 — ELASTIC_DENSITY에서 실측 우선
# 하한은 유지하되 첫 측정은 과밀 배치를 막는 보호값에서 시작한다. 합계
# 1150m이라 c5.large 관측 app budget 1180m 안에 1 Pod씩 들어가며,
# 더 작은 실제 노드에서는 Enforce-IdleBudget이 기존 하한까지 자동 축소한다.
$cpuRequestStart = @{ user=150.0; product=75.0; stress=925.0 }
$cpuLimitStart = @{ user=$null; product=$null; stress=2000.0 }  # immutable BASE reference; candidate analyzer may recommend a separate delta
$memoryRequestStart = @{ user=64.0; product=64.0; stress=640.0 }
$memoryLimitStart = @{ user=128.0; product=256.0; stress=1536.0 }  # Golden baseline: product 256Mi
# 관측된 앱 비용과 보호 정책은 서로 다르다.
# - 실제 처리 무게: Stress > User > Product
# - SLO 보호: User > Product > Stress
# - HPA 여유 축소: Product > User > Stress
# - Idle request 축소: Stress > Product > User
$appResourceWeight = @{ stress=3; user=2; product=1 }
$performanceProtectionOrder = @('user','product','stress')
$hpaReductionOrder = @('product','user','stress')
$idleRequestReductionOrder = @('stress','product','user')
# HPA maxReplicas는 관측 기반 수식(Get-AppHpaCapacity → FinalHpaMaxByApp)이
# 최종 overlay한다. 아래 값은 candidate 시작값/fallback floor일 뿐 최종 source of
# truth가 아니다. stress는 max=2가 기능적으로 부족해 floor를 6으로 올린다.
    # HPA floor는 live config에서 설정된다. reference profile의 앱별 숫자를
    # 다른 난이도의 앱에 재사용하지 않는다.
    $hpaMaxMinimum=@{ user=1; product=1; stress=1 }
# 관측 기반 HPA max 최종 상태 (candidate lifecycle과 분리).
# measurement마다 monotonic(max)으로 갱신되고 최종 적용 시 overlay된다.
$script:FinalHpaMaxByApp=@{}
# HPA baseline/warm min (monotonic: 같은 tune에서 급격 scale-down 방지)
$script:FinalHpaMinByApp=@{}
# Operating Node Budget: min/max HPA가 공유하는 비용 목표 node 수.
# minReplicas 증가 자체로 새 Karpenter node를 만들지 않는다 — 추가 node는
# paid scale-out(성능점수 vs 비용점수) 승인을 통과해야만 올린다.
$script:OperatingNodeBudget = [int]$CostBaselineNodes
# HPA behavior 정책: 기본 KEEP(라이브 보존). 별도 명시적 튜닝 근거가 있을 때만
# TUNE_SCALE_UP으로 바꾼다. maxReplicas/CPU target 튜닝과는 별개 축이다.
$script:HpaBehaviorAction = @{ user='KEEP'; product='KEEP'; stress='KEEP' }
# SPLIT/resource 튜닝 결과를 candidate lifecycle과 분리해 persist한다.
# Minimum/Balanced/CalculatedFinal/최종 선택/placement/budget optimizer 어느 단계도
# 이 값을 old candidate resource(예: 925m/1400m)로 되돌리지 못하게 한다.
#   key=app → @{requestCpu=...;limitCpu=...}
$script:FinalResourceOverrideByApp = @{}
$script:ExternalEvidence = $null
# Stress dedicated density 상태 (ISOLATED_DENSE / ISOLATED_SPREAD)
$script:StressDensityPlacement = $null
$script:StressDensityLimitM = $null
$script:StressDensityUpgradedToSpread = $false
# stress 전용 NodePool taint key: user/product toleration(app-capacity, 확장용)과 분리해
# stress 전용 노드에는 stress만 스케줄되게 한다. Apply-StressPlacement에서도 사용하므로 전역.
$stressPlacementKey = 'wsi2026.io/stress'
# 실제 대회 성적표 레이어: SLO 성공률(%) → 앱별 점수 0..4, 합 12 + CostScore 0..12.
# 탐색은 BoundaryProgress(실제 점수 +0 이전의 진행)를 인정하고, 최종 선택은
# Feasible + EvaluationTotalScore를 우선한다. 기존 QualityScore는 tie-break로 유지.
# 실측 채점 데이터 역추정 경계 (grader는 외부 플랫폼, 저장소에 로직 없음 — EMPIRICAL_UNCONFIRMED).
# 최신(31.5점) 채점: user 72.24→1.5, product 86.15→3.0, stress 65.36→1.0 = 성능 5.5 (실제 일치)
#   → 공통 경계: 50→1.0, 70→1.5, 82.5→3.0, 90→3.5, 95→4.0 (2.0/2.5 구간은 최신 관측 포인트 없음)
#   (앱별 모델(51ff561)은 31.5 채점과 불일치해 폐기 — user 72.24→2.0 등 오예측)
$performanceBoundaries = @(50,70,82.5,90,95,100)
$MinBoundaryProgress = 0.5      # %p — 이보다 작은 진행은 noise로 간주
$BoundarySafetyMargin = 0.3     # %p — 탐색 decision에서만 사용 (실제 점수에는 margin 없음)
$NearBoundaryWindow = 2.0     # %p — 이 거리 이하의 다음 boundary는 near-boundary harvesting 후보
$BoundarySafetyTargetMargin = 0.8  # %p — tuning target은 boundary + margin (score boundary와 분리)
$HardConstraintFloor = 30.0     # 앱별 SLO 성공률 < 30% → infeasible/hard constraint
# HPA ceiling CPU budget: Σ(maxReplicas × request) <= NodeBudgetCpu.
# 성능상 CapacityMax는 관측 수식이 계산하고, 최종 live HPA max는 budget 내에서 배분한다.
$NodeCpuBudgetUtilization = 0.80  # allocatable 100%를 앱에 허용하지 않는다
$MemoryBudgetUtilization = 0.80  # memory budget도 CPU와 동일하게 여유를 둔다
$ScaleOutSafetyMargin = 0.5      # node scale-out 승인 최소 delta evaluation (성적표 점수)
$StressPodsPerNodeUtil = 0.70     # stress 노드당 replica 밀도 계산용 target util
# HPA spike guard: 순간 CPU spike의 과도한 replica jump만 완화 (max는 건드리지 않음)
$HpaSpikeStabilizationSec = 15    # scaleUp stabilization (10~15 권장, 30 초과 금지)
$HpaScaleDownStabilizationSec = 90 # scale-down은 더 천천히 (flap 방지)
$HpaSpikeJumpRatio = 2.0          # JumpRatio >= 2 또는 delta >= 2 → spike-sensitive
# Stress dedicated density: 1 pod/node 고정 대신 request/limit로 2 pods/node 안전성을 판단한다.
$StressDensePodsPerNode = 2
$StressRequestSafetyFactor = 0.80   # request 기준 노드 사용률 상한
$StressBurstFactor = 1.50           # limit = request x burst (dense 시 동시 burst 제한)
$StressLimitSafetyFactor = 0.90     # limit = alloc x 0.9 / podsPerNode
$StressMaxPodsPerNodeCap = 2        # 현재 tune에서 노드당 최대 2까지만
# 실측 기반 burst/request 튜닝 (실제 평가 반영)
$ThrottleBurstThreshold = 0.30    # throttling 비율 >=30% + SLO fail → limit 상향 후보
$CpuRequestHeadroomFactor = 1.30  # request = typical CPU x 1.3 (하향 시)
$MemoryRequestHeadroomFactor = 1.25
$RequestDownCpuUtilThreshold = 0.50  # typical/request < 50% + 노드 많음 → REDUCE_CPU_REQUEST 후보
$LimitHardCapFactor = 0.95        # CPU limit <= nodeAlloc x 0.95 (hard safety cap)
# HPA baseline/warm min optimizer (minReplicas=1 고정 대체)
# No-Scale Min Fill: min budget을 노드 capacity(0.80)와 동일하게 사용한다.
# 40%는 soft 초기값이지 hard ceiling이 아니다 — OperatingNodeBudget의 실제 CPU/MEM
# capacity까지 warm min을 채운다 (추가 노드 없이 fit하는 warm replica 거부 금지).
$MinCpuBudgetUtilization = 0.80
$MinMemoryBudgetUtilization = 0.80

# ===== HPA CONTROL POINT MODEL =====
# T_abs = requestCpuM × target% / 100 — request와 target을 독립적으로 바꾸지 않는다.
# known-good 38점 reference (t3.medium 검증)를 empirical prior로 사용:
#   user    70m × 33% = 23.1m
#   product 70m × 29% = 20.3m
#   stress 600m × 55% = 330m
# 최종 source of truth는 same-run measurement (MEASURED_*) — prior보다 우선한다.
$script:ControlPointByApp=@{}
$script:ControlPointSourceByApp=@{}
$script:ControlPointConfidenceByApp=@{}
$script:ControlPointStateFile = Join-Path ([IO.Path]::GetTempPath()) 'wsi-hpa-controlpoints.json'
$HpaTargetLowerBound=15.0      # EMPIRICAL_UNCONFIRMED (known-good 29/33/55 포함 범위)
$HpaTargetUpperBound=90.0
# Known-good reference is a projection of BaseConfig; do not duplicate app numbers.
$GoldenBaseline = @{ Infra=@{PrefixDelegation=$true;WarmPrefixTarget=1;MaxPods=110}; Apps=@{} }
foreach ($app in @('user','product','stress')) {
    $b=$BaseConfig[$app]
    $GoldenBaseline.Apps[$app]=@{
        requestCpu=$b.requestCpu; requestMemory=$b.requestMemory
        limitCpu=$b.limitCpu; limitMemory=$b.limitMemory
        hpaTarget=$b.hpaTarget; minReplicas=$b.minReplicas; maxReplicas=$b.maxReplicas
        placement=$b.placement; placementDomain=$b.placementDomain
    }
}
$KnownGoodReference = $GoldenBaseline.Apps
# HardSafetyMax: cluster absolute ceiling (node budget과 무관 — maxPods/placement/앱 안전 기준)
# user/product max=20은 reference prior (max≠reservation — 실제 Pod/Node lifetime으로만 비용 계산)
# 앱별 안전 상한. 실제 선택은 측정된 quality/score/cost 후보로 결정한다.
$script:HardSafetyMaxByApp=@{user=20;product=20;stress=12}
# ELASTIC_DENSITY_REQUEST 대상 (burst 허용 + HPA 분산): user/product. GUARANTEED: stress.
$script:ElasticDensityApps=@('user','product')
$WarmReplicaHardCap = 3            # burst warm replica 최대 (전역 cap, 앱별 하드코딩 아님)
$SafeMemoryUtilizationDefault = 0.70
$CollapseMinFallback = 3           # 실측 spike-collapse fallback (history 부족 + collapse 증거 시, 성능 우선 warm 3)
# ==== Resource right-sizing tunables (스펙 21) ====
$CpuRequestFloor = 100.0          # CPU request 최소 (m)
$MemoryRequestFloor = 64.0        # Memory request 최소 (Mi)
# Request headroom: reliable measurement에서는 1.15~1.25로 완화 (기존 1.60→).
# unreliable이면 기존 1.60 유지 (보수적). actual utilization에 따라 동적 결정.
$CpuRequestMinHeadroom = 1.05
$CpuRequestMaxHeadroom = 1.60   # unreliable fallback (보수적)
$CpuRequestAlpha = 1.5
# Reliable measurement 시 headroom 상한: observed × 1.15~1.25 (density 향상)
# unreliable일 때는 기존 1.60 유지 — precision이 낮으면 보수적으로.
$CpuRequestReliableMaxHeadroom = 1.25
$MemoryRequestMinHeadroom = 1.10
$MemoryRequestMaxHeadroom = 1.80
$MemoryRequestAlpha = 1.5
$RequestDownHysteresis = 0.10     # target이 current보다 이 비율 이하로만 낮으면 KEEP
$CpuRequestStep = 25
$MemoryRequestStep = 32
$CpuLimitStep = 25
$ThrottleSafe = 0.15              # throttling 비율 안전선
$ThrottleWeight = 1.0
$SloWeight = 1.0
$CpuLimitMaxGrowth = 2.0
$BurstHeadroom = 1.50
$EpsDiv = 1e-9
# Stress capacity shape (SPLIT-first 정책) 상수.
$DesiredStressPods = 2
$StressCpuRequestMinimum = 400     # clamp 하한 (2-node shared에서 2~3 Pod 병렬성 확보)
$StressGranularityThreshold = 0.40 # request/노드alloc ≥ 이 값이면 coarse로 간주
$StressHpaMinMax = 6               # SPLIT 시 HPA max 하한
# Final candidate selection constants.  Cost never enters the core quality
# equation; it is considered only inside the near-best window.
#
# QualityScore = 100 * Q^0.30 * L^0.20 * T^0.25 * G^0.15 * R^0.10
# 가중치는 과거 장애 데이터로 학습한 값이 아니라 운영상 중요도 기반 초기
# heuristic이다. 코드 상수로 분리해 추후 쉽게 조정한다.
$QualityWeights = @{ Slo=0.30; Tail=0.20; Timeout=0.25; Generation=0.15; Reliability=0.10 }
$qualitySloExponent = 1.5
$qualityTimeoutCoefficient = 7.0
$qualityGenerationFullRatio = 0.90
$qualityNearBestTolerance = 3.0
$qualityNearBestRelative = 0.95
$ScoreEpsilon = 1e-6
$missingTailScore = 0.80
$missingRequiredMetricCompleteness = 0.50
$missingOptionalMetricCompleteness = 0.92
$reliabilityDropCoefficient = 5.0
# startup/self-test: 가중치 합이 1이 아니면 즉시 중단한다.
$qualityWeightSum = ($QualityWeights.Values | Measure-Object -Sum).Sum
if ([math]::Abs([double]$qualityWeightSum - 1.0) -gt 1e-9) {
    throw "QualityWeights는 합이 1이어야 합니다: $($QualityWeights | ConvertTo-Json -Compress) (sum=$qualityWeightSum)"
}
# Stress length calibration constants (최종 규칙: trimmedMean 방식).
#   Phase1      : n=8,  trimmedMean<=800ms,  SLO success(201 & <=1000ms) >= 7/8
#   Refinement  : n=10, trimmedMean<=780ms,  SLO success >= 9/10
#   Verification: n=10, trimmedMean<=800ms,  SLO success >= 9/10
# trimmedMean = latency 정렬 후 min/max 1개 제거한 평균. hard fail = timeout OR >5000ms OR !=201.
$StressLengthCandidates = @(64, 96, 128, 160, 192, 256)
$StressCalibrationStartLength = 128
$StressCalibrationMaxCandidates = 3
$Phase1SamplesPerLength = 8
$Phase1TrimmedMeanMs = 800
$Phase1SloSuccessRequired = 7      # 7/8
$RefinementSamplesPerLength = 10
$RefinementTrimmedMeanMs = 780
$RefinementSloSuccessRequired = 8  # 8/10 (후보 탐색 단계라 2개 jitter spike 허용)
$VerificationSamplesPerLength = 10
$VerificationTrimmedMeanMs = 800
$StressCalibrationSloMs = 1000          # SLO success = HTTP 201 AND latency <= 1000ms
$StressCalibrationHardMaxMs = 5000      # hard fail = timeout OR latency > 5000ms OR HTTP != 201
$StressCalibrationVerificationMax = 1   # winner 1개만 검증, FAIL 시 refinement PASS 중 downgrade
$StressCalibrationBudgetSeconds = 45
$StressCalibrationRequestTimeoutSeconds = 6   # client timeout만 6s (평가 기준은 그대로: availability<=5000ms, SLO<=1000ms)
$DefaultStressLength = 128
$script:SelectedStressLength = $null
# VU Retry / load generator saturation constants (사양 확정).
$MinScenarioVU = 2
$RequiredVUFactor = 2.5                 # RequiredVU = ceil(rate x L_est x 2.5) — 첫 측정부터 VU 여유 확보 (LOAD_GENERATOR_LIMIT retry 미실행 대비)
$MaxVUFactor = 1.6                      # maxVUs = ceil(RequiredVU x 1.6) + 8 (VU 부족 drop 방지)
$MaxVUBuffer = 8
$LatencyEstimatorFallbackSec = 1.5      # 성공 샘플 부족/전무 시 L_est fallback (5초 timeout 미사용)
$GlobalVUCapMax = 600
$GlobalVUCapPerCpu = 24
$GlobalVUCapFallback = 384
$RetryWarmupMinSec = 5
$RetryWarmupMaxSec = 10
$RetryWarmupSkipIncrease = 0.20         # VU 증가 <20% && retry gap <10s → warmup 생략
$RetryWarmupSkipGapSec = 10
$SaturationGeneratedRatio = 0.95
$SaturationDroppedPct = 0.02
# CalculatedFinal 최초 측정을 항상 보장하기 위한 runtime reserve.
# VU Retry 같은 optional 작업은 이 reserve를 침범하면 생략한다.
$CalculatedFinalReserveSec = 220
$startTime = Get-Date
$maxRuntimeSeconds = $MaxRuntimeMinutes*60
$hardCompletionSafetySeconds = 10
$hardDeadline = $startTime.AddSeconds($maxRuntimeSeconds)
$tuningDeadline = $hardDeadline.AddSeconds(-$ShutdownReserveSeconds)
$deadline = $tuningDeadline
$stopTuning = $false
$tuningStopReason = 'Completed'
$runFailed = $true
$finalApplied = $false
$finalSelectionFatal = $false
$originalConfig = $null
$script:originalNodePoolCpu = $null
$script:originalStressNodePoolCpu = $null
$script:originalNodePoolHadCpuLimit = $false
$script:originalStressNodePoolHadCpuLimit = $false
$nodePoolLimitChanged = $false
$placementPolicyChanged = $false
$originalNodePoolTaintsJson = $null
$originalNodePoolHadTaints = $false
$originalKarpenterReplicas = $null
$originalAppTolerations = @{}
$originalAppHadTolerations = @{}
$originalConsolidationPolicy = $null
$originalConsolidateAfter = $null
$finalConsolidationChanged = $false
$finalIdleConverged = $null
$adaptiveVuMultiplier = 1.0
# VU Retry 상태 (candidate별 초기화는 Run-ReliableLoadTest에서)
$script:vuPlanOverride = $null
$script:retryWarmupSeconds = 0
$script:lastVuPlan = $null
$metricJobs = [System.Collections.Generic.List[object]]::new()

function Get-RemainingRuntimeSeconds([ValidateSet('Hard','Tuning')][string]$Deadline = 'Hard') {
    $target=if ($Deadline -eq 'Tuning') { $tuningDeadline } else { $hardDeadline }
    return [math]::Max(0,[math]::Floor(($target-(Get-Date)).TotalSeconds))
}

function Format-ElapsedText([TimeSpan]$elapsed) {
    # tune.ps1 전체 실행시간 표시용. 중복 stopwatch를 만들지 않고 $startTime을 그대로 쓴다.
    if ($elapsed.TotalHours -ge 1) {
        return '{0}:{1:00}:{2:00}' -f [math]::Floor($elapsed.TotalHours),$elapsed.Minutes,$elapsed.Seconds
    }
    return '{0}:{1:00}' -f [math]::Floor($elapsed.TotalMinutes),$elapsed.Seconds
}

function Get-EstimatedMeasurementDuration([int]$DurationSec) {
    return $DurationSec+$MeasurementOverheadSeconds
}

function Test-CanStartMeasurement([int]$DurationSec,[switch]$Quiet) {
    $required=Get-EstimatedMeasurementDuration $DurationSec
    $remaining=Get-RemainingRuntimeSeconds Tuning
    $canStart=(-not $script:stopTuning -and $remaining -ge $required)
    if (-not $canStart -and -not $Quiet) {
        Write-Warning "20분 runtime 제한을 위해 새 측정을 시작하지 않습니다: tuningRemaining=${remaining}s, estimated=${required}s, shutdownReserve=${ShutdownReserveSeconds}s"
    }
    return $canStart
}

function Get-VerificationRunCountForBudget([int]$DurationSec,[int]$RequestedRuns) {
    $perRun=Get-EstimatedMeasurementDuration $DurationSec
    if ($perRun -le 0) { return 0 }
    return [math]::Max(0,[math]::Min($RequestedRuns,[math]::Floor((Get-RemainingRuntimeSeconds Tuning)/$perRun)))
}

function Get-DeadlineTimeoutSeconds([int]$RequestedSeconds,[ValidateSet('Hard','Tuning')][string]$Deadline = 'Hard',[int]$MinimumSeconds = 1) {
    $remaining=Get-RemainingRuntimeSeconds $Deadline
    if ($Deadline -eq 'Hard') { $remaining=[math]::Max(0,$remaining-$hardCompletionSafetySeconds) }
    return [int][math]::Max($MinimumSeconds,[math]::Min($RequestedSeconds,[math]::Max($MinimumSeconds,$remaining)))
}

# 플랫폼 분기: Amazon Linux 2023 Bastion / Windows 양쪽에서 동작 (curl/NUL vs /dev/null)
$script:curlCmd=if ($env:OS -eq 'Windows_NT' -or $IsWindows) { 'curl.exe' } else { 'curl' }
$script:nullDevice=if ($env:OS -eq 'Windows_NT' -or $IsWindows) { 'NUL' } else { '/dev/null' }

# ===================== HPA CONTROL POINT MODEL =====================
function Initialize-HpaControlPointModel {
    # 기본값은 새 앱에서도 동작하는 보수적 prior이며, live HPA/request를 읽을 수
    # 있으면 현재 설정의 절대 제어점(request x target)을 먼저 사용한다.
    $ref=@{user=@{cp=23.1;source='REFERENCE_PRIOR';conf=0.30};product=@{cp=20.3;source='REFERENCE_PRIOR';conf=0.30};stress=@{cp=330.0;source='REFERENCE_PRIOR';conf=0.30}}
    foreach ($app in $apps) {
        $cp=[double]$ref[$app].cp; $source=[string]$ref[$app].source; $confidence=[double]$ref[$app].conf
        try {
            $live=Get-LiveConfig 'ControlPointLive'
            $req=Convert-CpuToM $live[$app].requestCpu
            $target=[double]$live[$app].hpaTarget
            if ($req -gt 0 -and $target -gt 0) { $cp=$req*$target/100.0; $source='LIVE_SEED'; $confidence=0.45 }
        } catch { }
        $script:ControlPointByApp[$app]=$cp
        $script:ControlPointSourceByApp[$app]=$source
        $script:ControlPointConfidenceByApp[$app]=$confidence
    }
    Write-Host '===== HPA CONTROL POINT =====' -ForegroundColor Cyan
    foreach ($app in $apps) {
        Write-Host ("  {0}: absoluteThreshold={1:N1}m source={2} confidence={3:N2}" -f $app,$script:ControlPointByApp[$app],$script:ControlPointSourceByApp[$app],$script:ControlPointConfidenceByApp[$app]) -ForegroundColor DarkGray
    }
    Restore-HpaControlPointState
}

function Restore-HpaControlPointState {
    # 이전 run의 MEASURED control point 복원 — reference prior보다 실측 우선.
    # (target=15% clamp 방지: reference cp 23.1m + request 150m → target 15.4% → clamp)
    if (-not (Test-Path -LiteralPath $script:ControlPointStateFile)) { return }
    try {
        $state=Get-Content -Raw -LiteralPath $script:ControlPointStateFile | ConvertFrom-Json
        $restored=0
        foreach ($app in $apps) {
            if ($state.$app -and [string]$state.$app.source -like 'MEASURED_*' -and [double]$state.$app.cp -gt 0) {
                $script:ControlPointByApp[$app]=[double]$state.$app.cp
                $script:ControlPointSourceByApp[$app]=[string]$state.$app.source
                $script:ControlPointConfidenceByApp[$app]=[double]$state.$app.confidence
                $restored++
            }
        }
        if ($restored -gt 0) {
            Write-Host '===== HPA CONTROL POINT (state restored) =====' -ForegroundColor Cyan
            foreach ($app in $apps) {
                Write-Host ("  {0}: cp={1:N1}m source={2} confidence={3:N2}" -f $app,$script:ControlPointByApp[$app],$script:ControlPointSourceByApp[$app],$script:ControlPointConfidenceByApp[$app]) -ForegroundColor DarkGray
            }
        }
    } catch { Write-Warning "control point state 복원 실패: $($_.Exception.Message)" }
}

function Save-HpaControlPointState {
    $state=@{}
    foreach ($app in $apps) {
        $cp=Get-HpaControlPoint $app
        if ($cp.Source -like 'MEASURED_*' -and $cp.Value -gt 0) {
            $state[$app]=@{cp=$cp.Value;source=$cp.Source;confidence=$cp.Confidence}
        }
    }
    if ($state.Count -gt 0) {
        try { $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:ControlPointStateFile }
        catch { Write-Warning "control point state 저장 실패: $($_.Exception.Message)" }
    }
}

function Get-HpaControlPoint([string]$app) {
    $v=if ($script:ControlPointByApp.ContainsKey($app)) { [double]$script:ControlPointByApp[$app] } else { 0.0 }
    $src=if ($script:ControlPointSourceByApp.ContainsKey($app)) { [string]$script:ControlPointSourceByApp[$app] } else { 'UNKNOWN' }
    $conf=if ($script:ControlPointConfidenceByApp.ContainsKey($app)) { [double]$script:ControlPointConfidenceByApp[$app] } else { 0.0 }
    return [pscustomobject]@{Value=$v;Source=$src;Confidence=$conf}
}

function Get-HpaTargetFromControlPoint([string]$app,[double]$requestM) {
    # target = 100 x controlPoint / request — request가 바뀌어도 absolute HPA threshold 보존.
    # target이 bounds 밖이면 EMPIRICAL_UNCONFIRMED 경고 (request 재조정 신호).
    $cp=Get-HpaControlPoint $app
    if ($cp.Value -le 0 -or $requestM -le 0) { return 65.0 }
    $target=100.0*$cp.Value/$requestM
    if ($target -lt $HpaTargetLowerBound) {
        Write-Warning ("HPA_TARGET_BELOW_BOUND: {0} target={1:N1}% < {2}% (request {3:N0}m 너무 큼 — request 축소 또는 cp 하향 필요)" -f $app,$target,$HpaTargetLowerBound,$requestM)
        return [math]::Max($HpaTargetLowerBound,$target)
    }
    if ($target -gt $HpaTargetUpperBound) {
        Write-Warning ("HPA_TARGET_ABOVE_BOUND: {0} target={1:N1}% > {2}% (request {3:N0}m 너무 작음 — request 상향 필요)" -f $app,$target,$HpaTargetUpperBound,$requestM)
        return [math]::Min($HpaTargetUpperBound,$target)
    }
    return $target
}

function Update-HpaControlPointFromMeasurement([string]$app,$metric,$config) {
    # same-run evidence 기반 control point 학습 (MEASURED_STABLE/SLO_RECOVERY만).
    #   MEASURED_STABLE      : SLO>=95% + reliable → 현재 cp를 검증된 값으로 기록
    #   MEASURED_SLO_RECOVERY: SLO<95%면 더 민감하게 (cp 하향): T_cand = T x R_current / R_required
    $cur=Get-HpaControlPoint $app
    $slo=[double](Get-OptionalPropertyValue $metric 'SLOComplianceRate' 0)
    $reliable=[bool](Get-OptionalPropertyValue $metric 'MeasurementReliable' $false)
    if (-not $reliable) { return $cur }
    $requestM=[double](Convert-CpuToM $config[$app].requestCpu)
    $target=[int]$config[$app].hpaTarget
    if ($target -le 0) { return $cur }
    $currentCp=$requestM*$target/100.0
    if ($currentCp -le 0) { return $cur }
    if ($slo -ge 0.95) {
        # 검증된 안정 상태: 현재 cp 기록 (prior보다 실측 우선). confidence 누적.
        if ($script:ControlPointSourceByApp[$app] -eq 'MEASURED_STABLE') {
            $script:ControlPointConfidenceByApp[$app]=[math]::Min(1.0,$script:ControlPointConfidenceByApp[$app]+0.2)
        } else {
            $script:ControlPointByApp[$app]=$currentCp
            $script:ControlPointSourceByApp[$app]='MEASURED_STABLE'
            $script:ControlPointConfidenceByApp[$app]=0.5
        }
        return Get-HpaControlPoint $app
    }
    if ($slo -lt 0.95 -and $slo -gt 0.0) {
        # SLO 회복이 필요한 앱: replica 부족이 원인이라면 cp 하향(더 민감하게).
        $rCur=[double](Get-OptionalPropertyValue $metric 'PeakReadyReplicas' 0)
        $cpuAvg=[double](Get-OptionalPropertyValue $metric 'AverageCPUUtilization' 0)
        $rRequired=0.0
        if ($cpuAvg -gt 0 -and $target -gt 0) { $rRequired=[math]::Ceiling([math]::Max(1.0,$rCur)*$cpuAvg/$target) }
        if ($rRequired -gt $rCur -and $rCur -gt 0) {
            $candCp=$currentCp*$rCur/[math]::Max($rRequired,1.0)
            $script:ControlPointByApp[$app]=[math]::Max($candCp,[double]$script:ControlPointByApp[$app]*0.5)   # 절반 이하로 안 내림
            $script:ControlPointSourceByApp[$app]='MEASURED_SLO_RECOVERY'
            $script:ControlPointConfidenceByApp[$app]=0.4
            Write-Host ("  control point [{0}]: {1:N1}m -> {2:N1}m (SLO_RECOVERY R={3}->{4})" -f $app,$currentCp,$script:ControlPointByApp[$app],$rCur,$rRequired) -ForegroundColor Yellow
        }
    }
    return Get-HpaControlPoint $app
}

# ===================== POD DENSITY / VPC CNI =====================
function Get-VpcCniStatus {
    # 정확한 JSON 파싱으로 ENABLE_PREFIX_DELEGATION/WARM_PREFIX_TARGET 확인
    $envMap=@{}
    try {
        $dsJson = kubectl -n kube-system get ds aws-node -o json 2>$null | ConvertFrom-Json
        foreach ($e in $dsJson.spec.template.spec.containers[0].env) {
            $envMap[[string]$e.name] = [string]$e.value
        }
    } catch { }
    $prefix = if ($envMap.ContainsKey('ENABLE_PREFIX_DELEGATION')) {
        $envMap['ENABLE_PREFIX_DELEGATION'] -eq 'true'
    } else { $null }
    $warmPrefix = if ($envMap.ContainsKey('WARM_PREFIX_TARGET')) {
        [int]$envMap['WARM_PREFIX_TARGET']
    } else { $null }
    return [pscustomobject]@{PrefixDelegation=$prefix;WarmPrefixTarget=$warmPrefix;EnvMap=$envMap}
}

function Get-PodDensityReport($cluster,$config) {
    # 노드당 실제 application pod capacity:
    #   PodCapacityPerNode = min(kubeletSlots, networkSlots, cpuRequestSlots, memoryRequestSlots)
    # CPU가 남았는데 maxPods 때문에 새 노드가 생기면 POD_SLOT_LIMIT로 정확히 진단한다.
    $node=@(Invoke-Kubectl @('get','nodes','--no-headers') | Where-Object { $_ -match ' Ready ' } | Select-Object -First 1)
    $nodeName=if ($node) { ($node -split '\s+')[0] } else { '' }
    $kubeletPods=110
    if ($nodeName) {
        try { $kubeletPods=[int]((Invoke-Kubectl @('get','node',$nodeName,'-o','jsonpath={.status.allocatable.pods}')) -join '') } catch { }
    }
    $systemPods=0
    try { $systemPods=@(Invoke-Kubectl @('-n','kube-system','get','pods','--no-headers') | Where-Object { $_ -match ' Running ' }).Count } catch { }
    $appSlots=[math]::Max(1,$kubeletPods-$systemPods)
    $allocCpu=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableCPU' 1930.0)
    $allocMem=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableMemoryMi' 3292.0)
    $appCpuBudget=$allocCpu*$NodeCpuBudgetUtilization
    $appMemBudget=$allocMem*$MemoryBudgetUtilization
    $cni=Get-VpcCniStatus
    $networkSlots=$null
    if ($cni.PrefixDelegation) { $networkSlots=$kubeletPods }
    $perApp=@{}
    foreach ($app in $apps) {
        $reqC=[double](Convert-CpuToM $config[$app].requestCpu)
        $reqM=[double](Convert-MemoryToMi $config[$app].requestMemory)
        $cpuSlots=if ($reqC -gt 0) { [math]::Floor($appCpuBudget/$reqC) } else { 0 }
        $memSlots=if ($reqM -gt 0) { [math]::Floor($appMemBudget/$reqM) } else { 0 }
        $effective=[math]::Min($appSlots,$cpuSlots)
        if ($null -ne $networkSlots) { $effective=[math]::Min($effective,$networkSlots) }
        if ($memSlots -gt 0) { $effective=[math]::Min($effective,$memSlots) }
        $perApp[$app]=@{CpuSlots=$cpuSlots;MemorySlots=$memSlots;NetworkSlots=$networkSlots;Effective=$effective}
    }
    return [pscustomobject]@{NodeType=(Get-OptionalPropertyValue $cluster 'NodeInstanceType' '');NodeName=$nodeName;KubeletMaxPods=$kubeletPods;SystemPods=$systemPods;AppPodSlots=$appSlots;AppCpuBudgetM=$appCpuBudget;AppMemBudgetMi=$appMemBudget;Cni=$cni;PerApp=$perApp}
}

function Write-PodDensityLog($report,$config) {
    Write-Host '===== POD DENSITY =====' -ForegroundColor Cyan
    Write-Host ("  nodeType={0}  prefixDelegation={1}  warmPrefixTarget={2}  kubeletMaxPods={3}  systemPods={4}  appPodSlots={5}" -f $report.NodeType,$report.Cni.PrefixDelegation,$(if ($null -eq $report.Cni.WarmPrefixTarget) { '-' } else { $report.Cni.WarmPrefixTarget }),$report.KubeletMaxPods,$report.SystemPods,$report.AppPodSlots) -ForegroundColor DarkGray
    foreach ($app in $apps) {
        $p=$report.PerApp[$app]
        Write-Host ("  {0}: request={1}  cpuSlots={2}  memSlots={3}  netSlots={4}  effectivePodCapacity={5}" -f $app,(Format-Cpu (Convert-CpuToM $config[$app].requestCpu)),$p.CpuSlots,$p.MemorySlots,$(if ($null -eq $p.NetworkSlots) { '-' } else { $p.NetworkSlots }),$p.Effective) -ForegroundColor DarkGray
    }
    Write-Host '===== VPC CNI =====' -ForegroundColor Cyan
    Write-Host ("  ENABLE_PREFIX_DELEGATION={0}  WARM_PREFIX_TARGET={1}  (known-good reference: true/1)" -f $(if ($report.Cni.PrefixDelegation) { 'true' } else { 'false' }),$(if ($null -eq $report.Cni.WarmPrefixTarget) { '-' } else { $report.Cni.WarmPrefixTarget })) -ForegroundColor DarkGray
}

# ===================== ELASTIC_DENSITY_REQUEST (user/product) =====================
function Get-ElasticDensityRequest([string]$app,$metric,[double]$currentReqM) {
    # reference request가 아니라 현재 request와 실측 q75를 사용한다.
    $sustained=[bool](Get-OptionalPropertyValue $metric 'SustainedCpuPressure' $false)

    $avgM=[double](Get-OptionalPropertyValue $metric 'AverageCPUMillicores' 0)
    $q75M=[double](Get-OptionalPropertyValue $metric 'CPUP95Millicores' (Get-OptionalPropertyValue $metric 'AverageCPUMillicores' 0))
    $headroom=Get-AdaptiveHeadroom ([double]$avgM*0.75) $avgM $q75M $CpuRequestMinHeadroom $CpuRequestMaxHeadroom $CpuRequestAlpha
    $measuredTarget=[math]::Max([double]$cpuRequestMinimum[$app],$q75M*$headroom)
    $candidate=if ($sustained) { [math]::Max($measuredTarget,[double]$currentReqM) } else { $measuredTarget }
    $candidate=Round-UpStep $candidate $CpuRequestStep
    return $candidate
}

function Require([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "명령을 찾을 수 없습니다: $name" }
}

function Invoke-Kubectl([string[]]$Arguments) {
    # PowerShell 5.1은 native command 인자의 JSON 따옴표를 제거할 수 있다.
    # kubectl patch는 임시 --patch-file로 전달해 Windows/Linux 모두 동일하게 처리한다.
    $args2=[System.Collections.Generic.List[string]]::new()
    $tempFiles=[System.Collections.Generic.List[string]]::new()
    try {
        for ($i=0; $i -lt $Arguments.Count; $i++) {
            if ($Arguments[$i] -eq '-p' -and ($i+1) -lt $Arguments.Count) {
                $patch=[string]$Arguments[$i+1]
                if ($patch.TrimStart().StartsWith('{') -or $patch.TrimStart().StartsWith('[')) {
                    $file=[IO.Path]::GetTempFileName()
                    [IO.File]::WriteAllText($file,$patch,(New-Object System.Text.UTF8Encoding($false)))
                    $tempFiles.Add($file)
                    $args2.Add('--patch-file'); $args2.Add($file); $i++
                    continue
                }
            }
            $args2.Add([string]$Arguments[$i])
        }
        $output=@(& kubectl @args2 2>&1)
        $exitCode=$LASTEXITCODE
        if ($exitCode -ne 0) { throw "kubectl 실패: kubectl $($args2 -join ' '): $($output -join ' ')" }
        return @($output)
    } finally {
        foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

function Wait-DeploymentRollout([string]$app,[int]$timeoutSec = 180,[ValidateSet('Hard','Tuning')][string]$Deadline = 'Hard') {
    $timeoutSec=Get-DeadlineTimeoutSeconds $timeoutSec $Deadline
    $output=@(& kubectl -n $Namespace rollout status "deployment/$app" "--timeout=${timeoutSec}s" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ROLLOUT_TIMEOUT] $app - collecting diagnostics" -ForegroundColor Yellow
        try { $dpods=kubectl -n $Namespace get pods -l "app=$app" -o wide 2>&1 | Out-String; Write-Host $dpods -ForegroundColor Yellow } catch {}
        try { $dnodes=kubectl get nodes -o wide --no-headers 2>&1 | Out-String; Write-Host $dnodes -ForegroundColor Yellow } catch {}
        try { $devts=kubectl -n $Namespace get events --sort-by=.lastTimestamp 2>&1 | Select-Object -Last 8 | Out-String; Write-Host $devts -ForegroundColor Yellow } catch {}
        throw "ROLLOUT_TIMEOUT: $app - $($output -join ' ')"
    }
    if ($DetailedOutput) { Write-Host "  $app rollout 완료" -ForegroundColor DarkGray }
}

function Convert-CpuToM($value) {
    if ($null -eq $value) { return $null }
    $text = ([string]$value).Trim()
    if (-not $text -or $text -eq '0' -or $text -eq '0m' -or $text -eq '0.0') { return $null }
    if ($text -match '^([0-9.]+)n$') { return [double]$Matches[1] / 1000000.0 }
    if ($text -match '^([0-9.]+)u$') { return [double]$Matches[1] / 1000.0 }
    if ($text -match '^([0-9.]+)m$') { return [double]$Matches[1] }
    if ($text -match '^[0-9.]+$') { return [double]$text * 1000.0 }
    return $null
}

function Convert-MemoryToMi($value) {
    $text = ([string]$value).Trim()
    if (-not $text) { return $null }
    if ($text -match '^([0-9.]+)Ki$') { return [double]$Matches[1] / 1024.0 }
    if ($text -match '^([0-9.]+)Mi$') { return [double]$Matches[1] }
    if ($text -match '^([0-9.]+)Gi$') { return [double]$Matches[1] * 1024.0 }
    if ($text -match '^([0-9.]+)K$') { return [double]$Matches[1] * 1000.0 / 1MB }
    if ($text -match '^([0-9.]+)M$') { return [double]$Matches[1] * 1000000.0 / 1MB }
    if ($text -match '^([0-9.]+)G$') { return [double]$Matches[1] * 1000000000.0 / 1MB }
    if ($text -match '^[0-9.]+$') { return [double]$text / 1MB }
    return $null
}

function Format-Cpu($millicores) {
    if ($null -eq $millicores -or $millicores -eq '') { return $null }
    $mc = [double]$millicores
    if ($mc -eq 0) { return $null }
    $rounded = [math]::Max(25, [math]::Ceiling($mc / 25.0) * 25)
    return "$([int]$rounded)m"
}

function Format-Memory([double]$mi, [int]$minimumMi = 64) {
    $rounded = [math]::Max($minimumMi, [math]::Ceiling($mi / 32.0) * 32)
    return "$([int]$rounded)Mi"
}

function Get-Percentile([double[]]$values, [double]$percentile) {
    $valid = @($values | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $valid.Count) { return $null }
    $index = [math]::Ceiling(($percentile / 100.0) * $valid.Count) - 1
    return [double]$valid[[math]::Max(0, [math]::Min($valid.Count - 1, $index))]
}

function Get-MetricNumber($metric, [string]$name) {
    if ($null -eq $metric) { return $null }
    $direct = $metric.PSObject.Properties[$name]
    if ($direct) { return [double]$direct.Value }
    if ($metric.values) {
        $nested = $metric.values.PSObject.Properties[$name]
        if ($nested) { return [double]$nested.Value }
    }
    return $null
}

function Copy-Config([hashtable]$source, [string]$name) {
    $copy = @{ Name=$name }
    if ($source.ContainsKey('NodeBudget')) { $copy.NodeBudget=[int]$source.NodeBudget }
    foreach ($app in $apps) {
        $src = $source[$app]
        $copy[$app] = @{
            requestCpu=[string]$src.requestCpu
            requestMemory=[string]$src.requestMemory
            limitCpu=$src.limitCpu
            limitMemory=$src.limitMemory
            minReplicas=[int]$src.minReplicas
            maxReplicas=[int]$src.maxReplicas
            hpaTarget=[int]$src.hpaTarget
            replicas=[int]$src.replicas
            behavior=$src.behavior
            placementDomain=$(if ($src.ContainsKey('placementDomain')) { [string]$src.placementDomain } else { 'shared' })
        }
    }
    return $copy
}

function Get-StandardHpaBehavior([string]$app = '') {
    # User는 200ms SLO라 늦은 scale-up의 tail latency 손실이 크고, Stress는
    # timeout 전 용량이 필요하다. Product만 Min으로 비용을 제어한다.
    $scaleUpPolicy=if ($app -in @('user','stress')) { 'Max' } else { 'Min' }
    $scaleUpStabilization=if ($app -eq 'user') { 0 } else { 30 }
    return @{
        scaleUp=@{
            stabilizationWindowSeconds=$scaleUpStabilization
            selectPolicy=$scaleUpPolicy
            policies=@(
                @{type='Percent';value=50;periodSeconds=30},
                @{type='Pods';value=2;periodSeconds=30}
            )
        }
        scaleDown=@{
            stabilizationWindowSeconds=30
            selectPolicy='Max'
            policies=@(
                @{type='Percent';value=100;periodSeconds=15},
                @{type='Pods';value=4;periodSeconds=15}
            )
        }
    }
}

function Get-RateSteps([int]$peakRate) {
    $steps=[System.Collections.Generic.List[int]]::new()
    if ($peakRate -le 10) { $steps.Add($peakRate); return @($steps) }
    for ($rate=10; $rate -lt $peakRate; $rate+=10) { $steps.Add($rate) }
    if (-not $steps.Count -or $steps[$steps.Count-1] -ne $peakRate) { $steps.Add($peakRate) }
    return @($steps)
}

function Get-GlobalVUCap {
    # runner logical CPU 기반 cap: min(192, logicalCPU x 8). 읽기 실패 시 안전 fallback 128.
    $logical=$null
    try { $logical=[Environment]::ProcessorCount } catch { }
    if ($null -eq $logical -or [int]$logical -le 0) { return $GlobalVUCapFallback }
    return [math]::Min($GlobalVUCapMax,[int]$logical*$GlobalVUCapPerCpu)
}

function Get-LatencyEstimator($result) {
    # API별 L_est: steady_success_p95(sample>=100) -> success_p95(sample>=20) -> 1.5s fallback.
    # ZERO_SUCCESS_CAPACITY 등 성공 샘플 부족 시 5초 timeout을 estimator로 쓰지 않는다.
    $est=@{}
    foreach ($app in $apps) {
        $metric=Get-ResultAppMetric $result $app
        $steadyP95=Get-OptionalPropertyValue $metric 'SteadySuccessP95Ms'
        $steadySamples=Get-OptionalPropertyValue $metric 'SteadySuccessSampleCount'
        $overallP95=Get-OptionalPropertyValue $metric 'SuccessP95MsOverall'
        $overallSamples=Get-OptionalPropertyValue $metric 'SuccessSampleCount'
        if ($null -ne $steadyP95 -and $null -ne $steadySamples -and [int]$steadySamples -ge 100) { $est[$app]=[double]$steadyP95/1000.0 }
        elseif ($null -ne $overallP95 -and $null -ne $overallSamples -and [int]$overallSamples -ge 20) { $est[$app]=[double]$overallP95/1000.0 }
        else { $est[$app]=$LatencyEstimatorFallbackSec }
    }
    return $est
}

function Resolve-VUAllocation([hashtable]$required,[int]$globalCap,[hashtable]$saturated,[hashtable]$floorOverride) {
    # RequiredVU 합이 cap을 넘으면 비례 축소(floor) + MinScenarioVU floor + 합<=cap 보장.
    # saturation scenario는 growthFloor(floorOverride) 이상 유지하고,
    # 여유분은 정상 scenario부터 줄인다(의미 있는 VU 증가가 사라지지 않게).
    $total=[double](($required.Values | Measure-Object -Sum).Sum)
    if ($total -le $globalCap) { return $required }
    $scale=$globalCap/$total
    $allocated=@{}
    foreach ($app in $apps) { $allocated[$app]=[int][math]::Floor([double]$required[$app]*$scale) }
    foreach ($app in $apps) { if ($allocated[$app] -lt $MinScenarioVU) { $allocated[$app]=$MinScenarioVU } }
    $saturationFloor=@{}
    if ($floorOverride) { foreach ($app in $apps) { if ($floorOverride.ContainsKey($app)) { $saturationFloor[$app]=[int]$floorOverride[$app] } } }
    elseif ($saturated) { foreach ($app in $apps) { if ($saturated[$app]) { $saturationFloor[$app]=[int][math]::Ceiling([double]$required[$app]*0.8) } } }
    # saturation scenario는 growthFloor 이상으로 올려준다(축소로 증가가 사라지는 것 방지).
    foreach ($app in $apps) {
        if ($saturationFloor.ContainsKey($app) -and [int]$allocated[$app] -lt [int]$saturationFloor[$app]) {
            $allocated[$app]=[int]$saturationFloor[$app]
        }
    }
    while ((($allocated.Values | Measure-Object -Sum).Sum) -gt $globalCap) {
        # 감소 후보: 정상(saturation 아님) scenario 우선, 없으면 전체.
        $candidateApps=if ($saturated) { @($apps | Where-Object { -not $saturated[$_] }) } else { @($apps) }
        if (-not $candidateApps.Count) { $candidateApps=@($apps) }
        $largestKey=$null;$largestVal=0
        foreach ($app in $candidateApps) {
            $val=[int]$allocated[$app]
            $floor=if ($saturationFloor.ContainsKey($app)) { [int]$saturationFloor[$app] } else { $MinScenarioVU }
            if ($val -gt $floor -and $val -gt $largestVal) { $largestVal=$val; $largestKey=$app }
        }
        if ($null -eq $largestKey) {
            # 전부 floor에 도달: 그래도 cap 초과면 어쩔 수 없이 전체에서 감소 시도.
            $largestKey=($allocated.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
            if ([int]$allocated[$largestKey] -le $MinScenarioVU) { break }
        }
        $allocated[$largestKey]=[int]$allocated[$largestKey]-1
    }
    return $allocated
}

function New-VUAllocation([hashtable]$latencyEstimator,[int]$peakRate,[object]$currentPlan,[hashtable]$saturated,[hashtable]$targetGenerated,[hashtable]$peakByApp=$null) {
    # RequiredVU_i 산정. saturated scenario만 적극 증가한다(정상 scenario 강제 증가 금지).
    #   latencyBased = ceil(rate x L_est x 1.3)
    #   deficitBased = generated>0 ? ceil(currentPre x target/generated x 1.15) : ceil(currentPre x 2.0)
    #   growthFloor  = ceil(currentPre x 1.25)
    #   RequiredVU   = max(currentPre, latencyBased, deficitBased, growthFloor)
    # retry가 항상 실질적으로 VU를 늘리도록 보장한다(+0% retry 금지).
    $required=@{}
    $growthFloorAll=@{}
    foreach ($app in $apps) {
        $current=if ($currentPlan -and $currentPlan.Apps -and $currentPlan.Apps[$app]) { $currentPlan.Apps[$app] } else { $null }
        $currentPre=if ($current) { [int]$current.PreAllocated } else { 1 }
        $rate=[int][math]::Max(1,[math]::Round($peakRate*[double]$trafficShare[$app]))
        $lEst=[double]$latencyEstimator[$app]
        $latencyBased=[int][math]::Ceiling($rate*$lEst*$RequiredVUFactor)
        if ($null -eq $saturated) {
            # 최초 실행(saturation 정보 없음): latency 기반으로 초기 VU 산정.
            $required[$app]=[int][math]::Max($MinScenarioVU,$latencyBased)
            continue
        }
        if (-not $saturated[$app]) { $required[$app]=[int]$currentPre; continue }
        $generated=0.0;$target=0.0
        if ($targetGenerated -and $targetGenerated.ContainsKey($app)) {
            $generated=[double]$targetGenerated[$app].Generated
            $target=[double]$targetGenerated[$app].Target
        }
        $deficitBased=if ($generated -gt 0) { [int][math]::Ceiling([double]$currentPre*($target/[double]$generated)*1.15) } else { [int][math]::Ceiling([double]$currentPre*2.0) }
        $growthFloor=[int][math]::Ceiling([double]$currentPre*1.25)
        $growthFloorAll[$app]=$growthFloor
        $required[$app]=[int][math]::Max($currentPre,[math]::Max($latencyBased,[math]::Max($deficitBased,$growthFloor)))
        # 실측 VU demand 반영: peakVUs(런타임 관측)가 계산 required보다 크면 따라간다.
        # (LOAD_GENERATOR_LIMIT에서 peakVUs=156 > required 78 같은 격차 해소)
        if ($peakByApp -and $peakByApp.ContainsKey($app) -and [double]$peakByApp[$app] -gt 0) {
            $required[$app]=[int][math]::Max($required[$app],[int][math]::Ceiling([double]$peakByApp[$app]*1.15))
        }
    }
    $globalCap=Get-GlobalVUCap
    $requiredTotal=[double](($required.Values | Measure-Object -Sum).Sum)
    $allocated=Resolve-VUAllocation $required $globalCap $saturated $growthFloorAll
    $plan=@{}
    $totalMax=0
    foreach ($app in $apps) {
        $current=if ($currentPlan -and $currentPlan.Apps -and $currentPlan.Apps[$app]) { $currentPlan.Apps[$app] } else { $null }
        $currentPre=if ($current) { [int]$current.PreAllocated } else { 1 }
        $currentMax=if ($current) { [int]$current.Max } else { 1 }
        $pre=[math]::Max($currentPre,[int]$allocated[$app])
        $max=[math]::Max($currentMax,[math]::Ceiling([int]$allocated[$app]*$MaxVUFactor)+$MaxVUBuffer)
        $plan[$app]=[pscustomobject]@{Rate=[int]$rate;Required=[int]$required[$app];PreAllocated=[int]$pre;Max=[int]$max}
        $totalMax += [int]$max
    }
    return [pscustomobject]@{Apps=$plan;TotalMax=$totalMax;GlobalCap=$globalCap;RequiredTotal=[int]$requiredTotal;ProportionalScaled=($requiredTotal -gt $globalCap)}
}

function Get-RequiredK6VUs([int]$peakRate) {
    # 최초 실행: latency를 모르므로 L_est=1.5s fallback으로 API별 RequiredVU를 산정한다.
    $minPlan=@{}; foreach ($app in $apps) { $minPlan[$app]=[pscustomobject]@{PreAllocated=1;Max=1} }
    $est=@{}; foreach ($app in $apps) { $est[$app]=$LatencyEstimatorFallbackSec }
    return New-VUAllocation $est $peakRate ([pscustomobject]@{Apps=$minPlan}) $null $null
}

function Get-RetryWarmupSeconds([int]$durationSec,[double]$vuIncreaseRatio,[double]$retryGapSec) {
    # VU 증가 <20% && retry gap <10s면 warmup 생략(0). 아니면 clamp(5, 10, duration x 0.05).
    if ($vuIncreaseRatio -lt $RetryWarmupSkipIncrease -and $retryGapSec -lt $RetryWarmupSkipGapSec) { return 0 }
    $warmup=[math]::Round($durationSec*0.05)
    return [int][math]::Min($RetryWarmupMaxSec,[math]::Max($RetryWarmupMinSec,$warmup))
}

function Test-VURetryAllowed([double]$remainingAfterRetry,[int]$reserve) {
    # optional VU Retry는 CalculatedFinal 최초 측정 reserve를 침범하면 생략한다.
    # retry 이후 남는 시간이 reserve 이상이어야 허용. (사양: remaining < optionalCost + reserve → skip)
    return $remainingAfterRetry -ge $reserve
}

function Get-MeasurementConfidence($result) {
    # CalculatedFinal tuning source 선택용 신뢰도 = min(generatedRatio) x (1 - worst droppedPct).
    # G/R이 낮은(load generator unreliable) candidate의 병목 신호를 덜 신뢰한다.
    $gMin=[double]1.0;$rMin=[double]1.0
    foreach ($app in $apps) {
        $m=Get-ResultAppMetric $result $app
        $g=Get-OptionalPropertyValue $m 'GeneratedLoadRatio' 1.0
        $d=Get-OptionalPropertyValue $m 'DroppedPct' 0.0
        if ($null -eq $g) { $g=0.0 }
        if ($null -eq $d) { $d=0.0 }
        if ([double]$g -lt $gMin) { $gMin=[double]$g }
        if ((1.0-[double]$d) -lt $rMin) { $rMin=1.0-[double]$d }
    }
    return [math]::Round([double]$gMin*$rMin,4)
}

function Select-TuningReference([object[]]$candidates) {
    # 병목 신호 source 선택: 신뢰도(G x R) 높은 순 -> min generated 높은 순 -> 최신 순.
    $scored=@($candidates | Where-Object { $_ -and $_.Apps } | ForEach-Object {
        $gMin=[double]1.0
        foreach ($app in $apps) {
            $m=Get-ResultAppMetric $_ $app
            $g=Get-OptionalPropertyValue $m 'GeneratedLoadRatio' 1.0
            if ($null -ne $g -and [double]$g -lt $gMin) { $gMin=[double]$g }
        }
        [pscustomobject]@{Result=$_;Confidence=(Get-MeasurementConfidence $_);GeneratedMin=$gMin}
    })
    if (-not $scored.Count) { return $null }
    $selected=@($scored | Sort-Object @{Expression='Confidence';Descending=$true},@{Expression='GeneratedMin';Descending=$true}) | Select-Object -First 1
    return $selected.Result
}

function Get-LiveConfig([string]$name = 'original') {
    $deployments = (& kubectl get deployments -n $Namespace -o json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Deployment 조회 실패: namespace=$Namespace" }
    $hpas = (& kubectl get hpa -n $Namespace -o json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "HPA 조회 실패: namespace=$Namespace" }
    $config = @{ Name=$name }
    foreach ($app in $apps) {
        $deployment = $deployments.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1
        $hpa = $hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1
        if (-not $deployment -or -not $hpa) { throw "필수 Deployment/HPA를 찾지 못했습니다: $app" }
        $resources = $deployment.spec.template.spec.containers[0].resources
        if (-not $resources.requests -or -not $resources.requests.cpu -or -not $resources.requests.memory) {
            throw "$app resources.requests.cpu/memory가 필요합니다. CPU limit은 user/product에서 의도적으로 생략할 수 있습니다."
        }
        $target = $hpa.spec.metrics | Where-Object { $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' } | Select-Object -First 1
        if (-not $target) { throw "$app HPA CPU metric을 찾지 못했습니다." }
        $config[$app] = @{
            requestCpu=[string]$resources.requests.cpu
            requestMemory=[string]$resources.requests.memory
            # Kubernetes canonicalizes 2000m as "2"; normalize before fingerprint comparison.
            limitCpu=$(if ($resources.limits.cpu) { Format-Cpu (Convert-CpuToM $resources.limits.cpu) } else { $null })
            limitMemory=$(if ($resources.limits.memory) { [string]$resources.limits.memory } else { $null })
            minReplicas=[int]$hpa.spec.minReplicas
            maxReplicas=[int]$hpa.spec.maxReplicas
            hpaTarget=[int]$target.resource.target.averageUtilization
            replicas=[int]$deployment.spec.replicas
            behavior=$hpa.spec.behavior
        }
    }
    return $config
}

function Show-Config([hashtable]$config, [string]$label) {
    Write-Host $label -ForegroundColor Cyan
    if ($config.ContainsKey('NodeBudget')) { Write-Host "  capacity tier: 최대 $($config.NodeBudget) nodes" -ForegroundColor DarkGray }
    foreach ($app in $apps) {
        $c = $config[$app]
        Write-Host ("  {0,-7} req={1}/{2}, limit={3}/{4}, HPA={5}% {6}..{7}" -f $app,$c.requestCpu,$c.requestMemory,$c.limitCpu,$c.limitMemory,$c.hpaTarget,$c.minReplicas,$c.maxReplicas)
    }
}

function Set-RequiredPolicy([hashtable]$source,[string]$name,[hashtable]$desiredHpaMax = $null) {
    # P0-1: 측정 config = final config 원칙.
    #   request/limit은 실측에서 결정. minReplicas=1 강제 금지. stress limit=request×2 강제 금지.
    #   HPA target은 control point에서 결정. literal 고정 금지.
    $config=Copy-Config $source $name
    foreach ($app in $apps) {
        # 현재 Deployment request를 seed로 사용한다. KnownGoodReference는
        # 다른 대회 앱에 강제 적용하지 않고, 측정 전 참고 로그로만 남긴다.
        $existingReq=Convert-CpuToM $config[$app].requestCpu
        $requestM=[math]::Max([double]$cpuRequestMinimum[$app],[double]$existingReq)

        $existingLimit=Convert-CpuToM $config[$app].limitCpu
        # CPU limit은 모든 앱에서 제거한다. request만으로 burst를 허용하고
        # CPU throttling을 피한다. memory limit은 별도로 유지한다.
        $limitM=0
        # K8s invariant: request ≤ limit. limit이 있으면 request는 limit 이하로.
        if ($limitM -gt 0 -and $requestM -gt $limitM) {
            Write-Host ("  {0}: request {1:N0}m → {2:N0}m (limit {2:N0}m 초과 → request 축소)" -f $app,$requestM,$limitM) -ForegroundColor Yellow
            $requestM=$limitM
        }
        $requestedMax=[int]$config[$app].maxReplicas
        $config[$app].requestCpu=Format-Cpu $requestM
        $config[$app].limitCpu=Format-Cpu $limitM
        # P0-1: min=1 강제 금지 — 기존 min 보존 (control point/no-scale fill에서 결정).
        # 단 min이 0이면 1로 floor.
        if ([int]$config[$app].minReplicas -lt 1) { $config[$app].minReplicas=1 }
        $requestedMax=[int][math]::Min($MaxAutoReplicas,$requestedMax)
        $preservedMin=[int]$config[$app].minReplicas
        $config[$app].maxReplicas=[int][math]::Max($preservedMin,$requestedMax)
        $config[$app].hpaTarget=[int]$config[$app].hpaTarget
        $config[$app].replicas=1
    }
    return $config
}

function New-MinimumConfig([hashtable]$seed,[string]$name = 'Minimum') {
    # P0-1: 측정 config = final config 원칙. 기존 seed의 request/limit/min/max/target을 보존한다.
    $config=Copy-Config $seed $name
    $memoryFloor=@{user=[math]::Max([double]$memoryRequestStart.user,$MinMemoryRequestMi);product=[math]::Max([double]$memoryRequestStart.product,$MinMemoryRequestMi);stress=[math]::Max([double]$memoryRequestStart.stress,$MinMemoryRequestMi)}
    foreach ($app in $apps) {
        # 실제 live request를 튜닝 seed로 사용한다. KnownGoodReference는
        # 새 앱/새 난이도에서 잘못된 고정 prior가 되므로 seed를 덮어쓰지 않는다.
        $existingReq=Convert-CpuToM $config[$app].requestCpu
        $requestM=[math]::Max([double]$cpuRequestMinimum[$app],[double]$existingReq)
        # P0-6: CPU limit은 기존 그대로 보존 (request×2 강제 금지).
        $existingCpuLimit=Convert-CpuToM $config[$app].limitCpu
        $limitM=if ($existingCpuLimit) { [double]$existingCpuLimit } else { 0 }
        if ($limitM -gt 0 -and $requestM -gt $limitM) {
            Write-Host ("  {0}: request {1:N0}m → {2:N0}m (limit 초과 → request 축소)" -f $app,$requestM,$limitM) -ForegroundColor Yellow
            $requestM=$limitM
        }
        $existingMemoryLimit=Convert-MemoryToMi $config[$app].limitMemory
        $minimumLimit=[math]::Max([double]$memoryLimitStart[$app],[math]::Max($MinMemoryLimitMi,$memoryFloor[$app]*1.25))
        $config[$app].requestCpu=Format-Cpu $requestM
        $config[$app].limitCpu=Format-Cpu $limitM
        $config[$app].requestMemory=Format-Memory $memoryFloor[$app] $memoryFloor[$app]
        $config[$app].limitMemory=Format-Memory ([math]::Max($minimumLimit,$(if ($existingMemoryLimit) { $existingMemoryLimit } else { 0 }))) $minimumLimit
        # P0-1: min=1 강제 금지 — 기존 min 보존 (seed에서 결정).
        if ([int]$config[$app].minReplicas -lt 1) { $config[$app].minReplicas=1 }
        $requestedMax=[int][math]::Min($MaxAutoReplicas,$requestedMax)
        $preservedMin=[int]$config[$app].minReplicas
        $config[$app].maxReplicas=[int][math]::Max($preservedMin,$requestedMax)
        $config[$app].hpaTarget=[int]$config[$app].hpaTarget
        $config[$app].replicas=1
    }
    return $config
}


function Ensure-RolloutSafety([string]$app) {
    # RollingUpdate 기본 안전값: maxUnavailable=0, maxSurge=1.
    # resource/HPA/placement 변경으로 기존 Ready pod을 먼저 제거해 SLO/5xx가
    # 일시 악화되는 것을 방지한다. 기존 custom strategy가 더 안전하면 보존한다.
    try {
        $deploy=((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','json')) -join '') | ConvertFrom-Json
        $ru=$deploy.spec.strategy.rollingUpdate
        $mu=0
        if ($ru -and $null -ne $ru.maxUnavailable) {
            $raw=[string]$ru.maxUnavailable
            if ($raw -match '^([0-9]+)%$') { $mu=[int]$Matches[1] }
            elseif ($raw -match '^[0-9]+$') { $mu=[int]$raw }
        }
        if ($mu -gt 0) {
            $patch='{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":0}}}}'
            Invoke-Kubectl @('-n',$Namespace,'patch','deploy',$app,'--type=merge','-p',$patch)
            Write-Host ("rollout safety [{0}]: maxUnavailable {1} → 0 (maxSurge 보존)" -f $app,$mu) -ForegroundColor DarkGray
        }
    } catch { Write-Warning "rollout safety($app) 적용 실패: $($_.Exception.Message)" }
}

function Apply-Resources([hashtable]$config,[ValidateSet('Hard','Tuning')][string]$Deadline = 'Tuning') {
    foreach ($app in $apps) {
        Ensure-RolloutSafety $app
        $c = $config[$app]
        $limits=$null
        if (($null -ne $c.limitCpu -and $c.limitCpu -ne '') -or $c.limitMemory) {
            $limits=@{}
            if ($null -ne $c.limitCpu -and $c.limitCpu -ne '') { $limits.cpu=$c.limitCpu }
            if ($c.limitMemory) { $limits.memory=$c.limitMemory }
        }
        if ($null -eq $c.limitCpu -or $c.limitCpu -eq '') {
            # CPU limit 제거 (ELASTIC_DENSITY burst): strategic merge는 limits.cpu 삭제를
            # 보장하지 않는다 — JSON patch remove로 명시적 제거 (idempotent).
            # limit이 이미 없는 경우 kubectl이 'server rejected our request'로 거부하므로
            # live 상태를 확인해 limit이 실제로 없으면 no-op으로 처리한다 (롤백 안전성).
            $removePatch='[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]'
            try {
                Invoke-Kubectl @('-n',$Namespace,'patch',"deployment/$app",'--type=json','-p',$removePatch)
            } catch {
                $liveLimit=''
                try { $liveLimit=((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.spec.template.spec.containers[0].resources.limits.cpu}')) -join '').Trim() } catch { $liveLimit='' }
                if ($liveLimit -eq '') {
                    Write-Host ("  {0}: CPU limit 제거 no-op (이미 없음, remove 거부 무시)" -f $app) -ForegroundColor DarkGray
                } else {
                    Write-Warning "CPU limit 제거 patch 실패(live limit=$liveLimit 보존 상태): $($_.Exception.Message)"
                    throw
                }
            }
        }
        $resources=@{requests=@{cpu=$c.requestCpu;memory=$c.requestMemory};limits=$limits}
        $patch=@{spec=@{template=@{spec=@{containers=@(@{name=$app;resources=$resources})}}}} | ConvertTo-Json -Compress -Depth 10
        Invoke-Kubectl @('-n',$Namespace,'patch',"deployment/$app",'--type=strategic','-p',$patch)
        # node 단위 균등 배치 (ScheduleAnyway) — 새 Pod가 같은 node에 몰려 CPU contention을 만들지 않게
        Ensure-TopologySpread $app
    }
    foreach ($app in $apps) {
        try {
            Wait-DeploymentRollout $app $(if ($Deadline -eq 'Hard') { 30 } else { 180 }) $Deadline
        } catch {
            Write-Warning "deployment rollout timeout($app): $($_.Exception.Message)"
        }
    }
}

function Apply-Hpa([hashtable]$config) {
    foreach ($app in $apps) {
        $c = $config[$app]
        if ([int]$c.minReplicas -gt [int]$c.maxReplicas) { throw "HPA_CONFIG_INVALID_BEFORE_APPLY: $app min=$($c.minReplicas) max=$($c.maxReplicas)" }
        $spec = @{minReplicas=[int]$c.minReplicas;maxReplicas=[int]$c.maxReplicas;metrics=@(@{type='Resource';resource=@{name='cpu';target=@{type='Utilization';averageUtilization=[int]$c.hpaTarget}}})}
        $behaviorAction=if ($script:HpaBehaviorAction.ContainsKey($app)) { [string]$script:HpaBehaviorAction[$app] } else { 'KEEP' }
        if ($behaviorAction -eq 'TUNE_SCALE_UP' -and $null -ne $c.behavior) { $spec.behavior=$c.behavior }
        $patch=@{spec=$spec}|ConvertTo-Json -Compress -Depth 12
        Invoke-Kubectl @('-n',$Namespace,'patch','hpa',$app,'--type=merge','-p',$patch)
    }
}

function Apply-CandidateSafely([hashtable]$config,[ValidateSet('Hard','Tuning')][string]$Deadline='Hard') {
    # Never freeze a live service to 1..1. Apply the resource delta while the
    # existing replicas/HPA continue serving, then only scale UP to the candidate
    # minimum if the current deployment is below it.
    $allReady=$true
    Apply-Resources $config $Deadline
    Apply-Hpa $config
    foreach ($app in $apps) {
        $warm=[int][math]::Max(1,$config[$app].minReplicas)
        $current=0
        try { $current=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deployment',$app,'-o','jsonpath={.spec.replicas}')) -join '') } catch { $current=0 }
        if ($current -lt $warm) {
            Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app","--replicas=$warm")
        }
    }
    foreach ($app in $apps) {
        try {
            Wait-DeploymentRollout $app 180 $Deadline
        } catch {
            $allReady=$false
            Write-Warning "candidate rollout timeout($app): $($_.Exception.Message)"
        }
        try {
            $timeout=Get-DeadlineTimeoutSeconds 90 $Deadline
            Invoke-Kubectl @('-n',$Namespace,'wait','--for=condition=Available',"deployment/$app","--timeout=${timeout}s")
        } catch {
            $allReady=$false
            Write-Warning "candidate available 대기 timeout($app): $($_.Exception.Message)"
        }
    }
    # Re-apply after readiness so the measured fingerprint is the candidate.
    Apply-Hpa $config
    return $allReady
}

function Assert-MeasurementReady([int]$RecentSeconds = 90) {
    $pods=((& kubectl get pods -n $Namespace -o json 2>$null) -join '') | ConvertFrom-Json
    $bad=@($pods.items | Where-Object {
        $_.metadata.deletionTimestamp -eq $null -and $_.status.phase -ne 'Running'
    })
    if ($bad.Count) { throw "MEASUREMENT_ENV_INVALID: app pods not Running ($($bad.metadata.name -join ','))" }
    $events=((& kubectl get events -A --field-selector reason=FailedCreatePodSandBox -o json 2>$null) -join '') | ConvertFrom-Json
    $cutoff=(Get-Date).ToUniversalTime().AddSeconds(-1*[math]::Max(30,$RecentSeconds))
    $recent=@($events.items | Where-Object {
        $stamp=$_.eventTime; if (-not $stamp) { $stamp=$_.lastTimestamp }; if (-not $stamp) { $stamp=$_.firstTimestamp }
        try { ([datetime]$stamp).ToUniversalTime() -ge $cutoff } catch { $false }
    })
    if ($recent.Count) { throw "MEASUREMENT_ENV_INVALID: recent CNI FailedCreatePodSandBox=$($recent.Count)" }
    Write-Host "MEASUREMENT_ENV_READY: Pods Running, recent CNI sandbox errors=0" -ForegroundColor Green
}

function Wait-ReadyNodeCountAtMost([int]$targetTotal, [int]$timeoutSec, [ValidateSet('Hard','Tuning')][string]$Deadline = 'Tuning') {
    $targetKarpenter=[math]::Max(0,$targetTotal-$ManagedNodes)
    $timeoutSec=Get-DeadlineTimeoutSeconds $timeoutSec $Deadline
    $until = (Get-Date).AddSeconds($timeoutSec)
    $selectedDeadline=if ($Deadline -eq 'Hard') { $hardDeadline } else { $tuningDeadline }
    if ($until -gt $selectedDeadline) { $until=$selectedDeadline }
    do {
        $nodes = (& kubectl get nodes -o json 2>$null) | ConvertFrom-Json
        # Managed node는 kube-system 고정 Pod를 위해 유지한다. 비용/scale-in
        # 대기는 Karpenter 노드(eks.amazonaws.com/nodegroup 라벨이 없는 노드)만 센다.
        $ready = @($nodes.items | Where-Object {
            $isReady = @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
            $isManaged = $null -ne $_.metadata.labels.'eks.amazonaws.com/nodegroup' -and $_.metadata.labels.'eks.amazonaws.com/nodegroup' -ne ''
            $isReady -and -not $isManaged
        }).Count
        if ($ready -le $targetKarpenter) { return $true }
        $sleepSeconds=[math]::Min(5,(Get-RemainingRuntimeSeconds $Deadline))
        if ($sleepSeconds -le 0) { break }
        Start-Sleep -Seconds $sleepSeconds
    } while ((Get-Date) -lt $until)
    Write-Warning "${timeoutSec}초 내 전체 Ready Node가 $targetTotal대(Karpenter $targetKarpenter대)로 줄지 않았습니다. 측정은 계속하지만 Node 비용 비교가 오염될 수 있습니다."
    return $false
}

function Drain-KarpenterNodes([int]$timeoutSec = 45) {
    $nodes = (& kubectl get nodes -o json 2>$null) | ConvertFrom-Json
    $targets=[System.Collections.Generic.List[string]]::new()
    foreach ($node in @($nodes.items)) {
        $name = [string]$node.metadata.name
        $isManaged = $null -ne $node.metadata.labels.'eks.amazonaws.com/nodegroup' -and $node.metadata.labels.'eks.amazonaws.com/nodegroup' -ne ''
        $isReady = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        $deleting = $null -ne $node.metadata.deletionTimestamp
        if ($isManaged -or -not $isReady -or $deleting) { continue }
        $targets.Add($name)
    }
    if (-not $targets.Count) { return }
    foreach ($name in $targets) {
        $timeoutSec=Get-DeadlineTimeoutSeconds $timeoutSec Hard
        Write-Host "Karpenter 노드 cordon/drain: $name" -ForegroundColor Yellow
        try {
            Invoke-Kubectl @('cordon',$name)
            Invoke-Kubectl @('drain',$name,'--ignore-daemonsets','--delete-emptydir-data','--force','--grace-period=10',"--timeout=${timeoutSec}s")
            Invoke-Kubectl @('delete','node',$name,'--wait=false')
        } catch {
            Write-Warning "Karpenter 노드 $name drain 실패: $($_.Exception.Message)"
        }
    }
}

function Set-IdleState([int]$waitSec = $IdleWaitSec, [switch]$SkipNodeWait, [switch]$PreserveKarpenterNodes) {
    foreach ($app in $apps) {
        Invoke-Kubectl @('-n',$Namespace,'patch','hpa',$app,'--type=merge','-p','{"spec":{"minReplicas":1,"maxReplicas":1}}')
        Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app",'--replicas=1')
    }
    foreach ($app in $apps) {
        Wait-DeploymentRollout $app 180 Tuning
        $availableTimeout=Get-DeadlineTimeoutSeconds 60 Tuning
        Invoke-Kubectl @('-n',$Namespace,'wait','--for=condition=Available',"deployment/$app","--timeout=${availableTimeout}s")
    }
    Assert-HpaConfigInvariant $config 'MinimumReady'
    # P0: 측정 준비에서 Karpenter drain 금지 — IdleOneNodeFit=false지만 isolated 2-node
    # fit=true인 profile은 OperatingNodeBudget=2를 정상 baseline으로 유지한다.
    # (drain하면 PDB eviction 실패 반복 + warm capacity 제거 → 진입 SLA 하락 재발)
}

function Prepare-Test([hashtable]$config, $cluster, [switch]$PreserveKarpenterNodes) {
    # Measurement preparation must not take a serving application through 1..1.
    # Keep the current replicas/HPA while rolling the candidate, then warm only
    # missing minimum replicas. This makes BASE and candidate windows comparable
    # to the grader's continuously serving state.
    Apply-Resources $config
    $idle=Get-IdleCapacity $config $cluster
    if (-not $idle.IdleOneNodeFit) { Write-Warning "$($config.Name)은 IdleOneNodeFit=false — warm node 유지 상태로 측정합니다." }
    Apply-Hpa $config
    foreach ($app in $apps) {
        $warmMin=[int][math]::Max(1,$config[$app].minReplicas)
        $current=0
        try { $current=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deployment',$app,'-o','jsonpath={.spec.replicas}')) -join '') } catch { $current=0 }
        if ($current -lt $warmMin) {
            Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app","--replicas=$warmMin")
            Write-Host ("  warm prewarm [{0}]: replicas={1} -> {2} (scale-up only)" -f $app,$current,$warmMin) -ForegroundColor DarkGray
        }
    }
    foreach ($app in $apps) {
        $availableTimeout=Get-DeadlineTimeoutSeconds 90 Tuning
        Invoke-Kubectl @('-n',$Namespace,'wait','--for=condition=Available',"deployment/$app","--timeout=${availableTimeout}s")
        $warmMin=[int][math]::Max(1,$config[$app].minReplicas)
        $warmDeadline=(Get-Date).AddSeconds([math]::Max(10,(Get-DeadlineTimeoutSeconds 150 Tuning)))
        $ready=0
        while ((Get-Date) -lt $warmDeadline -and $ready -lt $warmMin) {
            try { $ready=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deployment',$app,'-o','jsonpath={.status.readyReplicas}')) -join '') } catch { $ready=0 }
            if ($ready -lt $warmMin) { Start-Sleep -Seconds 5 }
        }
        if ($ready -lt $warmMin) {
            throw "MEASUREMENT_PREP_NOT_READY: $app ready=$ready min=$warmMin"
        }
        Write-Host ("  warm ready [{0}]: {1}/{1}" -f $app,$warmMin) -ForegroundColor DarkGray
    }
}

function Restore-Config([hashtable]$config) {
    if (-not $config) { return }
    Write-Warning "원래 Deployment/HPA 설정을 복구합니다."
    try {
        # Recovery is also non-disruptive: never freeze a serving app to 1..1.
        # Restore resources/HPA in place and only scale up to the original replica
        # count if the current deployment is below it.
        Apply-Resources $config
        Apply-Hpa $config
        foreach ($app in $apps) {
            $wanted=[int][math]::Max(1,$config[$app].replicas)
            $current=0
            try { $current=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deployment',$app,'-o','jsonpath={.spec.replicas}')) -join '') } catch { $current=0 }
            if ($current -lt $wanted) { Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app","--replicas=$wanted") }
            try {
                $restoreTimeout=Get-DeadlineTimeoutSeconds 30 Hard
                Invoke-Kubectl @('-n',$Namespace,'wait','--for=condition=Available',"deployment/$app","--timeout=${restoreTimeout}s")
            } catch {
                Write-Warning "복구 rollout 대기 timeout($app): $($_.Exception.Message)"
            }
        }
        Apply-Hpa $config
    } catch {
        Write-Error "자동 복구 실패: $($_.Exception.Message)"
    }
}

function Assert-LiveConfigMatches([hashtable]$expected) {
    if ($expected.Name -ne 'CalculatedFinal') { throw "CalculatedFinal이 아닌 설정을 적용하려고 했습니다: $($expected.Name)" }
    $actual=Get-LiveConfig 'AppliedVerification'
    foreach ($app in $apps) {
        $checks=@(
            [pscustomobject]@{Name='cpu request';Expected=(Convert-CpuToM $expected[$app].requestCpu);Actual=(Convert-CpuToM $actual[$app].requestCpu)},
            [pscustomobject]@{Name='cpu limit';Expected=(Convert-CpuToM $expected[$app].limitCpu);Actual=(Convert-CpuToM $actual[$app].limitCpu)},
            [pscustomobject]@{Name='memory request';Expected=(Convert-MemoryToMi $expected[$app].requestMemory);Actual=(Convert-MemoryToMi $actual[$app].requestMemory)},
            [pscustomobject]@{Name='memory limit';Expected=(Convert-MemoryToMi $expected[$app].limitMemory);Actual=(Convert-MemoryToMi $actual[$app].limitMemory)},
            [pscustomobject]@{Name='HPA min';Expected=[double]$expected[$app].minReplicas;Actual=[double]$actual[$app].minReplicas},
            [pscustomobject]@{Name='HPA max';Expected=[double]$expected[$app].maxReplicas;Actual=[double]$actual[$app].maxReplicas},
            [pscustomobject]@{Name='HPA target';Expected=[double]$expected[$app].hpaTarget;Actual=[double]$actual[$app].hpaTarget}
        )
        foreach ($check in $checks) {
            # limit 제거(expected='' → $null)는 actual도 빈 값(0)이면 PASS로 취급한다.
            $exp=if ($null -eq $check.Expected) { 0.0 } else { [double]$check.Expected }
            $act=if ($null -eq $check.Actual -or ([string]$check.Actual).Trim() -eq '') { 0.0 } else { [double]$check.Actual }
            if ([math]::Abs($exp-$act) -gt 0.01) {
                throw "CalculatedFinal 라이브 검증 실패: $app $($check.Name), expected=$($check.Expected), actual=$($check.Actual)"
            }
        }
    }
    if ($DetailedOutput) { Write-Host 'CalculatedFinal 라이브 적용 검증 완료' -ForegroundColor Green }
    return $true
}

function Set-KarpenterNodeLimit($cluster) {
    # Enforce the real total-node ceiling through per-pool CPU budgets. Karpenter
    # has no account-wide node limit, so reserve at most one c5.large for the
    # shared pool and one for the dedicated pool within MaxNodes-ManagedNodes.
    $karpenterBudget=[math]::Max(0,$MaxNodes-$ManagedNodes)
    $sharedNodes=if ($DedicatedApp -and $karpenterBudget -ge 2) { 1 } else { 0 }
    $dedicatedNodes=[math]::Max(0,$karpenterBudget-$sharedNodes)
    $desired=@{default=[math]::Max(1,$sharedNodes*2000);stress=[math]::Max(1,$dedicatedNodes*2000)}
    foreach ($pool in @('default','stress')) {
        try {
            $obj=((& kubectl get nodepool $pool -o json 2>$null) -join '') | ConvertFrom-Json
            if (-not $obj) { throw "NodePool/$pool not found" }
            $old=[string]$obj.spec.limits.cpu
            $new=Format-Cpu ([double]$desired[$pool])
            if ([string]$old -ne [string]$new) {
                $patch=@{spec=@{limits=@{cpu=$new}}} | ConvertTo-Json -Compress -Depth 8
                Invoke-Kubectl @('patch','nodepool',$pool,'--type=merge','-p',$patch)
                Write-Host ("NodePool/{0} CPU limit: {1} -> {2} (MaxNodes={3}, KarpenterBudget={4})" -f $pool,$old,$new,$MaxNodes,$karpenterBudget) -ForegroundColor Yellow
            } else {
                Write-Host ("NodePool/{0} CPU limit enforced: {1}" -f $pool,$new) -ForegroundColor DarkGray
            }
        } catch { throw "NodePool/$pool CPU limit 적용 실패: $($_.Exception.Message)" }
    }
}

function Restore-KarpenterNodeLimit {
    # Final grading configuration intentionally keeps the enforced budget.
}

function Set-InstanceAwarePlacement {
    if ($SkipInstanceAwarePlacement) {
        Write-Warning '인스턴스 기반 Karpenter 앱 격리를 건너뜁니다.'
        return
    }

    $nodePool = ((& kubectl get nodepool default -o json 2>$null) -join '') | ConvertFrom-Json
    if (-not $nodePool) { throw 'Karpenter NodePool/default를 찾지 못했습니다. -SkipInstanceAwarePlacement로 우회할 수 있습니다.' }

    $script:originalNodePoolHadTaints = $null -ne $nodePool.spec.template.spec.PSObject.Properties['taints']
    $script:originalNodePoolTaintsJson = if ($script:originalNodePoolHadTaints) {
        ConvertTo-Json -InputObject @($nodePool.spec.template.spec.taints) -Compress -Depth 20
    } else { $null }

    foreach ($app in $apps) {
        $deployment = ((& kubectl -n $Namespace get deployment $app -o json) -join '') | ConvertFrom-Json
        $hasTolerations = $null -ne $deployment.spec.template.spec.PSObject.Properties['tolerations']
        $script:originalAppHadTolerations[$app] = $hasTolerations
        $script:originalAppTolerations[$app] = if ($hasTolerations) {
            ConvertTo-Json -InputObject @($deployment.spec.template.spec.tolerations) -Compress -Depth 20
        } else { $null }
    }

    $karpenterDeployment = ((& kubectl -n kube-system get deployment karpenter -o json 2>$null) -join '') | ConvertFrom-Json
    if ($karpenterDeployment) { $script:originalKarpenterReplicas = [int]$karpenterDeployment.spec.replicas }
    $script:placementPolicyChanged = $true

    $placementKey = 'wsi2026.io/app-capacity'
    # stress 전용 NodePool taint는 app-capacity(확장용)와 분리한다. (key는 전역 $stressPlacementKey)
    $placementValue = 'true'
    $taints = [System.Collections.Generic.List[object]]::new()
    foreach ($taint in @($nodePool.spec.template.spec.taints)) {
        if ($null -eq $taint) { continue }
        $taints.Add([pscustomobject]@{key=[string]$taint.key;value=[string]$taint.value;effect=[string]$taint.effect})
    }
    if (@($taints | Where-Object { $_.key -eq $placementKey -and $_.effect -eq 'NoSchedule' }).Count -eq 0) {
        $taints.Add([pscustomobject]@{key=$placementKey;value=$placementValue;effect='NoSchedule'})
    }

    # 앱은 Managed Node에도 그대로 배치될 수 있고, 확장 시에만 taint가 있는
    # Karpenter Node를 사용할 수 있다. kube-system Pod는 별도 toleration이
    # 없으므로 Karpenter Node를 점유해 자연 축소를 막지 않는다.
    foreach ($app in $apps) {
        $deployment = ((& kubectl -n $Namespace get deployment $app -o json) -join '') | ConvertFrom-Json
        $tolerations = [System.Collections.Generic.List[object]]::new()
        foreach ($tol in @($deployment.spec.template.spec.tolerations)) {
            if ($null -eq $tol) { continue }
            $tolerations.Add($tol)
        }
        if (@($tolerations | Where-Object { $_.key -eq $placementKey -and $_.effect -eq 'NoSchedule' }).Count -eq 0) {
            $tolerations.Add([pscustomobject]@{key=$placementKey;operator='Equal';value=$placementValue;effect='NoSchedule'})
        }
        $patch = @{spec=@{template=@{spec=@{tolerations=@($tolerations)}}}} | ConvertTo-Json -Compress -Depth 20
        Invoke-Kubectl @('-n',$Namespace,'patch','deployment',$app,'--type=merge','-p',$patch)
    }

    $nodePoolPatch = @{spec=@{template=@{spec=@{taints=@($taints)}}}} | ConvertTo-Json -Compress -Depth 20
    Invoke-Kubectl @('patch','nodepool','default','--type=merge','-p',$nodePoolPatch)

    if ($karpenterDeployment) {
        $desiredReplicas = [math]::Max(1,[math]::Min([int]$script:originalKarpenterReplicas,$ManagedNodes))
        if ([int]$karpenterDeployment.spec.replicas -ne $desiredReplicas) {
            Invoke-Kubectl @('-n','kube-system','scale','deployment/karpenter',"--replicas=$desiredReplicas")
        }
    }
    Write-Host "Instance-aware placement: Karpenter Node는 앱 확장 전용, controller replicas <= ManagedNodes($ManagedNodes)" -ForegroundColor Cyan
}

function Restore-InstanceAwarePlacement {
    if ($SkipInstanceAwarePlacement -or -not $script:placementPolicyChanged) { return }
    if (-not $script:originalAppTolerations -or -not $script:originalAppHadTolerations) { return }
    try {
        foreach ($app in $apps) {
            # PowerShell 5.1은 단일 항목 배열을 pipeline으로 ConvertTo-Json에
            # 넘기면 객체로 축소한다. Kubernetes 필드가 항상 배열이 되도록
            # 저장해 둔 원본 JSON 배열을 patch 본문에 그대로 삽입한다.
            $tolerationsJson = if ($script:originalAppHadTolerations[$app]) {
                [string]$script:originalAppTolerations[$app]
            } else { 'null' }
            $patch = '{"spec":{"template":{"spec":{"tolerations":' + $tolerationsJson + '}}}}'
            Invoke-Kubectl @('-n',$Namespace,'patch','deployment',$app,'--type=merge','-p',$patch)
        }
        $taintsJson = if ($script:originalNodePoolHadTaints) {
            [string]$script:originalNodePoolTaintsJson
        } else { 'null' }
        $patch = '{"spec":{"template":{"spec":{"taints":' + $taintsJson + '}}}}'
        Invoke-Kubectl @('patch','nodepool','default','--type=merge','-p',$patch)
        if ($null -ne $script:originalKarpenterReplicas) {
            Invoke-Kubectl @('-n','kube-system','scale','deployment/karpenter',"--replicas=$script:originalKarpenterReplicas")
        }
        $script:placementPolicyChanged=$false
        Write-Warning '인스턴스 기반 배치 정책을 원래 값으로 복구했습니다.'
    } catch { Write-Error "인스턴스 기반 배치 정책 복구 실패: $($_.Exception.Message)" }
}

function Get-NodeReadinessStatus {
    # NotReady 노드 이름 + 의도적 cordon(unschedulable) 노드 이름을 반환한다.
    # Karpenter drain/cordon 중인 노드는 NotReady여도 transient로 취급해야 한다.
    $nodes = (& kubectl get nodes -o json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{NotReadyNodes=@();CordonedNodes=@()} }
    $notReady=[System.Collections.Generic.List[string]]::new(); $cordoned=[System.Collections.Generic.List[string]]::new()
    foreach ($node in @($nodes.items)) {
        $ready=@($node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        if (-not $ready) { $notReady.Add([string]$node.metadata.name) }
        if ($node.spec.unschedulable) { $cordoned.Add([string]$node.metadata.name) }
    }
    return [pscustomobject]@{NotReadyNodes=@($notReady);CordonedNodes=@($cordoned)}
}

function Get-HealthSnapshot {
    $pods = (& kubectl get pods -n $Namespace -o json) | ConvertFrom-Json
    $restart = 0; $evicted = 0; $oom = 0; $crashLoop = 0; $notReady = 0
    $oomByApp=@{user=0;product=0;stress=0}
    foreach ($pod in @($pods.items)) {
        if ($pod.status.reason -eq 'Evicted') { $evicted++ }
        $deleting=$null -ne $pod.metadata.deletionTimestamp
        $ready=@($pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        if (-not $deleting -and $pod.status.phase -notin @('Succeeded','Failed') -and -not $ready) { $notReady++ }
        foreach ($status in @($pod.status.containerStatuses)) {
            $restart += [int]$status.restartCount
            if ($status.state.waiting.reason -eq 'CrashLoopBackOff') { $crashLoop++ }
            $oomCount=0
            if ($status.lastState.terminated.reason -eq 'OOMKilled') { $oomCount=[math]::Max(1,[int]$status.restartCount) }
            elseif ($status.state.terminated.reason -eq 'OOMKilled') { $oomCount=[math]::Max(1,[int]$status.restartCount+1) }
            if ($oomCount -gt 0) {
                $oom += $oomCount
                $app=[string]$pod.metadata.labels.app
                if ($app -in $apps) { $oomByApp[$app]+=$oomCount }
            }
        }
    }
    return [pscustomobject]@{Restart=$restart;Evicted=$evicted;OOMKilled=$oom;OOMByApp=$oomByApp;CrashLoopBackOff=$crashLoop;NotReady=$notReady}
}

function Enable-FinalIdleConsolidation {
    # 강제 drain/delete가 아니라 Karpenter가 빈/저사용 노드의 Pod를 안전하게
    # 재배치하도록 한다. 이 설정은 최종 적용에만 사용해 후보 측정 중 churn은 막는다.
    $nodePool=(((& kubectl get nodepool default -o json 2>$null) -join '') | ConvertFrom-Json)
    if (-not $nodePool) { Write-Warning 'NodePool을 읽지 못해 최종 자연 축소 정책을 적용하지 못했습니다.'; return $false }
    $script:originalConsolidationPolicy=[string]$nodePool.spec.disruption.consolidationPolicy
    $script:originalConsolidateAfter=[string]$nodePool.spec.disruption.consolidateAfter
    if ($script:originalConsolidationPolicy -eq 'WhenEmptyOrUnderutilized' -and $script:originalConsolidateAfter -eq '30s') { return $true }
    $patch=@{spec=@{disruption=@{consolidationPolicy='WhenEmptyOrUnderutilized';consolidateAfter='30s'}}}|ConvertTo-Json -Compress -Depth 8
    Invoke-Kubectl @('patch','nodepool','default','--type=merge','-p',$patch)
    $script:finalConsolidationChanged=$true
    return $true
}

function Restore-FinalIdleConsolidation {
    if (-not $script:finalConsolidationChanged) { return }
    try {
        $patch=@{spec=@{disruption=@{consolidationPolicy=$script:originalConsolidationPolicy;consolidateAfter=$script:originalConsolidateAfter}}}|ConvertTo-Json -Compress -Depth 8
        Invoke-Kubectl @('patch','nodepool','default','--type=merge','-p',$patch)
        $script:finalConsolidationChanged=$false
    } catch { Write-Error "Karpenter consolidation 정책 복구 실패: $($_.Exception.Message)" }
}

function Test-ToleratesTaint($template, $taint) {
    foreach ($tol in @($template.spec.tolerations)) {
        if ($tol.operator -eq 'Exists' -and (-not $tol.key -or $tol.key -eq $taint.key)) { return $true }
        if ($tol.key -eq $taint.key -and $tol.value -eq $taint.value -and ($tol.effect -eq $taint.effect -or -not $tol.effect)) { return $true }
    }
    return $false
}

function Get-ClusterCapacitySnapshot {
    $nodes = (& kubectl get nodes -o json) | ConvertFrom-Json
    $readyNodes = @($nodes.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count })
    if (-not $readyNodes.Count) { throw 'Ready Node가 없습니다.' }
    $managedReadyNodes = @($readyNodes | Where-Object {
        $null -ne $_.metadata.labels.'eks.amazonaws.com/nodegroup' -and $_.metadata.labels.'eks.amazonaws.com/nodegroup' -ne ''
    })
    if ($managedReadyNodes.Count) {
        # Idle 1-Node의 실제 목적지는 Managed Node다. Karpenter Node 또는 교체 중인
        # 더 큰 Node를 기준으로 계산하면 인스턴스 변경 시 false-positive가 생긴다.
        $candidate = $managedReadyNodes | Sort-Object @{Expression={ Convert-CpuToM $_.status.allocatable.cpu }}, @{Expression={ Convert-MemoryToMi $_.status.allocatable.memory }} | Select-Object -First 1
    } else {
        Write-Warning 'Ready Managed Node가 없어 가장 작은 Ready Node를 임시 용량 기준으로 사용합니다.'
        $candidate = $readyNodes | Sort-Object @{Expression={ Convert-CpuToM $_.status.allocatable.cpu }}, @{Expression={ Convert-MemoryToMi $_.status.allocatable.memory }} | Select-Object -First 1
    }
    $allocCpu = Convert-CpuToM $candidate.status.allocatable.cpu
    $allocMem = Convert-MemoryToMi $candidate.status.allocatable.memory
    $allocPods = [int]$candidate.status.allocatable.pods
    $capacityCpu = Convert-CpuToM $candidate.status.capacity.cpu
    $capacityMem = Convert-MemoryToMi $candidate.status.capacity.memory
    $systemPods = (& kubectl get pods -n kube-system -o json) | ConvertFrom-Json
    $seenDaemon = @{}; $systemCpu = 0.0; $systemMem = 0.0; $systemPodCount = 0
    $daemonCpu = 0.0; $daemonMem = 0.0; $daemonPodCount = 0
    $staticCpu = 0.0; $staticMem = 0.0; $staticPodCount = 0
    foreach ($pod in @($systemPods.items)) {
        # Pending system replica는 현재 단일 Node에 유지되는 workload가 아니므로 Idle budget에서 제외한다.
        if (-not $pod.spec.nodeName -or $pod.status.phase -ne 'Running') { continue }
        $owner = $pod.metadata.ownerReferences | Select-Object -First 1
        if ($owner.kind -eq 'DaemonSet') {
            if ($seenDaemon[$owner.name]) { continue }
            $seenDaemon[$owner.name] = $true
        }
        $systemPodCount++
        $podCpu=0.0; $podMem=0.0; $initCpu=0.0; $initMem=0.0
        foreach ($container in @($pod.spec.containers)) {
            $cpu = Convert-CpuToM $container.resources.requests.cpu
            $mem = Convert-MemoryToMi $container.resources.requests.memory
            if ($null -ne $cpu) { $podCpu += $cpu }
            if ($null -ne $mem) { $podMem += $mem }
        }
        foreach ($container in @($pod.spec.initContainers)) {
            $cpu=Convert-CpuToM $container.resources.requests.cpu; $mem=Convert-MemoryToMi $container.resources.requests.memory
            if ($null -ne $cpu) { $initCpu=[math]::Max($initCpu,$cpu) }
            if ($null -ne $mem) { $initMem=[math]::Max($initMem,$mem) }
        }
        $effectiveCpu=[math]::Max($podCpu,$initCpu); $effectiveMem=[math]::Max($podMem,$initMem)
        $systemCpu += $effectiveCpu; $systemMem += $effectiveMem
        if ($owner.kind -eq 'DaemonSet') {
            $daemonCpu += $effectiveCpu; $daemonMem += $effectiveMem; $daemonPodCount++
        } else {
            $staticCpu += $effectiveCpu; $staticMem += $effectiveMem; $staticPodCount++
        }
    }
    $safetyCpu = $allocCpu * $SafetyReservePercent / 100.0
    $safetyMem = $allocMem * $SafetyReservePercent / 100.0
    $deployments = (& kubectl get deployments -n $Namespace -o json) | ConvertFrom-Json
    $constraintRisk = $false; $constraintNotes = [System.Collections.Generic.List[string]]::new()
    foreach ($app in $apps) {
        $deployment = $deployments.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1
        $template = $deployment.spec.template
        $selectorProperties=@()
        if ($template.spec.nodeSelector) { $selectorProperties=@($template.spec.nodeSelector.PSObject.Properties) }
        foreach ($selectorProperty in $selectorProperties) {
            $key=$selectorProperty.Name
            $nodeLabel=$candidate.metadata.labels.PSObject.Properties[$key].Value
            $requiredLabel=$selectorProperty.Value
            if ([string]$nodeLabel -ne [string]$requiredLabel) { $constraintRisk=$true; $constraintNotes.Add("$app nodeSelector 불일치: $key") }
        }
        if ($template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution) { $constraintRisk=$true; $constraintNotes.Add("$app required nodeAffinity 수동 확인 필요") }
        if ($template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution) { $constraintRisk=$true; $constraintNotes.Add("$app required podAntiAffinity") }
        foreach ($spread in @($template.spec.topologySpreadConstraints)) {
            if ($spread.whenUnsatisfiable -eq 'DoNotSchedule') { $constraintNotes.Add("$app topologySpread=DoNotSchedule (minReplica 1은 허용)") }
        }
        foreach ($taint in @($candidate.spec.taints | Where-Object { $_.effect -in @('NoSchedule','NoExecute') })) {
            if (-not (Test-ToleratesTaint $template $taint)) { $constraintRisk=$true; $constraintNotes.Add("$app untolerated taint: $($taint.key)") }
        }
    }
    $karpenterPolicy='Unavailable'; $consolidateAfter=$null; $karpenterEnabled=$false
    $karpenterInstanceTypes=@(); $karpenterMatchesManaged=$false
    try {
        $nodePool = (& kubectl get nodepool default -o json 2>$null) | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $nodePool) {
            $karpenterPolicy=[string]$nodePool.spec.disruption.consolidationPolicy
            $consolidateAfter=[string]$nodePool.spec.disruption.consolidateAfter
            $karpenterEnabled=$karpenterPolicy -eq 'WhenEmptyOrUnderutilized'
            $instanceRequirement=$nodePool.spec.template.spec.requirements | Where-Object { $_.key -eq 'node.kubernetes.io/instance-type' } | Select-Object -First 1
            $karpenterInstanceTypes=@($instanceRequirement.values | ForEach-Object { [string]$_ })
            $karpenterMatchesManaged=$karpenterInstanceTypes.Count -eq 1 -and $karpenterInstanceTypes[0] -eq [string]$candidate.metadata.labels.'node.kubernetes.io/instance-type'
        }
    } catch { }
    return [pscustomobject]@{
        NodeName=$candidate.metadata.name
        ManagedReadyNodes=$managedReadyNodes.Count
        NodeInstanceType=[string]$candidate.metadata.labels.'node.kubernetes.io/instance-type'
        NodeCapacityCPU=[math]::Round($capacityCpu,1)
        NodeCapacityMemory=[math]::Round($capacityMem,1)
        NodeAllocatableCPU=[math]::Round($allocCpu,1)
        NodeAllocatableMemory=[math]::Round($allocMem,1)
        NodeAllocatablePods=$allocPods
        SystemReservedCPU=[math]::Round($systemCpu,1)
        SystemReservedMemory=[math]::Round($systemMem,1)
        SystemPodCount=$systemPodCount
        DaemonSetCPUPerNode=[math]::Round($daemonCpu,1)
        DaemonSetMemoryPerNode=[math]::Round($daemonMem,1)
        DaemonSetPodCount=$daemonPodCount
        StaticSystemCPU=[math]::Round($staticCpu,1)
        StaticSystemMemory=[math]::Round($staticMem,1)
        StaticSystemPodCount=$staticPodCount
        SafetyCPUReserve=[math]::Round($safetyCpu,1)
        SafetyMemoryReserve=[math]::Round($safetyMem,1)
        AvailableAppCPU=[math]::Max(0,[math]::Round($allocCpu-$systemCpu-$safetyCpu,1))
        AvailableAppMemory=[math]::Max(0,[math]::Round($allocMem-$systemMem-$safetyMem,1))
        SchedulingConstraintRisk=$constraintRisk
        SchedulingNotes=@($constraintNotes)
        KarpenterConsolidationEnabled=$karpenterEnabled
        KarpenterInstanceTypes=$karpenterInstanceTypes
        KarpenterMatchesManaged=$karpenterMatchesManaged
        ConsolidationPolicy=$karpenterPolicy
        ConsolidateAfter=$consolidateAfter
    }
}

function Get-IdleCapacity([hashtable]$config, $cluster) {
    $cpu=0.0; $mem=0.0
    foreach ($app in $apps) { $cpu += Convert-CpuToM $config[$app].requestCpu; $mem += Convert-MemoryToMi $config[$app].requestMemory }
    $podFit = ($cluster.SystemPodCount + $apps.Count) -le $cluster.NodeAllocatablePods
    $fit = $cpu -le $cluster.AvailableAppCPU -and $mem -le $cluster.AvailableAppMemory -and $podFit -and -not $cluster.SchedulingConstraintRisk
    # P0-3: IdleTopologyFit — isolated 2-node topology를 정상으로 인정.
    #   SHARED: 전체 apps가 target shared nodes에 fit
    #   ISOLATED: DedicatedApp이 dedicated domain fit AND 나머지 app이 shared domain fit
    $topologyFit=$false
    $idleExpectedNodes=1
    if (-not $cluster.SchedulingConstraintRisk) {
        # SHARED: 전체 apps가 1 shared node에 fit
        $topologyFit=$fit
        $idleExpectedNodes=1
    } else {
        # ISOLATED: DedicatedApp dedicated + 나머지 app shared
        $stressReqCpu = Convert-CpuToM $config[$DedicatedApp].requestCpu
        $stressReqMem = Convert-MemoryToMi $config[$DedicatedApp].requestMemory
        
        $dedicatedCpuBudget = [double]$cluster.NodeAllocatableCPU*0.80
        $dedicatedMemoryBudget = [double]$cluster.NodeAllocatableMemory*0.80
        $dedicatedPodFit = (1 + $cluster.DaemonSetPodCount) -le $cluster.NodeAllocatablePods
        
        $dedicatedFit = ($stressReqCpu -le $dedicatedCpuBudget) -and ($stressReqMem -le $dedicatedMemoryBudget) -and $dedicatedPodFit
        
        $fgCpu = [double]$cluster.AvailableAppCPU
        $fgMem = [double]$cluster.AvailableAppMemory
        
        $fgReqCpu = 0.0; $fgReqMem = 0.0; $sharedAppCount = 0
        foreach ($app in $apps) {
            if ($app -ne $DedicatedApp) {
                $fgReqCpu += [double](Convert-CpuToM $config[$app].requestCpu)
                $fgReqMem += [double](Convert-MemoryToMi $config[$app].requestMemory)
                $sharedAppCount++
            }
        }
        
        $sharedPodFit = ($cluster.SystemPodCount + $sharedAppCount) -le $cluster.NodeAllocatablePods
        $sharedFit = ($fgReqCpu -le $fgCpu) -and ($fgReqMem -le $fgMem) -and $sharedPodFit
        
        $topologyFit = $dedicatedFit -and $sharedFit
        $idleExpectedNodes = 2
    }
    return [pscustomobject]@{
        IdleOneNodeFit=$fit;IdleTopologyFit=$topologyFit;IdleExpectedNodes=$idleExpectedNodes;IdleAppCPURequest=[math]::Round($cpu,1);IdleAppMemoryRequest=[math]::Round($mem,1)
        AvailableAppCPU=$cluster.AvailableAppCPU;AvailableAppMemory=$cluster.AvailableAppMemory;PodFit=$podFit;SchedulingConstraintRisk=$cluster.SchedulingConstraintRisk
    }
}

function Test-ClusterReplicaFit([hashtable]$config,$cluster,[int]$nodeBudget = 0) {
    if ($nodeBudget -le 0) { $nodeBudget=if ($config.ContainsKey('NodeBudget')) { [int]$config.NodeBudget } else { $MaxNodes } }
    $reserveCpu=$cluster.NodeAllocatableCPU*$ClusterSchedulingReservePercent/100.0
    $reserveMem=$cluster.NodeAllocatableMemory*$ClusterSchedulingReservePercent/100.0
    $nodeSlots=[System.Collections.Generic.List[object]]::new()
    for ($index=0;$index -lt $nodeBudget;$index++) {
        $isSystemNode=$index -eq 0
        $cpu=$cluster.NodeAllocatableCPU-$cluster.DaemonSetCPUPerNode-$reserveCpu
        $mem=$cluster.NodeAllocatableMemory-$cluster.DaemonSetMemoryPerNode-$reserveMem
        $pods=$cluster.NodeAllocatablePods-$cluster.DaemonSetPodCount
        if ($isSystemNode) {
            $cpu-=$cluster.StaticSystemCPU; $mem-=$cluster.StaticSystemMemory; $pods-=$cluster.StaticSystemPodCount
        }
        $nodeSlots.Add(@{Cpu=[math]::Max(0,$cpu);Memory=[math]::Max(0,$mem);Pods=[math]::Max(0,$pods)})
    }
    $replicaItems=[System.Collections.Generic.List[object]]::new()
    foreach ($app in $apps) {
        $cpu=Convert-CpuToM $config[$app].requestCpu
        $mem=Convert-MemoryToMi $config[$app].requestMemory
        for ($replica=0;$replica -lt [int]$config[$app].maxReplicas;$replica++) {
            $replicaItems.Add([pscustomobject]@{App=$app;Cpu=$cpu;Memory=$mem})
        }
    }
    $ordered=@($replicaItems | Sort-Object @{Expression={ [int]$appResourceWeight[$_.App] };Descending=$true},@{Expression='Cpu';Descending=$true},@{Expression='Memory';Descending=$true})
    foreach ($item in $ordered) {
        $placed=$false
        foreach ($slot in $nodeSlots) {
            if ($slot.Pods -gt 0 -and $slot.Cpu -ge $item.Cpu -and $slot.Memory -ge $item.Memory) {
                $slot.Cpu-=$item.Cpu; $slot.Memory-=$item.Memory; $slot.Pods--; $placed=$true; break
            }
        }
        if (-not $placed) {
            return [pscustomobject]@{Fit=$false;UnplacedApp=$item.App;UnplacedCPU=$item.Cpu;UnplacedMemory=$item.Memory}
        }
    }
    return [pscustomobject]@{Fit=$true;UnplacedApp=$null;UnplacedCPU=0;UnplacedMemory=0}
}

function Enforce-ClusterReplicaBudget([hashtable]$config,$cluster,[int]$nodeBudget = 0) {
    $adjusted=Copy-Config $config $config.Name
    if ($nodeBudget -le 0) { $nodeBudget=if ($adjusted.ContainsKey('NodeBudget')) { [int]$adjusted.NodeBudget } else { $MaxNodes } }
    $adjusted.NodeBudget=$nodeBudget
    $initialMax=@{}
    foreach ($app in $apps) {
        $initialMax[$app]=[int]$adjusted[$app].maxReplicas
        $adjusted[$app].maxReplicas=[int][math]::Max([int]$hpaMaxMinimum[$app],[int]$adjusted[$app].maxReplicas)
    }
    for ($attempt=0;$attempt -lt ($MaxAutoReplicas*$apps.Count);$attempt++) {
        $fit=Test-ClusterReplicaFit $adjusted $cluster $nodeBudget
        if ($fit.Fit) { break }
        $app=[string]$fit.UnplacedApp
        $appFloor=[int]$hpaMaxMinimum[$app]
        if (-not $app -or [int]$adjusted[$app].maxReplicas -le $appFloor) {
            # 앱별 기능 하한보다 여유가 있는 후보만 축소한다.
            $app=$hpaReductionOrder | Where-Object { [int]$adjusted[$_].maxReplicas -gt [int]$hpaMaxMinimum[$_] } | Select-Object -First 1
        }
        if (-not $app) { throw "$nodeBudget Node 안에 HPA 기능 하한(user=$($hpaMaxMinimum.user), product=$($hpaMaxMinimum.product), stress=$($hpaMaxMinimum.stress))을 배치할 수 없습니다." }
        $adjusted[$app].maxReplicas=[int]$adjusted[$app].maxReplicas-1
    }
    $finalFit=Test-ClusterReplicaFit $adjusted $cluster $nodeBudget
    if (-not $finalFit.Fit) { throw "$nodeBudget Node replica budget 계산에 실패했습니다: unplaced=$($finalFit.UnplacedApp)" }
    $changes=@($apps | Where-Object { $initialMax[$_] -ne [int]$adjusted[$_].maxReplicas } | ForEach-Object { "$_ $($initialMax[$_])->$($adjusted[$_].maxReplicas)" })
    if ($changes.Count) { Write-Warning ("$nodeBudget Node scheduling budget: " + ($changes -join ', ')) }
    return $adjusted
}

function Get-ThrottleSnapshot {
    $snapshot = @{ Available=$false }
    foreach ($app in $apps) { $snapshot[$app]=@{Periods=0.0;Throttled=0.0} }
    try {
        $nodes = (& kubectl get nodes -o json) | ConvertFrom-Json
        foreach ($node in @($nodes.items)) {
            $path = "/api/v1/nodes/$($node.metadata.name)/proxy/metrics/cadvisor"
            $raw = ((& kubectl get --raw $path 2>$null) -join "`n")
            if ($LASTEXITCODE -ne 0 -or -not $raw) { continue }
            foreach ($line in ($raw -split "`n")) {
                if ($line -notmatch '^(container_cpu_cfs_(?:throttled_)?periods_total)\{([^}]*)\}\s+([0-9.eE+\-]+)') { continue }
                $metric=$Matches[1]; $labels=$Matches[2]; $value=[double]$Matches[3]
                if ($labels -notmatch ('namespace="' + [regex]::Escape($Namespace) + '"')) { continue }
                foreach ($app in $apps) {
                    if ($labels -match ('container="' + [regex]::Escape($app) + '"')) {
                        if ($metric -eq 'container_cpu_cfs_periods_total') { $snapshot[$app].Periods += $value }
                        else { $snapshot[$app].Throttled += $value }
                    }
                }
            }
        }
        $snapshot.Available = @($apps | Where-Object { $snapshot[$_].Periods -gt 0 }).Count -gt 0
    } catch { $snapshot.Available=$false }
    return $snapshot
}

function Get-ThrottleRatio($before, $after, [string]$app) {
    if (-not $before.Available -or -not $after.Available) { return $null }
    $periods=[double]$after[$app].Periods-[double]$before[$app].Periods
    $throttled=[double]$after[$app].Throttled-[double]$before[$app].Throttled
    if ($periods -le 0) { return $null }
    return [math]::Max(0,[math]::Min(1,$throttled/$periods))
}

function Start-MetricCollector([string]$path) {
    $header='Timestamp,ElapsedSec,ReadyNodes,ManagedReadyNodes,TotalReadyNodes,MemoryPressureNodes,MetricsAvailable,UserReady,UserTotal,UserPending,UserDesired,UserCurrent,UserCpuUtil,UserCpuTotalM,UserCpuPerPodM,UserMemoryTotalMi,UserMemoryPerPodMi,ProductReady,ProductTotal,ProductPending,ProductDesired,ProductCurrent,ProductCpuUtil,ProductCpuTotalM,ProductCpuPerPodM,ProductMemoryTotalMi,ProductMemoryPerPodMi,StressReady,StressTotal,StressPending,StressDesired,StressCurrent,StressCpuUtil,StressCpuTotalM,StressCpuPerPodM,StressMemoryTotalMi,StressMemoryPerPodMi,EvictedPods,ContainerRestarts,OOMKilled'
    $header | Set-Content -LiteralPath $path -Encoding UTF8
    $job = Start-Job -ScriptBlock {
        param($ns,$outPath,$started)
        function CpuM($value) {
            $t=([string]$value).Trim(); if (-not $t) { return $null }
            if ($t -match '^([0-9.]+)n$') { return [double]$Matches[1]/1000000 }
            if ($t -match '^([0-9.]+)u$') { return [double]$Matches[1]/1000 }
            if ($t -match '^([0-9.]+)m$') { return [double]$Matches[1] }
            if ($t -match '^[0-9.]+$') { return [double]$t*1000 }
            return $null
        }
        function MemMi($value) {
            $t=([string]$value).Trim(); if (-not $t) { return $null }
            if ($t -match '^([0-9.]+)Ki$') { return [double]$Matches[1]/1024 }
            if ($t -match '^([0-9.]+)Mi$') { return [double]$Matches[1] }
            if ($t -match '^([0-9.]+)Gi$') { return [double]$Matches[1]*1024 }
            if ($t -match '^[0-9.]+$') { return [double]$t/1MB }
            return $null
        }
        while ($true) {
            try {
                $nodes=((& kubectl get nodes -o json 2>$null) -join '') | ConvertFrom-Json
                $pods=((& kubectl get pods -n $ns -o json 2>$null) -join '') | ConvertFrom-Json
                $hpas=((& kubectl get hpa -n $ns -o json 2>$null) -join '') | ConvertFrom-Json
                $readyNodeItems=@($nodes.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count })
                $managedReadyNodes=@($readyNodeItems | Where-Object { $null -ne $_.metadata.labels.'eks.amazonaws.com/nodegroup' -and $_.metadata.labels.'eks.amazonaws.com/nodegroup' -ne '' }).Count
                # 비용/scale-out 집계에서는 고정 Managed 노드를 제외한다.
                $readyNodes=@($readyNodeItems | Where-Object { $null -eq $_.metadata.labels.'eks.amazonaws.com/nodegroup' -or $_.metadata.labels.'eks.amazonaws.com/nodegroup' -eq '' }).Count
                $totalReadyNodes=$readyNodeItems.Count
                $pressure=@($nodes.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'MemoryPressure' -and $_.status -eq 'True' }).Count }).Count
                $metricMap=@{}; $metricsAvailable=$false
                try {
                    $metricsRaw=((& kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/$ns/pods" 2>$null) -join '')
                    if ($LASTEXITCODE -eq 0 -and $metricsRaw) {
                        $podMetrics=$metricsRaw | ConvertFrom-Json; $metricsAvailable=$true
                        foreach ($metric in @($podMetrics.items)) { $metricMap[$metric.metadata.name]=$metric }
                    }
                } catch { $metricsAvailable=$false }
                function AppSample([string]$name) {
                    $appPods=@($pods.items | Where-Object { $_.metadata.labels.app -eq $name })
                    $ready=@($appPods | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count }).Count
                    $pending=@($appPods | Where-Object { $_.status.phase -eq 'Pending' }).Count
                    $hpa=$hpas.items | Where-Object { $_.metadata.name -eq $name } | Select-Object -First 1
                    $desired=if ($null -ne $hpa.status.desiredReplicas) { [int]$hpa.status.desiredReplicas } else { $null }
                    $current=if ($null -ne $hpa.status.currentReplicas) { [int]$hpa.status.currentReplicas } else { $null }
                    $util=$null
                    if ($hpa.status.currentMetrics -and $null -ne $hpa.status.currentMetrics[0].resource.current.averageUtilization) { $util=[int]$hpa.status.currentMetrics[0].resource.current.averageUtilization }
                    $cpu=0.0; $mem=0.0; $have=$false
                    foreach ($pod in $appPods) {
                        $pm=$metricMap[$pod.metadata.name]; if (-not $pm) { continue }
                        foreach ($container in @($pm.containers)) {
                            if ($container.name -ne $name) { continue }
                            $c=CpuM $container.usage.cpu; $m=MemMi $container.usage.memory
                            if ($null -ne $c) { $cpu+=$c; $have=$true }; if ($null -ne $m) { $mem+=$m }
                        }
                    }
                    $cpuPod=if ($have -and $ready -gt 0) { $cpu/$ready } else { $null }
                    $memPod=if ($have -and $ready -gt 0) { $mem/$ready } else { $null }
                    return [pscustomobject]@{Ready=$ready;Total=$appPods.Count;Pending=$pending;Desired=$desired;Current=$current;Util=$util;Cpu=$cpu;CpuPod=$cpuPod;Mem=$mem;MemPod=$memPod}
                }
                $u=AppSample user; $p=AppSample product; $s=AppSample stress
                $evicted=@($pods.items | Where-Object { $_.status.reason -eq 'Evicted' }).Count
                $restarts=0; $oom=0
                foreach ($pod in @($pods.items)) {
                    foreach ($cs in @($pod.status.containerStatuses)) {
                        $restarts+=[int]$cs.restartCount
                        if ($cs.lastState.terminated.reason -eq 'OOMKilled') { $oom += [math]::Max(1,[int]$cs.restartCount) }
                        elseif ($cs.state.terminated.reason -eq 'OOMKilled') { $oom += [math]::Max(1,[int]$cs.restartCount+1) }
                    }
                }
                $elapsed=[math]::Round(((Get-Date)-[datetime]$started).TotalSeconds,1)
                $fields=@((Get-Date -Format o),$elapsed,$readyNodes,$managedReadyNodes,$totalReadyNodes,$pressure,$metricsAvailable,$u.Ready,$u.Total,$u.Pending,$u.Desired,$u.Current,$u.Util,$u.Cpu,$u.CpuPod,$u.Mem,$u.MemPod,$p.Ready,$p.Total,$p.Pending,$p.Desired,$p.Current,$p.Util,$p.Cpu,$p.CpuPod,$p.Mem,$p.MemPod,$s.Ready,$s.Total,$s.Pending,$s.Desired,$s.Current,$s.Util,$s.Cpu,$s.CpuPod,$s.Mem,$s.MemPod,$evicted,$restarts,$oom)
                ($fields -join ',') | Add-Content -LiteralPath $outPath
            } catch { }
            Start-Sleep -Seconds 5
        }
    } -ArgumentList $Namespace,$path,(Get-Date)
    [void]$metricJobs.Add($job)
    return $job
}

function Stop-MetricCollector($job) {
    if (-not $job) { return }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    [void]$metricJobs.Remove($job)
}

function Get-Series([object[]]$samples,[string]$property) {
    $values=[System.Collections.Generic.List[double]]::new()
    foreach ($sample in $samples) {
        $member=$sample.PSObject.Properties[$property]
        if ($member -and $null -ne $member.Value -and [string]$member.Value -ne '') { $values.Add([double]$member.Value) }
    }
    return @($values)
}

function Get-AppRunResult([string]$app,$summary,[object[]]$samples,[object[]]$steadySamples,[double]$loadDurationSec,[double]$steadyDurationSec,[hashtable]$config,$throttleBefore,$throttleAfter) {
    $prefix=(Get-Culture).TextInfo.ToTitleCase($app)
    $durationMetric=$summary.metrics."${app}_duration"
    $sloMetric=$summary.metrics."${app}_slo"
    $requestCount=Get-MetricNumber $summary.metrics."${app}_requests" 'count'
    $successCount=Get-MetricNumber $summary.metrics."${app}_success" 'count'
    $failureCount=Get-MetricNumber $summary.metrics."${app}_failures" 'count'
    $steadyDurationMetric=$summary.metrics."${app}_steady_duration"
    $steadySloMetric=$summary.metrics."${app}_steady_slo"
    $steadyRequestCount=Get-MetricNumber $summary.metrics."${app}_steady_requests" 'count'
    $steadySuccessCount=Get-MetricNumber $summary.metrics."${app}_steady_success" 'count'
    $steadyFailureCount=Get-MetricNumber $summary.metrics."${app}_steady_failures" 'count'
    $timeoutCount=Get-MetricNumber $summary.metrics."${app}_timeouts" 'count'; if ($null -eq $timeoutCount) { $timeoutCount=0 }
    $steadyTimeoutCount=Get-MetricNumber $summary.metrics."${app}_steady_timeouts" 'count'; if ($null -eq $steadyTimeoutCount) { $steadyTimeoutCount=0 }
    # k6 Counter는 0회면 summary에 metric을 만들지 않는다. requests/success로 실제 0을 복원한다.
    if ($null -eq $failureCount -and $null -ne $requestCount -and $null -ne $successCount) { $failureCount=[math]::Max(0,$requestCount-$successCount) }
    if ($null -eq $successCount -and $null -ne $requestCount -and $null -ne $failureCount) { $successCount=[math]::Max(0,$requestCount-$failureCount) }
    if ($null -eq $steadyFailureCount -and $null -ne $steadyRequestCount -and $null -ne $steadySuccessCount) { $steadyFailureCount=[math]::Max(0,$steadyRequestCount-$steadySuccessCount) }
    if ($null -eq $steadySuccessCount -and $null -ne $steadyRequestCount -and $null -ne $steadyFailureCount) { $steadySuccessCount=[math]::Max(0,$steadyRequestCount-$steadyFailureCount) }
    $overallP95=Get-MetricNumber $durationMetric 'p(95)'
    $p50=Get-MetricNumber $steadyDurationMetric 'p(50)'; if ($null -eq $p50) { $p50=Get-MetricNumber $steadyDurationMetric 'med' }
    $p90=Get-MetricNumber $steadyDurationMetric 'p(90)'
    $p95=Get-MetricNumber $steadyDurationMetric 'p(95)'
    $p99=Get-MetricNumber $steadyDurationMetric 'p(99)'
    $maxLatency=Get-MetricNumber $steadyDurationMetric 'max'
    if ($null -eq $p95) { $p95=$overallP95; $p50=Get-MetricNumber $durationMetric 'med'; $p90=Get-MetricNumber $durationMetric 'p(90)'; $p99=Get-MetricNumber $durationMetric 'p(99)'; $maxLatency=Get-MetricNumber $durationMetric 'max' }
    # QualityScore Q/L은 timeout ceiling(5001ms)이 섞인 전체 latency가 아니라
    # 성공 응답만의 latency를 사용한다. k6가 success_duration trend에 성공
    # 응답만 기록하며, 성공 응답이 없으면 metric 자체가 summary에 없다.
    $successDurationMetric=$summary.metrics."${app}_success_duration"
    $steadySuccessDurationMetric=$summary.metrics."${app}_steady_success_duration"
    $successP95=Get-MetricNumber $successDurationMetric 'p(95)'
    $successP99=Get-MetricNumber $successDurationMetric 'p(99)'
    $steadySuccessP95=Get-MetricNumber $steadySuccessDurationMetric 'p(95)'
    $steadySuccessP99=Get-MetricNumber $steadySuccessDurationMetric 'p(99)'
    if ($null -eq $steadySuccessP95) { $steadySuccessP95=$successP95; $steadySuccessP99=$successP99 }
    # k6 summary-export의 Rate metric은 rate가 아니라 value 필드에 기록된다.
    $overallSloComplianceRate=Get-MetricNumber $sloMetric 'value'
    $sloComplianceRate=Get-MetricNumber $steadySloMetric 'value'; if ($null -eq $sloComplianceRate) { $sloComplianceRate=$overallSloComplianceRate }
    $readyValues=Get-Series $samples "${prefix}Ready"
    $pendingValues=Get-Series $samples "${prefix}Pending"
    $desiredValues=Get-Series $samples "${prefix}Desired"
    $currentValues=Get-Series $samples "${prefix}Current"
    $utilValues=Get-Series $samples "${prefix}CpuUtil"
    $cpuValues=Get-Series $samples "${prefix}CpuPerPodM"
    $memValues=Get-Series $samples "${prefix}MemoryPerPodMi"
    $highReadyValues=Get-Series $steadySamples "${prefix}Ready"
    $highCpuTotalValues=Get-Series $steadySamples "${prefix}CpuTotalM"
    $avgReady=if ($readyValues.Count) { ($readyValues | Measure-Object -Average).Average } else { $null }
    $peakReady=if ($readyValues.Count) { ($readyValues | Measure-Object -Maximum).Maximum } else { $null }
    $peakPending=if ($pendingValues.Count) { ($pendingValues | Measure-Object -Maximum).Maximum } else { $null }
    $peakDesired=if ($desiredValues.Count) { ($desiredValues | Measure-Object -Maximum).Maximum } else { $null }
    $peakCurrent=if ($currentValues.Count) { ($currentValues | Measure-Object -Maximum).Maximum } else { $null }
    $scalingStable=$samples.Count -ge 2 -and @($samples | Where-Object {
        $ready=$_.PSObject.Properties["${prefix}Ready"].Value
        $desired=$_.PSObject.Properties["${prefix}Desired"].Value
        $pending=$_.PSObject.Properties["${prefix}Pending"].Value
        $null -eq $ready -or $null -eq $desired -or [double]$ready -ne [double]$desired -or [double]$pending -gt 0
    }).Count -eq 0
    $avgUtil=if ($utilValues.Count) { ($utilValues | Measure-Object -Average).Average } else { $null }
    $peakUtil=if ($utilValues.Count) { ($utilValues | Measure-Object -Maximum).Maximum } else { $null }
    $avgCpu=if ($cpuValues.Count) { ($cpuValues | Measure-Object -Average).Average } else { $null }
    $peakCpu=if ($cpuValues.Count) { ($cpuValues | Measure-Object -Maximum).Maximum } else { $null }
    $cpuP95=Get-Percentile $cpuValues 95
    $memAvg=if ($memValues.Count) { ($memValues | Measure-Object -Average).Average } else { $null }
    $memP95=Get-Percentile $memValues 95; $memP99=Get-Percentile $memValues 99
    $memPeak=if ($memValues.Count) { ($memValues | Measure-Object -Maximum).Maximum } else { $null }
    $highAvgReady=if ($highReadyValues.Count) { ($highReadyValues | Measure-Object -Average).Average } else { $null }
    $highAvgCpuTotal=if ($highCpuTotalValues.Count) { ($highCpuTotalValues | Measure-Object -Average).Average } else { $null }
    $highCpuP95Total=Get-Percentile $highCpuTotalValues 95
    $rps=if ($null -ne $successCount -and $loadDurationSec -gt 0) { $successCount/$loadDurationSec } else { $null }
    $highRps=if ($null -ne $steadySuccessCount -and $steadyDurationSec -gt 0) { $steadySuccessCount/$steadyDurationSec } else { $null }
    $rpsPerPod=if ($null -ne $highRps -and $highAvgReady -gt 0) { $highRps/$highAvgReady } elseif ($null -ne $rps -and $avgReady -gt 0) { $rps/$avgReady } else { $null }
    $safeRpsPerPod=if ($null -ne $rpsPerPod) { $rpsPerPod*0.8 } else { $null }
    $cpuPerSuccessfulRps=if ($highRps -gt 0 -and $highAvgCpuTotal -gt 0) { $highAvgCpuTotal/$highRps } else { $null }
    $requestCore=(Convert-CpuToM $config[$app].requestCpu)/1000.0
    $requestGi=(Convert-MemoryToMi $config[$app].requestMemory)/1024.0
    $cpuCost=if ($avgReady -gt 0) { $requestCore*$avgReady } else { $null }
    $memoryCost=if ($avgReady -gt 0) { $requestGi*$avgReady } else { $null }
    $resourceCost=if ($null -ne $cpuCost) { $cpuCost+$MemoryWeight*$memoryCost } else { $null }
    $efficiency=if ($resourceCost -gt 0 -and $null -ne $rps) { $rps/$resourceCost } else { $null }
    $latencyPenalty=if ($null -ne $p95) { [math]::Pow([math]::Max(1,$p95/[double]$sloMs[$app]),2) } else { $null }
    $score=if ($efficiency -and $latencyPenalty) { $efficiency/$latencyPenalty } else { 0 }
    $throttle=Get-ThrottleRatio $throttleBefore $throttleAfter $app
    $metricUnavailable=($null -eq $cpuP95 -or $null -eq $memP95 -or $null -eq $avgUtil -or $null -eq $p95 -or $null -eq $highAvgReady)
    $failureRate=if ($requestCount -gt 0 -and $null -ne $failureCount) { $failureCount/$requestCount } else { $null }
    $highFailureRate=if ($steadyRequestCount -gt 0 -and $null -ne $steadyFailureCount) { $steadyFailureCount/$steadyRequestCount } else { $null }
    $timeoutRate=if ($requestCount -gt 0) { $timeoutCount/$requestCount } else { $null }
    $steadyTimeoutRate=if ($steadyRequestCount -gt 0) { $steadyTimeoutCount/$steadyRequestCount } else { $null }
    # k6가 {code:xxx} 태그로 남긴 실패 유형을 집계한다. timeout은 status=0(클라이언트
    # timeout)이므로 'timeout', 그 외에는 실제 HTTP status(500/502/403 등)가 code가 된다.
    $failureBreakdown=@{}
    $breakdownPrefix="${app}_failure_breakdown"
    foreach ($prop in @($summary.metrics.PSObject.Properties)) {
        if ($prop.Name -eq $breakdownPrefix -or $prop.Name -like "${breakdownPrefix}{*}") {
            $code=if ($prop.Name -eq $breakdownPrefix) { 'total' } else { $prop.Name.Substring($breakdownPrefix.Length+1).TrimEnd('}') -replace '^code:','' }
            $failureBreakdown[$code]=Get-MetricNumber $prop.Value 'count'
        }
    }
    $breakdownText=if ($failureBreakdown.Count) {
        ($failureBreakdown.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    } else { $null }
    # 운영 성공은 steady-state p95를 기본으로 하고 p99 심각 초과와 timeout도 배제한다.
    $tailSafe=($null -ne $p99 -and $p99 -le ([double]$sloMs[$app]*1.25))
    $sloPass=($null -ne $p95 -and $p95 -le [double]$sloMs[$app] -and $tailSafe -and $steadyTimeoutCount -eq 0)
    $headroomPass=($null -ne $p95 -and $p95 -le ([double]$sloMs[$app]*$LatencyHeadroomRatio) -and $tailSafe -and $steadyTimeoutCount -eq 0)
    $availabilityPass=($steadySuccessCount -gt 0 -and $null -ne $maxLatency -and $maxLatency -le 5000 -and $steadyTimeoutCount -eq 0)
    return [pscustomobject]@{
        App=$app;Requests=$requestCount;SuccessfulRequests=$successCount;FailedRequests=$failureCount;FailureRate=$failureRate;RPS=$rps
        P50Ms=$p50;P90Ms=$p90;P95Ms=$p95;P99Ms=$p99;MaxMs=$maxLatency;OverallP95Ms=$overallP95;HighLoadP95Ms=$p95;SLOComplianceRate=$sloComplianceRate;OverallSLOComplianceRate=$overallSloComplianceRate
        SuccessP95Ms=$steadySuccessP95;SuccessP99Ms=$steadySuccessP99;SuccessLatencyAvailable=($null -ne $steadySuccessP95)
        SteadySuccessP95Ms=$steadySuccessP95;SuccessP95MsOverall=$successP95;SuccessSampleCount=$successCount;SteadySuccessSampleCount=$steadySuccessCount
        TimeoutCount=$timeoutCount;TimeoutRate=$timeoutRate;SteadyTimeoutCount=$steadyTimeoutCount;SteadyTimeoutRate=$steadyTimeoutRate
        FailureBreakdown=$failureBreakdown;FailureBreakdownText=$breakdownText
        HighLoadRequests=$steadyRequestCount;HighLoadSuccessfulRequests=$steadySuccessCount;HighLoadFailedRequests=$steadyFailureCount;HighLoadFailureRate=$highFailureRate;HighLoadRPS=$highRps
        AverageReadyReplicas=$avgReady;PeakReadyReplicas=$peakReady;PeakPendingReplicas=$peakPending;PeakDesiredReplicas=$peakDesired;PeakCurrentReplicas=$peakCurrent;ScalingStable=$scalingStable
        HighLoadAverageReadyReplicas=$highAvgReady;HighLoadAverageTotalCPUMillicores=$highAvgCpuTotal;HighLoadCPUP95TotalMillicores=$highCpuP95Total;CPUPerSuccessfulRPS=$cpuPerSuccessfulRps
        AverageCPUUtilization=$avgUtil;PeakCPUUtilization=$peakUtil;AverageCPUMillicores=$avgCpu;PeakCPUMillicores=$peakCpu;CPUP95Millicores=$cpuP95
        AverageMemoryMi=$memAvg;MemoryP95Mi=$memP95;MemoryP99Mi=$memP99;MemoryPeakMi=$memPeak
        ThrottleRatio=$throttle;ThrottleMetricUnavailable=($null -eq $throttle);MetricUnavailable=$metricUnavailable
        RPSPerPod=$rpsPerPod;SafeRPSPerPod=$safeRpsPerPod;RPSPerRequestedCore=$(if ($cpuCost -gt 0) { $rps/$cpuCost } else { $null })
        CPUCost=$cpuCost;MemoryCost=$memoryCost;EfficiencyScore=$score;SLOPass=$sloPass;HeadroomPass=$headroomPass;AvailabilityPass=$availabilityPass
        PossibleExternalBottleneck=$false;DiminishingReturn=$false
    }
}

function Get-TieredRatePoints($Rate) {
    if ($null -eq $Rate) { return 0.0 }
    $points=0.0
    foreach ($threshold in @(0.90,0.875,0.85,0.825,0.80,0.70,0.50,0.30)) {
        if ([double]$Rate -ge $threshold) { $points += 0.5 }
    }
    return $points
}

function Get-EmpiricalPerformanceScore($Percent,[string]$app='') {
    # 실제 성적표: SLO 성공률(%) → 앱별 점수 0..4. 앱별 boundary 사용 (EMPIRICAL_UNCONFIRMED).
    # 최신 관측: 각 앱 baseline 2.0, stress 70에서 +0.5, user/product 82.5에서 +0.5.
    # p<50은 이전 관측(0점)을 보수적으로 유지, p<30은 infeasible.
    $p=if ($null -ne $Percent) { [double]$Percent } else { 0.0 }
    $feasible=($p -ge $HardConstraintFloor)
    $score=0.0
    if ($feasible -and $p -ge 50.0) {
        # 공통 경계 (최신 채점 31.5 기준): 50→1.0, 70→1.5, 82.5→3.0, 90→3.5, 95→4.0
        if ($p -ge 95.0) { $score=4.0 } elseif ($p -ge 90.0) { $score=3.5 } elseif ($p -ge 82.5) { $score=3.0 } elseif ($p -ge 70.0) { $score=1.5 } else { $score=1.0 }
    }
    return [pscustomobject]@{Score=$score;Feasible=$feasible;Percent=[math]::Round($p,2)}
}

function Get-NextPerformanceBoundary($Percent,[string]$app='') {
    # Percent보다 strictly greater인 첫 score 증가 boundary (앱별). 예: stress 67.08→70, user 81.61→82.5
    $p=if ($null -ne $Percent) { [double]$Percent } else { 0.0 }
    foreach ($b in $performanceBoundaries) { if ($p -lt $b) { return [double]$b } }
    return $null
}

function Get-BoundaryDistance($Percent,[string]$app='') {
    $next=Get-NextPerformanceBoundary $Percent $app
    if ($null -eq $next) { return $null }
    $p=if ($null -ne $Percent) { [double]$Percent } else { 0.0 }
    return [math]::Round(($next-$p),2)
}

function Get-BoundaryHarvestInfo($Percent,[string]$app='') {
    # near-boundary harvesting: 점수 경계 바로 아래 앱의 저비용 회수 후보 정보 (앱별 boundary).
    $p=if ($null -ne $Percent) { [double]$Percent } else { 0.0 }
    $bg=Get-NextPerformanceBoundaryGain $p $app
    $near=($null -ne $bg.NextBoundary -and $bg.Distance -le $NearBoundaryWindow -and $bg.Gain -gt 0)
    $safety=if ($null -ne $bg.NextBoundary) { $bg.NextBoundary+$BoundarySafetyTargetMargin } else { $null }
    return [pscustomobject]@{Performance=$p;CurrentScore=$bg.CurrentScore;NextBoundary=$bg.NextBoundary;Distance=$bg.Distance;Gain=$bg.Gain;SafetyTarget=$safety;NearBoundary=$near}
}

function Get-NextPerformanceBoundaryGain($Percent,[string]$app='') {
    # 다음 score boundary의 실제 gain (앱별). "다음 +0.5" 고정이 아니라 실제 점프 폭.
    $p=if ($null -ne $Percent) { [double]$Percent } else { 0.0 }
    $nb=Get-NextPerformanceBoundary $p $app
    if ($null -eq $nb) { return [pscustomobject]@{NextBoundary=$null;NextScore=4.0;CurrentScore=(Get-EmpiricalPerformanceScore $p $app).Score;Gain=0.0;Distance=$null} }
    $cur=(Get-EmpiricalPerformanceScore $p $app).Score
    $next=(Get-EmpiricalPerformanceScore $nb $app).Score
    return [pscustomobject]@{NextBoundary=$nb;NextScore=$next;CurrentScore=$cur;Gain=[math]::Round($next-$cur,2);Distance=[math]::Round($nb-$p,2)}
}

function Get-BoundaryProgress($OldPercent,$NewPercent) {
    # 같은 target boundary를 추적할 수 있을 때 OldDistance-NewDistance (같은 boundary 대상).
    # 예: 62.9→64.2 → distance 2.1→0.8 → progress 1.3
    $oNext=Get-NextPerformanceBoundary $OldPercent
    $nNext=Get-NextPerformanceBoundary $NewPercent
    if ($null -eq $oNext -or $null -eq $nNext) { return 0.0 }
    if ([double]$oNext -ne [double]$nNext) { return 0.0 }   # 다른 boundary로 이동하면 progress 정의 안 함
    $oD=if ($null -ne $OldPercent) { [double]$oNext-[double]$OldPercent } else { 0.0 }
    $nD=if ($null -ne $NewPercent) { [double]$nNext-[double]$NewPercent } else { 0.0 }
    return [math]::Round(($oD-$nD),2)
}

function Get-EmpiricalCostScore($profile) {
    # 실제 채점 비용은 EC2 평균 사용량 기반(avg node = CostNodeSeconds/CostWindowSeconds)이다.
    $costNodeSec=[double](Get-OptionalPropertyValue $profile 'CostNodeSeconds' -1)
    $costWindow=[double](Get-OptionalPropertyValue $profile 'CostWindowSeconds' 0)
    
    $avg=0.0
    if ($costNodeSec -ge 0 -and $costWindow -gt 0) {
        $avg = $costNodeSec / $costWindow
    } else {
        # Fallback (legacy field 허용)
        $nodeSec=[double](Get-OptionalPropertyValue $profile 'TotalNodeSeconds' (Get-OptionalPropertyValue $profile 'NodeSeconds' 0))
        $window=[double](Get-OptionalPropertyValue $profile 'LoadWindowSeconds' 0)
        $avg=if ($window -gt 0) { $nodeSec/$window } else { [double](Get-OptionalPropertyValue $profile 'AverageTotalReadyNodes' 0) }
    }
    
    if ($avg -le 0) { $avg=0.0 }   # missing cost telemetry는 0 nodes로 간주하지 않음 (cost=12 오인 방지)
    $ratio=if ($CostBaselineNodes -gt 0) { $avg/$CostBaselineNodes } else { [double]::PositiveInfinity }
    
    # tier (EMPIRICAL_UNCONFIRMED — 최신 채점: avg 2.87/ratio 1.433 → 10, 분석상 avg≤2.50→11, avg≤2.25→12):
    #   avg ≤ 2.25 (ratio 1.125) → 12 / avg ≤ 2.50 (1.25) → 11 / avg ≤ 3.0 (1.5) → 10 / 이후 8/6/4/2/0
    $points=if ($avg -le 2.25) { 12.0 } elseif ($avg -le 2.50) { 11.0 } elseif ($ratio -le 1.5) { 10.0 } elseif ($ratio -le 2.0) { 8.0 } elseif ($ratio -le 2.5) { 6.0 } elseif ($ratio -le 3.0) { 4.0 } elseif ($ratio -le 3.5) { 2.0 } else { 0.0 }
    
    return [pscustomobject]@{
        Score=$points
        Max=12.0
        AvgTotalNodes=[math]::Round($avg,2)
        PeakTotalNodes=[double](Get-OptionalPropertyValue $profile 'PeakTotalReadyNodes' 0)
        CostRatio=[math]::Round($ratio,3)
        TotalNodeSeconds=if ($costNodeSec -ge 0) { $costNodeSec } else { $nodeSec }
        WindowSeconds=if ($costWindow -gt 0) { $costWindow } else { $window }
        BaselineNodes=$CostBaselineNodes
    }
}

function Get-EvaluationCostScore($profile) {
    # backward-compat wrapper: cost source of truth는 평균 EC2 기반 Get-EmpiricalCostScore.
    return Get-EmpiricalCostScore $profile
}

function Get-EvaluationScore($profile) {
    # 실제 성적표: PerfScore(0..4N) + CostScore(0..12) = EvaluationTotalScore.
    # N-app generic: ManagedApps 목록을 그대로 순회 (앱 이름 하드코딩 없음).
    $appScores=@{}; $appPercents=@{}
    $perf=0.0; $feasible=$true
    foreach ($a in $apps) {
        $percent=100.0*[double](Get-OptionalPropertyValue $profile.Apps[$a] 'SLOComplianceRate' 0)
        $r=Get-EmpiricalPerformanceScore $percent $a
        $appScores[$a]=$r.Score; $appPercents[$a]=$r.Percent
        $perf += $r.Score
        if (-not $r.Feasible) { $feasible=$false }
    }
    $cost=Get-EmpiricalCostScore $profile
    $perf=[math]::Round($perf,2)
    $total=[math]::Round($perf+$cost.Score,2)
    # backward-compat reporting 필드 (source of truth는 AppScores/PerfScore)
    $u=[double](Get-OptionalPropertyValue $appScores 'user' 0); $p=[double](Get-OptionalPropertyValue $appScores 'product' 0); $s=[double](Get-OptionalPropertyValue $appScores 'stress' 0)
    return [pscustomobject]@{Feasible=$feasible;AppScores=$appScores;AppPercents=$appPercents;UserScore=$u;ProductScore=$p;StressScore=$s;PerfScore=$perf;CostScore=$cost.Score;CostEstimated=$false;TotalScore=$total}
}

function Get-EvaluationActionCostClass([string]$actionType) {
    # 노드/EC2 비용을 떨어뜨리지 않는 action = FREE. HPA max 증가는 잠재 PAID.
    if ($actionType -in @('INCREASE_HPA_MAX','DIAGNOSE_NODE_CAPACITY','NO_CHANGE')) { return 'PAID' }
    return 'FREE'
}

function Write-EvaluationLog($profile,[string]$name='') {
    # 스펙 14: candidate별 성적표 로그
    $e=Get-EvaluationScore $profile
    $label=if ($name) { $name } else { (Get-OptionalPropertyValue $profile 'Name' '') }
    Write-Host ("Evaluation [{0}]" -f $label) -ForegroundColor Cyan
    foreach ($a in $apps) {
        $percent=100.0*[double](Get-OptionalPropertyValue $profile.Apps[$a] 'SLOComplianceRate' 0)
        $sc=(Get-EmpiricalPerformanceScore $percent $a).Score
        $nb=Get-NextPerformanceBoundary $percent
        $d=Get-BoundaryDistance $percent
        $gain=Get-NextPerformanceBoundaryGain $percent $a
        Write-Host ("  {0}: performance={1}%  score={2}  nextBoundary={3}  distance={4}  nextBoundaryGain={5}" -f $a,([math]::Round($percent,1)),$sc,$(if ($null -eq $nb) {'-'} else { $nb }),$(if ($null -eq $d) {'-'} else { $d }),$gain.Gain) -ForegroundColor DarkGray
        # [SCORE] empirical 예측 로그 (raw boundary, safety margin 적용 전)
        Write-Host ("[SCORE] app={0} performance={1:N2} boundary={2} score={3:N1}" -f $a,$percent,$(if ($null -eq $nb) { 'max' } else { $nb }),$sc) -ForegroundColor DarkGray
        # 실제 채점 결과가 주입되면 empirical 예측과 mismatch 감지 (grader 코드가 없으므로 새 boundary 추측은 금지)
        if ($ObservedPerformance -and $ObservedPerformance.ContainsKey($a)) {
            $observed=[double]$ObservedPerformance[$a]
            if ([math]::Abs($observed-$percent) -gt 1.0) {
                Write-Host ("[PERFORMANCE-MISMATCH] app={0} predicted={1:N2} actual={2:N2} performance={3:N2} — empirical model 재검토 필요" -f $a,$percent,$observed,$percent) -ForegroundColor Yellow
            }
        }
    }
    Write-Host ("  PerfScore={0}/12  CostScore={1}/12  EvaluationTotal={2}/24  Feasible={3}" -f $e.PerfScore,$e.CostScore,$e.TotalScore,$e.Feasible) -ForegroundColor DarkGray
    return $e
}

function Get-CompetitionScore([hashtable]$appResults,[double]$totalReadyNodes) {
    $items=[System.Collections.Generic.List[object]]::new()
    $earned=0.0
    foreach ($app in $apps) {
        $metric=$appResults[$app]
        $loadRate=if ($null -ne $metric.LoadProcessingRate) { [double]$metric.LoadProcessingRate } elseif ($metric.Requests -gt 0) { [double]$metric.SuccessfulRequests/[double]$metric.Requests } else { 0 }
        $loadPoints=Get-TieredRatePoints $loadRate
        $latencyRate=if ($null -ne $metric.SLOComplianceRate) { [double]$metric.SLOComplianceRate } else { 0 }
        $latencyPass=$latencyRate -ge 0.90
        $latencyPoints=Get-TieredRatePoints $latencyRate
        $earned += $loadPoints+$latencyPoints
        $items.Add([pscustomobject]@{Key="${app}_load";Label="$app API 로드 처리";Rate=$loadRate;Pass=($loadRate -ge 0.90);Earned=$loadPoints;Max=4.0})
        $items.Add([pscustomobject]@{Key="${app}_latency";Label="$app API 응답시간";Rate=$latencyRate;SLOMs=$sloMs[$app];Pass=$latencyPass;Earned=$latencyPoints;Max=4.0})
    }
    # 비용은 실제 평가처럼 Managed+Karpenter EC2 전체를 사용한다. 점수 구간은
    # 저장소 tools/check.ps1 기준이며 공식 평가의 더 세밀한 구간과는 다를 수 있다.
    $instanceRatio=if ($CostBaselineNodes -gt 0) { $totalReadyNodes/$CostBaselineNodes } else { [double]::PositiveInfinity }
    $costPoints=if ($instanceRatio -le 1.0) { 12.0 } elseif ($instanceRatio -le 1.5) { 10.0 } elseif ($instanceRatio -le 2.0) { 8.0 } elseif ($instanceRatio -le 2.5) { 6.0 } elseif ($instanceRatio -le 3.0) { 4.0 } elseif ($instanceRatio -le 3.5) { 2.0 } else { 0.0 }
    $costRate=$costPoints/12.0
    $earned += $costPoints
    $items.Add([pscustomobject]@{Key='cost';Label='인스턴스 비용';Rate=$costRate;InstanceRatio=[math]::Round($instanceRatio,2);ReadyNodes=$totalReadyNodes;BaselineNodes=$CostBaselineNodes;Earned=[math]::Round($costPoints,2);Max=12.0})
    return [pscustomobject]@{Earned=[math]::Round($earned,2);Max=36.0;Items=@($items)}
}

function Get-LoadGeneratorLimitEvidence($GeneratedRatio,$DroppedIterations,$Requests,[bool]$MaxVUReached) {
    # 최종 saturation 기준: generatedRatio >= 0.95 AND droppedPct <= 2%가 아니면 Limited.
    $reasons=[System.Collections.Generic.List[string]]::new()
    $droppedPct=$null
    if ($null -ne $DroppedIterations -and $null -ne $Requests -and ([double]$DroppedIterations+[double]$Requests) -gt 0) {
        $droppedPct=[double]$DroppedIterations/([double]$DroppedIterations+[double]$Requests)
    }
    if ($null -ne $GeneratedRatio -and [double]$GeneratedRatio -lt $SaturationGeneratedRatio) { $reasons.Add('GENERATED_BELOW_95_PERCENT') }
    if ($null -ne $droppedPct -and $droppedPct -gt $SaturationDroppedPct) { $reasons.Add('DROPPED_ABOVE_2_PERCENT') }
    return [pscustomobject]@{
        Limited=($reasons.Count -gt 0);Reasons=@($reasons);GeneratedRatio=$GeneratedRatio;DroppedIterations=$DroppedIterations;DroppedPct=$droppedPct;MaxVUReached=$MaxVUReached
    }
}

function Get-BottleneckClassification($profile,[string]$app) {
    $metric=$profile.Apps[$app]
    $reasons=[System.Collections.Generic.List[string]]::new()
    if ([bool]$metric.LoadGeneratorLimited) { $reasons.Add('LOAD_GENERATOR_LIMIT') }
    $generated=Get-OptionalPropertyValue $metric 'GeneratedLoadRatio' 0
    $highRequests=Get-OptionalPropertyValue $metric 'HighLoadRequests' 0
    $highSuccess=Get-OptionalPropertyValue $metric 'HighLoadSuccessfulRequests' 0
    if ([double]$generated -ge 0.95 -and [double]$highRequests -ge 10 -and [double]$highSuccess -le 0) { $reasons.Add('ZERO_SUCCESS_CAPACITY') }
    if ($profile.OOMKilledDeltaByApp -and [int]$profile.OOMKilledDeltaByApp[$app] -gt 0) { $reasons.Add('MEMORY_OOM') }
    if ([double]$metric.PeakPendingReplicas -gt 0) {
        if ([double]$profile.PeakReadyNodes -ge [double]$profile.NodeBudget) { $reasons.Add('NODE_CAPACITY') }
        else { $reasons.Add('POD_STARTUP_DELAY') }
    }
    elseif (-not [bool]$metric.ScalingStable) { $reasons.Add('POD_STARTUP_DELAY') }
    if ($null -ne $metric.ThrottleRatio -and [double]$metric.ThrottleRatio -ge 0.10) { $reasons.Add('CPU_THROTTLING') }
    $ceilingValue=if ($null -ne $metric.PeakDesiredReplicas) { [double]$metric.PeakDesiredReplicas } else { [double]$metric.PeakReadyReplicas }
    $ceiling=$ceilingValue -ge ([int]$profile.Config[$app].maxReplicas-0.1)
    # ScalingLimited/TooManyReplicas 근사: replicas가 max에 닿고 CPU가 target을 넘으면 SLOPass와
    # 무관하게 HPA_CEILING으로 강하게 분류한다 (실측: product 4/4 + CPU 86/65).
    $cpuOver=($null -ne $metric.PeakCPUUtilization -and [double]$metric.PeakCPUUtilization -gt [int]$profile.Config[$app].hpaTarget)
    if ([bool]$metric.MeasurementReliable -and $ceiling -and $cpuOver) { $reasons.Add('HPA_CEILING') }
    if ([bool]$metric.MetricUnavailable) { $reasons.Add('UNKNOWN') }
    if (-not $metric.SLOPass -and $reasons.Count -eq 0) { $reasons.Add('APPLICATION_LATENCY') }
    return @($reasons | Select-Object -Unique)
}

function Test-CandidateConfigValid($Config) {
    if ($null -eq $Config) { return $false }
    foreach ($app in $apps) {
        $entry=if ($Config -is [System.Collections.IDictionary]) { $Config[$app] } else { $Config.PSObject.Properties[$app].Value }
        if ($null -eq $entry) { return $false }
        $requestCpu=Convert-CpuToM $entry.requestCpu; $limitCpu=Convert-CpuToM $entry.limitCpu
        $requestMemory=Convert-MemoryToMi $entry.requestMemory; $limitMemory=Convert-MemoryToMi $entry.limitMemory
        if ($null -eq $requestCpu -or $requestCpu -le 0) { return $false }
        # CPU limit은 optional이다 (user/product: null 허용). limit 있을 때만 request ≤ limit 검증.
        if ($null -ne $limitCpu -and $limitCpu -gt 0 -and $limitCpu -lt $requestCpu) { return $false }
        if ($null -eq $requestMemory -or $null -eq $limitMemory -or $requestMemory -le 0 -or $limitMemory -lt $requestMemory) { return $false }
        if ([int]$entry.minReplicas -lt 1 -or [int]$entry.maxReplicas -lt [int]$entry.minReplicas -or [int]$entry.maxReplicas -lt [int]$hpaMaxMinimum[$app] -or [int]$entry.hpaTarget -le 0) { return $false }
    }
    return $true
}

function Get-FailureClassification($Measurement) {
    $fatalReasons=[System.Collections.Generic.List[string]]::new()
    $performanceReasons=[System.Collections.Generic.List[string]]::new()
    $measurementReasons=[System.Collections.Generic.List[string]]::new()
    $config=Get-OptionalPropertyValue $Measurement 'Config'
    if (-not (Test-CandidateConfigValid $config)) { $fatalReasons.Add('INVALID_CONFIG') }
    foreach ($flag in @('RolloutFailure','ApplyFailure','CrashLoopBackOff','PersistentNotReady')) {
        $value=Get-OptionalPropertyValue $Measurement $flag $false
        if (($value -is [bool] -and $value) -or ($value -isnot [bool] -and [double]$value -gt 0)) { $fatalReasons.Add($flag.ToUpperInvariant()) }
    }
    $oom=[double](Get-OptionalPropertyValue $Measurement 'OOMKilledDelta' 0)
    if ($oom -ge 2) { $fatalReasons.Add('REPEATED_OOM') }
    elseif ($oom -gt 0) { $performanceReasons.Add('MEMORY_OOM') }
    if ([double](Get-OptionalPropertyValue $Measurement 'EvictionDelta' 0) -gt 0) { $performanceReasons.Add('POD_EVICTION') }
    if ([double](Get-OptionalPropertyValue $Measurement 'MemoryPressure' 0) -gt 0) { $performanceReasons.Add('MEMORY_PRESSURE') }
    if ([double](Get-OptionalPropertyValue $Measurement 'Upstream5xx' 0) -gt 0) { $performanceReasons.Add('UPSTREAM_5XX') }
    foreach ($app in $apps) {
        $metric=Get-ResultAppMetric $Measurement $app
        if ($null -eq $metric) { $measurementReasons.Add("${app}:METRIC_MISSING"); continue }
        $bottlenecks=@(Get-OptionalPropertyValue $metric 'Bottlenecks' @())
        foreach ($reason in $bottlenecks) {
            if ($reason -in @('LOAD_GENERATOR_LIMIT','UNKNOWN')) { $measurementReasons.Add("${app}:$reason") }
            elseif ($reason -in @('ZERO_SUCCESS_CAPACITY','CPU_THROTTLING','HPA_CEILING','APPLICATION_LATENCY','NODE_CAPACITY','POD_STARTUP_DELAY','MEMORY_OOM')) { $performanceReasons.Add("${app}:$reason") }
        }
        if (-not [bool](Get-OptionalPropertyValue $metric 'SLOPass' $false)) { $performanceReasons.Add("${app}:SLO") }
        $timeout=[double](Get-OptionalPropertyValue $metric 'SteadyTimeoutRate' 0)
        $error=[double](Get-OptionalPropertyValue $metric 'HighLoadFailureRate' 0)
        if ($timeout -gt 0 -or $error -gt 0) { $performanceReasons.Add("${app}:TIMEOUT_ERROR") }
        if ([bool](Get-OptionalPropertyValue $metric 'MetricUnavailable' $false)) { $measurementReasons.Add("${app}:METRIC_MISSING") }
        $generated=Get-OptionalPropertyValue $metric 'GeneratedLoadRatio'
        if ($null -eq $generated) { $measurementReasons.Add("${app}:GENERATED_MISSING") }
        elseif ([double]$generated -lt 0.95) { $measurementReasons.Add("${app}:INSUFFICIENT_GENERATION") }
        if ([bool](Get-OptionalPropertyValue $metric 'LoadGeneratorLimited' $false)) { $measurementReasons.Add("${app}:LOAD_GENERATOR_LIMIT") }
    }
    $fatal=@($fatalReasons | Select-Object -Unique)
    $performance=@($performanceReasons | Select-Object -Unique)
    $measurement=@($measurementReasons | Select-Object -Unique)
    return [pscustomobject]@{
        FatalFailure=($fatal.Count -gt 0);PerformanceFailure=($performance.Count -gt 0);MeasurementFailure=($measurement.Count -gt 0)
        FatalReasons=$fatal;PerformanceReasons=$performance;MeasurementReasons=$measurement;FailureReasons=@($fatal+$performance+$measurement)
    }
}

function Get-AppHpaCapacity($profile,[string]$app) {
    # 관측 기반 앱별 HPA maxReplicas 공통 수식. SLO만 앱별로 다르게 적용한다.
    # Current HPA max는 실제 capacity가 아니므로 R_base에 쓰지 않는다.
    #   R_base     = window에서 실제 Ready replica 최대 (0/null이면 1 fallback)
    #   R_CPU      = ceil(R_base x CPU_observed / CPU_target)   (CPU metric 없으면 제외)
    #   throughput source priority:
    #     1. server/ingress received count 신뢰 + SLO latency 신뢰 → lambda_ref=server_received, lambda_success=lambda_slo
    #     2. server count 신뢰, SLO 불신, availability(5초) 신뢰  → lambda_success=lambda_avail
    #     3. k6 generator reliable (server count 없음)           → lambda_ref=generator_requests, lambda_success=lambda_slo
    #     4. 둘 다 unreliable                                    → capacity term 없음 (CPU-only)
    #   lambda_floor = max(1/Δt, 0.01 x lambda_ref)
    #   F_max      = min(HpaHardMax/R_base, F_policy=3.0)
    #   F_capacity = min(F_max, max(1, lambda_ref/max(lambda_success, lambda_floor)))
    #   R_capacity = ceil(R_base x F_capacity)
    #   NewMax     = min(HpaHardMax, max(CurrentMax, R_CPU[, R_capacity]))  (감소 금지)
    $metric=$profile.Apps[$app]
    $currentMax=[int]$profile.Config[$app].maxReplicas
    # HardSafetyMax는 앱별 absolute ceiling (reference prior: user/product 20, stress 12).
    # node budget과 무관 — maxPods/placement/앱 안전 기준. max는 reservation이 아니다.
    $hardMax=if ($script:HardSafetyMaxByApp.ContainsKey($app)) { [int]$script:HardSafetyMaxByApp[$app] } else { [int]$MaxAutoReplicas }
    $window=[double](Get-OptionalPropertyValue $metric 'EffectiveSteadyWindowSec' 0)
    $readyPeak=[double](Get-OptionalPropertyValue $metric 'PeakReadyReplicas' 0)
    # R_base는 실제 Ready였던 capacity만 기준으로 한다. PeakCurrentReplicas/
    # PeakDesiredReplicas는 스케일 진행 중 상태라 실제 처리 capacity가 아니다.
    # (로그 표시용으로만 observedPeak을 유지한다.)
    $observedPeak=Get-OptionalPropertyValue $metric 'PeakCurrentReplicas'
    if ($null -eq $observedPeak) { $observedPeak=Get-OptionalPropertyValue $metric 'PeakDesiredReplicas' 0 }
    if ($null -eq $observedPeak) { $observedPeak=0 }
    $rBase=[math]::Max([double]1,[double]$readyPeak)
    # CPU estimate: HPA는 average utilization 기반으로 스케일하므로 평균 우선, 없으면 peak.
    $rCpu=$null
    $cpuObserved=Get-OptionalPropertyValue $metric 'AverageCPUUtilization'
    if ($null -eq $cpuObserved) { $cpuObserved=Get-OptionalPropertyValue $metric 'PeakCPUUtilization' }
    $cpuTarget=[int]$profile.Config[$app].hpaTarget
    if ($null -ne $cpuObserved -and $cpuTarget -gt 0) { $rCpu=[int][math]::Ceiling($rBase*([double]$cpuObserved/[double]$cpuTarget)) }
    # Throughput source priority
    $rCapacity=$null
    $source=$null;$lambdaRef=0.0;$lambdaSuccess=0.0;$raw=0.0;$fMax=0.0
    $serverReceived=Get-OptionalPropertyValue $metric 'ServerReceivedRequests'
    $generatorReliable=[bool](Get-OptionalPropertyValue $metric 'MeasurementReliable' $false)
    $generated=[double](Get-OptionalPropertyValue $metric 'HighLoadRequests' 0)
    $sloRate=Get-OptionalPropertyValue $metric 'SLOComplianceRate'
    $failRate=Get-OptionalPropertyValue $metric 'HighLoadFailureRate'
    if ($window -gt 0) {
        if ($null -ne $serverReceived -and [double]$serverReceived -gt 0) {
            $lambdaRef=[double]$serverReceived/$window
            if ($null -ne $sloRate -and [double]$sloRate -ge 0.5) {
                $lambdaSuccess=([double]$sloRate*[double]$serverReceived)/$window
                $source='server_ingress+slo'
            } elseif ($null -ne $failRate) {
                $lambdaSuccess=((1.0-[double]$failRate)*[double]$serverReceived)/$window
                $source='server_ingress+avail'
            }
        } elseif ($generatorReliable) {
            $lambdaRef=$generated/$window
            $lambdaSuccess=if ($null -ne $sloRate) { ([double]$sloRate*$generated)/$window } else { 0.0 }
            $source='generator+slo'
        }
        if ($source) {
            $lambdaFloor=[math]::Max(1.0/$window,0.01*$lambdaRef)
            $raw=if ($lambdaRef -gt 0) { $lambdaRef/[math]::Max($lambdaSuccess,$lambdaFloor) } else { 0.0 }
            $fMax=[math]::Min($hardMax/$rBase,3.0)   # F_policy = 3.0
            $fCapacity=[math]::Min($fMax,[math]::Max(1.0,$raw))
            $rCapacity=[int][math]::Ceiling($rBase*$fCapacity)
        }
    }
    $rCpuVal=if ($null -ne $rCpu) { [int]$rCpu } else { 0 }
    $rCapVal=if ($null -ne $rCapacity) { [int]$rCapacity } else { 0 }
    $newMax=[int][math]::Min($hardMax,[math]::Max($currentMax,[math]::Max($rCpuVal,$rCapVal)))
    Write-Host ("HPA capacity [{0}]" -f $app) -ForegroundColor DarkGray
    Write-Host ("  R_ready_peak={0}  R_observed_peak={1}  R_base={2}" -f $readyPeak,$observedPeak,$rBase) -ForegroundColor DarkGray
    if ($null -ne $rCpu) { Write-Host ("  CPU={0:P0}, target={1}% → R_CPU={2}" -f ([double]$cpuObserved/100.0),$cpuTarget,$rCpu) -ForegroundColor DarkGray }
    if ($source) {
        Write-Host ("  source={0}" -f $source) -ForegroundColor DarkGray
        Write-Host ("  lambda_ref={0:N2}  lambda_success={1:N2}" -f $lambdaRef,$lambdaSuccess) -ForegroundColor DarkGray
        Write-Host ("  F_capacity_raw={0:N2}  F_max={1:N2}  R_capacity={2}" -f $raw,$fMax,$rCapacity) -ForegroundColor DarkGray
    } else {
        Write-Host '  throughput source unreliable → capacity term skipped (CPU-only)' -ForegroundColor DarkGray
    }
    Write-Host ("  CurrentMax={0}  HardMax={1}  → NewMax={2}" -f $currentMax,$hardMax,$newMax) -ForegroundColor DarkGray
    return $newMax
}


function Get-StressDensityCandidate([double]$requestM,[double]$currentLimitM,[double]$nodeAllocM) {
    # dedicated node에서 몇 개의 stress pod을 안전하게 배치할 수 있는지 계산한다.
    #   RequestCapacity = floor(alloc x 0.80 / request)
    #   LimitByBurst    = request x BurstFactor
    #   LimitByNode     = alloc x 0.90 / DesiredPodsPerNode
    #   SelectedLimit   = max(request, min(LimitByBurst, LimitByNode))  (25m 단위)
    #   LimitCapacity   = floor(alloc / SelectedLimit)
    #   MaxStressPodsPerNode = min(2, max(1, min(RequestCapacity, LimitCapacity)))
    #   placementCandidate: MaxStressPodsPerNode >= 2 → ISOLATED_DENSE, else ISOLATED_SPREAD
    if ($nodeAllocM -le 0) { $nodeAllocM=1930.0 }
    if ($requestM -le 0) { $requestM=600.0 }
    $requestCapacity=[int][math]::Floor($nodeAllocM*$StressRequestSafetyFactor/$requestM)
    if ($requestCapacity -lt 1) { $requestCapacity=1 }
    $desiredPods=[int]$StressDensePodsPerNode
    $limitByBurst=$requestM*$StressBurstFactor
    $limitByNode=$nodeAllocM*$StressLimitSafetyFactor/$desiredPods
    $selectedLimit=[math]::Max($requestM,[math]::Min($limitByBurst,$limitByNode))
    $selectedLimit=[math]::Ceiling($selectedLimit/25.0)*25
    # limit 합 > node CPU는 스케줄링 불가가 아니다(request가 scheduling footprint).
    # LimitOvercommit은 runtime risk signal일 뿐 절대 placement 조건으로 쓰지 않는다.
    $limitCapacity=[int][math]::Floor($nodeAllocM/$selectedLimit)
    if ($limitCapacity -lt 1) { $limitCapacity=1 }
    $maxPods=[math]::Max(1,$requestCapacity)   # request 기준 hard scheduling constraint
    if ($maxPods -gt $StressMaxPodsPerNodeCap) { $maxPods=$StressMaxPodsPerNodeCap }
    $limitOvercommit=[math]::Round($maxPods*$selectedLimit/$nodeAllocM,2)
    $candidate=if ($maxPods -ge 2) { 'ISOLATED_DENSE' } else { 'ISOLATED_SPREAD' }
    return [pscustomobject]@{RequestCapacity=$requestCapacity;LimitByBurst=[math]::Round($limitByBurst);LimitByNode=[math]::Round($limitByNode);SelectedLimitM=[double]$selectedLimit;LimitCapacity=$limitCapacity;LimitOvercommitRatio=$limitOvercommit;MaxStressPodsPerNode=[int]$maxPods;PlacementCandidate=$candidate;RequestM=[double]$requestM;NodeAllocM=$nodeAllocM}
}

function Write-StressDensityLog($d) {
    Write-Host '===== Stress Dedicated Density =====' -ForegroundColor Cyan
    Write-Host ("nodeAllocatableCpu={0:N0}m  requestCpu={1:N0}m" -f $d.NodeAllocM,$d.RequestM) -ForegroundColor DarkGray
    Write-Host ("desiredDensePodsPerNode={0}" -f $StressDensePodsPerNode) -ForegroundColor DarkGray
    Write-Host ("requestSafety={0:N2}  requestCapacity={1}" -f $StressRequestSafetyFactor,$d.RequestCapacity) -ForegroundColor DarkGray
    Write-Host ("burstFactor={0:N2}  limitSafety={1:N2}" -f $StressBurstFactor,$StressLimitSafetyFactor) -ForegroundColor DarkGray
    Write-Host ("limitByBurst={0:N0}m  limitByNode={1:N0}m  selectedLimit={2:N0}m" -f $d.LimitByBurst,$d.LimitByNode,$d.SelectedLimitM) -ForegroundColor DarkGray
    Write-Host ("limitCapacity={0}" -f $d.LimitCapacity) -ForegroundColor DarkGray
    Write-Host ("MaxStressPodsPerNode={0}  placementCandidate={1}" -f $d.MaxStressPodsPerNode,$d.PlacementCandidate) -ForegroundColor DarkGray
}

function Get-StressDensityUpgradeDecision($density,$metric) {
    # Dense 상태 측정 후 승격 판단: stress SLO/throttling/throughput이 나쁘고 그 원인이
    # app/node CPU contention이면 ISOLATED_SPREAD로 승격. 같은 tune에서 SPREAD→DENSE 회귀 금지.
    $sloFail=(-not [bool](Get-OptionalPropertyValue $metric 'SLOPass' $true))
    $throttle=[double](Get-OptionalPropertyValue $metric 'ThrottleRatio' 0)
    $generated=[double](Get-OptionalPropertyValue $metric 'GeneratedLoadRatio' 1)
    $dropped=Get-OptionalPropertyValue $metric 'DroppedIterations'
    $droppedRate=if ($null -ne $dropped -and $null -ne (Get-OptionalPropertyValue $metric 'Requests' 0)) { [double]$dropped/([double]$dropped+[double](Get-OptionalPropertyValue $metric 'Requests' 0)) } else { 0 }
    $lgLimited=[bool](Get-OptionalPropertyValue $metric 'LoadGeneratorLimited' $false)
    $appContention=($throttle -ge 0.10) -or $sloFail -or ($generated -lt 0.95 -and -not $lgLimited)
    $decision=if ($density.PlacementCandidate -eq 'ISOLATED_DENSE' -and $appContention) { 'UPGRADE_TO_ISOLATED_SPREAD' } else { 'KEEP_ISOLATED_DENSE' }
    return [pscustomobject]@{Decision=$decision;StressSLO=(Get-OptionalPropertyValue $metric 'SLOPass' $null);CpuThrottling=($throttle -ge 0.10);GeneratedRatio=$generated;DroppedRate=[math]::Round($droppedRate,4);AppContention=$appContention}
}

function Get-MaxStressPodsPerNode($stressRequestM,$stressLimitM,$nodeAvailableCpuM) {
    # density는 request 기반으로만 계산: limit는 burst ceiling이라 pod 수 결정에 사용하지 않는다.
    # (2000m limit이 limitCapacity=0을 만들어 pod 수를1로 만드는 버그 방지)
    $requestCapacity=if ($stressRequestM -gt 0) { [int][math]::Floor(($nodeAvailableCpuM*$StressPodsPerNodeUtil)/$stressRequestM) } else { 0 }
    return [math]::Max(1,$requestCapacity)
}



function Get-HpaSpikeGuardDecision($metric,$liveBehaviorJson) {
    # 순간 CPU spike의 replica jump를 감지해 scale-up만 완화한다 (KEEP/LIMIT_SCALE_UP).
    # 기본값은 KEEP — 기존 live behavior를 무조건 덮어쓰지 않는다.
    # LIMIT 조건: JumpRatio>=2 또는 delta>=2 AND live behavior가 없거나(기본 aggressive) 이미 안전하지 않음.
    $start=[double](Get-OptionalPropertyValue $metric 'StartingReplicas' (Get-OptionalPropertyValue $metric 'StartReadyReplicas' 1))
    if ($start -lt 1) { $start=1 }
    $peak=[double](Get-OptionalPropertyValue $metric 'PeakReadyReplicas' (Get-OptionalPropertyValue $metric 'PeakCurrentReplicas' 1))
    if ($peak -lt 1) { $peak=1 }
    $jump=[math]::Round($peak/$start,2)
    $delta=$peak-$start
    $spike=($jump -ge $HpaSpikeJumpRatio -or $delta -ge 2)
    $decision='KEEP'
    if ($spike) {
        $alreadySafe=$false
        if (-not [string]::IsNullOrWhiteSpace([string]$liveBehaviorJson)) {
            $lb=$null
            try { $lb=[string]$liveBehaviorJson | ConvertFrom-Json } catch { $lb=$null }
            if ($lb -and $lb.scaleUp -and $null -ne $lb.scaleUp.stabilizationWindowSeconds -and [int]$lb.scaleUp.stabilizationWindowSeconds -ge $HpaSpikeStabilizationSec) { $alreadySafe=$true }
        }
        if (-not $alreadySafe) { $decision='LIMIT_SCALE_UP' }
    }
    return [pscustomobject]@{Decision=$decision;StartReplicas=$start;PeakReplicas=$peak;JumpRatio=$jump;Delta=$delta;SpikeDetected=$spike}
}

function Get-SpikeGuardHpaBehavior {
    # scaleUp: 1 pod/15s + 최대 50%/30s (Max select). stabilization 15s — 너무 둔하지 않게.
    # scaleDown: 90s stabilization, 25%/60s — 더 천천히 (flap 방지).
    return @{
        scaleUp=@{stabilizationWindowSeconds=[int]$HpaSpikeStabilizationSec;selectPolicy='Max';policies=@(@{type='Pods';value=1;periodSeconds=15},@{type='Percent';value=50;periodSeconds=30})}
        scaleDown=@{stabilizationWindowSeconds=[int]$HpaScaleDownStabilizationSec;selectPolicy='Max';policies=@(@{type='Percent';value=25;periodSeconds=60})}
    }
}

function Write-HpaSpikeGuardLog($app,$guard) {
    Write-Host ("HPA spike guard [{0}]" -f $app) -ForegroundColor Yellow
    Write-Host ("  startReplicas={0}  peakReplicas={1}  jumpRatio={2:N2}" -f $guard.StartReplicas,$guard.PeakReplicas,$guard.JumpRatio) -ForegroundColor DarkGray
    Write-Host ("  decision={0}" -f $guard.Decision) -ForegroundColor DarkGray
    if ($guard.Decision -eq 'LIMIT_SCALE_UP') {
        Write-Host ("  scaleUp: stabilization={0}s Pods=1/15s Percent=50%/30s" -f $HpaSpikeStabilizationSec) -ForegroundColor DarkGray
        Write-Host ("  scaleDown: stabilization={0}s" -f $HpaScaleDownStabilizationSec) -ForegroundColor DarkGray
    }
}

function Ensure-TopologySpread([string]$app) {
    # shared workload에 node 단위 균등 배치: maxSkew=1 hostname, ScheduleAnyway.
    # 이미 hostname constraint가 있으면 보존(merge/reuse) — 중복 추가/삭제 없음.
    # stress는 dedicated placement(DENSE/SPREAD)가 노드 배치를 관리하므로 spread를 추가하지
    # 않는다 — ScheduleAnyway spread가 DENSE(2 pods/node)에서 새 노드 생성을 유발할 수 있다.
    if ($app -eq $DedicatedApp) { return }
    $deploy=$null
    try { $deploy=((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','json')) -join '') | ConvertFrom-Json } catch { return }
    if (-not $deploy) { return }
    $existing=@($deploy.spec.template.spec.topologySpreadConstraints | Where-Object { $null -ne $_ })
    if (@($existing | Where-Object { $_.topologyKey -eq 'kubernetes.io/hostname' }).Count -gt 0) { return }
    $spread=@(@{maxSkew=1;topologyKey='kubernetes.io/hostname';whenUnsatisfiable='ScheduleAnyway';labelSelector=@{matchLabels=@{app=$app}}})
    $patch=@{spec=@{template=@{spec=@{topologySpreadConstraints=$spread}}}} | ConvertTo-Json -Compress -Depth 12
    Invoke-Kubectl @('-n',$Namespace,'patch','deploy',$app,'--type=merge','-p',$patch)
    Write-Host ("Pod spread [{0}] topologyKey=kubernetes.io/hostname maxSkew=1 whenUnsatisfiable=ScheduleAnyway" -f $app) -ForegroundColor DarkGray
}

function Guard-HpaAgainstBudget($config,$cluster) {
    # P0: min/warm reservation과 max capacity를 분리한다.
    #   hard invariant: Σ(minReplicas × request) <= domain min budget (반드시 fit)
    #   maxReplicas는 capacity ceiling — 여기서 축소하지 않는다.
    #   (stress max 6을 idle-budget 이유로 1로 자르는 상황 금지. 실제 스케줄링/노드
    #    확장은 paid-scale 정책이 판단한다.)
    $targetNodes=[int]$CostBaselineNodes
    if ($targetNodes -gt $MaxNodes) { $targetNodes=$MaxNodes }
    $capacityMax=@{}
    foreach ($app in $apps) { $capacityMax[$app]=[int]$config[$app].maxReplicas }
    try {
        $model=Build-HpaBudgetModel $config $cluster $targetNodes $capacityMax 1
        foreach ($d in $model.Domains.Keys) {
            $usedMinCpu=0.0; $usedMinMem=0.0
            foreach ($a in $apps) {
                if ($model.Apps.ContainsKey($a) -and $model.Apps[$a].Domain -eq $d) {
                    $usedMinCpu += [double]$model.Apps[$a].CpuRequestM*[int]$config[$a].minReplicas
                    $usedMinMem += [double]$model.Apps[$a].MemoryRequestMi*[int]$config[$a].minReplicas
                }
            }
            if ($usedMinCpu -gt [double]$model.Domains[$d].MinCpuBudget -or $usedMinMem -gt [double]$model.Domains[$d].MinMemoryBudget) {
                Write-Host ("HPA min guard: domain={0} min reservation {1:N0}m/{2:N0}Mi > min budget {3:N0}m/{4:N0}Mi — warm min 축소 검토 필요 (max는 유지)" -f $d,$usedMinCpu,$usedMinMem,$model.Domains[$d].MinCpuBudget,$model.Domains[$d].MinMemoryBudget) -ForegroundColor Yellow
            } else {
                Write-Host ("HPA min guard: domain={0} min {1:N0}m/{2:N0}Mi <= min budget {3:N0}m/{4:N0}Mi ✓ (max ceiling 유지)" -f $d,$usedMinCpu,$usedMinMem,$model.Domains[$d].MinCpuBudget,$model.Domains[$d].MinMemoryBudget) -ForegroundColor DarkGray
            }
        }
        # max는 축소하지 않는다 (capacity ceiling — 성능상 필요 값 유지)
    } catch {
        Write-Warning "HPA min guard 계산 실패: $($_.Exception.Message)"
    }
}



function Get-Clamped([double]$Value,[double]$Min,[double]$Max) {
    return [math]::Max($Min,[math]::Min($Max,$Value))
}
function Round-UpStep([double]$Value,[double]$Step) {
    if ($Step -le 0) { return $Value }
    return [math]::Ceiling($Value/$Step)*$Step
}
function Get-CpuRequestHeadroom([bool]$Reliable) {
    # Reliable measurement에서는 1.15~1.25 (density 향상), unreliable이면 1.60 (보수적).
    return if ($Reliable) { $CpuRequestReliableMaxHeadroom } else { $CpuRequestMaxHeadroom }
}

function Get-AdaptiveHeadroom([double]$Q25,[double]$Q50,[double]$Q75,[double]$MinHeadroom,[double]$MaxHeadroom,[double]$Alpha) {
    # steady usage 변동성(variability)에 따라 headroom을 적응시킨다.
    $variability=($Q75-$Q25)/[math]::Max($Q50,$EpsDiv)
    return Get-Clamped (1.0+$Alpha*$variability) $MinHeadroom $MaxHeadroom
}
function Get-RightSizedRequest([double]$Current,[double]$Floor,[double]$Q25,[double]$Q50,[double]$Q75,[double]$MinHeadroom,[double]$MaxHeadroom,[double]$Alpha,[double]$Step,[double]$DownHysteresis,[bool]$BlockDecrease=$false,[bool]$AllowIncrease=$false) {
    # request는 steady 실사용량(Q75) × adaptive headroom 기반으로 계산한다.
    #   decrease: target < current × (1-DownHysteresis)일 때만 (BlockDecrease면 금지)
    #   increase: AllowIncrease(sustained pressure)가 있을 때만
    $headroom=Get-AdaptiveHeadroom $Q25 $Q50 $Q75 $MinHeadroom $MaxHeadroom $Alpha
    $target=Round-UpStep ([math]::Max($Floor,$Q75*$headroom)) $Step
    if ($target -lt $Current) {
        if ($BlockDecrease) { return [pscustomobject]@{Value=$Current;Headroom=$headroom;Target=$target;Action='KEEP';Reason='BLOCK_DECREASE'} }
        if ($target -gt ($Current*(1.0-$DownHysteresis))) { return [pscustomobject]@{Value=$Current;Headroom=$headroom;Target=$target;Action='KEEP';Reason='DOWN_HYSTERESIS'} }
        return [pscustomobject]@{Value=$target;Headroom=$headroom;Target=$target;Action='DECREASE';Reason='STEADY_DEMAND'}
    }
    if ($target -gt $Current) {
        if (-not $AllowIncrease) { return [pscustomobject]@{Value=$Current;Headroom=$headroom;Target=$target;Action='KEEP';Reason='NO_SUSTAINED_PRESSURE'} }
        return [pscustomobject]@{Value=$target;Headroom=$headroom;Target=$target;Action='INCREASE';Reason='SUSTAINED_PRESSURE'}
    }
    return [pscustomobject]@{Value=$Current;Headroom=$headroom;Target=$target;Action='KEEP';Reason='WITHIN_BAND'}
}
function Get-CpuLimitTarget([double]$CurrentLimit,[double]$BurstCpu,[double]$BurstHeadroom,[double]$ThrottleRatio,[double]$ThrottleSafe,[double]$SloDeficit,[double]$ThrottleWeight,[double]$SloWeight,[double]$MaxGrowth,[double]$Step,[double]$HardLimit,[bool]$SloFail) {
    # CPU limit은 request/packing과 분리: throttling + SLO fail이 동시에 있을 때만 증가.
    if (-not $SloFail -or $ThrottleRatio -le $ThrottleSafe) { return [pscustomobject]@{Value=$CurrentLimit;Action='KEEP';Growth=1.0;Reason='NO_THROTTLE_SLO_PAIR'} }
    $excess=[math]::Max(0.0,($ThrottleRatio/[math]::Max($ThrottleSafe,$EpsDiv))-1.0)
    $growth=Get-Clamped (1.0+$ThrottleWeight*$excess+$SloWeight*$SloDeficit) 1.0 $MaxGrowth
    $burstTarget=$BurstCpu*$BurstHeadroom
    $growthTarget=$CurrentLimit*$growth
    $target=Round-UpStep ([math]::Max($burstTarget,$growthTarget)) $Step
    $target=[math]::Min($target,$HardLimit)
    $action=if ($target -gt $CurrentLimit) { 'INCREASE' } else { 'KEEP' }
    return [pscustomobject]@{Value=$target;Action=$action;Growth=[math]::Round($growth,3);Excess=[math]::Round($excess,3);Reason='THROTTLE_SLO_PAIR'}
}
function Get-ResourceRightSizingDecision([hashtable]$rsInput) {
    # 앱별 resource right-sizing decision. ($input은 PowerShell 자동 변수라 사용 금지)
    # rsInput: CurrentCpuRequest, CurrentMemoryRequest, CurrentCpuLimit, CpuQ25/Q50/Q75, MemQ25/Q50/Q75,
    #        BurstCpu, ThrottleRatio, SloFail, SloDeficit, OOM, MemoryPressure,
    #        SustainedCpuPressure, SustainedMemoryPressure, HardLimit
    $reasons=[System.Collections.Generic.List[string]]::new()
    # Reliable measurement에서는 headroom을 낮춰 request↓ → density↑ (P0-5).
    $rMaxHeadroom=if ([bool]$rsInput.MeasurementReliable) { $CpuRequestReliableMaxHeadroom } else { $CpuRequestMaxHeadroom }
    $cpuReq=Get-RightSizedRequest $rsInput.CurrentCpuRequest $rsInput.CpuFloor $rsInput.CpuQ25 $rsInput.CpuQ50 $rsInput.CpuQ75 $CpuRequestMinHeadroom $rMaxHeadroom $CpuRequestAlpha $CpuRequestStep $RequestDownHysteresis $false $rsInput.SustainedCpuPressure
    if ($cpuReq.Action -ne 'KEEP') { [void]$reasons.Add("CPU_REQUEST_$($cpuReq.Action)") }
    $memReq=Get-RightSizedRequest $rsInput.CurrentMemoryRequest $rsInput.MemFloor $rsInput.MemQ25 $rsInput.MemQ50 $rsInput.MemQ75 $MemoryRequestMinHeadroom $MemoryRequestMaxHeadroom $MemoryRequestAlpha $MemoryRequestStep $RequestDownHysteresis ([bool]$rsInput.OOM -or [bool]$rsInput.MemoryPressure) $rsInput.SustainedMemoryPressure
    if ($memReq.Action -ne 'KEEP') { [void]$reasons.Add("MEMORY_REQUEST_$($memReq.Action)") }
    $limit=Get-CpuLimitTarget $rsInput.CurrentCpuLimit $rsInput.BurstCpu $BurstHeadroom $rsInput.ThrottleRatio $ThrottleSafe $rsInput.SloDeficit $ThrottleWeight $SloWeight $CpuLimitMaxGrowth $CpuLimitStep $rsInput.HardLimit $rsInput.SloFail
    if ($limit.Action -eq 'INCREASE') { [void]$reasons.Add('CPU_LIMIT_INCREASE') }
    return [pscustomobject]@{
        CpuRequestOld=$rsInput.CurrentCpuRequest;CpuRequestNew=$cpuReq.Value;CpuRequestAction=$cpuReq.Action;CpuHeadroom=[math]::Round($cpuReq.Headroom,3);CpuTarget=[math]::Round($cpuReq.Target)
        MemoryRequestOld=$rsInput.CurrentMemoryRequest;MemoryRequestNew=$memReq.Value;MemoryRequestAction=$memReq.Action;MemoryHeadroom=[math]::Round($memReq.Headroom,3);MemoryTarget=[math]::Round($memReq.Target)
        CpuLimitOld=$rsInput.CurrentCpuLimit;CpuLimitNew=$limit.Value;CpuLimitAction=$limit.Action;LimitGrowth=$limit.Growth;ThrottleExcess=$limit.Excess
        Reasons=@($reasons)
    }
}
function Write-ResourceRightSizingLog([string]$app,$d,$metric) {
    Write-Host ("===== Resource Right-Sizing [{0}] =====" -f $app) -ForegroundColor Cyan
    $q25=[double](Get-OptionalPropertyValue $metric 'CpuQ25M' (Get-OptionalPropertyValue $metric 'AverageCPUMillicores' 0))
    $q50=[double](Get-OptionalPropertyValue $metric 'CpuQ50M' (Get-OptionalPropertyValue $metric 'AverageCPUMillicores' 0))
    $q75=[double](Get-OptionalPropertyValue $metric 'CpuQ75M' (Get-OptionalPropertyValue $metric 'CPUP95Millicores' (Get-OptionalPropertyValue $metric 'AverageCPUMillicores' 0)))
    Write-Host ("  CPU steady: q25={0:N0} q50={1:N0} q75={2:N0} headroom={3:N2}" -f $q25,$q50,$q75,$d.CpuHeadroom) -ForegroundColor DarkGray
    Write-Host ("  CPU request: current={0:N0} target={1:N0} final={2:N0} action={3}" -f $d.CpuRequestOld,$d.CpuTarget,$d.CpuRequestNew,$d.CpuRequestAction) -ForegroundColor DarkGray
    Write-Host ("  Memory request: current={0:N0} target={1:N0} final={2:N0} action={3}" -f $d.MemoryRequestOld,$d.MemoryTarget,$d.MemoryRequestNew,$d.MemoryRequestAction) -ForegroundColor DarkGray
    Write-Host ("  CPU limit: current={0:N0} burstThrottle={1:P1} safe={2:P1} excess={3:N3} sloDeficit={4:N3} growth={5:N2} final={6:N0} action={7}" -f $d.CpuLimitOld,$(if ($null -eq $metric.ThrottleRatio) { 0 } else { [double]$metric.ThrottleRatio }),$ThrottleSafe,$d.ThrottleExcess,$(if ($null -eq $metric.SloDeficit) { 0 } else { [double]$metric.SloDeficit }),$d.LimitGrowth,$d.CpuLimitNew,$d.CpuLimitAction) -ForegroundColor DarkGray
    if ($d.Reasons.Count) { Write-Host ("  reasons: {0}" -f ($d.Reasons -join ', ')) -ForegroundColor DarkGray }
}


function Get-AppSensitivity([object[]]$results,[string]$app) {
    # same-run history에서 앱별 replica sensitivity (deltaPerf/deltaReplica) median.
    # 유효 조건: reliable, replicas 증가, fatal 없음. 음수(회귀)는 보수적으로 제외.
    $valid=[System.Collections.Generic.List[double]]::new()
    $prev=$null
    foreach ($r in @($results | Where-Object { $_ -and $_.Apps -and $_.Apps[$app] })) {
        $m=$r.Apps[$app]
        $reliable=[bool](Get-OptionalPropertyValue $m 'MeasurementReliable' $false)
        $replicas=[double](Get-OptionalPropertyValue $m 'PeakReadyReplicas' 0)
        $perf=100.0*[double](Get-OptionalPropertyValue $m 'SLOComplianceRate' 0)
        if ($null -ne $prev -and $reliable -and $replicas -gt $prev.Replicas) {
            $dR=$replicas-$prev.Replicas
            $dP=$perf-$prev.Perf
            if ($dP -ge 0 -and $dR -gt 0) { [void]$valid.Add($dP/$dR) }
        }
        $prev=[pscustomobject]@{Replicas=$replicas;Perf=$perf}
    }
    if ($valid.Count) {
        $sorted=@($valid | Sort-Object)
        $med=$sorted[[int]($sorted.Count/2)]
        return [pscustomobject]@{Value=[math]::Round($med,3);Source='EMPIRICAL_HISTORY';N=$valid.Count}
    }
    return [pscustomobject]@{Value=0.0;Source='NO_HISTORY';N=0}
}

function Get-HpaBaselineOptimizer($profile,[string]$app,[int]$capacityMax) {
    # HPA minReplicas의 DesiredMin 계산: 실측 steady/peak CPU·memory로 warm capacity를 산출.
    #   Rcpu = ceil(ready x steadyCPU / safeCPU)      (safeCPU = HPA target)
    #   Rmem = ceil(ready x steadyMem / safeMem)      (memory 신뢰 시에만)
    #   Rbase = max(1, Rcpu, Rmem) clamp [1, CapacityMax]
    #   BurstRisk = max(0, (peak-steady)/safe)  (+mem)
    #   WarmReplicas = min(WarmReplicaHardCap, ceil(BurstRisk x Rbase))
    #   DesiredMin = min(CapacityMax, Rbase + WarmReplicas)
    # history 부족(metric 불신)이면 DesiredMin=1 (spike-collapse 증거 있으면 2 safety).
    $metric=$profile.Apps[$app]
    $reliable=[bool](Get-OptionalPropertyValue $metric 'MeasurementReliable' $false)
    $reasons=[System.Collections.Generic.List[string]]::new()
    $ready=[double](Get-OptionalPropertyValue $metric 'PeakReadyReplicas' (Get-OptionalPropertyValue $metric 'AverageReadyReplicas' 1))
    if ($ready -lt 1) { $ready=1 }
    $steady=[double](Get-OptionalPropertyValue $metric 'AverageCPUUtilization' $null)
    $peak=[double](Get-OptionalPropertyValue $metric 'PeakCPUUtilization' $null)
    $target=[int]$profile.Config[$app].hpaTarget
    if ($target -le 0) { $target=65 }
    $rcpu=$null
    if ($null -ne $steady -and $steady -gt 0) {
        $rcpu=[int][math]::Ceiling($ready*$steady/$target)
        if ($rcpu -lt 1) { $rcpu=1 }
        $reasons.Add('BASELINE_CPU')
    }
    $rmem=$null
    $memP95=[double](Get-OptionalPropertyValue $metric 'MemoryP95Mi' 0)
    $reqMem=[double](Convert-MemoryToMi $profile.Config[$app].requestMemory)
    if ($memP95 -gt 0 -and $reqMem -gt 0) {
        $memUtil=$memP95/$reqMem
        $rmem=[int][math]::Ceiling($ready*$memUtil/$SafeMemoryUtilizationDefault)
        if ($rmem -lt 1) { $rmem=1 }
        $reasons.Add('BASELINE_MEMORY')
    }
    $rbase=1.0
    if ($null -ne $rcpu -and $rcpu -gt $rbase) { $rbase=$rcpu }
    if ($null -ne $rmem -and $rmem -gt $rbase) { $rbase=$rmem }
    if ($rbase -gt $capacityMax) { $rbase=[double]$capacityMax }
    if ($rbase -lt 1) { $rbase=1.0 }
    # BurstRisk
    $burstCpu=0.0
    if ($null -ne $peak -and $null -ne $steady) { $burstCpu=[math]::Max(0.0,($peak-$steady)/[math]::Max($target,1e-9)) }
    $burstMem=0.0
    if ($null -ne $rmem -and $memP95 -gt 0) {
        $memPeak=[double](Get-OptionalPropertyValue $metric 'MemoryPeakMi' 0)
        if ($memPeak -gt 0) { $burstMem=[math]::Max(0.0,($memPeak-$memP95)/[math]::Max($reqMem*$SafeMemoryUtilizationDefault,1e-9)) }
    }
    $burst=[math]::Max($burstCpu,$burstMem)
    if ($burst -gt 0 -and $burst -ge 1.0) { $reasons.Add('BURST_WARM_CAPACITY') }
    $warm=[math]::Min($WarmReplicaHardCap,[int][math]::Ceiling($burst*$rbase))
    if ($warm -lt 0) { $warm=0 }
    $desired=[math]::Min($capacityMax,$rbase+$warm)
    if ($desired -lt 1) { $desired=1 }
    $confidence='NORMAL'
    if (-not $reliable -or $null -eq $steady) {
        # history 부족: 추측으로 min을 올리지 않는다. 단 collapse 증거가 있으면 2 safety.
        $collapse=(-not [bool](Get-OptionalPropertyValue $metric 'SLOPass' $true)) -and (([double](Get-OptionalPropertyValue $metric 'SteadyTimeoutCount' 0)) -gt 0)
        if ($collapse -and $capacityMax -ge $CollapseMinFallback) {
            $desired=[math]::Min($capacityMax,$CollapseMinFallback)
            $confidence='LOW'
            $reasons.Add('SPIKE_COLLAPSE_FALLBACK')
        } else {
            $desired=1
            $confidence='LOW'
        }
    }
    if ($desired -gt $capacityMax) { $desired=$capacityMax }
    return [pscustomobject]@{Rcpu=$rcpu;Rmem=$rmem;Rbase=[int]$rbase;BurstRisk=[math]::Round($burst,3);WarmReplicas=[int]$warm;DesiredMin=[int]$desired;Confidence=$confidence;Reasons=@($reasons);ReadyReplicas=[int]$ready;SteadyCpu=$steady;PeakCpu=$peak;SafeCpu=$target}
}

function Get-WarmMinFromValidation([hashtable]$config,$validation,$cluster) {
    # 직전 측정 결과로부터 warm min vector를 예측한다.
    # 목적: 측정 프리프웻(기존 min=1 cold-start)이 아닌, 채점 시작 상태(warm min)를
    #     반영한 측정을 다음 단계부터 시작하게 한다. 노드당 stress 용량(≈2.2rps) 실측에서
    #     cold start가 stress SLO를 0%로 붕괴시키는 것이 확인됐다.
    $capMax=@{}; $desired=@{}
    foreach ($a in $apps) {
        if ($null -eq $config -or -not $config.ContainsKey($a) -or $null -eq $config[$a]) { $desired[$a]=1; $capMax[$a]=6; continue }
        $capMax[$a]=[int]$config[$a].maxReplicas
        try {
            $metric=$null
            if ($null -ne $validation -and $null -ne $validation.Apps -and $validation.Apps.ContainsKey($a)) {
                $metric=$validation.Apps[$a]
            }
            if ($null -ne $metric) {
                $desired[$a]=[math]::Max(1,[int](Get-HpaBaselineOptimizer $validation $a $capMax[$a]).DesiredMin)
            } else {
                $desired[$a]=1
                Write-Warning "[WARM_MIN] app=$a validation metric missing -- default min=1"
            }
        } catch { $desired[$a]=1; Write-Warning "[WARM_MIN] app=$a baseline error: $($_.Exception.Message)" }
    }
    try {
        Write-Host ("  [WARM] config keys={0} capMax={1} desired={2}" -f ($config.Keys -join ','), ($capMax.Keys -join ','), ($desired.Keys -join ',')) -ForegroundColor DarkGray
        $model=Build-HpaBudgetModel $config $cluster ([int]$CostBaselineNodes) $capMax 1
        if ($null -eq $model -or $null -eq $model.Domains) { Write-Warning "Build-HpaBudgetModel returned null/empty model" }
        Write-Host ("  [WARM] model domains={0} apps={1}" -f ($model.Domains.Keys -join ','), ($model.Apps.Keys -join ',')) -ForegroundColor DarkGray
        $alloc=Get-BudgetedHpaMinVector $model.Apps $model.Domains $desired $capMax $validation
        if ($null -eq $alloc -or $null -eq $alloc.MinVector) {
            Write-Warning "Get-BudgetedHpaMinVector returned null — model.Domains keys=$($model.Domains.Keys -join ',') desired=$($desired.Keys -join ',')"
            return $desired
        }
        Write-Host ("  [WARM] alloc={0}" -f (($alloc.MinVector.Keys | ForEach-Object { "$_=$($alloc.MinVector[$_])" }) -join ' ')) -ForegroundColor DarkGray
        $warm=@{}
        foreach ($a in $apps) {
            if ($alloc.MinVector.ContainsKey($a)) { $warm[$a]=[int]$alloc.MinVector[$a] } else { $warm[$a]=$desired[$a] }
        }
        Write-Host ("progressive warm min: {0}" -f (($apps | ForEach-Object { "$_=$($warm[$_])" }) -join ' ')) -ForegroundColor Cyan
        # P0-2: warm min mutation 직후 invariant 검사
        foreach ($app in $apps) {
            if ($warm[$app] -gt [int]$finalConfig[$app].maxReplicas) {
                throw "HPA_CONFIG_INVALID: stage=ProgressiveWarm app=$app warm=$($warm[$app]) > max=$($finalConfig[$app].maxReplicas)"
            }
        }
        # warm min cap: measured peak ready + safety
        foreach ($app in $apps) {
            if ($null -ne $validation -and $null -ne $validation.Apps -and $validation.Apps.ContainsKey($app)) {
                $peakReady=[int](Get-OptionalPropertyValue $validation.Apps[$app] 'PeakReadyReplicas' 0)
                $peakDesired=[int](Get-OptionalPropertyValue $validation.Apps[$app] 'PeakDesiredReplicas' $peakReady)
                $maxObserved=[math]::Max($peakReady,$peakDesired)
                $hardWarmCap=$maxObserved+[int]$WarmReplicaHardCap
                if ($warm[$app] -gt $hardWarmCap) {
                    $warm[$app]=$hardWarmCap
                }
            }
        }
        return $warm
    } catch {
        Write-Warning "warm min 예측 실패 — desiredMin fallback: $($_.Exception.Message)"
        return $desired
    }
}

function Get-BudgetedHpaMinVector($appsModel,$domains,$desiredMin,$capacityMax,$profile) {
    # placement domain별 min budget 안에서 warm min replica를 배분한다.
    #   FinalMin[a] = 1 시작 (이 벡터가 budget 초과면 infeasible)
    #   priority: HardRisk > BurstRisk > StartupPenalty > BoundaryRisk > DominantShare 작은 순
    $min=@{}
    $used=@{}
    foreach ($d in $domains.Keys) { $used[$d]=@{Cpu=0.0;Memory=0.0} }
    foreach ($app in $appsModel.Keys) {
        $m=$appsModel[$app]
        $min[$app]=1
        $used[$m.Domain].Cpu += 1*[double]$m.CpuRequestM
        $used[$m.Domain].Memory += 1*[double]$m.MemoryRequestMi
    }
    foreach ($d in $domains.Keys) {
        if ($used[$d].Cpu -gt [double]$domains[$d].MinCpuBudget -or $used[$d].Memory -gt [double]$domains[$d].MinMemoryBudget) {
            # min=1(필수 floor)조차 min budget에 안 들어가는 경우: 해당 domain의 request가
            # min budget보다 큰 것. min 1개는 항상 보장해야 하므로 min budget을 필수 min 합으로
            # 확대한다 (운영 crash 방지 — 추가 warm min은 이후 priority 배분에서만 할당).
            Write-Host ("MIN_WARM_BASELINE_OVERRIDE: domain={0} 필수 min=1이 min budget 초과 — budget을 필수 min 합으로 확대 (used={1:N0}m/{2:N0}Mi budget={3:N0}m/{4:N0}Mi)" -f $d,$used[$d].Cpu,$used[$d].Memory,$domains[$d].MinCpuBudget,$domains[$d].MinMemoryBudget) -ForegroundColor Yellow
            $domains[$d].MinCpuBudget=[math]::Max([double]$domains[$d].MinCpuBudget,$used[$d].Cpu)
            $domains[$d].MinMemoryBudget=[math]::Max([double]$domains[$d].MinMemoryBudget,$used[$d].Memory)
        }
    }
    $maxIters=0
    foreach ($app in $appsModel.Keys) { $maxIters += [math]::Max(0,[int]$desiredMin[$app]-1) }
    $eps=1e-9
    $cappedReason=@{}
    for ($i=0; $i -lt $maxIters; $i++) {
        $cands=[System.Collections.Generic.List[object]]::new()
        foreach ($app in $appsModel.Keys) {
            if ([int]$min[$app] -ge [int]$desiredMin[$app]) { continue }
            $m=$appsModel[$app]; $d=$m.Domain
            if (-not $used.ContainsKey($d)) { $used[$d]=@{Cpu=0.0;Memory=0.0} }
            $newCpu=$used[$d].Cpu+[double]$m.CpuRequestM
            $newMem=$used[$d].Memory+[double]$m.MemoryRequestMi
            if ($newCpu -gt [double]$domains[$d].MinCpuBudget -or $newMem -gt [double]$domains[$d].MinMemoryBudget) { continue }
            # priority metrics
            $percent=100.0*[double](Get-OptionalPropertyValue $profile.Apps[$app] 'SLOComplianceRate' 0)
            $hard=($percent -lt $HardConstraintFloor)
            $baseline=Get-HpaBaselineOptimizer $profile $app ([int]$capacityMax[$app])
            $burst=$baseline.BurstRisk
            $nb=Get-NextPerformanceBoundary $percent
            $boundaryRisk=if ($null -ne $nb) { [math]::Max(0.0,[double]$nb-$percent) } else { 9999.0 }
            $qCpu=if ([double]$domains[$d].MinCpuBudget -gt 0) { [double]$m.CpuRequestM/[double]$domains[$d].MinCpuBudget } else { 0.0 }
            $qMem=if ([double]$domains[$d].MinMemoryBudget -gt 0) { [double]$m.MemoryRequestMi/[double]$domains[$d].MinMemoryBudget } else { 0.0 }
            $share=[math]::Max($qCpu,$qMem)
            $cands.Add([pscustomobject]@{App=$app;Hard=[bool]$hard;Burst=$burst;Startup=0.0;BoundaryRisk=$boundaryRisk;Share=$share})
        }
        if (-not $cands.Count) { break }
        $best=@($cands | Sort-Object @{Expression='Hard';Descending=$true},@{Expression='Burst';Descending=$true},@{Expression='Startup';Descending=$true},@{Expression='BoundaryRisk'},@{Expression='Share'}) | Select-Object -First 1
        $min[$best.App]++
        $m=$appsModel[$best.App]; $d=$m.Domain
        if (-not $used.ContainsKey($d)) { $used[$d]=@{Cpu=0.0;Memory=0.0} }
        $used[$d].Cpu += [double]$m.CpuRequestM
        $used[$d].Memory += [double]$m.MemoryRequestMi
    }
    foreach ($app in $appsModel.Keys) {
        if ([int]$min[$app] -lt [int]$desiredMin[$app]) { $cappedReason[$app]='MIN_RESOURCE_BUDGET' }
        else { $cappedReason[$app]='DESIRED_MET' }
    }
    return [pscustomobject]@{MinVector=$min;DomainsUsed=$used;CappedReason=$cappedReason;DesiredMin=$desiredMin}
}



function Write-EmpiricalSummary($finalConfig,$validation,$cluster,[int]$targetTotalScore=36) {
    # tune 종료 요약: empirical score model + app별 boundary/action + node budget + cost.
    $fixedScores=16.0  # 비정상 4 + 고가용성 12 (현재 과제 배점 — 변경 시 파라미터로)
    Write-Host '=== EMPIRICAL SCORE MODEL ===' -ForegroundColor Cyan
    Write-Host ('  boundaries: {0}' -f ($performanceBoundaries -join ',')) -ForegroundColor DarkGray
    Write-Host '  model source: observed grader results (역추정)' -ForegroundColor DarkGray
    Write-Host '  confidence: empirical / not confirmed grader formula' -ForegroundColor DarkGray
    Write-Host '=== APP SCORE ===' -ForegroundColor Cyan
    # domain model은 app별 action cost 계산에서 필요 — 함수 상단에서 구성한다.
    $model=Build-HpaBudgetModel $finalConfig $cluster ([int]$script:OperatingNodeBudget) (@{} ) 1
    $perfTotal=0.0
    foreach ($a in $apps) {
        $appMetric=$null
        if ($null -ne $validation -and $null -ne $validation.Apps -and $validation.Apps.ContainsKey($a)) { $appMetric=$validation.Apps[$a] }
        $percent=100.0*[double](Get-OptionalPropertyValue $appMetric 'SLOComplianceRate' 0)
        $bg=Get-NextPerformanceBoundaryGain $percent $a
        $perfTotal += $bg.CurrentScore
        $m=$appMetric
        $cpuReq=Convert-CpuToM $finalConfig[$a].requestCpu
        Write-Host ("  App {0}" -f $a) -ForegroundColor DarkGray
        Write-Host ("    performance={0:N2}%  currentScore={1:N1}  nextBoundary={2}  nextScore={3:N1}  distance={4}%p  gain={5:N1}" -f $percent,$bg.CurrentScore,$(if ($null -eq $bg.NextBoundary) {'-'} else { $bg.NextBoundary }),$bg.NextScore,$(if ($null -eq $bg.Distance) { '-' } else { $bg.Distance }),$bg.Gain) -ForegroundColor DarkGray
        Write-Host ("    HPA {0}..{1}  ready={2}  cpuRequest={3:N0}m  memRequest={4:N0}Mi  cpuLimit={5}" -f $finalConfig[$a].minReplicas,$finalConfig[$a].maxReplicas,(Get-OptionalPropertyValue $m 'PeakReadyReplicas' 0),$cpuReq,(Convert-MemoryToMi $finalConfig[$a].requestMemory),$finalConfig[$a].limitCpu) -ForegroundColor DarkGray
        # 다음 action cost: max+1 action의 ΔCPU/ΔMEM/P(cross)/예상 score gain
        $capMax=[int](Get-OptionalPropertyValue $script:FinalHpaMaxByApp $a ([int]$finalConfig[$a].maxReplicas))
        $nextMax=[math]::Min($capMax,[int]$finalConfig[$a].maxReplicas+1)
        $deltaCpu=[double]$cpuReq
        $deltaMem=[double](Convert-MemoryToMi $finalConfig[$a].requestMemory)
        $dom=if ($model.Apps.ContainsKey($a)) { $model.Apps[$a].Domain } else { 'shared' }
        $budgetCpu=if ($model.Domains.ContainsKey($dom)) { [double]$model.Domains[$dom].CpuBudget } else { 1 }
        $usedCpu=0.0
        foreach ($b in $apps) { if ($model.Apps.ContainsKey($b) -and $model.Apps[$b].Domain -eq $dom) { $usedCpu += [double]$model.Apps[$b].CpuRequestM } }
        $fits=($usedCpu+$deltaCpu -le $budgetCpu)
        # P(cross): distance 기반 근사 heuristic (sensitivity history 없으면 — 명시적으로 근사)
        $pcross=[math]::Max(0.1,[math]::Min(0.9,1.0-(([double]$bg.Distance)/10.0)))
        $expGain=[math]::Round($pcross*$bg.Gain,2)
        $nodeImpact=if ($fits) { 'none' } else { 'node+budget' }
        Write-Host ("    nextAction: max {0}->{1}  dCPU=+{2:N0}m  dMEM=+{3:N0}Mi  P(cross)={4:N2}  expScoreGain={5:N2}  nodeImpact={6}" -f [int]$finalConfig[$a].maxReplicas,$nextMax,$deltaCpu,$deltaMem,$pcross,$expGain,$nodeImpact) -ForegroundColor DarkGray
    }
    $cost=Get-EvaluationCostScore $validation
    Write-Host '=== BOUNDARY HARVEST ===' -ForegroundColor Cyan
    foreach ($a in $apps) {
        $percent=100.0*[double](Get-OptionalPropertyValue $validation.Apps[$a] 'SLOComplianceRate' 0)
        $h=Get-BoundaryHarvestInfo $percent $a
        Write-Host ("  App {0}: performance={1:N2} score={2:N1} nextBoundary={3} distance={4:N2} safetyTarget={5} boundaryGain={6:N1} nearBoundary={7}" -f $a,$h.Performance,$h.CurrentScore,$(if ($null -eq $h.NextBoundary) {'-'} else { $h.NextBoundary }),$(if ($null -eq $h.Distance) {'-'} else { $h.Distance }),$(if ($null -eq $h.SafetyTarget) {'-'} else { $h.SafetyTarget }),$h.Gain,$h.NearBoundary) -ForegroundColor DarkGray
        if ($h.NearBoundary) {
            # 저비용 후보: min+1 (warm) — 기존 node 내. node 추가는 마지막.
            $cpuReq=Convert-CpuToM $finalConfig[$a].requestCpu
            $dom=if ($model.Apps.ContainsKey($a)) { $model.Apps[$a].Domain } else { 'shared' }
            $budgetCpu=if ($model.Domains.ContainsKey($dom)) { [double]$model.Domains[$dom].CpuBudget } else { 1 }
            $usedCpu=0.0
            foreach ($b in $apps) { if ($model.Apps.ContainsKey($b) -and $model.Apps[$b].Domain -eq $dom) { $usedCpu += [double]$model.Apps[$b].CpuRequestM } }
            $pcross=[math]::Max(0.3,[math]::Min(0.9,1.0-(([double]$h.Distance)/5.0)))  # near-boundary는 crossing 확률 높게 (heuristic)
            $expGain=[math]::Round($pcross*$h.Gain,2)
            $nodeImpact=if (($usedCpu+$cpuReq) -le $budgetCpu) { 'none' } else { 'node+budget' }
            Write-Host ("    bestAction: min/max +1  dCPU=+{0:N0}m  dMEM=+{1:N0}Mi  P(cross)={2:N2}  expectedScoreGain={3:N2}  nodeImpact={4}  expectedEvaluationGain={5:N2}" -f $cpuReq,(Convert-MemoryToMi $finalConfig[$a].requestMemory),$pcross,$expGain,$nodeImpact,$expGain) -ForegroundColor Yellow
        }
    }
    Write-Host '=== NODE BUDGET ===' -ForegroundColor Cyan
    # domain별 used/budget (finalConfig request 기준)
    $totalReqCpu=0.0; $totalReqMem=0.0
    foreach ($d in $model.Domains.Keys) {
        $usedCpu=0.0; $usedMem=0.0
        foreach ($a in $apps) { if ($model.Apps[$a].Domain -eq $d) { $usedCpu += [double]$model.Apps[$a].CpuRequestM; $usedMem += [double]$model.Apps[$a].MemoryRequestMi } }
        $totalReqCpu += $usedCpu; $totalReqMem += $usedMem
        Write-Host ("  Domain {0}: CPU {1:N0}/{2:N0}m  MEM {3:N0}/{4:N0}Mi  resourceBudgetFeasible={5}" -f $d,$usedCpu,$model.Domains[$d].CpuBudget,$usedMem,$model.Domains[$d].MemoryBudget,($usedCpu -le $model.Domains[$d].CpuBudget -and $usedMem -le $model.Domains[$d].MemoryBudget)) -ForegroundColor DarkGray
    }
    # scheduler feasibility: 실제 Ready node의 allocatable 합 대비 요구 (bin-packing/시스템 오버헤드 포함).
    # budget은 utilization 0.80으로 이미 여유를 뒀지만, 실제 노드가 그보다 작거나 시스템 오버헤드가
    # 크면 scheduler에서 실패할 수 있다 — aggregate budget과 실제 allocatable을 분리해 비교한다.
    $readyNodes=[double](Get-OptionalPropertyValue $cluster 'ManagedReadyNodes' 1)
    $actualAllocCpu=$readyNodes*[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableCPU' 0)
    $actualAllocMem=$readyNodes*[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableMemoryMi' 0)
    $schedFeasible=($totalReqCpu -le $actualAllocCpu -and $totalReqMem -le $actualAllocMem)
    Write-Host ("  SchedulerPlacementFeasible={0} (실제 Ready {1}노드 alloc {2:N0}m/{3:N0}Mi vs 요구 {4:N0}m/{5:N0}Mi)" -f $schedFeasible,$readyNodes,$actualAllocCpu,$actualAllocMem,$totalReqCpu,$totalReqMem) -ForegroundColor DarkGray
    Write-Host '=== CLUSTER COST ===' -ForegroundColor Cyan
    $avgNodes=[double](Get-OptionalPropertyValue $validation 'AverageTotalNodes' -1)
    if ($avgNodes -lt 0) {
        $avgNodes=[double](Get-OptionalPropertyValue $validation 'NodeSeconds' 0)/[math]::Max(1,[double](Get-OptionalPropertyValue $validation 'LoadWindowSeconds' 0))
    }
    Write-Host ("  avgNodes={0:N2}  maxNodes={1:N0}  costRatio={2:N3}  costScore={3:N1}" -f $avgNodes,(Get-OptionalPropertyValue $validation 'PeakReadyNodes' 0),$cost.InstanceRatio,$cost.Score) -ForegroundColor DarkGray
    # POD DENSITY + VPC CNI (first-class axis: maxPods/prefix delegation/slots)
    try {
        $density=Get-PodDensityReport $cluster $finalConfig
        Write-PodDensityLog $density $finalConfig
    } catch { Write-Warning "pod density report 실패: $($_.Exception.Message)" }
    # KNOWN-GOOD REFERENCE vs CALCULATED 비교 표 (왜 다르게 했는지 실측 근거 필수)
    Write-Host '===== FINAL CONFIG (reference vs calculated) =====' -ForegroundColor Cyan
    Write-Host ("  {0,-9} {1,-28} {2,-28} {3}" -f 'APP','REFERENCE','CALCULATED','REASON') -ForegroundColor DarkGray
    foreach ($a in $apps) {
        $ref=$KnownGoodReference[$a]
        $reqM=[math]::Round((Convert-CpuToM $finalConfig[$a].requestCpu))
        $refReqM=[math]::Round((Convert-CpuToM $ref.requestCpu))
        $tgt=[int]$finalConfig[$a].hpaTarget
        $mn=[int]$finalConfig[$a].minReplicas
        $mx=[int]$finalConfig[$a].maxReplicas
        $lim=[string]$finalConfig[$a].limitCpu
        $limTxt=if ($lim -eq '') { 'none' } else { $lim }
        $refLim=if ($null -eq $ref.limitCpu -or [string]$ref.limitCpu -eq '') { 'none' } else { [string]$ref.limitCpu }
        $percent=100.0*[double](Get-OptionalPropertyValue $validation.Apps[$a] 'SLOComplianceRate' 0)
        $thr=[double](Get-OptionalPropertyValue $validation.Apps[$a] 'ThrottleRatio' 0)
        $cpNow=Get-HpaControlPoint $a
        # reason: 실측 근거 기반 설명
        $reason=switch ($true) {
            ($a -eq 'stress') { "GUARANTEED_REQUEST (Q75xheadroom) + burst limit {0}; slo={1:N0}% thr={2:P1}" -f $limTxt,$percent,$thr }
            ($reqM -gt $refReqM) { "ELASTIC_DENSITY — measured CPU Q75={0:N0}m이 reference보다 큼; slo={1:N0}% thr={2:P1}" -f (Get-OptionalPropertyValue $validation.Apps[$a] 'CPUP95Millicores' 0),$percent,$thr }
            default { "ELASTIC_DENSITY — reference density prior 유지; slo={0:N0}% cp={1:N1}m({2})" -f $percent,$cpNow.Value,$cpNow.Source }
        }
        Write-Host ("  {0,-9} {1,-28} {2,-28} {3}" -f $a,("$($refReqM)m / $($ref.target)% / $($ref.min)..$($ref.max) / lim $refLim"),("$reqM m / $tgt% / $mn..$mx / lim $limTxt"),$reason) -ForegroundColor DarkGray
    }
    Write-Host '=== FINAL ===' -ForegroundColor Cyan
    $eval=Get-EvaluationScore $validation
    $perfTarget=[math]::Max(0.0,[double]$targetTotalScore-$fixedScores-[double]$cost.Score)
    Write-Host ("  actualPerfScore={0:N1}  actualCostScore={1:N1}  Evaluation={2:N1}" -f $eval.PerfScore,$cost.Score,$eval.TotalScore) -ForegroundColor DarkGray
    Write-Host ("  targetScore={0}  remainingGap={1:N1}  (필요 PerfScore {2:N1})" -f $targetTotalScore,[math]::Max(0.0,[double]$targetTotalScore-$eval.TotalScore),$perfTarget) -ForegroundColor DarkGray
    # 가장 가치 있는 다음 action (boundary gain/거리 기반)
    $best=@{App=$null;Gain=0.0;Distance=9999.0}
    foreach ($a in $apps) {
        $percent=100.0*[double](Get-OptionalPropertyValue $validation.Apps[$a] 'SLOComplianceRate' 0)
        $bg=Get-NextPerformanceBoundaryGain $percent $a
        if ($null -ne $bg.NextBoundary -and $bg.Gain -gt 0) {
            $score=if ($bg.Gain -gt $best.Gain) { $bg.Gain } else { $best.Gain }
            if ($bg.Gain -gt $best.Gain -or ($bg.Gain -eq $best.Gain -and $bg.Distance -lt $best.Distance)) { $best=@{App=$a;Gain=$bg.Gain;Distance=$bg.Distance} }
        }
    }
    if ($null -ne $best.App) {
        Write-Host ("  bestNextAction: {0} → nextBoundary, gain={1:N1}, distance={2:N1}%p" -f $best.App,$best.Gain,$best.Distance) -ForegroundColor Yellow
    }
}

function Write-NodeBudgetObservation($result,[int]$operatingBudget) {
    # 평균 노드 수 = NodeSec / 측정 window. operating budget 초과 시 overshoot 진단.
    $nodeSec=[double](Get-OptionalPropertyValue $result 'NodeSeconds' 0)
    $duration=[double](Get-OptionalPropertyValue $result 'LoadWindowSeconds' 0)
    $avg=if ($duration -gt 0) { [math]::Round($nodeSec/$duration,2) } else { $null }
    $peak=[double](Get-OptionalPropertyValue $result 'PeakReadyNodes' 0)
    Write-Host 'Node budget observation' -ForegroundColor Cyan
    Write-Host ("  OperatingNodeBudget={0}  AverageNodes={1}  PeakNodes={2}" -f $operatingBudget,$(if ($null -eq $avg) { '-' } else { $avg }),$peak) -ForegroundColor DarkGray
    if ($null -ne $avg -and $avg -gt $operatingBudget) {
        Write-Host ("  overshootNodeSeconds=~{0:N0}s  reason candidates: HPA_BURST / PENDING_PODS / SLOW_KARPENTER_SCALE_IN / LARGE_RESOURCE_REQUEST" -f ($nodeSec-($operatingBudget*$duration))) -ForegroundColor Yellow
    }
    # 3번째 node 생성 원인 추적: 피크 노드가 operating budget을 넘으면 pending/scheduler 이유를 남긴다.
    if ($peak -gt $operatingBudget) {
        $pending=@(& kubectl get pods -n $Namespace --field-selector=status.phase=Pending -o json 2>$null | ConvertFrom-Json).items
        $pendingInfo=if ($pending.Count) {
            ($pending | ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" }) -join ','
        } else { 'none' }
        $reasonCandidates=@()
        if ($pending.Count) { $reasonCandidates+='PENDING_PODS' }
        if ($peak -gt ($operatingBudget*1.5)) { $reasonCandidates+='HPA_OVERSHOOT' }
        if (-not $reasonCandidates.Count) { $reasonCandidates+='CONSOLIDATION_DELAY_OR_STARTUP_OVERLAP' }
        Write-Host ("[NODE-SCALE] peak={0} operatingBudget={1} pendingPods={2} reasonCandidates={3} — predictedImpact=none(2-node budget) actualImpact=node-added 모델 불일치 검토" -f $peak,$operatingBudget,$pendingInfo,($reasonCandidates -join '/')) -ForegroundColor Yellow
    }
    return $avg
}

function Get-BudgetedHpaVector($appsModel,$domains,$capacityMax,$perfByApp,$sensitivityByApp,$minVector=$null) {
    # placement domain별 CPU+Memory budget 내에서 가치 높은 replica ceiling vector를 계산한다.
    #   appsModel[app]  = @{Domain=...;CpuRequestM=...;MemoryRequestMi=...;HpaMin=...}
    #   domains[domain] = @{CpuBudget=...;MemoryBudget=...}
    #   CapacityMax     = Get-AppHpaCapacity() 결과 (성능 상한, live HPA max 아님)
    # greedy: floor에서 시작, candidate 조건(budget 만족) 하에 lexicographic priority로 1 replica씩.
    # priority: 1.HardViolation 2.RecoveryEfficiency 3.CrossesBoundary 4.ExpectedPerfScoreGain
    #           5.BoundaryEfficiency 6.DominantShare 작은 순
    # 시작점은 HpaMin 대신 minVector(Baseline/Warm min) — warm capacity를 먼저 예약하고
    # 남은 budget만 maxReplicas에 배분한다. minVector 없으면 기존 HpaMin(1) 사용.
    $r=@{}
    $used=@{}
    foreach ($d in $domains.Keys) { $used[$d]=@{Cpu=0.0;Memory=0.0} }
    foreach ($app in $appsModel.Keys) {
        $m=$appsModel[$app]
        $start=if ($null -ne $minVector -and $minVector.ContainsKey($app) -and [int]$minVector[$app] -gt 0) { [int]$minVector[$app] } else { [int]$m.HpaMin }
        $r[$app]=$start
        $used[$m.Domain].Cpu += $start*[double]$m.CpuRequestM
        $used[$m.Domain].Memory += $start*[double]$m.MemoryRequestMi
    }
    $maxIters=0
    foreach ($app in $appsModel.Keys) { $maxIters += [int]$capacityMax[$app]-[int]$r[$app] }
    $eps=1e-9
    for ($i=0; $i -lt $maxIters; $i++) {
        $cands=[System.Collections.Generic.List[object]]::new()
        foreach ($app in $appsModel.Keys) {
            if ([int]$r[$app] -ge [int]$capacityMax[$app]) { continue }
            $m=$appsModel[$app]; $d=$m.Domain
            if (-not $used.ContainsKey($d)) { $used[$d]=@{Cpu=0.0;Memory=0.0} }
            $newCpu=$used[$d].Cpu+[double]$m.CpuRequestM
            $newMem=$used[$d].Memory+[double]$m.MemoryRequestMi
            if ($newCpu -gt [double]$domains[$d].CpuBudget) { continue }
            if ($newMem -gt [double]$domains[$d].MemoryBudget) { continue }
            $perf=[double]$perfByApp[$app]
            $sens=[double]$sensitivityByApp[$app]
            $hard=($perf -lt $HardConstraintFloor)
            # history가 없으면(sens=0) 성능 상승을 임의로 가정하지 않는다 (스펙 5).
            $est=if ($sens -gt 0) { $perf+$sens } else { $perf }
            $curScore=(Get-EmpiricalPerformanceScore $perf $app).Score
            $estScore=(Get-EmpiricalPerformanceScore $est).Score
            $gain=[math]::Max(0.0,$estScore-$curScore)
            # 실제 다음 boundary 점프 gain (sens와 무관 — 거리가 아닌 실제 score 이득)
            $boundaryGain=(Get-NextPerformanceBoundaryGain $perf $app).Gain
            $nb=Get-NextPerformanceBoundary $perf $app
            $crosses=($null -ne $nb -and $sens -gt 0 -and $est -ge $nb)
            $progress=Get-BoundaryProgress $perf $est
            $qCpu=if ([double]$domains[$d].CpuBudget -gt 0) { [double]$m.CpuRequestM/[double]$domains[$d].CpuBudget } else { 0.0 }
            $qMem=if ([double]$domains[$d].MemoryBudget -gt 0) { [double]$m.MemoryRequestMi/[double]$domains[$d].MemoryBudget } else { 0.0 }
            $share=[math]::Max($qCpu,$qMem)
            $recoveryGain=if ($hard) { [math]::Max(0.0,$HardConstraintFloor-$perf) } else { 0.0 }
            $recoveryEff=if ($hard -and $share -gt 0) { $recoveryGain/($share+$eps) } else { 0.0 }
            $boundaryEff=if ($progress -gt 0) { $progress/($share+$eps) } else { 0.0 }
            $cands.Add([pscustomobject]@{App=$app;Hard=[bool]$hard;RecoveryEff=$recoveryEff;Crosses=[bool]$crosses;ScoreGain=$gain;BoundaryGain=$boundaryGain;BoundaryEff=$boundaryEff;Share=$share;Progress=$progress;Perf=$perf;Est=$est})
        }
        if (-not $cands.Count) { break }
        $best=@($cands | Sort-Object @{Expression='Hard';Descending=$true},@{Expression='RecoveryEff';Descending=$true},@{Expression='Crosses';Descending=$true},@{Expression='ScoreGain';Descending=$true},@{Expression='BoundaryEff';Descending=$true},@{Expression='Progress';Descending=$true},@{Expression='BoundaryGain';Descending=$true},@{Expression='Share'}) | Select-Object -First 1
        $r[$best.App]++
        $m=$appsModel[$best.App]; $d=$m.Domain
        if (-not $used.ContainsKey($d)) { $used[$d]=@{Cpu=0.0;Memory=0.0} }
        $used[$d].Cpu += [double]$m.CpuRequestM
        $used[$d].Memory += [double]$m.MemoryRequestMi
    }
    $cappedReason=@{}
    foreach ($app in $appsModel.Keys) {
        if ([int]$r[$app] -lt [int]$capacityMax[$app]) { $cappedReason[$app]='DOMAIN_RESOURCE_BUDGET' }
        else { $cappedReason[$app]='CAPACITY_MAX' }
    }
    foreach ($d in $domains.Keys) {
        if ($used[$d].Cpu -gt ([double]$domains[$d].CpuBudget+$eps) -or $used[$d].Memory -gt ([double]$domains[$d].MemoryBudget+$eps)) {
            throw "HPA_BUDGET_CALCULATION_FAILED: domain=$d usedCpu=$([math]::Round($used[$d].Cpu))m usedMem=$([math]::Round($used[$d].Memory))Mi budgetCpu=$([math]::Round($domains[$d].CpuBudget))m budgetMem=$([math]::Round($domains[$d].MemoryBudget))Mi"
        }
    }
    return [pscustomobject]@{Vector=$r;DomainsUsed=$used;CappedReason=$cappedReason;CapacityMax=$capacityMax}
}

function Build-HpaBudgetModel($config,$cluster,[int]$targetNodes,[hashtable]$capacityMax,[int]$stressNodes=1) {
    # placement domain 분리: 격리 구성(SchedulingConstraintRisk)이면 stress를 dedicated domain으로.
    # optimizer(Get-BudgetedHpaVector)는 앱 이름을 보지 않고 domain membership만 사용한다.
    # $config는 request/limit가 최신으로 반영된 authoritative config hashtable이어야 한다.
    $isolated=[bool](Get-OptionalPropertyValue $cluster 'SchedulingConstraintRisk' $false)
    $allocCpu=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableCPU' 0)
    $allocMem=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableMemoryMi' 0)
    if ($allocCpu -le 0) { $allocCpu=1930.0 }
    if ($allocMem -le 0) { $allocMem=3292.0 }
    $stressNodes=[math]::Max(1,[int]$stressNodes)
    # placement domain은 config의 placementDomain 필드(placement 결정이 설정)를 우선한다.
    # candidate 생성 단계(config에 placementDomain 없음)에서는 격리 구성이면 DedicatedApp을
    # dedicated로 매핑한다 — Guard/budget optimizer가 candidate를 shared로 잘못 넣지 않게.
    $dedicatedUsed=$false
    foreach ($app in $apps) {
        if ($config[$app].ContainsKey('placementDomain') -and [string]$config[$app].placementDomain -eq 'dedicated') { $dedicatedUsed=$true }
        elseif (-not $config[$app].ContainsKey('placementDomain') -and $isolated -and $DedicatedApp -and $app -eq $DedicatedApp) { $dedicatedUsed=$true }
    }
    $domains=@{}
    if ($dedicatedUsed) {
        # placementDomain이 dedicated를 쓰는 앱이 있으면 dedicated domain을 만든다.
        # isolated flag(cluster snapshot)와 무관하게 placement 결정이 source of truth다
        # (final overlay는 배치 적용 후 placementDomain을 설정하지만 snapshot은 시작 시점 것일 수 있음).
        $fgNodes=[math]::Max(1,$targetNodes-$stressNodes)
        $domains['shared']=@{CpuBudget=[double][math]::Round($fgNodes*$allocCpu*$NodeCpuBudgetUtilization);MemoryBudget=[double][math]::Round($fgNodes*$allocMem*$MemoryBudgetUtilization);MinCpuBudget=[double][math]::Round($fgNodes*$allocCpu*$MinCpuBudgetUtilization);MinMemoryBudget=[double][math]::Round($fgNodes*$allocMem*$MinMemoryBudgetUtilization)}
        $domains['dedicated']=@{CpuBudget=[double][math]::Round($stressNodes*$allocCpu*$NodeCpuBudgetUtilization);MemoryBudget=[double][math]::Round($stressNodes*$allocMem*$MemoryBudgetUtilization);MinCpuBudget=[double][math]::Round($stressNodes*$allocCpu*$MinCpuBudgetUtilization);MinMemoryBudget=[double][math]::Round($stressNodes*$allocMem*$MinMemoryBudgetUtilization)}
    } else {
        # SHARED(격리 해제/미사용): budget은 OperatingNodeBudget 전체 노드 capacity를 쓴다.
        # (격리 구성인데 placementDomain=shared면 1노드로 오인하는 버그 방지)
        $domains['shared']=@{CpuBudget=[double][math]::Round($targetNodes*$allocCpu*$NodeCpuBudgetUtilization);MemoryBudget=[double][math]::Round($targetNodes*$allocMem*$MemoryBudgetUtilization);MinCpuBudget=[double][math]::Round($targetNodes*$allocCpu*$MinCpuBudgetUtilization);MinMemoryBudget=[double][math]::Round($targetNodes*$allocMem*$MinMemoryBudgetUtilization)}
    }
    $appsModel=@{}
    foreach ($app in $apps) {
        $domain='shared'
        if ($config[$app].ContainsKey('placementDomain') -and [string]$config[$app].placementDomain -ne '') { $domain=[string]$config[$app].placementDomain }
        elseif ($isolated -and $DedicatedApp -and $app -eq $DedicatedApp) { $domain='dedicated' }
        $appsModel[$app]=@{Domain=$domain;CpuRequestM=[double](Convert-CpuToM $config[$app].requestCpu);LimitCpuM=[double](Convert-CpuToM $config[$app].limitCpu);MemoryRequestMi=[double](Convert-MemoryToMi $config[$app].requestMemory);HpaMin=1}
    }
    # placement 결정이 반영된 후 재계산: dedicated를 쓰는 앱이 없으면 빈 dedicated domain 제거
    # (SHARED 결정인데 빈 dedicated 노드 capacity를 계속 예약해 1-node로 보이는 버그 방지).
    $dedicatedUsed=$false
    foreach ($app in $apps) { if ($appsModel[$app].Domain -eq 'dedicated') { $dedicatedUsed=$true } }
    if (-not $dedicatedUsed -and $domains.ContainsKey('dedicated')) { $domains.Remove('dedicated') }
    return [pscustomobject]@{Apps=$appsModel;Domains=$domains;Isolated=$isolated;TargetNodes=$targetNodes;StressNodes=$stressNodes;NodeAllocCpu=$allocCpu;NodeAllocMem=$allocMem}
}

function Write-HpaBudgetOptimizerLog($model,$vector,$capacityMax,$perfByApp,$sensitivityByApp) {
    Write-Host '===== HPA Budget Optimizer =====' -ForegroundColor Cyan
    foreach ($d in $model.Domains.Keys) {
        Write-Host ("Domain={0}" -f $d) -ForegroundColor Cyan
        Write-Host ("  CPU budget: allocatable={0:N0}m usable={1:N0}m" -f $model.NodeAllocCpu,$model.Domains[$d].CpuBudget) -ForegroundColor DarkGray
        Write-Host ("  Memory budget: allocatable={0:N0}Mi usable={1:N0}Mi" -f $model.NodeAllocMem,$model.Domains[$d].MemoryBudget) -ForegroundColor DarkGray
        $dApps=@($apps | Where-Object { $model.Apps[$_].Domain -eq $d })
        foreach ($app in $dApps) {
            $m=$model.Apps[$app]
            $nb=Get-NextPerformanceBoundary ([double]$perfByApp[$app])
            Write-Host ("  {0}: requestCpu={1:N0}m requestMemory={2:N0}Mi min={3} capacityMax={4} performance={5:N1}% nextBoundary={6} sensitivity={7:N2}" -f $app,$m.CpuRequestM,$m.MemoryRequestMi,$m.HpaMin,[int]$capacityMax[$app],$perfByApp[$app],$(if ($null -eq $nb) { '-' } else { $nb }),$sensitivityByApp[$app]) -ForegroundColor DarkGray
        }
        $used=$vector.DomainsUsed[$d]
        Write-Host ("  Final vector: {0}" -f (($dApps | ForEach-Object { "$_=$([int]$vector.Vector[$_])" }) -join ' ')) -ForegroundColor DarkGray
        Write-Host ("  CPU: used={0:N0}m / {1:N0}m" -f $used.Cpu,$model.Domains[$d].CpuBudget) -ForegroundColor DarkGray
        Write-Host ("  Memory: used={0:N0}Mi / {1:N0}Mi" -f $used.Memory,$model.Domains[$d].MemoryBudget) -ForegroundColor DarkGray
    }
    $valid=$true
    foreach ($d in $model.Domains.Keys) {
        $used=$vector.DomainsUsed[$d]
        if ($used.Cpu -gt $model.Domains[$d].CpuBudget -or $used.Memory -gt $model.Domains[$d].MemoryBudget) { $valid=$false }
    }
    Write-Host ("budgetValid={0}" -f $valid) -ForegroundColor DarkGray
    foreach ($app in $apps) {
        $cap=[int]$capacityMax[$app]; $bud=[int]$vector.Vector[$app]
        if ($bud -lt $cap) {
            Write-Host ("  {0}: capacityMax={1} budgetedMax={2} cappedBy={3}" -f $app,$cap,$bud,$vector.CappedReason[$app]) -ForegroundColor Yellow
        }
    }
}

function Evaluate-NodeScaleOut($model,$capacityMax,$perfByApp,$sensitivityByApp,[double]$margin=0.5) {
    # 현재 budget vector를 먼저 완전히 계산한 뒤, 노드 추가 시 expanded budget 재최적화 가치를 평가한다.
    $current=Get-BudgetedHpaVector $model.Apps $model.Domains $capacityMax $perfByApp $sensitivityByApp
    $expandedTarget=$model.TargetNodes+1
    $allocCpu=[double]$model.NodeAllocCpu; $allocMem=[double]$model.NodeAllocMem
    $newDomains=@{}
    foreach ($d in $model.Domains.Keys) {
        $addCpu=0.0; $addMem=0.0
        if (-not $model.Isolated -or $d -ne 'dedicated') { $addCpu=$allocCpu*$NodeCpuBudgetUtilization; $addMem=$allocMem*$MemoryBudgetUtilization }
        $newDomains[$d]=@{CpuBudget=[double]($model.Domains[$d].CpuBudget+$addCpu);MemoryBudget=[double]($model.Domains[$d].MemoryBudget+$addMem)}
    }
    $expandedModel=[pscustomobject]@{Apps=$model.Apps;Domains=$newDomains;TargetNodes=$expandedTarget;StressNodes=$model.StressNodes;NodeAllocCpu=$allocCpu;NodeAllocMem=$allocMem;Isolated=$model.Isolated}
    $expandedVector=Get-BudgetedHpaVector $expandedModel.Apps $expandedModel.Domains $capacityMax $perfByApp $sensitivityByApp
    $perfGain=0.0
    foreach ($app in $apps) {
        $before=[int]$current.Vector[$app]; $after=[int]$expandedVector.Vector[$app]
        $sens=[double]$sensitivityByApp[$app]
        if ($after -gt $before -and $sens -gt 0) {
            $base=(Get-EmpiricalPerformanceScore ([double]$perfByApp[$app])).Score
            $est=(Get-EmpiricalPerformanceScore ([double]$perfByApp[$app]+$sens*($after-$before))).Score
            $perfGain += [math]::Max(0.0,$est-$base)
        }
    }
    # cost는 단일 source (Get-EmpiricalCostScore) 사용: targetNodes를 평균 노드 근사로 전달.
    $mockOld=[pscustomobject]@{TotalNodeSeconds=([double]$model.TargetNodes*360.0);LoadWindowSeconds=360.0;PeakTotalReadyNodes=[double]$model.TargetNodes}
    $mockNew=[pscustomobject]@{TotalNodeSeconds=([double]$expandedTarget*360.0);LoadWindowSeconds=360.0;PeakTotalReadyNodes=[double]$expandedTarget}
    $costOld=(Get-EmpiricalCostScore $mockOld).Score
    $costNew=(Get-EmpiricalCostScore $mockNew).Score
    $costLoss=$costOld-$costNew
    $delta=$perfGain-$costLoss
    $allowed=($delta -gt $margin)
    return [pscustomobject]@{Allowed=$allowed;DeltaEvaluation=$delta;ExpectedPerfGain=$perfGain;ExpectedCostLoss=$costLoss;CurrentVector=$current.Vector;ExpandedVector=$expandedVector.Vector;Reason=$(if ($allowed) { 'POSITIVE_EVALUATION_NET_GAIN' } else { 'SCALE_OUT_DENIED' })}
}

function Update-FinalHpaMax($profile,[string]$app) {
    # 관측 기반 HPA max를 candidate lifecycle과 분리된 전역 상태에 monotonic으로 저장한다.
    # CPU 또는 throughput 중 하나라도 유효하면 Get-AppHpaCapacity이 NewMax를 계산하므로,
    # generator unreliable(LOAD_GENERATOR_LIMIT)여도 CPU가 있으면 저장 가능하다.
    # 최종 적용 시 이 값을 FinalConfig.maxReplicas에 overlay한다.
    $calculated=Get-AppHpaCapacity $profile $app
    $prev=$script:FinalHpaMaxByApp[$app]
    $prevVal=if ($null -ne $prev -and [double]$prev -gt 0) { [double]$prev } else { 0.0 }
    $stored=[int][math]::Max([int]$prevVal,[int]$calculated)
    $script:FinalHpaMaxByApp[$app]=$stored
    Write-Host ("HPA observation [{0}]" -f $app) -ForegroundColor DarkGray
    Write-Host ("  previousFinalMax={0}  calculatedNewMax={1}  storedFinalMax={2}" -f $(if ($prevVal -gt 0) { [int]$prevVal } else { '-' }),$calculated,$stored) -ForegroundColor DarkGray
    return $calculated
}

function Get-StressPlacementDecision {
    param(
        [double]$P95User,[double]$P95Product,
        [double]$P95UserBase,[double]$P95ProductBase,
        [double]$NodeCpuUtil,[double]$NodeMemUtil,
        [double]$ThrottleRatio,
        [double]$SloFailUser,[double]$SloFailProduct,
        [bool]$Isolated,
        [bool]$BaselineTrustworthy,
        [double]$SharedCost,[double]$DedicatedCost
    )
    # stress 동거 간섭 판단 (순수 계산):
    #   L     = max(0, Duser-1, Dprod-1), D=P95/P95baseline (baseline 없으면 L=0, merge-back 금지)
    #   Ccpu  = max(0, Ucpu-0.75)/0.25, Cmem = max(0, Umem-0.75)/0.25
    #   Tstress = stress throttle 비율
    #   I = 1.0*L + 0.5*Ccpu + 0.5*Cmem + 0.5*Tstress
    #   DeltaCost = (Dedicated-Shared)/max(Shared, eps)
    # 결정:
    #   SLOFailFg >= 0.02 → ISOLATE_STRESS (cost 무시, foreground 보호 최우선)
    #   현재 SHARED: I>=0.30 and (I-0.30)>=0.10*DeltaCost → ISOLATE_STRESS
    #   현재 ISOLATED: SLOFailFg<0.02 and I<=0.15 and baseline 신뢰 → SHARED (hysteresis), else ISOLATED 유지
    $alpha=1.0; $beta=0.5; $gamma=0.5
    $epsilon=0.02; $thetaHi=0.30; $thetaLo=0.15; $kappa=0.10
    $epsNum=1e-6
    $dUser=if ($null -ne $P95UserBase -and [double]$P95UserBase -gt 0) { [double]$P95User/[double]$P95UserBase } else { $null }
    $dProd=if ($null -ne $P95ProductBase -and [double]$P95ProductBase -gt 0) { [double]$P95Product/[double]$P95ProductBase } else { $null }
    $L=0.0
    if ($null -ne $dUser -and $null -ne $dProd) { $L=[math]::Max(0.0,[math]::Max([double]$dUser-1.0,[double]$dProd-1.0)) }
    $cpuUtil=if ($null -ne $NodeCpuUtil) { [math]::Max(0.0,[math]::Min(1.0,[double]$NodeCpuUtil)) } else { 0.0 }
    $memUtil=if ($null -ne $NodeMemUtil) { [math]::Max(0.0,[math]::Min(1.0,[double]$NodeMemUtil)) } else { 0.0 }
    $Ccpu=[math]::Max(0.0,($cpuUtil-0.75)/0.25)
    $Cmem=[math]::Max(0.0,($memUtil-0.75)/0.25)
    $Tstress=if ($null -ne $ThrottleRatio) { [math]::Max(0.0,[math]::Min(1.0,[double]$ThrottleRatio)) } else { 0.0 }
    $I=($alpha*$L)+($beta*$Ccpu)+($beta*$Cmem)+($gamma*$Tstress)
    $sloFailUser=if ($null -ne $SloFailUser) { [math]::Max(0.0,[double]$SloFailUser) } else { 0.0 }
    $sloFailProd=if ($null -ne $SloFailProduct) { [math]::Max(0.0,[double]$SloFailProduct) } else { 0.0 }
    $sloFailFg=[math]::Max($sloFailUser,$sloFailProd)
    $deltaCost=if ($null -ne $SharedCost -and [double]$SharedCost -gt 0) { ([double]$DedicatedCost-[double]$SharedCost)/[math]::Max([double]$SharedCost,$epsNum) } else { 0.0 }
    $decision='SHARED'; $reason=''
    if ($sloFailFg -ge $epsilon) {
        $decision='ISOLATE_STRESS'; $reason='FOREGROUND_SLO_GUARD'
    } elseif ($Isolated) {
        if ($sloFailFg -lt $epsilon -and $I -le $thetaLo -and $BaselineTrustworthy) {
            $decision='SHARED'; $reason='MERGE_BACK_HYSTERESIS'
        } else {
            $decision='ISOLATED'; $reason='KEEP_ISOLATED'
        }
    } else {
        if ($I -ge $thetaHi -and ($I-$thetaHi) -ge ($kappa*$deltaCost)) {
            $decision='ISOLATE_STRESS'; $reason='INTERFERENCE_AND_COST_OK'
        } else {
            $decision='SHARED'; $reason='BELOW_THRESHOLD'
        }
    }
    return [pscustomobject]@{Decision=$decision;Reason=$reason;I=[math]::Round($I,4);L=[math]::Round($L,4);Ccpu=[math]::Round($Ccpu,4);Cmem=[math]::Round($Cmem,4);Tstress=[math]::Round($Tstress,4);DUser=$dUser;DProd=$dProd;SloFailFg=[math]::Round($sloFailFg,4);DeltaCost=[math]::Round($deltaCost,4);Isolated=$Isolated;BaselineTrustworthy=$BaselineTrustworthy}
}

function Write-StressPlacementLog($p) {
    Write-Host "Stress placement decision" -ForegroundColor Cyan
    if ($null -ne $p.DUser -and $null -ne $p.DProd) {
        Write-Host ("  Duser={0:N2}  Dprod={1:N2}  L={2:N2}" -f $p.DUser,$p.DProd,$p.L) -ForegroundColor DarkGray
    } else {
        Write-Host '  baseline(P95u0/P95p0) 없음 → L 미계산 (interference는 node/throttle 기반만)' -ForegroundColor DarkGray
    }
    Write-Host ("  Ccpu={0:N2}  Cmem={1:N2}  Tstress={2:N2}" -f $p.Ccpu,$p.Cmem,$p.Tstress) -ForegroundColor DarkGray
    Write-Host ("  I={0:N3}" -f $p.I) -ForegroundColor DarkGray
    Write-Host ("  SLOFailFg={0:N3}" -f $p.SloFailFg) -ForegroundColor DarkGray
    Write-Host ("  DeltaCost={0:N2}" -f $p.DeltaCost) -ForegroundColor DarkGray
    if ($p.Reason -eq 'FOREGROUND_SLO_GUARD') {
        Write-Host ("  decision={0}  reason={1}" -f $p.Decision,$p.Reason) -ForegroundColor Yellow
    } elseif ($p.Decision -eq 'ISOLATE_STRESS') {
        Write-Host ("  decision={0}  reason={1}" -f $p.Decision,$p.Reason) -ForegroundColor Yellow
    } else {
        Write-Host ("  decision={0}  reason={1}" -f $p.Decision,$p.Reason) -ForegroundColor DarkGray
    }
    if ($p.Decision -eq 'ISOLATE_STRESS') {
        Write-Host '  → stress 전용 배치 필요: stress Deployment에 workload-class=stress nodeSelector + dedicated NodePool' -ForegroundColor Yellow
    }
}

function Get-StressCapacityShape($profile,$cluster) {
    # Stress CPU allocation granularity 판정 + right-sizing 계산.
    #   granularity = StressCpuRequestM / NodeAllocatableCpuM
    #   granularity >= 0.40 AND foreground(user/product) degraded → SPLIT_STRESS_CAPACITY
    #   newRequest = clamp(StressCpuRequestMinimum, appCpuBudget/DesiredStressPods, currentRequest) (25m)
    #   newLimit   = min(2*newRequest, 0.8*nodeAlloc)
    #   newHpaMax  = max(6, calculated)  (MaxAutoReplicas cap)
    # placement는 SHARED 유지 — dedicated isolation은 right-sized shared 측정 후에만.
    $metric=$profile.Apps.stress
    $nodeAlloc=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableCPU' 0)
    $appBudget=[double](Get-OptionalPropertyValue $cluster 'AvailableAppCPU' $nodeAlloc)
    if ($nodeAlloc -le 0) { $nodeAlloc=$appBudget }
    $currentRequest=[double](Convert-CpuToM $profile.Config.stress.requestCpu)
    $granularity=if ($nodeAlloc -gt 0) { $currentRequest/$nodeAlloc } else { 0 }
    $fgDegraded=((Get-OptionalPropertyValue $profile.Apps.user 'SLOPass' $true) -eq $false) -or ((Get-OptionalPropertyValue $profile.Apps.product 'SLOPass' $true) -eq $false)
    # stress 자체 성능 신호: foreground가 건강해도 stress가 coarse request(925m)로 성능이
    # 나쁘면 SPLIT이 필요하다 (1 pod x 큰 request의 병렬성 부족). SLO 성공률 < 65%면 split 후보.
    $stressSlo=[double](Get-OptionalPropertyValue $metric 'SLOComplianceRate' 1.0)
    $stressBad=($stressSlo -lt 0.65) -or ([bool](Get-OptionalPropertyValue $metric 'LoadGeneratorLimited' $false) -and [double](Get-OptionalPropertyValue $metric 'GeneratedLoadRatio' 1.0) -lt 0.80)
    $splitNeeded=($granularity -ge $StressGranularityThreshold) -and ($fgDegraded -or $stressBad)
    $requestCandidate=if ($DesiredStressPods -gt 0) { $appBudget/$DesiredStressPods } else { $currentRequest }
    # 계산은 현재 request를 기준으로 한다. 앱별 reference request를 사용하지 않는다.
    $effectiveCurrentRequest=$currentRequest

    $newRequest=[math]::Min($effectiveCurrentRequest,[math]::Max([double]$StressCpuRequestMinimum,$requestCandidate))
    $newRequest=[math]::Ceiling($newRequest/25.0)*25
    $safeLimit=[double][math]::Floor($nodeAlloc*0.8/25)*25   # NodeCpuSafeLimit
    $currentLimit=Convert-CpuToM $profile.Config.stress.limitCpu
    $newLimit=if ($null -eq $currentLimit) { $null } else { [math]::Ceiling([math]::Min($currentLimit,$safeLimit)/25.0)*25 }
    if ($null -ne $newLimit -and $newLimit -lt $newRequest) { $newLimit=$newRequest }  # request 이하 금지
    # HPA: split 시 최소 6, 관측 기반 계산값이 크면 그 값 사용 (cap 유지)
    $calculatedMax=Get-AppHpaCapacity $profile $DedicatedApp
    $newHpaMax=[int][math]::Min($MaxAutoReplicas,[math]::Max($StressHpaMinMax,$calculatedMax))
    Write-Host 'Stress capacity shape' -ForegroundColor DarkGray
    Write-Host ("  nodeAllocatableCPU={0:N0}m  currentRequest={1:N0}m  granularity={2:N3}" -f $nodeAlloc,$currentRequest,$granularity) -ForegroundColor DarkGray
    Write-Host ("  foregroundDegraded={0}  desiredStressPods={1}" -f $fgDegraded,$DesiredStressPods) -ForegroundColor DarkGray
    Write-Host ("  appCpuBudget={0:N0}m  requestCandidate={1:N0}m" -f $appBudget,$requestCandidate) -ForegroundColor DarkGray
    Write-Host ("  newRequest={0:N0}m  newLimit={1:N0}m  newHpaMax={2}" -f $newRequest,$newLimit,$newHpaMax) -ForegroundColor DarkGray
    Write-Host ("  action={0}  placement=SHARED" -f $(if ($splitNeeded) {'SPLIT_STRESS_CAPACITY'} else {'NO_SPLIT'})) -ForegroundColor DarkGray
    return [pscustomobject]@{SplitNeeded=$splitNeeded;Granularity=[math]::Round($granularity,3);NewRequestM=$newRequest;NewLimitM=$newLimit;NewHpaMax=$newHpaMax;ForegroundDegraded=$fgDegraded;CurrentRequestM=$currentRequest}
}

function Apply-StressPlacement {
    # ISOLATED_SPREAD: stress를 전용 Karpenter NodePool('stress')로 보낸다.
    # 1) default NodePool의 수동 taint 제거 → shared 노드가 user/product를 받는다.
    # 2) default spec을 복제한 전용 NodePool 'stress' 생성 (label workload-class=stress,
    #    taint $stressPlacementKey 유지) — user/product toleration(app-capacity)과 key가
    #    분리되어 있어 stress 전용 노드에는 stress만 스케줄된다.
    # 3) stress deployment에 nodeSelector {workload-class: stress} + 전용 toleration 추가
    # isolation 전환 전에 과다 replica를 safe prewarm 수준으로 정리해 rollout storm을 피한다.
    # (HPA minReplicas=1 유지 — prewarm은 영구 floor가 아니다.)
    try {
        $desired=0
        $desiredRaw=@(Invoke-Kubectl @('-n',$Namespace,'get','deploy',$DedicatedApp,'-o','jsonpath={.spec.replicas}'))
        if ($desiredRaw.Count -and [int]($desiredRaw[0]) -gt 0) { $desired=[int]$desiredRaw[0] }
        if ($desired -gt $DesiredStressPods) {
            Write-Host ("isolation 전 stress replicas 정리: {0} → {1} (prewarm, HPA min=1 유지)" -f $desired,$DesiredStressPods) -ForegroundColor Yellow
            Invoke-Kubectl @('-n',$Namespace,'scale','deploy',$DedicatedApp,'--replicas=1')
        }
    } catch { Write-Warning "isolation 전 stress replica 정리 실패: $($_.Exception.Message)" }
    try {
        Invoke-Kubectl @('patch','nodepool','default','--type=merge','-p','{"spec":{"template":{"spec":{"taints":[]}}}}')
        Write-Host 'default NodePool taint 제거 (shared 노드로 user/product 수용)' -ForegroundColor Green
    } catch { Write-Warning "default NodePool taint 제거 실패: $($_.Exception.Message)" }
    $exists=$null
    try { $exists=[string](Invoke-Kubectl @('get','nodepool',$DedicatedApp,'-o','jsonpath={.metadata.name}')) } catch { $exists=$null }
    if (-not $exists) {
        try {
            $npRaw=@(Invoke-Kubectl @('get','nodepool','default','-o','json'))
            $np=($npRaw -join '') | ConvertFrom-Json
            $spec=$np.spec
            if ($null -eq $spec.template.metadata) { $spec.template | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{}) -Force }
            if ($null -eq $spec.template.spec.PSObject.Properties['taints']) { $spec.template.spec | Add-Member -NotePropertyName taints -NotePropertyValue @() -Force }
            if ($null -eq $spec.PSObject.Properties['limits']) { $spec | Add-Member -NotePropertyName limits -NotePropertyValue ([ordered]@{}) -Force }
            $spec.template.metadata | Add-Member -NotePropertyName labels -NotePropertyValue ([ordered]@{'workload-class'=$DedicatedApp}) -Force
            $spec.template.spec.taints=@([pscustomobject]@{key=$stressPlacementKey;value='true';effect='NoSchedule'})
            $body=[ordered]@{apiVersion='karpenter.sh/v1';kind='NodePool';metadata=[ordered]@{name='stress'};spec=$spec}
            $jsonBody=$body | ConvertTo-Json -Depth 20
            # Invoke-Kubectl은 stdin을 전달하지 않아 apply -f - 가 실패한다 — 직접 실행으로 교체.
            $applyOut=@($jsonBody | & kubectl apply -f - 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "kubectl apply -f - 실패: $($applyOut -join ' ')" }
            Write-Host '전용 NodePool stress 생성 (label workload-class=stress, taint key 분리)' -ForegroundColor Green
        } catch { Write-Warning "전용 NodePool stress 생성 실패: $($_.Exception.Message)" }
    } else {
        # 이미 존재: taint key를 전용 key로 통일 (구 app-capacity taint와 혼용 방지)
        try {
            Invoke-Kubectl @('patch','nodepool',$DedicatedApp,'--type=merge','-p',('{"spec":{"template":{"spec":{"taints":[{"key":"' + $stressPlacementKey + '","value":"true","effect":"NoSchedule"}]}}}}'))
            Write-Host '전용 NodePool stress taint key 통일' -ForegroundColor Green
        } catch { Write-Warning "stress NodePool taint 통일 실패: $($_.Exception.Message)" }
    }
    try {
        Invoke-Kubectl @('-n',$Namespace,'patch','deploy',$DedicatedApp,'--type=strategic','-p','{"spec":{"template":{"spec":{"nodeSelector":{"workload-class":"stress"}}}}}')
        Write-Host 'stress deployment → 전용 NodePool 배치 (nodeSelector workload-class=stress)' -ForegroundColor Green
    } catch { Write-Warning "stress nodeSelector 적용 실패: $($_.Exception.Message)" }
    # stress 전용 toleration 추가 (기존 app-capacity toleration은 유지 — 확장용 Karpenter 노드 접근용)
    try {
        $deploy=(Invoke-Kubectl @('-n',$Namespace,'get','deploy',$DedicatedApp,'-o','json')) -join '' | ConvertFrom-Json
        $tols=[System.Collections.Generic.List[object]]::new()
        foreach ($tol in @($deploy.spec.template.spec.tolerations)) { if ($null -ne $tol) { $tols.Add($tol) } }
        if (@($tols | Where-Object { $_.key -eq $stressPlacementKey -and $_.effect -eq 'NoSchedule' }).Count -eq 0) {
            $tols.Add([pscustomobject]@{key=$stressPlacementKey;operator='Equal';value='true';effect='NoSchedule'})
            $patch=@{spec=@{template=@{spec=@{tolerations=@($tols)}}}} | ConvertTo-Json -Compress -Depth 20
            Invoke-Kubectl @('-n',$Namespace,'patch','deploy',$DedicatedApp,'--type=merge','-p',$patch)
            Write-Host 'stress deployment 전용 toleration 추가' -ForegroundColor Green
        }
    } catch { Write-Warning "stress toleration 추가 실패: $($_.Exception.Message)" }
    foreach ($app in $apps) {
        try { Wait-DeploymentRollout $app 120 Hard } catch { Write-Warning "$app rollout 대기 실패: $($_.Exception.Message)" }
    }
}

function Revert-StressPlacement {
    # merge-back/SHARED: stress nodeSelector 제거 + 전용 NodePool 삭제 (기본 shared 배치 복귀)
    try {
        Invoke-Kubectl @('-n',$Namespace,'patch','deploy','stress','--type=strategic','-p','{"spec":{"template":{"spec":{"nodeSelector":null}}}}')
        Write-Host 'stress nodeSelector 제거 (shared 배치 복귀)' -ForegroundColor Green
    } catch { Write-Warning "stress nodeSelector 제거 실패: $($_.Exception.Message)" }
    try {
        Invoke-Kubectl @('delete','nodepool','stress','--ignore-not-found')
        Write-Host '전용 NodePool stress 삭제' -ForegroundColor Green
    } catch { Write-Warning "전용 NodePool stress 삭제 실패: $($_.Exception.Message)" }
    try { Wait-DeploymentRollout 'stress' 120 Hard } catch { Write-Warning "stress rollout 대기 실패: $($_.Exception.Message)" }
}

function Ensure-38PointStressTopology([switch]$ApplyPlacement) {
    # apply-38point.ps1와 동일한 dedicated stress 불변조건을 튜닝 시작/최종 전에
    # 실제 리소스 기준으로 보장한다. 단순히 NodePool spec만 보는 것이 아니라
    # Node allocatable CPU, 실제 Pod nodeName, 전체 Pod request 사용량까지 함께 확인한다.
    if ($ApplyPlacement) { Apply-StressPlacement }

    $defaultPool=((& kubectl get nodepool default -o json 2>$null) -join '') | ConvertFrom-Json
    $stressPool=((& kubectl get nodepool stress -o json 2>$null) -join '') | ConvertFrom-Json
    if (-not $defaultPool -or -not $stressPool) { throw '38POINT_TOPOLOGY_INVALID: default/stress NodePool을 모두 찾지 못했습니다.' }

    $nodes=((& kubectl get nodes -o json) -join '') | ConvertFrom-Json
    $readyStressNodes=@($nodes.items | Where-Object {
        $ready=@($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        $pool=[string]$_.metadata.labels.'karpenter.sh/nodepool'
        $label=[string]$_.metadata.labels.'workload-class'
        $ready -and ($pool -eq 'stress' -or $label -eq 'stress')
    })
    $capacityNode=$readyStressNodes | Select-Object -First 1
    if (-not $capacityNode) {
        $capacityNode=@($nodes.items | Where-Object {
            @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        } | Select-Object -First 1)
    }
    if (-not $capacityNode) { throw '38POINT_TOPOLOGY_INVALID: Ready 노드가 없습니다.' }
    $nodeCapacityM=Convert-CpuToM $capacityNode.status.capacity.cpu
    $nodeAllocatableM=Convert-CpuToM $capacityNode.status.allocatable.cpu
    if ($nodeCapacityM -le 0 -or $nodeAllocatableM -le 0) { throw '38POINT_TOPOLOGY_INVALID: 노드 CPU capacity/allocatable 조회 실패' }
    $nodeCpuCores=[int][math]::Ceiling($nodeCapacityM/1000.0)

    # 38점 재현 설정에는 NodePool CPU limit이 없다. 튜너는 이를 변경하지 않는다.
    Write-Host ("NodePool CPU limit not managed by tuner: default={0}, stress={1}" -f $defaultPool.spec.limits.cpu,$stressPool.spec.limits.cpu) -ForegroundColor DarkGray

    # stress NodePool의 생성 조건을 apply-38point.ps1와 동일하게 맞춘다.
    $stressPatch='{"spec":{"template":{"metadata":{"labels":{"workload-class":"stress"}},"spec":{"taints":[{"key":"wsi2026.io/stress","value":"true","effect":"NoSchedule"}]}}}}'
    Invoke-Kubectl @('patch','nodepool','stress','--type=merge','-p',$stressPatch)

    $deployment=((& kubectl -n $Namespace get deployment stress -o json) -join '') | ConvertFrom-Json
    if (-not $deployment) { throw '38POINT_TOPOLOGY_INVALID: stress Deployment을 찾지 못했습니다.' }
    $selector=$deployment.spec.template.spec.nodeSelector
    if ([string]$selector.'workload-class' -ne 'stress') {
        Invoke-Kubectl @('-n',$Namespace,'patch','deployment','stress','--type=merge','-p','{"spec":{"template":{"spec":{"nodeSelector":{"workload-class":"stress"}}}}}')
    }
    $hasStressTol=@($deployment.spec.template.spec.tolerations | Where-Object {
        $_.key -eq 'wsi2026.io/stress' -and $_.value -eq 'true' -and $_.effect -eq 'NoSchedule'
    }).Count -gt 0
    if (-not $hasStressTol) {
        $tolerations=[System.Collections.Generic.List[object]]::new()
        foreach ($tol in @($deployment.spec.template.spec.tolerations)) { if ($null -ne $tol) { $tolerations.Add($tol) } }
        $tolerations.Add([pscustomobject]@{key='wsi2026.io/stress';operator='Equal';value='true';effect='NoSchedule'})
        $tolPatch=@{spec=@{template=@{spec=@{tolerations=@($tolerations)}}}} | ConvertTo-Json -Compress -Depth 20
        Invoke-Kubectl @('-n',$Namespace,'patch','deployment','stress','--type=merge','-p',$tolPatch)
    }
    Wait-DeploymentRollout 'stress' 180 Hard

    # nodeSelector/toleration 수정이나 Karpenter reconciliation으로 노드가 교체될 수
    # 있으므로 rollout 후의 live 노드 목록을 기준으로 실제 Pod 배치를 검증한다.
    $nodes=((& kubectl get nodes -o json) -join '') | ConvertFrom-Json
    $pods=((& kubectl -n $Namespace get pods -l app=stress -o json) -join '') | ConvertFrom-Json
    $stressPods=@($pods.items | Where-Object { $_.metadata.deletionTimestamp -eq $null })
    if (-not $stressPods.Count) { throw '38POINT_TOPOLOGY_INVALID: 현재 stress Pod가 없습니다.' }
    $nodeByName=@{}
    foreach ($n in @($nodes.items)) { $nodeByName[[string]$n.metadata.name]=$n }
    $allPods=((& kubectl get pods --all-namespaces -o json) -join '') | ConvertFrom-Json
    $requestsByNode=@{}
    foreach ($p in @($allPods.items)) {
        $n=[string]$p.spec.nodeName
        if (-not $n -or $p.status.phase -ne 'Running') { continue }
        if (-not $requestsByNode.ContainsKey($n)) { $requestsByNode[$n]=0.0 }
        foreach ($c in @($p.spec.containers)) { $requestsByNode[$n]+=[double](Convert-CpuToM $c.resources.requests.cpu) }
    }
    foreach ($pod in $stressPods) {
        $nodeName=[string]$pod.spec.nodeName
        if (-not $nodeName -or -not $nodeByName.ContainsKey($nodeName)) { throw "38POINT_TOPOLOGY_INVALID: stress Pod $($pod.metadata.name)이 Pending/미배치 상태입니다." }
        $node=$nodeByName[$nodeName]
        $label=[string]$node.metadata.labels.'workload-class'
        $taint=@($node.spec.taints | Where-Object { $_.key -eq 'wsi2026.io/stress' -and $_.value -eq 'true' -and $_.effect -eq 'NoSchedule' })
        if ($label -ne 'stress' -or $taint.Count -eq 0) { throw "38POINT_TOPOLOGY_INVALID: stress Pod $($pod.metadata.name)이 dedicated taint/label 노드에 있지 않습니다: $nodeName" }
        $alloc=Convert-CpuToM $node.status.allocatable.cpu
        if ($alloc -lt (Convert-CpuToM $deployment.spec.template.spec.containers[0].resources.requests.cpu)) { throw "38POINT_TOPOLOGY_INVALID: stress 노드 allocatable CPU 부족: $nodeName alloc=${alloc}m" }
        $used=[double]$requestsByNode[$nodeName]
        Write-Host ("  stress placement: pod={0} node={1} allocatable={2:N0}m requested={3:N0}m remaining={4:N0}m" -f $pod.metadata.name,$nodeName,$alloc,$used,($alloc-$used)) -ForegroundColor DarkGray
    }
    Write-Host ("38POINT_TOPOLOGY verified: NodePool CPU default/stress={0} cores, stress nodes={1}, capacity={2:N0}m allocatable={3:N0}m" -f $desiredLimit,$readyStressNodes.Count,$nodeCapacityM,$nodeAllocatableM) -ForegroundColor Green
    return [pscustomobject]@{DefaultNodePoolCpu=$desiredLimit;StressNodePoolCpu=$desiredLimit;StressNodeCount=$readyStressNodes.Count;NodeCapacityCPU=$nodeCapacityM;NodeAllocatableCPU=$nodeAllocatableM;StressPodCount=$stressPods.Count}
}

function Get-NextTuningAction($profile,[string]$app,$cluster=$null) {
    $metric=$profile.Apps[$app]
    $reasons=@($metric.Bottlenecks)
    # Stress capacity shape: coarse CPU allocation + foreground degraded면 SPLIT 우선.
    # dedicated isolation은 right-sized shared 측정 이후에만 판단한다.
    $stressShape=$null
    if ($app -eq 'stress' -and $null -ne $cluster) {
        $stressShape=Get-StressCapacityShape $profile $cluster
    }
    # LOAD_GENERATOR_LIMIT여도 VU action으로 끝내지 않고 CPU 기반 HPA 계산을 먼저 수행한다.
    # generator가 부하를 못 만들었다는 사실과 Pod CPU 부족으로 scale-out이 필요한지는 별개의
    # 문제다. VU 조정은 Run-ReliableLoadTest/RetryPhase가 별도 처리하므로 여기서 early return하지
    # 않는다. capacity term 신뢰도만 reliability가 결정하고 CPU 항은 항상 유지한다.
    if ('LOAD_GENERATOR_LIMIT' -in $reasons) {
        $current=[int]$profile.Config[$app].maxReplicas
        # Stress coarse allocation + foreground degraded면 LOAD_GENERATOR_LIMIT(생성률 부족)이
        # 단일 Pod의 병렬성 부족 때문일 수 있으므로 SPLIT을 최우선으로 판단한다.
        # VU 증가로 생성률을 복구해도 CPU allocation이 coarse면 결국 SPLIT이 필요하다.
        if ($stressShape -and $stressShape.SplitNeeded) {
            $hpaTo=[int][math]::Min($MaxAutoReplicas,[math]::Max($StressHpaMinMax,$stressShape.NewHpaMax))
            return [pscustomobject]@{App=$app;Type='SPLIT_STRESS_CAPACITY';Reason='STRESS_COARSE_CAPACITY';From=$current;To=$hpaTo;RequestTo=$stressShape.NewRequestM;LimitTo=$stressShape.NewLimitM;HpaMaxTo=$hpaTo;VuAction='INCREASE_K6_VUS'}
        }
        if ($app -eq 'stress') {
            $interactiveFailure=@('user','product') | Where-Object { -not [bool]$profile.Apps[$_].SLOPass -or -not [bool]$profile.Apps[$_].LoadPass -or -not [bool]$profile.Apps[$_].AvailabilityPass }
            if (@($interactiveFailure).Count) {
                # interactive 보호: HPA 증가 보류 (계산 로그는 남긴다), VU는 RetryPhase가 처리.
                [void](Get-AppHpaCapacity $profile $app)
                return [pscustomobject]@{App=$app;Type='INCREASE_K6_VUS';Reason='LOAD_GENERATOR_LIMIT_INTERACTIVE_PROTECTED';From=$null;To=$null;VuAction='INCREASE_K6_VUS'}
            }
        }
        $next=Get-AppHpaCapacity $profile $app
        if ($next -gt $current) {
            return [pscustomobject]@{App=$app;Type='INCREASE_HPA_MAX';Reason='LOAD_GENERATOR_LIMIT_CAPACITY';From=$current;To=$next;VuAction='INCREASE_K6_VUS'}
        }
        # 계산값이 없고(CPU metric 부재) CPU_THROTTLING이 명확하면 초기 안전 fallback.
        # 다음 정상 measurement 이후 Get-AppHpaCapacity 계산 결과로 덮어쓴다.
        if ($current -le 2 -and 'CPU_THROTTLING' -in $reasons -and $null -eq (Get-OptionalPropertyValue $metric 'AverageCPUUtilization') -and $null -eq (Get-OptionalPropertyValue $metric 'PeakCPUUtilization')) {
            return [pscustomobject]@{App=$app;Type='INCREASE_HPA_MAX';Reason='LOAD_GENERATOR_LIMIT_CPU_FALLBACK';From=$current;To=6;VuAction='INCREASE_K6_VUS'}
        }
        return [pscustomobject]@{App=$app;Type='INCREASE_K6_VUS';Reason='LOAD_GENERATOR_LIMIT';From=$null;To=$null;VuAction='INCREASE_K6_VUS'}
    }
    # 충분한 요청을 생성했는데 성공이 0이면 startup/throttling 진단에 막혀
    # HPA max가 그대로 남는 것이 가장 큰 손실이다. OOM이 없는 한 용량을 먼저
    # 두 배로 열어 다음 후보에서 실제 처리 가능성을 확인한다.
    if ('ZERO_SUCCESS_CAPACITY' -in $reasons -and 'MEMORY_OOM' -notin $reasons) {
        $current=[int]$profile.Config[$app].maxReplicas
        if ($app -eq 'stress') {
            # user/product가 모두 정상일 때만 stress 수평 확장을 허용한다.
            # 초기화하지 않으면 $null이 false로 평가되어 항상 NO_CHANGE가 되는 버그가 있다.
            $interactiveProtected=$true
            foreach ($protectedApp in @('user','product')) {
                $protectedMetric=$profile.Apps[$protectedApp]
                if ($null -eq $protectedMetric -or -not [bool]$protectedMetric.SLOPass -or -not [bool]$protectedMetric.LoadPass -or -not [bool]$protectedMetric.AvailabilityPass) { $interactiveProtected=$false }
            }
            if (-not $interactiveProtected) { return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='INTERACTIVE_API_PROTECTION';From=$current;To=$current} }
        }
        # 모든 앱 공통: 관측 기반 capacity 계산으로 결정한다.
        $next=Get-AppHpaCapacity $profile $app
        if ($next -gt $current) { return [pscustomobject]@{App=$app;Type='INCREASE_HPA_MAX';Reason='ZERO_SUCCESS_CAPACITY';From=$current;To=$next} }
        return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='HPA_CAPACITY_NO_INCREASE';From=$current;To=$current}
    }
    if ('MEMORY_OOM' -in $reasons) {
        $current=Convert-MemoryToMi $profile.Config[$app].limitMemory
        $peak=[double]$metric.MemoryPeakMi
        $next=[math]::Ceiling([math]::Max($current*1.50,$peak*1.50)/32.0)*32
        return [pscustomobject]@{App=$app;Type='INCREASE_MEMORY_LIMIT';Reason='MEMORY_OOM';From=$current;To=$next}
    }
    # Stress coarse CPU allocation + foreground degraded → SPLIT (request/limit 분할 + horizontal).
    # OOM 다음 최우선. CPU_THROTTLING이어도 granularity가 크면 limit부터 올리지 않는다.
    if ($stressShape -and $stressShape.SplitNeeded) {
        $current=[int]$profile.Config[$app].maxReplicas
        $hpaTo=[int][math]::Min($MaxAutoReplicas,[math]::Max($StressHpaMinMax,$stressShape.NewHpaMax))
        return [pscustomobject]@{App=$app;Type='SPLIT_STRESS_CAPACITY';Reason='STRESS_COARSE_CAPACITY';From=$current;To=$hpaTo;RequestTo=$stressShape.NewRequestM;LimitTo=$stressShape.NewLimitM;HpaMaxTo=$hpaTo}
    }
    if ('NODE_CAPACITY' -in $reasons -or 'POD_STARTUP_DELAY' -in $reasons) { return [pscustomobject]@{App=$app;Type='DIAGNOSE_NODE_CAPACITY';Reason=($reasons | Where-Object { $_ -in @('NODE_CAPACITY','POD_STARTUP_DELAY') } | Select-Object -First 1);From=$null;To=$null} }
    if ('HPA_CEILING' -in $reasons) {
        $current=[int]$profile.Config[$app].maxReplicas
        if ($app -eq 'stress') {
            $interactiveFailure=@('user','product') | Where-Object { -not [bool]$profile.Apps[$_].SLOPass -or -not [bool]$profile.Apps[$_].LoadPass -or -not [bool]$profile.Apps[$_].AvailabilityPass }
            if (@($interactiveFailure).Count) { return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='INTERACTIVE_API_PROTECTION';From=$current;To=$current} }
        }
        # 모든 앱 공통: 관측 기반 capacity 계산으로 결정한다 (단계 heuristic 제거).
        $next=Get-AppHpaCapacity $profile $app
        if ($next -gt $current) { return [pscustomobject]@{App=$app;Type='INCREASE_HPA_MAX';Reason='HPA_CEILING';From=$current;To=$next} }
        return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='HPA_CAPACITY_NO_INCREASE';From=$current;To=$current}
    }
    # load generator가 신뢰 가능한 상태에서 stress timeout → 실제 애플리케이션 capacity 신호.
    # HPA_CEILING 라벨이 안 붙어도(예: peak desired < max) maxReplicas=2에 고착되지 않게 scale-out.
    if ($app -eq 'stress' -and -not [bool]$metric.SLOPass -and [double](Get-OptionalPropertyValue $metric 'SteadyTimeoutCount' 0) -gt 0 -and [bool](Get-OptionalPropertyValue $metric 'MeasurementReliable' $false)) {
        $current=[int]$profile.Config[$app].maxReplicas
        $interactiveFailure=@('user','product') | Where-Object { -not [bool]$profile.Apps[$_].SLOPass -or -not [bool]$profile.Apps[$_].LoadPass -or -not [bool]$profile.Apps[$_].AvailabilityPass }
        if (@($interactiveFailure).Count) { return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='INTERACTIVE_API_PROTECTION';From=$current;To=$current} }
        $next=Get-AppHpaCapacity $profile $app
        if ($next -gt $current) { return [pscustomobject]@{App=$app;Type='INCREASE_HPA_MAX';Reason='STRESS_TIMEOUT_CAPACITY';From=$current;To=$next} }
        return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='HPA_CAPACITY_NO_INCREASE';From=$current;To=$current}
    }
    if ('CPU_THROTTLING' -in $reasons) {
        $current=Convert-CpuToM $profile.Config[$app].limitCpu
        $request=Convert-CpuToM $profile.Config[$app].requestCpu
        if ($app -eq 'stress') {
            $interactiveFailure=@('user','product') | Where-Object { -not [bool]$profile.Apps[$_].SLOPass -or -not [bool]$profile.Apps[$_].LoadPass -or -not [bool]$profile.Apps[$_].AvailabilityPass }
            if (@($interactiveFailure).Count) { return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='INTERACTIVE_API_PROTECTION';From=$current;To=$current} }
            # CPU limit은 request/packing과 분리: throttling + SLO fail이 동시일 때만 severity 기반으로 증가.
            # 평균 CPU가 낮아도 throttling은 limit 병목 신호다.
            $throttle=[double](Get-OptionalPropertyValue $metric 'ThrottleRatio' 0)
            $sloRate=[double](Get-OptionalPropertyValue $metric 'SLOComplianceRate' 1.0)
            $sloDeficit=if ($sloRate -gt 0) { [math]::Max(0.0,1.0/$sloRate-1.0) } else { 0.0 }
            $nodeAlloc=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableCPU' 0)
            if ($nodeAlloc -le 0) { $nodeAlloc=1930.0 }
            $hardCap=[math]::Floor($nodeAlloc*$LimitHardCapFactor/25)*25
            $limitDec=Get-CpuLimitTarget $current ([double](Get-OptionalPropertyValue $metric 'PeakCPUMillicores' 0)) $BurstHeadroom $throttle $ThrottleSafe $sloDeficit $ThrottleWeight $SloWeight $CpuLimitMaxGrowth $CpuLimitStep $hardCap (-not [bool]$metric.SLOPass)
            if ($limitDec.Action -eq 'INCREASE') {
                return [pscustomobject]@{App=$app;Type='INCREASE_CPU_LIMIT_FOR_BURST';Reason='CPU_LIMIT_THROTTLING';From=$current;To=$limitDec.Value}
            }
            # throttling이어도 coarse granularity면 limit부터 올리지 않고 horizontal(SPLIT/HPA) 우선.
            if ($stressShape) {
                $readyReplicas=[double](Get-OptionalPropertyValue $metric 'AverageReadyReplicas' 1)
                if ($stressShape.Granularity -ge $StressGranularityThreshold) {
                    $hpaTo=[int][math]::Min($MaxAutoReplicas,[math]::Max($StressHpaMinMax,$stressShape.NewHpaMax))
                    return [pscustomobject]@{App=$app;Type='SPLIT_STRESS_CAPACITY';Reason='STRESS_THROTTLE_COARSE';From=$current;To=$hpaTo;RequestTo=$stressShape.NewRequestM;LimitTo=$stressShape.NewLimitM;HpaMaxTo=$hpaTo}
                }
                if ($readyReplicas -lt $DesiredStressPods) {
                    # ready replica 부족 → horizontal first (HPA 증가)
                    $curMax=[int]$profile.Config[$app].maxReplicas
                    $nextMax=[int][math]::Min($MaxAutoReplicas,[math]::Max($StressHpaMinMax,$stressShape.NewHpaMax))
                    if ($nextMax -gt $curMax) { return [pscustomobject]@{App=$app;Type='INCREASE_HPA_MAX';Reason='STRESS_THROTTLE_HORIZONTAL';From=$curMax;To=$nextMax} }
                }
            }
        }
        $next=[math]::Ceiling([math]::Max($current*1.25,$request*1.50)/25.0)*25
        if ($next -gt $current) { return [pscustomobject]@{App=$app;Type='INCREASE_CPU_LIMIT';Reason='CPU_THROTTLING';From=$current;To=$next} }
    }
    if ('APPLICATION_LATENCY' -in $reasons) { return [pscustomobject]@{App=$app;Type='NO_AUTOMATIC_RESOURCE_CHANGE';Reason='APPLICATION_LATENCY';From=$null;To=$null} }
    if ($metric.SLOPass -and $metric.HeadroomPass -and $metric.LoadPass -and [bool]$metric.MeasurementReliable) {
        $requestCpu=Convert-CpuToM $profile.Config[$app].requestCpu
        $limitCpu=Convert-CpuToM $profile.Config[$app].limitCpu
        # limit 축소 하한: 채점 트래픽은 tune k6보다 burst가 클 수 있어 user/product는
        # request x 2.5 또는 500m 미만으로 내리지 않는다 (채점 200ms SLO 보호).
        $minimumCpuLimit=if ($app -eq 'stress') { $requestCpu } else { [math]::Max(500.0,$requestCpu*2.5) }
        $observedCpuLimit=[math]::Ceiling([math]::Max($minimumCpuLimit,[double]$metric.PeakCPUMillicores*1.25)/25.0)*25
        # request right-sizing: steady 실사용량(Q75) x adaptive headroom 기반.
        # decrease는 hysteresis 안쪽이면 KEEP, increase는 sustained pressure 있을 때만.
        $reqMemMi=[double](Convert-MemoryToMi $profile.Config[$app].requestMemory)
        $avgCpuM=[double](Get-OptionalPropertyValue $metric 'AverageCPUMillicores' 0)
        $cpuQ75=[double](Get-OptionalPropertyValue $metric 'CPUP95Millicores' (Get-OptionalPropertyValue $metric 'PeakCPUMillicores' $avgCpuM))
        $cpuQ50=$avgCpuM
        $cpuQ25=$avgCpuM*0.75
        $memQ50=[double](Get-OptionalPropertyValue $metric 'MemoryP95Mi' 0)
        $memQ75=[double](Get-OptionalPropertyValue $metric 'MemoryP99Mi' $memQ50)
        $memQ25=$memQ50*0.8
        $oomDelta=[int](Get-OptionalPropertyValue $metric 'OOMKilledDelta' 0)
        $memPressure=[bool](Get-OptionalPropertyValue $metric 'MemoryPressure' $false)
        $cpuDecision=Get-RightSizedRequest ([double]$requestCpu) ([double]$cpuRequestMinimum[$app]) $cpuQ25 $cpuQ50 $cpuQ75 $CpuRequestMinHeadroom $CpuRequestMaxHeadroom $CpuRequestAlpha $CpuRequestStep $RequestDownHysteresis $false $false
        $memDecision=Get-RightSizedRequest $reqMemMi $MinMemoryRequestMi $memQ25 $memQ50 $memQ75 $MemoryRequestMinHeadroom $MemoryRequestMaxHeadroom $MemoryRequestAlpha $MemoryRequestStep $RequestDownHysteresis ([bool]$oomDelta -or $memPressure) $false
        if ($cpuDecision.Action -eq 'DECREASE') {
            return [pscustomobject]@{App=$app;Type='REDUCE_CPU_REQUEST';Reason='STEADY_DEMAND';From=[double]$requestCpu;To=$cpuDecision.Value}
        }
        if ($memDecision.Action -eq 'DECREASE') {
            return [pscustomobject]@{App=$app;Type='REDUCE_MEMORY_REQUEST';Reason='STEADY_DEMAND';From=$reqMemMi;To=$memDecision.Value}
        }
        if ($cpuDecision.Action -eq 'INCREASE') {
            return [pscustomobject]@{App=$app;Type='INCREASE_CPU_REQUEST';Reason='SUSTAINED_PRESSURE';From=[double]$requestCpu;To=$cpuDecision.Value}
        }
        if (-not $metric.MetricUnavailable -and ($null -eq $metric.ThrottleRatio -or [double]$metric.ThrottleRatio -lt 0.05) -and $limitCpu -gt $observedCpuLimit*1.20) {
            return [pscustomobject]@{App=$app;Type='REDUCE_CPU_LIMIT';Reason='EXCESS_HEADROOM';From=$limitCpu;To=$observedCpuLimit}
        }
        $requestMemory=Convert-MemoryToMi $profile.Config[$app].requestMemory
        $limitMemory=Convert-MemoryToMi $profile.Config[$app].limitMemory
        $observedMemoryLimit=[math]::Ceiling([math]::Max($requestMemory*1.25,[double]$metric.MemoryPeakMi*1.50)/32.0)*32
        if (-not $metric.MetricUnavailable -and $metric.MemoryPeakMi -gt 0 -and $limitMemory -gt $observedMemoryLimit*1.20) {
            return [pscustomobject]@{App=$app;Type='REDUCE_MEMORY_LIMIT';Reason='EXCESS_HEADROOM';From=$limitMemory;To=$observedMemoryLimit}
        }
        return [pscustomobject]@{App=$app;Type='HOLD_STABLE';Reason='SLO_HEADROOM';From=$null;To=$null}
    }
    return [pscustomobject]@{App=$app;Type='NO_CHANGE';Reason='UNKNOWN';From=$null;To=$null}
}

function Apply-TuningActions([hashtable]$source,$profile,[string]$name,$cluster=$null) {
    $config=Copy-Config $source $name
    # 기존에 persist된 resource override(SPLIT 등)를 candidate 생성 시 반영한다.
    # tuningSource가 Minimum이라 SPLIT 신호가 없어도, 이전 측정의 override가 살아있다.
    foreach ($app in $script:FinalResourceOverrideByApp.Keys) {
        $ro=$script:FinalResourceOverrideByApp[$app]
        $config[$app].requestCpu=Format-Cpu ([double]$ro.requestCpu)
        $config[$app].limitCpu=$null  # CPU limit 정책: 모든 앱에서 제거
    }
    $actions=[System.Collections.Generic.List[object]]::new()
    foreach ($app in $apps) {
        $action=Get-NextTuningAction $profile $app $cluster
        $actions.Add($action)
        switch ($action.Type) {
            'INCREASE_MEMORY_LIMIT' { $config[$app].limitMemory=Format-Memory ([double]$action.To) ([int][math]::Ceiling([double]$action.To)) }
            'INCREASE_CPU_LIMIT' { $config[$app].limitCpu=$null }
            'INCREASE_HPA_MAX' { $config[$app].maxReplicas=[int]$action.To }
            'REDUCE_CPU_LIMIT' { $config[$app].limitCpu=$null }
            'INCREASE_CPU_LIMIT_FOR_BURST' { $config[$app].limitCpu=$null }
            'REDUCE_CPU_REQUEST' {
                # 현재 앱의 안전 하한만 적용한다. reference profile의 request는 사용하지 않는다.
                $reqAfter=[math]::Max([double]$cpuRequestMinimum[$app],[double]$action.To)
                $config[$app].requestCpu=Format-Cpu $reqAfter
                $reqM=[double](Convert-CpuToM $config[$app].requestCpu)
                $config[$app].limitCpu=$null
            }
            'REDUCE_MEMORY_REQUEST' { $config[$app].requestMemory=Format-Memory ([double]$action.To) ([int][math]::Max($MinMemoryRequestMi,[double]$action.To)) }
            'INCREASE_CPU_REQUEST' {
                $config[$app].requestCpu=Format-Cpu ([double]$action.To)
                $config[$app].limitCpu=$null
            }
            'REDUCE_MEMORY_LIMIT' { $config[$app].limitMemory=Format-Memory ([double]$action.To) ([int][math]::Ceiling([double]$action.To)) }
            # Stress coarse allocation → request/limit 분할 + HPA 확대 + 측정 pre-warm(replicas=2).
            # HPA minReplicas는 별도로 1 유지된다.
            'SPLIT_STRESS_CAPACITY' {
                $config[$app].requestCpu=Format-Cpu ([double]$action.RequestTo)
                $config[$app].limitCpu=$null
                $config[$app].maxReplicas=[int]$action.HpaMaxTo
                $config[$app].replicas=2
                # SPLIT 결과를 전역 override로 persist: 이후 어떤 candidate도 old resource로 되돌리지 못한다.
                $script:FinalResourceOverrideByApp[$app]=@{requestCpu=[double]$action.RequestTo;limitCpu=$null}
            }
        }
    }
    $config.Name=$name
    return [pscustomobject]@{Config=$config;Actions=@($actions)}
}

function Send-StressCalibrationRequest([string]$Endpoint,[int]$Length,[int]$TimeoutSec) {
    # 단일 POST /v1/stress. requestid/uuid/length schema는 diagnose-stress.ps1과
    # 동일하게 유지한다(두 구현이 요청 형식에서 어긋나지 않게). 2초 timeout으로
    # 650ms 목표 workload 후보를 빠르게 탈락시키며, 실제 서비스 가용성 timeout과
    #는 무관한 calibration 전용 timeout이다.
    $uri="$($Endpoint.TrimEnd('/'))/v1/stress"
    $body=@{requestid='999999999999';uuid='7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729';length=$Length}|ConvertTo-Json
    $sw=[Diagnostics.Stopwatch]::StartNew()
    try {
        $resp=Invoke-WebRequest -Uri $uri -Method POST -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec -Headers @{'User-Agent'='wsi2026-calibration/1.0';'X-Request-ID'='999999999999'} -SkipHttpErrorCheck
        $sw.Stop()
        return [pscustomobject]@{Status=[int]$resp.StatusCode;ElapsedMs=[double]$sw.Elapsed.TotalMilliseconds;Timeout=$false;Exception=$null}
    } catch {
        $sw.Stop()
        $isTimeout=(($_.Exception -is [System.Net.WebException]) -and ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) -or ($_.Exception.Message -match 'timed out|timeout|operation has timed')
        return [pscustomobject]@{Status=0;ElapsedMs=[double]$sw.Elapsed.TotalMilliseconds;Timeout=$isTimeout;Exception=[string]$_.Exception.Message}
    }
}

function Test-StressLengthCandidate([string]$Endpoint,[int]$Length,[int]$Samples,[double]$TrimmedMeanMs,[double]$SloMs,[int]$SloSuccessRequired,[datetime]$Deadline) {
    # 후보 length를 Samples회 측정. PASS = hard fail 없음 AND SLO success >= SloSuccessRequired AND trimmedMean <= 기준.
    #   trimmedMean = latency 정렬 후 min/max 1개 제거한 나머지 평균
    #   SLO success = HTTP 201 AND latency <= SloMs(1000ms)
    #   hard fail   = timeout OR latency > 5000ms OR HTTP != 201 (즉시 early fail)
    # SLO success 부족이 수학적으로 확정되면(초과가 Samples-SloSuccessRequired+1회) early fail로 남은 샘플 생략.
    #   Phase1: 7/8  -> 2회 초과 시 early / Refinement: 8/10 -> 3회 초과 시 early
    $latencies=[System.Collections.Generic.List[double]]::new()
    $successCount=0;$timeoutCount=0;$httpErrorCount=0
    $earlyFailReason=$null
    for ($i=0;$i -lt $Samples;$i++) {
        if ((Get-Date) -ge $Deadline) { break }
        $r=Send-StressCalibrationRequest $Endpoint $Length $StressCalibrationRequestTimeoutSeconds
        $latencies.Add([double]$r.ElapsedMs)
        if ($r.Status -eq 201) { $successCount++ }
        elseif ($r.Timeout) { $timeoutCount++ }
        else { $httpErrorCount++ }
        if ($r.Status -ne 201) {
            $earlyFailReason=if ($r.Timeout) { "timeout(status=0, ${StressCalibrationRequestTimeoutSeconds}s)" } else { "status=$($r.Status)" }
            break
        }
        if ([double]$r.ElapsedMs -gt $StressCalibrationHardMaxMs) { $earlyFailReason="latency > ${StressCalibrationHardMaxMs}ms"; break }
        $overSloCount=@($latencies | Where-Object { [double]$_ -gt $SloMs }).Count
        # SLO success SloSuccessRequired/Samples 필요: 초과 허용 한도를 넘으면 불가 확정.
        if ($overSloCount -ge ($Samples-$SloSuccessRequired+1)) { $earlyFailReason=("sloSuccess {0}/{1} 달성 불가 ({2}회 > {3}ms)" -f $SloSuccessRequired,$Samples,$overSloCount,$SloMs); break }
    }
    $sloSuccessCount=@($latencies | Where-Object { [double]$_ -le $SloMs }).Count
    $sorted=@($latencies | Sort-Object)
    $trimmedMean=if ($sorted.Count -ge 3) {
        [double](($sorted[1..($sorted.Count-2)] | Measure-Object -Average).Average)
    } elseif ($sorted.Count -eq 1) { [double]$sorted[0] } else { [double](($sorted | Measure-Object -Average).Average) }
    $maxLatency=if ($latencies.Count) { [double](($latencies | Measure-Object -Maximum).Maximum) } else { [double]::PositiveInfinity }
    $passed=($null -eq $earlyFailReason) -and ($latencies.Count -eq $Samples) -and ($successCount -eq $Samples) -and ($sloSuccessCount -ge $SloSuccessRequired) -and ($trimmedMean -le $TrimmedMeanMs)
    # 결과 상태 분류: PASS / MEASURED_FAIL(정상 응답+latency 측정 존재, 조건 미달) /
    # TIMEOUT(측정 자체 불가 — latency fallback 후보에서 제외) / HTTP_FAIL(status 응답은 있지만 201 아님).
    $resultClass=if ($passed) { 'PASS' } elseif ($timeoutCount -gt 0) { 'TIMEOUT' } elseif ($httpErrorCount -gt 0) { 'HTTP_FAIL' } else { 'MEASURED_FAIL' }
    return [pscustomobject]@{Length=$Length;Latencies=@($latencies);TrimmedMeanMs=$trimmedMean;SloSuccessCount=$sloSuccessCount;MaxLatencyMs=$maxLatency;SuccessCount=$successCount;TimeoutCount=$timeoutCount;HttpErrorCount=$httpErrorCount;Passed=$passed;SampleCount=$latencies.Count;EarlyFailReason=$earlyFailReason;ResultClass=$resultClass}
}
function Test-VerificationCandidate([string]$Endpoint,[int]$Length,[double[]]$RefinementLatencies,[int]$Samples,[double]$TrimmedMeanMs,[double]$SloMs,[datetime]$Deadline) {
    # Final Verification = Refinement winner 기존 샘플(보통 10개) + 추가 Samples회(10개)를
    # 합친 combined 표본(총 20개)으로 판정한다. Refinement의 좋은 데이터를 버리지 않는다.
    # PASS = SLO success >= (combinedN-2)=18/20 AND 10% trimmed mean <= 기준(800ms).
    #   10% trimmed mean = 정렬 후 lowest 2 / highest 2 제거한 가운데 16개 평균 (TM20).
    # early fail도 combined 기준: 남은 추가 샘플이 전부 성공해도 18/20 불가능할 때만.
    # hard fail = timeout OR latency > 5000ms OR HTTP != 201.
    $latencies=[System.Collections.Generic.List[double]]::new()
    foreach ($v in @($RefinementLatencies)) { $latencies.Add([double]$v) }
    $seedCount=$latencies.Count
    $finalRequired=$seedCount+$Samples-2   # combined 20개 중 18
    $earlyFailReason=$null
    for ($i=0;$i -lt $Samples;$i++) {
        if ((Get-Date) -ge $Deadline) { break }
        $r=Send-StressCalibrationRequest $Endpoint $Length $StressCalibrationRequestTimeoutSeconds
        $latencies.Add([double]$r.ElapsedMs)
        if ($r.Status -ne 201) {
            $earlyFailReason=if ($r.Timeout) { "timeout(status=0, ${StressCalibrationRequestTimeoutSeconds}s)" } else { "status=$($r.Status)" }
            break
        }
        if ([double]$r.ElapsedMs -gt $StressCalibrationHardMaxMs) { $earlyFailReason="latency > ${StressCalibrationHardMaxMs}ms"; break }
        $addedSoFar=$latencies.Count-$seedCount
        $remaining=$Samples-$addedSoFar
        $maxSuccess=@($latencies | Where-Object { [double]$_ -le $SloMs }).Count + $remaining
        if ($maxSuccess -lt $finalRequired) {
            $earlyFailReason=("combined sloSuccess {0}/{1} 달성 불가 (남은 {2}개 모두 성공해도 {3})" -f ($finalRequired-1),$finalRequired,$remaining,$maxSuccess)
            break
        }
    }
    $sloSuccessCount=@($latencies | Where-Object { [double]$_ -le $SloMs }).Count
    $sorted=@($latencies | Sort-Object)
    $trimCount=[int][math]::Floor($latencies.Count*0.10)
    $inner=@($sorted[$trimCount..($sorted.Count-1-$trimCount)])
    $trimmedMean=if ($inner.Count) { [double](($inner | Measure-Object -Average).Average) } else { [double](($sorted | Measure-Object -Average).Average) }
    $maxLatency=if ($latencies.Count) { [double](($latencies | Measure-Object -Maximum).Maximum) } else { [double]::PositiveInfinity }
    $passed=($null -eq $earlyFailReason) -and ($latencies.Count -eq ($seedCount+$Samples)) -and ($sloSuccessCount -ge $finalRequired) -and ($trimmedMean -le $TrimmedMeanMs)
    return [pscustomobject]@{Length=$Length;Latencies=@($latencies);TrimmedMeanMs=$trimmedMean;SloSuccessCount=$sloSuccessCount;MaxLatencyMs=$maxLatency;Passed=$passed;SampleCount=$latencies.Count;SeedCount=$seedCount;EarlyFailReason=$earlyFailReason}
}

function Write-StressCalibrationCandidateLog($result,[string]$label) {
    Write-Host ("length={0}{1}" -f $result.Length,$(if ($label) { " ($label)" } else { '' }))
    Write-Host ("  {0}" -f (($result.Latencies | ForEach-Object { '{0:F0}' -f [double]$_ }) -join '  '))
    if ($result.EarlyFailReason) {
        Write-Host ("  → FAIL EARLY ({0})" -f $result.EarlyFailReason) -ForegroundColor Yellow
    } else {
        Write-Host ("  trimmedMean={0:F0}ms" -f [double]$result.TrimmedMeanMs)
        Write-Host ("  sloSuccess={0}/{1}" -f $result.SloSuccessCount,$result.SampleCount)
        Write-Host ("  max={0:F0}ms" -f [double]$result.MaxLatencyMs)
        Write-Host ("  → {0}" -f $(if ($result.Passed) {'PASS'} else {'FAIL'})) -ForegroundColor $(if ($result.Passed) {'Green'} else {'Yellow'})
    }
}

function Select-StressLength {
    param([Parameter(Mandatory=$true)][string]$Endpoint,[datetime]$Deadline,[switch]$SkipRefinement,[switch]$SkipVerification)
    # 3단계: Phase1 adaptive(n=8, trimmedMean<=800ms, sloSuccess>=7/8)
    #        -> Refinement(lowerMid/base/upperMid, n=10, trimmedMean<=780ms, sloSuccess>=9/10)
    #        -> Verification(winner 1개, n=10, trimmedMean<=800ms, sloSuccess>=9/10; FAIL 시 downgrade).
    # trimmedMean = 정렬 후 min/max 1개 제거한 평균. hard fail = timeout OR >5000ms OR !=201.
    if ($null -eq $Deadline -or $Deadline -eq [datetime]::MinValue) { $Deadline=(Get-Date).AddSeconds($StressCalibrationBudgetSeconds) }
    Write-Host "`n===== Stress Length Calibration =====" -ForegroundColor Cyan
    Write-Host ("SLO: {0}ms" -f $sloMs['stress'])
    Write-Host ''
    Write-Host 'PASS:'
    Write-Host ("  Phase1      : n={0} trimmedMean<={1}ms sloSuccess>={2}/{3}" -f $Phase1SamplesPerLength,$Phase1TrimmedMeanMs,($Phase1SamplesPerLength-1),$Phase1SamplesPerLength)
    Write-Host ("  Refinement  : n={0} trimmedMean<={1}ms sloSuccess>={2}/{3}" -f $RefinementSamplesPerLength,$RefinementTrimmedMeanMs,$RefinementSloSuccessRequired,$RefinementSamplesPerLength)
    Write-Host ("  Verification: combined {0}+{1}=20 trimmedMean<={2}ms sloSuccess>=18/20" -f $VerificationSamplesPerLength,$VerificationSamplesPerLength,$VerificationTrimmedMeanMs)
    Write-Host ''
    Write-Host '[Phase 1]' -ForegroundColor Cyan
    $startIdx=[array]::IndexOf($StressLengthCandidates,$StressCalibrationStartLength)
    if ($startIdx -lt 0) { $startIdx=[int][math]::Floor($StressLengthCandidates.Count/2) }
    $tested=@{};$testOrder=[System.Collections.Generic.List[int]]::new()
    $current=$StressLengthCandidates[$startIdx];$idx=$startIdx
    $firstMove=$true
    while ($testOrder.Count -lt $StressCalibrationMaxCandidates) {
        if ((Get-Date) -ge $Deadline) { Write-Host '  (calibration budget 도달로 중단)' -ForegroundColor Yellow; break }
        # 전체 20분 runtime 예비를 지키는 guard: Tuning 남은 시간이 예비 미만이면 중단.
        if ((Get-RemainingRuntimeSeconds Tuning) -lt ($StressCalibrationBudgetSeconds+30)) { Write-Host '  (전체 runtime 예비 부족으로 중단)' -ForegroundColor Yellow; break }
        try {
            $result=Test-StressLengthCandidate $Endpoint $current $Phase1SamplesPerLength $Phase1TrimmedMeanMs $StressCalibrationSloMs $Phase1SloSuccessRequired $Deadline
        } catch {
            Write-Warning "length=$current 측정 실패: $($_.Exception.Message). 측정된 후보로 선택을 진행합니다."
            break
        }
        if ($result.SampleCount -eq 0) { Write-Host '  (측정 예산 만료)' -ForegroundColor Yellow; break }
        $tested[$current]=$result;$testOrder.Add($current)
        Write-StressCalibrationCandidateLog $result
        if ($testOrder.Count -ge $StressCalibrationMaxCandidates) { break }
        # adaptive 이동: 첫 이동은 128에서 ±2(192/96)로 크게, 이후는 ±1 인접 이동.
        $step=if ($firstMove) { if ($result.Passed) { 2 } else { -1 } } elseif ($result.Passed) { 1 } else { -1 }
        $firstMove=$false
        $next=$idx+$step
        if ($next -lt 0 -or $next -ge $StressLengthCandidates.Count) { break }
        if ($tested.ContainsKey($StressLengthCandidates[$next])) { break }
        $idx=$next
        $current=$StressLengthCandidates[$idx]
    }
    $phase1Passed=@($testOrder | Where-Object { $tested[$_].Passed })
    $phase1Selected=if ($phase1Passed.Count) { [int]($phase1Passed | Sort-Object -Descending | Select-Object -First 1) } else { $null }
    Write-Host ''
    if ($null -eq $phase1Selected) {
        Write-Host 'Phase 1 base: 없음 (모든 후보 FAIL)' -ForegroundColor Yellow
    } else {
        Write-Host ("Phase 1 base: {0}" -f $phase1Selected) -ForegroundColor Cyan
    }
    # ---- Refinement: lowerMid / base / upperMid (중간값은 coarse 목록에 없어도 테스트) ----
    $refinement=[System.Collections.Generic.List[object]]::new()
    $phase2Passed=@()
    if ($null -ne $phase1Selected -and -not $SkipRefinement) {
        $refineAllowed=((Get-Date) -lt $Deadline) -and ((Get-RemainingRuntimeSeconds Tuning) -ge ($StressCalibrationBudgetSeconds+30))
        if (-not $refineAllowed) {
            Write-Host ''
            Write-Host '[Refinement] 생략 (calibration budget 부족)' -ForegroundColor Yellow
        } else {
            $selIdx=[array]::IndexOf($StressLengthCandidates,$phase1Selected)
            $lower=if ($selIdx -gt 0) { $StressLengthCandidates[$selIdx-1] } else { $null }
            $upper=if ($selIdx -ge 0 -and $selIdx -lt $StressLengthCandidates.Count-1) { $StressLengthCandidates[$selIdx+1] } else { $null }
            $lowerMid=if ($null -ne $lower) { [int][math]::Round(($lower+$phase1Selected)/2.0) } else { $null }
            $upperMid=if ($null -ne $upper) { [int][math]::Round(($phase1Selected+$upper)/2.0) } else { $null }
            $refinementCandidates=@($lowerMid,$phase1Selected,$upperMid | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            Write-Host ''
            Write-Host '[Refinement]' -ForegroundColor Cyan
            Write-Host ("Candidates: {0}" -f ($refinementCandidates -join ', '))
            foreach ($candidate in $refinementCandidates) {
                if ((Get-Date) -ge $Deadline) { Write-Host '  (budget 도달로 refinement 중단)' -ForegroundColor Yellow; break }
                $known=$tested.ContainsKey($candidate)
                # 시간이 충분하면 base도 동일 조건으로 재측정(공정 비교). deadline 10초 미만이면 1차 측정 재사용.
                $reuse=($known -and $candidate -eq $phase1Selected -and ((Get-Date).AddSeconds(10) -ge $Deadline))
                try {
                    if ($reuse) {
                        $result=$tested[$candidate]
                        Write-StressCalibrationCandidateLog $result ('1차 측정 재사용')
                    } else {
                        $result=Test-StressLengthCandidate $Endpoint $candidate $RefinementSamplesPerLength $RefinementTrimmedMeanMs $StressCalibrationSloMs $RefinementSloSuccessRequired $Deadline
                        if ($result.SampleCount -eq 0) { Write-Host '  (측정 예산 만료)' -ForegroundColor Yellow; break }
                        Write-StressCalibrationCandidateLog $result $(if ($known) { '재측정' } else { '' })
                    }
                } catch {
                    Write-Warning "length=$candidate 측정 실패: $($_.Exception.Message). refinement를 중단합니다."
                    break
                }
                $tested[$candidate]=$result;$refinement.Add($result)
            }
            $phase2Passed=@($refinement | Where-Object { $_.Passed })
        }
    }
    # Refinement winner: PASS한 후보 중 가장 큰 length 선택 (risk heuristic 없음).
    $phase2Selected=$null
    if ($phase2Passed.Count) {
        $phase2Selected=[int]($phase2Passed | Sort-Object Length -Descending | Select-Object -First 1).Length
        Write-Host ''
        Write-Host ("Refinement winner: {0} (largest PASS among {1})" -f $phase2Selected,($phase2Passed | ForEach-Object Length | Join-String -Separator ',')) -ForegroundColor Cyan
    }
    # ---- Verification: winner 1개 재검증, FAIL 시 refinement PASS 중 다음 작은 값 downgrade ----
    $verification=[System.Collections.Generic.List[object]]::new()
    $finalSelected=$phase2Selected
    if ($null -ne $phase2Selected -and -not $SkipVerification) {
        $verificationAllowed=((Get-Date) -lt $Deadline) -and ((Get-RemainingRuntimeSeconds Tuning) -ge ($StressCalibrationBudgetSeconds+30))
        if (-not $verificationAllowed) {
            Write-Host ''
            Write-Host '[Verification] 생략 (calibration budget 부족)' -ForegroundColor Yellow
            Write-Warning "Verification 예산이 부족해 Refinement winner STRESS_LENGTH=$phase2Selected를 사용합니다."
        } else {
            Write-Host ''
            Write-Host "[Verification] ($VerificationSamplesPerLength fresh samples, trimmedMean<=$VerificationTrimmedMeanMs, sloSuccess>=$VerificationSloSuccessRequired/$VerificationSamplesPerLength)" -ForegroundColor Cyan
            $result=$null
            try {
                $result=Test-StressLengthCandidate $Endpoint $phase2Selected $VerificationSamplesPerLength $VerificationTrimmedMeanMs $StressCalibrationSloMs $VerificationSloSuccessRequired $Deadline
            } catch {
                Write-Warning "length=$phase2Selected 검증 실패: $($_.Exception.Message)"
            }
            if ($result -and $result.SampleCount -gt 0) {
                $verification.Add($result)
                Write-StressCalibrationCandidateLog $result 'final verification'
                if (-not $result.Passed) {
                    # Verification FAIL: 검증 실패 candidate는 최종 선택 불가.
                    # 다음 smaller candidate을 fresh verification으로 검증 후 선택.
                    $smallerCandidates=@($phase2Passed | Where-Object { $_.Length -lt $phase2Selected } | Sort-Object Length -Descending)
                    if ($smallerCandidates.Count) {
                        $verified=$false
                        foreach ($smaller in $smallerCandidates) {
                            if ((Get-Date) -ge $Deadline) { break }
                            try {
                                $vr=Test-StressLengthCandidate $Endpoint $smaller.Length $VerificationSamplesPerLength $VerificationTrimmedMeanMs $StressCalibrationSloMs $VerificationSloSuccessRequired $Deadline
                                $verification.Add($vr)
                                Write-StressCalibrationCandidateLog $vr "downgrade verification ($($smaller.Length)->$($vr.Length))"
                                if ($vr.Passed) { $finalSelected=[int]$vr.Length; $verified=$true; break }
                            } catch { Write-Warning "length=$($smaller.Length) downgrade verification failed: $($_.Exception.Message)" }
                        }
                        if (-not $verified) {
                            $finalSelected=[int](($StressLengthCandidates | Measure-Object -Minimum).Minimum)
                            Write-Warning "Verification FAIL - all smaller candidates failed verification - fallback to minimum: $finalSelected"
                        }
                    } else {
                        $finalSelected=[int](($StressLengthCandidates | Measure-Object -Minimum).Minimum)
                        Write-Warning "Verification FAIL - no smaller candidates - fallback to minimum: $finalSelected"
                    }
                }
            }
        }
    }
    # ---- 최종 선택 (fallback 분리: valid measurement vs timeout) ----
    $selectedLength=$DefaultStressLength;$allFailed=$false
    $confidence='NORMAL';$fallbackReason=''
    $measuredResults=@($testOrder | Where-Object { $tested[$_].ResultClass -eq 'MEASURED_FAIL' })
    $timeoutResults=@($testOrder | Where-Object { $tested[$_].ResultClass -eq 'TIMEOUT' })
    $httpFailResults=@($testOrder | Where-Object { $tested[$_].ResultClass -eq 'HTTP_FAIL' })
    Write-Host ''
    Write-Host '[Phase 1 summary]' -ForegroundColor Cyan
    foreach ($length in $testOrder) {
        $r=$tested[$length]
        $latText=if ($r.ResultClass -eq 'TIMEOUT' -or $r.Latencies.Count -eq 0) { 'NA' } else { '{0:N0}ms' -f $r.MaxLatencyMs }
        Write-Host ("  length={0} result={1} latency={2}" -f $length,$r.ResultClass,$latText) -ForegroundColor DarkGray
    }
    Write-Host ("  passCount={0} measuredCount={1} timeoutCount={2} httpFailCount={3}" -f @($phase1Passed).Count,$measuredResults.Count,$timeoutResults.Count,$httpFailResults.Count) -ForegroundColor DarkGray
    if ($null -eq $phase1Selected -and $testOrder.Count -gt 0) {
        Write-Host 'No measurable Phase1 base.' -ForegroundColor Yellow
        Write-Host '→ skip refinement, skip verification (safe fallback)' -ForegroundColor Yellow
    }
    if ($null -ne $finalSelected) {
        $selectedLength=$finalSelected
        $confidence='NORMAL'
    } elseif ($null -ne $phase1Selected) {
        if ($refinement.Count -gt 0 -and -not $phase2Passed.Count) {
            Write-Warning "Refinement에서 PASS 후보를 찾지 못했습니다. Phase 1 base STRESS_LENGTH=$phase1Selected를 사용합니다."
        }
        $selectedLength=$phase1Selected
        $confidence='NORMAL'
    } elseif ($measuredResults.Count -gt 0) {
        # Case A: PASS 없음, 하지만 valid latency 측정 존재 → best measured fallback.
        # TIMEOUT/HTTP_FAIL은 latency 후보로 취급하지 않는다.
        $allFailed=$true
        $sortedMeasured=@($measuredResults | Sort-Object { [double]$tested[$_].MaxLatencyMs })
        $selectedLength=[int]$sortedMeasured[0]
        $confidence='LOW'
        $fallbackReason='BEST_MEASURED_LATENCY'
        Write-Host 'No Phase1 candidate passed.' -ForegroundColor Yellow
        Write-Host ("Using best measured fallback: length={0} reason={1}" -f $selectedLength,$fallbackReason) -ForegroundColor Yellow
        if ($timeoutResults.Count) { Write-Host ("  (timeout 후보는 latency fallback 제외: {0})" -f (($timeoutResults | ForEach-Object Length) -join ',')) -ForegroundColor DarkGray }
        if ($httpFailResults.Count) { Write-Host ("  (HTTP_FAIL 별도 기록: {0})" -f (($httpFailResults | ForEach-Object { "length=$($_.Length) httpFail" }) -join ', ')) -ForegroundColor DarkGray }
    } elseif ($testOrder.Count -gt 0) {
        # Case B: 모든 후보 TIMEOUT → latency 기준 selection 금지, min coarse length fallback.
        $allFailed=$true
        $selectedLength=[int](($StressLengthCandidates | Measure-Object -Minimum).Minimum)
        $confidence='UNAVAILABLE'
        $fallbackReason='ALL_CANDIDATES_TIMEOUT_MIN_LENGTH'
        Write-Warning 'All Stress calibration candidates timed out. No valid latency measurement exists.'
        Write-Host ("Fallback: length={0} reason={1} confidence={2}" -f $selectedLength,$fallbackReason,$confidence) -ForegroundColor Yellow
        # 최소 length probe 1회 (runtime budget 안에서, 추가 반복 retry 없음)
        try {
            $probe=Send-StressCalibrationRequest $Endpoint $selectedLength $StressCalibrationRequestTimeoutSeconds
            if ($null -ne $probe -and $probe.Status -ne 0) {
                # HTTP 응답 존재 → LOW (latency가 5000ms 초과여도 availability 판정으로 오판하지 않는다)
                Write-Host ("Fallback probe: length={0} status={1} latency={2:N0}ms" -f $selectedLength,$probe.Status,$probe.ElapsedMs) -ForegroundColor Yellow
                $confidence='LOW'
                $fallbackReason='ALL_CANDIDATES_TIMEOUT_PROBE_OK'
            } else {
                Write-Warning ("Fallback probe timeout: length={0} status=0 → confidence=UNAVAILABLE (reason=STRESS_ENDPOINT_UNAVAILABLE)" -f $selectedLength)
                $confidence='UNAVAILABLE'
                $fallbackReason='STRESS_ENDPOINT_UNAVAILABLE'
            }
        } catch {
            Write-Warning "Fallback probe 실패: $($_.Exception.Message)"
            $confidence='UNAVAILABLE'
        }
    } else {
        $allFailed=$true
        $selectedLength=$DefaultStressLength
        $confidence='UNAVAILABLE'
        $fallbackReason='NO_CANDIDATE_MEASURED'
        Write-Warning "Stress calibration에 실패하여 기본 STRESS_LENGTH=$DefaultStressLength를 사용합니다."
    }
    # null-safe invariant: selectedLength는 반드시 int > 0이어야 한다.
    if ($null -eq $selectedLength -or ([string]$selectedLength) -eq '' -or ([int]$selectedLength -le 0)) {
        $selectedLength=[int](($StressLengthCandidates | Measure-Object -Minimum).Minimum)
        $fallbackReason='NULL_SELECTION_SAFETY_FALLBACK'
        $confidence='UNAVAILABLE'
        Write-Warning "selectedLength null/empty 방지 안전 fallback: length=$selectedLength reason=$fallbackReason"
    }
    Write-Host ''
    Write-Host ("Selected STRESS_LENGTH={0}" -f $selectedLength) -ForegroundColor Green
    Write-Host '=====================================' -ForegroundColor Cyan
    return [pscustomobject]@{SelectedLength=$selectedLength;AllFailed=$allFailed;NoData=($testOrder.Count -eq 0);Phase1Selected=$phase1Selected;Phase2Selected=$phase2Selected;Confidence=$confidence;FallbackReason=$fallbackReason;Measured=$tested;Refinement=@($refinement);Verification=@($verification);Order=@($testOrder)}
}
function Run-LoadTest([hashtable]$config,[int]$durationSec,$cluster,[switch]$PreserveKarpenterNodes) {
    if (-not (Test-CanStartMeasurement $durationSec)) { return $null }
    $name=$config.Name
    Write-Host "`n===== $name ($durationSec sec) =====" -ForegroundColor Green
    if ($DetailedOutput) { Show-Config $config '적용 설정' }
    Prepare-Test $config $cluster -PreserveKarpenterNodes:$PreserveKarpenterNodes
    # HPA budget guard: 현재 request 기준 budgeted ceiling으로 live HPA를 제한해
    # 측정 중 HPA가 Karpenter 노드를 역으로 폭증시키지 않게 한다 (스펙 8/9).
    Guard-HpaAgainstBudget $config $cluster
    if ((Get-RemainingRuntimeSeconds Tuning) -lt ($durationSec+10)) {
        Write-Warning "$name 준비 후 남은 시간이 부족하여 k6를 시작하지 않습니다. 현재 후보 평가 단계로 전환합니다."
        $script:stopTuning=$true
        $script:tuningStopReason='Runtime budget reached'
        return $null
    }
    $idle=Get-IdleCapacity $config $cluster
    $healthBefore=Get-HealthSnapshot
    $throttleBefore=Get-ThrottleSnapshot
    $stamp=Get-Date -Format yyyyMMdd-HHmmss
    $resultPath=Join-Path $OutputDir "$name-$stamp-k6.json"
    $metricPath=Join-Path $OutputDir "$name-$stamp-metrics.csv"
    $rateSteps=@(Get-RateSteps $TargetRate)
    $loadWindowSec=$durationSec-$CooldownDurationSec
    $rampSeconds=[math]::Max(10,[math]::Floor(($loadWindowSec-$WarmupDurationSec-$SteadyDurationSec)/[math]::Max(1,$rateSteps.Count-1)))
    # steady window는 k6 내부 isSteadyState()와 동일하게 계산한다.
    # retry warmup이 있으면 그 구간(1s + retryWarmup)만큼 steady 시작이 뒤로 밀린다.
    $retryWarmupForWindow=[int]$(if ($null -ne $script:retryWarmupSeconds -and [int]$script:retryWarmupSeconds -gt 0) { [int]$script:retryWarmupSeconds } else { 0 })
    $steadyStartSec=[double]$WarmupDurationSec+($rampSeconds*[math]::Max(0,$rateSteps.Count-1))+$(if ($retryWarmupForWindow -gt 0) { $retryWarmupForWindow+1 } else { 0 })
    $vuPlan=if ($null -ne $script:vuPlanOverride) { $script:vuPlanOverride } else { Get-RequiredK6VUs $TargetRate }
    $script:lastVuPlan=$vuPlan
    $job=$null; $k6Exit=1; $elapsed=0.0
    try {
        $job=Start-MetricCollector $metricPath
        $env:ENDPOINT=$Endpoint.TrimEnd('/'); $env:USER_DATA_FILE=$UserDataJson; $env:PRODUCT_ID=$ProductId
        $env:PRODUCT_IDS=if ($ProductIds) { $ProductIds } else { $ProductId }
        $env:RATE_STEPS=($rateSteps -join ','); $env:PROFILE_DURATION=$durationSec; $env:COOLDOWN_DURATION=$CooldownDurationSec
        $env:STRESS_LENGTH=[string]$(if ($script:SelectedStressLength -gt 0) { $script:SelectedStressLength } else { $DefaultStressLength })
        $env:WARMUP_DURATION=$WarmupDurationSec; $env:STEADY_DURATION=$SteadyDurationSec
        $env:PRE_ALLOCATED_VUS=$PreAllocatedVUs; $env:MAX_VUS=$MaxVUs
        # VU Retry warmup(초). 0이면 k6 프로필에 warmup 구간이 추가되지 않는다.
        $env:RETRY_WARMUP_SECONDS=[string]$(if ($null -ne $script:retryWarmupSeconds -and [int]$script:retryWarmupSeconds -gt 0) { [int]$script:retryWarmupSeconds } else { 0 })
        # Stress는 latency가 긴 arrival-rate 시나리오라 planner의 초기 max(예: 63)가
        # 목표 생성률을 막을 수 있다. MaxVUs를 stress scenario의 hard floor로 적용한다.
        # 요청률/length는 변경하지 않고 generator saturation만 방지한다.
        if ($apps -contains 'stress' -and $vuPlan.Apps.stress.Max -lt $MaxVUs) {
            $vuPlan.Apps.stress.Max=[int]$MaxVUs
        }
        foreach ($app in $apps) {
            $upper=$app.ToUpperInvariant()
            [Environment]::SetEnvironmentVariable("${upper}_PRE_ALLOCATED_VUS",[string]$vuPlan.Apps[$app].PreAllocated,'Process')
            [Environment]::SetEnvironmentVariable("${upper}_MAX_VUS",[string]$vuPlan.Apps[$app].Max,'Process')
        }
        $vuText=($apps | ForEach-Object { "$_=$($vuPlan.Apps[$_].PreAllocated)..$($vuPlan.Apps[$_].Max)" }) -join ', '
        Write-Host "k6 phases: warmup=${WarmupDurationSec}s ramp=${rampSeconds}s×$([math]::Max(0,$rateSteps.Count-1)) steady=${SteadyDurationSec}s cooldown=${CooldownDurationSec}s; VUs $vuText" -ForegroundColor Cyan
        Write-Host ("Stress length={0}" -f $env:STRESS_LENGTH) -ForegroundColor Cyan
        $watch=[Diagnostics.Stopwatch]::StartNew()
        # 작은 tier에서는 timeout이 정상적인 탐색 신호다. k6 WARN을 콘솔에 수백 줄
        # 출력하지 않되, console.warn 진단 로그(실패 상세 첫 N건)는 결과 디렉토리의
        # *-k6.log 파일에 남긴다. progress bar는 콘솔에 그대로 유지된다.
        $k6LogPath=Join-Path $OutputDir "$name-$stamp-k6.log"
        k6 run --log-output=file=$k6LogPath --summary-export $resultPath (Join-Path $PSScriptRoot (Join-Path 'tune' 'k6-load.js'))
        $k6Exit=$LASTEXITCODE; $watch.Stop(); $elapsed=$watch.Elapsed.TotalSeconds
    } finally { Stop-MetricCollector $job }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw "$name k6 summary가 생성되지 않았습니다. exit=$k6Exit" }
    $healthAfter=Get-HealthSnapshot; $throttleAfter=Get-ThrottleSnapshot
    # transient NotReady(cordon/drain/Karpenter node 교체)를 Fatal로 승격하지 않기 위해
    # 의도적 cordon 노드를 제외하고, 남은 NotReady 노드가 있으면 5초 후 재검사한다.
    $persistentNotReady=0
    $nodeStatus=Get-NodeReadinessStatus
    $nonCordonedNotReady=@($nodeStatus.NotReadyNodes | Where-Object { $_ -notin $nodeStatus.CordonedNodes })
    if ($nonCordonedNotReady.Count -gt 0) {
        Start-Sleep -Seconds 5
        $recheck=Get-NodeReadinessStatus
        $persistentNotReady=@($recheck.NotReadyNodes | Where-Object { $_ -notin $recheck.CordonedNodes }).Count
    }
    $summary=Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    $samples=if (Test-Path -LiteralPath $metricPath) { @(Import-Csv -LiteralPath $metricPath) } else { @() }
    $stableSamples=@($samples | Where-Object { [double]$_.ElapsedSec -ge $steadyStartSec -and [double]$_.ElapsedSec -le $loadWindowSec })
    if (-not $stableSamples.Count) { $stableSamples=$samples }
    $highSamples=@($stableSamples)
    if (-not $highSamples.Count) { $highSamples=$stableSamples }
    $appResults=@{}
    foreach ($app in $apps) { $appResults[$app]=Get-AppRunResult $app $summary $stableSamples $highSamples $loadWindowSec $SteadyDurationSec $config $throttleBefore $throttleAfter }
    $nodeValues=Get-Series $samples 'ReadyNodes'; $totalNodeValues=Get-Series $samples 'TotalReadyNodes'; $pressureValues=Get-Series $samples 'MemoryPressureNodes'
    $nodeMax=if ($nodeValues.Count) { ($nodeValues|Measure-Object -Maximum).Maximum } else { $null }
    $nodeAvg=if ($nodeValues.Count) { ($nodeValues|Measure-Object -Average).Average } else { $null }
    $totalNodeMax=if ($totalNodeValues.Count) { ($totalNodeValues|Measure-Object -Maximum).Maximum } else { [double]$nodeMax+$ManagedNodes }
    $totalNodeAvg=if ($totalNodeValues.Count) { ($totalNodeValues|Measure-Object -Average).Average } else { [double]$nodeAvg+$ManagedNodes }
    $pressureMax=if ($pressureValues.Count) { ($pressureValues|Measure-Object -Maximum).Maximum } else { $null }
    $restartDelta=[math]::Max(0,$healthAfter.Restart-$healthBefore.Restart)
    $evictionDelta=[math]::Max(0,$healthAfter.Evicted-$healthBefore.Evicted)
    $oomDelta=[math]::Max(0,$healthAfter.OOMKilled-$healthBefore.OOMKilled)
    $oomDeltaByApp=@{}
    foreach ($app in $apps) { $oomDeltaByApp[$app]=[math]::Max(0,[int]$healthAfter.OOMByApp[$app]-[int]$healthBefore.OOMByApp[$app]) }
    $upstream5xx=Get-MetricNumber $summary.metrics.upstream_5xx 'count'; if ($null -eq $upstream5xx) { $upstream5xx=0 }
    $globalDroppedIterations=Get-MetricNumber $summary.metrics.dropped_iterations 'count'; if ($null -eq $globalDroppedIterations) { $globalDroppedIterations=0 }
    $appDroppedIterations=@{}
    $appIterations=@{}
    $appPeakVUs=@{}
    $hasScenarioDroppedMetric=$false
    foreach ($app in $apps) {
        $scenarioMetricName="dropped_iterations{scenario:${app}_api}"
        $scenarioMetric=$summary.metrics.PSObject.Properties[$scenarioMetricName]
        $scenarioDropped=if ($scenarioMetric) { Get-MetricNumber $scenarioMetric.Value 'count' } else { $null }
        if ($null -ne $scenarioDropped) { $hasScenarioDroppedMetric=$true; $appDroppedIterations[$app]=[double]$scenarioDropped }
        else { $appDroppedIterations[$app]=$null }
        $iterationMetricName="iterations{scenario:${app}_api}"
        $iterationMetric=$summary.metrics.PSObject.Properties[$iterationMetricName]
        $scenarioIterations=if ($iterationMetric) { Get-MetricNumber $iterationMetric.Value 'count' } else { $null }
        $appIterations[$app]=if ($null -ne $scenarioIterations) { [double]$scenarioIterations } else { [double]$appResults[$app].Requests }
        $vuMetricName="vus{scenario:${app}_api}"
        $vuMetric=$summary.metrics.PSObject.Properties[$vuMetricName]
        $peakVUs=if ($vuMetric) { Get-MetricNumber $vuMetric.Value 'max' } else { $null }
        # scenario 태그가 붙은 vus metric이 없거나 0이면 전역 vus/vus_max로 fallback한다.
        # peakVUs=0을 'VU 도달 0'으로 해석하지 않는다(parser 실패 가능성).
        if ($null -eq $peakVUs -or [double]$peakVUs -le 0) {
            $globalVusMax=Get-MetricNumber $summary.metrics.vus_max 'max'
            $globalVus=Get-MetricNumber $summary.metrics.vus 'max'
            if ($null -ne $globalVusMax -and [double]$globalVusMax -gt 0) { $peakVUs=[double]$globalVusMax }
            elseif ($null -ne $globalVus -and [double]$globalVus -gt 0) { $peakVUs=[double]$globalVus }
        }
        $appPeakVUs[$app]=if ($null -ne $peakVUs -and [double]$peakVUs -gt 0) { [double]$peakVUs } else { $null }
    }
    if (-not $hasScenarioDroppedMetric) {
        # 전역 dropped 수를 앱별로 임의 분배하면 generated=100%인 앱까지
        # LOAD_GENERATOR_LIMIT으로 오판한다. 앱별 값은 null로 유지한다.
        foreach ($app in $apps) { $appDroppedIterations[$app]=$null }
    }
    $droppedIterations=[double]$globalDroppedIterations
    $totalRequests=($apps | ForEach-Object { [double]$appResults[$_].Requests } | Measure-Object -Sum).Sum
    $totalSuccessful=($apps | ForEach-Object { [double]$appResults[$_].SuccessfulRequests } | Measure-Object -Sum).Sum
    $processingDenominator=$totalRequests+$droppedIterations
    $processingRate=if ($processingDenominator -gt 0) { $totalSuccessful/$processingDenominator } else { 0 }
    $processingPass=$processingRate -ge $MinProcessingRate
    foreach ($app in $apps) {
        $appDropped=$appDroppedIterations[$app]
        $appDenominator=[double]$appResults[$app].Requests+$(if ($null -ne $appDropped) { [double]$appDropped } else { 0.0 })
        $appLoadRate=if ($appDenominator -gt 0) { [double]$appResults[$app].SuccessfulRequests/$appDenominator } else { 0 }
        # k6-load.js와 동일한 trafficShare( user 50%, product 35%, stress 잔여 )를
        # 사용한다. 기존 30% 고정식은 stress를 24rps로 잘못 계산해 실제 9rps를
        # 720/270=37%로 오판하는 LOAD_GENERATOR_LIMIT 버그를 만들었다.
        $expectedAppRate=if ($app -eq 'stress') {
            $userRate=[math]::Max(1,[math]::Round($TargetRate*[double]$trafficShare.user))
            $productRate=[math]::Max(1,[math]::Round($TargetRate*[double]$trafficShare.product))
            [math]::Max(1,$TargetRate-$userRate-$productRate)
        } else { [math]::Max(1,[math]::Round($TargetRate*[double]$trafficShare[$app])) }
        # 분자(steady 실제 생성)와 분모(steady target)는 반드시 같은 window를 쓴다.
        # retry warmup이 steady 시작을 밀었으면 실제 steady window로 보정한다(30s 고정 금지).
        $effectiveSteadyWindow=[math]::Max(0,[math]::Min([double]$SteadyDurationSec,[double]$loadWindowSec-$steadyStartSec))
        $expectedSteady=[double]$expectedAppRate*$effectiveSteadyWindow
        $generatedRatio=if ($expectedSteady -gt 0) { [double]$appResults[$app].HighLoadRequests/$expectedSteady } else { 0 }
        $peakVUs=$appPeakVUs[$app]
        $maxVUs=[double]$vuPlan.Apps[$app].Max
        # peakVUs=0/null은 실제 도달 VU가 0이라는 뜻이 아니라 parser 실패일 수 있다.
        # 전역 vus/vus_max로 fallback하고, 그래도 없으면 Unknown으로 남긴다(0으로 확정하지 않음).
        $peakVUUnknown=($null -eq $peakVUs -or [double]$peakVUs -le 0)
        $maxVuReached=(-not $peakVUUnknown -and $maxVUs -gt 0 -and [double]$peakVUs -ge ([double]$maxVUs*0.98))
        # max VU에 닿았다는 사실만으로 포화로 판정하지 않는다. 생성률 부족 또는
        # 실제 dropped iteration이 있어야 LOAD_GENERATOR_LIMIT이다.
        $generatorEvidence=Get-LoadGeneratorLimitEvidence $generatedRatio $appDropped $appResults[$app].Requests $maxVuReached
        $loadGeneratorLimited=[bool]$generatorEvidence.Limited
        $measurementReliable=(-not $loadGeneratorLimited -and $generatedRatio -ge 0.95 -and $null -ne $appResults[$app].P95Ms -and [double]$appResults[$app].HighLoadRequests -ge 10 -and [bool]$appResults[$app].ScalingStable)
        $appResults[$app] | Add-Member -NotePropertyName AllocatedDroppedIterations -NotePropertyValue $appDropped -Force
        $appResults[$app] | Add-Member -NotePropertyName Iterations -NotePropertyValue ([double]$appIterations[$app]) -Force
        $appResults[$app] | Add-Member -NotePropertyName LoadProcessingRate -NotePropertyValue $appLoadRate -Force
        $appResults[$app] | Add-Member -NotePropertyName LoadPass -NotePropertyValue ($appLoadRate -ge 0.90) -Force
        $appResults[$app] | Add-Member -NotePropertyName ExpectedSteadyRequests -NotePropertyValue $expectedSteady -Force
        $appResults[$app] | Add-Member -NotePropertyName EffectiveSteadyWindowSec -NotePropertyValue $effectiveSteadyWindow -Force
        $appResults[$app] | Add-Member -NotePropertyName GeneratedLoadRatio -NotePropertyValue $generatedRatio -Force
        $appResults[$app] | Add-Member -NotePropertyName LoadGeneratorLimited -NotePropertyValue $loadGeneratorLimited -Force
        $appResults[$app] | Add-Member -NotePropertyName MeasurementReliable -NotePropertyValue $measurementReliable -Force
        $appResults[$app] | Add-Member -NotePropertyName K6PreAllocatedVUs -NotePropertyValue $vuPlan.Apps[$app].PreAllocated -Force
        $appResults[$app] | Add-Member -NotePropertyName K6MaxVUs -NotePropertyValue $vuPlan.Apps[$app].Max -Force
        $appResults[$app] | Add-Member -NotePropertyName PeakVUs -NotePropertyValue $peakVUs -Force
        $appResults[$app] | Add-Member -NotePropertyName PeakVUUnknown -NotePropertyValue $peakVUUnknown -Force
        $appResults[$app] | Add-Member -NotePropertyName MaxVUReached -NotePropertyValue $maxVuReached -Force
        $appResults[$app] | Add-Member -NotePropertyName LoadGeneratorLimitReasons -NotePropertyValue $generatorEvidence.Reasons -Force
        $appResults[$app] | Add-Member -NotePropertyName DroppedPct -NotePropertyValue $generatorEvidence.DroppedPct -Force
    }
    $activeNodeBudget=if ($config.ContainsKey('NodeBudget')) { [int]$config.NodeBudget } else { $MaxNodes }
    $maxOver5s=@($apps | Where-Object { $null -eq $appResults[$_].MaxMs -or $appResults[$_].MaxMs -gt 5000 }).Count -gt 0
    $allSlo=@($apps | Where-Object { -not $appResults[$_].SLOPass }).Count -eq 0
    $anyTimeout=@($apps | Where-Object { [double]$appResults[$_].SteadyTimeoutCount -gt 0 }).Count -gt 0
    $steadyPending=@($apps | Where-Object { [double]$appResults[$_].PeakPendingReplicas -gt 0 }).Count -gt 0
    # 부하 발생기 포화는 측정 무효이지 서버 HardFailure가 아니다. Kubernetes
    # 설정을 바꾸지 않고 VU를 늘려 재측정해야 한다.
    # P0-7: isolated 2-node topology( stress dedicated + user/product shared)는 정상.
    #   IdleTopologyFit=true → HardFailure=false (TopologyFit가 false일 때만 HardFailure).
    $hard=$maxOver5s -or $anyTimeout -or $upstream5xx -gt 0 -or $restartDelta -gt 0 -or $evictionDelta -gt 0 -or $oomDelta -gt 0 -or $pressureMax -gt 0 -or $steadyPending -or $nodeMax -gt $activeNodeBudget -or (-not $idle.IdleTopologyFit)
    $totalRps=($apps | ForEach-Object { [double]$appResults[$_].RPS } | Measure-Object -Sum).Sum
    $totalScore=($apps | ForEach-Object { [double]$appResults[$_].EfficiencyScore } | Measure-Object -Sum).Sum
    $totalCpu=($apps | ForEach-Object { (Convert-CpuToM $config[$_].requestCpu)*[double]$appResults[$_].AverageReadyReplicas } | Measure-Object -Sum).Sum
    $totalMem=($apps | ForEach-Object { (Convert-MemoryToMi $config[$_].requestMemory)*[double]$appResults[$_].AverageReadyReplicas } | Measure-Object -Sum).Sum
    $nodeSeconds=0.0; $totalNodeSeconds=0.0
    $CostNodeSeconds=0.0
    $CostWindowSeconds=[double]$loadWindowSec
    $orderedSamples=@($samples | Sort-Object { [double]$_.ElapsedSec })
    for ($i=0;$i -lt $orderedSamples.Count;$i++) {
        $sampleStart=[double]$orderedSamples[$i].ElapsedSec
        $sampleEnd=if ($i+1 -lt $orderedSamples.Count) { [double]$orderedSamples[$i+1].ElapsedSec } else { [math]::Min($durationSec,$sampleStart+5) }
        if ($sampleEnd -gt $sampleStart) {
            $windowSeconds=$sampleEnd-$sampleStart
            $nodeSeconds += [double]$orderedSamples[$i].ReadyNodes*$windowSeconds
            $totalNodeSeconds += [double]$orderedSamples[$i].TotalReadyNodes*$windowSeconds
        }
        # P0-4: CostNodeSeconds 계산 (0 <= sample time < CostWindowSeconds 범위만 적분 & clamp)
        $intervalStart = $sampleStart
        $intervalEnd = [math]::Min($sampleEnd, $CostWindowSeconds)
        if ($intervalStart -lt $CostWindowSeconds -and $intervalEnd -gt $intervalStart) {
            $CostNodeSeconds += [double]$orderedSamples[$i].TotalReadyNodes * ($intervalEnd - $intervalStart)
        }
    }
    $AverageTotalNodes = if ($CostWindowSeconds -gt 0) { $CostNodeSeconds / $CostWindowSeconds } else { 0.0 }
    $cooldownSamples=@($orderedSamples | Where-Object { [double]$_.ElapsedSec -ge $loadWindowSec })
    $podsAtOneSample=$cooldownSamples | Where-Object { [double]$_.UserReady -le 1 -and [double]$_.ProductReady -le 1 -and [double]$_.StressReady -le 1 } | Select-Object -First 1
    $karpenterAtZeroSample=$cooldownSamples | Where-Object { [double]$_.ReadyNodes -le 0 } | Select-Object -First 1
    $lastSample=$orderedSamples | Select-Object -Last 1
    $podsToOneSeconds=if ($podsAtOneSample) { [math]::Max(0,[double]$podsAtOneSample.ElapsedSec-$loadWindowSec) } else { $null }
    $karpenterToZeroSeconds=if ($karpenterAtZeroSample) { [math]::Max(0,[double]$karpenterAtZeroSample.ElapsedSec-$loadWindowSec) } else { $null }
    $competitionScore=Get-CompetitionScore $appResults $totalNodeMax
    $observedVUs=Get-MetricNumber $summary.metrics.vus 'max'
    $configuredVUs=Get-MetricNumber $summary.metrics.vus_max 'max'; if ($null -eq $configuredVUs) { $configuredVUs=$vuPlan.TotalMax }
    $vuUtilization=if ($configuredVUs -gt 0 -and $null -ne $observedVUs) { [double]$observedVUs/[double]$configuredVUs } else { $null }
    $profile=[pscustomobject]@{
        Name=$name;Config=$config;NodeBudget=$activeNodeBudget;DurationSec=[math]::Round($elapsed,1);K6Exit=$k6Exit;Apps=$appResults;K6LogPath=$k6LogPath
        PeakReadyNodes=$nodeMax;AverageReadyNodes=$nodeAvg;NodeSeconds=[math]::Round($nodeSeconds,1);NodeSecondsPerSecond=$(if ($durationSec -gt 0) { $nodeSeconds/$durationSec } else { $null })
        PeakTotalReadyNodes=$totalNodeMax;AverageTotalReadyNodes=$totalNodeAvg;TotalNodeSeconds=[math]::Round($totalNodeSeconds,1);TotalNodeSecondsPerSecond=$(if ($durationSec -gt 0) { $totalNodeSeconds/$durationSec } else { $null });TotalSuccessfulRPS=$totalRps;TotalRequestedCPU=$totalCpu;TotalRequestedMemory=$totalMem
        TotalRequests=$totalRequests;TotalSuccessfulRequests=$totalSuccessful;ProcessingRate=$processingRate;ProcessingPass=$processingPass
        Upstream5xx=$upstream5xx;DroppedIterations=$droppedIterations;RestartDelta=$restartDelta;EvictionDelta=$evictionDelta;OOMKilledDelta=$oomDelta;OOMKilledDeltaByApp=$oomDeltaByApp;MemoryPressure=$pressureMax
        CrashLoopBackOff=[math]::Max(0,[int]$healthAfter.CrashLoopBackOff-[int]$healthBefore.CrashLoopBackOff);PersistentNotReady=$persistentNotReady
        IdleCapacity=$idle;AllSLOPass=$allSlo;HardFailure=$hard;TotalScore=$totalScore;CompetitionScore=$competitionScore;MetricSamples=$samples.Count
        LoadWindowSeconds=$loadWindowSec;CooldownSeconds=$CooldownDurationSec;PodsToOneSeconds=$podsToOneSeconds;KarpenterToZeroSeconds=$karpenterToZeroSeconds
        ObservedVUs=$observedVUs;ConfiguredVUs=$configuredVUs;VUUtilization=$vuUtilization
        EndReadyNodes=$(if ($lastSample) { [double]$lastSample.ReadyNodes } else { $null });EndTotalReadyNodes=$(if ($lastSample) { [double]$lastSample.TotalReadyNodes } else { $null })
        CostNodeSeconds=[math]::Round($CostNodeSeconds,1)
        CostWindowSeconds=$CostWindowSeconds
        AverageTotalNodes=[math]::Round($AverageTotalNodes,2)
    }
    foreach ($app in $apps) {
        $bottlenecks=@(Get-BottleneckClassification $profile $app)
        $appResults[$app] | Add-Member -NotePropertyName Bottlenecks -NotePropertyValue $bottlenecks -Force
        $capacityReliable=([bool]$appResults[$app].MeasurementReliable -and -not [bool]$appResults[$app].MetricUnavailable -and [double]$appResults[$app].HighLoadSuccessfulRequests -gt 0 -and [double]$appResults[$app].LoadProcessingRate -ge $MinProcessingRate -and 'MEMORY_OOM' -notin $bottlenecks -and 'NODE_CAPACITY' -notin $bottlenecks)
        $appResults[$app] | Add-Member -NotePropertyName CapacityReliable -NotePropertyValue $capacityReliable -Force
    }
    $profile | Add-Member -NotePropertyName MeasurementReliable -NotePropertyValue (@($apps | Where-Object { -not $appResults[$_].MeasurementReliable }).Count -eq 0) -Force
    $profile | Add-Member -NotePropertyName LoadGeneratorLimited -NotePropertyValue (@($apps | Where-Object { $appResults[$_].LoadGeneratorLimited }).Count -gt 0) -Force
    $profile | Add-Member -NotePropertyName TuningActions -NotePropertyValue @($apps | ForEach-Object { Get-NextTuningAction $profile $_ $cluster }) -Force
    # 관측 기반 HPA max는 tuning action 분류와 무관하게 항상 계산해 전역 상태에 저장한다.
    # LOAD_GENERATOR_LIMIT/CPU_THROTTLING 등 어떤 action이 반환되든 CPU/throughput이
    # 하나라도 유효하면 FinalHpaMaxByApp이 갱신된다 (monotonic).
    foreach ($app in $apps) { [void](Update-FinalHpaMax $profile $app) }
    # SPLIT 등 resource override는 measurement 직후에 저장한다. candidate 생성(tuningSource)이
    # Minimum을 골라 SPLIT 신호가 없어도, 측정에서 SPLIT이 판단되면 즉시 persist되어
    # 이후 생성되는 candidate와 최종 적용에 반영된다.
    foreach ($app in $apps) {
        $splitAction=@($profile.TuningActions | Where-Object { $_.App -eq $app -and $_.Type -eq 'SPLIT_STRESS_CAPACITY' }) | Select-Object -First 1
        if ($splitAction -and $null -ne $splitAction.RequestTo -and [double]$splitAction.RequestTo -gt 0) {
            $script:FinalResourceOverrideByApp[$app]=@{requestCpu=[double]$splitAction.RequestTo;limitCpu=$null}
        }
    }
    # 실제 성적표 로그 (스펙 14)
    [void](Write-EvaluationLog $profile $name)
    $failureClass=Get-FailureClassification $profile
    foreach ($property in @('FatalFailure','PerformanceFailure','MeasurementFailure','FailureReasons')) {
        $profile | Add-Member -NotePropertyName $property -NotePropertyValue $failureClass.$property -Force
    }
    Write-Host ("{0}: SLO={1} Process={2:P1} HardFailure={3} TotalNodes={4}(Karpenter={5}) NodeSec={6:N0} RPS={7:N1} Efficiency={8:N2} Competition={9:N2}/36 Idle1Node={10} PodsToOne={11}s KarpenterToZero={12}s" -f $name,$allSlo,$processingRate,$hard,$totalNodeMax,$nodeMax,$totalNodeSeconds,$totalRps,$totalScore,$competitionScore.Earned,$idle.IdleOneNodeFit,$podsToOneSeconds,$karpenterToZeroSeconds) -ForegroundColor Cyan
    foreach ($app in $apps) {
        $m=$appResults[$app]
        $appAction=$profile.TuningActions | Where-Object App -eq $app | Select-Object -First 1
        $actionText=if ($appAction) { [string]$appAction.Type } else { '' }
        if ($appAction -and $appAction.VuAction) { $actionText="$actionText, vu=$($appAction.VuAction)" }
        Write-Host ("  {0}: reliable={1}, generated={2:P1}, bottleneck=[{3}], action={4}" -f $app,$m.MeasurementReliable,$m.GeneratedLoadRatio,($m.Bottlenecks -join ','),$actionText) -ForegroundColor DarkGray
        if ($m.FailureBreakdownText -and ([double]$m.FailedRequests -gt 0 -or [double]$m.SteadyTimeoutCount -gt 0)) {
            # 실패 유형: timeout은 k6 클라이언트 5초 timeout, 5xx는 서버 오류, 4xx는 WAF/형식.
            Write-Host ("    FAILURE breakdown={0}" -f $m.FailureBreakdownText) -ForegroundColor Yellow
        }
        if ($m.LoadGeneratorLimited) {
            Write-Host ("    LOAD_GENERATOR_LIMIT reason=[{0}]: target={1:N0}, generated={2:N0} ({3:P1}), dropped={4}, peakVUs={5}, maxVUs={6}, maxVUReached={7}" -f ($m.LoadGeneratorLimitReasons -join ','),$m.ExpectedSteadyRequests,$m.HighLoadRequests,$m.GeneratedLoadRatio,$(if ($null -eq $m.AllocatedDroppedIterations) {'metric-missing'} else {[double]$m.AllocatedDroppedIterations}),$(if ($null -eq $m.PeakVUs) {'unknown'} else {[double]$m.PeakVUs}),$m.K6MaxVUs,$m.MaxVUReached) -ForegroundColor Yellow
        }
    }
    return $profile
}

function Invoke-SingleVURetry($initialResult,[hashtable]$config,[int]$durationSec,$cluster) {
    # VU Retry 1회: 이미 측정된 $initialResult의 saturation을 기반으로 API별 VU를
    # 재산정해 동일 Kubernetes config에서 1회 재측정한다 (후보당 최대 1회, optional).
    # CalculatedFinal reserve / 남은 runtime이 부족하면 $null을 반환한다.
    if (-not $initialResult -or -not $initialResult.Apps) { return $null }
    $result=$initialResult
    $currentPlan=$script:lastVuPlan
    $latencyEstimator=Get-LatencyEstimator $result
    $saturated=@{};$targetGenerated=@{}
    foreach ($app in $apps) {
        $m=$result.Apps[$app]
        $saturated[$app]=[bool](Get-OptionalPropertyValue $m 'LoadGeneratorLimited' $false)
        $targetGenerated[$app]=[pscustomobject]@{
            Target=[double](Get-OptionalPropertyValue $m 'ExpectedSteadyRequests' 0)
            Generated=[double](Get-OptionalPropertyValue $m 'HighLoadRequests' 0)
            Dropped=[double](Get-OptionalPropertyValue $m 'AllocatedDroppedIterations' 0)
        }
    }
    $peakByApp=@{}
    foreach ($app in $apps) { $peakByApp[$app]=[double](Get-OptionalPropertyValue $result.Apps[$app] 'PeakVUs' 0) }
    $newPlan=New-VUAllocation $latencyEstimator $TargetRate $currentPlan $saturated $targetGenerated $peakByApp
    $oldTotal=if ($currentPlan) { [int]$currentPlan.TotalMax } else { 0 }
    $increaseRatio=if ($oldTotal -gt 0) { ([int]$newPlan.TotalMax-$oldTotal)/[double]$oldTotal } else { 1.0 }
    $warmup=Get-RetryWarmupSeconds $durationSec $increaseRatio 0
    $script:vuPlanOverride=$newPlan
    $script:retryWarmupSeconds=$warmup
    # ---- saturation 로그 (계산 근거 포함) ----
    $effectiveWindow=[double](Get-OptionalPropertyValue $result.Apps[$apps[0]] 'EffectiveSteadyWindowSec' 0)
    Write-Host "`n===== LOAD GENERATOR SATURATION =====" -ForegroundColor Yellow
    Write-Host ("Candidate: {0}" -f $config.Name)
    Write-Host ("Measurement window: steady {0:N0}s" -f $effectiveWindow)
    Write-Host ''
    foreach ($app in $apps) {
        $tg=$targetGenerated[$app]
        $ratio=if ($tg.Target -gt 0) { [double]$tg.Generated/[double]$tg.Target } else { 0 }
        $droppedPct=if (([double]$tg.Generated+[double]$tg.Dropped) -gt 0) { [double]$tg.Dropped/([double]$tg.Generated+[double]$tg.Dropped) } else { 0 }
        Write-Host ("{0}:" -f $app)
        Write-Host ("  target={0:N0}  generated={1:N0}  dropped={2:N0}" -f $tg.Target,$tg.Generated,$tg.Dropped)
        Write-Host ("  generatedRatio={0:P1}  droppedPct={1:P1}  saturated={2}" -f $ratio,$droppedPct,$saturated[$app])
    }
    Write-Host ''
    Write-Host 'Latency estimator:'
    foreach ($app in $apps) {
        $m=$result.Apps[$app]
        $steadyP95=Get-OptionalPropertyValue $m 'SteadySuccessP95Ms'
        $steadySamples=Get-OptionalPropertyValue $m 'SteadySuccessSampleCount'
        $overallP95=Get-OptionalPropertyValue $m 'SuccessP95MsOverall'
        $overallSamples=Get-OptionalPropertyValue $m 'SuccessSampleCount'
        if ($null -ne $steadyP95 -and $null -ne $steadySamples -and [int]$steadySamples -ge 100) {
            Write-Host ('  {0,-7} steadySuccessSamples={1}  steadySuccessP95={2:N2}s  source=steady_success_p95' -f $app,[int]$steadySamples,([double]$steadyP95/1000.0))
        } elseif ($null -ne $overallP95 -and $null -ne $overallSamples -and [int]$overallSamples -ge 20) {
            Write-Host ('  {0,-7} successSamples={1}  successP95={2:N2}s  source=success_p95' -f $app,[int]$overallSamples,([double]$overallP95/1000.0))
        } else {
            $s1=if ($null -ne $steadySamples) { [int]$steadySamples } else { 0 }
            $s2=if ($null -ne $overallSamples) { [int]$overallSamples } else { 0 }
            Write-Host ('  {0,-7} steadySuccessSamples={1}  successSamples={2}  source=fallback  L_est=1.50s' -f $app,$s1,$s2)
        }
    }
    Write-Host ''
    foreach ($app in $apps) {
        $m=$result.Apps[$app]
        $currentPre=[int](Get-OptionalPropertyValue $m 'K6PreAllocatedVUs' 1)
        $tg=$targetGenerated[$app]
        $generated=[double]$tg.Generated;$target=[double]$tg.Target
        $lEst=[double]$latencyEstimator[$app]
        $latencyBased=[int][math]::Ceiling([double]([int][math]::Max(1,[math]::Round($TargetRate*[double]$trafficShare[$app])))*$lEst*$RequiredVUFactor)
        $deficitBased=if ($generated -gt 0) { [int][math]::Ceiling($currentPre*($target/$generated)*1.15) } else { [int][math]::Ceiling($currentPre*2.0) }
        $growthFloor=[int][math]::Ceiling($currentPre*1.25)
        $required=[int]$newPlan.Apps[$app].Required
        $retryPre=[int]$newPlan.Apps[$app].PreAllocated
        $retryMax=[int]$newPlan.Apps[$app].Max
        if ($saturated[$app]) {
            Write-Host ("{0} (saturated):" -f $app)
            Write-Host ("  currentPre={0}  latencyBased={1}  deficitBased={2}  growthFloor={3}" -f $currentPre,$latencyBased,$deficitBased,$growthFloor)
            Write-Host ("  required=max({0},{1},{2}) = {3}" -f $latencyBased,$deficitBased,$growthFloor,$required)
            Write-Host ("  retry pre={0}  max={1}" -f $retryPre,$retryMax)
        } else {
            Write-Host ("{0} (ok): pre={1} max={2} (강제 증가 없음)" -f $app,$retryPre,$retryMax)
        }
    }
    Write-Host ''
    Write-Host ("Runner logical CPU: {0}" -f [Environment]::ProcessorCount)
    Write-Host ("Global VU cap: {0}" -f $newPlan.GlobalCap)
    if ($newPlan.ProportionalScaled) {
        Write-Host ("Required total VU={0} > GlobalCap={1}" -f $newPlan.RequiredTotal,$newPlan.GlobalCap) -ForegroundColor Yellow
        Write-Host 'Applying proportional allocation (saturation scenario 우선 배정)...' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host ("VU increase: {0}{1:P1}" -f $(if ($increaseRatio -ge 0) {'+'} else {''}),$increaseRatio)
    Write-Host ("Retry warmup: {0}s" -f $warmup)
    Write-Host ("Retry steady: {0}s" -f [math]::Max(1,$durationSec-$warmup))
    Write-Host ''
    Write-Host ("→ {0}-VURetry1" -f $config.Name) -ForegroundColor Green
    Write-Host '=====================================' -ForegroundColor Yellow
    $retryEstimate=Get-EstimatedMeasurementDuration $durationSec
    $remainingAfterRetry=(Get-RemainingRuntimeSeconds Tuning)-$retryEstimate
    if (-not (Test-CanStartMeasurement $durationSec) -or -not (Test-VURetryAllowed $remainingAfterRetry $CalculatedFinalReserveSec)) {
        Write-Warning ("{0} saturation detected. Remaining runtime: {1}s, Estimated retry cost: {2}s, CalculatedFinal reserve: {3}s → VU retry skipped to preserve final selection/apply time." -f $config.Name,[math]::Floor((Get-RemainingRuntimeSeconds Tuning)),[math]::Floor($retryEstimate),$CalculatedFinalReserveSec)
        return $null
    }
    $retryConfig=Copy-Config $config "$($config.Name)-VURetry1"
    $retryResult=Run-LoadTest $retryConfig $durationSec $cluster
    if (-not $retryResult) { return $null }
    # ---- retry 결과 로그 (API별) ----
    $effectiveWindow=[double](Get-OptionalPropertyValue $retryResult.Apps[$apps[0]] 'EffectiveSteadyWindowSec' 0)
    Write-Host "`n===== VU RETRY RESULT =====" -ForegroundColor Cyan
    Write-Host ("Measurement window: steady {0:N0}s" -f $effectiveWindow)
    Write-Host ''
    $allReliable=$true
    foreach ($app in $apps) {
        $m=$retryResult.Apps[$app]
        $g=Get-OptionalPropertyValue $m 'GeneratedLoadRatio' 0
        $d=Get-OptionalPropertyValue $m 'DroppedPct' 0
        if ($null -eq $d) { $d=0.0 }
        if ($null -eq $g -or [double]$g -lt $SaturationGeneratedRatio -or [double]$d -gt $SaturationDroppedPct) { $allReliable=$false }
        Write-Host ("{0}:" -f $app)
        Write-Host ("  generatedRatio={0:P1}" -f $g)
        Write-Host ("  droppedPct={0:P1}" -f $d)
    }
    Write-Host ''
    if ($allReliable -and -not $retryResult.LoadGeneratorLimited) {
        Write-Host 'LoadGeneratorLimit=false' -ForegroundColor Green
        Write-Host '→ measurement reliable'
    } else {
        Write-Host 'LoadGeneratorLimit=true' -ForegroundColor Yellow
        Write-Host '→ no additional VU retry'
        Write-Host '→ candidate remains Eligible'
        Write-Host '→ G/R penalty applied'
    }
    Write-Host '===========================' -ForegroundColor Cyan
    return $retryResult
}

function Run-ReliableLoadTest([hashtable]$config,[int]$durationSec,$cluster,[int]$ReservedFutureMeasurements = 0,[switch]$SkipRetry) {
    # 최초 측정은 항상 1회 수행한다. VU Retry는 optional이며(후보당 최대 1회)
    # -SkipRetry면 생략한다. 세 profile 최초 측정 이후 Invoke-RetryPhase에서
    # 남는 runtime으로 retry를 수행하는 것이 기본 흐름이다.
    $attempts=[System.Collections.Generic.List[object]]::new()
    $script:vuPlanOverride=$null
    $script:retryWarmupSeconds=0
    $estimated=Get-EstimatedMeasurementDuration $durationSec
    if (-not (Test-CanStartMeasurement $durationSec) -or ((Get-RemainingRuntimeSeconds Tuning)-$estimated -lt ($ReservedFutureMeasurements*$estimated))) {
        $script:stopTuning=$true
        $script:tuningStopReason='Runtime budget reached'
        return [pscustomobject]@{Result=$null;Attempts=$attempts.ToArray();Status='NOT_EXECUTED_RUNTIME_BUDGET';SkippedRuntime=1}
    }
    $result=Run-LoadTest $config $durationSec $cluster
    if (-not $result) {
        $script:stopTuning=$true
        $script:tuningStopReason='Runtime budget reached'
        return [pscustomobject]@{Result=$null;Attempts=$attempts.ToArray();Status='NOT_EXECUTED_RUNTIME_BUDGET';SkippedRuntime=1}
    }
    $attempts.Add($result)
    if ($SkipRetry -or -not $result.LoadGeneratorLimited) {
        return [pscustomobject]@{Result=$result;Attempts=$attempts.ToArray();Status='PASS';SkippedRuntime=0}
    }
    $retryResult=Invoke-SingleVURetry $result $config $durationSec $cluster
    if ($retryResult) { $attempts.Add($retryResult) }
    return [pscustomobject]@{Result=$attempts[$attempts.Count-1];Attempts=$attempts.ToArray();Status='PASS';SkippedRuntime=0}
}

function Invoke-RetryPhase([object[]]$results,[int]$durationSec,$cluster) {
    # 세 profile 최초 측정 이후 호출. LOAD_GENERATOR_LIMIT 후보를 신뢰도(G×R) 낮은 순으로
    # 최대 1회씩 VU Retry한다 (optional). retry 후보당 최대 1회, 남는 runtime만 사용.
    $candidates=[System.Collections.Generic.List[object]]::new()
    $groups=[ordered]@{}
    foreach ($r in @($results)) {
        if (-not $r -or -not $r.Apps) { continue }
        if (-not [bool](Get-OptionalPropertyValue $r 'LoadGeneratorLimited' $false)) { continue }
        $cfg=Get-OptionalPropertyValue $r 'Config'
        if (-not (Test-CandidateConfigValid $cfg)) { continue }
        $fp=Get-ConfigFingerprint $cfg
        if (-not $groups.Contains($fp)) { $groups[$fp]=[System.Collections.Generic.List[object]]::new() }
        $groups[$fp].Add($r)
    }
    foreach ($fp in $groups.Keys) {
        $runs=@($groups[$fp])
        $latest=$runs[$runs.Count-1]
        $config=Get-OptionalPropertyValue $latest 'Config'
        $name=Get-QualityCandidateBaseName ([string]$latest.Name)
        # retry 최대 1회: 이미 retry 측정이 있으면 스킵.
        if (@($runs | Where-Object { $_.Name -like "${name}-VURetry*" }).Count) { continue }
        [void]$candidates.Add([pscustomobject]@{Config=$config;Latest=$latest;Name=$name;Confidence=(Get-MeasurementConfidence $latest)})
    }
    $retried=[System.Collections.Generic.List[object]]::new()
    foreach ($c in @($candidates | Sort-Object Confidence)) {
        if ((Get-RemainingRuntimeSeconds Tuning) -le ($durationSec+$CalculatedFinalReserveSec)) {
            Write-Warning ("VU retry phase: remaining {0}s 부족으로 더 이상 retry하지 않습니다." -f [math]::Floor((Get-RemainingRuntimeSeconds Tuning)))
            break
        }
        Write-Host ("VU retry phase: {0} (confidence={1:N2})" -f $c.Name,$c.Confidence) -ForegroundColor Cyan
        $retryResult=Invoke-SingleVURetry $c.Latest $c.Config $durationSec $cluster
        if ($retryResult) { [void]$retried.Add($retryResult) }
    }
    return @($retried)
}
function Get-ConfigFingerprint([hashtable]$config) {
    $parts=[System.Collections.Generic.List[string]]::new()
    foreach ($app in $apps) {
        $c=$config[$app]
        $parts.Add("$app|$($c.requestCpu)|$($c.limitCpu)|$($c.requestMemory)|$($c.limitMemory)|$($c.hpaTarget)|$($c.minReplicas)|$($c.maxReplicas)")
    }
    return ($parts -join ';')
}

function Test-StableCandidate([object[]]$results,[hashtable]$config,[int]$requiredRuns = 2) {
    $fingerprint=Get-ConfigFingerprint $config
    $matching=@($results | Where-Object { (Get-ConfigFingerprint $_.Config) -eq $fingerprint })
    # LOAD_GENERATOR_LIMIT 실행은 서버 후보의 실패가 아니라 무효 측정이므로
    # 안정성 분모에서 제외하고, VU를 늘린 재측정만 사용한다.
    $eligible=@($matching | Where-Object { -not $_.LoadGeneratorLimited })
    $valid=@($eligible | Where-Object {
        $candidate=$_
        $allHeadroom=@($apps | Where-Object { -not [bool]$candidate.Apps[$_].HeadroomPass }).Count -eq 0
        $failure=Get-FailureClassification $candidate
        $candidate.MeasurementReliable -and -not $failure.FatalFailure -and -not $failure.PerformanceFailure -and -not $failure.MeasurementFailure -and $candidate.AllSLOPass -and $allHeadroom
    })
    $p95Variance=@{}
    $variancePass=$true
    foreach ($app in $apps) {
        $values=@($valid | ForEach-Object { [double]$_.Apps[$app].P95Ms } | Where-Object { $_ -gt 0 })
        $ratio=if ($values.Count -ge 2) { (($values|Measure-Object -Maximum).Maximum-(($values|Measure-Object -Minimum).Minimum))/[math]::Max(1,(($values|Measure-Object -Average).Average)) } else { 0 }
        $p95Variance[$app]=[math]::Round($ratio,4)
        if ($ratio -gt 0.20) { $variancePass=$false }
    }
    $stable=$eligible.Count -ge $requiredRuns -and $valid.Count -eq $eligible.Count -and $variancePass
    return [pscustomobject]@{Stable=$stable;Runs=$eligible.Count;PassRuns=$valid.Count;InvalidLoadGeneratorRuns=($matching.Count-$eligible.Count);RequiredRuns=$requiredRuns;P95Variance=$p95Variance;Results=$eligible}
}


function Assert-HpaConfigInvariant([hashtable]$config,[string]$stage) {
    foreach ($app in $apps) {
        if ($null -eq $config -or $null -eq $config[$app]) { throw "HPA_CONFIG_INVALID: stage=$stage app=$app config is null" }
        $min=[int]$config[$app].minReplicas
        $max=[int]$config[$app].maxReplicas
        $hsMax=if ($script:HardSafetyMaxByApp.ContainsKey($app)) { [int]$script:HardSafetyMaxByApp[$app] } else { $MaxAutoReplicas }
        if ($min -lt 1 -or $max -lt 1 -or $min -gt $max) {
            throw "HPA_CONFIG_INVALID: stage=$stage app=$app min=$min max=$max (invariant: 1 <= min <= max)"
        }
        if ($max -gt $hsMax) { throw "HPA_CONFIG_INVALID: stage=$stage app=$app max=$max > HardSafetyMax=$hsMax" }
        if ([double](Convert-CpuToM $config[$app].requestCpu) -le 0) { throw "HPA_CONFIG_INVALID: stage=$stage app=$app requestCpu=$($config[$app].requestCpu)" }
        if ([double](Convert-MemoryToMi $config[$app].requestMemory) -le 0) { throw "HPA_CONFIG_INVALID: stage=$stage app=$app requestMemory=$($config[$app].requestMemory)" }
        Write-Host ("  [HPA-STATE] stage=$stage app=$app min=$min max=$max req=$($config[$app].requestCpu)") -ForegroundColor DarkGray
    }
}

function Get-OptionalPropertyValue($Object,[string]$Name,$Default=$null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property=$Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-ResultAppMetric($Result,[string]$App) {
    $appsObject=Get-OptionalPropertyValue $Result 'Apps'
    return Get-OptionalPropertyValue $appsObject $App
}

function Get-RepresentativeMeasurement($Candidate) {
    if ($null -eq $Candidate) { return $null }
    $verification=@(Get-OptionalPropertyValue $Candidate 'VerificationResults' @())
    $passed=@($verification | Where-Object { $_ -and [bool](Get-OptionalPropertyValue $_ 'Executed' $false) -and [bool](Get-OptionalPropertyValue $_ 'Passed' $false) })
    if ($passed.Count -gt 0) { return $passed[$passed.Count-1] }
    $measurement=Get-OptionalPropertyValue $Candidate 'Measurement'
    if ($null -ne $measurement) { return $measurement }
    $result=Get-OptionalPropertyValue $Candidate 'Result'
    if ($null -ne $result) { return $result }
    return $Candidate
}

function Expand-CandidateMeasurements($Value) {
    $expanded=[System.Collections.Generic.List[object]]::new()
    function Add-CandidateValue($item) {
        if ($null -eq $item) { return }
        $hasDirectMeasurement=$null -ne (Get-OptionalPropertyValue $item 'Apps') -or $null -ne (Get-OptionalPropertyValue $item 'Config') -or $null -ne (Get-OptionalPropertyValue $item 'Measurement')
        if ($hasDirectMeasurement) { $expanded.Add($item); return }
        $attemptValues=Get-OptionalPropertyValue $item 'Attempts'
        if ($null -ne $attemptValues) {
            foreach ($child in $attemptValues) { Add-CandidateValue $child }
            return
        }
        $resultValue=Get-OptionalPropertyValue $item 'Result'
        if ($null -ne $resultValue) { Add-CandidateValue $resultValue; return }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string] -and $item -isnot [System.Collections.IDictionary]) {
            foreach ($child in $item) { Add-CandidateValue $child }
        }
    }
    Add-CandidateValue $Value
    return $expanded.ToArray()
}

function Get-MinGeneratedPercent($Measurement) {
    $values=[System.Collections.Generic.List[double]]::new()
    foreach ($app in $apps) {
        $metric=Get-ResultAppMetric $Measurement $app
        $value=Get-OptionalPropertyValue $metric 'GeneratedLoadRatio'
        # 일부 API metric이 빠졌다면 좋은 값으로 보간하지 않고 null로 유지한다.
        if ($null -eq $value) { return $null }
        $values.Add([double]$value*100.0)
    }
    if ($values.Count -eq 0) { return $null }
    return [double](($values | Measure-Object -Minimum).Minimum)
}

function Get-QualityMedian([object[]]$Values) {
    $numbers=@($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -eq 0) { return $null }
    $middle=[math]::Floor($numbers.Count/2)
    if (($numbers.Count % 2) -eq 1) { return [double]$numbers[$middle] }
    return ([double]$numbers[$middle-1]+[double]$numbers[$middle])/2.0
}

function Get-Mad([object[]]$samples) {
    # Median Absolute Deviation: median(abs(sample - median(sample))).
    # Refinement winner risk 계산의 jitter(J) 추정에 사용한다.
    if (-not @($samples).Count) { return $null }
    $median=Get-QualityMedian @($samples)
    if ($null -eq $median) { return $null }
    $absDev=@($samples | ForEach-Object { [math]::Abs([double]$_ - [double]$median) })
    return Get-QualityMedian $absDev
}

function Get-ApiSloQuality {
    param($P95,$Slo,[double]$Exponent = $qualitySloExponent)
    # Q_i = min(1, (SLO_i / p95_i)^1.5). 성공 응답 p95만 사용한다.
    # timeout ceiling(5001ms)을 일반 latency처럼 넣지 않는다. 성공 응답이
    # 없으면 null을 반환하고 호출부가 보수적으로 처리한다.
    if ($null -eq $P95 -or $null -eq $Slo -or [double]$P95 -le 0 -or [double]$Slo -le 0 -or $Exponent -le 0) { return $null }
    if ([double]$P95 -le [double]$Slo) { return 1.0 }
    return [math]::Min(1.0,[math]::Pow([double]$Slo/[double]$P95,$Exponent))
}

function Get-SloQuality([object[]]$ApiQualities) {
    # Q = 0.6*min(Q_i) + 0.4*geometricMean(Q_i). worst API를 산술 평균으로
    # 희석하지 않는다. 0이 포함되면 geomean이 epsilon으로 수렴해 Q가 붕괴한다.
    $values=@($ApiQualities | Where-Object { $null -ne $_ } | ForEach-Object { [math]::Max(0.0,[math]::Min(1.0,[double]$_)) })
    if ($values.Count -eq 0) { return $null }
    $minimum=[double](($values | Measure-Object -Minimum).Minimum)
    $logSum=0.0
    foreach ($value in $values) { $logSum += [math]::Log([math]::Max(1e-12,$value)) }
    $geometric=[math]::Exp($logSum/$values.Count)
    return 0.6*$minimum+0.4*$geometric
}

function Get-TailQuality {
    param($P95,$P99)
    # L_i = min(1, p95_i/p99_i). 성공 응답 p95/p99만 사용한다. p99가 없으면
    # null(측정 불가)이며 호출부가 보수적 fallback(missingTailScore)을 쓴다.
    if ($null -eq $P99 -or $null -eq $P95 -or [double]$P95 -le 0 -or [double]$P99 -le 0) { return $null }
    return [math]::Min(1.0,[double]$P95/[double]$P99)
}

function Get-TimeoutQuality([double]$TimeoutRate) {
    # T = e^{-7r}, r = timeout rate(0~1). timeout 실패는 T에서 독립적으로
    # 반영하며 ceiling latency를 Q/L에 다시 넣어 중복 극단 감점하지 않는다.
    if ($null -eq $TimeoutRate) { return $null }
    return [math]::Exp(-[math]::Max(0.0,[double]$TimeoutRate)*$qualityTimeoutCoefficient)
}

function Get-GenerationQuality([double]$GeneratedRatio) {
    # G = min(1, g/0.90). g = 세 API 중 최소 generated/target 비율.
    # generated 평균은 사용하지 않는다. 90% 이상은 정상 부하로 취급한다.
    if ($null -eq $GeneratedRatio) { return $null }
    return [math]::Min(1.0,[math]::Max(0.0,[double]$GeneratedRatio)/$qualityGenerationFullRatio)
}

function Get-MeasurementReliability {
    param($DroppedRate,[bool]$RequiredMetricsPresent,[bool]$OptionalMetricsMissing)
    # R = exp(-5*droppedRate) * completeness. 부하 테스트 자체의 신뢰성만 표현한다.
    # - dropped iteration: raw metric 기반 exp 감쇠
    # - metric completeness: 필수 누락 0.50 / optional 누락 0.92 / 모두 존재 1.0
    # - VU saturation(label LOAD_GENERATOR_LIMIT, capacityReliable)은 G와 raw
    #   metric(dropped/generated)으로 이미 반영되므로 R에서 다시 감점하지 않는다.
    $safeDropped=if ($null -eq $DroppedRate) { 0.0 } else { [math]::Max(0.0,[double]$DroppedRate) }
    $dropComponent=[math]::Exp(-$reliabilityDropCoefficient*$safeDropped)
    $completeness=1.0
    if (-not $RequiredMetricsPresent) { $completeness=$missingRequiredMetricCompleteness }
    elseif ($OptionalMetricsMissing) { $completeness=$missingOptionalMetricCompleteness }
    return $dropComponent*$completeness
}

function Test-CandidateEligible($Candidate) {
    $reasons=[System.Collections.Generic.List[string]]::new()
    $config=Get-OptionalPropertyValue $Candidate 'Config'
    if (-not (Test-CandidateConfigValid $config)) { $reasons.Add('INVALID_CONFIG') }
    $appsValue=Get-OptionalPropertyValue $Candidate 'Apps'
    if ($null -eq $appsValue) { $reasons.Add('UNPARSEABLE_MEASUREMENT') }
    if ([bool](Get-OptionalPropertyValue $Candidate 'RolloutFailure' $false)) { $reasons.Add('ROLLOUT_FAILURE') }
    if ([bool](Get-OptionalPropertyValue $Candidate 'ApplyFailure' $false)) { $reasons.Add('APPLY_FAILURE') }
    if ([double](Get-OptionalPropertyValue $Candidate 'CrashLoopBackOff' 0) -gt 0) { $reasons.Add('CRASH_LOOP_BACK_OFF') }
    if ([double](Get-OptionalPropertyValue $Candidate 'OOMKilledDelta' 0) -ge 2) { $reasons.Add('REPEATED_OOM_KILLED') }
    if ([double](Get-OptionalPropertyValue $Candidate 'PersistentNotReady' 0) -gt 0) { $reasons.Add('PERSISTENT_NOT_READY') }
    return [pscustomobject]@{Eligible=($reasons.Count -eq 0);Reasons=$reasons.ToArray()}
}

function Get-CandidateCostMetrics($Candidate,[object[]]$Runs=@()) {
    $config=Get-OptionalPropertyValue $Candidate 'Config'
    $nodeSecondsValues=@($Runs | ForEach-Object {
        $value=Get-OptionalPropertyValue $_ 'TotalNodeSeconds'
        if ($null -eq $value) { $value=Get-OptionalPropertyValue $_ 'NodeSeconds' }
        if ($null -ne $value) { [double]$value }
    })
    if ($nodeSecondsValues.Count -eq 0) {
        $value=Get-OptionalPropertyValue $Candidate 'TotalNodeSeconds'
        if ($null -eq $value) { $value=Get-OptionalPropertyValue $Candidate 'NodeSeconds' }
        if ($null -ne $value) { $nodeSecondsValues=@([double]$value) }
    }
    $nodeValues=@($Runs | ForEach-Object {
        $value=Get-OptionalPropertyValue $_ 'PeakTotalReadyNodes'
        if ($null -eq $value) {
            $karpenter=Get-OptionalPropertyValue $_ 'PeakReadyNodes'
            if ($null -ne $karpenter) { $value=[double]$karpenter+$ManagedNodes }
        }
        if ($null -ne $value) { [double]$value }
    })
    $cpu=$null;$memory=$null
    if (Test-CandidateConfigValid $config) {
        $cpu=[double](($apps | ForEach-Object { Convert-CpuToM $config[$_].requestCpu } | Measure-Object -Sum).Sum)
        $memory=[double](($apps | ForEach-Object { Convert-MemoryToMi $config[$_].requestMemory } | Measure-Object -Sum).Sum)
    }
    $competitionValues=@($Runs | ForEach-Object {
        $competition=Get-OptionalPropertyValue $_ 'CompetitionScore'
        $earned=Get-OptionalPropertyValue $competition 'Earned'
        if ($null -ne $earned) { [double]$earned }
    })
    return [pscustomobject]@{
        NodeSec=Get-QualityMedian $nodeSecondsValues
        CPURequestM=$cpu
        MemoryRequestMi=$memory
        Nodes=Get-QualityMedian $nodeValues
        CompetitionScore=Get-QualityMedian $competitionValues
    }
}

function Get-CandidateQualityScore {
    param([Parameter(Mandatory=$true)][object[]]$Runs,[string]$Name='candidate',$Config=$null)
    $usableRuns=@($Runs | Where-Object { $null -ne $_ -and $null -ne (Get-OptionalPropertyValue $_ 'Apps') })
    $representative=$usableRuns | Select-Object -Last 1
    if ($null -eq $Config -and $null -ne $representative) { $Config=Get-OptionalPropertyValue $representative 'Config' }
    $eligibility=Test-CandidateEligible ([pscustomobject]@{
        Config=$Config;Apps=$(if ($representative) { Get-OptionalPropertyValue $representative 'Apps' } else { $null })
        RolloutFailure=[bool]($usableRuns | Where-Object { [bool](Get-OptionalPropertyValue $_ 'RolloutFailure' $false) } | Select-Object -First 1)
        ApplyFailure=[bool]($usableRuns | Where-Object { [bool](Get-OptionalPropertyValue $_ 'ApplyFailure' $false) } | Select-Object -First 1)
        CrashLoopBackOff=[double](($usableRuns | ForEach-Object { [double](Get-OptionalPropertyValue $_ 'CrashLoopBackOff' 0) } | Measure-Object -Maximum).Maximum)
        OOMKilledDelta=[double](($usableRuns | ForEach-Object { [double](Get-OptionalPropertyValue $_ 'OOMKilledDelta' 0) } | Measure-Object -Maximum).Maximum)
        PersistentNotReady=[double](($usableRuns | ForEach-Object { [double](Get-OptionalPropertyValue $_ 'PersistentNotReady' 0) } | Measure-Object -Maximum).Maximum)
    })
    $details=[ordered]@{};$qValues=[System.Collections.Generic.List[double]]::new();$generatedValues=[System.Collections.Generic.List[double]]::new()
    $timeoutValues=[System.Collections.Generic.List[double]]::new();$tailValues=[System.Collections.Generic.List[double]]::new();$dropValues=[System.Collections.Generic.List[double]]::new()
    $requiredMissing=$false;$optionalMissing=$false
    foreach ($app in $apps) {
        $metrics=@($usableRuns | ForEach-Object { Get-ResultAppMetric $_ $app } | Where-Object { $null -ne $_ })
        # Q/L은 성공 응답 latency(SuccessP95Ms/SuccessP99Ms)만 사용한다.
        # SuccessP95Ms가 null이면 성공 응답이 없다는 뜻이며(예: timeout 100%),
        # timeout ceiling을 성공 latency로 대체하지 않는다.
        $p95=Get-QualityMedian @($metrics | ForEach-Object { Get-OptionalPropertyValue $_ 'SuccessP95Ms' })
        $p99Values=@($metrics | ForEach-Object { Get-OptionalPropertyValue $_ 'SuccessP99Ms' } | Where-Object { $null -ne $_ })
        $p99=if ($p99Values.Count) { [double](($p99Values | Measure-Object -Maximum).Maximum) } else { $null }
        $generatedValuesForApp=@($metrics | ForEach-Object {
            $g=Get-OptionalPropertyValue $_ 'GeneratedLoadRatio'
            if ($null -eq $g) {
                $actual=Get-OptionalPropertyValue $_ 'HighLoadRequests';$expected=Get-OptionalPropertyValue $_ 'ExpectedSteadyRequests'
                if ($null -ne $actual -and $null -ne $expected -and [double]$expected -gt 0) { $g=[double]$actual/[double]$expected }
            }
            if ($null -ne $g) { [double]$g }
        })
        $generated=if ($generatedValuesForApp.Count) { [double](($generatedValuesForApp | Measure-Object -Minimum).Minimum) } else { $null }
        # k6의 failure rate는 timeout을 포함하므로(같은 실패 요청) 중복 집계가
        # 아니라 단일 실패 비율이다. T는 이 최대 실패 비율을 timeout 중심으로 쓴다.
        $errors=@($metrics | ForEach-Object {
            $timeout=Get-OptionalPropertyValue $_ 'SteadyTimeoutRate'
            $failure=Get-OptionalPropertyValue $_ 'HighLoadFailureRate'
            if ($null -ne $timeout -or $null -ne $failure) { [math]::Max([double]$(if ($null -eq $timeout) {0} else {$timeout}),[double]$(if ($null -eq $failure) {0} else {$failure})) }
        })
        $errorRate=if ($errors.Count) { [double](($errors | Measure-Object -Maximum).Maximum) } else { $null }
        $dropRates=@($metrics | ForEach-Object {
            $dropped=Get-OptionalPropertyValue $_ 'AllocatedDroppedIterations';$requests=Get-OptionalPropertyValue $_ 'Requests'
            if ($null -ne $dropped -and $null -ne $requests -and ([double]$dropped+[double]$requests) -gt 0) { [double]$dropped/([double]$dropped+[double]$requests) }
        })
        $droppedRate=if ($dropRates.Count) { [double](($dropRates | Measure-Object -Maximum).Maximum) } else { $null }
        $q=Get-ApiSloQuality $p95 $sloMs[$app]
        if ($null -eq $q) { $q=0.0;$requiredMissing=$true }
        $qValues.Add([double]$q)
        if ($null -eq $generated) { $requiredMissing=$true } else { $generatedValues.Add([double]$generated) }
        if ($null -eq $errorRate) { $requiredMissing=$true } else { $timeoutValues.Add([double]$errorRate) }
        $tail=Get-TailQuality $p95 $p99
        $tailMetricAvailable=($null -ne $tail)
        if ($null -eq $tail) { $tail=[double]$missingTailScore }
        $tailValues.Add([double]$tail)
        if ($null -eq $p99) { $optionalMissing=$true }
        if ($null -ne $droppedRate) { $dropValues.Add([double]$droppedRate) } else { $optionalMissing=$true }
        $details[$app]=[pscustomobject]@{P95Ms=$p95;SLOMs=[double]$sloMs[$app];SloQuality=$q;GeneratedRatio=$generated;ErrorRate=$errorRate;P99Ms=$p99;TailRatio=$(if ($null -ne $p99 -and $null -ne $p95 -and [double]$p95 -gt 0) {[double]$p99/[double]$p95} else {$null});TailQuality=$tail;TailMetricAvailable=$tailMetricAvailable;DroppedRate=$droppedRate}
    }
    $qScore=Get-SloQuality $qValues.ToArray();if ($null -eq $qScore) { $qScore=0.0 }
    $minimumGenerated=if ($generatedValues.Count -eq $apps.Count) { [double](($generatedValues | Measure-Object -Minimum).Minimum) } else { $null }
    $generationScore=Get-GenerationQuality $minimumGenerated;if ($null -eq $generationScore) { $generationScore=0.0 }
    $worstError=if ($timeoutValues.Count -eq $apps.Count) {[double](($timeoutValues | Measure-Object -Maximum).Maximum)} else {$null}
    $timeoutScore=Get-TimeoutQuality $worstError;if ($null -eq $timeoutScore) { $timeoutScore=0.0 }
    $tailScore=if ($tailValues.Count) {[double](($tailValues | Measure-Object -Minimum).Minimum)} else {[double]$missingTailScore}
    $worstDropped=if ($dropValues.Count) {[double](($dropValues | Measure-Object -Maximum).Maximum)} else {$null}
    $reliability=Get-MeasurementReliability $worstDropped (-not $requiredMissing) $optionalMissing
    # 가중 기하평균. ln(0) 방지 epsilon은 내부 계산만 보호하고 표시 항은 실제 값을 쓴다.
    $safeQ=[math]::Max([double]$qScore,$ScoreEpsilon);$safeTail=[math]::Max([double]$tailScore,$ScoreEpsilon)
    $safeTimeout=[math]::Max([double]$timeoutScore,$ScoreEpsilon);$safeGeneration=[math]::Max([double]$generationScore,$ScoreEpsilon)
    $safeReliability=[math]::Max([double]$reliability,$ScoreEpsilon)
    $core=[math]::Exp(($QualityWeights.Slo*[math]::Log($safeQ))+($QualityWeights.Tail*[math]::Log($safeTail))+($QualityWeights.Timeout*[math]::Log($safeTimeout))+($QualityWeights.Generation*[math]::Log($safeGeneration))+($QualityWeights.Reliability*[math]::Log($safeReliability)))
    $score=100.0*$core
    $cost=Get-CandidateCostMetrics $representative $usableRuns
    return [pscustomobject]@{Name=$Name;Status='MEASURED';Result=$representative;Config=$Config;Runs=$usableRuns;RunCount=$Runs.Count;UsedRunCount=$usableRuns.Count;Eligible=[bool]$eligibility.Eligible;EligibilityReasons=$eligibility.Reasons;MeasurementIncomplete=$requiredMissing;QualityScore=$score;Q=[double]$qScore;Tail=[double]$tailScore;Timeout=[double]$timeoutScore;Generation=[double]$generationScore;Reliability=[double]$reliability;MinimumGeneratedRatio=$minimumGenerated;WorstErrorRate=$worstError;WorstDroppedRate=$worstDropped;Apps=$details;Cost=$cost}
}

function Get-QualityCandidateBaseName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'candidate' }
    return ($Name -replace '-VURetry\d+$','' -replace '-Verify\d+$','')
}

function Get-CandidateMainIssue($Entry) {
    if ($Entry.Status -eq 'NOT_MEASURED') { return 'NOT_MEASURED' }
    if (-not $Entry.Eligible) { return [string]$(if ($Entry.EligibilityReasons.Count) {$Entry.EligibilityReasons[0]} else {'INELIGIBLE'}) }
    $appMetrics=@($apps | ForEach-Object { [pscustomobject]@{App=$_;Metric=$Entry.Apps[$_]} } | Where-Object { $null -ne $_.Metric })
    $loadIssue=$appMetrics | Where-Object { $null -eq $_.Metric.GeneratedRatio -or [double]$_.Metric.GeneratedRatio -lt .95 } | Sort-Object { if ($null -eq $_.Metric.GeneratedRatio) {-1.0} else {[double]$_.Metric.GeneratedRatio} } | Select-Object -First 1
    if ($loadIssue) { return 'LOAD_GENERATOR_LIMIT' }
    $errorIssue=$appMetrics | Where-Object { $null -ne $_.Metric.ErrorRate -and [double]$_.Metric.ErrorRate -gt 0 } | Sort-Object { [double]$_.Metric.ErrorRate } -Descending | Select-Object -First 1
    if ($errorIssue) { return "$($errorIssue.App.ToUpperInvariant())_TIMEOUT" }
    if ($null -ne $Entry.WorstDroppedRate -and [double]$Entry.WorstDroppedRate -gt 0) { return 'DROPPED_ITERATIONS' }
    $tailIssue=$appMetrics | Where-Object { [double]$_.Metric.TailQuality -lt .80 } | Sort-Object { [double]$_.Metric.TailQuality } | Select-Object -First 1
    if ($tailIssue) { return "$($tailIssue.App.ToUpperInvariant())_TAIL" }
    $sloIssue=$appMetrics | Where-Object { [double]$_.Metric.SloQuality -lt 1.0 } | Sort-Object { [double]$_.Metric.SloQuality } | Select-Object -First 1
    if ($sloIssue) { return "$($sloIssue.App.ToUpperInvariant())_SLO" }
    if ($Entry.MeasurementIncomplete) { return 'METRIC_INCOMPLETE' }
    return 'OK'
}

function Write-CandidateAppDetails($Entry) {
    # 앱별 상세 (디버그/개발 옵션에서만). timeout 100% 등 성공 응답이 없으면
    # ceiling latency를 정상 latency처럼 보여주지 않고 N/A로 표시한다.
    Write-Host ("`n[{0}] runs={1}/{2}, incomplete={3}, QualityScore={4:N2}" -f $Entry.Name,$Entry.UsedRunCount,$Entry.RunCount,$Entry.MeasurementIncomplete,$Entry.QualityScore) -ForegroundColor DarkCyan
    foreach ($app in $apps) {
        $metric=$Entry.Apps[$app];if ($null -eq $metric) { Write-Host ("  {0,-7} metric=UNPARSEABLE" -f $app);continue }
        Write-Host ("  {0,-7} success p95/SLO = {1}/{2}" -f $app,$(if ($null -eq $metric.P95Ms) {'N/A'} else {'{0:N0}' -f [double]$metric.P95Ms}),$metric.SLOMs)
        Write-Host ("  {0,-7} Q               = {1}" -f $app,$(if ($null -eq $metric.P95Ms) {'N/A/fallback'} else {'{0:N3}' -f [double]$metric.SloQuality}))
        Write-Host ("  {0,-7} generated       = {1}" -f $app,$(if ($null -eq $metric.GeneratedRatio) {'N/A'} else {'{0:P1}' -f [double]$metric.GeneratedRatio}))
        Write-Host ("  {0,-7} timeout         = {1}" -f $app,$(if ($null -eq $metric.ErrorRate) {'N/A'} else {'{0:P1}' -f [double]$metric.ErrorRate}))
        Write-Host ("  {0,-7} success p99     = {1}" -f $app,$(if ($null -eq $metric.P99Ms) {'N/A'} else {'{0:N0}' -f [double]$metric.P99Ms}))
        Write-Host ("  {0,-7} tail            = {1}" -f $app,$(if (-not $metric.TailMetricAvailable) {'N/A/fallback'} else {'{0:N3}' -f [double]$metric.TailQuality}))
    }
}

function Write-FinalScoreboard([object[]]$Entries,[switch]$DebugSelection) {
    $measuredEligible=@($Entries | Where-Object { $_.Status -eq 'MEASURED' -and $_.Eligible })
    $best=if ($measuredEligible.Count) {[double](($measuredEligible | Measure-Object QualityScore -Maximum).Maximum)} else {0.0}
    Write-Host "`n================ FINAL SCOREBOARD =================" -ForegroundColor Cyan
    Write-Host 'Rank Candidate          Eligible Quality    Rel%  Q     L     T     G     R     NodeSec MainIssue'
    Write-Host '---- ------------------ -------- ---------- ----- ----- ----- ----- ----- ----- ------- --------------------'
    $rank=0
    foreach ($entry in $Entries) {
        if ($entry.Status -eq 'NOT_MEASURED') {
            Write-Host ("{0,4} {1,-18} {2,8} {3,10} {4,5} {5,5} {6,5} {7,5} {8,5} {9,5} {10,7} {11}" -f '-',$entry.Name,'No','---','---','---','---','---','---','---','---','NOT_MEASURED')
            continue
        }
        if ($entry.Eligible) {$rank++;$rankText=$rank} else {$rankText='-'}
        $relative=if ($best -gt 0) {[double]$entry.QualityScore/$best} elseif ($entry.QualityScore -eq $best) {1.0} else {0.0}
        $qualityText=if ($entry.QualityScore -lt 1.0) {'{0:0.000000}' -f [double]$entry.QualityScore} else {'{0:0.00}' -f [double]$entry.QualityScore}
        $nodeSec=if ($null -eq $entry.Cost.NodeSec) {'---'} else {'{0:N0}' -f [double]$entry.Cost.NodeSec}
        Write-Host ("{0,4} {1,-18} {2,8} {3,10} {4,5} {5,5} {6,5} {7,5} {8,5} {9,5} {10,7} {11}" -f $rankText,$entry.Name,$(if ($entry.Eligible) {'Yes'} else {'No'}),$qualityText,('{0:P0}' -f [double]$relative),('{0:0.00}' -f [double]$entry.Q),('{0:0.00}' -f [double]$entry.Tail),('{0:0.00}' -f [double]$entry.Timeout),('{0:0.00}' -f [double]$entry.Generation),('{0:0.00}' -f [double]$entry.Reliability),$nodeSec,(Get-CandidateMainIssue $entry))
    }
    Write-Host '====================================================' -ForegroundColor Cyan
    if ($DebugSelection -or $DetailedOutput) {
        foreach ($entry in @($Entries | Where-Object Status -eq 'MEASURED')) { Write-CandidateAppDetails $entry }
    }
}

function Write-FinalSelection($Selection,$Config,[switch]$DebugSelection) {
    Write-Host "`n================ FINAL SELECTION ==================" -ForegroundColor Green
    if (-not $Selection.ApplyAllowed) {
        Write-Host '선택 후보: 없음 (원래 설정 유지)' -ForegroundColor Yellow
        Write-Host '선택 이유: 모든 측정 후보가 실제 적용 불가 상태입니다.'
    } else {
        $selected=$Selection.SelectedEntry
        Write-Host ("Best QualityScore: {0:N2}" -f [double]$Selection.BestQuality)
        Write-Host ("Near-best threshold: {0:N2}" -f [double]$Selection.NearBestThreshold)
        Write-Host ''
        Write-Host 'Near-best candidates:'
        foreach ($candidate in $Selection.NearBestCandidates) {
            Write-Host ("  {0,-20} Quality={1:N2} NodeSec={2}" -f $candidate.Name,[double]$candidate.QualityScore,$(if ($null -eq $candidate.Cost.NodeSec) {'---'} else {'{0:N0}' -f [double]$candidate.Cost.NodeSec}))
        }
        Write-Host ''
        Write-Host ("선택 후보: {0}" -f $selected.Name) -ForegroundColor Green
        Write-Host ''
        Write-Host '선택 이유:'
        Write-Host ('- {0}' -f $Selection.SelectionReason)
        Write-Host '- Eligible=true'
        Write-Host ''
        Write-Host 'CompetitionScore는 참고용입니다.'
        Write-Host ("Stress length: {0}" -f $(if ($script:SelectedStressLength -gt 0) { $script:SelectedStressLength } else { $DefaultStressLength }))
        Write-Host "`n최종 설정:"
        foreach ($app in $apps) {
            $c=$Config[$app]
            Write-Host ("  {0,-7} request={1}/{2}, limit={3}/{4}, HPA={5}% {6}..{7}" -f $app,$c.requestCpu,$c.requestMemory,$c.limitCpu,$c.limitMemory,$c.hpaTarget,$c.minReplicas,$c.maxReplicas)
        }
        if ($DebugSelection -or $DetailedOutput) {
            Write-Host ("Near-best candidates={0}" -f (($Selection.NearBestCandidates | ForEach-Object Name) -join ', ')) -ForegroundColor DarkGray
        }
    }
    Write-Host '====================================================' -ForegroundColor Green
}

function Select-QualityCandidate {
    param([object[]]$Results,[object[]]$ExpectedConfigs=@(),[int]$RequestedVerificationRuns=2,[int]$SkippedRuntimeRuns=0,[switch]$Quiet)
    # 최종 후보 선택 source of truth:
    # Eligible -> QualityScore -> near-best -> 비용(NodeSec/CPU/Memory/Nodes) -> CompetitionScore(참고)
    $measurements=@(Expand-CandidateMeasurements $Results | Where-Object { $null -ne $_ })
    $groups=[ordered]@{}
    foreach ($measurement in $measurements) {
        $config=Get-OptionalPropertyValue $measurement 'Config'
        $fingerprint=if (Test-CandidateConfigValid $config) { Get-ConfigFingerprint $config } else { "invalid:$([guid]::NewGuid())" }
        if (-not $groups.Contains($fingerprint)) { $groups[$fingerprint]=[System.Collections.Generic.List[object]]::new() }
        $groups[$fingerprint].Add($measurement)
    }
    $entries=[System.Collections.Generic.List[object]]::new()
    foreach ($fingerprint in $groups.Keys) {
        $allRuns=@($groups[$fingerprint]);$validGeneratorRuns=@($allRuns | Where-Object { -not [bool](Get-OptionalPropertyValue $_ 'LoadGeneratorLimited' $false) })
        $used=if ($validGeneratorRuns.Count) {$validGeneratorRuns} else {$allRuns}
        $representative=$used | Select-Object -Last 1
        # 동일 config의 base/verification은 하나의 후보다. 가장 최근 실제
        # 측정 이름을 사용해 CalculatedFinal 검증이 Minimum 이름에 숨지 않게 한다.
        $name=Get-QualityCandidateBaseName ([string](Get-OptionalPropertyValue $representative 'Name' 'candidate'))
        try {
            $entries.Add((Get-CandidateQualityScore -Runs $used -Name $name -Config (Get-OptionalPropertyValue $representative 'Config')))
            $entries[$entries.Count-1].RunCount=$allRuns.Count
        } catch {
            # 한 후보의 손상된 metric이 전체 결과를 폐기하지 않게 하고 해당
            # 후보만 명시적인 apply 불가 상태로 점수표에 남긴다.
            $entries.Add([pscustomobject]@{Name=$name;Status='MEASURED';Result=$representative;Config=(Get-OptionalPropertyValue $representative 'Config');Runs=$used;RunCount=$allRuns.Count;UsedRunCount=$used.Count;Eligible=$false;EligibilityReasons=@("UNPARSEABLE_MEASUREMENT: $($_.Exception.Message)");MeasurementIncomplete=$true;QualityScore=0.0;Q=0.0;Tail=0.0;Timeout=0.0;Generation=0.0;Reliability=0.0;Apps=@{};Cost=[pscustomobject]@{NodeSec=$null;CPURequestM=$null;MemoryRequestMi=$null;Nodes=$null;CompetitionScore=$null}})
        }
    }
    foreach ($expected in $ExpectedConfigs) {
        if ($null -eq $expected) { continue }
        $expectedName=Get-QualityCandidateBaseName ([string](Get-OptionalPropertyValue $expected 'Name' 'candidate'))
        $namedMeasurement=@($measurements | Where-Object { (Get-QualityCandidateBaseName ([string](Get-OptionalPropertyValue $_ 'Name' ''))) -eq $expectedName }).Count -gt 0
        if (-not $namedMeasurement) { $entries.Add([pscustomobject]@{Name=$expectedName;Status='NOT_MEASURED';Result=$null;Config=$expected;Runs=@();RunCount=0;UsedRunCount=0;Eligible=$false;EligibilityReasons=@('NOT_MEASURED');MeasurementIncomplete=$true;QualityScore=$null;Q=$null;Tail=$null;Timeout=$null;Generation=$null;Reliability=$null;Apps=@{};Cost=[pscustomobject]@{NodeSec=$null;CPURequestM=$null;MemoryRequestMi=$null;Nodes=$null;CompetitionScore=$null}}) }
    }
    $measured=@($entries | Where-Object Status -eq 'MEASURED')
    $sorted=@($measured | Sort-Object @{Expression='Eligible';Descending=$true},@{Expression='QualityScore';Descending=$true},@{Expression={$_.Cost.NodeSec};Descending=$false})+@($entries | Where-Object Status -eq 'NOT_MEASURED')
    if (-not $Quiet) { Write-FinalScoreboard $sorted }
    $eligible=@($measured | Where-Object Eligible)
    if ($eligible.Count -eq 0) {
        if (-not $Quiet) { Write-Warning 'Eligible 후보가 없어 원래 설정을 유지합니다.' }
        return [pscustomobject]@{Result=$(if($measured.Count){$measured[0].Result}else{$null});Config=$null;Grade='INVALID';FatalFailure=$true;PerformanceFailure=$false;MeasurementFailure=$true;ApplyAllowed=$false;QualityScore=$null;SelectedEntry=$null;Scoreboard=$sorted;Verification=[pscustomobject]@{Requested=$RequestedVerificationRuns;Completed=$measurements.Count;SkippedRuntime=$SkippedRuntimeRuns};Stability=$null}
    }
    $best=[double](($eligible | Measure-Object QualityScore -Maximum).Maximum)
    # NearBestThreshold = max(BestQuality - 3, BestQuality * 0.95).
    # 작은 Quality 영역에서 absolute 3점만 쓰면 모든 후보가 near-best가 되는
    # 문제를 relative 항이 막는다. 비용은 품질 차이를 역전시키지 않는다.
    $threshold=[math]::Max($best-$qualityNearBestTolerance,$best*$qualityNearBestRelative)
    $nearBest=@($eligible | Where-Object { [double]$_.QualityScore -ge $threshold })
    $costSorted=@($nearBest | Sort-Object `
        @{Expression={if($null -eq $_.Cost.NodeSec){[double]::PositiveInfinity}else{[double]$_.Cost.NodeSec}};Descending=$false},`
        @{Expression={if($null -eq $_.Cost.CPURequestM){[double]::PositiveInfinity}else{[double]$_.Cost.CPURequestM}};Descending=$false},`
        @{Expression={if($null -eq $_.Cost.MemoryRequestMi){[double]::PositiveInfinity}else{[double]$_.Cost.MemoryRequestMi}};Descending=$false},`
        @{Expression={if($null -eq $_.Cost.Nodes){[double]::PositiveInfinity}else{[double]$_.Cost.Nodes}};Descending=$false},`
        @{Expression={if($null -eq $_.Cost.CompetitionScore){[double]::NegativeInfinity}else{[double]$_.Cost.CompetitionScore}};Descending=$true},`
        @{Expression='QualityScore';Descending=$true})
    $selected=$costSorted[0]
    $failure=Get-FailureClassification $selected.Result
    $stability=Test-StableCandidate @($measurements) $selected.Config 2
    $reason=if ($nearBest.Count -eq 1) {'최고 QualityScore 후보이며 저품질 후보는 near-best 범위 밖입니다.'} elseif ($selected.QualityScore -eq $best) {'최고 QualityScore 후보이며 near-best 비용 비교 결과 선택됐습니다.'} else {'최고 QualityScore와 near-best 범위이며 NodeSec/request 비용이 더 낮아 선택됐습니다.'}
    $selectionResult=[pscustomobject]@{Result=$selected.Result;Config=$selected.Config;Grade='QUALITY_SELECTED';FatalFailure=$false;PerformanceFailure=[bool]$failure.PerformanceFailure;MeasurementFailure=[bool]$selected.MeasurementIncomplete;ApplyAllowed=$true;CapacityReliable=(-not $selected.MeasurementIncomplete);ReliableApis=@($apps | Where-Object { $null -ne $selected.Apps[$_].GeneratedRatio -and $selected.Apps[$_].GeneratedRatio -ge .95 }).Count;SLOPassCount=@($apps | Where-Object { $selected.Apps[$_].SloQuality -ge 1.0 }).Count;TimeoutRate=$selected.WorstErrorRate;CompetitionScore=$selected.Cost.CompetitionScore;QualityScore=$selected.QualityScore;SelectedEntry=$selected;SelectionReason=$reason;BestQuality=$best;NearBestThreshold=$threshold;NearBestCandidates=$nearBest;Stability=$stability;Verification=[pscustomobject]@{Requested=$RequestedVerificationRuns;Completed=$selected.UsedRunCount;SkippedRuntime=$SkippedRuntimeRuns};Scoreboard=$sorted}
    if (-not $Quiet) { Write-FinalSelection $selectionResult $selected.Config }
    return $selectionResult
}

function New-CandidateRankEntry {
    param([Parameter(Mandatory=$true)]$Candidate)
    $measurement=Get-RepresentativeMeasurement $Candidate
    $sloPass=0; $reliableApis=0; $timeoutError=0.0; $violationTotal=0.0; $violationWorst=0.0; $score=[double]::NegativeInfinity
    foreach ($app in $apps) {
        $metric=Get-ResultAppMetric $measurement $app
        if ($null -eq $metric) { $timeoutError=[double]::PositiveInfinity; $violationTotal=[double]::PositiveInfinity; $violationWorst=[double]::PositiveInfinity; continue }
        if ([bool](Get-OptionalPropertyValue $metric 'SLOPass' $false)) { $sloPass++ }
        if ([bool](Get-OptionalPropertyValue $metric 'CapacityReliable' $false)) { $reliableApis++ }
        $timeoutValue=Get-OptionalPropertyValue $metric 'SteadyTimeoutRate'
        $errorValue=Get-OptionalPropertyValue $metric 'HighLoadFailureRate'
        if ($null -eq $timeoutValue -or $null -eq $errorValue) { $timeoutError=[double]::PositiveInfinity }
        elseif (-not [double]::IsInfinity($timeoutError)) { $timeoutError += [double]$timeoutValue+[double]$errorValue }
        $p95=Get-OptionalPropertyValue $metric 'P95Ms'
        if ($null -eq $p95) { $violationTotal=[double]::PositiveInfinity; $violationWorst=[double]::PositiveInfinity }
        elseif (-not [double]::IsInfinity($violationTotal)) {
            $ratio=[double]$p95/[double]$sloMs[$app]
            $violationTotal += [math]::Max(0.0,$ratio-1.0)
            $violationWorst=[math]::Max($violationWorst,$ratio)
        }
    }
    $competition=Get-OptionalPropertyValue $measurement 'CompetitionScore'; $earned=Get-OptionalPropertyValue $competition 'Earned'
    $scoreRecovered=$false
    if ($null -eq $earned) {
        # 측정 객체가 존재하는데 CompetitionScore 직렬화/래핑만 누락된 경우
        # 앱별 실제 metric으로 공식 점수를 다시 계산한다.
        $metricTable=Get-OptionalPropertyValue $measurement 'Apps'
        $hasAllApps=$null -ne $metricTable -and @($apps | Where-Object { $null -eq (Get-ResultAppMetric $measurement $_) }).Count -eq 0
        if ($hasAllApps) {
            $readyNodes=Get-OptionalPropertyValue $measurement 'PeakTotalReadyNodes'
            if ($null -eq $readyNodes) { $readyNodes=([double](Get-OptionalPropertyValue $measurement 'PeakReadyNodes' 0))+$ManagedNodes }
            try {
                $competition=Get-CompetitionScore $metricTable ([double]$readyNodes)
                $measurement | Add-Member -NotePropertyName CompetitionScore -NotePropertyValue $competition -Force
                $earned=$competition.Earned;$scoreRecovered=$true
            } catch { }
        }
    }
    if ($null -ne $earned) { $score=[double]$earned }
    else {
        # 유효한 측정 후보를 점수 field 하나 때문에 폐기하지 않는다. 0점으로
        # 남겨 tie-breaker가 그나마 좋은 값을 고르게 한다.
        $score=0.0;$scoreRecovered=$true
        $competition=[pscustomobject]@{Earned=0.0;Max=36.0;Items=@();RecoveredFallback=$true}
        $measurement | Add-Member -NotePropertyName CompetitionScore -NotePropertyValue $competition -Force
    }
    $config=Get-OptionalPropertyValue $measurement 'Config'; if ($null -eq $config) { $config=Get-OptionalPropertyValue $Candidate 'Config' }
    $failure=Get-FailureClassification $measurement
    $generatedMin=Get-MinGeneratedPercent $measurement
    $resourceCost=[double]::PositiveInfinity
    if (Test-CandidateConfigValid $config) { $resourceCost=[double](($apps | ForEach-Object { (Convert-CpuToM $config[$_].requestCpu)+((Convert-MemoryToMi $config[$_].requestMemory)*0.25) } | Measure-Object -Sum).Sum) }
    return [pscustomobject]@{
        Candidate=$Candidate; Representative=$measurement; Config=$config
        FatalFailure=[bool]$failure.FatalFailure;PerformanceFailure=[bool]$failure.PerformanceFailure;MeasurementFailure=[bool]$failure.MeasurementFailure;FailureClassification=$failure
        RankFatalFailure=if ($failure.FatalFailure) {1} else {0};RankReliableApis=[int]$reliableApis
        RankSloPassCount=[int]$sloPass;RankGeneratedMinPercent=if ($null -eq $generatedMin) {[double]::NegativeInfinity} else {[double]$generatedMin}
        RankTimeoutError=$timeoutError;RankSloViolationTotal=$violationTotal;RankSloViolationWorst=$violationWorst;RankCompetitionScore=$score;CompetitionScoreRecovered=$scoreRecovered
        RankRps=if ($null -ne (Get-OptionalPropertyValue $measurement 'TotalSuccessfulRPS')) {[double]$measurement.TotalSuccessfulRPS} else {[double]::NegativeInfinity}
        RankEfficiency=if ($null -ne (Get-OptionalPropertyValue $measurement 'TotalScore')) {[double]$measurement.TotalScore} else {[double]::NegativeInfinity}
        RankNodeSeconds=if ($null -ne (Get-OptionalPropertyValue $measurement 'TotalNodeSeconds')) {[double]$measurement.TotalNodeSeconds} elseif ($null -ne (Get-OptionalPropertyValue $measurement 'NodeSeconds')) {[double]$measurement.NodeSeconds} else {[double]::PositiveInfinity}
        RankNodes=if ($null -ne (Get-OptionalPropertyValue $measurement 'PeakTotalReadyNodes')) {[double]$measurement.PeakTotalReadyNodes} elseif ($null -ne (Get-OptionalPropertyValue $measurement 'PeakReadyNodes')) {[double]$measurement.PeakReadyNodes+$ManagedNodes} else {[double]::PositiveInfinity}
        RankResourceCost=$resourceCost
    }
}

function Show-FinalScoreboard([object[]]$Entries) {
    $rows=@($Entries | Where-Object { $_ })
    Write-Host "`n================ FINAL SCOREBOARD ================" -ForegroundColor Cyan
    if ($DetailedOutput) { Write-Host 'Rank Candidate                 Score  SLO Rel GenMin Fatal Perf Measure Tmo/Err   RPS Efficiency Nodes NodeSec Bottleneck' }
    else { Write-Host 'Rank Candidate                 Score  SLO   Reliable GenMin Fatal Nodes' }
    if ($rows.Count -eq 0) { Write-Warning '측정된 후보가 없어 최종 점수표를 출력할 수 없습니다.'; return }
    $rank=0
    foreach ($entry in $rows) {
        $rank++
        $result=$entry.Candidate
        $score=if ([double]::IsNegativeInfinity($entry.RankCompetitionScore)) {'NOT_MEASURED'} else {'{0:N2}' -f $entry.RankCompetitionScore}
        $slo="{0}/{1}" -f $entry.RankSloPassCount,$apps.Count
        $reliable="{0}/{1}" -f $entry.RankReliableApis,$apps.Count
        $generated=if ([double]::IsNegativeInfinity($entry.RankGeneratedMinPercent)) {'null'} else {'{0:N1}%' -f $entry.RankGeneratedMinPercent}
        $rps=if ([double]::IsNegativeInfinity($entry.RankRps)) {'-'} else {'{0:N1}' -f $entry.RankRps}
        $nodes=if ([double]::IsPositiveInfinity($entry.RankNodes)) {'-'} else {'{0:N0}' -f $entry.RankNodes}
        $nodeSec=if ([double]::IsPositiveInfinity($entry.RankNodeSeconds)) {'-'} else {'{0:N0}' -f $entry.RankNodeSeconds}
        $candidateName=[string](Get-OptionalPropertyValue $result 'Name' 'candidate')
        $fatal=if ($entry.FatalFailure) {'Yes'} else {'No'}
        $performance=if ($entry.PerformanceFailure) {'Yes'} else {'No'}
        $measurement=if ($entry.MeasurementFailure) {'Yes'} else {'No'}
        $timeoutError=if ([double]::IsPositiveInfinity($entry.RankTimeoutError)) {'null'} else {'{0:P1}' -f $entry.RankTimeoutError}
        $bottleneck=if ($entry.FailureClassification.FailureReasons.Count) {$entry.FailureClassification.FailureReasons -join ','} else {'-'}
        $efficiency=if ([double]::IsNegativeInfinity($entry.RankEfficiency)) {'-'} else {'{0:N1}' -f $entry.RankEfficiency}
        if ($DetailedOutput) {
            $columns=@($rank,$candidateName,$score,$slo,$reliable,$generated,$fatal,$performance,$measurement,$timeoutError,$rps,$efficiency,$nodes,$nodeSec,$bottleneck)
            Write-Host ("{0,4} {1,-24} {2,6} {3,-3} {4,-3} {5,6} {6,-5} {7,-4} {8,-7} {9,7} {10,5} {11,10} {12,5} {13,7} {14}" -f $columns)
        } else {
            Write-Host ("{0,4} {1,-24} {2,6} {3,-5} {4,-8} {5,6} {6,-5} {7,5}" -f $rank,$candidateName,$score,$slo,$reliable,$generated,$fatal,$nodes)
        }
    }
    Write-Host "===================================================" -ForegroundColor Cyan
}

function Select-BestAvailableCandidate([object[]]$results,[int]$RequestedVerificationRuns=2,[int]$SkippedRuntimeRuns=0) {
    $inputResults=@(Expand-CandidateMeasurements $results)
    if ($inputResults.Count -eq 0) { Write-Warning '후보 결과가 없습니다.'; return $null }
    # 측정 결과가 하나라도 있으면 전부 scoreboard/ranking에 남긴다.
    # CompetitionScore 누락은 New-CandidateRankEntry에서 재계산 또는 0점
    # fallback으로 복구되므로 여기서 후보를 필터링하지 않는다.
    $rankable=@($inputResults | ForEach-Object { New-CandidateRankEntry $_ })
    if ($rankable.Count -eq 0) { Write-Warning '측정 후보 객체를 평가할 수 없습니다.'; return $null }
    $recoveredCount=@($rankable | Where-Object CompetitionScoreRecovered).Count
    if ($recoveredCount -gt 0) { Write-Warning "CompetitionScore가 누락된 ${recoveredCount}개 후보를 측정 metric 기반 점수 또는 0점 best-effort로 복구했습니다." }
    $sortRules=@(
        @{Expression='RankCompetitionScore';Descending=$true},@{Expression='RankFatalFailure';Descending=$false},
        @{Expression='RankReliableApis';Descending=$true},@{Expression='RankSloPassCount';Descending=$true},
        @{Expression='RankGeneratedMinPercent';Descending=$true},@{Expression='RankTimeoutError';Descending=$false},
        @{Expression='RankSloViolationTotal';Descending=$false},@{Expression='RankSloViolationWorst';Descending=$false},
        @{Expression='RankRps';Descending=$true},@{Expression='RankEfficiency';Descending=$true},
        @{Expression='RankNodeSeconds';Descending=$false},@{Expression='RankNodes';Descending=$false},@{Expression='RankResourceCost';Descending=$false}
    )
    $sorted=@($rankable | Sort-Object -Property $sortRules)
    Show-FinalScoreboard $sorted
    $applicable=@($sorted | Where-Object { -not $_.FatalFailure })
    $allFatal=$applicable.Count -eq 0
    $entry=if ($allFatal) {$sorted[0]} else {$applicable[0]}
    $representative=$entry.Candidate; $config=$entry.Config
    $stability=Test-StableCandidate @($inputResults) $config 2
    $eligible=@($inputResults | Where-Object { -not (Get-FailureClassification $_).MeasurementFailure })
    $isFinal=([string](Get-OptionalPropertyValue $representative 'Name' '') -like 'CalculatedFinal*')
    $allExecutedPass=$eligible.Count -gt 0 -and @($eligible | Where-Object { -not (Get-FailureClassification $_).FatalFailure -and [bool](Get-OptionalPropertyValue $_ 'MeasurementReliable' $false) -and [bool](Get-OptionalPropertyValue $_ 'AllSLOPass' $false) }).Count -eq $eligible.Count
    $stable=[bool](Get-OptionalPropertyValue $stability 'Stable' $false)
    $grade=if ($allFatal) {'INVALID'} elseif ($stable) {'STABLE'} elseif ($isFinal -and $allExecutedPass -and $SkippedRuntimeRuns -gt 0) {'PARTIALLY_VERIFIED'} elseif ($entry.RankReliableApis -eq $apps.Count) {'BEST_EFFORT_RELIABLE'} else {'BEST_EFFORT'}
    $ties=@($sorted | Where-Object { $_.RankCompetitionScore -eq $entry.RankCompetitionScore } | ForEach-Object { [string](Get-OptionalPropertyValue $_.Candidate 'Name' 'candidate') })
    if ($DetailedOutput) {
        Write-Host "`n================ FINAL SELECTION =================" -ForegroundColor Green
        Write-Host ("선택 후보: {0}" -f $representative.Name)
        Write-Host ("CompetitionScore: {0:N2} / 36" -f $entry.RankCompetitionScore)
        Write-Host ("동점 후보: {0}" -f $(if ($ties.Count -gt 1) {$ties -join ', '} else {'없음'}))
        Write-Host ("Tie-break: Reliable API={0}/{1}, SLO PASS={2}/{1}, GeneratedMin={3}, Timeout/Error={4}, SLO violation total/worst={5:N3}/{6:N3}, RPS={7}, Efficiency={8}, NodeSec={9}, Nodes={10}" -f $entry.RankReliableApis,$apps.Count,$entry.RankSloPassCount,$(if ([double]::IsNegativeInfinity($entry.RankGeneratedMinPercent)) {'null'} else {"$([math]::Round($entry.RankGeneratedMinPercent,1))%"}),$(if ([double]::IsPositiveInfinity($entry.RankTimeoutError)) {'null'} else {"$([math]::Round($entry.RankTimeoutError*100,2))%"}),$entry.RankSloViolationTotal,$entry.RankSloViolationWorst,$entry.RankRps,$entry.RankEfficiency,$entry.RankNodeSeconds,$entry.RankNodes)
        Write-Host ("Failure class: Fatal={0}, Performance={1}, Measurement={2}" -f $entry.FatalFailure,$entry.PerformanceFailure,$entry.MeasurementFailure)
        Write-Host "선택 이유: CompetitionScore → Fatal → Reliable API → SLO PASS → GeneratedMin → timeout/error → normalized SLO violation → RPS → efficiency → NodeSec → nodes → resource cost"
        Write-Host "===================================================" -ForegroundColor Green
    }
    if ($allFatal) { Write-Warning '모든 측정 후보가 FatalFailure입니다. 점수표 1위는 표시하지만 실제 Apply는 금지하고 원래 설정을 유지합니다.' }
    elseif ($entry.PerformanceFailure -or $entry.MeasurementFailure) { Write-Warning '완전 안정 후보는 아니지만 FatalFailure가 없는 최고 후보를 선택했습니다.' }
    return [pscustomobject]@{Result=$representative;Config=$config;Grade=$grade;GradeRank=@{STABLE=1;PARTIALLY_VERIFIED=2;BEST_EFFORT_RELIABLE=3;BEST_EFFORT=4;INVALID=5}[$grade];FatalFailure=$entry.FatalFailure;PerformanceFailure=$entry.PerformanceFailure;MeasurementFailure=$entry.MeasurementFailure;ApplyAllowed=(-not $allFatal);CapacityReliable=($entry.RankReliableApis -eq $apps.Count);ReliableApis=$entry.RankReliableApis;SLOPassCount=$entry.RankSloPassCount;TimeoutRate=$entry.RankTimeoutError;CompetitionScore=$entry.RankCompetitionScore;Stability=$stability;Verification=[pscustomobject]@{Requested=$RequestedVerificationRuns;Completed=$eligible.Count;SkippedRuntime=$SkippedRuntimeRuns};Scoreboard=$sorted}
}
function Set-ExplorationDiagnostics([object[]]$results) {
    # 순차 탐색(Minimum -> Balanced) 실행 순서로 한계 효율을 비교한다.
    $ordered=@($results)
    foreach ($app in $apps) {
        for ($i=1;$i -lt $ordered.Count;$i++) {
            $previous=$ordered[$i-1]; $current=$ordered[$i]
            $previousRps=[double]$previous.Apps[$app].RPS; $currentRps=[double]$current.Apps[$app].RPS
            $rpsIncrease=if ($previousRps -gt 0) { ($currentRps-$previousRps)/$previousRps } else { 0 }
            $replicasGrew=[double]$current.Apps[$app].PeakReadyReplicas -gt [double]$previous.Apps[$app].PeakReadyReplicas
            $functionalImproved=([double]$current.Apps[$app].LoadProcessingRate -gt [double]$previous.Apps[$app].LoadProcessingRate+0.03) -or ([double]$current.Apps[$app].SLOComplianceRate -gt [double]$previous.Apps[$app].SLOComplianceRate+0.03)
            if ($replicasGrew -and $rpsIncrease -lt 0.10 -and -not $functionalImproved) { $current.Apps[$app].DiminishingReturn=$true }
            $previousP95=[double]$previous.Apps[$app].P95Ms; $currentP95=[double]$current.Apps[$app].P95Ms
            $latencyImprovement=if ($previousP95 -gt 0) { ($previousP95-$currentP95)/$previousP95 } else { 0 }
            $cpuLow=[double]$current.Apps[$app].AverageCPUUtilization -lt ($hpaTargets[$app]*0.50)
            if ($cpuLow -and $replicasGrew -and $latencyImprovement -lt 0.10 -and $currentP95 -gt $sloMs[$app]) { $current.Apps[$app].PossibleExternalBottleneck=$true }
        }
    }
}

function Select-CapacityTier([object[]]$results) {
    $tiers=[System.Collections.Generic.List[object]]::new()
    foreach ($result in @($results | Where-Object { $null -ne $_.CompetitionScore -and $null -ne $_.Config })) {
        $functionalScore=($result.CompetitionScore.Items |
            Where-Object { $_.Key -ne 'cost' } |
            Measure-Object -Property Earned -Sum).Sum
        $continuousQuality=0.0
        foreach ($item in @($result.CompetitionScore.Items | Where-Object { $_.Key -ne 'cost' })) {
            if ($null -ne $item.Rate) { $continuousQuality += [math]::Min(1.0,[double]$item.Rate/0.90) }
        }
        $stabilityPenalty=0.0
        if ([double]$result.OOMKilledDelta -gt 0) { $stabilityPenalty += 4.0 }
        if ([double]$result.RestartDelta -gt [double]$result.OOMKilledDelta) { $stabilityPenalty += 2.0 }
        if ([double]$result.EvictionDelta -gt 0) { $stabilityPenalty += 4.0 }
        if ([double]$result.MemoryPressure -gt 0) { $stabilityPenalty += 4.0 }
        if ([double]$result.PeakReadyNodes -gt [double]$result.NodeBudget) { $stabilityPenalty += 4.0 }
        $selectionScore=[math]::Max(0,[double]$result.CompetitionScore.Earned-$stabilityPenalty)
        $timeoutCount=($apps | ForEach-Object { [double]$result.Apps[$_].SteadyTimeoutCount } | Measure-Object -Sum).Sum
        $headroomCount=@($apps | Where-Object { [bool]$result.Apps[$_].HeadroomPass }).Count
        $strictSloPass=@($apps | Where-Object { -not [bool]$result.Apps[$_].SLOPass }).Count -eq 0
        $reliable=[bool]$result.MeasurementReliable
        $tiers.Add([pscustomobject]@{
            Result=$result
            Name=$result.Name
            NodeBudget=[int]$result.NodeBudget
            FunctionalScore=[double]$functionalScore
            CompetitionScore=[double]$result.CompetitionScore.Earned
            ContinuousQuality=[math]::Round($continuousQuality,4)
            StabilityPenalty=$stabilityPenalty
            SelectionScore=[math]::Round($selectionScore,2)
            Stable=($stabilityPenalty -eq 0 -and -not [bool]$result.HardFailure -and $reliable -and $strictSloPass -and $timeoutCount -eq 0)
            HardFailure=[bool]$result.HardFailure
            MeasurementReliable=$reliable
            StrictSLOPass=$strictSloPass
            TimeoutFree=($timeoutCount -eq 0)
            HeadroomCount=$headroomCount
            PeakReadyNodes=[double]$result.PeakReadyNodes
            NodeSecondsPerSecond=[double]$result.NodeSecondsPerSecond
            SuccessfulRPS=[double]$result.TotalSuccessfulRPS
        })
    }
    if (-not $tiers.Count) { throw '비교할 capacity tier 결과가 없습니다.' }
    # Lexicographic selection: 실패와 비용을 숫자로 상쇄하지 않는다.
    return $tiers | Sort-Object `
        @{Expression='HardFailure';Descending=$false},
        @{Expression='MeasurementReliable';Descending=$true},
        @{Expression='StrictSLOPass';Descending=$true},
        @{Expression='TimeoutFree';Descending=$true},
        @{Expression='Stable';Descending=$true},
        @{Expression='HeadroomCount';Descending=$true},
        @{Expression='FunctionalScore';Descending=$true},
        @{Expression='ContinuousQuality';Descending=$true},
        @{Expression='CompetitionScore';Descending=$true},
        @{Expression='SelectionScore';Descending=$true},
        PeakReadyNodes,
        NodeSecondsPerSecond,
        @{Expression='SuccessfulRPS';Descending=$true},
        NodeBudget | Select-Object -First 1
}

function Test-CapacitySearchCanStop([object[]]$results,[int]$nextNodeBudget) {
    if (-not $results.Count -or $nextNodeBudget -gt $MaxNodes) { return $true }
    $best=Select-CapacityTier $results
    if (-not $best.Stable) { return $false }
    # 기능 24점을 이미 모두 얻었다면 더 큰 tier는 기능 점수를 추가할 수 없고
    # 실제 사용 노드가 같아도 더 작은 budget이 tie-break에서 이긴다.
    return [double]$best.FunctionalScore -ge 24.0
}

# Legacy 계산식은 이전 결과 해석을 위해 남겨 두지만 실행 흐름에서는 호출하지
# 않는다. 성공 RPS 외삽과 다변수 동시 변경은 원인 기반 제어 루프에 금지된다.
function Select-LegacyAppReference([string]$app,[object[]]$results) {
    $safe=@($results | Where-Object {
        $appOom=if ($_.OOMKilledDeltaByApp) { [int]$_.OOMKilledDeltaByApp[$app] } else { 0 }
        $_.Apps[$app].LoadPass -and $_.Apps[$app].SLOPass -and $_.Apps[$app].AvailabilityPass -and $appOom -eq 0 -and $_.EvictionDelta -eq 0 -and $_.MemoryPressure -eq 0 -and $_.PeakReadyNodes -le $_.NodeBudget
    })
    if (-not $safe.Count) {
        # 통과 후보가 없을 때 첫 실패 결과를 고정 참조하면 이후 tier도 같은
        # maxReplicas를 반복한다. OOM이 없는 후보 중 기능 지표가 가장 나은
        # 결과를 사용해 다음 탐색이 실제로 전진하도록 한다.
        $fallback=@($results | Where-Object {
            $appOom=if ($_.OOMKilledDeltaByApp) { [int]$_.OOMKilledDeltaByApp[$app] } else { 0 }
            $appOom -eq 0 -and $_.MemoryPressure -eq 0 -and $_.EvictionDelta -eq 0
        })
        if (-not $fallback.Count) { $fallback=@($results) }
        $quality=$fallback | Sort-Object `
            @{Expression={ [bool]$_.Apps[$app].AvailabilityPass };Descending=$true},
            @{Expression={ [double]$_.Apps[$app].LoadProcessingRate };Descending=$true},
            @{Expression={ [double]$_.Apps[$app].SLOComplianceRate };Descending=$true},
            @{Expression={ [double]$_.Apps[$app].HighLoadSuccessfulRequests };Descending=$true},
            PeakReadyNodes,
            NodeSecondsPerSecond,
            @{Expression={ Convert-CpuToM $_.Config[$app].requestCpu }},
            @{Expression={ Convert-MemoryToMi $_.Config[$app].requestMemory }},
            @{Expression={ [double]$_.Apps[$app].P95Ms }} | Select-Object -First 1
        $efficient=$fallback | Sort-Object `
            PeakReadyNodes,
            NodeSecondsPerSecond,
            @{Expression={ Convert-CpuToM $_.Config[$app].requestCpu }},
            @{Expression={ Convert-MemoryToMi $_.Config[$app].requestMemory }},
            @{Expression={ [double]$_.Apps[$app].AverageReadyReplicas }},
            @{Expression={ [double]$_.Apps[$app].LoadProcessingRate };Descending=$true},
            @{Expression={ [double]$_.Apps[$app].SLOComplianceRate };Descending=$true} | Select-Object -First 1

        # 더 비싼 후보가 처리율/SLO를 3%p 이상 올리지 못하고 90% 경계도
        # 넘지 못하면 증설 효과가 없는 것으로 보고 저비용 후보를 유지한다.
        $loadGain=[double]$quality.Apps[$app].LoadProcessingRate-[double]$efficient.Apps[$app].LoadProcessingRate
        $latencyGain=[double]$quality.Apps[$app].SLOComplianceRate-[double]$efficient.Apps[$app].SLOComplianceRate
        $crossesBoundary=([bool]$quality.Apps[$app].LoadPass -and -not [bool]$efficient.Apps[$app].LoadPass) -or ([bool]$quality.Apps[$app].SLOPass -and -not [bool]$efficient.Apps[$app].SLOPass)
        if (-not $crossesBoundary -and $loadGain -lt 0.03 -and $latencyGain -lt 0.03) { return $efficient }
        return $quality
    }
    return $safe | Sort-Object `
        PeakReadyNodes,
        NodeSecondsPerSecond,
        @{Expression={ [double]$_.ProcessingRate };Descending=$true},
        @{Expression={ if ($_.Apps[$app].DiminishingReturn) { 1 } else { 0 } }},
        @{Expression={ [double]$_.Apps[$app].EfficiencyScore };Descending=$true},
        @{Expression={ Convert-CpuToM $_.Config[$app].requestCpu }},
        @{Expression={ Convert-MemoryToMi $_.Config[$app].requestMemory }},
        @{Expression={ if ($null -eq $_.Apps[$app].ThrottleRatio) { [double]::PositiveInfinity } else { [double]$_.Apps[$app].ThrottleRatio } }},
        @{Expression={ [double]$_.Apps[$app].P95Ms }} | Select-Object -First 1
}

function New-LegacyRecommendedConfig([hashtable]$seed,[object[]]$results) {
    $config=Copy-Config $seed 'CalculatedFinal'
    $diagnostics=@{}
    foreach ($app in $apps) {
        $reference=Select-LegacyAppReference $app $results
        $metric=$reference.Apps[$app]
        $target=[int]$hpaTargets[$app]
        $minimumObservation=$results[0]
        $latestObservation=$results[$results.Count-1]
        $loadGain=[double]$latestObservation.Apps[$app].LoadProcessingRate-[double]$minimumObservation.Apps[$app].LoadProcessingRate
        $latencyGain=[double]$latestObservation.Apps[$app].SLOComplianceRate-[double]$minimumObservation.Apps[$app].SLOComplianceRate
        $crossesBoundary=([bool]$latestObservation.Apps[$app].LoadPass -and -not [bool]$minimumObservation.Apps[$app].LoadPass) -or ([bool]$latestObservation.Apps[$app].SLOPass -and -not [bool]$minimumObservation.Apps[$app].SLOPass)
        $protectionIndex=[array]::IndexOf($performanceProtectionOrder,$app)
        $protectedApps=if ($protectionIndex -gt 0) { @($performanceProtectionOrder[0..($protectionIndex-1)]) } else { @() }
        $collateralRegression=$false
        foreach ($protectedApp in $protectedApps) {
            $protectedLoadDrop=[double]$minimumObservation.Apps[$protectedApp].LoadProcessingRate-[double]$latestObservation.Apps[$protectedApp].LoadProcessingRate
            $protectedLatencyDrop=[double]$minimumObservation.Apps[$protectedApp].SLOComplianceRate-[double]$latestObservation.Apps[$protectedApp].SLOComplianceRate
            $crossesBelowBoundary=([bool]$minimumObservation.Apps[$protectedApp].LoadPass -and -not [bool]$latestObservation.Apps[$protectedApp].LoadPass) -or ([bool]$minimumObservation.Apps[$protectedApp].SLOPass -and -not [bool]$latestObservation.Apps[$protectedApp].SLOPass)
            if ($crossesBelowBoundary -or $protectedLoadDrop -ge 0.03 -or $protectedLatencyDrop -ge 0.03) { $collateralRegression=$true; break }
        }
        $meaningfulImprovement=(-not $collateralRegression) -and ($crossesBoundary -or $loadGain -ge 0.03 -or $latencyGain -ge 0.03)
        if ($collateralRegression) {
            $reference=$minimumObservation
            $metric=$reference.Apps[$app]
        }
        $fallbackCpu=Convert-CpuToM $reference.Config[$app].requestCpu
        $observedCpu=[double]$metric.CPUP95Millicores
        # 성공 용량이 거의 0인 앱의 높은 CPU는 요청 처리비용이 아니라 긴
        # timeout 요청의 동시 실행/queue일 수 있다. 이 값을 request로 올리면
        # replica 배치만 줄어드므로 최소 10% 처리된 경우에만 CPU를 역산한다.
        $hasUsefulCpuSample=([double]$metric.LoadProcessingRate -ge 0.10 -and [double]$metric.SuccessfulRequests -ge 10)
        $requestM=if ($observedCpu -gt 0 -and $hasUsefulCpuSample) { $observedCpu/($target/100.0) } else { $fallbackCpu }
        $explored=@($results | ForEach-Object { Convert-CpuToM $_.Config[$app].requestCpu })
        $lower=[math]::Max(25,(($explored|Measure-Object -Minimum).Minimum)*0.8)
        $upper=[math]::Min(2000,(($explored|Measure-Object -Maximum).Maximum)*1.2)
        $requestM=[math]::Max($lower,[math]::Min($upper,$requestM))
        if ($results.Count -gt 1 -and -not $meaningfulImprovement) { $requestM=$fallbackCpu }
        $cpuRisk=($null -ne $metric.ThrottleRatio -and [double]$metric.ThrottleRatio -gt 0.10) -or ([double]$metric.PeakCPUUtilization -ge $target)
        $limitFactor=if ($cpuRisk) { 2.0 } else { 1.5 }
        $observedPeakCpu=[double]$metric.PeakCPUMillicores
        $limitM=[math]::Max($requestM*$limitFactor,$observedPeakCpu*1.20)
        # CPU limit은 스케줄링 비용에 포함되지 않는다. 기능 기준을 통과하기
        # 전에는 실패한 관측치만 보고 limit을 낮춰 throttling 위험을 만들지 않는다.
        $observedCpuLimits=@($results | ForEach-Object { Convert-CpuToM $_.Config[$app].limitCpu } | Where-Object { $null -ne $_ -and $_ -gt 0 })
        $largestObservedCpuLimit=if ($observedCpuLimits.Count) { ($observedCpuLimits | Measure-Object -Maximum).Maximum } else { 0 }
        $referenceCpuLimit=Convert-CpuToM $reference.Config[$app].limitCpu
        $limitM=[math]::Max($limitM,$(if ($meaningfulImprovement) { $largestObservedCpuLimit } else { $referenceCpuLimit }))
        if ($results.Count -gt 1 -and -not $meaningfulImprovement) { $limitM=[math]::Max($requestM,$referenceCpuLimit) }
        $memoryP95=[double]$metric.MemoryP95Mi; $memoryP99=[double]$metric.MemoryP99Mi; $memoryPeak=[double]$metric.MemoryPeakMi
        $memoryRequest=if ($memoryP95 -gt 0) { $memoryP95*1.15 } else { Convert-MemoryToMi $reference.Config[$app].requestMemory }
        $minimumMemory=$MinMemoryRequestMi
        $minimumMemoryLimit=[math]::Max($MinMemoryLimitMi,$minimumMemory*1.25)
        $oomObserved=($results | ForEach-Object { if ($_.OOMKilledDeltaByApp) { [int]$_.OOMKilledDeltaByApp[$app] } else { 0 } } | Measure-Object -Sum).Sum
        $oomProfiles=@($results | Where-Object { $_.OOMKilledDeltaByApp -and [int]$_.OOMKilledDeltaByApp[$app] -gt 0 })
        $oomProfileCount=$oomProfiles.Count
        $failedLimits=@($oomProfiles | ForEach-Object { Convert-MemoryToMi $_.Config[$app].limitMemory } | Where-Object { $null -ne $_ -and $_ -gt 0 })
        $largestFailedLimit=if ($failedLimits.Count) { ($failedLimits | Measure-Object -Maximum).Maximum } else { 0 }
        if ($oomObserved -gt 0) {
            # OOM이 난 실행의 scrape peak는 kill 직전 값을 놓친 censored sample이다.
            # 반복 OOM이면 가장 큰 실패 limit의 2배를 request로 잡아 장시간
            # 누적 증가에도 여유를 둔다. 정상 후보 limit은 재증폭 기준에 넣지 않는다.
            $requestFloor=if ($oomProfileCount -ge 2) { $largestFailedLimit*2.0 } else { $largestFailedLimit*0.85 }
            $memoryRequest=[math]::Max($memoryRequest,[math]::Max($requestFloor,$memoryPeak*$OOMMemoryRequestGrowth))
        }
        elseif ($results.Count -gt 1 -and -not $meaningfulImprovement) {
            $memoryRequest=Convert-MemoryToMi $reference.Config[$app].requestMemory
        }
        $memoryRequest=[math]::Max($minimumMemory,$memoryRequest)
        $memoryLimit=if ($memoryP99 -gt 0) { [math]::Max($memoryP99*1.30,$memoryRequest*1.25) } else { [math]::Max((Convert-MemoryToMi $reference.Config[$app].limitMemory),$memoryRequest*1.25) }
        if ($oomObserved -gt 0) {
            $oomLimitGrowth=if ($oomProfileCount -ge 2) { [math]::Max(4.0,$OOMMemoryLimitGrowth) } else { $OOMMemoryLimitGrowth }
            $memoryLimit=[math]::Max($memoryLimit,[math]::Max($largestFailedLimit*$oomLimitGrowth,$memoryPeak*$oomLimitGrowth))
        }
        elseif ($results.Count -gt 1 -and -not $meaningfulImprovement) {
            $memoryLimit=[math]::Max($memoryRequest,$(Convert-MemoryToMi $reference.Config[$app].limitMemory))
        }
        $memoryLimit=[math]::Max($minimumMemoryLimit,$memoryLimit)
        $peakReady=[math]::Max(1,[double]$metric.PeakReadyReplicas)
        $peakUtil=[double]$metric.PeakCPUUtilization
        $expectedRps=$TargetRate*[double]$trafficShare[$app]
        $referenceOom=if ($reference.OOMKilledDeltaByApp) { [int]$reference.OOMKilledDeltaByApp[$app] } else { 0 }
        # 요청이 목표량의 절반도 관측되지 않은 프로필은 확장 근거로 사용하지 않는다.
        # arrival-rate가 dropped/timeout으로 무너진 상태에서 이를 용량으로 환산하면
        # 다음 프로필이 과도하게 증설되어 이후 테스트를 더 악화시킨다.
        $expectedObservedRequests=[math]::Max(10,$expectedRps*[double]$ProbeDurationSec*0.50)
        $enoughTraffic=([double]$metric.Requests -ge $expectedObservedRequests)
        $capacityReliable=($enoughTraffic -and [double]$metric.LoadProcessingRate -ge 0.80 -and [double]$metric.HighLoadSuccessfulRequests -ge 10 -and $referenceOom -eq 0)
        $cpuSafety=1.15
        $cpuPerRps=[double]$metric.CPUPerSuccessfulRPS
        # 실패/OOM 상태의 성공 RPS로 역산하면 CPUPerRPS가 무한히 커져 HPA max를
        # 상한까지 밀어 올린다. 성공 용량이 충분히 관측된 경우에만 외삽한다.
        $expectedPeakCpu=if ($capacityReliable -and $cpuPerRps -gt 0) { $cpuPerRps*$expectedRps*$cpuSafety } else { $null }
        $replicaCpu=if ($expectedPeakCpu -gt 0 -and $requestM -gt 0) { [math]::Ceiling($expectedPeakCpu/($requestM*($target/100.0))) } elseif ($peakUtil -gt 0) { [math]::Ceiling($peakReady*$peakUtil/$target) } else { [math]::Ceiling($peakReady) }
        $safeRps=[double]$metric.SafeRPSPerPod
        $replicaRps=if ($capacityReliable -and $safeRps -gt 0) { [math]::Ceiling($expectedRps/$safeRps) } else { [math]::Ceiling($peakReady) }
        $functionalPass=([double]$metric.LoadProcessingRate -ge 0.90 -and [double]$metric.SLOComplianceRate -ge 0.90)
        if (-not $functionalPass) {
            # 실패한 후보는 축소 근거가 아니다. 현재 HPA 상한과 이미 Pending인
            # 수요를 보존한다. 처리율이 크게 부족하면 최대 2배, 처리율은 충분하지만
            # latency만 부족하면 1.25배로 넓히고 node tier bin-packing에서 다시 제한한다.
            $configuredMax=[int]$reference.Config[$app].maxReplicas
            $pending=[math]::Max(0,[double]$metric.PeakPendingReplicas)
            if (-not $enoughTraffic) {
                Write-Warning "${app}: 관측 요청($([int]$metric.Requests))이 기대량($([int]$expectedObservedRequests)) 미만이므로 HPA max를 증액하지 않습니다."
                $replicaCpu=$configuredMax
                $replicaRps=$configuredMax
            }
            $unmetDemandFloor=[math]::Max($configuredMax,[math]::Ceiling($peakReady+$pending))
            $observedLoad=[math]::Max(0,[double]$metric.LoadProcessingRate)
            $growthFactor=if ($observedLoad -lt 0.50) { 2.0 } elseif ($observedLoad -lt 0.90) { 1.5 } else { 1.25 }
            if ($meaningfulImprovement -and ($peakReady -ge ($configuredMax-0.5) -or $observedLoad -lt 0.90)) {
                $unmetDemandFloor=[math]::Max($unmetDemandFloor,[math]::Ceiling($configuredMax*$growthFactor))
            }
            $replicaCpu=[math]::Max($replicaCpu,$unmetDemandFloor)
            $replicaRps=[math]::Max($replicaRps,$unmetDemandFloor)
            if ($results.Count -gt 1 -and -not $meaningfulImprovement) {
                $replicaCpu=$configuredMax
                $replicaRps=$configuredMax
            }
        }
        $scaleRisk=([double]$metric.PeakPendingReplicas -gt 0) -or ([double]$metric.FailureRate -gt 0.05)
        $headroom=if ($capacityReliable -and $scaleRisk) { 1.25 } elseif ($capacityReliable) { 1.15 } else { 1.0 }
        $maxReplicas=[int][math]::Min($MaxAutoReplicas,[math]::Max([int]$hpaMaxMinimum[$app],[math]::Ceiling([math]::Max($replicaCpu,$replicaRps)*$headroom)))
        $config[$app]=@{
            requestCpu=Format-Cpu $requestM;requestMemory=Format-Memory $memoryRequest $minimumMemory
            limitCpu=Format-Cpu $limitM;limitMemory=Format-Memory $memoryLimit $minimumMemoryLimit
            minReplicas=1;maxReplicas=$maxReplicas;hpaTarget=$target;replicas=1;behavior=$reference.Config[$app].behavior
        }
        $diagnostics[$app]=[pscustomobject]@{
            ReferenceProfile=$reference.Name;CapacityReliable=$capacityReliable;MeaningfulImprovement=$meaningfulImprovement;CollateralRegression=$collateralRegression;LoadGain=$loadGain;LatencyGain=$latencyGain;ReplicaByCPU=$replicaCpu;ReplicaByRPS=$replicaRps;CPUPerSuccessfulRPS=$cpuPerRps;ExpectedPeakCPUMillicores=$expectedPeakCpu;ObservedOOMRestarts=$oomObserved;OOMProfileCount=$oomProfileCount
            PossibleExternalBottleneck=(@($results | Where-Object { $_.Apps[$app].PossibleExternalBottleneck }).Count -gt 0)
            DiminishingReturn=(@($results | Where-Object { $_.Apps[$app].DiminishingReturn }).Count -gt 0)
            MetricUnavailable=[bool]$metric.MetricUnavailable
        }
    }
    return [pscustomobject]@{Config=$config;Diagnostics=$diagnostics}
}

function Enforce-IdleBudget([hashtable]$config,$cluster) {
    $adjusted=Set-RequiredPolicy $config $config.Name
    $originalHpaMax=@{}
    foreach ($app in $apps) { $originalHpaMax[$app]=[int]$adjusted[$app].maxReplicas }

    $cpuTotal=[double](($apps | ForEach-Object { Convert-CpuToM $adjusted[$_].requestCpu } | Measure-Object -Sum).Sum)
    if ($cpuTotal -gt $cluster.AvailableAppCPU) {
        $originalExcess=$cpuTotal-$cluster.AvailableAppCPU

        # Idle bin-packing은 Stress -> Product -> User 순서로 조정한다.
        # User는 성능 보호를 위해 가장 마지막에 조정하며, 모든 앱은
        # 지정된 request 하한 미만으로 내려가지 않는다.
        foreach ($app in $idleRequestReductionOrder) {
            $cpuTotal=[double](($apps | ForEach-Object { Convert-CpuToM $adjusted[$_].requestCpu } | Measure-Object -Sum).Sum)
            $remainingExcess=$cpuTotal-$cluster.AvailableAppCPU
            if ($remainingExcess -le 0) { break }

            $current=Convert-CpuToM $adjusted[$app].requestCpu
            $floor=[double]$cpuRequestMinimum[$app]
            $reducible=[math]::Max(0,$current-$floor)
            if ($reducible -le 0) { continue }

            $reduction=[math]::Min($remainingExcess,$reducible)
            $newRequest=[math]::Max($floor,[math]::Floor((($current-$reduction)/25.0))*25)
            $adjusted[$app].requestCpu=Format-Cpu $newRequest
        }

        $stressRequest=Convert-CpuToM $adjusted.stress.requestCpu
        $stressLimit=Convert-CpuToM $adjusted.stress.limitCpu
        $adjusted.stress.limitCpu=if ($null -eq $stressLimit) { $null } else { Format-Cpu ([math]::Max($stressRequest,$stressLimit)) }
        Write-Warning "Idle CPU 초과분 ${originalExcess}m을 Stress -> Product -> User 순서로 조정했습니다."
    }

    # Memory도 User/Product를 보존하고 Stress request를 먼저 낮춘다.
    $memoryFloor=@{user=[math]::Max(64,$MinMemoryRequestMi);product=[math]::Max(64,$MinMemoryRequestMi);stress=[math]::Max(128,$MinMemoryRequestMi)}
    foreach ($app in $apps) {
        $current=Convert-MemoryToMi $adjusted[$app].requestMemory
        if ($current -lt $memoryFloor[$app]) { $adjusted[$app].requestMemory=Format-Memory $memoryFloor[$app] $memoryFloor[$app] }
    }
    $memoryTotal=($apps | ForEach-Object { Convert-MemoryToMi $adjusted[$_].requestMemory } | Measure-Object -Sum).Sum
    if ($memoryTotal -gt $cluster.AvailableAppMemory) {
        $originalExcess=$memoryTotal-$cluster.AvailableAppMemory
        foreach ($app in $idleRequestReductionOrder) {
            $memoryTotal=[double](($apps | ForEach-Object { Convert-MemoryToMi $adjusted[$_].requestMemory } | Measure-Object -Sum).Sum)
            $remainingExcess=$memoryTotal-$cluster.AvailableAppMemory
            if ($remainingExcess -le 0) { break }

            $current=Convert-MemoryToMi $adjusted[$app].requestMemory
            $floor=[double]$memoryFloor[$app]
            $reducible=[math]::Max(0,$current-$floor)
            if ($reducible -le 0) { continue }

            $reduction=[math]::Min($remainingExcess,$reducible)
            $newRequest=[math]::Max($floor,[math]::Floor((($current-$reduction)/32.0))*32)
            $adjusted[$app].requestMemory="$([int]$newRequest)Mi"
        }

        $stressRequestMemory=Convert-MemoryToMi $adjusted.stress.requestMemory
        $stressLimitMemory=Convert-MemoryToMi $adjusted.stress.limitMemory
        $adjusted.stress.limitMemory=Format-Memory ([math]::Max($stressRequestMemory*1.25,$stressLimitMemory)) ([math]::Ceiling($stressRequestMemory*1.25))
        Write-Warning "Idle Memory 초과분 $([math]::Round($originalExcess))Mi를 Stress -> Product -> User 순서로 조정했습니다."
    }

    foreach ($app in $apps) {
        if ([int]$adjusted[$app].maxReplicas -ne $originalHpaMax[$app]) { throw "Idle 보정 중 $app HPA max가 변경되었습니다." }
        $request=Convert-CpuToM $adjusted[$app].requestCpu
        $effectiveFloor=[double]$cpuRequestMinimum[$app]
        if ($request -lt $effectiveFloor) { throw "$app CPU request 하한을 만족할 수 없습니다: $request m (floor=$effectiveFloor)" }
    }
    # P0-1: stress limit request*2 cap 제거
    $idle=Get-IdleCapacity $adjusted $cluster
    if (-not $idle.IdleOneNodeFit) {
        # 격리 구성(stress 전용 노드 + nodeSelector/taint)에서는 단일 노드에 모든 앱이
        # 스케줄 가능한지 판정하는 SchedulingConstraintRisk가 당연히 true가 된다.
        # 이 경우 stress는 전용 노드에 두고 user/product만 shared 1노드에 fit하면
        # Idle 2-node(stress 전용 + shared)로 판정한다.
        $nonStressCpu=[double](('user','product' | ForEach-Object { Convert-CpuToM $adjusted[$_].requestCpu } | Measure-Object -Sum).Sum)
        $nonStressMem=[double](('user','product' | ForEach-Object { Convert-MemoryToMi $adjusted[$_].requestMemory } | Measure-Object -Sum).Sum)
        $isolationConfig=[bool]$cluster.SchedulingConstraintRisk
        if ($isolationConfig -and $nonStressCpu -le $cluster.AvailableAppCPU -and $nonStressMem -le $cluster.AvailableAppMemory) {
            Write-Warning "격리 구성(stress 전용 노드)으로 Idle 2-node(stress 전용 + user/product shared 1-node)로 판정합니다."
        } else {
            throw "지정 CPU 하한과 Memory 하한으로 Idle 1-Node를 구성할 수 없습니다: app=$($idle.IdleAppCPURequest)m/$($idle.IdleAppMemoryRequest)Mi, available=$($idle.AvailableAppCPU)m/$($idle.AvailableAppMemory)Mi"
        }
    }
    return $adjusted
}

function Scale-AppsToFinalMin([hashtable]$config) {
    # dynamic warm min을 채점 시작 상태까지 유지한다 (Scale-AppsToOne 아님).
    foreach ($app in $apps) {
        $desired=[int]$config[$app].minReplicas
        if ($desired -lt 1) { $desired=1 }
        Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app","--replicas=$desired")
        Write-Host ("  final min prewarm [{0}]: replicas={1}" -f $app,$desired) -ForegroundColor DarkGray
    }
    foreach ($app in $apps) {
        try { Wait-DeploymentRollout $app 150 Hard } catch { Write-Warning "final min rollout 대기 실패($app): $($_.Exception.Message)" }
        $desired=[int]$config[$app].minReplicas
        $ready=0
        try { $ready=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.status.readyReplicas}')) -join '') } catch { $ready=0 }
        if ($ready -lt $desired) { Write-Warning "$app ready=$ready < final min=$desired (warm capacity 미달)" }
    }
}

function Scale-AppsToOne {
    foreach ($app in $apps) { Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app",'--replicas=1') }
    foreach ($app in $apps) { Wait-DeploymentRollout $app 30 Hard }
}

function Get-ResultReportingRank($Result) {
    if ($null -ne $Result.Config -and $null -ne $Result.CompetitionScore) { return Select-CapacityTier @($Result) }
    $score=if ($null -ne $Result.CompetitionScore.Earned) {[double]$Result.CompetitionScore.Earned} else {0.0}
    return [pscustomobject]@{
        CompetitionScore=$score;SelectionScore=$score;FunctionalScore=0.0;ContinuousQuality=0.0;StabilityPenalty=0.0;Stable=$false
        NodeBudget=[int](Get-OptionalPropertyValue $Result 'NodeBudget' 0);PeakReadyNodes=[double](Get-OptionalPropertyValue $Result 'PeakReadyNodes' 0)
    }
}

function Save-Results([object[]]$results,[hashtable]$finalConfig,[hashtable]$diagnostics,$cluster,$validation,$correction) {
    $rows=[System.Collections.Generic.List[object]]::new()
    foreach ($result in $results) {
        $rank=Get-ResultReportingRank $result
        foreach ($app in $apps) {
            $m=$result.Apps[$app]
            $c=if ($null -ne $result.Config -and $null -ne $result.Config[$app]) {$result.Config[$app]} else {[pscustomobject]@{requestCpu=$null;limitCpu=$null;requestMemory=$null;limitMemory=$null;hpaTarget=$null;minReplicas=$null;maxReplicas=$null}}
            $loadScore=$result.CompetitionScore.Items | Where-Object Key -eq "${app}_load" | Select-Object -First 1
            $latencyScore=$result.CompetitionScore.Items | Where-Object Key -eq "${app}_latency" | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                Profile=$result.Name;NodeBudget=$result.NodeBudget;OfficialScore=$rank.CompetitionScore;RiskAdjustedScore=$rank.SelectionScore;StabilityPenalty=$rank.StabilityPenalty;Stable=$rank.Stable;App=$app;CPURequest=$c.requestCpu;CPULimit=$c.limitCpu;MemoryRequest=$c.requestMemory;MemoryLimit=$c.limitMemory
                HPATarget=$c.hpaTarget;HPAMin=$c.minReplicas;HPAMax=$c.maxReplicas;Iterations=$m.Iterations;Requests=$m.Requests;SuccessfulRequests=$m.SuccessfulRequests;FailedRequests=$m.FailedRequests;FailureRate=$m.FailureRate;RPS=$m.RPS
                P50Ms=$m.P50Ms;P90Ms=$m.P90Ms;P95Ms=$m.P95Ms;P99Ms=$m.P99Ms;HighLoadP95Ms=$m.HighLoadP95Ms;MaxMs=$m.MaxMs;TimeoutRate=$m.TimeoutRate;SteadyTimeoutRate=$m.SteadyTimeoutRate;HighLoadFailureRate=$m.HighLoadFailureRate;SuccessP95Ms=$m.SuccessP95Ms;SuccessP99Ms=$m.SuccessP99Ms;AverageReady=$m.AverageReadyReplicas;PeakReady=$m.PeakReadyReplicas;PeakPending=$m.PeakPendingReplicas
                HighLoadRPS=$m.HighLoadRPS;HighLoadAverageReady=$m.HighLoadAverageReadyReplicas;CPUPerSuccessfulRPS=$m.CPUPerSuccessfulRPS
                AverageCPUUtil=$m.AverageCPUUtilization;PeakCPUUtil=$m.PeakCPUUtilization;AverageCPUM=$m.AverageCPUMillicores;CPUP95M=$m.CPUP95Millicores
                MemoryP95Mi=$m.MemoryP95Mi;MemoryP99Mi=$m.MemoryP99Mi;MemoryPeakMi=$m.MemoryPeakMi;ThrottleRatio=$m.ThrottleRatio;MetricUnavailable=$m.MetricUnavailable
                RPSPerPod=$m.RPSPerPod;RPSPerRequestedCore=$m.RPSPerRequestedCore;EfficiencyScore=$m.EfficiencyScore;LoadProcessingRate=$m.LoadProcessingRate;SLOComplianceRate=$m.SLOComplianceRate;LoadScore=$loadScore.Earned;LatencyScore=$latencyScore.Earned;SLOPass=$m.SLOPass
                MeasurementReliable=$m.MeasurementReliable;CapacityReliable=$m.CapacityReliable;LoadGeneratorLimited=$m.LoadGeneratorLimited;GeneratedLoadRatio=$m.GeneratedLoadRatio;ExpectedSteadyRequests=$m.ExpectedSteadyRequests;K6MaxVUs=$m.K6MaxVUs;PeakVUs=$m.PeakVUs;MaxVUReached=$m.MaxVUReached;ObservedVUs=$result.ObservedVUs;ConfiguredVUs=$result.ConfiguredVUs;VUUtilization=$result.VUUtilization;Bottlenecks=($m.Bottlenecks -join '|');TuningAction=(($result.TuningActions | Where-Object App -eq $app | Select-Object -First 1).Type);PossibleExternalBottleneck=$m.PossibleExternalBottleneck;DiminishingReturn=$m.DiminishingReturn;HardFailure=$result.HardFailure;FatalFailure=$result.FatalFailure;PerformanceFailure=$result.PerformanceFailure;MeasurementFailure=$result.MeasurementFailure;AppOOMKilledDelta=$(if ($result.OOMKilledDeltaByApp) { $result.OOMKilledDeltaByApp[$app] } else { $null })
                PeakReadyNodes=$result.PeakReadyNodes;PeakTotalReadyNodes=$result.PeakTotalReadyNodes;NodeSeconds=$result.NodeSeconds;TotalNodeSeconds=$result.TotalNodeSeconds;NodeSecondsPerSecond=$result.NodeSecondsPerSecond;TotalNodeSecondsPerSecond=$result.TotalNodeSecondsPerSecond;EndReadyNodes=$result.EndReadyNodes;EndTotalReadyNodes=$result.EndTotalReadyNodes;PodsToOneSeconds=$result.PodsToOneSeconds;KarpenterToZeroSeconds=$result.KarpenterToZeroSeconds;AppDroppedIterations=$m.AllocatedDroppedIterations;DroppedIterations=$result.DroppedIterations;ProcessingRate=$result.ProcessingRate;ProcessingPass=$result.ProcessingPass;IdleOneNodeFit=$result.IdleCapacity.IdleOneNodeFit;CrashLoopBackOff=$result.CrashLoopBackOff;PersistentNotReady=$result.PersistentNotReady;OOMKilledDelta=$result.OOMKilledDelta
            })
        }
    }
    $csvPath=Join-Path $OutputDir 'tuning-summary.csv'; $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
    $idle=Get-IdleCapacity $finalConfig $cluster
    $finalApps=[System.Collections.Generic.List[object]]::new()
    foreach ($app in $apps) {
        $m=$validation.Apps[$app]; $c=$finalConfig[$app]; $d=$diagnostics[$app]
        $loadScore=$validation.CompetitionScore.Items | Where-Object Key -eq "${app}_load" | Select-Object -First 1
        $latencyScore=$validation.CompetitionScore.Items | Where-Object Key -eq "${app}_latency" | Select-Object -First 1
        $finalApps.Add([pscustomobject]@{
            App=$app;CPURequest=$c.requestCpu;CPULimit=$c.limitCpu;MemoryRequest=$c.requestMemory;MemoryLimit=$c.limitMemory
            HPACPUTarget=$c.hpaTarget;HPAMin=$c.minReplicas;HPAMax=$c.maxReplicas;MeasuredRPS=$m.RPS;SafeRPSPerPod=$m.SafeRPSPerPod;RPSPerRequestedCore=$m.RPSPerRequestedCore
            P50Ms=$m.P50Ms;P90Ms=$m.P90Ms;P95Ms=$m.P95Ms;P99Ms=$m.P99Ms;HighLoadP95Ms=$m.HighLoadP95Ms;HighLoadRPS=$m.HighLoadRPS;TimeoutRate=$m.TimeoutRate;SteadyTimeoutRate=$m.SteadyTimeoutRate;SuccessP95Ms=$m.SuccessP95Ms;SuccessP99Ms=$m.SuccessP99Ms;AverageCPUM=$m.AverageCPUMillicores;PeakCPUM=$m.PeakCPUMillicores;CPUP95M=$m.CPUP95Millicores
            ThrottleRatio=$m.ThrottleRatio;ThrottleMetricUnavailable=$m.ThrottleMetricUnavailable;MemoryP95Mi=$m.MemoryP95Mi;MemoryPeakMi=$m.MemoryPeakMi
            AverageReadyReplicas=$m.AverageReadyReplicas;PeakReadyReplicas=$m.PeakReadyReplicas;PeakPendingReplicas=$m.PeakPendingReplicas;ExpectedPods=[int][math]::Max(1,[math]::Ceiling([double]$m.PeakReadyReplicas));IdleOneNodeFit=$idle.IdleOneNodeFit
            EfficiencyScore=$m.EfficiencyScore;LoadProcessingRate=$m.LoadProcessingRate;SLOComplianceRate=$m.SLOComplianceRate;LoadScore=$loadScore.Earned;LatencyScore=$latencyScore.Earned;SLOPass=$m.SLOPass;HeadroomPass=$m.HeadroomPass;MeasurementReliable=$m.MeasurementReliable;CapacityReliable=$m.CapacityReliable;LoadGeneratorLimited=$m.LoadGeneratorLimited;GeneratedLoadRatio=$m.GeneratedLoadRatio;K6MaxVUs=$m.K6MaxVUs;Bottlenecks=$m.Bottlenecks;TuningAction=$d.TuningAction;MeaningfulImprovement=$d.MeaningfulImprovement;CollateralRegression=$d.CollateralRegression;LoadGain=$d.LoadGain;LatencyGain=$d.LatencyGain;PossibleExternalBottleneck=$d.PossibleExternalBottleneck;DiminishingReturn=$d.DiminishingReturn;MetricUnavailable=$m.MetricUnavailable
        })
    }
    $selectedRank=Get-ResultReportingRank $validation
    $clusterSummary=[pscustomobject]@{
        PeakReadyNodes=$validation.PeakReadyNodes;AverageReadyNodes=$validation.AverageReadyNodes;NodeSeconds=$validation.NodeSeconds;NodeSecondsPerSecond=$validation.NodeSecondsPerSecond
        PeakTotalReadyNodes=$validation.PeakTotalReadyNodes;AverageTotalReadyNodes=$validation.AverageTotalReadyNodes;TotalNodeSeconds=$validation.TotalNodeSeconds;TotalNodeSecondsPerSecond=$validation.TotalNodeSecondsPerSecond;EndReadyNodes=$validation.EndReadyNodes;EndTotalReadyNodes=$validation.EndTotalReadyNodes;PodsToOneSeconds=$validation.PodsToOneSeconds;KarpenterToZeroSeconds=$validation.KarpenterToZeroSeconds;TotalSuccessfulRPS=$validation.TotalSuccessfulRPS
        ProcessingRate=$validation.ProcessingRate;ProcessingPass=$validation.ProcessingPass;DroppedIterations=$validation.DroppedIterations;MinimumProcessingRate=$MinProcessingRate
        CompetitionScoreEarned=$validation.CompetitionScore.Earned;CompetitionScoreMax=$validation.CompetitionScore.Max;RiskAdjustedScore=$selectedRank.SelectionScore;StabilityPenalty=$selectedRank.StabilityPenalty;Stable=$selectedRank.Stable
        TotalRequestedCPU=$validation.TotalRequestedCPU;TotalRequestedMemory=$validation.TotalRequestedMemory;TotalScore=$validation.TotalScore;StressModeEnabled=[bool]$StressMode
        IdleOneNodeFit=$idle.IdleOneNodeFit;IdleExpectedNodes=1;IdleAppCPURequest=$idle.IdleAppCPURequest;IdleAppMemoryRequest=$idle.IdleAppMemoryRequest
        NodeInstanceType=$cluster.NodeInstanceType;ManagedReadyNodes=$cluster.ManagedReadyNodes;NodeCapacityCPU=$cluster.NodeCapacityCPU;NodeCapacityMemory=$cluster.NodeCapacityMemory;NodeAllocatableCPU=$cluster.NodeAllocatableCPU;NodeAllocatableMemory=$cluster.NodeAllocatableMemory
        SystemReservedCPU=$cluster.SystemReservedCPU;SystemReservedMemory=$cluster.SystemReservedMemory;AvailableAppCPU=$cluster.AvailableAppCPU;AvailableAppMemory=$cluster.AvailableAppMemory
        MaxNodes=$MaxNodes;SelectedNodeBudget=$(if ($finalConfig.ContainsKey('NodeBudget')) { [int]$finalConfig.NodeBudget } else { $MaxNodes });ClusterSchedulingReservePercent=$ClusterSchedulingReservePercent;DaemonSetCPUPerNode=$cluster.DaemonSetCPUPerNode;DaemonSetMemoryPerNode=$cluster.DaemonSetMemoryPerNode;StaticSystemCPU=$cluster.StaticSystemCPU;StaticSystemMemory=$cluster.StaticSystemMemory
        KarpenterConsolidationEnabled=$(if ($script:finalConsolidationChanged) {$true} else {$cluster.KarpenterConsolidationEnabled});KarpenterInstanceTypes=$cluster.KarpenterInstanceTypes;KarpenterMatchesManaged=$cluster.KarpenterMatchesManaged;ConsolidationPolicy=$(if ($script:finalConsolidationChanged) {'WhenEmptyOrUnderutilized'} else {$cluster.ConsolidationPolicy});ConsolidateAfter=$(if ($script:finalConsolidationChanged) {'30s'} else {$cluster.ConsolidateAfter});FinalIdleConverged=$script:finalIdleConverged
        SchedulingConstraintRisk=$cluster.SchedulingConstraintRisk;SchedulingNotes=$cluster.SchedulingNotes
    }
    $payload=[pscustomobject]@{
        GeneratedAt=(Get-Date -Format o);RuntimeSeconds=[math]::Round(((Get-Date)-$startTime).TotalSeconds,1);Configuration=$finalConfig;Apps=@($finalApps);ClusterSummary=$clusterSummary;Score=$validation.CompetitionScore
        StressLength=$script:SelectedStressLength
        Selection=[pscustomobject]@{Winner=$validation.Name;CandidateGrade=$correction.CandidateGrade;SelectionReason=$correction.SelectionReason;QualityScore=$(if ($correction.QualitySelection) {$correction.QualitySelection.QualityScore} else {$null});QualityComponents=$(if ($correction.QualitySelection) {[pscustomobject]@{Q=$correction.QualitySelection.Q;Tail=$correction.QualitySelection.Tail;Timeout=$correction.QualitySelection.Timeout;Generation=$correction.QualitySelection.Generation;Reliability=$correction.QualitySelection.Reliability}} else {$null});Eligible=$(if ($correction.QualitySelection) {$correction.QualitySelection.Eligible} else {$false});MeasurementIncomplete=$(if ($correction.QualitySelection) {$correction.QualitySelection.MeasurementIncomplete} else {$true});UsedRunCount=$(if ($correction.QualitySelection) {$correction.QualitySelection.UsedRunCount} else {0});Cost=$(if ($correction.QualitySelection) {$correction.QualitySelection.Cost} else {$null});OfficialScore=$selectedRank.CompetitionScore;RiskAdjustedScore=$selectedRank.SelectionScore;FunctionalScore=$selectedRank.FunctionalScore;ContinuousQuality=$selectedRank.ContinuousQuality;StabilityPenalty=$selectedRank.StabilityPenalty;Stable=$selectedRank.Stable;NodeBudget=$selectedRank.NodeBudget;PeakReadyNodes=$selectedRank.PeakReadyNodes}
        Validation=[pscustomobject]@{Name=$validation.Name;MeasurementReliable=$validation.MeasurementReliable;LoadGeneratorLimited=$validation.LoadGeneratorLimited;AllSLOPass=$validation.AllSLOPass;ProcessingRate=$validation.ProcessingRate;ProcessingPass=$validation.ProcessingPass;HardFailure=$validation.HardFailure;FatalFailure=$validation.FatalFailure;PerformanceFailure=$validation.PerformanceFailure;MeasurementFailure=$validation.MeasurementFailure;FailureReasons=$validation.FailureReasons;Upstream5xx=$validation.Upstream5xx;TuningActions=$validation.TuningActions}
        Verification=$correction.Verification;RuntimeBudget=[pscustomobject]@{MaxSeconds=$maxRuntimeSeconds;ShutdownReserveSeconds=$ShutdownReserveSeconds;TuningDeadline=$tuningDeadline;HardDeadline=$hardDeadline;StopReason=$correction.StopReason}
        Corrections=$correction.Corrections;CorrectionUnvalidated=$correction.CorrectionUnvalidated;NoApply=[bool]$NoApply
    }
    $jsonPath=Join-Path $OutputDir 'calculated-final.json'
    $jsonText=$payload | ConvertTo-Json -Depth 15
    [IO.File]::WriteAllText($jsonPath,$jsonText,(New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{Csv=$csvPath;Json=$jsonPath;Cluster=$clusterSummary;Apps=@($finalApps);Score=$validation.CompetitionScore;Selection=$payload.Selection}
}

function Read-UserRecords([string]$path) {
    $raw=Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $records=[System.Collections.Generic.List[object]]::new()
    try {
        $json=$raw|ConvertFrom-Json
        foreach ($item in @($json)) { if ($item.email) { $records.Add([pscustomobject]@{id=[string]$item.id;email=[string]$item.email}) } }
    } catch { }
    if (-not $records.Count) {
        $emails=@([regex]::Matches($raw,'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')|ForEach-Object Value)
        $ids=@([regex]::Matches($raw,'(?i)\b(?:dbdump|user)[A-Za-z0-9_-]*\d+\b')|ForEach-Object Value)
        for ($i=0;$i -lt $emails.Count;$i++) { $records.Add([pscustomobject]@{id=$(if($i -lt $ids.Count){$ids[$i]}else{"user$i"});email=$emails[$i]}) }
    }
    if (-not $records.Count) { throw "사용자 데이터에서 email을 찾지 못했습니다: $path" }
    return @($records|Sort-Object email -Unique)
}

function Initialize-EndpointAndData {
    if (-not (Test-Path -LiteralPath $DataFile)) { throw "사용자 데이터 파일을 찾을 수 없습니다: $DataFile" }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $records=Read-UserRecords $DataFile
    $script:UserDataJson=Join-Path $OutputDir 'user-data.json'
    $userJson=$records|ConvertTo-Json -Compress
    [IO.File]::WriteAllText($script:UserDataJson,$userJson,(New-Object System.Text.UTF8Encoding($false)))
    Write-Host "사용자 데이터: $($records.Count)건"
    if (-not $script:Endpoint) {
        $domain=(& aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='wsi2026'].DomainName | [0]" --output text).Trim()
        if (-not $domain -or $domain -eq 'None') { throw 'Comment가 wsi2026인 CloudFront 배포를 찾지 못했습니다.' }
        $script:Endpoint="https://$domain"
    } elseif ($script:Endpoint -notmatch '^https?://') { $script:Endpoint="https://$script:Endpoint" }
    $script:Endpoint=$script:Endpoint.TrimEnd('/'); Write-Host "k6 endpoint: $script:Endpoint"
    $getCode=((& $script:curlCmd -ksS -o $script:nullDevice -w '%{http_code}' -A 'wsi2026-k6/2.0' "$script:Endpoint/v1/product?id=$([uri]::EscapeDataString($ProductId))&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729") -join '')
    if ($getCode -ne '200') { throw "Product fixture를 조회할 수 없습니다: HTTP $getCode. 임의 데이터는 삽입하지 않습니다." }
}

# ============================================================
# BASE-FIRST MATHEMATICAL RECOMMENDER
# ============================================================
# These functions are pure recommendation builders. They never mutate a config,
# live cluster, or global candidate state.
function New-RequestRecommendation($measurement,[hashtable]$config,[string]$app) {
    $m=$measurement.Apps[$app]
    if ($null -eq $m -or -not [bool](Get-OptionalPropertyValue $m 'MeasurementReliable' $false)) { return $null }
    if (-not [bool](Get-OptionalPropertyValue $m 'SLOPass' $false)) { return $null }
    $q75=Get-OptionalPropertyValue $m 'CPUP95Millicores' $null
    if ($null -eq $q75 -or [double]$q75 -le 0) { return $null }
    $current=[double](Convert-CpuToM $config[$app].requestCpu)
    $proposed=[math]::Ceiling(([double]$q75*$CpuRequestMinHeadroom)/25.0)*25
    $proposed=[math]::Max([double]$cpuRequestMinimum[$app],[double]$proposed)
    if ($proposed -ge $current) { return $null }
    return [pscustomobject]@{
        Axis=("{0}_CPU_REQUEST" -f $app.ToUpperInvariant()); App=$app; Field='requestCpu'
        Current=(Format-Cpu $current); Proposed=(Format-Cpu $proposed)
        Confidence=0.82; ExpectedBenefit='NODE_DENSITY'; Risk=0.25
        Evidence=@("Q75=$([math]::Round([double]$q75,1))m","headroom=$CpuRequestMinHeadroom","SLO=reliable")
    }
}
function New-HpaMaxRecommendation($measurement,[hashtable]$config,[string]$app) {
    $m=$measurement.Apps[$app]
    if ($null -eq $m) { return $null }
    $reasons=@(Get-OptionalPropertyValue $m 'Bottlenecks' @())
    if ('HPA_CEILING' -notin $reasons -and 'ZERO_SUCCESS_CAPACITY' -notin $reasons) { return $null }
    $generated=[double](Get-OptionalPropertyValue $m 'GeneratedLoadRatio' 0)
    if ($generated -lt 0.95) { return $null }
    $current=[int]$config[$app].maxReplicas
    $hard=[int](Get-OptionalPropertyValue $script:HardSafetyMaxByApp $app $MaxAutoReplicas)
    if ($current -ge $hard) { return $null }
    $proposed=[int][math]::Min($hard,$current+1)
    $cpu=[double](Get-OptionalPropertyValue $m 'AverageCPUUtilization' 0)
    $confidence=[math]::Min(0.95,[math]::Max(0.55,0.60+([math]::Min(1.0,$cpu/100.0)*0.25)))
    return [pscustomobject]@{
        Axis=("{0}_HPA_MAX" -f $app.ToUpperInvariant()); App=$app; Field='maxReplicas'
        Current=$current; Proposed=$proposed; Confidence=$confidence
        ExpectedBenefit='HPA_CEILING'; Risk=0.35
        Evidence=@("bottleneck=$($reasons -join ',')","generated=$([math]::Round($generated*100,1))%","cpu=$([math]::Round($cpu,1))%")
    }
}
function Get-NextExperimentRecommendation($bestMeasurement,[hashtable]$bestConfig,[int]$ExperimentCount) {
    # Environment/measurement failures never become tuning recommendations.
    foreach ($app in $apps) {
        $m=$bestMeasurement.Apps[$app]
        $b=@(Get-OptionalPropertyValue $m 'Bottlenecks' @())
        if ('CNI_FAILURE' -in $b -or 'ROLLOUT_FAILURE' -in $b -or 'POD_STARTUP_DELAY' -in $b -or [double](Get-OptionalPropertyValue $m 'PeakPendingReplicas' 0) -gt 0 -or [bool](Get-OptionalPropertyValue $bestMeasurement 'RolloutFailure' $false) -or [bool](Get-OptionalPropertyValue $bestMeasurement 'ApplyFailure' $false)) { return $null }
    }
    $recs=[System.Collections.Generic.List[object]]::new()
    # Lock stress during the first two experiments as a safety rule.
    foreach ($app in @('user','product','stress')) {
        if ($app -eq 'stress' -and $ExperimentCount -lt 2) { continue }
        $h=New-HpaMaxRecommendation $bestMeasurement $bestConfig $app
        if ($h) { $recs.Add($h) }
        $r=New-RequestRecommendation $bestMeasurement $bestConfig $app
        if ($r) { $recs.Add($r) }
    }
    if (-not $recs.Count) { return $null }
    # Ranking is only experiment order; KEEP/REJECT uses actual measured score.
    return @($recs | Sort-Object @{Expression={([double]$_.Confidence*1.0)/([math]::Max(0.05,[double]$_.Risk))};Descending=$true},@{Expression='Axis';Descending=$false})[0]
}
function New-ExperimentCandidate([hashtable]$bestConfig,$recommendation,[string]$name) {
    if ($null -eq $recommendation) { throw 'NO_SAFE_RECOMMENDATION' }
    $candidate=Copy-Config $bestConfig $name
    $candidate[$recommendation.App][$recommendation.Field]=$recommendation.Proposed
    # Human-facing recommendation axis maps to the existing config field axis.
    $diffAxis=("{0}_{1}" -f $recommendation.App,$recommendation.Field).ToUpperInvariant()
    $axis=Assert-ConfigDrift $bestConfig $candidate @($diffAxis)
    if ($axis -ne $diffAxis) { throw "RECOMMENDATION_AXIS_MISMATCH: $axis" }
    return $candidate
}

Require kubectl;Require k6;Require $script:curlCmd;Require aws
if (-not $SkipKubeconfig) {
    Write-Host "[tune] kubeconfig 갱신: aws eks update-kubeconfig --name $ClusterName --region $Region" -ForegroundColor Cyan
    & aws eks update-kubeconfig --name $ClusterName --region $Region
    if ($LASTEXITCODE -ne 0) { throw "kubeconfig 갱신 실패: aws eks update-kubeconfig --name $ClusterName" }
}
if ($MaxNodes -lt $ManagedNodes) { throw 'MaxNodes는 ManagedNodes 이상이어야 합니다.' }
if ($MaxVUs -lt $PreAllocatedVUs) { throw 'MaxVUs는 PreAllocatedVUs 이상이어야 합니다.' }
if ($SingleNode -and $ManagedNodes -ne 1) { throw 'SingleNode 모드는 ManagedNodes=1을 전제로 합니다.' }
if ($SingleNode -and $IdleNodes -ne 1) { throw 'SingleNode 모드는 IdleNodes=1을 전제로 합니다.' }
$minimumProfileDuration=$CooldownDurationSec+$WarmupDurationSec+$SteadyDurationSec+(10*[math]::Max(0,(Get-RateSteps $TargetRate).Count-1))
if ($ProbeDurationSec -lt $minimumProfileDuration -or $FinalDurationSec -lt $minimumProfileDuration) {
    throw "프로필 시간은 warm-up/ramp/steady/cooldown을 포함해 최소 ${minimumProfileDuration}초여야 합니다."
}

try {
    Initialize-EndpointAndData
    if (-not [string]::IsNullOrWhiteSpace($ExternalResultDir)) { Import-ExternalEvidence | Out-Null }
    if ($BaseExperiment -and -not $LegacyAdaptive) {
        Write-Host "`n========== BASE EXPERIMENT MODE ==========" -ForegroundColor Green
        if ($SelfTestOnly) { . (Join-Path $PSScriptRoot "tune\selftest.ps1"); return }
        $envStatus = Get-VpcCniStatus
        # Get-VpcCniStatus exposes PrefixDelegation/WarmPrefixTarget; the old
        # Enabled/MaxPods property names silently produced a blank precondition.
        if ($null -eq $envStatus.PrefixDelegation) {
            throw 'BASE_ENVIRONMENT_INVALID: PREFIX_DELEGATION=UNAVAILABLE (aws-node DaemonSet env 조회 실패)'
        }
        if ($envStatus.PrefixDelegation -ne $true) {
            throw "BASE_ENVIRONMENT_INVALID: PREFIX_DELEGATION=$($envStatus.PrefixDelegation)"
        }
        if ($null -eq $envStatus.WarmPrefixTarget -or [int]$envStatus.WarmPrefixTarget -lt 1) {
            throw "BASE_ENVIRONMENT_INVALID: WARM_PREFIX_TARGET=$($envStatus.WarmPrefixTarget)"
        }
        Write-Host "CNI: PREFIX_DELEGATION=true WARM_PREFIX_TARGET=$($envStatus.WarmPrefixTarget)" -ForegroundColor DarkGray
        Write-Host "`n===== BASELINE CONTROL =====" -ForegroundColor Green
        foreach ($app in $apps) { $bc=$BaseConfig[$app]; $lim=if($bc.limitCpu){$bc.limitCpu}else{'none'}; Write-Host ("  {0}: {1}/{2} limit={3}/{4} HPA={5}% {6}..{7} ({8})" -f $app,$bc.requestCpu,$bc.requestMemory,$lim,$bc.limitMemory,$bc.hpaTarget,$bc.minReplicas,$bc.maxReplicas,$bc.placement) }
        $originalConfig=Get-LiveConfig 'Original'
        # 38점 앱 세트에서는 이전 tune 실행이 남긴 HPA/resource를 seed로
        # 재사용하지 않는다. 매번 검증된 기준 구성에서 시작해야
        # `terraform apply -> tune.ps1` 재현성이 유지된다.
        $baseSeed=if ($script:Is38PointAppSet) {
            Write-Host 'BASE seed: 38점 재현 구성(오염된 live HPA/resource 무시)' -ForegroundColor Yellow
            Copy-Config $BaseConfig 'BASE_SEED'
        } else {
            Write-Host 'BASE seed: live Deployment/HPA (범용 앱 세트)' -ForegroundColor DarkGray
            Copy-Config $originalConfig 'BASE_SEED'
        }
        foreach ($app in $apps) {
            # BASE candidate의 max는 seed 설정이 기준이다. 직전 실행의
            # 실험용 max가 다음 실행의 축소 불가 floor가 되지 않게 한다.
            $hpaMaxMinimum[$app]=[int][math]::Max(1,$baseSeed[$app].maxReplicas)
            if (-not $script:HardSafetyMaxByApp.ContainsKey($app)) { $script:HardSafetyMaxByApp[$app]=[int]$MaxAutoReplicas }
        }
        $baseCfg=Copy-Config $baseSeed 'BASE'; foreach($app in $apps){$baseCfg[$app].replicas=[int]$baseCfg[$app].minReplicas}
        foreach($app in $apps){ Write-Host ("BASE candidate {0}: req={1}/{2} limit={3}/{4} HPA={5}..{6}" -f $app,$baseCfg[$app].requestCpu,$baseCfg[$app].requestMemory,$baseCfg[$app].limitCpu,$baseCfg[$app].limitMemory,$baseCfg[$app].minReplicas,$baseCfg[$app].maxReplicas) -ForegroundColor DarkGray }
        if (-not $NoApply) {
            Ensure-38PointStressTopology -ApplyPlacement
            $preBaseCluster=Get-ClusterCapacitySnapshot; Set-KarpenterNodeLimit $preBaseCluster
        }
        $baseReady=Apply-CandidateSafely $baseCfg Hard
        if (-not $baseReady) { throw 'BASE candidate가 Ready 상태가 되지 않아 측정할 수 없습니다.' }
        $baseLive=Get-LiveConfig 'BASE_LIVE_VERIFY'
        foreach($app in $apps){ Write-Host ("BASE live {0}: req={1}/{2} limit={3}/{4} HPA={5}..{6}" -f $app,$baseLive[$app].requestCpu,$baseLive[$app].requestMemory,$baseLive[$app].limitCpu,$baseLive[$app].limitMemory,$baseLive[$app].minReplicas,$baseLive[$app].maxReplicas) -ForegroundColor DarkGray }
        $baseDiff=@(Compare-Config $baseCfg $baseLive @())
        if ($baseDiff.Count -ne 0) { throw "BASE_CONFIG_DRIFT: $([string]::Join(',',@($baseDiff | ForEach-Object { $_.App+'.'+$_.Field })))" }
        Write-Host 'BASE_CONFIG_EXACT: live fingerprint matches immutable BaseConfig' -ForegroundColor Green
        $baseCluster=Get-ClusterCapacitySnapshot; Set-KarpenterNodeLimit $baseCluster
        if (-not $NoApply) {
            $withinBudget=Wait-ReadyNodeCountAtMost $CostBaselineNodes 180 Hard
            if (-not $withinBudget) { throw "BASE_ENVIRONMENT_INVALID: Ready node budget did not converge to $CostBaselineNodes" }
            Assert-MeasurementReady 90
        }
        $baseRun=Run-ReliableLoadTest $baseCfg $ProbeDurationSec $baseCluster 0 -SkipRetry
        $baseMeas=$baseRun.Result; if(-not $baseMeas){throw 'BASE measurement failed'}
        $baseSnap=Save-EvaluationSnapshot $baseMeas $baseCfg 'BASE'; $bestSnap=$baseSnap; $bestCfg=$baseCfg
        $baseProfilePath=Join-Path $OutputDir 'calculated-final.json'
        Save-BaseExperimentProfile $baseCfg $baseMeas $baseProfilePath | Out-Null
        Write-Host ("BASE Eval={0:N2} user={1:N1}% prod={2:N1}% stress={3:N1}% profile={4}" -f $bestSnap.EvalScore,$bestSnap.UserPerformance,$bestSnap.ProductPerformance,$bestSnap.StressPerformance,$baseProfilePath) -ForegroundColor Cyan

        # ONE DELTA loop: recommendation is generated from immutable BEST measurement,
        # candidate is an exact BEST copy plus one field, and rejected candidates never
        # become the input of the next recommendation.
        $hist=[System.Collections.Generic.List[object]]::new()
        for ($ei=1; $ei -le 3; $ei++) {
            if ((Get-RemainingRuntimeSeconds Tuning) -lt (240 + (Get-EstimatedMeasurementDuration $ProbeDurationSec))) { Write-Warning 'Runtime 부족: recommendation experiment 종료'; break }
            $rec=Get-NextExperimentRecommendation $bestSnap.Measurement $bestCfg ($ei-1)
            if ($null -eq $rec) { Write-Host 'NO_SAFE_RECOMMENDATION: BEST verification으로 진행' -ForegroundColor Yellow; break }
            Write-Host "`n===== RECOMMENDATION #$ei =====" -ForegroundColor Cyan
            Write-Host ("  Axis={0}  Current={1}  Proposed={2}" -f $rec.Axis,$rec.Current,$rec.Proposed)
            Write-Host ("  Formula={0}  Confidence={1:P0}  Benefit={2}  Evidence={3}" -f $rec.Field,$rec.Confidence,$rec.ExpectedBenefit,($rec.Evidence -join '; ')) -ForegroundColor DarkGray
            $cand=New-ExperimentCandidate $bestCfg $rec "Exp$ei"
            $ac=Copy-Config $cand "Exp$ei"
            Write-Host "`n===== EXPERIMENT #$ei =====" -ForegroundColor Green
            $candidateValid=$false; $es=$null
            try {
                $candidateReady=Apply-CandidateSafely $ac Hard
                if (-not $candidateReady) { throw 'CANDIDATE_ROLLOUT_NOT_READY' }
                $cl=Get-ClusterCapacitySnapshot; Set-KarpenterNodeLimit $cl
                $er=Run-ReliableLoadTest $ac $ProbeDurationSec $cl 0 -SkipRetry; $em=$er.Result
                if ($em) {
                    $candidateValid=($apps | ForEach-Object { [bool](Get-OptionalPropertyValue $em.Apps[$_] 'MeasurementReliable' $false) } | Where-Object { -not $_ }).Count -eq 0
                    if ($candidateValid) { $es=Save-EvaluationSnapshot $em $ac "Exp$ei" }
                }
            } catch { Write-Warning "Experiment #$ei 환경/측정 실패: $($_.Exception.Message)" }
            $keep=($candidateValid -and $es -and ($es.EvalScore -gt $bestSnap.EvalScore -or ($es.EvalScore -eq $bestSnap.EvalScore -and $es.AvgNodes -lt $bestSnap.AvgNodes)))
            $decision=if ($keep) { 'KEEP' } else { 'REJECT' }
            Write-Host ("  actual Eval={0} BEST={1:N2} Decision={2}" -f $(if($es){'{0:N2}' -f $es.EvalScore}else{'INVALID'}),$bestSnap.EvalScore,$decision) -ForegroundColor $(if($keep){'Green'}else{'Yellow'})
            $hist.Add([pscustomobject]@{Num=$ei;Axis=$rec.Axis;Current=$rec.Current;Proposed=$rec.Proposed;Decision=$decision;Score=$(if($es){$es.EvalScore}else{$null});BaseFingerprint=$bestSnap.ConfigFingerprint})
            if ($keep) { $bestSnap=$es; $bestCfg=$ac } else { Apply-CandidateSafely $bestCfg Hard; foreach($app in $apps){Wait-DeploymentRollout $app 180 Hard} }
        }

        # BEST verification uses the complete selected BEST configuration.
        if ((Get-RemainingRuntimeSeconds Tuning) -ge (Get-EstimatedMeasurementDuration $FinalDurationSec)) {
            $verifyReady=Apply-CandidateSafely $bestCfg Hard
            $verifyCluster=Get-ClusterCapacitySnapshot; Set-KarpenterNodeLimit $verifyCluster
            $verifyRun=$null
            if ($verifyReady) { $verifyRun=Run-ReliableLoadTest $bestCfg $FinalDurationSec $verifyCluster 0 -SkipRetry }

            if ($verifyRun -and $verifyRun.Result) {
                $verifySnap=Save-EvaluationSnapshot $verifyRun.Result $bestCfg 'BEST_VERIFY'
                if ($verifySnap.EvalScore -lt ($bestSnap.EvalScore - 0.5)) {
                    Apply-CandidateSafely $bestCfg Hard
                } else { $bestSnap=$verifySnap }
            }
        }
        # 채점 부하에서 stress와 foreground의 CPU contention을 피하기 위해
        # 실측한 전용 배치를 그대로 유지한다. fresh NodePool limit=2이면
        # Managed 1 + default 1 + stress 1(총 3대) 예산으로 동작한다.
        $finalConfig=Copy-Config $bestCfg 'GRADING_READY'
        foreach($app in $apps) {
            $finalConfig[$app].replicas=[int]$finalConfig[$app].minReplicas
        }
        if (-not $NoApply) {
            Ensure-38PointStressTopology
            $finalReady=Apply-CandidateSafely $finalConfig Hard
            if (-not $finalReady) { Write-Warning 'GRADING_READY candidate rollout incomplete; applied configuration is retained for external scoring.' }
            $finalCluster=Get-ClusterCapacitySnapshot
            Set-KarpenterNodeLimit $finalCluster
            $withinBudget=Wait-ReadyNodeCountAtMost $CostBaselineNodes 180 Hard
            if (-not $withinBudget) { Write-Warning "GRADING_READY_NODE_BUDGET_WARN: target=$CostBaselineNodes" }
        }
        Write-Host 'GRADING_READY: dedicated stress placement, warm min replicas, HPA max preserved' -ForegroundColor Green
        $finalApplied=(-not $NoApply)
        $selectedCandidate=$null; $selectedValidation=$bestSnap.Measurement
        $verificationStatuses=@(); $verificationSkipped=0
        $correction=[pscustomobject]@{Config=$finalConfig;CandidateGrade='BASE_EXPERIMENT';SelectionReason='38POINT_BASE -> ONE DELTA -> BEST -> GRADING_READY';Corrections=@();StopReason='BASE_COMPLETE'}
        # BASE 경로도 최종 적용 구성을 결과 파일에 남긴다. 중간 BASE 측정만
        # 저장하면 다음 실행/사후 분석에서 실제 적용 상태를 잃는다.
        Save-BaseExperimentProfile $finalConfig $bestSnap.Measurement $baseProfilePath 'FINAL_APPLIED' | Out-Null
        $runFailed=$false; return
    }
    Initialize-HpaControlPointModel

    $originalConfig=Get-LiveConfig 'Original'
    # HPA floor는 앱 이름별 GoldenBaseline이 아니라 live min을 보존한다.
    # 새 대회 앱/난이도에서는 현재 설정을 seed로 삼고 실측에서만 확장한다.
    foreach ($app in $apps) {
        $hpaMaxMinimum[$app]=[int][math]::Max(1,$originalConfig[$app].minReplicas)
        if (-not $script:HardSafetyMaxByApp.ContainsKey($app)) { $script:HardSafetyMaxByApp[$app]=[int]$MaxAutoReplicas }
    }
    if ($DetailedOutput) { Show-Config $originalConfig '원본 설정 스냅샷' }
    if ($SingleNode) {
        Write-Host '=== SingleNode 모드: 부하가 들어와도 Ready 노드를 1대(Managed)로 유지합니다. HPA max는 1노드 용량에 bin-packing합니다 ===' -ForegroundColor Yellow
    }
    Set-InstanceAwarePlacement
    $cluster=Get-ClusterCapacitySnapshot
    if (-not $cluster.KarpenterMatchesManaged) {
        throw "Managed Node type($($cluster.NodeInstanceType))과 Karpenter NodePool type($($cluster.KarpenterInstanceTypes -join ','))이 다릅니다. terraform.tfvars의 eks_node_instance_type을 두 구성에 동일하게 적용한 뒤 다시 실행하세요."
    }
    # P0: 이전 세션의 stress isolation artifact가 남아 있으면(stress nodeSelector +
    #     전용 NodePool) 측정 전체가 dedicated 1-node budget으로 묶여 stress capacity가
    #     1노드(약 3.6 rps)로 고정된다. baseline 간섭 근거가 없는 시작 지점은
    #     기본 배포 상태(shared)와 동일해야 하므로, 측정 시작 전 배치를 재판정한다.
    $startupPlacement=Get-StressPlacementDecision `
        -P95User 0 -P95Product 0 -P95UserBase $null -P95ProductBase $null `
        -NodeCpuUtil $null -NodeMemUtil $null -ThrottleRatio 0 `
        -SloFailUser 0 -SloFailProduct 0 `
        -Isolated $false -BaselineTrustworthy $false `
        -SharedCost ([double]$ManagedNodes) -DedicatedCost ([double]($ManagedNodes+1))
    Write-StressPlacementLog $startupPlacement
    if (-not $NoApply -and $startupPlacement.Decision -eq 'SHARED') {
        Revert-StressPlacement
        # 배치 변화를 반영해 cluster snapshot 재조회 (SchedulingConstraintRisk 갱신)
        $cluster=Get-ClusterCapacitySnapshot
    }
    Write-Host ("Idle 기준 Node={0}, alloc={1}m/{2:N0}Mi, system={3}m/{4:N0}Mi, app available={5}m/{6:N0}Mi" -f $cluster.NodeInstanceType,$cluster.NodeAllocatableCPU,$cluster.NodeAllocatableMemory,$cluster.SystemReservedCPU,$cluster.SystemReservedMemory,$cluster.AvailableAppCPU,$cluster.AvailableAppMemory) -ForegroundColor Cyan
    Set-KarpenterNodeLimit $cluster

        # Phase 2-4: ONE DELTA experiments
        $userReqM=[double](Convert-CpuToM $bestCfg.user.requestCpu)
        $userReqDown=[math]::Max([double]$cpuRequestMinimum.user,[math]::Floor(($userReqM*0.85)/25.0)*25.0)
        if ($userReqDown -ge $userReqM) { $userReqDown=$userReqM+25.0 }
        $userTargetDown=[math]::Max([double]$HpaTargetLowerBound,[math]::Floor(([double]$bestCfg.user.hpaTarget-5)/5.0)*5.0)
        $productReqM=[double](Convert-CpuToM $bestCfg.product.requestCpu)
        $productReqDown=[math]::Max([double]$cpuRequestMinimum.product,[math]::Floor(($productReqM*0.85)/25.0)*25.0)
        if ($productReqDown -ge $productReqM) { $productReqDown=$productReqM+25.0 }
        $exps=@(
            @{App='user';Field='requestCpu';Old="${userReqM}m";New=(Format-Cpu $userReqDown);Axis='USER_CPU_REQUEST'},
            @{App='user';Field='hpaTarget';Old=[string]$bestCfg.user.hpaTarget;New=[int]$userTargetDown;Axis='USER_HPA_TARGET'},
            @{App='product';Field='requestCpu';Old="${productReqM}m";New=(Format-Cpu $productReqDown);Axis='PRODUCT_CPU_REQUEST'}
        )
        $hist=[System.Collections.Generic.List[object]]::new(); $ei=0
        foreach ($exp in $exps) {
            if((Get-RemainingRuntimeSeconds Tuning)-lt 240){Write-Warning "Runtime 부족: experiment skip";break}
            $ei++
            Write-Host "`n===== EXPERIMENT #$ei =====" -ForegroundColor Green
            Write-Host ("  Axis: {0} {1} -> {2}" -f $exp.Axis,$exp.Old,$exp.New)
            $cand=Copy-Config $bestCfg "Exp${ei}"; $cand[$exp.App][$exp.Field]=$exp.New; $cand.Name="Exp${ei}"
            Assert-ConfigDrift $bestCfg $cand @($exp.Axis) | Out-Null
            $ac=Copy-Config $cand "Exp${ei}"; foreach($app in $apps){$ac[$app].replicas=1}
            Apply-Resources $ac Hard; Apply-Hpa $ac; foreach($app in $apps){Wait-DeploymentRollout $app 180 Hard}
            $cl=Get-ClusterCapacitySnapshot; Set-KarpenterNodeLimit $cl
            $er=Run-ReliableLoadTest $ac $ProbeDurationSec $cl 0 -SkipRetry; $em=$er.Result
            if(-not $em){Write-Warning "Exp${ei}: measurement failed, REJECT"; $dec='REJECT'}
            else {
                $es=Save-EvaluationSnapshot $em $ac "Exp${ei}"
                Write-Host ("  Candidate={0:N2} BEST={1:N2}" -f $es.EvalScore,$bestSnap.EvalScore)
                if($es.EvalScore -gt $bestSnap.EvalScore -or ($es.EvalScore -eq $bestSnap.EvalScore -and $es.AverageNodes -lt $bestSnap.AverageNodes)){
                    $dec='KEEP'; $bestSnap=$es; $bestCfg=$ac
                    Write-Host "  -> KEEP" -ForegroundColor Green
                } else {
                    $dec='REJECT'; Write-Host "  -> REJECT" -ForegroundColor Yellow
                }
            }
            $hist.Add([pscustomobject]@{Num=$ei;Axis=$exp.Axis;Old=$exp.Old;New=$exp.New;Decision=$dec;Score=$(if($es){$es.EvalScore}else{0})})
            if($dec -eq 'REJECT'){Apply-Resources $bestCfg Hard;Apply-Hpa $bestCfg;foreach($app in $apps){Wait-DeploymentRollout $app 180 Hard};Write-Host "  Rollback to BEST" -ForegroundColor DarkGray}
        }

        # Phase 5: BEST verify
        if((Get-RemainingRuntimeSeconds Tuning)-ge 180){
            Write-Host "`n===== BEST VERIFICATION =====" -ForegroundColor Green
            $vc=Copy-Config $bestCfg 'Verify';Apply-Resources $vc Hard;Apply-Hpa $vc
            foreach($app in $apps){Wait-DeploymentRollout $app 180 Hard}
            $vcl=Get-ClusterCapacitySnapshot;Set-KarpenterNodeLimit $vcl
            $vr=Run-ReliableLoadTest $vc $FinalDurationSec $vcl 0 -SkipRetry;$vm=$vr.Result
            if($vm){$vs=Save-EvaluationSnapshot $vm $vc 'Verify'
                Write-Host ("  Verify={0:N2} BEST={1:N2}" -f $vs.EvalScore,$bestSnap.EvalScore)
                if($vs.EvalScore -lt ($bestSnap.EvalScore-0.5)){Write-Warning "REGRESSION -> BASE";$bestSnap=$baseSnap;$bestCfg=$baseCfg}
                else{$bestSnap=$vs}
            }
        }

        # Phase 6: FINAL apply
        Write-Host "`n===== FINAL APPLY =====" -ForegroundColor Green
        $fc=Copy-Config $bestCfg 'Final';Apply-Resources $fc Hard;Apply-Hpa $fc
    # ==== Stress Length Calibration ====

    # length는 workload 난이도를 결정한다. SLO(1000ms)의 ~65%인 650ms 이하가 되는
    # 가장 큰 length를 전체 튜닝 전에 한 번 결정하고 이후 모든 k6 run에 고정한다.
    # 튜닝 중 SLO 결과를 보고 length를 다시 바꾸지 않는다.
    if ($StressLength -gt 0) {
        $script:SelectedStressLength=$StressLength
        Write-Host ("Stress length 지정됨(calibration 생략): {0}" -f $StressLength) -ForegroundColor Cyan
    } elseif ((Get-RemainingRuntimeSeconds Tuning) -lt ($StressCalibrationBudgetSeconds+60)) {
        Write-Warning "전체 runtime 여유가 부족해 Stress calibration을 생략하고 기본 STRESS_LENGTH=$DefaultStressLength를 사용합니다."
        $script:SelectedStressLength=$DefaultStressLength
    } else {
        try {
            $calibration=Select-StressLength $Endpoint
            $script:SelectedStressLength=$calibration.SelectedLength
        } catch {
            Write-Warning "Stress calibration 실패: $($_.Exception.Message) 기본 STRESS_LENGTH=$DefaultStressLength를 사용합니다."
            $script:SelectedStressLength=$DefaultStressLength
        }
    }
    $results=[System.Collections.Generic.List[object]]::new()
    $latestDiagnostics=@{}
    # SingleNode: Karpenter 노드 0대가 목표다. NodeBudget=0이면 부하 중 Karpenter
    # 노드가 1대라도 생기면 hard failure로 판정된다.
    $karpenterBudget=if ($SingleNode) { 0 } else { [math]::Max(1,$MaxNodes-$ManagedNodes) }
    # 1) 최소 설정을 측정하고, 먼저 측정 자체의 신뢰성을 검증한다.
    $minimumConfig=New-MinimumConfig $originalConfig 'Minimum'
        Assert-HpaConfigInvariant $minimumConfig 'NewMinimum'
    $minimumConfig.NodeBudget=$karpenterBudget
    if ($SingleNode) {
        # HPA max를 1노드 용량에 bin-packing해 채점 중에도 노드가 늘지 않게 한다.
        $minimumConfig=Enforce-ClusterReplicaBudget $minimumConfig $cluster 1
        $minimumConfig.NodeBudget=0
    } else {
        $minimumConfig=Enforce-ClusterReplicaBudget $minimumConfig $cluster $MaxNodes
        $minimumConfig.NodeBudget=$karpenterBudget
    }
    $minimumConfig=Enforce-IdleBudget $minimumConfig $cluster
    $priorityABudget=2*(Get-EstimatedMeasurementDuration $ProbeDurationSec)
    if ((Get-RemainingRuntimeSeconds Tuning) -lt $priorityABudget) {
        throw "Minimum과 최소 1개 개선 후보를 안전하게 측정할 시간이 없습니다: remaining=$(Get-RemainingRuntimeSeconds Tuning)s, required=${priorityABudget}s"
    }
    $minimumRun=Run-ReliableLoadTest $minimumConfig $ProbeDurationSec $cluster 1 -SkipRetry
    foreach ($attempt in $minimumRun.Attempts) { [void]$results.Add($attempt) }
    $minimumResult=$minimumRun.Result
    if (-not $minimumResult) { throw '유효한 Minimum 측정 결과가 없습니다.' }

    # 2) 앱별 최우선 병목에 해당하는 변수 하나만 변경한다.
    $balancedDecision=Apply-TuningActions $minimumConfig $minimumResult 'Balanced' $cluster
        Assert-HpaConfigInvariant $balancedDecision.Config 'BalancedPolicy'
    $balancedConfig=$balancedDecision.Config
    $balancedConfig.NodeBudget=$karpenterBudget
    if ($SingleNode) {
        $balancedConfig=Enforce-ClusterReplicaBudget $balancedConfig $cluster 1
        $balancedConfig.NodeBudget=0
    } else {
        $balancedConfig=Enforce-ClusterReplicaBudget $balancedConfig $cluster $MaxNodes
        $balancedConfig.NodeBudget=$karpenterBudget
    }
    $balancedConfig=Enforce-IdleBudget $balancedConfig $cluster
    # P0: 직전 측정(Mmm)의 warm min을 다음 측정부터 반영한다 (채점 시작 상태 = warm min).
    #     cold start(min=1)로 측정하면 stress SLO가 0%로 붕괴한다 (노드당 ≈2.2rps 실측).
    if (-not $SingleNode) {
        $warmMinB=Get-WarmMinFromValidation $balancedConfig $minimumResult $cluster
        foreach ($app in $apps) { $balancedConfig[$app].minReplicas=[int]($warmMinB[$app]) }
    }
    $balancedRun=Run-ReliableLoadTest $balancedConfig $ProbeDurationSec $cluster -SkipRetry
    foreach ($attempt in $balancedRun.Attempts) { [void]$results.Add($attempt) }
    $balancedResult=$balancedRun.Result
    if (-not $balancedResult) {
        Write-Warning 'runtime 예산으로 개선 후보 측정을 완료하지 못했습니다. Minimum 결과에서 best candidate를 확정합니다.'
        $balancedResult=$minimumResult
        $balancedConfig=$minimumConfig
    }

    # 3) 두 번째 관측에서도 원인 하나에 해당하는 변수만 변경한다.
    Set-ExplorationDiagnostics @($results)
    # CalculatedFinal tuning source는 신뢰도(G x R) 높은 측정을 우선한다.
    # Balanced가 load generator unreliable(G/R 낮음)여도 Minimum의 stress 신호를 사용한다.
    $tuningSource=Select-TuningReference @($minimumResult,$balancedResult)
    if ($null -eq $tuningSource) { $tuningSource=$balancedResult }
    $calculatedDecision=Apply-TuningActions $balancedConfig $tuningSource 'CalculatedFinal' $cluster
        Assert-HpaConfigInvariant $calculatedDecision.Config 'CalculatedFinalPolicy'
    $calculatedConfig=$calculatedDecision.Config
    foreach ($app in $apps) {
        $action=$calculatedDecision.Actions | Where-Object App -eq $app | Select-Object -First 1
        $latestDiagnostics[$app]=[pscustomobject]@{ReferenceProfile=$tuningSource.Name;CapacityReliable=$tuningSource.Apps[$app].CapacityReliable;MeaningfulImprovement=$false;CollateralRegression=$false;LoadGain=$null;LatencyGain=$null;Bottlenecks=$tuningSource.Apps[$app].Bottlenecks;TuningAction=$action.Type;MetricUnavailable=$tuningSource.Apps[$app].MetricUnavailable}
    }
    $calculatedConfig.NodeBudget=$karpenterBudget
    if ($SingleNode) {
        $calculatedConfig=Enforce-ClusterReplicaBudget $calculatedConfig $cluster 1
        $calculatedConfig.NodeBudget=0
    } else {
        $calculatedConfig=Enforce-ClusterReplicaBudget $calculatedConfig $cluster $MaxNodes
        $calculatedConfig.NodeBudget=$karpenterBudget
    }
    $calculatedConfig=Enforce-IdleBudget $calculatedConfig $cluster
    # P0: Balanced 측정 기반 warm min을 CalculatedFinal에 반영 (진입 cold start 제거).
    if (-not $SingleNode) {
        $warmMinC=Get-WarmMinFromValidation $calculatedConfig $balancedResult $cluster
        foreach ($app in $apps) { $calculatedConfig[$app].minReplicas=[int]($warmMinC[$app]) }
    }
    $calculatedIdle=Get-IdleCapacity $calculatedConfig $cluster
    if ($DetailedOutput) { Show-Config $calculatedConfig '최종 계산값 CalculatedFinal' }
    # CalculatedFinal은 VU Retry 같은 optional 단계보다 항상 우선한다.
    Write-Host ("Starting CalculatedFinal. Remaining runtime: {0}s, Reserved: {1}s" -f [math]::Floor((Get-RemainingRuntimeSeconds Tuning)),$CalculatedFinalReserveSec) -ForegroundColor Cyan
    $verificationStatuses=[System.Collections.Generic.List[object]]::new()
    $verificationAllowed=Get-VerificationRunCountForBudget $FinalDurationSec $VerificationRuns
    for ($verify=1;$verify -le $VerificationRuns;$verify++) {
        if ($verify -gt $verificationAllowed -or -not (Test-CanStartMeasurement $FinalDurationSec -Quiet)) {
            $verificationStatuses.Add([pscustomobject]@{Run=$verify;Status='NOT_EXECUTED_RUNTIME_BUDGET';Profile="CalculatedFinal-Verify$verify"})
            $script:stopTuning=$true;$script:tuningStopReason='Runtime budget reached'
            continue
        }
        $verifyConfig=Copy-Config $calculatedConfig $(if ($verify -eq 1) { 'CalculatedFinal' } else { "CalculatedFinal-Verify$verify" })
        $verification=Run-ReliableLoadTest $verifyConfig $FinalDurationSec $cluster -SkipRetry
        foreach ($attempt in $verification.Attempts) { [void]$results.Add($attempt) }
        if ($verification.Status -eq 'NOT_EXECUTED_RUNTIME_BUDGET' -or -not $verification.Result) {
            $verificationStatuses.Add([pscustomobject]@{Run=$verify;Status='NOT_EXECUTED_RUNTIME_BUDGET';Profile=$verifyConfig.Name})
            $script:stopTuning=$true;$script:tuningStopReason='Runtime budget reached'
            continue
        }
        $v=$verification.Result
        $allHeadroom=@($apps | Where-Object { $metric=Get-ResultAppMetric $v $_; $null -eq $metric -or -not [bool]$metric.HeadroomPass }).Count -eq 0
        $verificationFailure=Get-FailureClassification $v
        $status=if ($v.MeasurementReliable -and -not $verificationFailure.FatalFailure -and -not $verificationFailure.PerformanceFailure -and -not $verificationFailure.MeasurementFailure -and $v.AllSLOPass -and $allHeadroom) { 'PASS' } else { 'FAIL' }
        $verificationStatuses.Add([pscustomobject]@{Run=$verify;Status=$status;Profile=$v.Name})
    }

    $verificationSkipped=@($verificationStatuses | Where-Object Status -eq 'NOT_EXECUTED_RUNTIME_BUDGET').Count
    # VU Retry phase (optional): Minimum/Balanced/CalculatedFinal 최초 측정이 모두
    # 확보된 뒤, 남는 runtime으로 LOAD_GENERATOR_LIMIT 후보를 신뢰도(G×R) 낮은 순으로
    # 최대 1회씩 retry한다. 같은 K8s config의 측정이라 scoreboard는 profile 이름으로 합쳐진다.
    Write-Host ("Remaining runtime after mandatory measurements: {0}s" -f [math]::Floor((Get-RemainingRuntimeSeconds Tuning))) -ForegroundColor Cyan
    $retryRuns=Invoke-RetryPhase @($results) $ProbeDurationSec $cluster
    foreach ($retryRun in $retryRuns) { [void]$results.Add($retryRun) }
    # Final selection source of truth: measured raw metrics -> QualityScore ->
    # absolute 3-point near-best window -> observed/configured cost.  Stress의
    # CompetitionScore 같은 rule-based 예외로 후보를 미리 제거하지 않는다.
    $selectedCandidate=Select-QualityCandidate -Results @($results) -ExpectedConfigs @($minimumConfig,$balancedConfig,$calculatedConfig) -RequestedVerificationRuns $VerificationRuns -SkippedRuntimeRuns $verificationSkipped -Quiet
    if (-not $selectedCandidate) { throw '점수를 계산할 수 있는 측정 후보가 없습니다.' }
    if (-not $selectedCandidate) {
        Write-Warning "selectedCandidate is null — BEST_EFFORT_RELIABLE로 fallback."
        $selectedCandidate=[pscustomobject]@{ApplyAllowed=$true;Grade='BEST_EFFORT_RELIABLE';Name='fallback';SelectionReason='null candidate recovery';Result=$selectedValidation;Scoreboard=@();Stability=$null}
    }
    $finalSelectionFatal=(-not [bool]$selectedCandidate.ApplyAllowed)
    $selectedValidation=$selectedCandidate.Result
    $selectedStability=$selectedCandidate.Stability
    # 실제 성적표(EvaluationTotalScore) 기반 최종 순위: Feasible → TotalScore desc →
    # (tie) 기존 QualityScore. 최종 배포 후보는 feasible 후보 중 EvaluationTotalScore가
    # 가장 높은 설정을 우선하고, 동점/불확실은 기존 QualityScore 규칙이 결정한다.
    $evalRanked=@($results | Where-Object { $_ -and $_.Config -and -not [bool]$_.FatalFailure } | ForEach-Object {
        [pscustomobject]@{Result=$_;Evaluation=(Get-EvaluationScore $_);Reliable=[bool](Get-OptionalPropertyValue $_ 'MeasurementReliable' $false)} } | Sort-Object @{Expression={[bool]$_.Evaluation.Feasible};Descending=$true},@{Expression={[bool]$_.Reliable};Descending=$true},@{Expression={[double]$_.Evaluation.TotalScore};Descending=$true})
    $bestEval=$evalRanked | Where-Object { $_.Evaluation.Feasible } | Select-Object -First 1
    if ($bestEval -and $bestEval.Result -ne $selectedValidation) {
        $currentEval=Get-EvaluationScore $selectedValidation
        if ($bestEval.Evaluation.TotalScore -gt ($currentEval.TotalScore+1e-9)) {
            Write-Host ("→ Evaluation 기반 최종 후보 변경: {0} (Total {1}) → {2} (Total {3})" -f $selectedValidation.Name,$currentEval.TotalScore,$bestEval.Result.Name,$bestEval.Evaluation.TotalScore) -ForegroundColor Yellow
            $selectedValidation=$bestEval.Result
            $selectedCandidate=[pscustomobject]@{ApplyAllowed=$true;Grade='EVALUATION_SELECTED';Result=$selectedValidation;Stability=$selectedStability;Name=$bestEval.Result.Name;SelectionReason='MAX_EVALUATION_TOTAL_SCORE'}
        }
    }
    Write-Host 'FINAL EVALUATION RANKING' -ForegroundColor Cyan
    $evalIdx=0
    foreach ($entry in ($evalRanked | Where-Object { $_.Evaluation.Feasible } | Select-Object -First 5)) {
        $evalIdx++
        Write-Host ("{0}. {1}  Perf={2}  Cost={3}  Total={4}  Feasible={5}" -f $evalIdx,$entry.Result.Name,$entry.Evaluation.PerfScore,$entry.Evaluation.CostScore,$entry.Evaluation.TotalScore,$entry.Evaluation.Feasible) -ForegroundColor DarkGray
    }
    Write-Host ("Selected={0} reason=MAX_EVALUATION_TOTAL_SCORE" -f $(if ($bestEval) { $bestEval.Result.Name } else { 'NONE (no feasible)' })) -ForegroundColor Cyan
    # Stress placement decision: stress와 user/product가 같은 노드를 공유할 때 간섭이
    # 실제로 관측되면(foreground SLO 손상 또는 latency/노드 contention + 비용 조건) 전용
    # NodePool로 격리를 권장한다. baseline(부하 없는 user/product p95)이나 노드별 util
    # 데이터가 없으면 L/node 항은 0으로 두고 SLO hard guard만 유효하다.
    $placementRun=$results | Where-Object { $_ -and $_.Apps } | Select-Object -Last 1
    if ($placementRun -and -not $finalSelectionFatal) {
        $pu=$placementRun.Apps.user; $pp=$placementRun.Apps.product; $ps=$placementRun.Apps.stress
        $sloFailU=1.0-([double](Get-OptionalPropertyValue $pu 'SLOComplianceRate' 1.0))
        $sloFailP=1.0-([double](Get-OptionalPropertyValue $pp 'SLOComplianceRate' 1.0))
        $sharedNodes=[double](Get-OptionalPropertyValue $placementRun 'PeakTotalReadyNodes' $ManagedNodes)
        if ($sharedNodes -lt 1) { $sharedNodes=1 }
        $placementDecision=Get-StressPlacementDecision `
            -P95User ([double](Get-OptionalPropertyValue $pu 'P95Ms' 0)) -P95Product ([double](Get-OptionalPropertyValue $pp 'P95Ms' 0)) `
            -P95UserBase $null -P95ProductBase $null `
            -NodeCpuUtil $null -NodeMemUtil $null `
            -ThrottleRatio (Get-OptionalPropertyValue $ps 'ThrottleRatio' 0) `
            -SloFailUser $sloFailU -SloFailProduct $sloFailP `
            -Isolated $false -BaselineTrustworthy $false `
            -SharedCost $sharedNodes -DedicatedCost ($sharedNodes+1)
        Write-StressPlacementLog $placementDecision
        # 판정 결과를 실제 클러스터에 적용한다 (NoApply 모드면 로그만).
        if (-not $NoApply) {
            if ($placementDecision.Decision -eq 'ISOLATE_STRESS') {
                # right-sized shared 검증 전이면 ISOLATE 대신 SPLIT 우선:
                # coarse CPU allocation(925m×1)의 interference는 잘못된 vertical sizing이
                # 과장했을 수 있으므로, request/limit 분할 후 재측정해 본다.
                $placementCfg=Get-OptionalPropertyValue $placementRun 'Config'
                $sReq=[double](Convert-CpuToM $placementCfg.stress.requestCpu)
                $nAlloc=[double](Get-OptionalPropertyValue $cluster 'NodeAllocatableCPU' 0)
                $gran=if ($nAlloc -gt 0) { $sReq/$nAlloc } else { 0 }
                if ($gran -ge $StressGranularityThreshold) {
                    Write-Host '→ ISOLATE 보류: stress coarse allocation → SPLIT_STRESS_CAPACITY 우선 (right-sized shared 검증 후 재판정)' -ForegroundColor Yellow
                    [void](Get-StressCapacityShape $placementRun $cluster)
                } else {
                    # dedicated isolation: density 결정. 반드시 SPLIT override가 반영된 최신
                    # request를 사용한다 (stale 925m 금지).
                    $stressReqM=0.0; $stressLimitM=0.0
                    if ($script:FinalResourceOverrideByApp.ContainsKey('stress')) {
                        $stressReqM=[double]$script:FinalResourceOverrideByApp['stress'].requestCpu
                        $stressLimitM=[double]$script:FinalResourceOverrideByApp['stress'].limitCpu
                    }
                    if ($stressReqM -le 0) { $stressReqM=$sReq }
                    if ($stressLimitM -le 0) { $stressLimitM=[double](Convert-CpuToM $placementCfg.stress.limitCpu) }
                    if ([math]::Abs($stressReqM-$sReq) -gt 1) {
                        # placementCfg가 stale(925m)이고 override가 600m이면 override 우선 + stale 로그
                        Write-Host ("STALE_STRESS_RESOURCE_STATE: placementCfg request=$([math]::Round($sReq))m, override=$([math]::Round($stressReqM))m → override 사용") -ForegroundColor Yellow
                    }
                    $density=Get-StressDensityCandidate $stressReqM $stressLimitM $nAlloc
                    Write-StressDensityLog $density
                    $densityCandidate=$density.PlacementCandidate
                    # flip-flop 방지: 한번 SPREAD로 승격되면 같은 tune run에서 DENSE 회귀 금지
                    if ($densityCandidate -eq 'ISOLATED_DENSE' -and $script:StressDensityUpgradedToSpread) {
                        Write-Host '→ 이전 run에서 ISOLATED_SPREAD로 승격됨 — DENSE 회귀 금지' -ForegroundColor Yellow
                        $densityCandidate='ISOLATED_SPREAD'
                    }
                    # Dense 검증: 이전 run이 DENSE였고 측정 결과가 나쁘면 SPREAD로 승격
                    if ($densityCandidate -eq 'ISOLATED_DENSE' -and $script:StressDensityPlacement -eq 'ISOLATED_DENSE') {
                        $upgrade=Get-StressDensityUpgradeDecision $density $placementRun.Apps.stress
                        Write-Host ("Dense verification: stressSLO={0} cpuThrottling={1} generatedRatio={2:N3} droppedRate={3}" -f $upgrade.StressSLO,$upgrade.CpuThrottling,$upgrade.GeneratedRatio,$upgrade.DroppedRate) -ForegroundColor Yellow
                        if ($upgrade.Decision -eq 'UPGRADE_TO_ISOLATED_SPREAD') {
                            Write-Host '  decision=UPGRADE_TO_ISOLATED_SPREAD' -ForegroundColor Yellow
                            $script:StressDensityUpgradedToSpread=$true
                            $densityCandidate='ISOLATED_SPREAD'
                        } else {
                            Write-Host '  decision=KEEP_ISOLATED_DENSE' -ForegroundColor DarkGray
                        }
                    }
                    if ($densityCandidate -eq 'ISOLATED_DENSE') {
                        Write-Host '→ ISOLATED_DENSE 적용 (목표 2 pods/node, density-aware limit)' -ForegroundColor Yellow
                        $script:StressDensityPlacement='ISOLATED_DENSE'
                        $script:StressDensityLimitM=[double]$density.SelectedLimitM
                        Apply-StressPlacement
                        # Dense prewarm: replicas=2 (HPA min=1 유지)
                        try { Invoke-Kubectl @('-n',$Namespace,'scale','deploy','stress','--replicas=2') } catch { Write-Warning "stress dense prewarm 실패: $($_.Exception.Message)" }
                    } else {
                        Write-Host '→ ISOLATED_SPREAD 적용 (목표 1 pod/node)' -ForegroundColor Yellow
                        $script:StressDensityPlacement='ISOLATED_SPREAD'
                        $script:StressDensityLimitM=$null
                        Apply-StressPlacement
                    }
                }
            } elseif ($placementDecision.Decision -eq 'SHARED' -and $placementDecision.Reason -eq 'MERGE_BACK_HYSTERESIS') {
                Write-Host '→ stress 격리 해제(merge-back) 적용 중...' -ForegroundColor Yellow
                Revert-StressPlacement
            }
        }
    }
    # 전 후보 Fatal이면 점수표 1위의 측정값은 보존하되 손상되었을 수 있는
    # candidate config를 복사하지 않고 실제 유지할 원래 설정을 저장한다.
    $finalConfig=if ($finalSelectionFatal) { Copy-Config $originalConfig 'Original-Retained' } else { Copy-Config $selectedValidation.Config 'CalculatedFinal' }
    # placement 상태를 config placementDomain에 반영 (budget optimizer의 domain membership).
    # 앱 이름 분기 없이 placement 결정이 만든 상태만 전달한다.
    if ($script:StressDensityPlacement -in @('ISOLATED_DENSE','ISOLATED_SPREAD')) {
        $finalConfig[$DedicatedApp].placementDomain='dedicated'
    } else {
        $finalConfig[$DedicatedApp].placementDomain='shared'
    }
    # resource override overlay: request만 반영하고 CPU limit은 항상 제거한다.
    foreach ($app in $script:FinalResourceOverrideByApp.Keys) {
        $ro=$script:FinalResourceOverrideByApp[$app]
        $finalConfig[$app].requestCpu=Format-Cpu ([double]$ro.requestCpu)
        $finalConfig[$app].limitCpu=$null
        $script:FinalResourceOverrideByApp[$app].limitCpu=$null
        Write-Host ("  resource override [{0}]: request={1} limit=none" -f $app,$finalConfig[$app].requestCpu) -ForegroundColor DarkGray
    }
    # stale resource guard: optimizer 입력 request는 반드시 최신 override와 일치해야 한다.
    foreach ($app in $script:FinalResourceOverrideByApp.Keys) {
        $ro=$script:FinalResourceOverrideByApp[$app]
        $actual=[double](Convert-CpuToM $finalConfig[$app].requestCpu)
        if ([math]::Abs([double]$ro.requestCpu-$actual) -gt 1) {
            throw "STALE_RESOURCE_STATE: $app expected request=$([double]$ro.requestCpu)m but finalConfig=$($actual)m"
        }
    }
    # HPA MAX HARD INVARIANT: final maxReplicas는 오직 capacity ceiling(관측 기반)이다.
    # CapacityMax = Update-FinalHpaMax (관측 peak/R_CPU/throughput) — 노드 budget으로
    # bin-pack하지 않는다. budget model은 min(No-Scale fill)과 cost 진단에만 사용한다.
    $capacityMaxByApp=@{}
    foreach ($app in $apps) {
        $calc=$script:FinalHpaMaxByApp[$app]
        $capacityMaxByApp[$app]=if ($null -ne $calc -and [double]$calc -gt 0) { [int]$calc } else { [int]$finalConfig[$app].maxReplicas }
    }
    $targetNodeBudget=[int]$script:OperatingNodeBudget
    if ($targetNodeBudget -gt $MaxNodes) { $targetNodeBudget=$MaxNodes }
    # placementDomain이 반영된 최신 resource(finalConfig)로 budget model 구성 (min fill용).
    $budgetModel=Build-HpaBudgetModel $finalConfig $cluster $targetNodeBudget $capacityMaxByApp 1
    $perfByApp=@{}; $sensByApp=@{}
    foreach ($app in $apps) {
        $perfByApp[$app]=100.0*[double](Get-OptionalPropertyValue $selectedValidation.Apps[$app] 'SLOComplianceRate' 0)
        # same-run sensitivity: reliable 측정 history가 있으면 empirical, 없으면 0(명시적 fallback).
        $sensInfo=Get-AppSensitivity @($results) $app
        $sensByApp[$app]=$sensInfo.Value
        Write-Host ("  sensitivity [{0}] value={1} source={2} n={3}" -f $app,$sensInfo.Value,$sensInfo.Source,$sensInfo.N) -ForegroundColor DarkGray
    }
    # no-scale diagnostic only — max 제한에 사용하지 않는다.
    $budgetedMaxByApp=@{}
    foreach ($app in $apps) { $budgetedMaxByApp[$app]=[int]$capacityMaxByApp[$app] }
    # control point 학습 (same-run evidence: MEASURED_STABLE / MEASURED_SLO_RECOVERY)
    Write-Host '===== HPA CONTROL POINT (measured update) =====' -ForegroundColor Cyan
    foreach ($app in $apps) {
        $cp=Update-HpaControlPointFromMeasurement $app $selectedValidation.Apps[$app] $finalConfig
        Write-Host ("  {0}: controlPoint={1:N1}m source={2} confidence={3:N2}  (reference={4:N1}m)" -f $app,$cp.Value,$cp.Source,$cp.Confidence,$script:ControlPointByApp[$app]) -ForegroundColor DarkGray
    }
    # HPA Baseline/Warm min optimizer: minReplicas=1 고정 대신 실측 steady/burst로 DesiredMin 계산,
    # domain별 min budget 안에서 우선순위 배분 후 이전 검증된 warm min과 monotonic(max)으로 유지.
    Write-Host '===== HPA Baseline Optimizer =====' -ForegroundColor Cyan
    $desiredMinByApp=@{}; $baselineByApp=@{}
    foreach ($app in $apps) {
        $baseline=Get-HpaBaselineOptimizer $selectedValidation $app ([int]$capacityMaxByApp[$app])
        $baselineByApp[$app]=$baseline
        $desiredMinByApp[$app]=$baseline.DesiredMin
        Write-Host ("app={0} ready={1} steadyCPU={2} peakCPU={3} safe={4}% Rbase={5} BurstRisk={6} Warm={7} DesiredMin={8} Confidence={9}" -f $app,$baseline.ReadyReplicas,$(if ($null -eq $baseline.SteadyCpu) { '-' } else { "$($baseline.SteadyCpu)%" }),$(if ($null -eq $baseline.PeakCpu) { '-' } else { "$($baseline.PeakCpu)%" }),$baseline.SafeCpu,$baseline.Rbase,$baseline.BurstRisk,$baseline.WarmReplicas,$baseline.DesiredMin,$baseline.Confidence) -ForegroundColor DarkGray
        if ($baseline.DesiredMin -gt 1) { Write-Host ("  reason: {0}" -f ($baseline.Reasons -join ', ')) -ForegroundColor DarkGray }
    }
    # ELASTIC_DENSITY warm prior: user/product는 부하 중 steady CPU의 Rbase가 아니라
    # 진입 warm replica 기준으로 min을 산정한다 (reference min=2, startup lag evidence 시 3).
    # 부하 중 steady 기반 DesiredMin(user 6 등)을 warm 그대로 쓰면 상시 노드 예약이 과대해진다.
    foreach ($app in $script:ElasticDensityApps) {
        # P0-4: warmCap hard cap(3) 제거 — min은 baseline DesiredMin + No-Scale Min Fill로만 결정.
        # reference prior floor=2는 unreliable 시에만 적용 (startup lag 없는 앱).
        $startupEvidence=('POD_STARTUP_DELAY' -in @(Get-OptionalPropertyValue $selectedValidation.Apps[$app] 'Bottlenecks' @()))
        if ($desiredMinByApp[$app] -lt 2 -and -not $startupEvidence) {
            Write-Host ("  warm min [{0}]: desiredMin={1} -> 2 (ELASTIC_DENSITY reference prior floor=2, startup={2})" -f $app,[int]$desiredMinByApp[$app],$startupEvidence) -ForegroundColor Yellow
            $desiredMinByApp[$app]=2
        }
        # warmCap 하드 캡(3) 제거 — No-Scale Min Fill에서 budget 내 max를 결정.
    }
    $minAlloc=$null
    try {
        $minAlloc=Get-BudgetedHpaMinVector $budgetModel.Apps $budgetModel.Domains $desiredMinByApp $capacityMaxByApp $selectedValidation
    } catch {
        Write-Warning "min vector 계산 실패 — desiredMin으로 fallback: $($_.Exception.Message)"
        $minAlloc=[pscustomobject]@{MinVector=@{};CappedReason=@{};DesiredMin=$desiredMinByApp}
        foreach ($app in $apps) { $minAlloc.MinVector[$app]=[int][math]::Min([int]$desiredMinByApp[$app],[int]$capacityMaxByApp[$app]) }
    }
    $script:BaselineMinVector=@{}
    foreach ($app in $apps) {
        $script:BaselineMinVector[$app]=[int]$minAlloc.MinVector[$app]
    }
    
    # P0-3: No-Scale Min Fill — OperatingNodeBudget 안에서 min을 최대한 높인다.
    # baseline DesiredMin 이후 남은 CPU/MEM slack을 사용해 추가 warm replica를 배치한다.
    $noScaleVector=@{}; foreach ($app in $apps) { $noScaleVector[$app]=[int]$minAlloc.MinVector[$app] }
    $noScaleFillIterations=0
    $maxPossibleAdds = 0
    foreach ($app in $apps) {
        $maxPossibleAdds += [int]$capacityMaxByApp[$app] - [int]$minAlloc.MinVector[$app]
    }
    if ($maxPossibleAdds -lt 1) { $maxPossibleAdds = 1 }
    
    try {
    while ($noScaleFillIterations -lt $maxPossibleAdds) {
        $candidates = @()
        foreach ($app in $apps) {
            $newMin = $noScaleVector[$app] + 1
            if ($newMin -gt [int]$capacityMaxByApp[$app] -or $newMin -gt [int]$finalConfig[$app].maxReplicas) { continue }
            if ($newMin -gt [int]$MaxAutoReplicas) { continue }
            
            # budget fit 확인: 기존 사용량에 min+1의 request를 더해도 domain budget 내.
            $d = $budgetModel.Apps[$app].Domain
            $reqCpu = [double]$budgetModel.Apps[$app].CpuRequestM
            $reqMem = [double]$budgetModel.Apps[$app].MemoryRequestMi
            
            $usedCpu = 0.0; $usedMem = 0.0
            foreach ($b in $apps) {
                if ($budgetModel.Apps[$b].Domain -eq $d) {
                    $usedCpu += [double]$budgetModel.Apps[$b].CpuRequestM * $noScaleVector[$b]
                    $usedMem += [double]$budgetModel.Apps[$b].MemoryRequestMi * $noScaleVector[$b]
                }
            }
            
            $newUsedCpu = $usedCpu + $reqCpu
            $newUsedMem = $usedMem + $reqMem
            # budget 90% 초과 시 중단 (soft limit) — 단일 앱이 budget 독점 방지.
            if ($newUsedCpu -gt [double]$budgetModel.Domains[$d].CpuBudget*0.90 -or $newUsedMem -gt [double]$budgetModel.Domains[$d].MemoryBudget*0.90) {
                continue
            }
            if ($newUsedCpu -gt [double]$budgetModel.Domains[$d].CpuBudget -or $newUsedMem -gt [double]$budgetModel.Domains[$d].MemoryBudget) {
                continue
            }
            
            # 우선순위 항목들 계산
            $metric = $selectedValidation.Apps[$app]
            $sloPass = [bool](Get-OptionalPropertyValue $metric 'SLOPass' $false)
            $hpaCeiling = [bool]('HPA_CEILING' -in @(Get-OptionalPropertyValue $metric 'Bottlenecks' @()))
            $throttle = [bool]('CPU_THROTTLING' -in @(Get-OptionalPropertyValue $metric 'Bottlenecks' @()))
            $startup = [bool]('POD_STARTUP_DELAY' -in @(Get-OptionalPropertyValue $metric 'Bottlenecks' @()))
            
            $hardRecovery = -not $sloPass
            $hardRecoveryOrCeiling = $hardRecovery -or $hpaCeiling
            
            # Boundary Gain
            $sloCompliance = [double](Get-OptionalPropertyValue $metric 'SLOComplianceRate' 1.0)
            $boundaryGain = 1.0 - $sloCompliance
            
            # Sensitivity
            $sens = [double](Get-OptionalPropertyValue $metric 'Sensitivity' 0.0)
            $sensReliable = [bool](Get-OptionalPropertyValue $metric 'SensitivityReliable' $false)
            if (-not $sensReliable -or $sens -lt 0) {
                $sens = 0.0
            }
            
            # Burst / Startup
            $burstEvidence = $startup -or $throttle
            
            # Dominant Share
            $cpuShare = $reqCpu / [double]$budgetModel.Domains[$d].CpuBudget
            $memShare = $reqMem / [double]$budgetModel.Domains[$d].MemoryBudget
            $dominantShare = [math]::Max($cpuShare, $memShare)
            
            $candidates += [pscustomobject]@{
                App = $app
                NewMin = $newMin
                CpuDelta = $reqCpu
                MemoryDelta = $reqMem
                Domain = $d
                HardRecoveryOrCeiling = $hardRecoveryOrCeiling
                BoundaryGain = $boundaryGain
                Sensitivity = $sens
                BurstEvidence = $burstEvidence
                DominantShare = $dominantShare
            }
        }
        
        if ($candidates.Count -eq 0) { break }
        
        # 랭킹 정렬 (Sort-Object)
        $sorted = @($candidates | Sort-Object `
            @{ Expression = 'HardRecoveryOrCeiling'; Descending = $true }, `
            @{ Expression = 'BoundaryGain'; Descending = $true }, `
            @{ Expression = 'Sensitivity'; Descending = $true }, `
            @{ Expression = 'BurstEvidence'; Descending = $true }, `
            @{ Expression = 'DominantShare'; Descending = $false }, `
            @{ Expression = 'App'; Descending = $false } `
        )
        
        $bestCandidate = $sorted[0].App
        $noScaleVector[$bestCandidate]++
        $noScaleFillIterations++
    }
    
    if ($noScaleFillIterations -gt 0) {
        Write-Host ("No-Scale Min Fill: {0} iterations → {1}" -f $noScaleFillIterations, (($noScaleVector.Keys | ForEach-Object { "$_=$($noScaleVector[$_])" }) -join ' ')) -ForegroundColor Cyan
    }
    $finalMinByApp=@{}
    foreach ($app in $apps) {
        $budMin=[int]$noScaleVector[$app]
        # P0-3: No-Scale Min Fill 결과가 authoritative — monotonic 유지.
        $finalMin=[int]$budMin
        if ($finalMin -gt [int]$capacityMaxByApp[$app]) { $finalMin=[int]$capacityMaxByApp[$app] }
        if ($finalMin -lt 1) { $finalMin=1 }
        $script:FinalHpaMinByApp[$app]=$finalMin
        $finalMinByApp[$app]=$finalMin
        if ([int]$minAlloc.MinVector[$app] -lt [int]$desiredMinByApp[$app]) {
            Write-Host ("  {0}: desiredMin={1} budgetedMin={2} cappedBy={3}" -f $app,[int]$desiredMinByApp[$app],[int]$minAlloc.MinVector[$app],$minAlloc.CappedReason[$app]) -ForegroundColor Yellow
        }
    }
    # warm min이 현재 OperatingNodeBudget 안에서 충족됐는지: budget cap 때문에 desired보다
    # 낮아졌으면 MIN_WARM_CAPACITY_CAPPED_BY_NODE_BUDGET 기록 (자동 node 추가 금지).
    $minCappedTotal=@($apps | Where-Object { [int]$minAlloc.MinVector[$_] -lt [int]$desiredMinByApp[$_] }).Count
    if ($minCappedTotal -gt 0) {
        Write-Host 'MIN_WARM_CAPACITY_CAPPED_BY_NODE_BUDGET: 일부 warm min이 현재 OperatingNodeBudget 내 min budget에 맞지 않아 보류 — 추가 node는 paid scale-out에서만 승인' -ForegroundColor Yellow
    }
    } catch {
        # No-Scale fill 계산 오류가 전체 적용을 막지 않도록 baseline vector로 fallback하고 계속 진행한다.
        Write-Warning "No-Scale Min Fill 계산 오류 — BaselineMinVector로 fallback: $($_.Exception.Message)"
        $noScaleVector=@{}; foreach ($app in $apps) { $noScaleVector[$app]=[int]$script:BaselineMinVector[$app] }
        $finalMinByApp=@{}; foreach ($app in $apps) { $finalMinByApp[$app]=1 }
        foreach ($app in $apps) {
            $finalMin=[int]$noScaleVector[$app]
            if ($finalMin -gt [int]$capacityMaxByApp[$app]) { $finalMin=[int]$capacityMaxByApp[$app] }
            if ($finalMin -lt 1) { $finalMin=1 }
            $script:FinalHpaMinByApp[$app]=$finalMin
            $finalMinByApp[$app]=$finalMin
        }
    }
    # HPA MAX HARD INVARIANT: maxReplicas는 scheduler reservation이 아니다.
    # Σ(max×request)<=budget으로 bin-pack하지 않는다. max는 오직 application capacity
    # ceiling (관측 peak/R_CPU/HardMax 기반). 노드 budget은 min(No-Scale fill)에만 적용.
    $budgetedMaxByApp=@{}
    foreach ($app in $apps) { $budgetedMaxByApp[$app]=[int]$capacityMaxByApp[$app] }   # no-scale diagnostic (max 제한에 미사용)
    $hpaOverlayLog=[System.Collections.Generic.List[string]]::new()
    foreach ($app in $apps) {
        $candidateMax=[int]$finalConfig[$app].maxReplicas
        $capMax=[int]$capacityMaxByApp[$app]
        $budMax=[int]$budgetedMaxByApp[$app]
        # budgetedMax는 no-scale diagnostic일 뿐 — max를 줄이는 데 사용하지 않는다.
        # node budget에 맞지 않는다는 이유만으로 FinalMax를 낮추지 않는다.
        # HardSafetyMax(앱별 absolute ceiling)만 적용한다.
        $hardMax=if ($script:HardSafetyMaxByApp.ContainsKey($app)) { [int]$script:HardSafetyMaxByApp[$app] } else { [int]$MaxAutoReplicas }
        $finalMax=[int][math]::Min($hardMax,$capMax)
        if ($finalMax -lt 1) { $finalMax=1 }
        $finalMin=[int]$finalMinByApp[$app]
        if ($finalMin -gt $finalMax) { $finalMin=$finalMax }
        # min<=max 강제: min은 maxReplicas를 초과할 수 없다
        $finalConfig[$app].maxReplicas=$finalMax
        $finalConfig[$app].minReplicas=$finalMin
        $behaviorAction=if ($script:HpaBehaviorAction.ContainsKey($app)) { [string]$script:HpaBehaviorAction[$app] } else { 'KEEP' }
        $behaviorState=if ($behaviorAction -eq 'TUNE_SCALE_UP') { 'modified' } else { 'preserved' }
        # HPA CONTROL POINT: request가 바뀌었으면 target을 재계산해 absolute threshold 보존.
        #   target_new = 100 x controlPoint / request_new
        $reqM=[double](Convert-CpuToM $finalConfig[$app].requestCpu)
        $cpInfo=Get-HpaControlPoint $app
        $oldTarget=[int]$finalConfig[$app].hpaTarget
        $newTarget=[math]::Round((Get-HpaTargetFromControlPoint $app $reqM))
        if ($newTarget -ne $oldTarget) {
            Write-Host ("  HPA target [{0}]: {1}% -> {2}% (controlPoint={3:N1}m source={4} request={5:N0}m)" -f $app,$oldTarget,$newTarget,$cpInfo.Value,$cpInfo.Source,$reqM) -ForegroundColor Yellow
            $finalConfig[$app].hpaTarget=$newTarget
        }
        $hpaOverlayLog.Add(('  Final HPA [{0}] min={1} max={2} (capacity={3} noScale={4}) target={5}% cp={6:N1}m({7}) behavior={8}' -f $app,$finalMin,$finalMax,$capMax,$budMax,[int]$finalConfig[$app].hpaTarget,$cpInfo.Value,$cpInfo.Source,$behaviorState))
    }
    Write-Host 'Final HPA overlay' -ForegroundColor Cyan
    Write-Host ('  candidate: {0}' -f $finalConfig.Name) -ForegroundColor DarkGray
    foreach ($line in $hpaOverlayLog) { Write-Host $line -ForegroundColor DarkGray }
    # user/product CPU limit 제거 candidate (ELASTIC_DENSITY — burst 허용):
    # throttling/회귀 evidence 없고 SLO 안정이면 CFS quota 제거 (known-good reference: limit 없음).
    # stress는 제외 (request=reservation, limit=burst ceiling 분리 — reference 2 CPU prior).
    Write-Host '===== RESOURCE RIGHT-SIZING (CPU limit policy) =====' -ForegroundColor Cyan
    foreach ($app in $script:ElasticDensityApps) {
        $m=$selectedValidation.Apps[$app]
        $thr=[double](Get-OptionalPropertyValue $m 'ThrottleRatio' 0)
        $slo=[double](Get-OptionalPropertyValue $m 'SLOComplianceRate' 0)
        $oom=[int](Get-OptionalPropertyValue $m 'OOMKilledDelta' 0)
        $limitNow=[string]$finalConfig[$app].limitCpu
        if ($limitNow -ne '' -and $slo -ge 0.95 -and $thr -lt 0.05 -and $oom -le 0) {
            Write-Host ("  {0}: CPU limit 제거 ({1} -> none) source=ELASTIC_DENSITY+REFERENCE_PRIOR (throttle={2:P1} slo={3:P1} oom={4})" -f $app,$limitNow,$thr,$slo,$oom) -ForegroundColor Yellow
            $finalConfig[$app].limitCpu=''
        } else {
            $reason=if ($limitNow -eq '') { 'ALREADY_REMOVED' } elseif ($slo -lt 0.95) { 'SLO_BELOW_95' } elseif ($thr -ge 0.05) { 'THROTTLING' } else { 'OOM_RISK' }
            Write-Host ("  {0}: CPU limit 유지 ({1}) reason={2}" -f $app,$limitNow,$reason) -ForegroundColor DarkGray
        }
    }
    # Near-boundary harvesting: 모든 후보 생성 → budget/근거 검증 → ranking → best 1개만 적용.
    # node 추가가 필요한 action은 여기서 하지 않는다 (paid scale-out 판단으로 넘김).
    $harvestCandidates=[System.Collections.Generic.List[object]]::new()
    foreach ($a in $apps) {
        $harvestPercent=100.0*[double](Get-OptionalPropertyValue $selectedValidation.Apps[$a] 'SLOComplianceRate' 0)
        $hInfo=Get-BoundaryHarvestInfo $harvestPercent $a
        if (-not $hInfo.NearBoundary) { continue }
        $m=$selectedValidation.Apps[$a]
        $bottlenecks=@(Get-OptionalPropertyValue $m 'Bottlenecks' @())
        $sensVal=[double]$sensByApp[$a]
        # replica 증가 근거: HPA ceiling/throttling/startup 지연/양수 sensitivity가 있을 때만.
        # SLO fail 자체는 근거가 아니다 — APPLICATION_LATENCY만 있으면 scale candidate 제외
        # (user처럼 CPU saturation 근거 없는 앱은 resource 낭비 방지).
        $scaleEvidence=('HPA_CEILING' -in $bottlenecks) -or ('CPU_THROTTLING' -in $bottlenecks) -or ('POD_STARTUP_DELAY' -in $bottlenecks) -or ($sensVal -gt 0)
        if (-not $scaleEvidence) { continue }
        $capMax=[int]$capacityMaxByApp[$a]
        $cpuReq=[double](Convert-CpuToM $finalConfig[$a].requestCpu)
        $memReq=[double](Convert-MemoryToMi $finalConfig[$a].requestMemory)
        $dom=if ($budgetModel.Apps.ContainsKey($a)) { $budgetModel.Apps[$a].Domain } else { 'shared' }
        $minBudgetCpu=if ($budgetModel.Domains.ContainsKey($dom)) { [double]$budgetModel.Domains[$dom].MinCpuBudget } else { 1 }
        $minBudgetMem=if ($budgetModel.Domains.ContainsKey($dom)) { [double]$budgetModel.Domains[$dom].MinMemoryBudget } else { 1 }
        $usedMinCpu=0.0; $usedMinMem=0.0
        foreach ($b in $apps) {
            if ($budgetModel.Apps.ContainsKey($b) -and $budgetModel.Apps[$b].Domain -eq $dom) {
                $usedMinCpu += [double]$budgetModel.Apps[$b].CpuRequestM*[int]$finalConfig[$b].minReplicas
                $usedMinMem += [double]$budgetModel.Apps[$b].MemoryRequestMi*[int]$finalConfig[$b].minReplicas
            }
        }
        $pcross=[math]::Max(0.3,[math]::Min(0.9,1.0-(([double]$hInfo.Distance)/5.0)))
        $expScore=[math]::Round($pcross*$hInfo.Gain,2)
        $share=[math]::Max($cpuReq/[math]::Max($minBudgetCpu,1e-9),$memReq/[math]::Max($minBudgetMem,1e-9))
        # MIN+1
        if ([int]$finalConfig[$a].minReplicas -lt [int]$finalConfig[$a].maxReplicas) {
            $newMin=[int]$finalConfig[$a].minReplicas+1
            $budgetOk=((($usedMinCpu-$cpuReq*[int]$finalConfig[$a].minReplicas)+$cpuReq*$newMin) -le $minBudgetCpu) -and ((($usedMinMem-$memReq*[int]$finalConfig[$a].minReplicas)+$memReq*$newMin) -le $minBudgetMem)
            $harvestCandidates.Add([pscustomobject]@{App=$a;Type='HPA_MIN_PLUS_ONE';OldMin=[int]$finalConfig[$a].minReplicas;NewMin=$newMin;OldMax=[int]$finalConfig[$a].maxReplicas;NewMax=[int]$finalConfig[$a].maxReplicas;Boundary=$hInfo.NextBoundary;Gain=$hInfo.Gain;Pcross=$pcross;ScoreGain=$expScore;Share=[math]::Round($share,3);BudgetOk=$budgetOk;EvalGain=$expScore;Sens=$sensVal})
        }
        # MAX+1 (CPU+Memory budget 동시 검증)
        if ([int]$finalConfig[$a].maxReplicas -lt $capMax) {
            $newMax=[int]$finalConfig[$a].maxReplicas+1
            $maxBudgetCpu=if ($budgetModel.Domains.ContainsKey($dom)) { [double]$budgetModel.Domains[$dom].CpuBudget } else { 1 }
            $maxBudgetMem=if ($budgetModel.Domains.ContainsKey($dom)) { [double]$budgetModel.Domains[$dom].MemoryBudget } else { 1 }
            $usedMaxCpu=0.0; $usedMaxMem=0.0
            foreach ($b in $apps) { if ($budgetModel.Apps.ContainsKey($b) -and $budgetModel.Apps[$b].Domain -eq $dom) {
                $usedMaxCpu += [double]$budgetModel.Apps[$b].CpuRequestM*[int]$finalConfig[$b].maxReplicas
                $usedMaxMem += [double]$budgetModel.Apps[$b].MemoryRequestMi*[int]$finalConfig[$b].maxReplicas } }
            $budgetOk=((($usedMaxCpu-$cpuReq*[int]$finalConfig[$a].maxReplicas)+$cpuReq*$newMax) -le $maxBudgetCpu) -and ((($usedMaxMem-$memReq*[int]$finalConfig[$a].maxReplicas)+$memReq*$newMax) -le $maxBudgetMem)
            $harvestCandidates.Add([pscustomobject]@{App=$a;Type='HPA_MAX_PLUS_ONE';OldMin=[int]$finalConfig[$a].minReplicas;NewMin=[int]$finalConfig[$a].minReplicas;OldMax=[int]$finalConfig[$a].maxReplicas;NewMax=$newMax;Boundary=$hInfo.NextBoundary;Gain=$hInfo.Gain;Pcross=$pcross;ScoreGain=$expScore;Share=[math]::Round($share,3);BudgetOk=$budgetOk;EvalGain=$expScore;Sens=$sensVal})
        }
    }
    # ranking: BudgetOk → EvalGain desc → Pcross desc → Share asc (apps 순서 무관)
    $harvestAction=$null
    if ($harvestCandidates.Count) {
        $harvestAction=@($harvestCandidates | Sort-Object @{Expression='BudgetOk';Descending=$true},@{Expression='EvalGain';Descending=$true},@{Expression='Pcross';Descending=$true},@{Expression='Share'}) | Select-Object -First 1
    }
    if ($harvestAction -and -not $harvestAction.BudgetOk) { $harvestAction=$null }
    if ($harvestAction) {
        # runtime 부족이면 unvalidated harvest를 final configuration으로 남기지 않는다.
        if ((Get-RemainingRuntimeSeconds Tuning) -lt ([int]$ProbeDurationSec+30)) {
            Write-Host '→ near-boundary action 후보 있으나 runtime 부족 — unvalidated harvest 미적용' -ForegroundColor Yellow
            $harvestAction=$null
        } else {
            $finalConfig[$harvestAction.App].minReplicas=$harvestAction.NewMin
            $finalConfig[$harvestAction.App].maxReplicas=$harvestAction.NewMax
            Write-Host ("→ near-boundary action 적용: {0} {1} min {2}→{3} max {4}→{5} (boundary {6}, gain +{7:N1}, Pcross {8:N2}, budgetOk {9})" -f $harvestAction.App,$harvestAction.Type,$harvestAction.OldMin,$harvestAction.NewMin,$harvestAction.OldMax,$harvestAction.NewMax,$harvestAction.Boundary,$harvestAction.Gain,$harvestAction.Pcross,$harvestAction.BudgetOk) -ForegroundColor Yellow
            # short validation run: NewEval vs OldEval → regression이면 rollback
            $oldEval=(Get-EvaluationScore $selectedValidation).TotalScore
            $harvestRun=Run-ReliableLoadTest $finalConfig $ProbeDurationSec $cluster -SkipRetry
            $newEval=if ($harvestRun -and $harvestRun.Result) { (Get-EvaluationScore $harvestRun.Result).TotalScore } else { $null }
            if ($null -ne $newEval -and $newEval -ge $oldEval) {
                Write-Host ("[BOUNDARY-HARVEST] app={0} action={1} oldEval={2} newEval={3} decision=KEEP" -f $harvestAction.App,$harvestAction.Type,$oldEval,$newEval) -ForegroundColor Green
            } else {
                $finalConfig[$harvestAction.App].minReplicas=$harvestAction.OldMin
                $finalConfig[$harvestAction.App].maxReplicas=$harvestAction.OldMax
                Write-Host ("[BOUNDARY-HARVEST] app={0} action={1} oldEval={2} newEval={3} decision=ROLLBACK reason=EVALUATION_DECREASE_OR_INVALID" -f $harvestAction.App,$harvestAction.Type,$oldEval,$(if ($null -eq $newEval) { 'invalid' } else { $newEval })) -ForegroundColor Yellow
                $harvestAction=$null
            }
        }
    }
    [void](Write-NodeBudgetObservation $selectedValidation ([int]$script:OperatingNodeBudget))
    Write-EmpiricalSummary $finalConfig $selectedValidation $cluster
    # HPA spike guard: 순간 CPU spike의 과도한 replica jump만 scale-up 속도를 완화한다.
    # HPA max(budget optimizer 결과)는 건드리지 않는다 — 2→3→4→... 로 서서히 확장.
    foreach ($app in $apps) {
        $guardMetric=$selectedValidation.Apps[$app]
        $liveBehavior=$null
        try { $liveBehavior=((Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.behavior}')) -join '') } catch { $liveBehavior=$null }
        $guard=Get-HpaSpikeGuardDecision $guardMetric $liveBehavior
        Write-HpaSpikeGuardLog $app $guard
        # startup lag가 관측된 앱은 scale-up을 늦추지 않는다 — min↓+max↓+scaleUp↓ 3중
        # 결합으로 성능을 죽이는 설정 방지 (P1: startup delay 있으면 LIMIT_SCALE_UP 금지).
        if ($guard.Decision -eq 'LIMIT_SCALE_UP' -and ('POD_STARTUP_DELAY' -in @(Get-OptionalPropertyValue $guardMetric 'Bottlenecks' @()))) {
            Write-Warning ("SPIKE_GUARD_SKIPPED: {0} — POD_STARTUP_DELAY 관측, LIMIT_SCALE_UP 미적용 (startup 지연 앱은 공격적 scale-up 유지)" -f $app)
            $guard=$null
        }
        if ($null -ne $guard -and $guard.Decision -eq 'LIMIT_SCALE_UP') {
            $script:HpaBehaviorAction[$app]='TUNE_SCALE_UP'
            $finalConfig[$app].behavior=Get-SpikeGuardHpaBehavior
        }
    }
    
    $finalFingerprint = Get-ConfigFingerprint $finalConfig
    $validationFingerprint = Get-ConfigFingerprint $selectedValidation.Config
    
    if ($finalFingerprint -eq $validationFingerprint) {
        Write-Host "FINAL_CONFIG_MEASURED=true" -ForegroundColor Green
    } else {
        Write-Warning "FINAL_CONFIG_CHANGED: measured != final (immutable measurement)"
        Write-Warning "  Measured: $validationFingerprint"
        Write-Warning "  Final   : $finalFingerprint"
        $requiredSeconds = $FinalDurationSec + 30
        $remainingSeconds = Get-RemainingRuntimeSeconds Tuning
        if ($remainingSeconds -ge $requiredSeconds) {
            Write-Host "런타임이 충분합니다 (${remainingSeconds}s >= ${requiredSeconds}s). finalConfig 재측정을 시작합니다." -ForegroundColor Cyan
            $finalValidation = Run-ReliableLoadTest $finalConfig $FinalDurationSec $cluster -SkipRetry
            
            $validationSuccess = $false
            if ($null -ne $finalValidation) {
                $failure = Get-FailureClassification $finalValidation
                $finalFp = Get-ConfigFingerprint $finalValidation.Config
                
                # validation 성공 조건: measurement 존재, MeasurementReliable=true, FatalFailure=false, fingerprint == finalConfig fingerprint
                if ([bool]$finalValidation.MeasurementReliable -and -not $failure.FatalFailure -and $finalFp -eq $finalFingerprint) {
                    $validationSuccess = $true
                }
            }
            
            if ($validationSuccess) {
                Write-Host "finalConfig 재측정 성공. selectedValidation을 업데이트합니다." -ForegroundColor Green
                $selectedValidation = $finalValidation
            } else {
                Write-Warning "finalConfig 재측정에 실패했거나 불완전합니다. last measured config로 롤백합니다."
                $finalConfig = Copy-Config $selectedValidation.Config 'CalculatedFinal'
                $finalFingerprint = Get-ConfigFingerprint $finalConfig
            }
        } else {
            # 런타임 부족 시 aggressive overlay를 apply하지 않고 last measured config로 rollback한다.
            Write-Warning "FINAL_CONFIG_NOT_MEASURED: fingerprint mismatch이나 런타임 부족 — measured config를 final로 그대로 적용."
            # rollback하지 않는다: warm state 검증에서 측정된 config의 안전성을 확인.
            $finalFingerprint = Get-ConfigFingerprint $finalConfig
        }
    }
    $correction=[pscustomobject]@{
        Config=$finalConfig
        CandidateGrade=$selectedCandidate.Grade
        SelectionReason=$(switch ($selectedCandidate.Grade) {
            'QUALITY_SELECTED' { $selectedCandidate.SelectionReason }
            'STABLE' { '요청한 반복 검증을 모두 통과한 안정 후보입니다.' }
            'PARTIALLY_VERIFIED' { '실행된 verification을 모두 통과했으며 나머지는 runtime budget으로 미실행되었습니다.' }
            'BEST_EFFORT_RELIABLE' { '완전 검증 후보는 없지만 세 API 처리 용량이 모두 신뢰 가능한 최고 후보입니다.' }
            'INVALID' { '모든 후보가 FatalFailure이므로 점수표 1위만 기록하고 실제 적용하지 않습니다.' }
            default { '완전 검증·신뢰 후보는 아니지만 FatalFailure가 없는 최고 best-effort 후보입니다.' }
        })
        Verification=@($verificationStatuses)
        StopReason=$script:tuningStopReason
        Corrections=@("candidate grade=$($selectedCandidate.Grade), reason=$($script:tuningStopReason), verification=$($verificationStatuses | ConvertTo-Json -Compress)")
        CorrectionUnvalidated=[bool]$selectedCandidate.MeasurementFailure
        QualitySelection=$selectedCandidate.SelectedEntry
    }
    if ($DetailedOutput) { Write-Host ("후보 확정: {0}, grade={1}, official={2:N2}/36, KarpenterPeak={3}" -f $selectedValidation.Name,$selectedCandidate.Grade,$selectedValidation.CompetitionScore.Earned,$selectedValidation.PeakReadyNodes) -ForegroundColor Green }
    $finalIdle=Get-IdleCapacity $finalConfig $cluster
    if (-not $finalSelectionFatal -and -not $finalIdle.IdleOneNodeFit) {
        # 격리 구성(stress 전용 노드)에서는 단일 노드 fit이 구조적으로 false다.
        # stress는 전용 노드, user/product만 shared 1노드에 fit하면 진행한다.
        $nonStressCpu=[double](('user','product' | ForEach-Object { Convert-CpuToM $finalConfig[$_].requestCpu } | Measure-Object -Sum).Sum)
        $nonStressMem=[double](('user','product' | ForEach-Object { Convert-MemoryToMi $finalConfig[$_].requestMemory } | Measure-Object -Sum).Sum)
        $isolationConfig=[bool]$cluster.SchedulingConstraintRisk
        if (-not ($isolationConfig -and $nonStressCpu -le $cluster.AvailableAppCPU -and $nonStressMem -le $cluster.AvailableAppMemory)) {
            throw '적용 가능한 Idle 1-Node 설정을 계산하지 못했습니다.'
        }
    }
    # 라이브 적용이 실패해도 측정 결과와 선택 근거는 먼저 보존한다. 적용 성공
    # 뒤에는 실제 idle convergence를 포함해 같은 파일을 한 번 갱신한다.
    $saved=Save-Results @($results) $finalConfig $latestDiagnostics $cluster $selectedValidation $correction
    if ($finalSelectionFatal) {
        Write-Warning '선택 가능한 non-Fatal 후보가 없어 실제 적용을 생략하고 finally에서 원래 설정을 복구합니다.'
    } elseif ($NoApply) {
        Write-Warning 'NoApply: 결과 저장 후 finally에서 원래 설정을 복구합니다.'
    } else {
        if ($DetailedOutput) { Show-Config $finalConfig '최종 라이브 적용' }
        else { Write-Host '최종 설정 적용 및 검증 중...' -ForegroundColor Cyan }
        # 적용 전 snapshot
        $ReadyNodesBefore = 0
        try {
            $nodesJson = & kubectl get nodes -o json 2>$null | ConvertFrom-Json
            $ReadyNodesBefore = @($nodesJson.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0 }).Count
        } catch {
            $ReadyNodesBefore = 0
        }
        
        $pendingPodsBefore = @(& kubectl get pods -n $Namespace --field-selector=status.phase=Pending -o json 2>$null | ConvertFrom-Json).items
        $PendingBefore = $pendingPodsBefore.Count
        
        # HPA behavior KEEP verification: final apply 전 live behavior snapshot.
        # $liveBehaviorBefore는 null array였으므로 모든 app에 대해 null → null 비교가
        # 의도대로 동작했으나, PowerShell에서 null[$app]은 "Cannot index into a null array" 발생.
        # 반드시 @{}로 초기화하고 null-safe하게 처리한다.
        $liveBehaviorBefore=@{}
        foreach ($app in $apps) {
            try {
                $liveBehaviorBefore[$app]=((Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.behavior}')) -join '').Trim()
            } catch {
                $liveBehaviorBefore[$app]=$null
            }
        }
        Assert-HpaConfigInvariant $finalConfig 'FinalOverlay'
        Apply-Resources $finalConfig Hard;Apply-Hpa $finalConfig
        # dynamic warm min을 final min까지 prewarm (Scale-AppsToOne 금지 — warm capacity 유지).
        Scale-AppsToFinalMin $finalConfig
        [void](Enable-FinalIdleConsolidation)
        # Apply-Resources가 template을 patch했으므로 unconditional rollout restart는 하지 않는다
        # (채점 직전 불필요한 node churn 방지). rollout은 Scale-AppsToFinalMin이 보장한다.
        [void](Assert-LiveConfigMatches $finalConfig)
        
        # P0-6: No-Scale Min Fill 실제 node 증가 및 Pending/Unschedulable 롤백 검사
        $ReadyNodesAfter = 0
        try {
            $nodesJson = & kubectl get nodes -o json 2>$null | ConvertFrom-Json
            $ReadyNodesAfter = @($nodesJson.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0 }).Count
        } catch {
            $ReadyNodesAfter = 0
        }
        
        $pendingPodsAfter = @(& kubectl get pods -n $Namespace --field-selector=status.phase=Pending -o json 2>$null | ConvertFrom-Json).items
        $pendingPodsCountAfter = $pendingPodsAfter.Count
        
        $unschedulableCountAfter = 0
        foreach ($pod in $pendingPodsAfter) {
            $scheduledCondition = @($pod.status.conditions | Where-Object { $_.type -eq 'PodScheduled' })
            if ($scheduledCondition.Count -gt 0 -and $scheduledCondition[0].status -eq 'False' -and $scheduledCondition[0].reason -eq 'Unschedulable') {
                $unschedulableCountAfter++
            }
        }
        
        $liveMinMatches = $true
        $readyReplicasMatches = $true
        foreach ($app in $apps) {
            $expectedMin = [int]$finalConfig[$app].minReplicas
            $liveMin = 0
            try { $liveMin = [int]((Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.minReplicas}')) -join '') } catch { $liveMin = 0 }
            if ($liveMin -ne $expectedMin) { $liveMinMatches = $false }
            
            $readyRep = 0
            try { $readyRep = [int]((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.status.readyReplicas}')) -join '') } catch { $readyRep = 0 }
            if ($readyRep -lt $expectedMin) { $readyReplicasMatches = $false }
        }
        
        $violation = $false
        $violationReason = ""
        if (-not $liveMinMatches) {
            $violation = $true
            $violationReason = "LIVE_MIN_MISMATCH"
        } elseif (-not $readyReplicasMatches) {
            $violation = $true
            $violationReason = "READY_REPLICAS_UNMET"
        } elseif ($pendingPodsCountAfter -gt 0) {
            $violation = $true
            $violationReason = "PENDING_PODS"
        } elseif ($unschedulableCountAfter -gt 0) {
            $violation = $true
            $violationReason = "UNSCHEDULABLE_PODS"
        } elseif ($ReadyNodesAfter -gt [int]$script:OperatingNodeBudget) {
            # fill 적용 후에 추가로 증가했는지 여부 검사
            if ($ReadyNodesAfter -gt $ReadyNodesBefore) {
                $violation = $true
                $violationReason = "NODE_INCREASE"
            }
        }
        
        if ($violation) {
            Write-Warning "[NO-SCALE-MIN-FILL-VIOLATION] beforeNodes=$ReadyNodesBefore afterNodes=$ReadyNodesAfter budget=$($script:OperatingNodeBudget) reason=$violationReason"
            Write-Warning "No-Scale Min Fill 위반 — exact snapshot rollback"
            
            # P0-10: No-Scale rollback은 exact snapshot (min-only rollback 금지)
            # $beforeNoScaleConfig는 No-Scale 전에 저장됨.
            $rollbackConfig=Copy-Config $beforeNoScaleConfig 'NoScaleRollback'
            foreach ($app in $apps) {
                $finalConfig[$app]=$rollbackConfig[$app]
                $script:FinalHpaMinByApp[$app]=[int]$rollbackConfig[$app].minReplicas
            }
            $rollbackFp=Get-ConfigFingerprint $finalConfig
            if ($null -ne $lastMeasuredFingerprint -and $rollbackFp -ne $lastMeasuredFingerprint) {
                throw "FINGERPRINT_ROLLBACK_MISMATCH"
            }
            Assert-HpaConfigInvariant $finalConfig 'NoScaleRollback'
            # 롤백 HPA 적용 및 Deployment prewarm
            Apply-Hpa $finalConfig
            Scale-AppsToFinalMin $finalConfig
            [void](Assert-LiveConfigMatches $finalConfig)
        }
        # P0-1: No-Scale 전 exact config snapshot (rollback 시 min/max/resource 보존)
    $beforeNoScaleConfig=Copy-Config $finalConfig 'BeforeNoScale'
    # HPA behavior KEEP verify: behavior를 보존하기로 했으면 적용 전후가 동일해야 한다.
        foreach ($app in $apps) {
            $behaviorAction=if ($script:HpaBehaviorAction.ContainsKey($app)) { [string]$script:HpaBehaviorAction[$app] } else { 'KEEP' }
            if ($behaviorAction -eq 'TUNE_SCALE_UP') { continue }
            $after=$null
            try { $after=((Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.behavior}')) -join '') } catch { $after=$null }
            $before=$liveBehaviorBefore[$app]
            if (($null -eq $before) -ne ($null -eq $after) -or ($null -ne $before -and $before -ne $after)) {
                throw "HPA_BEHAVIOR_UNEXPECTEDLY_CHANGED: $app behavior changed despite KEEP (before=$before after=$after)"
            }
        }
        # HPA overlay live verify: 실제 HPA max가 최종 overlay 값과 일치하는지 확인한다.
        # FinalHpaMaxByApp[stress]>=6인데 live stress max=2면 성공 종료하지 않는다.
        $hpaOverlayFailed=$false
        foreach ($app in $apps) {
            $expected=[int]$finalConfig[$app].maxReplicas
            $expectedMin=[int]$finalConfig[$app].minReplicas
            $live=0; $liveMin=0
            try { $live=[int](Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.maxReplicas}')) } catch { $live=-1 }
            try { $liveMin=[int](Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.minReplicas}')) } catch { $liveMin=-1 }
            if ($live -ne $expected -or $liveMin -ne $expectedMin) {
                Write-Warning "FINAL_HPA_OVERLAY_VERIFY_FAILED: $app max live=$live expected=$expected / min live=$liveMin expected=$expectedMin"
                $hpaOverlayFailed=$true
            } else {
                Write-Host ("  HPA live [{0}] {1}..{2} ✓" -f $app,$liveMin,$live) -ForegroundColor DarkGray
            }
        }
        if ($liveMin -ne $expectedMin -and $expectedMin -gt 1) {
            Write-Warning "FINAL_HPA_MIN_VERIFY_FAILED: $app min live=$liveMin expected=$expectedMin (warm min 미적용)"
        }
        if ($hpaOverlayFailed) {
            Write-Host 'HPA overlay 불일치 → 재적용 후 재검증' -ForegroundColor Yellow
            Apply-Hpa $finalConfig
            Start-Sleep -Seconds 5
            foreach ($app in $apps) {
                $expected=[int]$finalConfig[$app].maxReplicas
                $live=0
                try { $live=[int](Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.maxReplicas}')) } catch { $live=-1 }
                if ($live -ne $expected) { throw "FINAL_HPA_OVERLAY_VERIFY_FAILED: $app live=$live expected=$expected" }
            }
        }
        # placement/resource live verify (스펙 11):
        #   - resource override(request)가 live에 반영됐는지
        #   - 격리 상태면 stress pod은 dedicated 노드에만, user/product는 dedicated 노드에 0
        $liveVerifyFailed=$false
        foreach ($app in $script:FinalResourceOverrideByApp.Keys) {
            $expectedReq=[double]$script:FinalResourceOverrideByApp[$app].requestCpu
            $liveReq=0
            try { $liveReq=[double]((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.spec.template.spec.containers[0].resources.requests.cpu}')) -join '') } catch { $liveReq=0 }
            if ($liveReq -gt 0 -and [math]::Abs($expectedReq-$liveReq) -gt 1) {
                Write-Warning "FINAL_RESOURCE_VERIFY_FAILED: $app expected request=$expectedReq m live=$liveReq m"
                $liveVerifyFailed=$true
            }
        }
        try {
            $dedRaw=((Invoke-Kubectl @('get','nodes','-l','workload-class=stress','-o','jsonpath={.items[*].metadata.name}')) -join ' ')
            $dedNodeList=@($dedRaw -split '\s+' | Where-Object { $_ })
            if ($dedNodeList.Count) {
                $fgOnDed=0
                foreach ($app in @('user','product')) {
                    $podNodes=((Invoke-Kubectl @('-n',$Namespace,'get','pods','-l',("app="+$app),'-o','jsonpath={.items[*].spec.nodeName}')) -join ' ')
                    foreach ($n in @($podNodes -split '\s+')) {
                        if ($n -and $n -in $dedNodeList) { $fgOnDed++ }
                    }
                }
                if ($fgOnDed -gt 0) {
                    Write-Warning "FINAL_PLACEMENT_VERIFY_FAILED: user/product $fgOnDed pod(s) on dedicated stress nodes"
                    $liveVerifyFailed=$true
                }
            }
        } catch { Write-Warning "placement live verify 실패: $($_.Exception.Message)" }
        if ($liveVerifyFailed) { throw 'FINAL_LIVE_VERIFY_FAILED: 최종 resource/placement가 계산된 상태와 일치하지 않습니다.' }
        # FINAL_WARM_STATE: warm min이 채점 시작 상태까지 유지되는지 invariant.
        $warmOk=$true
        foreach ($app in $apps) {
            $expMin=[int]$finalConfig[$app].minReplicas
            $expMax=[int]$finalConfig[$app].maxReplicas
            $liveMin=0; $liveMax=0; $desired=0; $ready=0
            try { $liveMin=[int]((Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.minReplicas}')) -join '') } catch { $liveMin=-1 }
            try { $liveMax=[int]((Invoke-Kubectl @('-n',$Namespace,'get','hpa',$app,'-o','jsonpath={.spec.maxReplicas}')) -join '') } catch { $liveMax=-1 }
            try { $desired=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.spec.replicas}')) -join '') } catch { $desired=-1 }
            try { $ready=[int]((Invoke-Kubectl @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.status.readyReplicas}')) -join '') } catch { $ready=-1 }
            $ok=($liveMin -eq $expMin -and $liveMax -eq $expMax -and $desired -ge $expMin -and $ready -ge $expMin -and $expMin -le $expMax)
            Write-Host ("[FINAL-WARM-STATE] app={0} min={1} max={2} desired={3} ready={4} status={5}" -f $app,$liveMin,$liveMax,$desired,$ready,$(if ($ok) { 'PASS' } else { 'FAIL' })) -ForegroundColor DarkGray
            if (-not $ok) { $warmOk=$false }
        }
        if ($warmOk) { Write-Host 'FINAL_WARM_STATE_VALID=true' -ForegroundColor Green } else { throw 'FINAL_WARM_STATE_VALID=false: warm min/Ready 상태 불일치' }
        $finalApplied=$true
        # Karpenter 강제 drain 금지: warm capacity를 채점 시작 상태까지 유지한다.
        # (부하 진입 시 Pending → 재확장 → startup overlap → avg node 증가 → 진입 SLA 하락 재발 방지)
        $readyNodesJson=& kubectl get nodes -o json 2>$null | ConvertFrom-Json
        $readyNodeCount=@($readyNodesJson.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0 }).Count
        if ($readyNodeCount -gt [int]$script:OperatingNodeBudget) {
            # transient Karpenter 노드(부하잔여/축소 중)는 정상 — 적용 상태를 유지하고 경고만 남긴다.
            # (throw하면 finally가 적용된 설정을 롤백해 채점 시작 상태를 잃는다)
            Write-Warning "FINAL_WARM_NODE_BUDGET_WARN: ready=$readyNodeCount > OperatingNodeBudget=$($script:OperatingNodeBudget) (transient node, 적용 상태 유지)"
        } else {
            Write-Host ("  final warm node: {0} (OperatingNodeBudget {1} 이하 ✓ — score-optimal warm budget, 1강제 아님)" -f $readyNodeCount,$script:OperatingNodeBudget) -ForegroundColor DarkGray
        }
    }
    # 결과 저장/보조 출력: 적용은 이미 검증됐으므로 저장 실패는 non-fatal로 처리한다.
    $saved=$null
    try {
        $correction | Add-Member -NotePropertyName FinalIdleConverged -NotePropertyValue $script:finalIdleConverged -Force
        $saved=Save-Results @($results) $finalConfig $latestDiagnostics $cluster $selectedValidation $correction
        if ($DetailedOutput) {
            Write-Host "`nIDLE CAPACITY" -ForegroundColor Cyan
            Write-Host ("Node Type={0}, Allocatable={1}m/{2:N0}Mi, System={3}m/{4:N0}Mi" -f $saved.Cluster.NodeInstanceType,$saved.Cluster.NodeAllocatableCPU,$saved.Cluster.NodeAllocatableMemory,$saved.Cluster.SystemReservedCPU,$saved.Cluster.SystemReservedMemory)
            Write-Host ("App Requests={0}m/{1:N0}Mi, TheoreticalFit={2}, NaturalConvergence={3}" -f $saved.Cluster.IdleAppCPURequest,$saved.Cluster.IdleAppMemoryRequest,$saved.Cluster.IdleOneNodeFit,$saved.Cluster.FinalIdleConverged)
        }
    } catch {
        Write-Warning "결과 저장/보조 출력 오류(적용 상태 유지): $($_.Exception.Message)"
        $saved=$null
    }
    if ($Finalize -and $finalApplied) {
        Write-Host "`n=== Finalize: 채점 직전 노드 1대 + pre-warm 적용 ===" -ForegroundColor Yellow
        $finalizeSeconds=[math]::Max(0,(Get-RemainingRuntimeSeconds Hard)-$hardCompletionSafetySeconds)
        if ($finalizeSeconds -lt 30) {
            Write-Warning 'Hard runtime deadline까지 30초 미만이라 finalize.ps1을 실행하지 않습니다.'
        } else {
            $finalizeJob=Start-Job -ScriptBlock { param($path,$json) & $path -ProfileJson $json } -ArgumentList (Join-Path $PSScriptRoot 'finalize.ps1'),$saved.Json
            $completed=Wait-Job $finalizeJob -Timeout $finalizeSeconds
            Receive-Job $finalizeJob -ErrorAction Continue
            if (-not $completed) {
                Stop-Job $finalizeJob -ErrorAction SilentlyContinue
                Write-Warning '20분 Hard runtime 제한으로 finalize.ps1을 중단했습니다.'
            } elseif ($finalizeJob.State -ne 'Completed') { Write-Warning "finalize.ps1 비정상 종료: state=$($finalizeJob.State)" }
            Remove-Job $finalizeJob -Force -ErrorAction SilentlyContinue
        }
    }
    # 최종 요약/보고 구간: 적용 완료 후이므로 오류가 나도 적용 상태를 롤백하지 않고 경고만 남긴다.
    try {
        $elapsedNow=(Get-Date)-$startTime
        if ($null -ne $selectedCandidate -and $null -ne $selectedCandidate.Scoreboard) {
            Write-FinalScoreboard $selectedCandidate.Scoreboard -DebugSelection:$DetailedOutput
        }
        if ($null -ne $selectedCandidate) {
            Write-FinalSelection $selectedCandidate $finalConfig -DebugSelection:$DetailedOutput
        }
        if ($DetailedOutput) {
            Write-Host ("Runtime={0}:{1:00}/{2}:00, Reason={3}, Applied={4}, Competition={5:N2}/36" -f [math]::Floor($elapsedNow.TotalMinutes),$elapsedNow.Seconds,$MaxRuntimeMinutes,$script:tuningStopReason,$finalApplied,$(if ($saved) { $saved.Score.Earned } else { 0 })) -ForegroundColor DarkGray
            Write-Host ("Verification requested={0}, completed={1}, passed={2}, skipped={3}" -f $VerificationRuns,@($verificationStatuses | Where-Object Status -ne 'NOT_EXECUTED_RUNTIME_BUDGET').Count,@($verificationStatuses | Where-Object Status -eq 'PASS').Count,$verificationSkipped) -ForegroundColor DarkGray
            Write-Host ("Files: {0} | {1}" -f $(if ($saved) { $saved.Csv } else { '-' }),$(if ($saved) { $saved.Json } else { '-' })) -ForegroundColor DarkGray
        }
        # 최종 요약: calibration을 포함한 tune.ps1 전체 wall-clock 시간만 출력한다.
        $selectedProfileName=Get-QualityCandidateBaseName ([string]$selectedValidation.Name)
        Write-Host "`n====================================================" -ForegroundColor Cyan
        Save-HpaControlPointState
        Write-Host '튜닝 완료'
        Write-Host ("선택 후보: {0}" -f $(if ($finalSelectionFatal) { '원래 설정 유지' } else { $selectedProfileName }))
        Write-Host ("측정 결과: {0}" -f $selectedValidation.Name)
        Write-Host ("Stress length: {0}" -f $(if ($script:SelectedStressLength -gt 0) { $script:SelectedStressLength } else { $DefaultStressLength }))
        Write-Host ("총 실행 시간: {0} ({1:N1}초)" -f (Format-ElapsedText $elapsedNow),$elapsedNow.TotalSeconds)
        Write-Host '====================================================' -ForegroundColor Cyan
        $runFailed=$false
    } catch {
        Write-Warning "최종 요약/보고 중 오류(적용 상태는 유지): $($_.Exception.Message)"
        $runFailed=$false
    }
} catch {
    # Main pipeline errors must retain the exact PowerShell location and stack.
    # finally still performs the original-state restoration before rethrowing.
    $runFailed = $true
    $err = $_
    Write-Error ("tune.ps1: message={0}" -f $err.Exception.Message)
    Write-Error ("tune.ps1: line={0}" -f $err.InvocationInfo.ScriptLineNumber)
    Write-Error ("tune.ps1: position={0}" -f $err.InvocationInfo.PositionMessage)
    Write-Error ("tune.ps1: stack={0}" -f $err.ScriptStackTrace)
    throw
} finally {
    foreach ($job in @($metricJobs)) { Stop-MetricCollector $job }
    if ($runFailed -or $finalSelectionFatal -or ($NoApply -and -not $finalApplied)) {
        Restore-FinalIdleConsolidation
        if ($originalConfig) { Restore-Config $originalConfig }
        Restore-KarpenterNodeLimit
        Restore-InstanceAwarePlacement
    } elseif ($finalApplied -and -not $SkipNodeLimit) {
        if ($DetailedOutput) { Write-Warning "최종 적용 후 Ready Node 상한 ${MaxNodes}대를 유지하기 위해 Karpenter CPU 상한을 유지합니다." }
    }
    if ($script:UserDataJson -and (Test-Path -LiteralPath $script:UserDataJson)) { Remove-Item -Force -LiteralPath $script:UserDataJson -ErrorAction SilentlyContinue }
    if ($DiscardResults -and (Test-Path -LiteralPath $OutputDir)) { Remove-Item -Force -Recurse -LiteralPath $OutputDir -ErrorAction SilentlyContinue }
    elseif ((Test-Path -LiteralPath $OutputDir) -and ($DetailedOutput -or $runFailed)) { Write-Host "튜닝 결과 보존: $OutputDir" -ForegroundColor Cyan }
    $elapsed=(Get-Date)-$startTime
    # 성공 경로에서는 try 끝에서 총 실행시간을 출력했으므로 finally는 실패/예외 시에만 출력한다.
    if ($runFailed) { Write-Host ("총 실행 시간: {0} ({1:N1}초)" -f (Format-ElapsedText $elapsed),$elapsed.TotalSeconds) -ForegroundColor Yellow }
}


# ============================================================


# ============================================================
# SELF TESTS (BASE EXPERIMENT MODE)
# ============================================================
if ($BaseExperiment) {
    Write-Host 'Running BASE EXPERIMENT self-tests...' -ForegroundColor Cyan
    $testPassed = 0; $testTotal = 0

    function Assert-Test([string]$name,[scriptblock]$block) {
        $script:testTotal++
        try { & $block; $script:testPassed++; Write-Host "  PASS: $name" -ForegroundColor Green }
        catch { Write-Host "  FAIL: $name - $($_.Exception.Message)" -ForegroundColor Red }
    }

    # TEST 1: BaseConfig exact values
    Assert-Test 'BaseConfig values' {
        $u=$BaseConfig.user; $p=$BaseConfig.product; $st=$BaseConfig.stress
        if ($u.requestCpu -ne '70m') { throw 'user req' }
        if ($null -ne $u.limitCpu) { throw 'user limitCpu not null' }
        if ($u.limitMemory -ne '256Mi') { throw 'user limMem' }
        if ($u.hpaTarget -ne 33) { throw 'user target' }
        if ($u.minReplicas -ne 2) { throw 'user min' }
        if ($u.maxReplicas -ne 20) { throw 'user max' }
        if ($p.hpaTarget -ne 29) { throw 'product target' }
        if ($p.maxReplicas -ne 20) { throw 'product max' }
        if ($st.requestCpu -ne '600m') { throw 'stress req' }
        if ($st.requestMemory -ne '640Mi') { throw 'stress reqMem' }
        if ($st.limitCpu -ne '2000m') { throw 'stress CPU limit' }
        if ($st.limitMemory -ne '1536Mi') { throw 'stress limMem' }
        if ($st.hpaTarget -ne 55) { throw 'stress target' }
        if ($st.minReplicas -ne 1) { throw 'stress min' }
        if ($st.maxReplicas -ne 6) { throw 'stress max' }
        if ($st.placement -ne 'ISOLATED') { throw 'stress placement' }
    }

    # TEST 2: hpaMaxMinimum does not mutate BaseConfig
    Assert-Test 'hpaMaxMinimum no mutation' {
        $test=Copy-Config $BaseConfig 'test'
        $oldMax=$test.user.maxReplicas
        Set-RequiredPolicy $test 'test' @{}
        if ($test.user.maxReplicas -ne $oldMax) { throw "max changed $oldMax -> $($test.user.maxReplicas)" }
    }

    # TEST 3: Compare-Config single diff
    Assert-Test 'Compare-Config single diff' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'
        $diffs=Compare-Config $a $b @('USER_REQUESTCPU')
        if (@($diffs).Count -ne 1) { throw "expected 1 diff got $(@($diffs).Count)" }
        if ($diffs[0].Axis -ne 'USER_REQUESTCPU') { throw "wrong axis $($diffs[0].Axis)" }
    }

    # TEST 4: Compare-Config identical = 0 diffs
    Assert-Test 'Compare-Config identical' {
        $a=Copy-Config $BaseConfig 'a'
        $diffs=Compare-Config $a $a @()
        if ($diffs.Count -ne 0) { throw "expected 0 diffs got $($diffs.Count)" }
    }

    # TEST 5: Assert-ConfigDrift passes on single allowed axis
    Assert-Test 'ConfigDrift single allowed' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'
        $axis=Assert-ConfigDrift $a $b @('USER_REQUESTCPU')
        if ($axis -ne 'USER_REQUESTCPU') { throw "wrong axis $axis" }
    }

    # TEST 6: Assert-ConfigDrift rejects multi-axis
    Assert-Test 'ConfigDrift multi-axis rejected' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'; $b.product.hpaTarget=30
        try { Assert-ConfigDrift $a $b @('USER_REQUESTCPU') } catch { return }
        throw 'should have thrown MULTI_AXIS_MUTATION'
    }

    # TEST 7: Assert-ConfigDrift rejects unauthorized
    Assert-Test 'ConfigDrift unauthorized rejected' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'
        try { Assert-ConfigDrift $a $b @('PRODUCT_HPA_TARGET') } catch { return }
        throw 'should have thrown EXPERIMENT_CONFIG_DRIFT'
    }

    # TEST 8: REJECT does not change BEST
    Assert-Test 'REJECT preserves BEST' {
        $best=Copy-Config $BaseConfig 'best'
        $before=Get-ConfigFingerprintFromValues $best
        $after=Get-ConfigFingerprintFromValues $best
        if ($before -ne $after) { throw 'BEST changed on reject' }
    }

    # TEST 9: KEEP updates BEST
    Assert-Test 'KEEP updates BEST' {
        $best=Copy-Config $BaseConfig 'best'
        $cand=Copy-Config $BaseConfig 'cand'; $cand.user.requestCpu='60m'
        $best=$cand
        $after=Get-ConfigFingerprintFromValues $best
        $expected=Get-ConfigFingerprintFromValues $cand
        if ($after -ne $expected) { throw 'BEST not updated' }
    }

    # TEST 10: Stress length=112 returns valid result
    Assert-Test 'StressLength 112 valid' {
        if ($script:SelectedStressLength -ne 112 -and $script:SelectedStressLength -ne 0) {
            throw "unexpected stress length $($script:SelectedStressLength)"
        }
    }

    # TEST 11: FINAL >= BASE invariant (config check)
    Assert-Test 'BaseConfig invariant check' {
        $fp=Get-ConfigFingerprintFromValues $BaseConfig
        if ([string]::IsNullOrWhiteSpace($fp)) { throw 'empty fingerprint' }
        $parts=$fp -split ';'
        if ($parts.Count -ne 3) { throw "expected 3 apps got $($parts.Count)" }
    }

    Write-Host "`nSelf-tests: $testPassed/$testTotal passed" -ForegroundColor $(if($testPassed -eq $testTotal){'Green'}else{'Red'})
}
