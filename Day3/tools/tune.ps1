[CmdletBinding()]
param(
    [string]$ClusterName = 'wsi2026-cluster',
    [string]$Region = 'ap-northeast-2',
    [switch]$SkipKubeconfig,
    [string]$Endpoint,
    [string]$Namespace = 'app',
    [ValidateSet(20)][int]$MaxRuntimeMinutes = 20,
    [ValidateRange(60, 180)][int]$ShutdownReserveSeconds = 120,
    [ValidateRange(180, 300)][int]$ProfileDurationSec = 240,
    [ValidateSet(1)][int]$MaxProfileCandidates = 1,
    [ValidateRange(10, 100)][int]$TargetRate = 60,
    [ValidateRange(10, 60)][int]$WarmupDurationSec = 20,
    [ValidateRange(20, 60)][int]$SteadyDurationSec = 30,
    [ValidateRange(15, 90)][int]$CooldownDurationSec = 30,
    [ValidateRange(5, 10)][int]$SampleIntervalSec = 7,
    [ValidateRange(0.0, 2.0)][double]$NoiseTolerance = 0.5,
    [ValidateRange(95.0, 100.0)][double]$PerformancePassPercent = 99.0,
    [string]$OutputDir = (Join-Path ([IO.Path]::GetTempPath()) "wsi-measured-tune-$PID"),
    [switch]$NoApply,
    [switch]$DiscardResults,
    [switch]$SelfTestOnly
)

# This absolute deadline is created exactly once and is shared by BASE,
# candidates, rollback, FINAL, and evidence persistence.
$script:StartTime = [datetime]::UtcNow
$script:HardDeadline = $script:StartTime.AddMinutes(20)
$script:Apps = @('user', 'product', 'stress')
$script:SloMs = @{user=200.0; product=200.0; stress=1000.0}
$script:ProfileNames = @('Ramp')
$script:ApplyBudgetSec = 45
$script:RollbackBudgetSec = 45
$script:EvidenceSaveBudgetSec = 15
# Single k6-compatible ramp; reserve one bounded Kubernetes sample overrun.
$script:FinalMeasurementBudgetSec = $ProfileDurationSec + 10
$script:CandidateMeasurementBudgetSec = $ProfileDurationSec + 10
$script:LocalRun = $null
$script:PythonExe = $null
$script:PythonArgs = @()
$ErrorActionPreference = 'Stop'

function Get-RemainingSeconds {
    return [math]::Max(0, [math]::Floor(($script:HardDeadline - [datetime]::UtcNow).TotalSeconds))
}

function Get-DeadlineTimeout([int]$RequestedSec, [int]$ReserveSec = 10) {
    $available = (Get-RemainingSeconds) - $ReserveSec
    if ($available -lt 1) { throw 'HARD_DEADLINE_EXHAUSTED' }
    return [int][math]::Min($RequestedSec, $available)
}

function Test-CanStartBase {
    $required = $script:CandidateMeasurementBudgetSec + $script:FinalMeasurementBudgetSec + $ShutdownReserveSeconds
    return (Get-RemainingSeconds) -ge $required
}

function Test-CanStartCandidate {
    $required = $script:ApplyBudgetSec + $script:CandidateMeasurementBudgetSec + $script:RollbackBudgetSec +
        $script:FinalMeasurementBudgetSec + $ShutdownReserveSeconds + $script:EvidenceSaveBudgetSec
    return (Get-RemainingSeconds) -ge $required
}

function Test-CanStartFinal {
    $required = $script:FinalMeasurementBudgetSec + $script:RollbackBudgetSec + $ShutdownReserveSeconds + $script:EvidenceSaveBudgetSec
    return (Get-RemainingSeconds) -ge $required
}

function Get-WorstCaseRuntimeSeconds {
    $base = $script:CandidateMeasurementBudgetSec
    $candidate = $script:ApplyBudgetSec + $script:CandidateMeasurementBudgetSec + $script:RollbackBudgetSec
    return $base + ($MaxProfileCandidates * $candidate) + $script:FinalMeasurementBudgetSec +
        $ShutdownReserveSeconds + $script:EvidenceSaveBudgetSec
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "COMMAND_NOT_FOUND: $Name" }
}

function Get-Property($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Invoke-Kubectl([string[]]$Arguments) {
    $args = [System.Collections.Generic.List[string]]::new()
    $temporaryFiles = [System.Collections.Generic.List[string]]::new()
    try {
        $args.Add('--request-timeout=2s')
        for ($index = 0; $index -lt $Arguments.Count; $index++) {
            if ($Arguments[$index] -eq '-p' -and ($index + 1) -lt $Arguments.Count) {
                $patch = [string]$Arguments[$index + 1]
                if ($patch.TrimStart().StartsWith('{') -or $patch.TrimStart().StartsWith('[')) {
                    $file = [IO.Path]::GetTempFileName()
                    [IO.File]::WriteAllText($file, $patch, [Text.UTF8Encoding]::new($false))
                    $temporaryFiles.Add($file)
                    $args.Add('--patch-file'); $args.Add($file); $index++
                    continue
                }
            }
            $args.Add([string]$Arguments[$index])
        }
        $output = @(& kubectl @args 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "KUBECTL_FAILED: kubectl $($args -join ' '): $($output -join ' ')" }
        return @($output)
    } finally {
        foreach ($file in $temporaryFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

function Get-KubeJson([string[]]$Arguments) {
    return ((Invoke-Kubectl $Arguments) -join '') | ConvertFrom-Json
}

function Convert-CpuToM($Value) {
    if ($null -eq $Value) { return 0.0 }
    $text = ([string]$Value).Trim()
    if (-not $text) { return 0.0 }
    if ($text -match '^([0-9.]+)n$') { return [double]$Matches[1] / 1000000.0 }
    if ($text -match '^([0-9.]+)u$') { return [double]$Matches[1] / 1000.0 }
    if ($text -match '^([0-9.]+)m$') { return [double]$Matches[1] }
    if ($text -match '^[0-9.]+$') { return [double]$text * 1000.0 }
    throw "CPU_QUANTITY_INVALID: $text"
}

function Convert-MemoryToMi($Value) {
    if ($null -eq $Value) { return 0.0 }
    $text = ([string]$Value).Trim()
    if (-not $text) { return 0.0 }
    if ($text -match '^([0-9.]+)Ki$') { return [double]$Matches[1] / 1024.0 }
    if ($text -match '^([0-9.]+)Mi$') { return [double]$Matches[1] }
    if ($text -match '^([0-9.]+)Gi$') { return [double]$Matches[1] * 1024.0 }
    if ($text -match '^[0-9.]+$') { return [double]$text / 1MB }
    throw "MEMORY_QUANTITY_INVALID: $text"
}

function Format-CpuM([double]$Value) {
    return "$([int][math]::Max(1, [math]::Round($Value)))m"
}

function Format-MemoryMi([double]$Value) {
    return "$([int][math]::Max(1, [math]::Round($Value)))Mi"
}

function Copy-Config($Config, [string]$Name) {
    $copy = ($Config | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -AsHashtable
    $copy.Name = $Name
    return $copy
}

function Get-ConfigFingerprint($Config) {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($app in $script:Apps) {
        $value = $Config[$app]
        $parts.Add((@(
            $app,
            [int]$value.requestCpuM,
            [int]$value.requestMemoryMi,
            $(if ($null -eq $value.limitCpuM) { '' } else { [int]$value.limitCpuM }),
            $(if ($null -eq $value.limitMemoryMi) { '' } else { [int]$value.limitMemoryMi }),
            [int]$value.minReplicas,
            [int]$value.maxReplicas,
            [int]$value.hpaTarget,
            [string]$value.behaviorJson,
            [string]$value.placementJson
        ) -join '|'))
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join ';'))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ConfigDiff($Expected, $Actual) {
    $diff = [System.Collections.Generic.List[object]]::new()
    $fields = @('requestCpuM','requestMemoryMi','limitCpuM','limitMemoryMi','minReplicas','maxReplicas','hpaTarget','behaviorJson','placementJson')
    foreach ($app in $script:Apps) {
        foreach ($field in $fields) {
            $left = Get-Property $Expected[$app] $field $null
            $right = Get-Property $Actual[$app] $field $null
            if ([string]$left -ne [string]$right) {
                $diff.Add([pscustomobject]@{App=$app;Field=$field;Expected=$left;Actual=$right})
            }
        }
    }
    return @($diff)
}

function Get-LiveConfig([string]$Name = 'LIVE') {
    $deployments = Get-KubeJson @('-n',$Namespace,'get','deploy','-o','json')
    $hpas = Get-KubeJson @('-n',$Namespace,'get','hpa','-o','json')
    $config = @{Name=$Name}
    foreach ($app in $script:Apps) {
        $deployment = @($deployments.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
        $hpa = @($hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
        if (-not $deployment.Count -or -not $hpa.Count) { throw "WORKLOAD_NOT_FOUND: $app" }
        $container = @($deployment[0].spec.template.spec.containers | Where-Object { $_.name -eq $app } | Select-Object -First 1)
        if (-not $container.Count) { $container = @($deployment[0].spec.template.spec.containers | Select-Object -First 1) }
        $metric = @($hpa[0].spec.metrics | Where-Object { $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' } | Select-Object -First 1)
        if (-not $container.Count -or -not $metric.Count) { throw "WORKLOAD_SCHEMA_INVALID: $app" }
        $requests = $container[0].resources.requests
        if (-not $requests.cpu -or -not $requests.memory) { throw "RESOURCE_REQUEST_REQUIRED: $app" }
        $limits = $container[0].resources.limits
        $behaviorJson = if ($null -eq $hpa[0].spec.behavior) { '' } else { $hpa[0].spec.behavior | ConvertTo-Json -Depth 20 -Compress }
        $placementJson = @{
            nodeSelector=$deployment[0].spec.template.spec.nodeSelector
            affinity=$deployment[0].spec.template.spec.affinity
            topologySpreadConstraints=$deployment[0].spec.template.spec.topologySpreadConstraints
            tolerations=$deployment[0].spec.template.spec.tolerations
        } | ConvertTo-Json -Depth 20 -Compress
        $config[$app] = @{
            containerName=[string]$container[0].name
            requestCpuM=[int][math]::Round((Convert-CpuToM $requests.cpu))
            requestMemoryMi=[int][math]::Ceiling((Convert-MemoryToMi $requests.memory))
            limitCpuM=$(if ($limits -and $limits.cpu) { [int][math]::Round((Convert-CpuToM $limits.cpu)) } else { $null })
            limitMemoryMi=$(if ($limits -and $limits.memory) { [int][math]::Ceiling((Convert-MemoryToMi $limits.memory)) } else { $null })
            minReplicas=[int]$hpa[0].spec.minReplicas
            maxReplicas=[int]$hpa[0].spec.maxReplicas
            hpaTarget=[int]$metric[0].resource.target.averageUtilization
            behaviorJson=$behaviorJson
            placementJson=$placementJson
        }
    }
    $config.Fingerprint = Get-ConfigFingerprint $config
    return $config
}

function Assert-LiveConfig($Expected, [string]$ErrorCode = 'CONFIG_DRIFT') {
    $live = Get-LiveConfig 'VERIFY_LIVE'
    $diff = @(Get-ConfigDiff $Expected $live)
    if ($diff.Count) {
        $summary = @($diff | ForEach-Object { "$($_.App).$($_.Field):$($_.Expected)!=$($_.Actual)" }) -join ','
        throw "${ErrorCode}: $summary"
    }
    return $live
}

function Show-Config($Config, [string]$Title) {
    Write-Host $Title -ForegroundColor Cyan
    foreach ($app in $script:Apps) {
        $value = $Config[$app]
        Write-Host ("  {0,-7} request={1}m/{2}Mi limit={3}/{4} HPA={5}% {6}..{7}" -f
            $app,$value.requestCpuM,$value.requestMemoryMi,$value.limitCpuM,$value.limitMemoryMi,
            $value.hpaTarget,$value.minReplicas,$value.maxReplicas)
    }
}

function Get-PodEffectiveRequest($Pod) {
    $cpu = 0.0; $memory = 0.0; $initCpu = 0.0; $initMemory = 0.0
    foreach ($container in @($Pod.spec.containers)) {
        $cpu += Convert-CpuToM $container.resources.requests.cpu
        $memory += Convert-MemoryToMi $container.resources.requests.memory
    }
    foreach ($container in @($Pod.spec.initContainers)) {
        $initCpu = [math]::Max($initCpu, (Convert-CpuToM $container.resources.requests.cpu))
        $initMemory = [math]::Max($initMemory, (Convert-MemoryToMi $container.resources.requests.memory))
    }
    $cpu = [math]::Max($cpu, $initCpu) + (Convert-CpuToM $Pod.spec.overhead.cpu)
    $memory = [math]::Max($memory, $initMemory) + (Convert-MemoryToMi $Pod.spec.overhead.memory)
    return [pscustomobject]@{CpuM=$cpu;MemoryMi=$memory}
}

function Test-PodReady($Pod) {
    return @($Pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
}

function Get-Sample([datetime]$ProfileStartedAt, [hashtable]$InitialRestarts) {
    $nodes = Get-KubeJson @('get','nodes','-o','json')
    $allPods = Get-KubeJson @('get','pods','-A','-o','json')
    $hpas = Get-KubeJson @('-n',$Namespace,'get','hpa','-o','json')
    $metrics = $null; $metricsAvailable = $false
    try {
        $metrics = Get-KubeJson @('get','--raw',"/apis/metrics.k8s.io/v1beta1/namespaces/$Namespace/pods")
        $metricsAvailable = $true
    } catch { }
    $events = $null
    try { $events = Get-KubeJson @('-n',$Namespace,'get','events','-o','json') } catch { }

    $readyNodes = @($nodes.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count })
    $allocCpu = 0.0; $allocMemory = 0.0
    foreach ($node in $readyNodes) {
        $allocCpu += Convert-CpuToM $node.status.allocatable.cpu
        $allocMemory += Convert-MemoryToMi $node.status.allocatable.memory
    }

    $requestedCpu = 0.0; $requestedMemory = 0.0; $appRequestedCpu = 0.0; $appRequestedMemory = 0.0
    foreach ($pod in @($allPods.items | Where-Object { $_.status.phase -notin @('Succeeded','Failed') })) {
        $request = Get-PodEffectiveRequest $pod
        if ($pod.spec.nodeName) { $requestedCpu += $request.CpuM; $requestedMemory += $request.MemoryMi }
        if ($pod.metadata.namespace -eq $Namespace -and [string]$pod.metadata.labels.app -in $script:Apps) {
            $appRequestedCpu += $request.CpuM; $appRequestedMemory += $request.MemoryMi
        }
    }

    $apps = @{}
    $pendingRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $script:Apps) {
        $appPods = @($allPods.items | Where-Object { $_.metadata.namespace -eq $Namespace -and [string]$_.metadata.labels.app -eq $app -and $_.status.phase -notin @('Succeeded','Failed') })
        $ready = @($appPods | Where-Object { Test-PodReady $_ }).Count
        $pending = @($appPods | Where-Object { $_.status.phase -eq 'Pending' -or -not (Test-PodReady $_) })
        $restartTotal = 0
        foreach ($pod in $appPods) {
            foreach ($status in @($pod.status.containerStatuses)) { $restartTotal += [int]$status.restartCount }
        }
        foreach ($pod in $pending) {
            $messages = [System.Collections.Generic.List[string]]::new()
            foreach ($condition in @($pod.status.conditions)) {
                if ($condition.reason) { $messages.Add([string]$condition.reason) }
                if ($condition.message) { $messages.Add([string]$condition.message) }
            }
            foreach ($status in @($pod.status.containerStatuses)) {
                if ($status.state.waiting.reason) { $messages.Add([string]$status.state.waiting.reason) }
                if ($status.state.waiting.message) { $messages.Add([string]$status.state.waiting.message) }
            }
            $pendingRecords.Add([pscustomobject]@{App=$app;Pod=[string]$pod.metadata.name;Reason=($messages -join '; ')})
        }

        $cpuTotal = 0.0; $memoryTotal = 0.0; $metricPods = 0
        foreach ($podMetric in @($metrics.items | Where-Object { $_.metadata.name -in @($appPods.metadata.name) })) {
            $metricPods++
            foreach ($container in @($podMetric.containers)) {
                $cpuTotal += Convert-CpuToM $container.usage.cpu
                $memoryTotal += Convert-MemoryToMi $container.usage.memory
            }
        }
        $hpa = @($hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)[0]
        $currentMetric = @($hpa.status.currentMetrics | Where-Object { $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' } | Select-Object -First 1)
        $targetMetric = @($hpa.spec.metrics | Where-Object { $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' } | Select-Object -First 1)
        $apps[$app] = [pscustomobject]@{
            CurrentReplicas=[int]$hpa.status.currentReplicas
            DesiredReplicas=[int]$hpa.status.desiredReplicas
            MinReplicas=[int]$hpa.spec.minReplicas
            MaxReplicas=[int]$hpa.spec.maxReplicas
            CpuUtilization=$(if ($currentMetric.Count -and $null -ne $currentMetric[0].resource.current.averageUtilization) { [int]$currentMetric[0].resource.current.averageUtilization } else { $null })
            CpuTarget=$(if ($targetMetric.Count) { [int]$targetMetric[0].resource.target.averageUtilization } else { $null })
            ReadyPods=$ready
            PendingPods=$pending.Count
            RestartTotal=$restartTotal
            RestartDelta=[math]::Max(0, $restartTotal - [int](Get-Property $InitialRestarts $app 0))
            CpuTotalM=[math]::Round($cpuTotal,2)
            CpuPerPodM=$(if ($metricPods) { [math]::Round($cpuTotal/$metricPods,2) } else { $null })
            MemoryTotalMi=[math]::Round($memoryTotal,2)
            MemoryPerPodMi=$(if ($metricPods) { [math]::Round($memoryTotal/$metricPods,2) } else { $null })
            MetricPods=$metricPods
        }
    }

    $eventMessages = [System.Collections.Generic.List[string]]::new()
    foreach ($event in @($events.items)) {
        $timestamp = $event.eventTime
        if (-not $timestamp) { $timestamp = $event.lastTimestamp }
        if (-not $timestamp) { $timestamp = $event.firstTimestamp }
        if ($timestamp -and ([datetime]$timestamp).ToUniversalTime() -lt $ProfileStartedAt.ToUniversalTime()) { continue }
        if ($event.reason -in @('FailedScheduling','FailedCreatePodSandBox') -or [string]$event.message -match 'disruption budget|Insufficient|failed to assign an IP') {
            $eventMessages.Add("$($event.reason): $($event.message)")
        }
    }
    $allReasons = (@($pendingRecords.Reason) + @($eventMessages)) -join '; '
    return [pscustomobject]@{
        Timestamp=[datetime]::UtcNow.ToString('o')
        ElapsedSec=[math]::Round(([datetime]::UtcNow-$ProfileStartedAt.ToUniversalTime()).TotalSeconds,1)
        MetricsAvailable=$metricsAvailable
        Apps=$apps
        Node=[pscustomobject]@{
            ReadyCount=$readyNodes.Count
            AllocatableCpuM=[math]::Round($allocCpu,1)
            AllocatableMemoryMi=[math]::Round($allocMemory,1)
            RequestedCpuM=[math]::Round($requestedCpu,1)
            RequestedMemoryMi=[math]::Round($requestedMemory,1)
            AppRequestedCpuM=[math]::Round($appRequestedCpu,1)
            AppRequestedMemoryMi=[math]::Round($appRequestedMemory,1)
            AverageAllocatableCpuM=$(if ($readyNodes.Count) { [math]::Round($allocCpu/$readyNodes.Count,1) } else { 0 })
            AverageAllocatableMemoryMi=$(if ($readyNodes.Count) { [math]::Round($allocMemory/$readyNodes.Count,1) } else { 0 })
        }
        Pending=@($pendingRecords)
        Scheduling=[pscustomobject]@{
            InsufficientCpu=([bool]($allReasons -match 'Insufficient cpu'))
            InsufficientMemory=([bool]($allReasons -match 'Insufficient memory'))
            FailedScheduling=([bool]($allReasons -match 'FailedScheduling|Unschedulable'))
            CniError=([bool]($allReasons -match 'FailedCreatePodSandBox|failed to assign an IP'))
            PdbConstraint=([bool]($allReasons -match 'disruption budget'))
            NodePoolLimit=([bool]($allReasons -match 'exceed limits for nodepool|nodepool.+limit'))
            Reasons=$allReasons
        }
    }
}

function Get-ProfileSteps([string]$Name) {
    $steps=[System.Collections.Generic.List[int]]::new()
    for($rate=10;$rate -lt $TargetRate;$rate+=10){$steps.Add($rate)}
    $steps.Add($TargetRate)
    return @($steps | Select-Object -Unique)
}

function Get-ProfileSpec([string]$Name) {
    $steps = @(Get-ProfileSteps $Name)
    $rampCount=[math]::Max(0,$steps.Count-1)
    $loadWindow=$ProfileDurationSec-$CooldownDurationSec
    $rampSeconds=if($rampCount){[math]::Floor(($loadWindow-$WarmupDurationSec-$SteadyDurationSec)/$rampCount)}else{0}
    if($rampCount -and $rampSeconds -lt 10){throw 'PROFILE_DURATION_TOO_SHORT_FOR_K6_RAMP'}
    $phases = [System.Collections.Generic.List[hashtable]]::new()
    $phases.Add(@{kind='warmup';start_rps=[int]$steps[0];rps=[int]$steps[0];duration_sec=$WarmupDurationSec})
    $previous=[int]$steps[0]
    foreach($rate in @($steps | Select-Object -Skip 1)){
        $phases.Add(@{kind='ramp';start_rps=$previous;rps=[int]$rate;duration_sec=[int]$rampSeconds})
        $previous=[int]$rate
    }
    $used=$WarmupDurationSec+($rampSeconds*$rampCount)+$SteadyDurationSec+$CooldownDurationSec
    $steadySeconds=$SteadyDurationSec+($ProfileDurationSec-$used)
    $phases.Add(@{kind='steady';start_rps=[int]$TargetRate;rps=[int]$TargetRate;duration_sec=[int]$steadySeconds})
    $phases.Add(@{kind='cooldown';start_rps=[int]$TargetRate;rps=0;duration_sec=1})
    $phases.Add(@{kind='cooldown';start_rps=0;rps=0;duration_sec=($CooldownDurationSec-1)})
    return @{
        profile=$Name
        endpoint=$script:Endpoint
        timeout_sec=5
        phases=@($phases)
        apps=@{
            user=@{share=0.50;slo_ms=$script:SloMs.user;expected_status=200;method='GET';path='/v1/user?email=dbdump500001@example.org&requestid=999999999999&uuid=7c5a3c6a-7584-4bc5-9bdf-3e573a0ad729';headers=@{'User-Agent'='wsi-local-loadgen/2.0'}}
            product=@{share=0.35;slo_ms=$script:SloMs.product;expected_status=200;method='GET';path='/v1/product?id=dbdump500001&requestid=999999999999&uuid=7c5a3c6a-7584-4bc5-9bdf-3e573a0ad729';headers=@{'User-Agent'='wsi-local-loadgen/2.0'}}
            stress=@{share=0.15;slo_ms=$script:SloMs.stress;expected_status=201;method='POST';path='/v1/stress';body=@{requestid='999999999999';uuid='7c5a3c6a-7584-4bc5-9bdf-3e573a0ad729';length=256};headers=@{'User-Agent'='wsi-local-loadgen/2.0';'Content-Type'='application/json'}}
        }
    }
}

function Initialize-Python {
    if ($script:PythonExe) { return }
    foreach ($candidate in @(@('py','-3.14'),@('python'))) {
        try {
            $version = ((& $candidate[0] @($candidate | Select-Object -Skip 1) --version 2>&1) -join ' ').Trim()
            if ($version -notmatch 'Python 3\.14(?:\.|$)') { continue }
            & $candidate[0] @($candidate | Select-Object -Skip 1) -c 'import aiohttp' 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'PYTHON_AIOHTTP_MISSING' }
            $script:PythonExe = $candidate[0]
            $script:PythonArgs = @($candidate | Select-Object -Skip 1)
            return
        } catch { if ($_.Exception.Message -eq 'PYTHON_AIOHTTP_MISSING') { throw } }
    }
    throw 'PYTHON314_REQUIRED'
}

function Stop-LocalLoad([switch]$Force) {
    $run = $script:LocalRun
    if (-not $run) { return }
    try {
        if (-not $run.Process.HasExited) {
            if (-not $Force) { [void]$run.Process.CloseMainWindow(); Start-Sleep -Milliseconds 300 }
            if (-not $run.Process.HasExited) { $run.Process.Kill($true) }
        }
        [void]$run.Process.WaitForExit(3000)
    } catch { Write-Warning "LOCAL_LOAD_CLEANUP_FAILED: $($_.Exception.Message)" }
    finally { $script:LocalRun = $null }
}

function Get-LoadPhaseAtElapsed($ProfileSpec,[double]$ElapsedSec) {
    $cursor=0.0
    foreach($phase in @($ProfileSpec.phases)){
        $cursor += [double]$phase.duration_sec
        if($ElapsedSec -lt $cursor){return $phase}
    }
    return @($ProfileSpec.phases)[-1]
}

function Invoke-Profile([string]$CandidateName, [string]$ProfileName) {
    Assert-LiveConfig $script:MeasurementConfig 'CONFIG_DRIFT_BEFORE_PROFILE' | Out-Null
    Initialize-Python
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $safe = ($CandidateName + '-' + $ProfileName) -replace '[^A-Za-z0-9_.-]','_'
    $configPath = Join-Path $OutputDir "$safe.loadgen.json"
    $resultPath = Join-Path $OutputDir "$safe.loadgen-result.json"
    $profileSpec=Get-ProfileSpec $ProfileName
    $rampPhases=@($profileSpec.phases | Where-Object kind -eq 'ramp')
    Write-Host ("  Python arrival-rate: warmup={0}s ramp={1}s×{2} steady={3}s cooldown={4}s target={5}rps" -f $WarmupDurationSec,$rampPhases[0].duration_sec,$rampPhases.Count,$SteadyDurationSec,$CooldownDurationSec,$TargetRate) -ForegroundColor DarkCyan
    $profileSpec | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $script:PythonExe
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in @($script:PythonArgs) + @((Join-Path $PSScriptRoot 'tune/loadgen.py'),'--config',$configPath,'--output',$resultPath)) {
        [void]$processInfo.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $processInfo
    if (-not $process.Start()) { throw "LOCAL_LOAD_START_FAILED: $ProfileName" }
    $started = [datetime]::UtcNow
    $script:LocalRun = [pscustomobject]@{Process=$process;ResultPath=$resultPath;Started=$started}
    $samples = [System.Collections.Generic.List[object]]::new()
    $initialRestarts = @{}
    foreach ($app in $script:Apps) { $initialRestarts[$app]=0 }
    $nextSample = $started
    try {
        while (-not $process.HasExited) {
            if ([datetime]::UtcNow -ge $script:HardDeadline) { throw 'HARD_DEADLINE_DURING_PROFILE' }
            if ([datetime]::UtcNow -ge $nextSample) {
                $sample = Get-Sample $started $initialRestarts
                if ($samples.Count -eq 0) {
                    foreach ($app in $script:Apps) {
                        $initialRestarts[$app]=[int]$sample.Apps[$app].RestartTotal
                        $sample.Apps[$app].RestartDelta=0
                    }
                }
                $phase=Get-LoadPhaseAtElapsed $profileSpec ([double]$sample.ElapsedSec)
                $sample | Add-Member -NotePropertyName LoadKind -NotePropertyValue ([string]$phase.kind) -Force
                $sample | Add-Member -NotePropertyName TargetRps -NotePropertyValue ([double]$phase.rps) -Force
                $samples.Add($sample)
                Write-Host ("  sample {0}: phase={1} rps={2} nodes={3} pending={4}" -f $samples.Count,$sample.LoadKind,$sample.TargetRps,$sample.Node.ReadyCount,@($sample.Pending).Count) -ForegroundColor DarkGray
                $nextSample = [datetime]::UtcNow.AddSeconds($SampleIntervalSec)
            }
            Start-Sleep -Milliseconds 250
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $stderr = $process.StandardError.ReadToEnd()
            throw "LOCAL_LOAD_FAILED: exit=$($process.ExitCode) $stderr"
        }
        if (-not (Test-Path -LiteralPath $resultPath)) { throw "LOCAL_LOAD_RESULT_MISSING: $resultPath" }
        $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        if ([bool]$result.generator_limited) { throw "GENERATOR_LIMIT: $($result.generator_limit_reason)" }
        $result | Add-Member -NotePropertyName Samples -NotePropertyValue @($samples) -Force
        return $result
    } finally { Stop-LocalLoad -Force }
}

function Convert-ProfileResult($Evidence, [string]$ProfileName) {
    $apps = @{}
    $availability = 100.0; $performance = 100.0
    $steady=@($Evidence.phases | Where-Object { [string]$_.kind -eq 'steady' }) | Select-Object -Last 1
    foreach ($app in $script:Apps) {
        $value = if($steady){$steady.apps.$app}else{$Evidence.apps.$app}
        $success = [double]$value.success_rate
        $slo = [double]$value.slo_success_rate
        $availability = [math]::Min($availability, $success)
        $performance = [math]::Min($performance, $slo)
        $apps[$app] = [pscustomobject]@{
            SuccessRate=$success
            SloSuccessRate=$slo
            TimeoutRate=[double]$value.timeout_rate
            P95Ms=[double](Get-Property $value.latency_ms 'p95' 5000)
        }
    }
    $averageNodes = if (@($Evidence.Samples).Count) {
        [double]((@($Evidence.Samples | ForEach-Object { [double]$_.Node.ReadyCount }) | Measure-Object -Average).Average)
    } else { [double]::PositiveInfinity }
    return [pscustomobject]@{
        Profile=$ProfileName
        Valid=$true
        Availability=$availability
        Performance=$performance
        Result=[math]::Round(($availability+$performance)/2.0,3)
        AverageNodes=$averageNodes
        Apps=$apps
        Evidence=$Evidence
        Samples=@($Evidence.Samples)
    }
}

function Get-Objective($Runs, $Config, [string]$Name) {
    $runs = @($Runs)
    if ($runs.Count -ne $script:ProfileNames.Count -or @($runs | Where-Object { -not $_.Valid }).Count) {
        return [pscustomobject]@{Name=$Name;Valid=$false;Measured=$false;Runs=$runs;Config=$Config}
    }
    $profileResults = @{}; $appWorst = @{}
    foreach ($app in $script:Apps) {
        $appWorst[$app] = [double](($runs | ForEach-Object { [double]$_.Apps[$app].SloSuccessRate } | Measure-Object -Minimum).Minimum)
    }
    foreach ($run in $runs) { $profileResults[$run.Profile]=[double]$run.Result }
    return [pscustomobject]@{
        Name=$Name
        Valid=$true
        Measured=$true
        ConfigFingerprint=Get-ConfigFingerprint $Config
        Config=Copy-Config $Config "${Name}_MEASURED_CONFIG"
        WorstAvailability=[double](($runs.Availability | Measure-Object -Minimum).Minimum)
        WorstPerformance=[double](($runs.Performance | Measure-Object -Minimum).Minimum)
        WorstDeficit=100.0-[double](($runs.Performance | Measure-Object -Minimum).Minimum)
        WorstProfileResult=[double](($runs.Result | Measure-Object -Minimum).Minimum)
        AverageResult=[double](($runs.Result | Measure-Object -Average).Average)
        AverageNodes=[double](($runs.AverageNodes | Measure-Object -Average).Average)
        ProfileResults=$profileResults
        AppWorst=$appWorst
        Runs=$runs
    }
}

function Invoke-Measurement($Config, [string]$Name) {
    $script:MeasurementConfig = $Config
    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in $script:ProfileNames) {
        Write-Host "`n===== LOCAL PROFILE: $Name / $profile =====" -ForegroundColor Cyan
        $evidence = Invoke-Profile $Name $profile
        $runs.Add((Convert-ProfileResult $evidence $profile))
    }
    $objective = Get-Objective @($runs) $Config $Name
    $objective | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $OutputDir "measurement-$Name.json") -Encoding utf8
    return $objective
}

function Get-AllSamples($Evaluation) {
    return @($Evaluation.Runs | ForEach-Object { @($_.Samples) })
}

function Get-AllLoadSamples($Evaluation) {
    return @(Get-AllSamples $Evaluation | Where-Object { [string]$_.LoadKind -ne 'cooldown' })
}

function Get-PendingSummary($Sample) {
    $pending=@($Sample.Pending)
    $byApp=@($pending | Group-Object App | ForEach-Object { "$($_.Name)=$($_.Count)" })
    return "pending=$($pending.Count)$(if($byApp.Count){' ('+($byApp -join ',')+')'}else{''}) readyNodes=$($Sample.Node.ReadyCount)"
}

function Get-InfrastructureStop($Evaluation) {
    $samples = @(Get-AllSamples $Evaluation)
    if (-not $Evaluation.Valid -or -not $samples.Count) { return [pscustomobject]@{Type='MEASUREMENT_INVALID';Reason='measurement or samples missing'} }
    # At least half of the samples must contain pod metrics for every app.
    $usableMetrics = @($samples | Where-Object {
        if (-not $_.MetricsAvailable) { return $false }
        foreach ($app in $script:Apps) { if ([int]$_.Apps[$app].MetricPods -lt 1) { return $false } }
        return $true
    })
    if ($usableMetrics.Count -lt [math]::Ceiling($samples.Count/2.0)) { return [pscustomobject]@{Type='METRICS_UNAVAILABLE';Reason="usable=$($usableMetrics.Count)/$($samples.Count)"} }
    $latest = $samples[-1]
    if ($latest.Scheduling.CniError -and @($latest.Pending).Count) { return [pscustomobject]@{Type='CNI_UNRESOLVED';Reason="$(Get-PendingSummary $latest) unresolved CNI allocation failure"} }
    if ($latest.Scheduling.PdbConstraint) { return [pscustomobject]@{Type='PDB_CONSTRAINT';Reason="$(Get-PendingSummary $latest) disruption budget constraint"} }
    # Insufficient capacity and NodePool limits are measured bottleneck evidence.
    # They must not suppress the bounded resource/HPA candidate lifecycle.
    return $null
}

function Get-AppTemporalEvidence($Evaluation, [string]$App) {
    $earlyWorst = 100.0; $lateWorst = 100.0; $profiles = 0
    foreach ($run in $Evaluation.Runs) {
        $phases = @($run.Evidence.phases | Where-Object { [string]$_.kind -in @('ramp','steady') -and [double]$_.target_rps -gt 0 })
        if ($phases.Count -lt 2) { continue }
        $split = [math]::Ceiling($phases.Count/2.0)
        $early = @($phases | Select-Object -First $split)
        $late = @($phases | Select-Object -Skip $split)
        $earlyRate = [double](($early | ForEach-Object { [double]$_.apps.$App.slo_success_rate } | Measure-Object -Minimum).Minimum)
        $lateRate = [double](($late | ForEach-Object { [double]$_.apps.$App.slo_success_rate } | Measure-Object -Minimum).Minimum)
        $earlyWorst = [math]::Min($earlyWorst,$earlyRate)
        $lateWorst = [math]::Min($lateWorst,$lateRate)
        $profiles++
    }
    return [pscustomobject]@{EarlyWorst=$earlyWorst;LateWorst=$lateWorst;Profiles=$profiles;Recovered=($earlyWorst -lt $PerformancePassPercent -and $lateWorst -ge $PerformancePassPercent -and ($lateWorst-$earlyWorst) -ge 5.0)}
}

function Get-HpaMaxValue([int]$CurrentMax, [int]$UncappedDesired) {
    $lower = [int][math]::Ceiling($CurrentMax*1.20)
    $upper = [int][math]::Ceiling($CurrentMax*1.25)
    return [int][math]::Max($CurrentMax+1, [math]::Min($upper, [math]::Max($lower,$UncappedDesired)))
}

function Get-HpaTargetValue([int]$CurrentTarget) {
    $step = [int][math]::Max(1, [math]::Ceiling($CurrentTarget*0.10))
    return [int][math]::Max(10, $CurrentTarget-$step)
}

function Test-MinDownCanReduceFloor($Config, [string]$App, $Samples) {
    foreach ($appName in $script:Apps) {
        $placement = $Config[$appName].placementJson | ConvertFrom-Json
        if ($placement.nodeSelector -and @($placement.nodeSelector.PSObject.Properties).Count) { return $false }
    }
    $latest = @($Samples)[-1]
    $cpuPerNode = [double]$latest.Node.AverageAllocatableCpuM
    $memoryPerNode = [double]$latest.Node.AverageAllocatableMemoryMi
    if ($cpuPerNode -le 0 -or $memoryPerNode -le 0) { return $false }
    $cpu = 0.0; $memory = 0.0
    foreach ($appName in $script:Apps) {
        $cpu += [int]$Config[$appName].minReplicas * [int]$Config[$appName].requestCpuM
        $memory += [int]$Config[$appName].minReplicas * [int]$Config[$appName].requestMemoryMi
    }
    $oldFloor = [math]::Max([math]::Ceiling($cpu/$cpuPerNode),[math]::Ceiling($memory/$memoryPerNode))
    $newCpu = $cpu-[int]$Config[$App].requestCpuM
    $newMemory = $memory-[int]$Config[$App].requestMemoryMi
    $newFloor = [math]::Max([math]::Ceiling($newCpu/$cpuPerNode),[math]::Ceiling($newMemory/$memoryPerNode))
    return $newFloor -lt $oldFloor
}

function New-Recommendation([string]$Axis,[string]$App,$To,[string]$Reason,$NewTarget=$null) {
    return [pscustomobject]@{Axis=$Axis;App=$App;To=$To;NewTarget=$NewTarget;Reason=$Reason;Signature="${Axis}:${App}:${To}:${NewTarget}"}
}

function Test-RecommendationRejected($Rejected,[string]$Axis,[string]$App,$To,$NewTarget=$null) {
    if ($null -eq $Rejected) { return $false }
    return $Rejected.Contains("${Axis}:${App}:${To}:${NewTarget}")
}

function Get-Recommendation($Best, $Rejected=$null) {
    $infra = Get-InfrastructureStop $Best
    if ($infra) { return [pscustomobject]@{Axis='INFRA_STOP';App=$null;To=$null;Reason="$($infra.Type): $($infra.Reason)"} }
    $samples = @(Get-AllLoadSamples $Best)
    $failingApps = @($script:Apps | Where-Object { [double]$Best.AppWorst[$_] -lt $PerformancePassPercent } | Sort-Object { [double]$Best.AppWorst[$_] })
    if ($failingApps.Count) {
        # k6-compatible behavior: NodePool saturation is evidence for one bounded
        # request/control-point packing probe, not a reason to abort measurement.
        foreach($app in $failingApps){
            $capacity=@($samples | Where-Object {
                $_.Scheduling.NodePoolLimit -and @($_.Pending | Where-Object App -eq $app).Count -gt 0
            })
            $oldRequest=[int]$Best.Config[$app].requestCpuM
            if($capacity.Count -ge 2 -and $oldRequest -gt 50){
                $newRequest=[int][math]::Max(50,[math]::Floor(($oldRequest*0.90)/10.0)*10)
                $absoluteTrigger=[double]$oldRequest*[double]$Best.Config[$app].hpaTarget/100.0
                $newTarget=[int][math]::Round(100.0*$absoluteTrigger/$newRequest)
                if($newTarget -ge 10 -and $newTarget -le 90 -and -not(Test-RecommendationRejected $Rejected 'REQUEST_CONTROL_POINT' $app $newRequest $newTarget)){
                    return New-Recommendation 'REQUEST_CONTROL_POINT' $app $newRequest "nodepool limit samples=$($capacity.Count), bounded request -10%, preserve trigger=${absoluteTrigger}m" $newTarget
                }
            }
        }
        foreach ($app in $failingApps) {
            $capacity=@($samples | Where-Object { $_.Scheduling.NodePoolLimit -and @($_.Pending | Where-Object App -eq $app).Count -gt 0 })
            if($capacity.Count -ge 2){continue}
            $ceiling = @($samples | Where-Object {
                $metric=$_.Apps[$app]
                $null -ne $metric.CpuUtilization -and [int]$metric.DesiredReplicas -ge [int]$metric.MaxReplicas -and [int]$metric.CpuUtilization -gt [int]$metric.CpuTarget
            })
            if ($ceiling.Count) {
                $uncapped = [int](($ceiling | ForEach-Object {
                    $metric=$_.Apps[$app]
                    [math]::Ceiling([double]$metric.CurrentReplicas*[double]$metric.CpuUtilization/[math]::Max(1,[double]$metric.CpuTarget))
                } | Measure-Object -Maximum).Maximum)
                $to=Get-HpaMaxValue ([int]$Best.Config[$app].maxReplicas) $uncapped
                if (-not (Test-RecommendationRejected $Rejected 'HPA_MAX' $app $to)) { return New-Recommendation 'HPA_MAX' $app $to "ceiling samples=$($ceiling.Count), uncapped=$uncapped" }
            }
        }
        foreach ($app in $failingApps) {
            $temporal = Get-AppTemporalEvidence $Best $app
            $metrics = @($samples | ForEach-Object { $_.Apps[$app] })
            $highCpu = @($metrics | Where-Object { $null -ne $_.CpuUtilization -and [int]$_.CpuUtilization -gt [int]$_.CpuTarget }).Count
            $lag = @($metrics | Where-Object { [int]$_.DesiredReplicas -gt [int]$_.CurrentReplicas -or [int]$_.ReadyPods -lt [int]$_.DesiredReplicas }).Count
            $atCeiling = @($metrics | Where-Object { [int]$_.DesiredReplicas -ge [int]$_.MaxReplicas }).Count
            if (-not $temporal.Recovered -and $highCpu -ge 2 -and $lag -ge 2 -and $atCeiling -eq 0) {
                $to=Get-HpaTargetValue ([int]$Best.Config[$app].hpaTarget)
                if (-not (Test-RecommendationRejected $Rejected 'HPA_TARGET' $app $to)) { return New-Recommendation 'HPA_TARGET' $app $to "highCpu=$highCpu lag=$lag lateSlo=$($temporal.LateWorst)" }
            }
        }
        foreach ($app in $failingApps) {
            $temporal = Get-AppTemporalEvidence $Best $app
            $metrics = @($samples | ForEach-Object { $_.Apps[$app] })
            $lag = @($metrics | Where-Object { [int]$_.DesiredReplicas -gt [int]$_.CurrentReplicas -or [int]$_.ReadyPods -lt [int]$_.DesiredReplicas }).Count
            $atCeiling = @($metrics | Where-Object { [int]$_.DesiredReplicas -ge [int]$_.MaxReplicas }).Count
            if ($temporal.Recovered -and $lag -ge 2 -and $atCeiling -eq 0 -and [int]$Best.Config[$app].minReplicas -lt [int]$Best.Config[$app].maxReplicas) {
                $to=[int]$Best.Config[$app].minReplicas+1
                if (-not (Test-RecommendationRejected $Rejected 'MIN_UP' $app $to)) { return New-Recommendation 'MIN_UP' $app $to "early=$($temporal.EarlyWorst) late=$($temporal.LateWorst) lag=$lag" }
            }
        }
        return $null
    }

    foreach ($app in @($script:Apps | Sort-Object { -1*[int]$Best.Config[$_].minReplicas })) {
        if ([int]$Best.Config[$app].minReplicas -le 1) { continue }
        $low = @($samples | Where-Object {
            $metric=$_.Apps[$app]
            $null -ne $metric.CpuUtilization -and [double]$metric.CpuUtilization -le ([double]$metric.CpuTarget*0.60) -and [int]$metric.PendingPods -eq 0
        }).Count
        if ($low -ge 3 -and (Test-MinDownCanReduceFloor $Best.Config $app $samples)) {
            $to=[int]$Best.Config[$app].minReplicas-1
            if (-not (Test-RecommendationRejected $Rejected 'MIN_DOWN' $app $to)) { return New-Recommendation 'MIN_DOWN' $app $to "low-load samples=$low and calculated node floor decreases" }
        }
    }

    $requestCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $script:Apps) {
        $observed = @($samples | ForEach-Object { if ($null -ne $_.Apps[$app].CpuPerPodM) { [double]$_.Apps[$app].CpuPerPodM } })
        if (-not $observed.Count) { continue }
        $peak = [double](($observed | Measure-Object -Maximum).Maximum)
        $oldRequest = [double]$Best.Config[$app].requestCpuM
        $step = [math]::Max(1,[math]::Round($oldRequest*0.05))
        $newRequest = [math]::Ceiling(([math]::Max($peak*1.25,$oldRequest*0.50))/$step)*$step
        if ($newRequest -ge $oldRequest*0.90) { continue }
        $absoluteTrigger = $oldRequest*[double]$Best.Config[$app].hpaTarget/100.0
        $newTarget = [int][math]::Round(100.0*$absoluteTrigger/$newRequest)
        if ($newTarget -lt 10 -or $newTarget -gt 90) { continue }
        if (-not (Test-RecommendationRejected $Rejected 'REQUEST_CONTROL_POINT' $app ([int]$newRequest) $newTarget)) {
            $requestCandidates.Add([pscustomobject]@{Axis='REQUEST_CONTROL_POINT';App=$app;To=[int]$newRequest;NewTarget=$newTarget;Ratio=$oldRequest/[math]::Max(1,$newRequest);Reason="observed peak=${peak}m, preserve trigger=${absoluteTrigger}m";Signature="REQUEST_CONTROL_POINT:${app}:$([int]$newRequest):${newTarget}"})
        }
    }
    if ($requestCandidates.Count) { return @($requestCandidates | Sort-Object Ratio -Descending)[0] }
    return $null
}

function Assert-OneLogicalDelta($BestConfig,$Candidate,$Recommendation) {
    $app=[string]$Recommendation.App
    $diff=@(Get-ConfigDiff $BestConfig $Candidate)
    if ($Recommendation.Axis -eq 'REQUEST_CONTROL_POINT') {
        $allowed=@($diff | Where-Object { $_.App -eq $app -and $_.Field -in @('requestCpuM','hpaTarget') })
        if ($diff.Count -ne 2 -or $allowed.Count -ne 2) { throw 'ONE_DELTA_VIOLATION' }
        $oldTrigger=[double]$BestConfig[$app].requestCpuM*[double]$BestConfig[$app].hpaTarget/100.0
        $newTrigger=[double]$Candidate[$app].requestCpuM*[double]$Candidate[$app].hpaTarget/100.0
        if ([math]::Abs($oldTrigger-$newTrigger) -gt [math]::Max(1.0,$oldTrigger*0.03)) { throw 'CONTROL_POINT_DRIFT' }
    } elseif ($diff.Count -ne 1 -or $diff[0].App -ne $app) { throw 'ONE_DELTA_VIOLATION' }
}

function New-CandidateFromBest($Best, $Recommendation, [string]$Name) {
    if (-not $Best.Measured) { throw 'BEST_IS_NOT_MEASURED' }
    $candidate = Copy-Config $Best.Config $Name
    $candidate.ParentFingerprint = [string]$Best.ConfigFingerprint
    $app = [string]$Recommendation.App
    switch ($Recommendation.Axis) {
        'HPA_MAX' { $candidate[$app].maxReplicas=[int]$Recommendation.To }
        'HPA_TARGET' { $candidate[$app].hpaTarget=[int]$Recommendation.To }
        'MIN_UP' { $candidate[$app].minReplicas=[int]$Recommendation.To }
        'MIN_DOWN' { $candidate[$app].minReplicas=[int]$Recommendation.To }
        'REQUEST_CONTROL_POINT' {
            $candidate[$app].requestCpuM=[int]$Recommendation.To
            $candidate[$app].hpaTarget=[int]$Recommendation.NewTarget
        }
        default { throw "CANDIDATE_AXIS_INVALID: $($Recommendation.Axis)" }
    }
    Assert-OneLogicalDelta $Best.Config $candidate $Recommendation
    $candidate.Fingerprint = Get-ConfigFingerprint $candidate
    return $candidate
}

function Patch-AppResources([string]$App, $Value) {
    $limits = $null
    if ($null -ne $Value.limitCpuM -or $null -ne $Value.limitMemoryMi) {
        $limits = @{
            cpu=$(if ($null -ne $Value.limitCpuM) { Format-CpuM $Value.limitCpuM } else { $null })
            memory=$(if ($null -ne $Value.limitMemoryMi) { Format-MemoryMi $Value.limitMemoryMi } else { $null })
        }
    }
    $resources = @{requests=@{cpu=Format-CpuM $Value.requestCpuM;memory=Format-MemoryMi $Value.requestMemoryMi};limits=$limits}
    $patch = @{spec=@{template=@{spec=@{containers=@(@{name=[string]$Value.containerName;resources=$resources})}}}} | ConvertTo-Json -Depth 12 -Compress
    Invoke-Kubectl @('-n',$Namespace,'patch',"deployment/$App",'--type=strategic','-p',$patch) | Out-Null
}

function Patch-AppHpa([string]$App, $Value) {
    $behavior = if ([string]::IsNullOrWhiteSpace([string]$Value.behaviorJson)) { $null } else { [string]$Value.behaviorJson | ConvertFrom-Json }
    $spec = @{
        minReplicas=[int]$Value.minReplicas
        maxReplicas=[int]$Value.maxReplicas
        metrics=@(@{type='Resource';resource=@{name='cpu';target=@{type='Utilization';averageUtilization=[int]$Value.hpaTarget}}})
        behavior=$behavior
    }
    $patch = @{spec=$spec} | ConvertTo-Json -Depth 20 -Compress
    Invoke-Kubectl @('-n',$Namespace,'patch','hpa',$App,'--type=merge','-p',$patch) | Out-Null
}

function Wait-Deployment([string]$App, [int]$TimeoutSec = 45) {
    $timeout = Get-DeadlineTimeout $TimeoutSec 10
    $output = @(& kubectl --request-timeout=5s -n $Namespace rollout status "deployment/$App" "--timeout=${timeout}s" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "ROLLOUT_TIMEOUT: $App $($output -join ' ')" }
}

function Wait-MinReady([string]$App, [int]$Minimum, [int]$TimeoutSec = 30) {
    $end = [datetime]::UtcNow.AddSeconds((Get-DeadlineTimeout $TimeoutSec 10))
    while ([datetime]::UtcNow -lt $end) {
        $deployment = Get-KubeJson @('-n',$Namespace,'get','deploy',$App,'-o','json')
        if ([int]$deployment.status.availableReplicas -ge $Minimum) { return }
        Start-Sleep -Seconds 2
    }
    throw "MIN_READY_TIMEOUT: $App expected=$Minimum"
}

function Set-ConfigExact($Expected, [string]$Mode) {
    $current = Get-LiveConfig "${Mode}_BEFORE"
    $diff = @(Get-ConfigDiff $Expected $current)
    $placementDrift = @($diff | Where-Object { $_.Field -eq 'placementJson' })
    if ($placementDrift.Count) { throw "PLACEMENT_DRIFT: $(@($placementDrift.App) -join ',')" }
    $resourceFields = @('requestCpuM','requestMemoryMi','limitCpuM','limitMemoryMi')
    $hpaFields = @('minReplicas','maxReplicas','hpaTarget','behaviorJson')
    $resourceApps = @($diff | Where-Object { $_.Field -in $resourceFields } | ForEach-Object App | Sort-Object -Unique)
    $hpaApps = @($diff | Where-Object { $_.Field -in $hpaFields } | ForEach-Object App | Sort-Object -Unique)
    foreach ($app in $resourceApps) { Patch-AppResources $app $Expected[$app] }
    foreach ($app in $hpaApps) { Patch-AppHpa $app $Expected[$app] }
    foreach ($app in $resourceApps) { Wait-Deployment $app }
    foreach ($app in $hpaApps) {
        if ([int]$Expected[$app].minReplicas -gt [int]$current[$app].minReplicas) { Wait-MinReady $app ([int]$Expected[$app].minReplicas) }
    }
    $errorCode = if ($Mode -eq 'ROLLBACK') { 'ROLLBACK_DRIFT' } else { 'CONFIG_DRIFT' }
    Assert-LiveConfig $Expected $errorCode | Out-Null
}

function Test-CandidateBetter($Candidate, $Best) {
    if (-not $Candidate.Valid -or -not $Candidate.Measured) { return [pscustomobject]@{Keep=$false;Reason='measurement invalid'} }
    if ([double]$Candidate.WorstAvailability -lt [double]$Best.WorstAvailability-$NoiseTolerance) {
        return [pscustomobject]@{Keep=$false;Reason='availability regression'}
    }
    foreach ($profile in $Best.ProfileResults.Keys) {
        if ([double]$Candidate.ProfileResults[$profile] -lt [double]$Best.ProfileResults[$profile]-1.0) {
            return [pscustomobject]@{Keep=$false;Reason="significant profile regression: $profile"}
        }
    }
    $performanceGain = [double]$Candidate.WorstPerformance-[double]$Best.WorstPerformance
    if ([double]$Candidate.AverageNodes -ge [double]$Best.AverageNodes+2.0 -and $performanceGain -lt 5.0) {
        return [pscustomobject]@{Keep=$false;Reason='node cost explosion without strong recovery'}
    }
    if ([double]$Candidate.WorstDeficit -lt [double]$Best.WorstDeficit-$NoiseTolerance) {
        return [pscustomobject]@{Keep=$true;Reason='worst performance deficit improved'}
    }
    if ([double]$Candidate.WorstProfileResult -gt [double]$Best.WorstProfileResult+$NoiseTolerance) {
        return [pscustomobject]@{Keep=$true;Reason='worst profile improved'}
    }
    if ([double]$Candidate.AverageResult -gt [double]$Best.AverageResult+$NoiseTolerance) {
        return [pscustomobject]@{Keep=$true;Reason='average result improved'}
    }
    if ([math]::Abs([double]$Candidate.WorstProfileResult-[double]$Best.WorstProfileResult) -le $NoiseTolerance -and
        [math]::Abs([double]$Candidate.AverageResult-[double]$Best.AverageResult) -le $NoiseTolerance -and
        [double]$Candidate.AverageNodes -lt [double]$Best.AverageNodes-0.10) {
        return [pscustomobject]@{Keep=$true;Reason='performance tie with lower node cost'}
    }
    return [pscustomobject]@{Keep=$false;Reason='no measured improvement'}
}

function Test-FinalRegression($Fresh, $Reference) {
    if (-not $Fresh.Valid) { return $true }
    if ([double]$Fresh.WorstAvailability -lt [double]$Reference.WorstAvailability-1.0) { return $true }
    if ([double]$Fresh.WorstPerformance -lt [double]$Reference.WorstPerformance-2.0) { return $true }
    foreach ($profile in $Reference.ProfileResults.Keys) {
        if ([double]$Fresh.ProfileResults[$profile] -lt [double]$Reference.ProfileResults[$profile]-1.0) { return $true }
    }
    return $false
}

function Save-Lifecycle($Lifecycle) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $Lifecycle | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath (Join-Path $OutputDir 'lifecycle.json') -Encoding utf8
}

function Invoke-TuningLifecycle($BaseConfig) {
    if (-not (Test-CanStartBase)) { throw 'NO_TIME_FOR_BASE_AND_SAFE_SHUTDOWN' }
    $base = Invoke-Measurement $BaseConfig 'BASE'
    $best = $base
    $bestConfig = Copy-Config $BaseConfig 'MEASURED_BEST'
    $confirmed = $base
    $confirmedConfig = Copy-Config $BaseConfig 'CONFIRMED_BEST'
    $history = [System.Collections.Generic.List[object]]::new()
    $rejected = [System.Collections.Generic.HashSet[string]]::new()
    $stopReason = 'NO_SAFE_MEASURED_DELTA'
    $skipFinalReason = $null

    if ($NoApply) {
        $lifecycle = [pscustomobject]@{StartedAt=$script:StartTime;HardDeadline=$script:HardDeadline;StopReason='NO_APPLY_BASE_ONLY';Best=$best;BestConfig=$bestConfig;Final=$null;History=@($history)}
        Save-Lifecycle $lifecycle
        return $lifecycle
    }

    for ($iteration=1; $iteration -le $MaxProfileCandidates; $iteration++) {
        $recommendation = Get-Recommendation $best $rejected
        if ($null -eq $recommendation) { $stopReason='NO_SAFE_MEASURED_DELTA'; break }
        if ($recommendation.Axis -eq 'INFRA_STOP') {
            $stopReason=$recommendation.Reason
            $skipFinalReason='INFRASTRUCTURE_INVALID'
            Write-Warning "SEARCH_STOP: $stopReason"
            break
        }
        if (-not (Test-CanStartCandidate)) { $stopReason='NO_TIME_FOR_SAFE_CANDIDATE'; break }
        $candidate = New-CandidateFromBest $best $recommendation "CANDIDATE_$iteration"
        if ([string]$candidate.ParentFingerprint -ne [string]$best.ConfigFingerprint) { throw 'CANDIDATE_NOT_FROM_BEST' }
        $applied = $false
        $stopAfterRollback = $false
        try {
            # Mark before apply so a partial patch is also rolled back exactly.
            $applied = $true
            Set-ConfigExact $candidate 'CANDIDATE'
            $measured = Invoke-Measurement $candidate "CANDIDATE_$iteration"
            $decision = Test-CandidateBetter $measured $best
            $history.Add([pscustomobject]@{Iteration=$iteration;Recommendation=$recommendation;Decision=$(if($decision.Keep){'KEEP'}else{'REJECT'});Reason=$decision.Reason;Measurement=$measured})
            if ($decision.Keep) {
                $confirmed = $best
                $confirmedConfig = Copy-Config $bestConfig 'CONFIRMED_BEST'
                $best = $measured
                $bestConfig = Copy-Config $candidate 'MEASURED_BEST'
                Write-Host "KEEP: $($recommendation.Axis) $($recommendation.App) — $($decision.Reason)" -ForegroundColor Green
            } else {
                Write-Warning "REJECT: $($recommendation.Axis) $($recommendation.App) — $($decision.Reason)"
                [void]$rejected.Add([string]$recommendation.Signature)
                Set-ConfigExact $bestConfig 'ROLLBACK'
                $applied = $false
            }
        } catch {
            $candidateError = $_.Exception.Message
            if ($applied) {
                try { Set-ConfigExact $bestConfig 'ROLLBACK' } catch { throw "ROLLBACK_FAILED_AFTER_ERROR: $($_.Exception.Message)" }
            }
            if ($candidateError -like 'GENERATOR_LIMIT:*') {
                $stopReason=$candidateError
                $skipFinalReason='GENERATOR_LIMIT_MEASUREMENT_INVALID'
                $stopAfterRollback=$true
            } else { throw }
        }
        if ($stopAfterRollback) { break }
    }

    $final = $null; $rolledBack = $false
    if ($skipFinalReason) {
        Assert-LiveConfig $bestConfig 'BEST_DRIFT_AT_EARLY_STOP' | Out-Null
        Write-Warning "FINAL_SKIPPED: $skipFinalReason"
    } else {
        Set-ConfigExact $bestConfig 'BEST_APPLY'
        if (Test-CanStartFinal) {
            try { $final = Invoke-Measurement $bestConfig 'FINAL_FRESH' }
            catch {
                if ($_.Exception.Message -like 'GENERATOR_LIMIT:*') { $stopReason="FINAL_$($_.Exception.Message)" }
                else { throw }
            }
            if ($final -and (Test-FinalRegression $final $best) -and (Get-ConfigFingerprint $bestConfig) -ne (Get-ConfigFingerprint $confirmedConfig)) {
                Set-ConfigExact $confirmedConfig 'ROLLBACK'
                $best = $confirmed
                $bestConfig = Copy-Config $confirmedConfig 'FINAL_ROLLED_BACK_BEST'
                $rolledBack = $true
                $stopReason = 'FINAL_REGRESSION_ROLLBACK'
            }
        } else {
            $stopReason = if ($stopReason -eq 'NO_SAFE_MEASURED_DELTA') { 'NO_TIME_FOR_FINAL_FRESH' } else { $stopReason }
        }
    }
    $lifecycle = [pscustomobject]@{
        StartedAt=$script:StartTime
        HardDeadline=$script:HardDeadline
        FinishedAt=[datetime]::UtcNow
        StopReason=$stopReason
        FinalSkippedReason=$skipFinalReason
        RolledBack=$rolledBack
        Best=$best
        BestConfig=$bestConfig
        Final=$final
        History=@($history)
        WorstCaseRuntimeSec=Get-WorstCaseRuntimeSeconds
    }
    Save-Lifecycle $lifecycle
    return $lifecycle
}

if ($SelfTestOnly) {
    . (Join-Path $PSScriptRoot 'tune/selftest.ps1')
    exit 0
}

$runFailed = $true
$originalConfig = $null
try {
    Require-Command kubectl
    Require-Command aws
    if (-not $SkipKubeconfig) {
        & aws eks update-kubeconfig --name $ClusterName --region $Region --cli-connect-timeout 5 --cli-read-timeout 10 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'KUBECONFIG_UPDATE_FAILED' }
    }
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        $domain = ((& aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='wsi2026'].DomainName | [0]" --output text --cli-connect-timeout 5 --cli-read-timeout 10 2>$null) -join '').Trim()
        if (-not $domain -or $domain -eq 'None') { throw 'CLOUDFRONT_ENDPOINT_NOT_FOUND' }
        $script:Endpoint = "https://$domain"
    } else {
        $script:Endpoint = if ($Endpoint -match '^https?://') { $Endpoint.TrimEnd('/') } else { "https://$($Endpoint.TrimEnd('/'))" }
    }
    Write-Host "HARD_DEADLINE=$($script:HardDeadline.ToString('o'))" -ForegroundColor Cyan
    Write-Host "MAX_RUNTIME=20m (hard ceiling; terminal evidence exits earlier)" -ForegroundColor DarkCyan
    Write-Host "ENDPOINT=$script:Endpoint" -ForegroundColor Cyan
    Write-Host "`n========== MEASURED TUNER ==========" -ForegroundColor Green

    # No tuning mutation is allowed before these two operations complete.
    $originalConfig = Get-LiveConfig 'IMMUTABLE_BASE'
    Show-Config $originalConfig 'Live BASE snapshot'
    $result = Invoke-TuningLifecycle $originalConfig
    $bestLabel=if($result.Final){'Final measured BEST'}else{'Measured BEST (FINAL skipped)'}
    Show-Config $result.BestConfig $bestLabel
    Write-Host "STOP_REASON=$($result.StopReason)" -ForegroundColor Cyan
    Write-Host "RESULT_DIR=$OutputDir" -ForegroundColor Cyan
    $runFailed = $false
} catch {
    $errorRecord = $_
    Write-Error "TUNE_FAILED: $($errorRecord.Exception.Message)"
    if ($originalConfig) {
        try { Set-ConfigExact $originalConfig 'ROLLBACK' } catch { Write-Error "ORIGINAL_ROLLBACK_FAILED: $($_.Exception.Message)" }
    }
    throw
} finally {
    Stop-LocalLoad -Force
    if ($DiscardResults -and -not $runFailed -and (Test-Path -LiteralPath $OutputDir)) {
        Remove-Item -LiteralPath $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
