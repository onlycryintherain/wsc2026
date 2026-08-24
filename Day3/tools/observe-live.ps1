<#
.SYNOPSIS
    실제 유입 트래픽을 관측하면서 안전한 HPA 항목만 자동 조정한다.
.DESCRIPTION
    인자 없이 실행한다. 추가 트래픽을 만들지 않고 Kubernetes metrics와 애플리케이션
    JSON access log를 분석한다. 트래픽/CPU 편중/HPA 압력이 확인되면 warm minReplicas와
    scale-down stabilization만 조정하고, 유휴가 지속되면 시작 전 기준으로 복구한다.

    Deployment, resource request/limit, NodePool, Terraform은 변경하지 않는다.
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
    [ValidateRange(30, 300)][int]$DecisionWindowSeconds = 60,
    [ValidateRange(60, 600)][int]$ScaleDownStabilizationSeconds = 300,
    [ValidateRange(120, 1800)][int]$IdleRestoreSeconds = 300,
    [switch]$ObserveOnly,
    [switch]$Once,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ExpectedAccountId = '586639730662'
$ManagedApps = @('user', 'product', 'stress')
$MutationOrder = @('stress', 'user', 'product')
$WarmFloor = @{ user = 2; product = 2; stress = 4 }
$ActivityCpuM = @{ user = 15.0; product = 15.0; stress = 250.0 }
$HotCpuM = @{ user = 50.0; product = 50.0; stress = 500.0 }
$script:History = @()
$script:Baseline = @{}
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
}

function Get-HpaScaleDownSeconds($Hpa) {
    $value = $Hpa.spec.behavior.scaleDown.stabilizationWindowSeconds
    if ($null -eq $value) { return 300 }
    return [int]$value
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
    return [pscustomobject]@{
        TimestampUtc = $now.ToString('o')
        Apps = $apps
        ReadyNodes = $readyNodes
        NotReadyNodes = $notReadyNodes
    }
}

function Add-Snapshot($Snapshot) {
    $script:History += $Snapshot
    $cutoff = [datetime]::UtcNow.AddSeconds(-[math]::Max($IdleRestoreSeconds + $IntervalSeconds, $DecisionWindowSeconds * 3))
    $script:History = @($script:History | Where-Object { [datetime]$_.TimestampUtc -ge $cutoff })
    $Snapshot | ConvertTo-Json -Compress -Depth 10 | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
}

function Get-Window([int]$Seconds) {
    $cutoff = [datetime]::UtcNow.AddSeconds(-$Seconds)
    return @($script:History | Where-Object { [datetime]$_.TimestampUtc -ge $cutoff })
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
    $hotObserved = @($metrics | Where-Object { $_.Ready -ge 2 -and $_.CpuMaxM -ge $HotCpuM[$App] -and $_.HotRatio -ge 2.5 }).Count -gt 0
    $requestsObserved = [int](($metrics.Requests | Measure-Object -Sum).Sum) -gt 0
    $active = $requestsObserved -or $maxCpu -ge $ActivityCpuM[$App] -or $maxDesired -gt $baseline.Min
    $pressure = $maxDesired -gt $latest.Min -or ($latest.TargetUtil -gt 0 -and $maxUtil -ge [math]::Floor($latest.TargetUtil * 0.85))

    $idle = $false
    if ($idleWindow.Count -gt 0) {
        $oldest = [datetime]$idleWindow[0].TimestampUtc
        $coversIdleWindow = ([datetime]::UtcNow - $oldest).TotalSeconds -ge ($IdleRestoreSeconds - $IntervalSeconds * 2)
        $idleMetrics = @($idleWindow | ForEach-Object { $_.Apps[$App] })
        $idleCpuMax = [double](($idleMetrics.CpuTotalM | Measure-Object -Maximum).Maximum)
        $idleRequests = [int](($idleMetrics.Requests | Measure-Object -Sum).Sum)
        $idleDesired = [int](($idleMetrics.Desired | Measure-Object -Maximum).Maximum)
        $idle = $coversIdleWindow -and $idleRequests -eq 0 -and $idleCpuMax -lt $ActivityCpuM[$App] -and $idleDesired -le $latest.Min
    }

    $targetMin = [int]$latest.Min
    $targetScaleDown = [int]$latest.ScaleDownSeconds
    $reason = 'HOLD'
    if ($window.Count -lt 2) {
        $reason = 'WARMUP'
    } elseif ($active -and ($pressure -or $hotObserved)) {
        $warmCap = [math]::Min([int]$baseline.Max, [math]::Max([int]$baseline.Min, [int]$WarmFloor[$App]))
        $targetMin = [math]::Min($warmCap, [math]::Max([int]$baseline.Min, $maxDesired))
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
        CurrentScaleDown = [int]$latest.ScaleDownSeconds
        TargetScaleDown = [int]$targetScaleDown
        MaxCpuM = [math]::Round($maxCpu, 1)
        MaxDesired = $maxDesired
        MaxUtil = $maxUtil
    }
}

function Set-SafeHpaState($Recommendation) {
    if ($Recommendation.CurrentMin -eq $Recommendation.TargetMin -and $Recommendation.CurrentScaleDown -eq $Recommendation.TargetScaleDown) {
        return $false
    }
    if (([datetime]::UtcNow - $script:LastMutationUtc).TotalSeconds -lt $DecisionWindowSeconds) {
        return $false
    }
    $app = [string]$Recommendation.App
    $baseline = $script:Baseline[$app]
    $description = "HPA/$app min $($Recommendation.CurrentMin)->$($Recommendation.TargetMin), scaleDown $($Recommendation.CurrentScaleDown)->$($Recommendation.TargetScaleDown)s ($($Recommendation.Reason))"
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
        $verifiedScaleDown = Get-HpaScaleDownSeconds $verify
        if ($verifiedMin -ne $Recommendation.TargetMin -or $verifiedScaleDown -ne $Recommendation.TargetScaleDown) {
            throw "검증 불일치: min=$verifiedMin scaleDown=$verifiedScaleDown"
        }
        $script:LastMutationUtc = [datetime]::UtcNow
        return $true
    } catch {
        Write-Warning "적용 실패, HPA/$app 기준값 복구: $($_.Exception.Message)"
        $rollback = @{ spec = @{ minReplicas = [int]$Recommendation.CurrentMin; behavior = @{ scaleDown = @{ stabilizationWindowSeconds = [int]$Recommendation.CurrentScaleDown } } } } | ConvertTo-Json -Compress -Depth 8
        Invoke-Kubectl @('-n', $Namespace, 'patch', 'hpa', $app, '--type=merge', '-p', $rollback) -AllowFailure | Out-Null
        return $false
    }
}

function Show-Snapshot($Snapshot, $Recommendations) {
    $kst = ([datetime]$Snapshot.TimestampUtc).ToLocalTime().ToString('HH:mm:ss')
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
            Decision = $r.Reason
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ([math]::Abs((Convert-CpuToMillicores '1970000000n') - 1970.0) -gt 0.001) { $failures.Add('nanocore 변환') }
    if ([math]::Abs((Convert-CpuToMillicores '250m') - 250.0) -gt 0.001) { $failures.Add('millicore 변환') }
    if ((Get-Percentile ([double[]]@(1, 2, 3, 4, 100)) 95) -ne 100) { $failures.Add('P95 계산') }
    if ($WarmFloor.stress -gt 4 -or $WarmFloor.user -gt 2 -or $WarmFloor.product -gt 2) { $failures.Add('warm cap 안전선') }
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
    if ($recommendation.TargetScaleDown -ne 300) { $failures.Add('scale-down 안정화 추천') }
    $script:History = @()
    $script:Baseline = @{}
    if ($failures.Count -gt 0) { throw "SELF-TEST FAIL: $($failures -join ', ')" }
    Write-Host 'SELF-TEST PASS: 6/6' -ForegroundColor Green
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
    $mode = if ($ObserveOnly) { 'OBSERVE' } else { 'SAFE-AUTO' }
    if ($WhatIfPreference) { $mode = 'WHATIF' }
    Write-Host "WSC LIVE TUNER 시작: mode=$mode interval=${IntervalSeconds}s log=$script:LogPath" -ForegroundColor Green
    Write-Host '추가 트래픽/Deployment rollout/NodePool/Terraform 변경 없음. 종료: Ctrl+C' -ForegroundColor DarkGray

    do {
        try {
            $snapshot = Get-LiveSnapshot
            Add-Snapshot $snapshot
            $recommendations = @{}
            foreach ($app in $ManagedApps) { $recommendations[$app] = Get-Recommendation $app }
            Show-Snapshot $snapshot $recommendations

            foreach ($app in $MutationOrder) {
                if (Set-SafeHpaState $recommendations[$app]) { break }
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
