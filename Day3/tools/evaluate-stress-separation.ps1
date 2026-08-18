<#
.SYNOPSIS
    stress 노드 분리 필요 여부를 평가합니다. stress 앱이 과한 부하를 발생시켜
    같은 노드의 user/product에 회귀를 주는지 진단합니다.
.DESCRIPTION
    부하 중에 실행해야 의미가 있습니다. 실제 배포된 stress requests/limits를
    읽어 CPU 점유율을 판단하고, healthcheck 응답, HPA 상태, user/product 영향을
    점수 매트릭스로 종합해 '분리 권장 / 관찰 / 분리 불필요' 3단계로 판정합니다.
    실제로 노드를 분리하지는 않으며, 적용/롤백 명령만 출력합니다.

    사용 예:
        .\tools\evaluate-stress-separation.ps1                     # 30초 CPU 샘플
        .\tools\evaluate-stress-separation.ps1 -SampleSeconds 60   # 60초
        .\tools\evaluate-stress-separation.ps1 -SkipCpuSampling    # 현재 스냅샷만

.NOTES
    판정 기준은 운영 heuristic이며 채점 공식과 무관합니다.
    stress 전용 NodePool은 기본 생성하지 않는다는 정책(AGENTS.md)을 따릅니다.
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 300)][int]$SampleSeconds = 30,
    [ValidateRange(1, 20)][int]$HealthCheckRuns = 5,
    [string]$Namespace = 'app',
    [switch]$SkipCpuSampling
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- helpers
function Invoke-Kubectl {
    param([string[]]$Arguments)
    $out = & kubectl @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($out)
}

function Get-KubectlText {
    param([string[]]$Arguments)
    # kubectl 실패/빈 출력이어도 null 메서드 호출로 죽지 않게 빈 문자열로 안전화.
    $out = & kubectl @Arguments 2>$null
    if ($null -eq $out) { return '' }
    return ([string]::Join('', @($out))).Trim()
}

function Get-DeployResources([string]$app) {
    # 실측 requests/limits를 읽는다(하드코딩 금지).
    $cpuRequest = Get-KubectlText @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.spec.template.spec.containers[0].resources.requests.cpu}')
    $cpuLimit = Get-KubectlText @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.spec.template.spec.containers[0].resources.limits.cpu}')
    $memRequest = Get-KubectlText @('-n',$Namespace,'get','deploy',$app,'-o','jsonpath={.spec.template.spec.containers[0].resources.requests.memory}')
    $cpuRequestM = if ($cpuRequest -match '^(\d+)m$') { [int]$Matches[1] } elseif ($cpuRequest -match '^(\d+)$') { [int]$Matches[1] * 1000 } else { $null }
    $cpuLimitM = if ($cpuLimit -match '^(\d+)m$') { [int]$Matches[1] } elseif ($cpuLimit -match '^(\d+)$') { [int]$Matches[1] * 1000 } else { $null }
    return [pscustomobject]@{ App=$app; CpuRequestM=$cpuRequestM; CpuLimitM=$cpuLimitM; MemoryRequest=$memRequest; RawCpuRequest=$cpuRequest; RawCpuLimit=$cpuLimit }
}

function Get-NodeSummary {
    $nodes = @(Invoke-Kubectl @('get','nodes','--no-headers'))
    $ready = @($nodes | Where-Object { $_ -match '\sReady\s' })
    $managed = @($ready | Where-Object { $_ -match 'managed|ng-' })
    $karpenter = @($ready | Where-Object { $_ -match 'karpenter' -or $_ -notmatch 'managed|ng-' })
    $instanceTypes = @($ready | ForEach-Object { if ($_ -match '(c5\.[a-z0-9]+|t3\.[a-z0-9]+|m5\.[a-z0-9]+)') { $Matches[1] } } | Sort-Object -Unique)
    return [pscustomobject]@{ Ready=$ready.Count; Managed=$managed.Count; Karpenter=$karpenter.Count; InstanceTypes=@($instanceTypes) }
}

function Test-ServiceHealth([string]$ip,[int]$port) {
    # scratch 이미지라 exec 불가한 경우에도 동작하도록 curl.exe로 clusterIP 직접 호출.
    $raw = & curl.exe -s -o NUL -w '%{http_code}|%{time_total}' --connect-timeout 2 --max-time 3 "http://${ip}:${port}/healthcheck" 2>$null
    $parts = ($raw -join '') -split '\|'
    $code = if ($parts.Count -ge 1) { [string]$parts[0] } else { '000' }
    $sec = if ($parts.Count -ge 2 -and $parts[1]) { [double]$parts[1] } else { 3.0 }
    return [pscustomobject]@{ Code=$code; ElapsedMs=[math]::Round($sec*1000) }
}

# ---------------------------------------------------------------- header
Write-Host '=============================================='
Write-Host ' stress 노드 분리 평가 (부하 중 실행 권장)'
Write-Host '=============================================='
Write-Host ''

# ---------------------------------------------------------------- 상태 스냅샷
$nodeSummary = Get-NodeSummary
$stressPods = @(Invoke-Kubectl @('-n',$Namespace,'get','pods','-l','app=stress','--no-headers'))
$stressCount = $stressPods.Count
$stressNotReady = @($stressPods | Where-Object { $_ -notmatch '\s+1/1\s+' }).Count

Write-Host '[ 현재 상태 ]'
Write-Host ("  Ready 노드: {0}대 (Managed {1} + Karpenter {2})  [{3}]" -f $nodeSummary.Ready,$nodeSummary.Managed,$nodeSummary.Karpenter,($nodeSummary.InstanceTypes -join ','))
Write-Host ("  stress pod: {0}개 (NotReady {1})" -f $stressCount,$stressNotReady)
Write-Host ''

$stressRes = Get-DeployResources 'stress'
$userRes = Get-DeployResources 'user'
$productRes = Get-DeployResources 'product'
Write-Host ("  stress request/limit: {0}/{1}  | user request: {2}  | product request: {3}" -f $(if ($null -ne $stressRes.CpuRequestM) { "$($stressRes.CpuRequestM)m" } else { $stressRes.RawCpuRequest }),$(if ($null -ne $stressRes.CpuLimitM) { "$($stressRes.CpuLimitM)m" } else { $stressRes.RawCpuLimit }),$(if ($null -ne $userRes.CpuRequestM) { "$($userRes.CpuRequestM)m" } else { $userRes.RawCpuRequest }),$(if ($null -ne $productRes.CpuRequestM) { "$($productRes.CpuRequestM)m" } else { $productRes.RawCpuRequest }))
Write-Host ''

# ---------------------------------------------------------------- CPU 측정
$cpuRows = [System.Collections.ArrayList]::new()   # pod별 샘플: [pscustomobject]@{Pod; CpuM}
if ($SkipCpuSampling) {
    Write-Host '[ stress CPU ] (샘플링 생략, 1회 스냅샷)'
    $metrics = Invoke-Kubectl @('-n',$Namespace,'top','pods','-l','app=stress','--no-headers')
    foreach ($line in @($metrics)) {
        if ($line -match '^(\S+)\s+(\d+)m') { [void]$cpuRows.Add([pscustomobject]@{Pod=$Matches[1];CpuM=[int]$Matches[2]}) }
    }
} else {
    Write-Host "[ ${SampleSeconds}초간 stress CPU 샘플링 (5초 간격) ]"
    $rounds = [math]::Max(2,[math]::Ceiling($SampleSeconds/5))
    for ($i=0; $i -lt $rounds; $i++) {
        $metrics = Invoke-Kubectl @('-n',$Namespace,'top','pods','-l','app=stress','--no-headers')
        foreach ($line in @($metrics)) {
            if ($line -match '^(\S+)\s+(\d+)m') { [void]$cpuRows.Add([pscustomobject]@{Pod=$Matches[1];CpuM=[int]$Matches[2]}) }
        }
        if ($i -lt $rounds-1) { Start-Sleep -Seconds 5 }
    }
}
if (-not $cpuRows.Count) { Write-Warning 'metrics-server에서 stress CPU를 읽지 못했습니다 (kubectl top pods 확인). CPU 기준은 스킵합니다.' }

$stressCpuAvg = if ($cpuRows.Count) { [math]::Round((($cpuRows | Measure-Object CpuM -Average).Average)) } else { $null }
$stressCpuMax = if ($cpuRows.Count) { ($cpuRows | Measure-Object CpuM -Maximum).Maximum } else { $null }
$cpuValues = @($cpuRows | ForEach-Object { $_.CpuM } | Sort-Object)
$stressCpuP95 = if ($cpuValues.Count) { $cpuValues[[math]::Min($cpuValues.Count-1,[int][math]::Ceiling($cpuValues.Count*0.95)-1)] } else { $null }

Write-Host ("  avg={0}  p95={1}  max={2}  (request {3}m, limit {4}m)" -f $(if ($null -eq $stressCpuAvg) {'-'} else {"${stressCpuAvg}m"}),$(if ($null -eq $stressCpuP95) {'-'} else {"${stressCpuP95}m"}),$(if ($null -eq $stressCpuMax) {'-'} else {"${stressCpuMax}m"}),$(if ($null -ne $stressRes.CpuRequestM) {$stressRes.CpuRequestM} else {'-'}),$(if ($null -ne $stressRes.CpuLimitM) {$stressRes.CpuLimitM} else {'-'}))

$stressCpuPctRequest = if ($null -ne $stressCpuAvg -and $null -ne $stressRes.CpuRequestM -and $stressRes.CpuRequestM -gt 0) { [math]::Round($stressCpuAvg/[double]$stressRes.CpuRequestM*100) } else { $null }
$stressCpuPctLimit = if ($null -ne $stressCpuMax -and $null -ne $stressRes.CpuLimitM -and $stressRes.CpuLimitM -gt 0) { [math]::Round($stressCpuMax/[double]$stressRes.CpuLimitM*100) } else { $null }
Write-Host ("  → avg {0}% of request, max {1}% of limit" -f $(if ($null -eq $stressCpuPctRequest) {'-'} else {$stressCpuPctRequest}),$(if ($null -eq $stressCpuPctLimit) {'-'} else {$stressCpuPctLimit}))

# ---------------------------------------------------------------- healthcheck
Write-Host ''
Write-Host '[ stress healthcheck 응답 ]'
$svcIp = Get-KubectlText @('-n',$Namespace,'get','svc','stress','-o','jsonpath={.spec.clusterIP}')
$svcPort = Get-KubectlText @('-n',$Namespace,'get','svc','stress','-o','jsonpath={.spec.ports[0].port}')
$hcOk = 0; $hcFail = 0; $hcTimeout = 0; $hcElapsed = [System.Collections.ArrayList]::new()
if ($svcIp) {
    for ($i=0; $i -lt $HealthCheckRuns; $i++) {
        $r = Test-ServiceHealth $svcIp $svcPort
        [void]$hcElapsed.Add($r.ElapsedMs)
        if ($r.Code -eq '200') { $hcOk++ } elseif ($r.Code -eq '000') { $hcTimeout++ } else { $hcFail++ }
        Start-Sleep -Seconds 1
    }
    $hcAvg = if ($hcElapsed.Count) { [math]::Round((($hcElapsed | Measure-Object -Average).Average)) } else { 0 }
    Write-Host ("  OK: {0} / Fail: {1} / Timeout: {2}   (avg elapsed {3}ms)" -f $hcOk,$hcFail,$hcTimeout,$hcAvg)
} else {
    Write-Warning 'stress Service clusterIP를 찾지 못해 healthcheck를 스킵합니다.'
}

# ---------------------------------------------------------------- user/product 영향
Write-Host ''
Write-Host '[ user/product 영향 ]'
$userRows = [System.Collections.ArrayList]::new()
$productRows = [System.Collections.ArrayList]::new()
foreach ($line in @(Invoke-Kubectl @('-n',$Namespace,'top','pods','-l','app=user','--no-headers'))) {
    if ($line -match '^(\S+)\s+(\d+)m') { [void]$userRows.Add([pscustomobject]@{Pod=$Matches[1];CpuM=[int]$Matches[2]}) }
}
foreach ($line in @(Invoke-Kubectl @('-n',$Namespace,'top','pods','-l','app=product','--no-headers'))) {
    if ($line -match '^(\S+)\s+(\d+)m') { [void]$productRows.Add([pscustomobject]@{Pod=$Matches[1];CpuM=[int]$Matches[2]}) }
}
$userCpuAvg = if ($userRows.Count) { [math]::Round((($userRows | Measure-Object CpuM -Average).Average)) } else { $null }
$productCpuAvg = if ($productRows.Count) { [math]::Round((($productRows | Measure-Object CpuM -Average).Average)) } else { $null }
$userRestarts = 0; $productRestarts = 0
foreach ($p in @(Invoke-Kubectl @('-n',$Namespace,'get','pods','-l','app=user','-o','jsonpath={range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\\n"}{end}'))) {
    if ($p -match '(\d+)$') { $userRestarts += [int]$Matches[1] }
}
foreach ($p in @(Invoke-Kubectl @('-n',$Namespace,'get','pods','-l','app=product','-o','jsonpath={range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\\n"}{end}'))) {
    if ($p -match '(\d+)$') { $productRestarts += [int]$Matches[1] }
}
$userPct = if ($null -ne $userCpuAvg -and $null -ne $userRes.CpuRequestM -and $userRes.CpuRequestM -gt 0) { [math]::Round($userCpuAvg/[double]$userRes.CpuRequestM*100) } else { $null }
$productPct = if ($null -ne $productCpuAvg -and $null -ne $productRes.CpuRequestM -and $productRes.CpuRequestM -gt 0) { [math]::Round($productCpuAvg/[double]$productRes.CpuRequestM*100) } else { $null }
Write-Host ("  user    avg CPU {0} ({1}% of request {2}m)  restarts={3}" -f $(if ($null -eq $userCpuAvg) {'-'} else {"${userCpuAvg}m"}),$(if ($null -eq $userPct) {'-'} else {$userPct}),$(if ($null -ne $userRes.CpuRequestM) {$userRes.CpuRequestM} else {'-'}),$userRestarts)
Write-Host ("  product avg CPU {0} ({1}% of request {2}m)  restarts={3}" -f $(if ($null -eq $productCpuAvg) {'-'} else {"${productCpuAvg}m"}),$(if ($null -eq $productPct) {'-'} else {$productPct}),$(if ($null -ne $productRes.CpuRequestM) {$productRes.CpuRequestM} else {'-'}),$productRestarts)

# ---------------------------------------------------------------- HPA
Write-Host ''
Write-Host '[ HPA 상태 ]'
$hpaCurrent = Get-KubectlText @('-n',$Namespace,'get','hpa','stress','-o','jsonpath={.status.currentReplicas}')
$hpaMax = Get-KubectlText @('-n',$Namespace,'get','hpa','stress','-o','jsonpath={.spec.maxReplicas}')
$hpaCpu = Get-KubectlText @('-n',$Namespace,'get','hpa','stress','-o','jsonpath={.status.currentMetrics[0].resource.current.averageUtilization}')
Write-Host ("  stress HPA: current={0} max={1} cpu%={2}" -f $(if ($hpaCurrent) {$hpaCurrent} else {'-'}),$(if ($hpaMax) {$hpaMax} else {'-'}),$(if ($hpaCpu) {"$hpaCpu%"} else {'-'}))

# ---------------------------------------------------------------- 판단 매트릭스
Write-Host ''
Write-Host '=============================================='
Write-Host ' 판단 결과'
Write-Host '=============================================='

$score = 0
$reasons = [System.Collections.ArrayList]::new()
$hpaAtMax = ($null -ne $hpaCurrent -and $null -ne $hpaMax -and $hpaMax -match '^\d+$' -and [int]$hpaCurrent -ge [int]$hpaMax -and [int]$hpaMax -gt 0)

# 기준 1: stress 평균 CPU가 request의 70% 이상 (지속 포화)
if ($null -ne $stressCpuPctRequest -and $stressCpuPctRequest -ge 70) {
    $score += 2
    [void]$reasons.Add("stress avg CPU ${stressCpuPctRequest}% of request(≥70%)")
}
# 기준 2: stress max CPU가 limit의 80% 이상 (스파이크 포화)
if ($null -ne $stressCpuPctLimit -and $stressCpuPctLimit -ge 80) {
    $score += 2
    [void]$reasons.Add("stress max CPU ${stressCpuPctLimit}% of limit(≥80%)")
}
# 기준 3: healthcheck 실패/타임아웃 (즉시 조치 대상)
if ($hcFail -gt 0 -or $hcTimeout -gt 0) {
    $score += 3
    [void]$reasons.Add("stress healthcheck 실패 ${hcFail}건, timeout ${hcTimeout}건")
}
# 기준 4: HPA가 max에 도달
if ($hpaAtMax) {
    $score += 2
    [void]$reasons.Add("stress HPA가 최대 replica(${hpaMax})에 도달")
}
# 기준 5: user/product에 실제 영향 (request를 넘는 CPU 또는 restart)
if ($null -ne $userPct -and $userPct -ge 100) {
    $score += 3
    [void]$reasons.Add("user CPU가 request(${userRes.CpuRequestM}m)를 초과(${userPct}%)")
}
if ($null -ne $productPct -and $productPct -ge 100) {
    $score += 3
    [void]$reasons.Add("product CPU가 request(${productRes.CpuRequestM}m)를 초과(${productPct}%)")
}
if ($userRestarts -gt 0 -or $productRestarts -gt 0) {
    $score += 3
    [void]$reasons.Add("user/product restart 발생 (user=$userRestarts, product=$productRestarts)")
}
# 기준 6: 같은 노드 공유 사실 (분리 시 추가 비용 발생을 명시)
$shared = $nodeSummary.Ready -le 1 -or $nodeSummary.Karpenter -eq 0
if (-not $shared) { [void]$reasons.Add("stress가 user/product와 노드를 공유 중 (분리 시 +1 노드 예상)") }

Write-Host ("  분리 필요 점수: {0}" -f $score)
if ($reasons.Count) {
    Write-Host '  근거:'
    foreach ($r in $reasons) { Write-Host "    - $r" -ForegroundColor DarkGray }
}

Write-Host ''
if ($score -ge 5) {
    Write-Host '⚠️  stress 노드 분리를 권장합니다.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '사유:'
    foreach ($r in $reasons) { Write-Host "  - $r" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ('비용 영향: 현재 Ready {0}대 → 분리 시 약 {1}대 (cost ratio {2:N1} → {3:N1})' -f $nodeSummary.Ready,($nodeSummary.Ready+1),[math]::Round($nodeSummary.Ready/2.0,1),[math]::Round(($nodeSummary.Ready+1)/2.0,1))
    Write-Host ''
    Write-Host '적용 방법 (방법 A - Karpenter taint, 채점 시 노드 증가 방지):'
    Write-Host '  # 1) default NodePool에 stress taint 추가'
    Write-Host '  kubectl patch nodepool default --type=merge -p ''{"spec":{"template":{"spec":{"taints":[{"key":"workload","value":"stress","effect":"NoSchedule"}]}}}}'''
    Write-Host '  # 2) stress deployment에 toleration + nodeSelector 적용'
    Write-Host '  kubectl -n app patch deploy stress --type=strategic -p ''{"spec":{"template":{"spec":{"nodeSelector":{"workload":"stress"},"tolerations":[{"key":"workload","operator":"Equal","value":"stress","effect":"NoSchedule"}]}}}}'''
    Write-Host ''
    Write-Host '적용 방법 (방법 B - 기존 patch, taint 없이 전용 노드 지정):'
    Write-Host '  kubectl -n app patch deploy stress --type=strategic -p ''{"spec":{"template":{"spec":{"nodeSelector":{"workload":"stress"}}}}}'''
    Write-Host ''
    Write-Host '롤백:'
    Write-Host '  kubectl -n app patch deploy stress --type=strategic -p ''{"spec":{"template":{"spec":{"nodeSelector":null,"tolerations":null}}}}'''
    Write-Host '  kubectl patch nodepool default --type=merge -p ''{"spec":{"template":{"spec":{"taints":[]}}}}'''
    Write-Host ''
    Write-Host '추가 권장: stress request/limit을 실제 관측치로 조정 (예: avg 대비 1.3x)'
    Write-Host ("  kubectl -n app set resources deployment/stress --requests=cpu=$([math]::Max(100,[math]::Ceiling($(if ($null -eq $stressCpuAvg) {700} else {$stressCpuAvg})*1.3/25)*25))m,memory=256Mi --limits=cpu=$([math]::Max(200,[math]::Ceiling($(if ($null -eq $stressCpuMax) {1000} else {$stressCpuMax})*1.3/25)*25))m,memory=512Mi")
} elseif ($score -ge 3) {
    Write-Host '🔍  관찰이 필요합니다 (부하 지속 시 재평가).' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '사유:'
    foreach ($r in $reasons) { Write-Host "  - $r" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host ('현재 Ready {0}대 유지. stress가 user/product에 실제 회귀를 주는지(5xx/timeout/P95) tune 실행과 함께 확인하세요.' -f $nodeSummary.Ready)
} else {
    Write-Host '✅  현재 stress가 가벼워 분리 불필요. 일반 노드 배치 유지.' -ForegroundColor Green
    Write-Host ''
    Write-Host ("  stress CPU avg {0} (request {1}m 대비 {2}%)" -f $(if ($null -eq $stressCpuAvg) {'-'} else {"${stressCpuAvg}m"}),$(if ($null -ne $stressRes.CpuRequestM) {$stressRes.CpuRequestM} else {'-'}),$(if ($null -eq $stressCpuPctRequest) {'-'} else {$stressCpuPctRequest}))
    Write-Host ("  노드 {0}대 유지 → cost ratio {1:N1}" -f $nodeSummary.Ready,[math]::Round($nodeSummary.Ready/2.0,1))
}

Write-Host ''
Write-Host '=============================================='
