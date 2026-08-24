<#
.SYNOPSIS
    38점 기준 User/Product/Stress Kubernetes 구성을 재현한다.
.DESCRIPTION
    VPC CNI prefix delegation, Karpenter maxPods=110, Deployment/HPA 기준값과
    stress 전용 NodePool/taint/selector를 한 번에 적용하고 마지막에 검증한다.

    Managed NodeGroup의 maxPods는 기존 노드에서 동적으로 바뀌지 않는다.
    실제 Launch Template 갱신/노드 롤링은 -ApplyManagedNodeGroupLaunchTemplate를
    명시했을 때만 수행한다.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ClusterName = 'wsi2026-cluster',
    [string]$Region = 'ap-northeast-2',
    [string]$Namespace = 'app',
    [string]$ManagedNodeGroupName = "$ClusterName-ng",
    [switch]$SkipKubeconfig,
    [switch]$DryRun,
    [switch]$ApplyManagedNodeGroupLaunchTemplate,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
$StressNodePool = 'stress'
$StressTaintKey = 'wsi2026.io/stress'

function Invoke-Kubectl([string[]]$Arguments) {
    $out = @(& kubectl @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "kubectl 실패: kubectl $($Arguments -join ' ')`n$($out -join "`n")" }
    return $out
}

function Invoke-Mutation([string]$Description, [scriptblock]$Action) {
    if ($DryRun) { Write-Host "[DRY-RUN] $Description" -ForegroundColor Yellow; return }
    Write-Host $Description -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "변경 실패: $Description" }
}

function Get-KubeJson([string[]]$Arguments) {
    $raw = (Invoke-Kubectl $Arguments) -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "kubectl JSON 결과가 비어 있습니다: $($Arguments -join ' ')" }
    return $raw | ConvertFrom-Json
}

function Get-AwsJson([string[]]$Arguments) {
    $raw = @(& aws @Arguments --output json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "aws 실패: aws $($Arguments -join ' ')`n$($raw -join "`n")" }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Set-KubeEnv([string]$Name, [string]$Value) {
    Invoke-Mutation "aws-node env: $Name=$Value" {
        & kubectl -n kube-system set env daemonset/aws-node "$Name=$Value"
    }
}

function Patch-Json([string]$Kind, [string]$Name, [string]$Patch, [string]$Type = 'merge', [string]$Ns = '') {
    $args = @()
    if ($Ns) { $args += @('-n', $Ns) }
    $args += @('patch', $Kind, $Name, '--type=' + $Type, '-p', $Patch)
    Invoke-Mutation "patch $Kind/$Name" { Invoke-Kubectl $args | Out-Host }
}

function Ensure-ResourceConfig([string]$App, [string]$RequestCpu, [string]$RequestMemory, [string]$LimitMemory, [string]$LimitCpu = '') {
    $d = Get-KubeJson @('-n',$Namespace,'get','deployment',$App,'-o','json')
    $container = @($d.spec.template.spec.containers | Where-Object name -eq $App | Select-Object -First 1)
    if (-not $container) { throw "Deployment/$App 컨테이너를 찾지 못했습니다." }
    $hasCpuLimit = $null -ne $container.resources.limits -and $null -ne $container.resources.limits.cpu
    if ($App -in @('user','product') -and $hasCpuLimit) {
        $remove='[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]'
        Patch-Json 'deployment' $App $remove 'json' $Namespace
    }
    $limits = [ordered]@{ memory = $LimitMemory }
    if ($LimitCpu) { $limits.cpu = $LimitCpu }
    $resources = [ordered]@{
        requests = [ordered]@{ cpu = $RequestCpu; memory = $RequestMemory }
        limits = $limits
    }
    $containerPatch = [ordered]@{ name = $App; resources = $resources }
    $bodyObject = [ordered]@{ spec = [ordered]@{ template = [ordered]@{ spec = [ordered]@{ containers = @($containerPatch) } } } }
    $body = $bodyObject | ConvertTo-Json -Compress -Depth 12
    Patch-Json 'deployment' $App $body 'strategic' $Namespace
}

function Ensure-Hpa([string]$App, [int]$Target, [int]$Min, [int]$Max) {
    $body = @{spec=@{minReplicas=$Min;maxReplicas=$Max;metrics=@(@{type='Resource';resource=@{name='cpu';target=@{type='Utilization';averageUtilization=$Target}}})}} | ConvertTo-Json -Compress -Depth 12
    Patch-Json 'hpa' $App $body 'merge' $Namespace
}

function Ensure-StressNodePool {
    $default = Get-KubeJson @('get','nodepool','default','-o','json')
    $spec = $default.spec
    $spec = $default.spec
    if ($null -eq $spec.template.metadata) { $spec.template | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{}) -Force }
    $labels = [ordered]@{}
    if ($spec.template.metadata.labels) {
        foreach ($p in $spec.template.metadata.labels.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value }
    }
    $labels['workload-class'] = 'stress'
    $spec.template.metadata.labels = $labels
    if ($null -eq $spec.template.spec.PSObject.Properties['taints']) {
        $spec.template.spec | Add-Member -NotePropertyName taints -NotePropertyValue @() -Force
    }
    $spec.template.spec.taints = @([ordered]@{key=$StressTaintKey;value='true';effect='NoSchedule'})
    $body = [ordered]@{
        apiVersion = 'karpenter.sh/v1'
        kind = 'NodePool'
        metadata = [ordered]@{name=$StressNodePool}
        spec = $spec
    } | ConvertTo-Json -Compress -Depth 30
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "wsi-stress-nodepool-$PID.json"
    try {
        $body | Set-Content -LiteralPath $tmp -Encoding UTF8
        Invoke-Mutation 'stress NodePool 생성/갱신 (dedicated taint)' { & kubectl apply -f $tmp }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-StressIsolation {
    $d = Get-KubeJson @('-n',$Namespace,'get','deployment','stress','-o','json')
    $ops = [System.Collections.Generic.List[object]]::new()
    $selector = [ordered]@{'workload-class'='stress'}
    if ($null -eq $d.spec.template.spec.nodeSelector) {
        $ops.Add([ordered]@{op='add';path='/spec/template/spec/nodeSelector';value=$selector})
    } else {
        $ops.Add([ordered]@{op='replace';path='/spec/template/spec/nodeSelector';value=$selector})
    }
    $tolerations = @($d.spec.template.spec.tolerations)
    $hasStressTol = @($tolerations | Where-Object { $_.key -eq $StressTaintKey -and $_.effect -eq 'NoSchedule' }).Count -gt 0
    if (-not $hasStressTol) {
        $tol = [ordered]@{key=$StressTaintKey;operator='Equal';value='true';effect='NoSchedule'}
        if ($null -eq $d.spec.template.spec.tolerations) {
            $ops.Add([ordered]@{op='add';path='/spec/template/spec/tolerations';value=@($tol)})
        } else {
            $ops.Add([ordered]@{op='add';path='/spec/template/spec/tolerations/-';value=$tol})
        }
    }
    if ($ops.Count -gt 0) {
        $patch = @($ops) | ConvertTo-Json -Compress -Depth 12
        Patch-Json 'deployment' 'stress' $patch 'json' $Namespace
    }
}

function New-ManagedNodeUserData {
    $nodeConfig = @"
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary=""BOUNDARY""

--BOUNDARY
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      maxPods: 110
--BOUNDARY--
"@
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodeConfig))
}

function Ensure-ManagedNodeLaunchTemplate {
    $ng = Get-AwsJson @('eks','describe-nodegroup','--cluster-name',$ClusterName,'--nodegroup-name',$ManagedNodeGroupName)
    $lt = $ng.nodegroup.launchTemplate
    if ($null -eq $lt -or -not $lt.id) {
        throw "Managed NodeGroup에 Launch Template이 없습니다: $ManagedNodeGroupName"
    }
    $sourceVersion = if ($lt.version) { [string]$lt.version } else { '$Default' }
    $data = @{UserData=(New-ManagedNodeUserData)} | ConvertTo-Json -Compress
    if ($DryRun) {
        Write-Host "[DRY-RUN] MNG Launch Template $($lt.id) version=$sourceVersion -> maxPods=110 새 버전 생성/NodeGroup 롤링" -ForegroundColor Yellow
        return
    }
    $new = Get-AwsJson @('ec2','create-launch-template-version','--launch-template-id',$lt.id,'--source-version',$sourceVersion,'--version-description','wsi-maxpods-110','--launch-template-data',$data)
    $newVersion = [string]$new.LaunchTemplateVersion.VersionNumber
    Write-Host "MNG Launch Template 새 버전: $newVersion (maxPods=110)" -ForegroundColor Cyan
    & aws eks update-nodegroup-version --region $Region --cluster-name $ClusterName --nodegroup-name $ManagedNodeGroupName --launch-template "id=$($lt.id),version=$newVersion"
    if ($LASTEXITCODE -ne 0) { throw 'Managed NodeGroup Launch Template 갱신 실패' }
    Write-Host 'Managed NodeGroup 롤링 업데이트를 시작했습니다.' -ForegroundColor Yellow
}

function Show-Verification {
    Write-Host "`n========== 38점 구성 검증 ==========" -ForegroundColor Green
    $cni = Get-KubeJson @('-n','kube-system','get','daemonset','aws-node','-o','json')
    $env = @{}
    foreach ($e in @($cni.spec.template.spec.containers[0].env)) { $env[[string]$e.name] = [string]$e.value }
    Write-Host "CNI: ENABLE_PREFIX_DELEGATION=$($env.ENABLE_PREFIX_DELEGATION) WARM_PREFIX_TARGET=$($env.WARM_PREFIX_TARGET)"
    $nc = Get-KubeJson @('get','ec2nodeclass','default','-o','json')
    Write-Host "EC2NodeClass/default maxPods=$($nc.spec.kubelet.maxPods)"
    foreach ($app in @('user','product','stress')) {
        $d=Get-KubeJson @('-n',$Namespace,'get','deployment',$app,'-o','json')
        $c=@($d.spec.template.spec.containers | Where-Object name -eq $app | Select-Object -First 1)
        $r=$c.resources
        Write-Host ("{0}: request={1}/{2} limitCpu={3} limitMemory={4}" -f $app,$r.requests.cpu,$r.requests.memory,$r.limits.cpu,$r.limits.memory)
        $h=Get-KubeJson @('-n',$Namespace,'get','hpa',$app,'-o','json')
        Write-Host ("  HPA: target={0}% min={1} max={2}" -f $h.spec.metrics[0].resource.target.averageUtilization,$h.spec.minReplicas,$h.spec.maxReplicas)
    }
    $np=Get-KubeJson @('get','nodepool','stress','-o','json')
    $selector=Get-KubeJson @('-n',$Namespace,'get','deployment','stress','-o','json')
    Write-Host "stress NodePool taint=$($np.spec.template.spec.taints[0].key), deployment selector=$($selector.spec.template.spec.nodeSelector.'workload-class')"
    Write-Host '======================================' -ForegroundColor Green
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { throw 'kubectl를 찾을 수 없습니다.' }
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'aws CLI를 찾을 수 없습니다.' }
if (-not $SkipKubeconfig) {
    & aws eks update-kubeconfig --name $ClusterName --region $Region
    if ($LASTEXITCODE -ne 0) { throw 'kubeconfig 갱신 실패' }
}

Write-Host '38점 기준 구성 적용: stress 격리 유지' -ForegroundColor Green
Set-KubeEnv 'ENABLE_PREFIX_DELEGATION' 'true'
Set-KubeEnv 'WARM_PREFIX_TARGET' '1'
Patch-Json 'ec2nodeclass' 'default' '{"spec":{"kubelet":{"maxPods":110}}}' 'merge'
Ensure-ResourceConfig 'user' '70m' '64Mi' '256Mi'
Ensure-ResourceConfig 'product' '70m' '64Mi' '256Mi'
Ensure-ResourceConfig 'stress' '600m' '640Mi' '1536Mi' '2000m'
Ensure-Hpa 'user' 33 2 20
Ensure-Hpa 'product' 29 2 20
Ensure-Hpa 'stress' 55 1 6
Ensure-StressNodePool
Ensure-StressIsolation
if ($ApplyManagedNodeGroupLaunchTemplate) { Ensure-ManagedNodeLaunchTemplate }
if (-not $NoWait -and -not $DryRun) {
    foreach ($app in @('user','product','stress')) {
        $out=@(kubectl -n $Namespace rollout status "deployment/$app" '--timeout=180s' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "rollout 실패: $app`n$($out -join "`n")" }
    }
}
Show-Verification
