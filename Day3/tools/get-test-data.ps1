<#
.SYNOPSIS
  load_user.dump가 SQL/JSON/CSV/텍스트로 바뀌어도 첫 사용자 정보를 추출한다.
#>
$DumpPath = if ($env:LOAD_USER_DUMP) { $env:LOAD_USER_DUMP } else { Join-Path $PSScriptRoot '..\application\load_user.dump' }
if (-not (Test-Path -LiteralPath $DumpPath)) { $DumpPath = Join-Path $PSScriptRoot '..\application\load_user.dump' }
$raw = if (Test-Path -LiteralPath $DumpPath) { Get-Content -LiteralPath $DumpPath -Raw -Encoding UTF8 } else { '' }

$id = $null; $email = $null
# JSON/CSV/일반 텍스트에서 이메일을 먼저 찾는다.
$emailMatch = [regex]::Match($raw, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')
if ($emailMatch.Success) { $email = $emailMatch.Value }
# SQL SET 형식: INSERT ... SET id='...', username='...', email='...'
$idMatch = [regex]::Match($raw, "(?im)^\s*INSERT\s+INTO\s+[^\r\n]*user[^\r\n]*SET\s+id\s*=\s*'([^']+)")
if ($idMatch.Success) { $id = $idMatch.Groups[1].Value }
# JSON/CSV의 id 필드를 시도한다.
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

$script:TestUserId = $id
$script:TestUserEmail = $email
# Product는 user dump에 없으므로 과제 fixture ID를 별도로 지정한다.
$script:TestProductId = if ($env:CHECK_PRODUCT_ID) { $env:CHECK_PRODUCT_ID } else { 'dbdump500001' }
