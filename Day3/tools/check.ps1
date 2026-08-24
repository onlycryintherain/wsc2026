<#
.SYNOPSIS
    2026 전국기능경기대회 Cloud 최종 점검 스크립트
.DESCRIPTION
    API 응답, 보안(WAF), 이미지 파이프라인, Kubernetes, ALB, RDS, S3, 비용을
    한 번에 점검하고 미흡 항목을 출력합니다.
.PARAMETER Endpoint
    CloudFront endpoint URL. 생략 시 자동 검색합니다.
#>
[CmdletBinding()]
param(
    [string]$Endpoint,
    [switch]$Api,
    [switch]$Finalize
)

$ErrorActionPreference = 'Continue'
$Region = 'ap-northeast-2'
$Fail = New-Object System.Collections.ArrayList

# --- Endpoint detection ---
if (-not $Endpoint) {
    Write-Host '[check] CloudFront 엔드포인트 검색...'
    # CloudFront API는 글로벌 서비스지만, CLI 프로파일/리전 설정에
    # 영향을 받지 않도록 us-east-1을 명시한다. JSON으로 받아서
    # PowerShell의 text 출력/개행 처리 차이도 피한다.
    $cfItems = @(
        aws cloudfront list-distributions `
            --region us-east-1 `
            --query 'DistributionList.Items[].{Comment:Comment,DomainName:DomainName,Status:Status}' `
            --output json 2>$null | ConvertFrom-Json
    )
    $cf = $cfItems |
        Where-Object { $_.Comment -and $_.Comment.Trim() -eq 'wsi2026' } |
        Select-Object -First 1
    if (-not $cf) {
        # Comment이 변경된 경우에도 단일 배포 환경에서는 검사 가능하도록 fallback
        $cf = $cfItems | Where-Object { $_.Status -eq 'Deployed' } | Select-Object -First 1
    }
    if (-not $cf) {
        Write-Host '❌ CloudFront 못 찾음. -Endpoint https://xxx.cloudfront.net 으로 지정하세요.'
        exit 1
    }
    $Endpoint = "https://$($cf.DomainName)"
}
if ($Endpoint -notmatch '^https?://') { $Endpoint = "https://$Endpoint" }
$Endpoint = $Endpoint.TrimEnd('/')
Write-Host "[check] endpoint=$Endpoint`n"

# dump에서 테스트 데이터 추출. check.ps1 단독 실행이 가능하도록 외부 helper에
# 의존하지 않는다. 당일 dump 형식이 SQL/JSON/CSV/텍스트로 바뀌어도 첫 사용자를 찾는다.
function Get-CheckFixture {
    $dumpPath = if ($env:LOAD_USER_DUMP) { $env:LOAD_USER_DUMP } else { Join-Path $PSScriptRoot '..\application\load_user.dump' }
    if (-not (Test-Path -LiteralPath $dumpPath)) { $dumpPath = Join-Path $PSScriptRoot '..\application\load_user.dump' }
    $raw = if (Test-Path -LiteralPath $dumpPath) { Get-Content -LiteralPath $dumpPath -Raw -Encoding UTF8 } else { '' }

    $id = $null
    $email = $null
    $emailMatch = [regex]::Match($raw, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')
    if ($emailMatch.Success) { $email = $emailMatch.Value }

    $idMatch = [regex]::Match($raw, "(?im)^\s*INSERT\s+INTO\s+[^\r\n]*user[^\r\n]*SET\s+id\s*=\s*'([^']+)")
    if ($idMatch.Success) { $id = $idMatch.Groups[1].Value }
    if (-not $id) { $idMatch = [regex]::Match($raw, '(?i)"(?:id|user_id|userid|username)"\s*:\s*"?([A-Za-z0-9_.-]+)') }
    if ($idMatch.Success -and -not $id) { $id = $idMatch.Groups[1].Value }
    if (-not $id) {
        $idMatch = [regex]::Match($raw, "\('([^']+)'\s*,\s*'[^']+'\s*,\s*'[^']+'\)")
        if ($idMatch.Success) { $id = $idMatch.Groups[1].Value }
    }
    if (-not $id) {
        $idMatch = [regex]::Match($raw, '(?i)\b(?:dbdump|user)[A-Za-z0-9_-]*\d+\b')
        if ($idMatch.Success) { $id = $idMatch.Value }
    }
    if (-not $id) { $id = if ($env:CHECK_USER_ID) { $env:CHECK_USER_ID } else { 'dbdump1' } }
    if (-not $email) { $email = if ($env:CHECK_USER_EMAIL) { $env:CHECK_USER_EMAIL } else { "$id@example.org" } }

    return [pscustomobject]@{
        UserId = $id
        UserEmail = $email
        ProductId = if ($env:CHECK_PRODUCT_ID) { $env:CHECK_PRODUCT_ID } else { 'dbdump500001' }
    }
}

$fixture = Get-CheckFixture
$TestUserId = $fixture.UserId
$TestUserEmail = $fixture.UserEmail
$TestProductId = $fixture.ProductId

Write-Host "[check] dump user: id=$TestUserId email=$TestUserEmail; product=$TestProductId`n"

# --- Helper ---
function Test-Http {
    param([string]$Name, [int]$Expect, [string]$Url, [string]$Method = 'GET', [string]$Body, [int]$SloMs = 0)
    
    $args = @('-s', '-o', 'NUL', '-w', '%{http_code}|%{time_total}', '-A', 'wsi2026-check/1.0', '--connect-timeout', '5', '--max-time', '30')
    if ($Method -eq 'POST') {
        $args += @('-X', 'POST', '-H', 'Content-Type: application/json', '-d', $Body)
    } elseif ($Method -eq 'DELETE') {
        $args += @('-X', 'DELETE')
    }
    $args += $Url
    
    $raw = (& curl.exe @args 2>$null) -join ''
    $parts = $raw -split '\|'
    $code = if ($parts.Count -ge 1) { [int]$parts[0] } else { 0 }
    $time = if ($parts.Count -ge 2) { [double]$parts[1] } else { 30.0 }
    $ms = [int]($time * 1000)
    
    $status = if ($code -eq $Expect) { '✅' } else { '❌' }
    Write-Host ("  {0} {1,-28} HTTP:{2,3} {3,5}ms" -f $status, $Name, $code, $ms)
    
    if ($code -ne $Expect) {
        [void]$script:Fail.Add("$Name : HTTP $code (expected $Expect)")
    }
    if ($SloMs -gt 0 -and $ms -gt $SloMs -and $code -eq $Expect) {
        [void]$script:Fail.Add("$Name 응답시간 ${ms}ms (>${SloMs}ms)")
    }
}

Write-Host '=============================================='
Write-Host ' 2026 전국기능경기대회 Cloud 최종 점검'
Write-Host '=============================================='
Write-Host ''

# ===== API =====
Write-Host '========== API =========='
Test-Http 'Healthcheck' 200 "$Endpoint/healthcheck" -SloMs 200
Test-Http 'User GET' 200 "$Endpoint/v1/user?email=$([Uri]::EscapeDataString($TestUserEmail))&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729" -SloMs 200
# load_user.dump에는 상품 seed가 없으므로, 테스트용 상품을 먼저 보장한다.
$seedBody = @{
    requestid = '999999999999'
    uuid      = '7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729'
    id        = $TestProductId
    name      = 'check-product'
    price     = 1
} | ConvertTo-Json -Compress
$existingProduct = curl.exe -s -o NUL -w '%{http_code}' -A 'wsi2026-check/1.0' "$Endpoint/v1/product?id=$([Uri]::EscapeDataString($TestProductId))&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729" 2>$null
if ($existingProduct -ne '200') {
    $seedRaw = curl.exe -s -o NUL -w '%{http_code}' -A 'wsi2026-check/1.0' -X POST -H 'Content-Type: application/json' -d $seedBody "$Endpoint/v1/product" 2>$null
    if ($seedRaw -notmatch '^(200|201|409)$') { Write-Host "  ⚠️ Product seed HTTP:$seedRaw" }
} else {
    Write-Host "  Product fixture already exists: $TestProductId"
}
Test-Http 'Product GET' 200 "$Endpoint/v1/product?id=$TestProductId&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729" -SloMs 200
Test-Http 'Stress POST' 201 "$Endpoint/v1/stress" -Method POST -Body '{"requestid":"999999999999","uuid":"7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729","length":256}' -SloMs 1000
Write-Host ''

# ===== Security (WAF) =====
Write-Host '========== Security (WAF) =========='
Test-Http 'DELETE /v1/user (block)' 403 "$Endpoint/v1/user" -Method DELETE
Test-Http 'Malformed existing API (block)' 403 "$Endpoint/v1/user?email=$([Uri]::EscapeDataString($TestUserEmail))%27%20or%20%271%27=%271&requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729"
Test-Http 'Unknown API /v1/none' 404 "$Endpoint/v1/none"
Test-Http 'Unknown malicious path' 404 "$Endpoint/v1/none?x=%27%20or%20%271%27=%271"
Write-Host ''

if ($Api) {
    Write-Host '=============================================='
    Write-Host '              API 점검 결과'
    Write-Host '=============================================='
    if ($Fail.Count -eq 0) {
        Write-Host '✅ API 점검 통과' -ForegroundColor Green
        exit 0
    }
    Write-Host "❌ API 미흡 항목 ($($Fail.Count)건)" -ForegroundColor Red
    foreach ($item in $Fail) { Write-Host "   - $item" -ForegroundColor Yellow }
    exit 1
}

# ===== Image Pipeline =====
Write-Host '========== Image Pipeline =========='
# PUT으로 이미지 업로드 후 다운로드 확인
$imageToken = (Get-Date -Format 'yyyyMMddHHmmssfff')
$imageFilename = "check-product-$imageToken.png"
$testImg = Join-Path $env:TEMP $imageFilename
if (-not (Test-Path $testImg)) {
    [IO.File]::WriteAllBytes($testImg, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='))
}
$putRaw = curl.exe -s -w '|%{http_code}' -A 'wsi2026-check/1.0' -X PUT -F "id=$TestProductId" -F 'requestid=999999999999' -F 'uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729' -F "image=@$testImg;type=image/png;filename=$imageFilename" "$Endpoint/v1/product?requestid=999999999999&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729" 2>$null
$putParts = ($putRaw -join '') -split '\|'
$putCode = if ($putParts.Count -ge 2) { [int]$putParts[-1] } else { 0 }
$putBody = ($putParts[0..($putParts.Count-2)] -join '|')
if ($putCode -eq 200) {
    Write-Host "  ✅ PUT /v1/product (image)    HTTP:200"
    # image_path 추출
    try { $imgPath = ($putBody | ConvertFrom-Json).image_path } catch { $imgPath = '' }
    if ($imgPath) {
        Test-Http 'Image Download' 200 "$Endpoint/images$imgPath" -SloMs 5000
    } else {
        Write-Host "  ⚠️  image_path를 응답에서 찾을 수 없음"
        [void]$Fail.Add("PUT 응답에 image_path 없음")
    }
} else {
    Write-Host "  ❌ PUT /v1/product (image)    HTTP:$putCode"
    [void]$Fail.Add("Image PUT : HTTP $putCode (expected 200)")
}
Write-Host ''

# ===== Kubernetes =====
Write-Host '========== Kubernetes =========='
Write-Host '  --- Nodes ---'
kubectl get nodes -o wide
$notReady = @(kubectl get nodes --no-headers | Where-Object { $_ -notmatch '\sReady\s' })
if ($notReady.Count -gt 0) { [void]$Fail.Add("Ready가 아닌 Node $($notReady.Count)개") }

Write-Host '  --- Pods ---'
kubectl -n app get pods -o wide
$badPods = @(kubectl -n app get pods --no-headers | Where-Object { $_ -notmatch 'Running|Completed' })
if ($badPods.Count -gt 0) { [void]$Fail.Add("Running 상태가 아닌 Pod $($badPods.Count)개") }

Write-Host '  --- HPA ---'
kubectl -n app get hpa -o wide

Write-Host '  --- Deployments ---'
kubectl -n app get deploy -o wide
Write-Host ''

# ===== Finalize (채점 직전) 검증 =====
if ($Finalize) {
    Write-Host '========== Finalize (채점 직전) =========='
    # warm 전략: score-optimal warm node budget 이하 + dynamic min 유지 (legacy 1-node 검증 폐기).
    $operatingNodeBudget = 2   # tune.ps1 CostBaselineNodes 기준 (필요 시 조정)
    $readyNodes = @(kubectl get nodes --no-headers | Where-Object { $_ -match '\sReady\s' })
    Write-Host "  Ready Node: $($readyNodes.Count)대 (OperatingNodeBudget $operatingNodeBudget 이하 목표)"
    if ($readyNodes.Count -gt $operatingNodeBudget) { [void]$Fail.Add("Ready Node가 OperatingNodeBudget($operatingNodeBudget) 초과: $($readyNodes.Count)대") }

    $hpaInfo = kubectl -n app get hpa -o json 2>$null | ConvertFrom-Json
    if ($hpaInfo -and $hpaInfo.items) {
        foreach ($item in @($hpaInfo.items)) {
            if ([int]$item.spec.minReplicas -lt 1 -or [int]$item.spec.maxReplicas -lt [int]$item.spec.minReplicas) {
                [void]$Fail.Add("HPA $($item.metadata.name) min/max 비정상: $($item.spec.minReplicas)/$($item.spec.maxReplicas)")
            }
            Write-Host ("  HPA {0}: min={1} max={2}" -f $item.metadata.name,$item.spec.minReplicas,$item.spec.maxReplicas)
        }
    }

    # calculated-final.json이 있으면 live HPA min/max와 최종 설정을 비교한다 (dynamic warm min 검증)
    $finalJson = $null
    $finalCandidates = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'wsi-k6-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'calculated-final.json') } |
        Sort-Object LastWriteTime -Descending)
    if ($finalCandidates.Count) {
        $finalJson = Join-Path $finalCandidates[0].FullName 'calculated-final.json'
        $finalPayload = Get-Content -Raw -LiteralPath $finalJson | ConvertFrom-Json
        foreach ($app in @('user','product','stress')) {
            $entry = $finalPayload.Configuration.PSObject.Properties[$app]
            if (-not $entry) { continue }
            $expMin = [int]$entry.Value.minReplicas
            $expMax = [int]$entry.Value.maxReplicas
            $liveHpa = kubectl -n app get hpa $app -o json 2>$null | ConvertFrom-Json
            if ($liveHpa -and $liveHpa.spec) {
                if ([int]$liveHpa.spec.minReplicas -ne $expMin -or [int]$liveHpa.spec.maxReplicas -ne $expMax) {
                    [void]$Fail.Add("$app live HPA가 finalConfig와 다름: live $($liveHpa.spec.minReplicas)/$($liveHpa.spec.maxReplicas) vs final $expMin/$expMax")
                }
                $ready = kubectl -n app get deploy $app -o jsonpath='{.status.readyReplicas}' 2>$null
                if ($null -ne $ready -and [int]$ready -lt $expMin) { [void]$Fail.Add("$app ready($ready) < final min($expMin)") }
            }
        }
    }

    # 1노드 용량 대비 HPA max CPU request 합계 검증 (system/DaemonSet 오버헤드 25% 가정)
    $requestCpu = @{ user = 125; product = 50; stress = 700 }
    $nodeJson = kubectl get nodes -o json 2>$null | ConvertFrom-Json
    if ($nodeJson -and $nodeJson.items) {
        $node = $nodeJson.items | Where-Object {
            @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        } | Select-Object -First 1
        if ($node) {
            $allocCpu = 0
            if ($node.status.allocatable.cpu -match '^(\d+)m$') { $allocCpu = [int]$Matches[1] }
            elseif ($node.status.allocatable.cpu -match '^\d+$') { $allocCpu = [int]$node.status.allocatable.cpu * 1000 }
            $appBudget = [int]($allocCpu * 0.75)
            $totalMaxRequest = 0
            foreach ($item in @($hpaInfo.items)) {
                $totalMaxRequest += [int]$requestCpu[$item.metadata.name] * [int]$item.spec.maxReplicas
            }
            Write-Host "  Node allocatable: ${allocCpu}m, 앱 가용(75%): ${appBudget}m, HPA max 합계 request: ${totalMaxRequest}m"
            if ($totalMaxRequest -gt $appBudget) {
                [void]$Fail.Add("HPA max 합계 CPU request ${totalMaxRequest}m가 1노드 가용 ${appBudget}m를 초과합니다")
            }
        }
    }
    Write-Host ''
}

# ===== ALB =====
Write-Host '========== ALB =========='
$albState = (aws elbv2 describe-load-balancers --region $Region --query 'LoadBalancers[].{DNS:DNSName,State:State.Code}' --output table)
$albState | ForEach-Object { Write-Host "  $_" }
if ($albState -join '' -notmatch 'active') { [void]$Fail.Add("ALB 상태 비정상") }
Write-Host ''

# ===== RDS =====
Write-Host '========== RDS =========='
$rdsInfo = aws rds describe-db-instances --region $Region --query 'DBInstances[].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ,Class:DBInstanceClass}' --output table
$rdsInfo | ForEach-Object { Write-Host "  $_" }
$rdsStatus = (aws rds describe-db-instances --region $Region --query 'DBInstances[0].DBInstanceStatus' --output text).Trim()
if ($rdsStatus -ne 'available') { [void]$Fail.Add("RDS 상태: $rdsStatus") }
Write-Host ''

# ===== Cost (Instance Count) =====
Write-Host '========== Cost =========='
$nodeCount = @(kubectl get nodes --no-headers | Where-Object { $_ -match '\sReady\s' }).Count
$ratio = [math]::Round($nodeCount / 2.0, 2)
$costPoints = if ($ratio -le 1.0) { 12 } elseif ($ratio -le 1.5) { 10 } elseif ($ratio -le 2.0) { 8 } elseif ($ratio -le 2.5) { 6 } elseif ($ratio -le 3.0) { 4 } elseif ($ratio -le 3.5) { 2 } else { 0 }
Write-Host "  Nodes: $nodeCount / Baseline: 2 / Ratio: $ratio / Cost Points: $costPoints/12"
if ($costPoints -lt 6) { [void]$Fail.Add("인스턴스 비용 ratio $ratio (cost points: $costPoints/12)") }
Write-Host ''

# ===== S3 =====
Write-Host '========== S3 =========='
aws s3 ls | ForEach-Object { Write-Host "  $_" }
Write-Host ''

# ===== ECR =====
Write-Host '========== ECR =========='
aws ecr describe-repositories --region $Region --query 'repositories[].repositoryName' --output table | ForEach-Object { Write-Host "  $_" }
Write-Host ''

# ===== ALB Target Health =====
Write-Host '========== ALB Target Health =========='
$tgbs = kubectl -n app get targetgroupbinding -o json 2>$null | ConvertFrom-Json
if ($tgbs -and $tgbs.items) {
    foreach ($tgb in $tgbs.items) {
        $svc = $tgb.spec.serviceRef.name
        $health = aws elbv2 describe-target-health --target-group-arn $tgb.spec.targetGroupARN --region $Region --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>$null
        $unhealthy = @(($health -split '\s+') | Where-Object { $_ -eq 'unhealthy' }).Count
        Write-Host "  $svc : $health"
        if ($unhealthy -gt 0) { [void]$Fail.Add("$svc ALB target unhealthy: $unhealthy개") }
    }
}
Write-Host ''

# ===== Result =====
Write-Host '=============================================='
Write-Host '               최종 결과'
Write-Host '=============================================='
if ($Fail.Count -eq 0) {
    Write-Host '✅ 모든 점검 통과' -ForegroundColor Green
    Write-Host '🚀 제출 가능한 상태입니다.'
} else {
    Write-Host "❌ 미흡한 항목 ($($Fail.Count)건)" -ForegroundColor Red
    foreach ($item in $Fail) {
        Write-Host "   - $item" -ForegroundColor Yellow
    }
}
Write-Host ''
Write-Host '=============================================='
Write-Host '                END'
Write-Host '=============================================='
