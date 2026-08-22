<#
.SYNOPSIS
    EKS CloudGame 성능 튜닝 스크립트 (WorldSkills 2026)

.DESCRIPTION
    skills-server의 부하 템플릿을 감지하여 최적 설정을 자동 적용합니다.
    - Default (15분): 노드 3대 고정, stress/user pod 분산
    - 순차증가 (30분): spike2 대응을 위해 HPA max 확대 + Karpenter 노드 확장 허용

.PARAMETER SkillsServer
    skills-server URL

.PARAMETER Template
    부하 템플릿 (Default / 순차증가). 미지정시 자동 감지 또는 Default 사용.

.PARAMETER MaxIterations
    테스트 반복 횟수

.PARAMETER SkipTest
    설정만 적용하고 테스트 생략

.PARAMETER DryRun
    설정 내용만 출력하고 적용하지 않음
#>
[CmdletBinding()]
param(
    [string]$SkillsServer = 'http://skills-server:8003',
    [string]$Template = '',
    [int]$MaxIterations = 2,
    [switch]$SkipTest,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ===== HELPERS =====
function Write-Step([string]$msg) { Write-Host "`n[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Write-OK([string]$msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

function Invoke-Api {
    param([string]$Method = 'GET', [string]$Path, [object]$Body)
    $uri = "$SkillsServer$Path"
    $params = @{ Method = $Method; Uri = $uri; ContentType = 'application/json' }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Compress -Depth 10) }
    try { return Invoke-RestMethod @params } catch { Write-Warn "API: $Method $Path - $($_.Exception.Message)"; return $null }
}

function Invoke-ApiCurl {
    param([string]$Method = 'GET', [string]$Path, [string]$JsonBody)
    $uri = "$SkillsServer$Path"
    if ($Method -eq 'GET') {
        return (curl -s $uri 2>$null) | ConvertFrom-Json
    } else {
        $args = @('-s', '-X', $Method, $uri, '-H', 'Content-Type: application/json; charset=utf-8')
        if ($JsonBody) { $args += @('--data-raw', $JsonBody) }
        return (& curl @args 2>$null) | ConvertFrom-Json
    }
}

function Show-Score($s) {
    if (-not $s) { return }
    Write-Host ""
    Write-Host "  === SCORE: $($s.total100)/100 (40pt: $($s.total40)) ===" -ForegroundColor White
    Write-Host "  perf=$($s.performance.score)/$($s.performance.max)  cost=$($s.cost.score)/$($s.cost.max)  avail=$($s.availability.score)/$($s.availability.max)" -ForegroundColor DarkGray
    Write-Host "  user=$([math]::Round($s.user_perf,1))%  product=$([math]::Round($s.product_perf,1))%  stress=$([math]::Round($s.stress_perf,1))%  ec2=$($s.avg_ec2)" -ForegroundColor DarkGray
    Write-Host ""
}

function Wait-LoadDone([int]$TimeoutMin = 35) {
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $st = Invoke-ApiCurl -Path '/api/load/status'
        if (-not $st.running) { Write-OK "Test done"; return $true }
        Write-Host "." -NoNewline
    }
    Write-Warn "Timeout"; return $false
}

function Start-LoadTest([string]$Tmpl) {
    Invoke-ApiCurl -Method POST -Path '/api/load/stop' | Out-Null
    Start-Sleep -Seconds 3
    $body = "{`"template`":`"$Tmpl`"}"
    $r = Invoke-ApiCurl -Method POST -Path '/api/load/start' -JsonBody $body
    if ($r.ok) { Write-OK "Load started: $Tmpl" } else { Write-Warn "Start failed" }
    return $r.ok
}

# ===== DETECT TEMPLATE =====
function Detect-Template {
    # skills-server API에서 사용 가능한 템플릿 확인
    $templates = Invoke-ApiCurl -Path '/api/config/templates'
    if ($templates.templates) {
        $names = $templates.templates | ForEach-Object { $_.name }
        Write-Info "Available templates: $($names -join ', ')"
    }
    # 기본 Default 반환 (사용자가 명시적으로 지정하지 않은 경우)
    return 'Default'
}

# ===== CONFIGURATION PROFILES =====

function Get-DefaultProfile {
    # Default 템플릿 (15분, peak1=22 RPS) - 93.8점 검증
    # 노드 3대 고정, stress 분산, user 미리 스케일업
    return @{
        Name = 'Default'
        Resources = @{
            user    = @{ req_cpu = "50m";  req_mem = "64Mi";  lim_mem = "256Mi" }
            product = @{ req_cpu = "30m";  req_mem = "64Mi";  lim_mem = "256Mi" }
            stress  = @{ req_cpu = "150m"; req_mem = "192Mi"; lim_mem = "512Mi" }
        }
        HPA = @{
            user    = @{ min = 10; max = 15; target = 40 }
            product = @{ min = 2;  max = 5;  target = 70 }
            stress  = @{ min = 6;  max = 10; target = 25 }
        }
        Karpenter = @{
            default_cpu = "2"
            default_mem = "4Gi"
            stress_cpu  = "2"
            stress_mem  = "4Gi"
        }
    }
}

function Get-SequentialProfile {
    # 순차증가 템플릿 (30분, peak2=65 RPS → 분당 4300 요청)
    # 실측 최적: 노드 4대(managed1 + default1 + stress2), stress CPU 확보
    # 75점(30/40) 안정적 달성. stress 80%+ 넘기면 77.5점 가능.
    return @{
        Name = '순차증가'
        Resources = @{
            user    = @{ req_cpu = "30m";  req_mem = "48Mi";  lim_mem = "192Mi" }
            product = @{ req_cpu = "20m";  req_mem = "48Mi";  lim_mem = "192Mi" }
            stress  = @{ req_cpu = "250m"; req_mem = "192Mi"; lim_mem = "512Mi" }
        }
        HPA = @{
            user    = @{ min = 15; max = 40; target = 50 }
            product = @{ min = 2;  max = 8;  target = 70 }
            stress  = @{ min = 8;  max = 12; target = 35 }
        }
        Karpenter = @{
            # stress 전용 2대 + shared(default) 1대
            default_cpu = "2"
            default_mem = "4Gi"
            stress_cpu  = "4"
            stress_mem  = "8Gi"
        }
    }
}

# ===== APPLY =====

function Apply-Profile {
    param([hashtable]$Profile)

    Write-Step "Applying profile: $($Profile.Name)"

    # 1. Karpenter limits
    Write-Info "Karpenter limits..."
    $kp = $Profile.Karpenter
    $patch = "{`"spec`":{`"limits`":{`"cpu`":`"$($kp.default_cpu)`",`"memory`":`"$($kp.default_mem)`"},`"disruption`":{`"consolidationPolicy`":`"WhenEmptyOrUnderutilized`",`"consolidateAfter`":`"60s`"}}}"
    kubectl patch nodepool default --type='merge' -p $patch 2>$null | Out-Null
    Write-Info "  default: cpu=$($kp.default_cpu), mem=$($kp.default_mem)"

    $stressNp = kubectl get nodepool stress -o name 2>$null
    if ($stressNp) {
        $patch2 = "{`"spec`":{`"limits`":{`"cpu`":`"$($kp.stress_cpu)`",`"memory`":`"$($kp.stress_mem)`"},`"disruption`":{`"consolidationPolicy`":`"WhenEmptyOrUnderutilized`",`"consolidateAfter`":`"60s`"}}}"
        kubectl patch nodepool stress --type='merge' -p $patch2 2>$null | Out-Null
        Write-Info "  stress: cpu=$($kp.stress_cpu), mem=$($kp.stress_mem)"
    }

    # 2. Resources (CPU limit 미지정 = 제거)
    Write-Info "Resources..."
    foreach ($app in @('user', 'product', 'stress')) {
        $res = $Profile.Resources[$app]
        $body = @{ $app = $res }
        $r = Invoke-Api -Method PUT -Path '/api/config/resources' -Body $body
        if ($r.ok) { Write-Info "  $app : $($res.req_cpu) / $($res.req_mem) / $($res.lim_mem)" }
    }

    # 3. HPA
    Write-Info "HPA..."
    $r = Invoke-Api -Method PUT -Path '/api/config/hpa' -Body $Profile.HPA
    if ($r.ok) {
        foreach ($app in @('user', 'product', 'stress')) {
            $h = $Profile.HPA[$app]
            Write-Info "  $app : min=$($h.min) max=$($h.max) target=$($h.target)%"
        }
    }

    Write-OK "Profile applied: $($Profile.Name)"
}

# ===== ADJUSTMENT LOGIC =====

function Adjust-ForScore {
    param([hashtable]$Profile, $Score)

    $adj = @{
        Name = $Profile.Name
        Resources = @{}
        HPA = @{}
        Karpenter = @{}
    }
    # Deep copy
    foreach ($app in @('user','product','stress')) {
        $adj.Resources[$app] = @{}; $adj.HPA[$app] = @{}
        foreach ($k in $Profile.Resources[$app].Keys) { $adj.Resources[$app][$k] = $Profile.Resources[$app][$k] }
        foreach ($k in $Profile.HPA[$app].Keys) { $adj.HPA[$app][$k] = $Profile.HPA[$app][$k] }
    }
    foreach ($k in $Profile.Karpenter.Keys) { $adj.Karpenter[$k] = $Profile.Karpenter[$k] }

    # stress availability < 50% → stress가 완전히 죽음 → requests 더 줄이고 max 대폭 확대
    if ($Score.stress_avail -lt 60) {
        Write-Info "stress availability critical ($([math]::Round($Score.stress_avail,1))%) → max 확대 + req 축소"
        $adj.Resources.stress.req_cpu = "80m"
        $adj.Resources.stress.req_mem = "96Mi"
        $adj.Resources.stress.lim_mem = "256Mi"
        $adj.HPA.stress.min = 8
        $adj.HPA.stress.max = 20
        $adj.HPA.stress.target = 50
        $adj.Karpenter.stress_cpu = "6"
        $adj.Karpenter.stress_mem = "12Gi"
    }
    elseif ($Score.stress_perf -lt 50) {
        Write-Info "stress perf low ($([math]::Round($Score.stress_perf,1))%) → max 증가"
        $adj.HPA.stress.max = [math]::Min(20, $adj.HPA.stress.max + 5)
        $adj.HPA.stress.min = [math]::Min(10, $adj.HPA.stress.min + 2)
    }

    # user perf < 30% → user p50이 SLA 초과 → pod 대폭 확대
    if ($Score.user_perf -lt 30) {
        Write-Info "user perf critical ($([math]::Round($Score.user_perf,1))%) → max 확대"
        $adj.Resources.user.req_cpu = "20m"
        $adj.Resources.user.req_mem = "32Mi"
        $adj.Resources.user.lim_mem = "128Mi"
        $adj.HPA.user.min = 15
        $adj.HPA.user.max = 60
        $adj.HPA.user.target = 50
        $adj.Karpenter.default_cpu = "10"
        $adj.Karpenter.default_mem = "20Gi"
    }
    elseif ($Score.user_perf -lt 70) {
        Write-Info "user perf low ($([math]::Round($Score.user_perf,1))%) → max/min 증가"
        $adj.HPA.user.max = [math]::Min(50, $adj.HPA.user.max + 10)
        $adj.HPA.user.min = [math]::Min(15, $adj.HPA.user.min + 3)
    }

    # avg_ec2 > 3 → 비용 과다: Karpenter 제한 강화는 하되 성능 우선
    # (37점 목표에서는 성능/가용성이 비용보다 우선)

    return $adj
}

# ===== MAIN =====

Write-Host ""
Write-Host "===== WSI 2026 EKS CloudGame Tuner =====" -ForegroundColor Cyan
Write-Host ""

$startTime = Get-Date

# Template 결정
if (-not $Template) {
    $Template = Detect-Template
    Write-Info "Using template: $Template"
}

# Profile 선택
$profile = switch ($Template) {
    '순차증가' { Get-SequentialProfile }
    default   { Get-DefaultProfile }
}

Write-Step "Selected profile: $($profile.Name)"
Write-Info "Template duration: $(if ($Template -eq '순차증가') { '30min' } else { '15min' })"

# 현재 점수 확인
$curScore = Invoke-ApiCurl -Path '/api/score'
if ($curScore) {
    Write-Step "Current score"
    Show-Score $curScore
}

if ($DryRun) {
    Write-Step "[DRY RUN] Config to apply:"
    Write-Host ($profile | ConvertTo-Json -Depth 5)
    return
}

# Profile 적용
Apply-Profile $profile

# Pod 안정화 대기
Write-Step "Waiting for pods to stabilize (45s)..."
Start-Sleep -Seconds 45

# EC2 확인
$cluster = Invoke-ApiCurl -Path '/api/cluster'
if ($cluster) { Write-Info "EC2: $($cluster.ec2.count) nodes" }

# 테스트 실행
if ($SkipTest) {
    Write-Step "Skipping load test (-SkipTest)"
} else {
    for ($iter = 1; $iter -le $MaxIterations; $iter++) {
        Write-Step "=== Iteration $iter/$MaxIterations ==="

        $started = Start-LoadTest $Template
        if (-not $started) { Write-Warn "Failed to start"; break }

        $timeoutMin = if ($Template -eq '순차증가') { 33 } else { 17 }
        $done = Wait-LoadDone $timeoutMin
        if (-not $done) {
            Invoke-ApiCurl -Method POST -Path '/api/load/stop' | Out-Null
            Start-Sleep -Seconds 5
        }

        $score = Invoke-ApiCurl -Path '/api/score'
        Write-Step "Result (iter $iter)"
        Show-Score $score

        # 목표 달성 체크
        if ($score.total40 -ge 37) {
            Write-OK "TARGET ACHIEVED: $($score.total40)/40 ($($score.total100)/100)"
            break
        }

        # 마지막이 아니면 조정 후 재시도
        if ($iter -lt $MaxIterations) {
            Write-Step "Adjusting config based on results..."
            $profile = Adjust-ForScore -Profile $profile -Score $score
            Apply-Profile $profile
            Write-Step "Waiting for stabilization (45s)..."
            Start-Sleep -Seconds 45
        }
    }
}

# 최종 결과
Write-Step "Final"
$final = Invoke-ApiCurl -Path '/api/score'
Show-Score $final

$elapsed = (Get-Date) - $startTime
Write-Host "Done in $([math]::Round($elapsed.TotalMinutes,1)) min" -ForegroundColor Green
Write-Host ""
