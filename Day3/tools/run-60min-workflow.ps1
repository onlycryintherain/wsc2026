<#
.SYNOPSIS
    skills-server "60분" 프로필을 실행하고 observe-live.ps1으로 관측·튜닝하면서
    성능 게이트(앱 성능 < 30%)를 감시하는 반복 워크플로우.

.DESCRIPTION
    0. observe-live.ps1을 먼저 실행하고 warm Pod/Node Ready를 확인
    1. POST /api/load/start {template='60분', endpoint}
    2. 주기적으로 /api/score 폴링
       - run_id 불일치(stale snapshot)는 2초×3회 재확인 후 판단
       - grace 이후 user/product/stress 중 하나라도 perf < 30% → 성능 게이트 off
         → POST /api/load/stop + observe 프로세스 종료
         → 이력 기록 후 -AutoRestart면 동일 루프 재시작, 아니면 non-zero exit
       - 프로필이 정상 완주하면 최종 점수 기록 후 종료
.EXAMPLE
    .\tools\run-60min-workflow.ps1
.EXAMPLE
    .\tools\run-60min-workflow.ps1 -AutoRestart -MaxRepeats 10
#>
[CmdletBinding()]
param(
    [string]$LoadServer = 'http://skills-server:8003',
    [string]$Template = '60분',
    [string]$Endpoint = 'https://d1mbhdnownt19i.cloudfront.net',
    [ValidateRange(1, 100)][double]$PerfGatePercent = 30,
    [ValidateRange(5, 120)][int]$PollIntervalSec = 30,
    [ValidateRange(1, 200)][int]$MaxRepeats = 1,
    [ValidateRange(1, 60)][int]$GateGraceMinutes = 15,
    [ValidateRange(60, 900)][int]$PrepareTimeoutSec = 300,
    [switch]$AutoRestart,
    [switch]$StopOnPerfGate,
    [switch]$SkipStartupProfile,
    [switch]$SelfTest,
    [string]$ObserveScript = '',
    [string]$LogPath = (Join-Path ([IO.Path]::GetTempPath()) ("wsi-60min-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ObserveScript)) {
    $ObserveScript = Join-Path $PSScriptRoot 'observe-live.ps1'
}
$script:StopRequested = $false
$script:ObserveProcess = $null
$script:ExpectedRunId = $null

function Write-Log([hashtable]$Entry) {
    $Entry.RecordedAtUtc = [datetime]::UtcNow.ToString('o')
    Add-Content -LiteralPath $LogPath -Value (($Entry | ConvertTo-Json -Compress -Depth 6))
}

function Invoke-Api([string]$Method, [string]$Path, $Body = $null) {
    $params = @{ Uri = "$LoadServer$Path"; Method = $Method; TimeoutSec = 10 }
    if ($null -ne $Body) { $params.ContentType = 'application/json'; $params.Body = ($Body | ConvertTo-Json -Compress -Depth 10) }
    return Invoke-RestMethod @params
}

function Get-ScoreVerified {
    # stale snapshot을 피하기 위해 2초 간격 3회 확인해 run_id와 대조한다.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $score = Invoke-Api 'GET' '/api/score'
        if ($script:ExpectedRunId -and [string]$score.run.run_id -eq $script:ExpectedRunId) { return $score }
        if (-not $script:ExpectedRunId) { return $score }
        Start-Sleep -Seconds 2
    }
    throw "PROFILE_RUN_CHANGED: expected=$($script:ExpectedRunId) actual=$($score.run.run_id)"
}

function Start-Observe {
    $args = @('-NoProfile', '-NonInteractive', '-File', $ObserveScript, '-PrepareForLoad')
    if ($SkipStartupProfile) { $args += '-SkipStartupProfile' }
    $observeLog = Join-Path ([IO.Path]::GetTempPath()) ("wsi-60min-observe-{0}.log" -f (Get-Date -Format 'HHmmss'))
    Write-Host "  observe-live 시작: $ObserveScript (log=$observeLog)" -ForegroundColor DarkCyan
    $script:ObserveProcess = Start-Process -FilePath 'pwsh' -ArgumentList $args -PassThru -RedirectStandardOutput $observeLog -RedirectStandardError ($observeLog + '.err')
    return $observeLog
}

function Wait-ObserveReady {
    $deadline = [datetime]::UtcNow.AddSeconds($PrepareTimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        if ($script:ObserveProcess.HasExited) {
            throw "observe-live가 준비 중 종료됨: exit=$($script:ObserveProcess.ExitCode)"
        }
        try {
            $hpas = kubectl get hpa -n app -o json | ConvertFrom-Json
            $deployments = kubectl get deployment -n app -o json | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw 'kubectl 조회 실패' }
            $ready = $true
            foreach ($app in @('user', 'product', 'stress')) {
                $hpa = @($hpas.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
                $deployment = @($deployments.items | Where-Object { $_.metadata.name -eq $app } | Select-Object -First 1)
                if (-not $hpa -or -not $deployment -or [int]$deployment.status.readyReplicas -lt [int]$hpa.spec.minReplicas) {
                    $ready = $false
                    break
                }
            }
            $pending = @(kubectl get pods -n app --field-selector=status.phase=Pending -o name 2>$null)
            $readyNodes = @(kubectl get nodes --no-headers 2>$null | Where-Object { $_ -match '\sReady\s' }).Count
            if ($ready -and $pending.Count -eq 0 -and $readyNodes -le 2) {
                Write-Host "  observer 준비 완료: warm Pod Ready, Pending=0, ReadyNode=$readyNodes" -ForegroundColor Green
                return
            }
        } catch { }
        Start-Sleep -Seconds 5
    }
    throw "OBSERVER_PREPARE_TIMEOUT: ${PrepareTimeoutSec}s"
}

function Get-MinPerformance($Score) {
    return [double]( @([double]$Score.user_perf, [double]$Score.product_perf, [double]$Score.stress_perf) |
        Measure-Object -Minimum | Select-Object -ExpandProperty Minimum )
}

function Test-PerformanceGate($Score) {
    if (-not $StopOnPerfGate) { return $false }
    if ([int]$Score.logged_minutes -lt $GateGraceMinutes) { return $false }
    return (Get-MinPerformance $Score) -lt $PerfGatePercent
}

function Stop-Observe {
    if ($null -ne $script:ObserveProcess -and -not $script:ObserveProcess.HasExited) {
        try { $script:ObserveProcess.Kill($true) } catch { }
        $script:ObserveProcess = $null
    }
}

function Stop-Profile([string]$Reason) {
    try { Invoke-Api 'POST' '/api/load/stop' -Body @{} | Out-Null } catch { Write-Warning "load/stop 실패: $($_.Exception.Message)" }
    Stop-Observe
    Write-Log @{ Event = 'STOPPED'; Reason = $Reason }
}

if ($SelfTest) {
    $good = [pscustomobject]@{ user_perf = 50; product_perf = 80; stress_perf = 40; logged_minutes = 20 }
    $earlyBad = [pscustomobject]@{ user_perf = 10; product_perf = 80; stress_perf = 20; logged_minutes = 2 }
    if ((Get-MinPerformance $good) -ne 40) { throw 'SELF-TEST FAIL: min performance' }
    if (Test-PerformanceGate $earlyBad) { throw 'SELF-TEST FAIL: grace period' }
    if (-not $StopOnPerfGate -and (Test-PerformanceGate $good)) { throw 'SELF-TEST FAIL: opt-in gate' }
    Write-Host 'SELF-TEST PASS: 3/3' -ForegroundColor Green
    return
}

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { Invoke-Api 'POST' '/api/load/stop' -Body @{} | Out-Null } catch { }
    try { Stop-Observe } catch { }
    Write-Log @{ Event = 'EXITING'; Reason = 'engine exit' }
}

try {
    if (-not (Test-Path -LiteralPath $ObserveScript)) { throw "observe 스크립트 없음: $ObserveScript" }

    foreach ($repeat in 1..$MaxRepeats) {
        Write-Host "`n========== 60분 WORKFLOW 반복 $repeat/$MaxRepeats ==========" -ForegroundColor Green

        # 기존 run이 남아 있으면 status 확인
        $status = Invoke-Api 'GET' '/api/load/status'
        if ([bool]$status.running) {
            Write-Warning "이미 실행 중인 run 감지 run_id=$($status.run_id). 자동 중지 후 재시작합니다."
            Invoke-Api 'POST' '/api/load/stop' -Body @{} | Out-Null
            Start-Sleep -Seconds 5
        }

        # 0. observer를 먼저 준비해 cold-start 손실을 부하 구간 밖으로 이동한다.
        $observeLog = Start-Observe
        Write-Log @{ Event = 'OBSERVE_START'; Log = $observeLog; Repeat = $repeat; SkipStartupProfile = [bool]$SkipStartupProfile }
        Wait-ObserveReady

        # 1. "60분" 프로필 시작 (POST는 retry하지 않는다)
        Write-Host "  template=$Template endpoint=$Endpoint" -ForegroundColor Cyan
        $start = Invoke-Api 'POST' '/api/load/start' -Body @{ template = $Template; endpoint = $Endpoint }
        $script:ExpectedRunId = [string]$start.run_id
        Write-Host "  run_id=$($script:ExpectedRunId)" -ForegroundColor Cyan
        Write-Log @{ Event = 'LOAD_START'; Template = $Template; RunId = $script:ExpectedRunId; Repeat = $repeat }

        # 2. 점수 폴링 루프
        $gateOff = $null
        try {
            while ($true) {
                if ($script:StopRequested) { throw 'USER_STOP' }
                Start-Sleep -Seconds $PollIntervalSec
                $score = Get-ScoreVerified
                $minPerf = Get-MinPerformance $score
                $now = Get-Date -Format 'HH:mm:ss'
                Write-Host ("  [{0}] user={1:F1} product={2:F1} stress={3:F1} min={4:F1} logged={5}m avgEc2={6}" -f `
                    $now, $score.user_perf, $score.product_perf, $score.stress_perf, $minPerf, $score.logged_minutes, $score.avg_ec2) -ForegroundColor DarkGray

                if ($minPerf -lt $PerfGatePercent) {
                    Write-Warning "PERF_LOW: min=$minPerf% (grace=${GateGraceMinutes}m, logged=$($score.logged_minutes)m)"
                }
                # 기본값은 측정 완주다. 명시적 -StopOnPerfGate에서만 grace 이후 중단한다.
                if (Test-PerformanceGate $score) {
                    $gateOff = [pscustomobject]@{ MinPerf = $minPerf; User = $score.user_perf; Product = $score.product_perf; Stress = $score.stress_perf }
                    Write-Warning "PERF_GATE_OFF: min=$minPerf% < ${PerfGatePercent}% (user=$($score.user_perf) product=$($score.product_perf) stress=$($score.stress_perf))"
                    break
                }

                # 프로필 완주 여부: score.run.running == false이고 run_id가 동일하면 완주
                $live = Invoke-Api 'GET' '/api/load/status'
                if (-not [bool]$live.running -and [string]$live.run_id -eq $script:ExpectedRunId -and [int]$live.elapsed_sec -gt 0) {
                    Write-Host "  프로필 완주: elapsed=$($live.elapsed_sec)s" -ForegroundColor Green
                    break
                }
            }
        } catch {
            Stop-Profile "POLL_ERROR: $($_.Exception.Message)"
            throw
        }

        if ($null -ne $gateOff) {
            Stop-Profile "PERF_GATE_OFF(min=$([math]::Round($gateOff.MinPerf,1))%)"
            Write-Log @{ Event = 'GATE_OFF'; MinPerf = $gateOff.MinPerf; User = $gateOff.User; Product = $gateOff.Product; Stress = $gateOff.Stress; Repeat = $repeat }
            if (-not $AutoRestart) {
                Write-Warning "성능 게이트가 꺼졌습니다. observe-live.ps1을 수정한 뒤 다시 실행하세요."
                exit 2
            }
            Write-Host "  -AutoRestart: 30초 후 재시작 (observe-live.ps1을 수정하려면 그 사이에 작업하세요)" -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            continue
        }

        # 정상 완주: 최종 점수
        $final = Get-ScoreVerified
        Write-Log @{ Event = 'COMPLETED'; Total40 = $final.total40; UserPerf = $final.user_perf; ProductPerf = $final.product_perf; StressPerf = $final.stress_perf; AvgEc2 = $final.avg_ec2; Repeat = $repeat }
        Stop-Observe
        Write-Host "`n[완주] total40=$($final.total40) user=$($final.user_perf) product=$($final.product_perf) stress=$($final.stress_perf) avgEc2=$($final.avg_ec2)" -ForegroundColor Green
        Write-Host "로그: $LogPath"
        exit 0
    }
    Write-Warning "MaxRepeats=$MaxRepeats 초과. 프로필을 중지된 상태로 종료합니다."
    exit 3
} finally {
    Stop-Observe
}
