<#
.SYNOPSIS
    2026 전국기능경기대회 채점 직전 finalize 스크립트
.DESCRIPTION
    채점 부하가 처음 들어오는 시점의 Ready 노드를 1대(Managed)로 보장한다.
    1) Karpenter 노드 drain/삭제 -> Ready 노드 1대
    4) Karpenter NodePool limits.cpu는 MaxNodes/ManagedNodes 기반으로 계산하며 추가 노드는 성능 실측을 통과한 경우에만 허용
    3) HPA min=1, max=SingleNode 튜닝값(또는 현재 값) 적용
    4) 1노드 내 pre-warm (기본 user 2 / product 2 / stress 1)
    5) 노드 1대 + replica + HPA 상태 검증
.EXAMPLE
    .\finalize.ps1 -ProfileJson "%TEMP%\wsi-k6-1234\calculated-final.json"
    .\finalize.ps1 -ProfileJson ... -FreezePreWarm   # 부하 시작까지 replica 유지
    .\finalize.ps1 -DryRun                            # 변경 없이 상태/계획만 표시
#>
[CmdletBinding()]
param(
    [string]$ClusterName = 'wsi2026-cluster',
    [string]$Region = 'ap-northeast-2',
    [switch]$SkipKubeconfig,
    [string]$Namespace = 'app',
    [string]$ProfileJson,
    [int]$UserPreWarm = 2,
    [int]$ProductPreWarm = 2,
    [int]$StressPreWarm = 1,
    # warm 전략 (tune.ps1 dynamic min/OperatingNodeBudget 유지):
    #   drain/NodePool limit은 기본 생략 — 채점 직전 warm Karpenter capacity를 유지한다.
    #   (legacy 1-node 축소는 폐기. -SkipDrain=false로 강제 실행하려면 명시적 지정 필요)
    [switch]$SkipDrain,
    [switch]$SkipNodePoolLimit,
    [switch]$FreezePreWarm,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$apps = @('user','product','stress')
$preWarm = @{ user = $UserPreWarm; product = $ProductPreWarm; stress = $StressPreWarm }
# tune.ps1 SingleNode 기준 최소 CPU request (request가 바뀐 경우 수동 조정)
$NodePoolCpuLimit = 2  # 각 Karpenter NodePool 1대분; 총 OperatingNodeBudget은 profile 기준

function Require([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "명령을 찾을 수 없습니다: $name" }
}

function Invoke-Kubectl([string[]]$Arguments) {
    # Windows PowerShell 5.1 native argument 전달에서 JSON 따옴표가 손상되지 않도록
    # kubectl patch payload는 임시 파일로 전달한다.
    $args2=[System.Collections.Generic.List[string]]::new(); $tempFiles=[System.Collections.Generic.List[string]]::new()
    try {
        for ($i=0; $i -lt $Arguments.Count; $i++) {
            if ($Arguments[$i] -eq '-p' -and ($i+1) -lt $Arguments.Count) {
                $patch=[string]$Arguments[$i+1]
                if ($patch.TrimStart().StartsWith('{') -or $patch.TrimStart().StartsWith('[')) {
                    $file=[IO.Path]::GetTempFileName()
                    [IO.File]::WriteAllText($file,$patch,(New-Object System.Text.UTF8Encoding($false)))
                    $tempFiles.Add($file); $args2.Add('--patch-file'); $args2.Add($file); $i++; continue
                }
            }
            $args2.Add([string]$Arguments[$i])
        }
        $output=@(& kubectl @args2 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "kubectl 실패: kubectl $($args2 -join ' '): $($output -join ' ')" }
    } finally { foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } }
}

function Get-ReadyNodeCount {
    $nodes = (& kubectl get nodes -o json 2>$null) | ConvertFrom-Json
    return @($nodes.items | Where-Object {
        @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
    }).Count
}

function Get-KarpenterNodeNames {
    $nodes = (& kubectl get nodes -o json 2>$null) | ConvertFrom-Json
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @($nodes.items)) {
        $isManaged = $null -ne $node.metadata.labels.'eks.amazonaws.com/nodegroup' -and $node.metadata.labels.'eks.amazonaws.com/nodegroup' -ne ''
        $isReady = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        $deleting = $null -ne $node.metadata.deletionTimestamp
        if (-not $isManaged -and $isReady -and -not $deleting) { $names.Add($node.metadata.name) }
    }
    return @($names)
}

function Get-DeploymentReplicas([string]$app) {
    $d = (& kubectl -n $Namespace get deployment $app -o json) | ConvertFrom-Json
    return [pscustomobject]@{ Desired=[int]$d.spec.replicas; Ready=[int]$d.status.readyReplicas; Available=[int]$d.status.availableReplicas }
}

function Wait-DeploymentRollout([string]$app,[int]$timeoutSec = 180) {
    $output=@(& kubectl -n $Namespace rollout status "deployment/$app" "--timeout=${timeoutSec}s" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "deployment rollout 실패($app): $($output -join ' ')" }
}

Require kubectl
if (-not $SkipKubeconfig) {
    Write-Host "[finalize] kubeconfig 갱신: aws eks update-kubeconfig --name $ClusterName --region $Region" -ForegroundColor Cyan
    & aws eks update-kubeconfig --name $ClusterName --region $Region
    if ($LASTEXITCODE -ne 0) { throw "kubeconfig 갱신 실패: aws eks update-kubeconfig --name $ClusterName" }
}

# ---------- 1. HPA min/max 결정 (ProfileJson 기반 — dynamic warm min 보존) ----------
$hpaMax = @{}
$hpaMin = @{}
if (-not $ProfileJson) {
    # 최신 튜닝 결과(calculated-final.json)를 자동 탐색한다. 인자 없이 실행 가능.
    $candidates = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'wsi-k6-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'calculated-final.json') } |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count) {
        $ProfileJson = Join-Path $candidates[0].FullName 'calculated-final.json'
        Write-Host "[finalize] 최신 튜닝 결과 자동 탐색: $ProfileJson" -ForegroundColor Cyan
    } else {
        Write-Warning '튜닝 결과(calculated-final.json)를 찾지 못해 현재 HPA max를 유지합니다.'
    }
}
if ($ProfileJson) {
    if (-not (Test-Path -LiteralPath $ProfileJson)) { throw "ProfileJson을 찾을 수 없습니다: $ProfileJson" }
    $payload = Get-Content -Raw -LiteralPath $ProfileJson | ConvertFrom-Json
    foreach ($app in $apps) {
        $entry = $payload.Configuration.PSObject.Properties[$app]
        if (-not $entry) { throw "ProfileJson에 $app 설정이 없습니다." }
        $hpaMax[$app] = [int]$entry.Value.maxReplicas
        $hpaMin[$app] = [int]$entry.Value.minReplicas
    }
    Write-Host ("[finalize] ProfileJson에서 HPA min/max 로드: user={0}/{1} product={2}/{3} stress={4}/{5}" -f $hpaMin.user,$hpaMax.user,$hpaMin.product,$hpaMax.product,$hpaMin.stress,$hpaMax.stress) -ForegroundColor Cyan
} else {
    foreach ($app in $apps) {
        $hpa = (& kubectl -n $Namespace get hpa $app -o json) | ConvertFrom-Json
        $hpaMax[$app] = [int]$hpa.spec.maxReplicas
    }
    Write-Host ("[finalize] 현재 HPA max를 유지합니다: user={0} product={1} stress={2}" -f $hpaMax.user,$hpaMax.product,$hpaMax.stress) -ForegroundColor Cyan
}

$requestCpu=@{}
foreach ($app in $apps) {
    $deployment = (& kubectl -n $Namespace get deployment $app -o json) | ConvertFrom-Json
    $requestCpu[$app]=[int]([regex]::Match([string]$deployment.spec.template.spec.containers[0].resources.requests.cpu,'[0-9]+').Value)
}
$totalRequest = 0
foreach ($app in $apps) { $totalRequest += [int]$requestCpu[$app] * $preWarm[$app] }
Write-Host "[finalize] pre-warm CPU request 합계(순수 앱): ${totalRequest}m" -ForegroundColor DarkGray

# ---------- 2. DryRun 계획 표시 ----------
if ($DryRun) {
    Write-Host "`n=== DryRun: 적용 계획 (변경 없음) ===" -ForegroundColor Yellow
    Write-Host "  Ready 노드: $(Get-ReadyNodeCount)대"
    Write-Host "  Karpenter 노드: $(@(Get-KarpenterNodeNames).Count)대"
    Write-Host ("  HPA min/max: user=1/{0} product=1/{1} stress=1/{2}" -f $hpaMax.user,$hpaMax.product,$hpaMax.stress)
    Write-Host "  pre-warm replica: user=$UserPreWarm product=$ProductPreWarm stress=$StressPreWarm"
    if ($FreezePreWarm) { Write-Host '  FreezePreWarm: HPA min을 pre-warm replica 수로 고정 (부하 시작까지 유지)' }
    Write-Host "  NodePool limits.cpu: $NodePoolCpuLimit (추가 노드 총량 제한)" -NoNewline
    if ($SkipNodePoolLimit) { Write-Host ' [SkipNodePoolLimit: 변경 안 함]' } else { Write-Host '' }
    Write-Host "  Karpenter drain: 실행" -NoNewline
    if ($SkipDrain) { Write-Host ' [SkipDrain: 생략]' } else { Write-Host '' }
    exit 0
}

# ---------- 3. Karpenter 노드 drain/삭제 ----------
# warm 전략: 기본 생략 (tune이 만든 warm node 유지 — drain하면 부하 진입 시
# Pending → 재확장 → startup overlap → avg node 증가 → 진입 SLA 하락 재발)
if (-not $SkipDrain -and $PSBoundParameters.ContainsKey('SkipDrain')) {
    $karpenterNodes = @(Get-KarpenterNodeNames)
    if ($karpenterNodes.Count) {
        Write-Host "[finalize] Karpenter 노드 cordon/drain/delete: $($karpenterNodes -join ', ')" -ForegroundColor Yellow
        foreach ($name in $karpenterNodes) {
            try {
                Invoke-Kubectl @('cordon',$name)
                Invoke-Kubectl @('drain',$name,'--ignore-daemonsets','--delete-emptydir-data','--force','--grace-period=10','--timeout=60s')
                Invoke-Kubectl @('delete','node',$name,'--wait=false')
            } catch {
                Write-Warning "Karpenter 노드 $name 정리 실패: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 10
    } else {
        Write-Host '[finalize] drain할 Karpenter 노드가 없습니다.' -ForegroundColor DarkGray
    }
}

# ---------- 4. NodePool 추가 노드 총량 제한 ----------
# 기본 적용: default와 stress NodePool 모두 현재 인스턴스 1대분(2 vCPU)으로 제한한다.
if (-not $SkipNodePoolLimit) {
    $patch = @{spec=@{limits=@{cpu="$NodePoolCpuLimit"}}} | ConvertTo-Json -Compress
    foreach ($nodePoolName in @('default','stress')) {
        $nodePool = ((& kubectl get nodepool $nodePoolName -o json 2>$null) -join '') | ConvertFrom-Json
        if (-not $nodePool) { throw "Karpenter NodePool/$nodePoolName을 찾지 못했습니다. -SkipNodePoolLimit로 우회할 수 있습니다." }
        Invoke-Kubectl @('patch','nodepool',$nodePoolName,'--type=merge','-p',$patch)
        Write-Host ("[finalize] NodePool/{0} limits.cpu={1} 적용 (추가 노드 총량 제한)" -f $nodePoolName,$NodePoolCpuLimit) -ForegroundColor Cyan
    }
}

# ---------- 5. HPA 적용 (ProfileJson의 최종 min/max 그대로) ----------
# 최종 invariant: tune finalConfig == finalize 적용값 == 채점 시작 상태.
# (dynamic warm min을 legacy min=1/preWarm으로 덮어쓰지 않는다)
foreach ($app in $apps) {
    $minReplicas = if ($ProfileJson) { [int]$hpaMin[$app] } else { if ($FreezePreWarm) { $preWarm[$app] } else { 1 } }
    $patch = @{ spec = @{ minReplicas = $minReplicas; maxReplicas = [int]$hpaMax[$app] } } | ConvertTo-Json -Compress
    Invoke-Kubectl @('-n',$Namespace,'patch','hpa',$app,'--type=merge','-p',$patch)
    Write-Host ("[finalize] HPA {0}: min={1} max={2}" -f $app,$minReplicas,$hpaMax[$app]) -ForegroundColor Cyan
}

# ---------- 6. pre-warm scale (final min으로 — warm capacity 유지) ----------
foreach ($app in $apps) {
    $warmReplicas = if ($ProfileJson) { [int]$hpaMin[$app] } else { $preWarm[$app] }
    Invoke-Kubectl @('-n',$Namespace,'scale',"deployment/$app","--replicas=$warmReplicas")
    Write-Host ("[finalize] deployment {0} -> {1} replica (final min)" -f $app,$warmReplicas) -ForegroundColor Cyan
}
foreach ($app in $apps) { Wait-DeploymentRollout $app 180 }

# ---------- 7. 검증 ----------
Write-Host "`n=== 최종 검증 ===" -ForegroundColor Yellow
$readyTotal = Get-ReadyNodeCount
$karpenterLeft = @(Get-KarpenterNodeNames).Count
$fail = 0
$operatingNodeBudget = 3   # tune.ps1 CostBaselineNodes 기준 (Managed 1 + Karpenter 2)
Write-Host "  Ready 노드: $readyTotal 대 (OperatingNodeBudget $operatingNodeBudget 이하 목표)"
if ($readyTotal -gt $operatingNodeBudget) { Write-Warning "Ready 노드가 OperatingNodeBudget 초과: $readyTotal 대"; $fail++ }
Write-Host "  Karpenter 노드: $karpenterLeft 대 (warm capacity 유지 — 0 강제 아님)"
foreach ($app in $apps) {
    $r = Get-DeploymentReplicas $app
    $expectedMin = if ($ProfileJson) { [int]$hpaMin[$app] } else { if ($FreezePreWarm) { $preWarm[$app] } else { 1 } }
    Write-Host ("  {0}: desired={1} ready={2} available={3} (final min {4})" -f $app,$r.Desired,$r.Ready,$r.Available,$expectedMin)
    if ($r.Available -lt $expectedMin) { Write-Warning "$app available replica가 final min($expectedMin) 미달"; $fail++ }
    $hpa = (& kubectl -n $Namespace get hpa $app -o json) | ConvertFrom-Json
    if ([int]$hpa.spec.minReplicas -ne $expectedMin -or [int]$hpa.spec.maxReplicas -ne [int]$hpaMax[$app]) {
        Write-Warning "$app HPA가 기대값과 다릅니다: min=$($hpa.spec.minReplicas) max=$($hpa.spec.maxReplicas)"; $fail++
    }
}
if ($fail -eq 0) {
    Write-Host '✅ 채점 직전 상태: warm min 유지 + final budget 노드' -ForegroundColor Green
} else {
    Write-Host "❌ 검증 실패 항목 $fail 건" -ForegroundColor Red
    exit 1
}
