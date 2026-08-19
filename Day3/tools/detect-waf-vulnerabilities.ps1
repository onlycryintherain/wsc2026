[CmdletBinding()]
param(
    [string]$LogGroup = 'aws-waf-logs-wsi2026-cluster',
    [int]$Minutes = 15,
    [string]$Region = 'us-east-1',
    [switch]$FailOnSuspicious
)

$ErrorActionPreference = 'Stop'
$start = [DateTimeOffset]::Now.AddMinutes(-$Minutes).ToUnixTimeMilliseconds()
$events = @(aws logs filter-log-events --log-group-name $LogGroup --start-time $start --region $Region --output json 2>$null | ConvertFrom-Json).events
if (-not $events) {
    Write-Host "최근 ${Minutes}분 WAF 로그가 없습니다: $LogGroup"
    exit 0
}

$pattern = '(?i)(union\s+select|select\s+.*from|<script|onerror|\.\./|%2e%2e|__proto__|\$ne|\$gt|169\.254\.169\.254|localhost|%00|\x00|[\x27%27]\s*(or|and)\s*[\x27\"]?\s*\d|\$\{|\{\{|\(\)\s*\{|%0d|%0a|shellshock|waf_canary)'
$allowedSuspicious = @()
$blocked = 0
foreach ($event in $events) {
    try { $log = $event.message | ConvertFrom-Json } catch { continue }
    $action = [string]$log.action
    if ($action -eq 'BLOCK') { $blocked++ }
    $request = $log.httpRequest
    $headerValues = @($request.headers | ForEach-Object { $_.value }) -join ' '
    $cookieValues = @($request.cookies | ForEach-Object { $_.value }) -join ' '
    $text = "{0} {1} {2}" -f ([string]$request.args), $headerValues, $cookieValues
    $isKnownApi = [string]$request.uri -match '^/v1/(user|product|stress)$|^/healthcheck$|^/images/'
    if ($action -eq 'ALLOW' -and $isKnownApi -and $text -match $pattern) {
        $allowedSuspicious += [pscustomobject]@{
            Timestamp = $event.timestamp
            ClientIp  = $request.clientIp
            Method    = $request.httpMethod
            Uri       = $request.uri
            Args      = $request.args
            Headers   = $headerValues
            Rule      = $log.terminatingRuleId
        }
    }
}

Write-Host "WAF 로그: $($events.Count)건 / 차단: $blocked건 / 의심 Allow: $($allowedSuspicious.Count)건"
if ($allowedSuspicious.Count) {
    Write-Host '⚠️ WAF를 통과한 의심 요청:' -ForegroundColor Red
    $allowedSuspicious | Format-Table -AutoSize
    Write-Host '이 요청은 자동으로 취약점이라고 확정하지 않습니다. 앱 로그와 응답 코드/지연시간을 대조하세요.' -ForegroundColor Yellow
    if ($FailOnSuspicious) { exit 2 }
} else {
    Write-Host '최근 로그에서 알려진 공격 패턴의 Allow 요청은 발견되지 않았습니다.' -ForegroundColor Green
}
