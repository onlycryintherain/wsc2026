[CmdletBinding()]
param(
    [string]$Cluster = 'wsi2026-cluster',
    [string]$Namespace = 'app',
    [string]$Region = 'ap-northeast-2',
    [string]$DbIdentifier = 'apdev-rds-instance',
    [string]$SecretName = 'apdev-rds-credentials',
    [string]$Database = 'dev',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# 1) DB 접속 정보 조회 (AWS CLI)
$dbHost = (aws rds describe-db-instances --db-instance-identifier $DbIdentifier --query 'DBInstances[0].Endpoint.Address' --output text --region $Region).Trim()
$secret = aws secretsmanager get-secret-value --secret-id $SecretName --query SecretString --output text --region $Region | ConvertFrom-Json
if (-not $dbHost -or $dbHost -eq 'None') { throw "DB host를 찾을 수 없습니다: $DbIdentifier" }
Write-Host "DB: $dbHost / $Database"

# 2) EKS 임시 mysql Pod로 SQL 실행
# 로컬 mysql client 없이도 EKS에서 mysql:8 이미지로 실행한다.
function Invoke-DbSql([string]$Sql) {
    $podName = "tmp-db-reset-$PID"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
    $args = @(
        'run', $podName, '--rm', '-i', '--restart=Never',
        '--image=mysql:8.0',
        '--command', '--', 'sh', '-c',
        "echo $encoded | base64 -d | mysql -h '$dbHost' -u '$($secret.username)' -p'$($secret.password)' '$Database'"
    )
    $output = & kubectl @args 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        throw "kubectl run 실패 (exit=$exit): $($output -join ' ')"
    }
    return ($output -join "`n")
}

# 3) 삭제 대상 확인
Write-Host "`n== 삭제 대상 (dump id 패턴 'dbdump%' 외) =="
$checkSql = "SELECT CONCAT('user   : ', COUNT(*)) FROM user WHERE id NOT LIKE 'dbdump%'; SELECT CONCAT('product: ', COUNT(*)) FROM product WHERE id NOT LIKE 'dbdump%';"
$result = Invoke-DbSql $checkSql
$result -split "`n" | Where-Object { $_ -match 'user|product' } | ForEach-Object { Write-Host "  $_" }

if ($WhatIf) {
    Write-Host "[WhatIf] 삭제 실행 안 함"
    return
}

# 4) 삭제 실행
Write-Host "`n== 삭제 실행 =="
$delSql = "DELETE FROM user WHERE id NOT LIKE 'dbdump%'; DELETE FROM product WHERE id NOT LIKE 'dbdump%';"
Invoke-DbSql $delSql | Out-Null
Write-Host "  삭제 완료"

# 5) 삭제 후 전체 카운트
Write-Host "`n== 삭제 후 전체 카운트 =="
$afterSql = "SELECT CONCAT('user   : ', COUNT(*)) FROM user; SELECT CONCAT('product: ', COUNT(*)) FROM product;"
$after = Invoke-DbSql $afterSql
$after -split "`n" | Where-Object { $_ -match 'user|product' } | ForEach-Object { Write-Host "  $_" }

Write-Host '완료'
