[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Namespace = 'app',
    [string]$Deployment = 'product',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$account = (aws sts get-caller-identity --query Account --output text).Trim()
if ($account -ne '586639730662') { throw "AWS account 확인 실패: $account" }

$envJson = (kubectl -n $Namespace get deployment $Deployment -o json | ConvertFrom-Json).spec.template.spec.containers[0].env
$bucket = ($envJson | Where-Object name -eq 'S3_BUCKET' | Select-Object -ExpandProperty value)
$region = ($envJson | Where-Object name -in @('S3_REGION','AWS_REGION') | Select-Object -First 1 -ExpandProperty value)
if (-not $bucket) { throw "${Deployment} Deployment에서 S3_BUCKET을 찾지 못했습니다." }
if (-not $region) { $region = 'ap-northeast-2' }

$objects = @(aws s3api list-objects-v2 --bucket $bucket --region $region --output json | ConvertFrom-Json).Contents
$imageObjects = @($objects | Where-Object {
    $_.Key -and $_.Key -notmatch '^(binary/|load_user\.dump$|scripts/)'
})

Write-Host "Bucket: $bucket"
if (-not $imageObjects.Count) { Write-Host '삭제할 이미지 객체가 없습니다.'; exit 0 }
$imageObjects | Select-Object Key,Size,LastModified | Format-Table -AutoSize

if (-not $Apply) {
    Write-Warning '미리보기만 수행했습니다. 삭제하려면 -Apply를 지정하세요.'
    exit 0
}

foreach ($object in $imageObjects) {
    if ($PSCmdlet.ShouldProcess("s3://$bucket/$($object.Key)",'Delete image object')) {
        aws s3api delete-object --bucket $bucket --key $object.Key --region $region | Out-Null
        Write-Host "삭제: $($object.Key)"
    }
}
Write-Host "이미지 객체 $($imageObjects.Count)개를 삭제했습니다."
