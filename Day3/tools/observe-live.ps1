<#
.SYNOPSIS
    실행 즉시 채점용 최소 용량을 준비하고 실제 유입 트래픽에 맞춰 자동 조정한다.
.DESCRIPTION
    인자 없이 실행한다. 추가 트래픽을 만들지 않고 Kubernetes metrics와 애플리케이션
    JSON access log를 분석한다. 시작 시 user CPU 예약을 실측치에 맞추고 stress를 전용
    NodePool에 배치한 뒤 비대칭 warm HPA를 적용한다. 이후 트래픽/CPU 편중/HPA 압력이
    확인되면 minReplicas, maxReplicas, NodePool CPU ceiling과 scale-down/consolidation
    시간을 조정한다. 유휴가 지속되면 HPA warm 상태와 NodePool을 시작 전 기준으로
    단계 복구한다. maxReplicas는 비용을 직접 발생시키지 않으므로 자동 축소하지 않는다.

    시작 프로필은 user CPU request와 stress nodeSelector만 변경하므로 Deployment rollout이
    한 번 발생한다. API/DB/Terraform은 변경하지 않는다. NodePool은 Pod를 직접 생성하지
    않고 허용 ceiling만 bounded 조정한다.
    Ctrl+C로 종료하며 결과는 임시 디렉터리의 JSONL 파일에 기록한다.
.EXAMPLE
    .\tools\observe-live.ps1
.EXAMPLE
    .\tools\observe-live.ps1 -Once -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Namespace = 'app',
    [string]$Region = 'ap-northeast-2',
    [ValidateRange(5, 60)][int]$IntervalSeconds = 10,
    [ValidateRange(30, 300)][int]$DecisionWindowSeconds = 30,
    [ValidateRange(60, 600)][int]$ScaleDownStabilizationSeconds = 600,
    [ValidateRange(120, 1800)][int]$IdleRestoreSeconds = 600,
    [switch]$ObserveOnly,
    [switch]$SkipStartupProfile,
    [switch]$Once,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ExpectedAccountId = '586639730662'
$ManagedApps = @('user', 'product', 'stress')
$MutationOrder = @('stress', 'user', 'product')
$WarmFloor = @{ user = 12; product = 2; stress = 4 }
$MaxSafetyCap = @{ user = 48; product = 20; stress = 12 }
$HpaTargetUtilization = @{ user = 12; product = 29; stress = 55 }
$UserCpuRequest = '200m'
$StressNodePool = 'stress'
$NodePoolApps = @{ default = @('user', 'product'); stress = @('stress') }
$NodePoolSafetyCapNodes = @{ default = 6; stress = 4 }
$FallbackNodeCpu = 2
$ActiveConsolidateAfter = '10m'
$ActivityCpuM = @{ user = 15.0; product = 15.0; stress = 250.0 }
$HotCpuM = @{ user = 50.0; product = 50.0; stress = 500.0 }
$script:History = @()
$script:Baseline = @{}
$script:NodePoolBaseline = @{}
$script:LastMutationUtc = [datetime]::MinValue
$script:LogPath = Join-Path ([IO.Path]::GetTempPath()) ("wsi-live-tune-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Convert-CpuToMillicores([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0.0 }
    if ($Value -match '^([0-9.]+)n$') { return [double]$Matches[1] / 1000000.0 }
    if ($Value -match '^([0-9.]+)u$') { return [double]$Matches[1] / 1000.0 }
    if ($Value -match '^([0-9.]+)m$') { return [double]$Matches[1] }
    return [double]$Value * 1000.0
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    $index = [math]::Max(0, [math]::Min($sorted.Count - 1, $index))
    return [double]$sorted[$index]
}

function Convert-ToUtcDateTime($Value) {
    return [datetimeoffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
}

function Invoke-Kubectl([string[]]$Arguments, [switch]$AllowFailure) {
    $output = @(& kubectl @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "kubectl 실패: kubectl $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return $output
}

function Get-KubeJson([string[]]$Arguments) {
    $raw = (Invoke-Kubectl $Arguments) -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "kubectl JSON 결과가 비어 있습니다: $($Arguments -join ' ')"
    }
    return $raw | ConvertFrom-Json
}

function Test-Prerequisites {
    foreach ($command in @('aws', 'kubectl')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "필수 명령을 찾지 못했습니다: $command"
        }
    }

    $account = ((@(& aws sts get-caller-identity --query Account --output text 2>&1)) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { throw "AWS 자격 증명 확인 실패: $account" }
    if ($account -ne $ExpectedAccountId) {
        throw "AWS 계정 불일치: expected=$ExpectedAccountId actual=$account"
    }

    $context = ((Invoke-Kubectl @('config', 'current-context')) -join '').Trim()
    if ($context -notmatch [regex]::Escape(":eks:${Region}:")) {
        throw "현재 kubectl context의 리전이 $Region 이 아닙니다: $context"
    }
    foreach ($app in $ManagedApps) {
        Invoke-Kubectl @('-n', $Namespace, 'get', 'deployment', $app, '-o', 'name') | Out-Null
        Invoke-Kubectl @('-n', $Namespace, 'get', 'hpa', $app, '-o', 'name') | Out-Null
    }
    foreach ($pool in $NodePoolApps.Keys) {
        Invoke-Kubectl @('get', 'nodepool', $pool, '-o', 'name') | Out-Null
    }
}

function Get-HpaScaleDownSeconds($Hpa) {
    $value = $Hpa.spec.behavior.scaleDown.stabilizationWindowSeconds
    if ($null -eq $value) { return 300 }
    return [int]$value
}

function Get-NodePoolConsolidateAfter($NodePool) {
    $value = [string]$NodePool.spec.disruption.consolidateAfter
    if ([string]::IsNullOrWhiteSpace($value)) { return '1m' }
    return $value
}

function Get-HpaMaxTarget([int]$CurrentMax, [int]$UncappedDesired, [int]$SafetyCap) {
    if ($CurrentMax -ge $SafetyCap) { return $CurrentMax }
    # maxReplicas는 실제 Pod/노드를 만들지 않는 capacity ceiling이다. 채점 spike에서
    # 1→2→4 순차 개방이 초기 가용성을 훼손하므로 pressure가 검증되면 안전 상한을 즉시 연다.
    return $SafetyCap
}

function Initialize-Baseline {
    $hpas = Get-KubeJson @('-n', $Namespace, 'get', 'hpa', '-o', 'json')
    foreach ($app in $ManagedApps) {
        $hpa = @($hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
        if (-not $hpa) { throw "HPA/$app 을 찾지 못했습니다." }

        $annotations = $hpa.metadata.annotations
        $savedMin = $null
        $savedScaleDown = $null
        if ($null -ne $annotations) {
            $savedMin = $annotations.'wsi2026.io/live-tune-baseline-min'
            $savedScaleDown = $annotations.'wsi2026.io/live-tune-baseline-scale-down'
        }
        $baselineMin = if ($null -ne $savedMin -and [string]$savedMin -match '^\d+$') { [int]$savedMin } else { [int]$hpa.spec.minReplicas }
        $baselineScaleDown = if ($null -ne $savedScaleDown -and [string]$savedScaleDown -match '^\d+$') { [int]$savedScaleDown } else { Get-HpaScaleDownSeconds $hpa }
        $script:Baseline[$app] = [pscustomobject]@{
            Min = $baselineMin
            ScaleDownSeconds = $baselineScaleDown
            Max = [int]$hpa.spec.maxReplicas
        }
    }

    $nodePools = Get-KubeJson @('get', 'nodepool', '-o', 'json')
    foreach ($pool in $NodePoolApps.Keys) {
        $nodePool = @($nodePools.items | Where-Object { $_.metadata.name -eq $pool } | Select-Object -First 1)
        if (-not $nodePool) { throw "NodePool/$pool 을 찾지 못했습니다." }
        $annotations = $nodePool.metadata.annotations
        $savedLimit = if ($null -ne $annotations) { $annotations.'wsi2026.io/live-tune-baseline-limit-cpu' } else { $null }
        $savedConsolidate = if ($null -ne $annotations) { $annotations.'wsi2026.io/live-tune-baseline-consolidate-after' } else { $null }
        $baselineLimit = if ($null -ne $savedLimit -and [string]$savedLimit -match '^\d+$') { [int]$savedLimit } else { [int]$nodePool.spec.limits.cpu }
        $baselineConsolidate = if (-not [string]::IsNullOrWhiteSpace([string]$savedConsolidate)) { [string]$savedConsolidate } else { Get-NodePoolConsolidateAfter $nodePool }
        $script:NodePoolBaseline[$pool] = [pscustomobject]@{
            LimitCpu = $baselineLimit
            ConsolidateAfter = $baselineConsolidate
        }
    }
}

function Initialize-PerformanceProfile {
    if ($SkipStartupProfile) {
        Write-Host '시작 성능 프로필 생략(-SkipStartupProfile)' -ForegroundColor Yellow
        return
    }

    $deployments = Get-KubeJson @('-n', $Namespace, 'get', 'deployment', 'user', 'stress', '-o', 'json')
    $userDeployment = @($deployments.items | Where-Object { $_.metadata.name -eq 'user' } | Select-Object -First 1)
    $stressDeployment = @($deployments.items | Where-Object { $_.metadata.name -eq 'stress' } | Select-Object -First 1)
    if (-not $userDeployment -or -not $stressDeployment) { throw 'user/stress Deployment를 찾지 못했습니다.' }

    $userContainer = [string]$userDeployment.spec.template.spec.containers[0].name
    $currentUserRequest = [string]$userDeployment.spec.template.spec.containers[0].resources.requests.cpu
    if ($currentUserRequest -ne $UserCpuRequest) {
        $description = "Deployment/user CPU request $currentUserRequest->$UserCpuRequest (실측 spike 약 300m/pod)"
        if ($ObserveOnly -or -not $PSCmdlet.ShouldProcess("$Namespace/Deployment/user", $description)) {
            Write-Host "[권고] $description" -ForegroundColor Yellow
        } else {
            $patch = @{
                spec = @{ template = @{
                    metadata = @{ annotations = @{ 'wsi2026.io/live-profile' = 'user-200m-v1' } }
                    spec = @{ containers = @(@{ name = $userContainer; resources = @{ requests = @{ cpu = $UserCpuRequest } } }) }
                } }
            } | ConvertTo-Json -Compress -Depth 12
            Write-Host "[적용/rollout] $description" -ForegroundColor Cyan
            Invoke-Kubectl @('-n', $Namespace, 'patch', 'deployment', 'user', '--type=strategic', '-p', $patch) | Out-Null
        }
    }

    $currentStressPool = [string]$stressDeployment.spec.template.spec.nodeSelector.'karpenter.sh/nodepool'
    if ($currentStressPool -ne $StressNodePool) {
        $description = "Deployment/stress nodeSelector -> karpenter.sh/nodepool=$StressNodePool (user 간섭 분리)"
        if ($ObserveOnly -or -not $PSCmdlet.ShouldProcess("$Namespace/Deployment/stress", $description)) {
            Write-Host "[권고] $description" -ForegroundColor Yellow
        } else {
            $patch = @{
                spec = @{ template = @{
                    metadata = @{ annotations = @{ 'wsi2026.io/live-profile' = 'stress-dedicated-v1' } }
                    spec = @{ nodeSelector = @{ 'karpenter.sh/nodepool' = $StressNodePool } }
                } }
            } | ConvertTo-Json -Compress -Depth 10
            Write-Host "[적용/rollout/비용주의] $description" -ForegroundColor Magenta
            Invoke-Kubectl @('-n', $Namespace, 'patch', 'deployment', 'stress', '--type=merge', '-p', $patch) | Out-Null
        }
    }

    $hpas = Get-KubeJson @('-n', $Namespace, 'get', 'hpa', '-o', 'json')
    foreach ($app in $MutationOrder) {
        $hpa = @($hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
        $targetMin = [int][math]::Max([int]$script:Baseline[$app].Min, [int]$WarmFloor[$app])
        $targetMax = [int]$MaxSafetyCap[$app]
        $targetUtil = [int]$HpaTargetUtilization[$app]
        $currentUtil = [int]$hpa.spec.metrics[0].resource.target.averageUtilization
        if ([int]$hpa.spec.minReplicas -eq $targetMin -and [int]$hpa.spec.maxReplicas -eq $targetMax -and
            $currentUtil -eq $targetUtil -and (Get-HpaScaleDownSeconds $hpa) -eq $ScaleDownStabilizationSeconds) { continue }

        $description = "HPA/$app min=$targetMin max=$targetMax target=${targetUtil}% scaleDown=${ScaleDownStabilizationSeconds}s"
        if ($ObserveOnly -or -not $PSCmdlet.ShouldProcess("$Namespace/HPA/$app", $description)) {
            Write-Host "[권고] $description" -ForegroundColor Yellow
            continue
        }
        $patch = @{
            metadata = @{ annotations = @{
                'wsi2026.io/live-tune-baseline-min' = [string]$script:Baseline[$app].Min
                'wsi2026.io/live-tune-baseline-scale-down' = [string]$script:Baseline[$app].ScaleDownSeconds
                'wsi2026.io/live-profile' = 'performance-first-v1'
            } }
            spec = @{
                minReplicas = $targetMin
                maxReplicas = $targetMax
                metrics = @(@{ type = 'Resource'; resource = @{ name = 'cpu'; target = @{ type = 'Utilization'; averageUtilization = $targetUtil } } })
                behavior = @{ scaleDown = @{ stabilizationWindowSeconds = $ScaleDownStabilizationSeconds } }
            }
        } | ConvertTo-Json -Compress -Depth 12
        Write-Host "[적용/비용주의] $description" -ForegroundColor Magenta
        Invoke-Kubectl @('-n', $Namespace, 'patch', 'hpa', $app, '--type=merge', '-p', $patch) | Out-Null
    }

    if (-not $ObserveOnly -and -not $WhatIfPreference) {
        $verifyUser = Get-KubeJson @('-n', $Namespace, 'get', 'deployment', 'user', '-o', 'json')
        $verifyStress = Get-KubeJson @('-n', $Namespace, 'get', 'deployment', 'stress', '-o', 'json')
        if ([string]$verifyUser.spec.template.spec.containers[0].resources.requests.cpu -ne $UserCpuRequest) {
            throw '시작 프로필 검증 실패: user CPU request'
        }
        if ([string]$verifyStress.spec.template.spec.nodeSelector.'karpenter.sh/nodepool' -ne $StressNodePool) {
            throw '시작 프로필 검증 실패: stress nodeSelector'
        }
    }
}

function Get-AccessLogMetric([string]$App) {
    $sinceSeconds = [math]::Max($IntervalSeconds + 2, 7)
    $lines = @(Invoke-Kubectl @('-n', $Namespace, 'logs', '-l', "app=$App", '--all-containers=true', "--since=${sinceSeconds}s", '--tail=-1', '--max-log-requests=30') -AllowFailure)
    $requests = 0
    $errors = 0
    $durations = [System.Collections.Generic.List[double]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace([string]$line) -or [string]$line -notmatch '^\s*\{') { continue }
        try { $entry = ([string]$line) | ConvertFrom-Json } catch { continue }
        if ($entry.path -eq '/healthcheck') { continue }
        if ($null -eq $entry.status) { continue }
        $requests++
        if ([int]$entry.status -ge 500) { $errors++ }
        if ($null -ne $entry.dur_ms) { $durations.Add([double]$entry.dur_ms) }
    }
    $p95 = Get-Percentile $durations.ToArray() 95
    return [pscustomobject]@{
        Requests = $requests
        Errors = $errors
        ErrorRate = if ($requests -gt 0) { [double]$errors / $requests } else { 0.0 }
        P95Ms = $p95
    }
}

function Get-LiveSnapshot {
    $now = [datetime]::UtcNow
    $hpas = Get-KubeJson @('-n', $Namespace, 'get', 'hpa', '-o', 'json')
    $pods = Get-KubeJson @('-n', $Namespace, 'get', 'pods', '-o', 'json')
    $podMetrics = $null
    try {
        $podMetrics = Get-KubeJson @('get', '--raw', "/apis/metrics.k8s.io/v1beta1/namespaces/$Namespace/pods")
    } catch {
        Write-Warning "metrics-server 조회 실패: $($_.Exception.Message)"
        $podMetrics = [pscustomobject]@{ items = @() }
    }
    $nodes = Get-KubeJson @('get', 'nodes', '-o', 'json')
    $nodePools = Get-KubeJson @('get', 'nodepool', '-o', 'json')

    $podApp = @{}
    $readyByApp = @{}
    $pendingByApp = @{}
    foreach ($app in $ManagedApps) { $readyByApp[$app] = 0; $pendingByApp[$app] = 0 }
    foreach ($pod in $pods.items) {
        $app = [string]$pod.metadata.labels.app
        if ($app -notin $ManagedApps) { continue }
        $podApp[[string]$pod.metadata.name] = $app
        $ready = @($pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        if ($ready) { $readyByApp[$app]++ }
        if ($pod.status.phase -eq 'Pending') { $pendingByApp[$app]++ }
    }

    $cpuByApp = @{}
    foreach ($app in $ManagedApps) { $cpuByApp[$app] = [System.Collections.Generic.List[double]]::new() }
    foreach ($metricPod in $podMetrics.items) {
        $name = [string]$metricPod.metadata.name
        if (-not $podApp.ContainsKey($name)) { continue }
        $app = $podApp[$name]
        $cpuM = 0.0
        foreach ($container in $metricPod.containers) { $cpuM += Convert-CpuToMillicores ([string]$container.usage.cpu) }
        $cpuByApp[$app].Add($cpuM)
    }

    $apps = @{}
    foreach ($app in $ManagedApps) {
        $hpa = @($hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
        $cpuValues = @($cpuByApp[$app].ToArray())
        $cpuTotal = if ($cpuValues.Count) { [double](($cpuValues | Measure-Object -Sum).Sum) } else { 0.0 }
        $cpuMax = if ($cpuValues.Count) { [double](($cpuValues | Measure-Object -Maximum).Maximum) } else { 0.0 }
        $cpuAverage = if ($cpuValues.Count) { [double](($cpuValues | Measure-Object -Average).Average) } else { 0.0 }
        $currentUtil = 0
        if ($hpa.status.currentMetrics) {
            $resourceMetric = @($hpa.status.currentMetrics | Where-Object { $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' } | Select-Object -First 1)
            if ($resourceMetric -and $null -ne $resourceMetric.resource.current.averageUtilization) {
                $currentUtil = [int]$resourceMetric.resource.current.averageUtilization
            }
        }
        $targetUtil = [int]$hpa.spec.metrics[0].resource.target.averageUtilization
        $logMetric = Get-AccessLogMetric $app
        $apps[$app] = [pscustomobject]@{
            Ready = [int]$readyByApp[$app]
            Pending = [int]$pendingByApp[$app]
            Current = [int]$hpa.status.currentReplicas
            Desired = [int]$hpa.status.desiredReplicas
            Min = [int]$hpa.spec.minReplicas
            Max = [int]$hpa.spec.maxReplicas
            CurrentUtil = $currentUtil
            TargetUtil = $targetUtil
            ScaleDownSeconds = Get-HpaScaleDownSeconds $hpa
            CpuTotalM = [math]::Round($cpuTotal, 1)
            CpuAverageM = [math]::Round($cpuAverage, 1)
            CpuMaxM = [math]::Round($cpuMax, 1)
            HotRatio = if ($cpuAverage -gt 0) { [math]::Round($cpuMax / $cpuAverage, 2) } else { 0.0 }
            Requests = [int]$logMetric.Requests
            Errors = [int]$logMetric.Errors
            ErrorRate = [double]$logMetric.ErrorRate
            P95Ms = $logMetric.P95Ms
        }
    }

    $readyNodes = 0
    $notReadyNodes = 0
    foreach ($node in $nodes.items) {
        $ready = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        if ($ready) { $readyNodes++ } else { $notReadyNodes++ }
    }
    $poolState = @{}
    foreach ($pool in $NodePoolApps.Keys) {
        $nodePool = @($nodePools.items | Where-Object { $_.metadata.name -eq $pool } | Select-Object -First 1)
        if (-not $nodePool) { throw "NodePool/$pool 을 찾지 못했습니다." }
        $usedCpu = if ($null -eq $nodePool.status.resources.cpu) { 0 } else { [int]$nodePool.status.resources.cpu }
        $poolNodes = if ($null -eq $nodePool.status.resources.nodes) { 0 } else { [int]$nodePool.status.resources.nodes }
        $cpuPerNode = if ($poolNodes -gt 0 -and $usedCpu -gt 0) { [int][math]::Ceiling($usedCpu / [double]$poolNodes) } else { $FallbackNodeCpu }
        $poolState[$pool] = [pscustomobject]@{
            LimitCpu = [int]$nodePool.spec.limits.cpu
            UsedCpu = $usedCpu
            Nodes = $poolNodes
            CpuPerNode = $cpuPerNode
            ConsolidateAfter = Get-NodePoolConsolidateAfter $nodePool
        }
    }
    return [pscustomobject]@{
        TimestampUtc = $now.ToString('o')
        Apps = $apps
        NodePools = $poolState
        ReadyNodes = $readyNodes
        NotReadyNodes = $notReadyNodes
    }
}

function Add-Snapshot($Snapshot) {
    $script:History += $Snapshot
    $cutoff = [datetime]::UtcNow.AddSeconds(-[math]::Max($IdleRestoreSeconds + $IntervalSeconds, $DecisionWindowSeconds * 3))
    $script:History = @($script:History | Where-Object { (Convert-ToUtcDateTime $_.TimestampUtc) -ge $cutoff })
    $Snapshot | ConvertTo-Json -Compress -Depth 10 | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
}

function Get-Window([int]$Seconds) {
    $cutoff = [datetime]::UtcNow.AddSeconds(-$Seconds)
    return @($script:History | Where-Object { (Convert-ToUtcDateTime $_.TimestampUtc) -ge $cutoff })
}

function Get-Recommendation([string]$App) {
    $window = @(Get-Window $DecisionWindowSeconds)
    $idleWindow = @(Get-Window $IdleRestoreSeconds)
    if ($window.Count -eq 0) { return $null }
    $metrics = @($window | ForEach-Object { $_.Apps[$App] })
    $latest = $metrics[-1]
    $baseline = $script:Baseline[$App]
    $maxCpu = [double](($metrics.CpuTotalM | Measure-Object -Maximum).Maximum)
    $maxDesired = [int](($metrics.Desired | Measure-Object -Maximum).Maximum)
    $maxUtil = [int](($metrics.CurrentUtil | Measure-Object -Maximum).Maximum)
    $minimumCeilingSamples = [math]::Max(2, [math]::Ceiling($window.Count / 2.0))
    $ceilingMetrics = @($metrics | Where-Object {
        $_.Desired -ge $_.Max -and $_.Current -ge $_.Max -and $_.Ready -ge $_.Current -and
        $_.Pending -eq 0 -and $_.TargetUtil -gt 0 -and $_.CurrentUtil -gt $_.TargetUtil
    })
    $uncappedDesired = if ($ceilingMetrics.Count) {
        [int](($ceilingMetrics | ForEach-Object {
            [math]::Ceiling([double]$_.Current * [double]$_.CurrentUtil / [math]::Max(1.0, [double]$_.TargetUtil))
        } | Measure-Object -Maximum).Maximum)
    } else { [int]$latest.Max }
    $hotObserved = @($metrics | Where-Object { $_.Ready -ge 2 -and $_.CpuMaxM -ge $HotCpuM[$App] -and $_.HotRatio -ge 2.5 }).Count -gt 0
    $requestsObserved = [int](($metrics.Requests | Measure-Object -Sum).Sum) -gt 0
    $active = $requestsObserved -or $maxCpu -ge $ActivityCpuM[$App] -or $maxDesired -gt $baseline.Min
    $pressure = $maxDesired -gt $latest.Min -or ($latest.TargetUtil -gt 0 -and $maxUtil -ge [math]::Floor($latest.TargetUtil * 0.85))

    $idle = $false
    if ($idleWindow.Count -gt 0) {
        $oldest = Convert-ToUtcDateTime $idleWindow[0].TimestampUtc
        $coversIdleWindow = ([datetime]::UtcNow - $oldest).TotalSeconds -ge ($IdleRestoreSeconds - $IntervalSeconds * 2)
        $idleMetrics = @($idleWindow | ForEach-Object { $_.Apps[$App] })
        $idleCpuMax = [double](($idleMetrics.CpuTotalM | Measure-Object -Maximum).Maximum)
        $idleRequests = [int](($idleMetrics.Requests | Measure-Object -Sum).Sum)
        $idleDesired = [int](($idleMetrics.Desired | Measure-Object -Maximum).Maximum)
        $idle = $coversIdleWindow -and $idleRequests -eq 0 -and $idleCpuMax -lt $ActivityCpuM[$App] -and $idleDesired -le $latest.Min
    }

    $targetMin = [int]$latest.Min
    $targetMax = [int]$latest.Max
    $targetScaleDown = [int]$latest.ScaleDownSeconds
    $reason = 'HOLD'
    if ($window.Count -lt 2) {
        $reason = 'WARMUP'
    } elseif ($active -and $ceilingMetrics.Count -ge $minimumCeilingSamples -and $latest.Max -lt $MaxSafetyCap[$App]) {
        $targetMax = Get-HpaMaxTarget ([int]$latest.Max) $uncappedDesired ([int]$MaxSafetyCap[$App])
        $targetScaleDown = [math]::Max([int]$baseline.ScaleDownSeconds, $ScaleDownStabilizationSeconds)
        $reason = 'HPA_MAX_PRESSURE'
    } elseif ($active -and ($pressure -or $hotObserved)) {
        $warmCap = [math]::Min([int]$MaxSafetyCap[$App], [math]::Max([int]$baseline.Min, [int]$WarmFloor[$App]))
        $targetMin = $warmCap
        $targetScaleDown = [math]::Max([int]$baseline.ScaleDownSeconds, $ScaleDownStabilizationSeconds)
        $reason = if ($hotObserved) { 'HOT_POD' } else { 'HPA_PRESSURE' }
    } elseif ($idle) {
        $targetMin = [int]$baseline.Min
        $targetScaleDown = [int]$baseline.ScaleDownSeconds
        $reason = 'IDLE_RESTORE'
    }

    return [pscustomobject]@{
        App = $App
        Reason = $reason
        Active = $active
        HotObserved = $hotObserved
        CurrentMin = [int]$latest.Min
        TargetMin = [int]$targetMin
        CurrentMax = [int]$latest.Max
        TargetMax = [int]$targetMax
        CurrentScaleDown = [int]$latest.ScaleDownSeconds
        TargetScaleDown = [int]$targetScaleDown
        MaxCpuM = [math]::Round($maxCpu, 1)
        MaxDesired = $maxDesired
        MaxUtil = $maxUtil
        CeilingSamples = [int]$ceilingMetrics.Count
        UncappedDesired = [int]$uncappedDesired
    }
}

function Get-NodePoolRecommendation([string]$Pool) {
    $window = @(Get-Window $DecisionWindowSeconds)
    $idleWindow = @(Get-Window $IdleRestoreSeconds)
    if ($window.Count -eq 0) { return $null }
    $latest = $window[-1].NodePools[$Pool]
    $baseline = $script:NodePoolBaseline[$Pool]
    $apps = @($NodePoolApps[$Pool])
    $minimumPressureSamples = [math]::Max(2, [math]::Ceiling($window.Count / 2.0))
    $pressureSamples = @($window | Where-Object {
        if ($_.NotReadyNodes -gt 0) { return $false }
        $poolState = $_.NodePools[$Pool]
        if ($poolState.UsedCpu -lt $poolState.LimitCpu) { return $false }
        foreach ($app in $apps) {
            $metric = $_.Apps[$app]
            if ($metric.Pending -gt 0 -or $metric.Desired -gt $metric.Ready -or
                ($metric.Desired -ge $metric.Max -and $metric.TargetUtil -gt 0 -and $metric.CurrentUtil -gt $metric.TargetUtil)) {
                return $true
            }
        }
        return $false
    })

    $idle = $false
    if ($idleWindow.Count -gt 0) {
        $oldest = Convert-ToUtcDateTime $idleWindow[0].TimestampUtc
        $coversIdleWindow = ([datetime]::UtcNow - $oldest).TotalSeconds -ge ($IdleRestoreSeconds - $IntervalSeconds * 2)
        $busyIdleSamples = @($idleWindow | Where-Object {
            if ($_.NotReadyNodes -gt 0) { return $true }
            foreach ($app in $apps) {
                $metric = $_.Apps[$app]
                if ($metric.Requests -gt 0 -or $metric.CpuTotalM -ge $ActivityCpuM[$app] -or
                    $metric.Desired -gt $metric.Min -or $metric.Pending -gt 0) { return $true }
            }
            return $false
        })
        $idle = $coversIdleWindow -and $busyIdleSamples.Count -eq 0
    }

    $targetLimit = [int]$latest.LimitCpu
    $targetConsolidate = [string]$latest.ConsolidateAfter
    $reason = 'HOLD'
    if ($window.Count -lt 2) {
        $reason = 'WARMUP'
    } elseif ($pressureSamples.Count -ge $minimumPressureSamples) {
        $cpuPerNode = [int][math]::Max(1, $latest.CpuPerNode)
        $safetyCapCpu = [int]$NodePoolSafetyCapNodes[$Pool] * $cpuPerNode
        $targetLimit = $safetyCapCpu
        $targetConsolidate = $ActiveConsolidateAfter
        $reason = if ($targetLimit -gt $latest.LimitCpu) { 'NODEPOOL_PRESSURE' } else { 'NODEPOOL_AT_CAP' }
    } elseif ($idle) {
        $targetConsolidate = [string]$baseline.ConsolidateAfter
        if ($latest.UsedCpu -le $baseline.LimitCpu) { $targetLimit = [int]$baseline.LimitCpu }
        $reason = 'IDLE_RESTORE'
    }

    return [pscustomobject]@{
        Pool = $Pool
        Reason = $reason
        CurrentLimitCpu = [int]$latest.LimitCpu
        TargetLimitCpu = [int]$targetLimit
        UsedCpu = [int]$latest.UsedCpu
        Nodes = [int]$latest.Nodes
        CurrentConsolidateAfter = [string]$latest.ConsolidateAfter
        TargetConsolidateAfter = [string]$targetConsolidate
        PressureSamples = [int]$pressureSamples.Count
    }
}

function Set-SafeNodePoolState($Recommendation) {
    if ($Recommendation.CurrentLimitCpu -eq $Recommendation.TargetLimitCpu -and
        $Recommendation.CurrentConsolidateAfter -eq $Recommendation.TargetConsolidateAfter) { return $false }
    if (([datetime]::UtcNow - $script:LastMutationUtc).TotalSeconds -lt $DecisionWindowSeconds) { return $false }
    $pool = [string]$Recommendation.Pool
    $baseline = $script:NodePoolBaseline[$pool]
    $description = "NodePool/$pool cpu $($Recommendation.CurrentLimitCpu)->$($Recommendation.TargetLimitCpu), consolidate $($Recommendation.CurrentConsolidateAfter)->$($Recommendation.TargetConsolidateAfter) ($($Recommendation.Reason))"
    if ($ObserveOnly -or -not $PSCmdlet.ShouldProcess("NodePool/$pool", $description)) {
        Write-Host "[권고] $description" -ForegroundColor Yellow
        return $false
    }
    $patch = [ordered]@{
        metadata = [ordered]@{ annotations = [ordered]@{
            'wsi2026.io/live-tune-baseline-limit-cpu' = [string]$baseline.LimitCpu
            'wsi2026.io/live-tune-baseline-consolidate-after' = [string]$baseline.ConsolidateAfter
        } }
        spec = [ordered]@{
            limits = [ordered]@{ cpu = [string]$Recommendation.TargetLimitCpu }
            disruption = [ordered]@{ consolidateAfter = [string]$Recommendation.TargetConsolidateAfter }
        }
    } | ConvertTo-Json -Compress -Depth 10
    Write-Host "[적용/비용주의] $description" -ForegroundColor Magenta
    try {
        Invoke-Kubectl @('patch', 'nodepool', $pool, '--type=merge', '-p', $patch) | Out-Null
        $verify = Get-KubeJson @('get', 'nodepool', $pool, '-o', 'json')
        $verifiedLimit = [int]$verify.spec.limits.cpu
        $verifiedConsolidate = Get-NodePoolConsolidateAfter $verify
        if ($verifiedLimit -ne $Recommendation.TargetLimitCpu -or $verifiedConsolidate -ne $Recommendation.TargetConsolidateAfter) {
            throw "검증 불일치: cpu=$verifiedLimit consolidateAfter=$verifiedConsolidate"
        }
        $script:LastMutationUtc = [datetime]::UtcNow
        return $true
    } catch {
        Write-Warning "적용 실패, NodePool/$pool 직전값 복구: $($_.Exception.Message)"
        $rollback = @{ spec = @{ limits = @{ cpu = [string]$Recommendation.CurrentLimitCpu }; disruption = @{ consolidateAfter = [string]$Recommendation.CurrentConsolidateAfter } } } | ConvertTo-Json -Compress -Depth 8
        Invoke-Kubectl @('patch', 'nodepool', $pool, '--type=merge', '-p', $rollback) -AllowFailure | Out-Null
        return $false
    }
}

function Set-SafeHpaState($Recommendation) {
    if ($Recommendation.CurrentMin -eq $Recommendation.TargetMin -and $Recommendation.CurrentMax -eq $Recommendation.TargetMax -and $Recommendation.CurrentScaleDown -eq $Recommendation.TargetScaleDown) {
        return $false
    }
    $app = [string]$Recommendation.App
    $baseline = $script:Baseline[$app]
    $description = "HPA/$app min $($Recommendation.CurrentMin)->$($Recommendation.TargetMin), max $($Recommendation.CurrentMax)->$($Recommendation.TargetMax), scaleDown $($Recommendation.CurrentScaleDown)->$($Recommendation.TargetScaleDown)s ($($Recommendation.Reason))"
    if ($ObserveOnly -or -not $PSCmdlet.ShouldProcess("$Namespace/HPA/$app", $description)) {
        Write-Host "[권고] $description" -ForegroundColor Yellow
        return $false
    }

    $patch = [ordered]@{
        metadata = [ordered]@{
            annotations = [ordered]@{
                'wsi2026.io/live-tune-baseline-min' = [string]$baseline.Min
                'wsi2026.io/live-tune-baseline-scale-down' = [string]$baseline.ScaleDownSeconds
            }
        }
        spec = [ordered]@{
            minReplicas = [int]$Recommendation.TargetMin
            maxReplicas = [int]$Recommendation.TargetMax
            behavior = [ordered]@{
                scaleDown = [ordered]@{ stabilizationWindowSeconds = [int]$Recommendation.TargetScaleDown }
            }
        }
    } | ConvertTo-Json -Compress -Depth 10

    Write-Host "[적용] $description" -ForegroundColor Cyan
    try {
        Invoke-Kubectl @('-n', $Namespace, 'patch', 'hpa', $app, '--type=merge', '-p', $patch) | Out-Null
        $verify = Get-KubeJson @('-n', $Namespace, 'get', 'hpa', $app, '-o', 'json')
        $verifiedMin = [int]$verify.spec.minReplicas
        $verifiedMax = [int]$verify.spec.maxReplicas
        $verifiedScaleDown = Get-HpaScaleDownSeconds $verify
        if ($verifiedMin -ne $Recommendation.TargetMin -or $verifiedMax -ne $Recommendation.TargetMax -or $verifiedScaleDown -ne $Recommendation.TargetScaleDown) {
            throw "검증 불일치: min=$verifiedMin max=$verifiedMax scaleDown=$verifiedScaleDown"
        }
        $script:LastMutationUtc = [datetime]::UtcNow
        return $true
    } catch {
        Write-Warning "적용 실패, HPA/$app 기준값 복구: $($_.Exception.Message)"
        $rollback = @{ spec = @{ minReplicas = [int]$Recommendation.CurrentMin; maxReplicas = [int]$Recommendation.CurrentMax; behavior = @{ scaleDown = @{ stabilizationWindowSeconds = [int]$Recommendation.CurrentScaleDown } } } } | ConvertTo-Json -Compress -Depth 8
        Invoke-Kubectl @('-n', $Namespace, 'patch', 'hpa', $app, '--type=merge', '-p', $rollback) -AllowFailure | Out-Null
        return $false
    }
}

function Show-Snapshot($Snapshot, $Recommendations, $NodePoolRecommendations) {
    $kst = (Convert-ToUtcDateTime $Snapshot.TimestampUtc).ToLocalTime().ToString('HH:mm:ss')
    Write-Host "`n[$kst KST] ReadyNode=$($Snapshot.ReadyNodes) NotReadyNode=$($Snapshot.NotReadyNodes)" -ForegroundColor Green
    $rows = foreach ($app in $ManagedApps) {
        $m = $Snapshot.Apps[$app]
        $r = $Recommendations[$app]
        [pscustomobject]@{
            App = $app
            Pod = "$($m.Ready)/$($m.Desired)"
            HPA = "$($m.CurrentUtil)%/$($m.TargetUtil)%"
            Cpu = "$($m.CpuTotalM)m"
            Hot = $m.HotRatio
            Req = $m.Requests
            Err = $m.Errors
            P95ms = if ($null -eq $m.P95Ms) { '-' } else { [math]::Round([double]$m.P95Ms, 1) }
            Min = "$($m.Min)->$($r.TargetMin)"
            Max = "$($m.Max)->$($r.TargetMax)"
            Decision = $r.Reason
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
    $poolRows = foreach ($pool in @('default', 'stress')) {
        $m = $Snapshot.NodePools[$pool]
        $r = $NodePoolRecommendations[$pool]
        [pscustomobject]@{
            NodePool = $pool
            Nodes = $m.Nodes
            Cpu = "$($m.UsedCpu)/$($m.LimitCpu)->$($r.TargetLimitCpu)"
            Consolidate = "$($m.ConsolidateAfter)->$($r.TargetConsolidateAfter)"
            Decision = $r.Reason
        }
    }
    $poolRows | Format-Table -AutoSize | Out-Host
}

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ([math]::Abs((Convert-CpuToMillicores '1970000000n') - 1970.0) -gt 0.001) { $failures.Add('nanocore 변환') }
    if ([math]::Abs((Convert-CpuToMillicores '250m') - 250.0) -gt 0.001) { $failures.Add('millicore 변환') }
    if ((Get-Percentile ([double[]]@(1, 2, 3, 4, 100)) 95) -ne 100) { $failures.Add('P95 계산') }
    if ($WarmFloor.user -ne 12 -or $WarmFloor.product -ne 2 -or $WarmFloor.stress -ne 4) { $failures.Add('비대칭 warm floor') }
    if ($UserCpuRequest -ne '200m' -or $HpaTargetUtilization.user -ne 12) { $failures.Add('user control point profile') }
    $script:Baseline['stress'] = [pscustomobject]@{ Min = 1; ScaleDownSeconds = 0; Max = 12 }
    $pressure = [pscustomobject]@{
        Ready = 2; Pending = 0; Current = 2; Desired = 6; Min = 1; Max = 12
        CurrentUtil = 100; TargetUtil = 55; ScaleDownSeconds = 0
        CpuTotalM = 1800.0; CpuAverageM = 900.0; CpuMaxM = 1700.0; HotRatio = 1.89
        Requests = 2; Errors = 0; ErrorRate = 0.0; P95Ms = 900.0
    }
    $now = [datetime]::UtcNow
    $script:History = @(
        [pscustomobject]@{ TimestampUtc = $now.AddSeconds(-5).ToString('o'); Apps = @{ stress = $pressure } },
        [pscustomobject]@{ TimestampUtc = $now.ToString('o'); Apps = @{ stress = $pressure } }
    )
    $recommendation = Get-Recommendation 'stress'
    if ($recommendation.TargetMin -ne 4) { $failures.Add('stress warm min 추천') }
    if ($recommendation.TargetScaleDown -ne 600) { $failures.Add('scale-down 안정화 추천') }
    $script:Baseline['user'] = [pscustomobject]@{ Min = 2; ScaleDownSeconds = 0; Max = 20 }
    $ceiling = [pscustomobject]@{
        Ready = 20; Pending = 0; Current = 20; Desired = 20; Min = 2; Max = 20
        CurrentUtil = 70; TargetUtil = 33; ScaleDownSeconds = 0
        CpuTotalM = 980.0; CpuAverageM = 49.0; CpuMaxM = 60.0; HotRatio = 1.22
        Requests = 20; Errors = 0; ErrorRate = 0.0; P95Ms = 220.0
    }
    $script:History = @(
        [pscustomobject]@{ TimestampUtc = $now.AddSeconds(-5).ToString('o'); Apps = @{ user = $ceiling } },
        [pscustomobject]@{ TimestampUtc = $now.ToString('o'); Apps = @{ user = $ceiling } }
    )
    $maxRecommendation = Get-Recommendation 'user'
    if ($maxRecommendation.Reason -ne 'HPA_MAX_PRESSURE' -or $maxRecommendation.TargetMax -ne 48) { $failures.Add('HPA max performance expansion') }
    $ceiling.Pending = 1
    $blockedRecommendation = Get-Recommendation 'user'
    if ($blockedRecommendation.TargetMax -ne 20) { $failures.Add('Pending 중 HPA max 확장 차단') }
    if ((Get-HpaMaxTarget 38 100 40) -ne 40) { $failures.Add('HPA max safety cap') }
    if ((Get-HpaMaxTarget 1 2 40) -ne 40 -or (Get-HpaMaxTarget 1 2 12) -ne 12) { $failures.Add('HPA max cold-start 즉시 개방') }
    $ceiling.Pending = 2
    $script:NodePoolBaseline['default'] = [pscustomobject]@{ LimitCpu = 2; ConsolidateAfter = '1m' }
    $poolAtLimit = [pscustomobject]@{ LimitCpu = 2; UsedCpu = 2; Nodes = 1; CpuPerNode = 2; ConsolidateAfter = '1m' }
    $script:History = @(
        [pscustomobject]@{ TimestampUtc = $now.AddSeconds(-5).ToString('o'); Apps = @{ user = $ceiling; product = $ceiling }; NodePools = @{ default = $poolAtLimit }; NotReadyNodes = 0 },
        [pscustomobject]@{ TimestampUtc = $now.ToString('o'); Apps = @{ user = $ceiling; product = $ceiling }; NodePools = @{ default = $poolAtLimit }; NotReadyNodes = 0 }
    )
    $poolRecommendation = Get-NodePoolRecommendation 'default'
    if ($poolRecommendation.TargetLimitCpu -ne 12 -or $poolRecommendation.TargetConsolidateAfter -ne '10m') { $failures.Add('NodePool performance ceiling 확장') }
    $script:History[0].NotReadyNodes = 1
    $script:History[1].NotReadyNodes = 1
    if ((Get-NodePoolRecommendation 'default').TargetLimitCpu -ne 2) { $failures.Add('NotReady 중 NodePool 중복 확장 차단') }
    $idleMetric = $ceiling.PSObject.Copy()
    $idleMetric.Pending = 0; $idleMetric.Requests = 0; $idleMetric.CpuTotalM = 0; $idleMetric.Current = 2; $idleMetric.Desired = 2; $idleMetric.Min = 2
    $expandedPool = [pscustomobject]@{ LimitCpu = 8; UsedCpu = 2; Nodes = 1; CpuPerNode = 2; ConsolidateAfter = '10m' }
    $script:History = @(
        [pscustomobject]@{ TimestampUtc = $now.AddSeconds(-($IdleRestoreSeconds - $IntervalSeconds)).ToString('o'); Apps = @{ user = $idleMetric; product = $idleMetric }; NodePools = @{ default = $expandedPool }; NotReadyNodes = 0 },
        [pscustomobject]@{ TimestampUtc = $now.AddSeconds(-5).ToString('o'); Apps = @{ user = $idleMetric; product = $idleMetric }; NodePools = @{ default = $expandedPool }; NotReadyNodes = 0 },
        [pscustomobject]@{ TimestampUtc = $now.ToString('o'); Apps = @{ user = $idleMetric; product = $idleMetric }; NodePools = @{ default = $expandedPool }; NotReadyNodes = 0 }
    )
    $restoreRecommendation = Get-NodePoolRecommendation 'default'
    if ($restoreRecommendation.TargetLimitCpu -ne 2 -or $restoreRecommendation.TargetConsolidateAfter -ne '1m') { $failures.Add("유휴 NodePool 기준값 복구(actual=$($restoreRecommendation.TargetLimitCpu)/$($restoreRecommendation.TargetConsolidateAfter), reason=$($restoreRecommendation.Reason))") }
    if ($NodePoolSafetyCapNodes.default -ne 6 -or $NodePoolSafetyCapNodes.stress -ne 4) { $failures.Add('NodePool node safety cap') }
    $script:History = @()
    $script:Baseline = @{}
    $script:NodePoolBaseline = @{}
    if ($failures.Count -gt 0) { throw "SELF-TEST FAIL: $($failures -join ', ')" }
    Write-Host 'SELF-TEST PASS: 15/15' -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$mutex = [System.Threading.Mutex]::new($false, 'wsi2026-observe-live')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { throw 'observe-live.ps1이 이미 실행 중입니다.' }
    Test-Prerequisites
    Initialize-Baseline
    Initialize-PerformanceProfile
    $mode = if ($ObserveOnly) { 'OBSERVE' } else { 'SAFE-AUTO' }
    if ($WhatIfPreference) { $mode = 'WHATIF' }
    Write-Host "WSC LIVE TUNER 시작: mode=$mode interval=${IntervalSeconds}s log=$script:LogPath" -ForegroundColor Green
    Write-Host '추가 트래픽/API/DB/Terraform 변경 없음. 시작 시 user/stress rollout 1회와 prewarm이 발생하며 EC2 비용이 증가할 수 있음. 종료: Ctrl+C' -ForegroundColor DarkGray

    do {
        try {
            $snapshot = Get-LiveSnapshot
            Add-Snapshot $snapshot
            $recommendations = @{}
            foreach ($app in $ManagedApps) { $recommendations[$app] = Get-Recommendation $app }
            $nodePoolRecommendations = @{}
            foreach ($pool in $NodePoolApps.Keys) { $nodePoolRecommendations[$pool] = Get-NodePoolRecommendation $pool }
            Show-Snapshot $snapshot $recommendations $nodePoolRecommendations

            foreach ($pool in @('default', 'stress')) {
                [void](Set-SafeNodePoolState $nodePoolRecommendations[$pool])
            }
            foreach ($app in $MutationOrder) {
                [void](Set-SafeHpaState $recommendations[$app])
            }
        } catch {
            Write-Warning "관측 주기 실패(다음 주기에 재시도): $($_.Exception.Message)"
        }
        if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
    } while (-not $Once)
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
