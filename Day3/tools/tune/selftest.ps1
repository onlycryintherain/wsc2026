$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0

function Assert-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:pass++
        Write-Host "PASS: $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "FAIL: $Name — $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-TestConfig {
    param([int]$UserMin=1,[int]$ProductMin=1,[int]$StressMin=1)
    $config = @{Name='TEST'}
    foreach ($app in $script:Apps) {
        $config[$app] = @{
            containerName=$app
            requestCpuM=100
            requestMemoryMi=100
            limitCpuM=$null
            limitMemoryMi=200
            minReplicas=$(if($app-eq'user'){$UserMin}elseif($app-eq'product'){$ProductMin}else{$StressMin})
            maxReplicas=6
            hpaTarget=50
            behaviorJson=''
            placementJson='{"nodeSelector":null,"affinity":null,"topologySpreadConstraints":null,"tolerations":null}'
        }
    }
    $config.Fingerprint=Get-ConfigFingerprint $config
    return $config
}

function New-TestSample {
    param(
        [int]$Current=2,
        [int]$Desired=3,
        [int]$Max=6,
        [int]$Util=70,
        [int]$Target=50,
        [int]$Ready=2,
        [double]$CpuPerPod=20,
        [switch]$LowLoad
    )
    $apps=@{}
    foreach($app in $script:Apps){
        $apps[$app]=[pscustomobject]@{
            CurrentReplicas=$Current;DesiredReplicas=$Desired;MinReplicas=1;MaxReplicas=$Max
            CpuUtilization=$(if($LowLoad){20}else{$Util});CpuTarget=$Target;ReadyPods=$Ready;PendingPods=0
            RestartDelta=0;RestartTotal=0;CpuTotalM=$CpuPerPod*$Ready;CpuPerPodM=$CpuPerPod
            MemoryTotalMi=100;MemoryPerPodMi=50;MetricPods=[math]::Max(1,$Ready)
        }
    }
    return [pscustomobject]@{
        MetricsAvailable=$true;LoadKind='ramp';TargetRps=40;Apps=$apps;Pending=@()
        Node=[pscustomobject]@{ReadyCount=2;AverageAllocatableCpuM=1000;AverageAllocatableMemoryMi=1000;AllocatableCpuM=2000;AllocatableMemoryMi=2000;RequestedCpuM=800;RequestedMemoryMi=800;AppRequestedCpuM=400;AppRequestedMemoryMi=400}
        Scheduling=[pscustomobject]@{InsufficientCpu=$false;InsufficientMemory=$false;FailedScheduling=$false;CniError=$false;PdbConstraint=$false;NodePoolLimit=$false;Reasons=''}
    }
}

function New-PhaseEvidence([string]$App,[double]$Early,[double]$Late) {
    $phases=@()
    foreach($rate in @($Early,$Early,$Late,$Late)){
        $apps=[pscustomobject]@{}
        foreach($name in $script:Apps){
            $value=if($name-eq$App){$rate}else{100.0}
            $apps|Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{slo_success_rate=$value})
        }
        $phases += [pscustomobject]@{kind='ramp';target_rps=20;apps=$apps}
    }
    return [pscustomobject]@{phases=$phases}
}

function New-TestEvaluation {
    param($Config,[string]$FailApp='stress',[double]$AppRate=50,[double]$Early=50,[double]$Late=50,$Samples=$null)
    if($null-eq$Samples){$Samples=@((New-TestSample),(New-TestSample),(New-TestSample))}
    $runs=@()
    foreach($profile in $script:ProfileNames){
        $appResults=@{}
        foreach($app in $script:Apps){$appResults[$app]=[pscustomobject]@{SloSuccessRate=$(if($app-eq$FailApp){$AppRate}else{100.0})}}
        $runs += [pscustomobject]@{Profile=$profile;Apps=$appResults;Samples=@($Samples);Evidence=(New-PhaseEvidence $FailApp $Early $Late)}
    }
    $worst=@{}
    foreach($app in $script:Apps){$worst[$app]=$(if($app-eq$FailApp){$AppRate}else{100.0})}
    return [pscustomobject]@{
        Name='BEST';Valid=$true;Measured=$true;Config=$Config;ConfigFingerprint=(Get-ConfigFingerprint $Config)
        AppWorst=$worst;WorstAvailability=100.0;WorstPerformance=$AppRate;WorstDeficit=100-$AppRate
        WorstProfileResult=$AppRate;AverageResult=$AppRate;AverageNodes=2.0
        ProfileResults=@{Default=$AppRate;'Default-spike2'=$AppRate;Ramp=$AppRate};Runs=$runs
    }
}

$source = Get-Content -Raw (Join-Path $PSScriptRoot '..\tune.ps1')
$loadgenSource = Get-Content -Raw (Join-Path $PSScriptRoot 'loadgen.py')

Assert-Test '1 BASE before mutation invariant' {
    $main=$source.Substring($source.IndexOf('$runFailed = $true'))
    $snapshot=$main.IndexOf("Get-LiveConfig 'IMMUTABLE_BASE'")
    $lifecycle=$main.IndexOf('Invoke-TuningLifecycle $originalConfig')
    if($snapshot-lt0-or$lifecycle-lt$snapshot){throw 'BASE ordering missing'}
    $prefix=$main.Substring(0,$lifecycle)
    if($prefix-match 'Patch-App|Set-ConfigExact|kubectl.+patch'){throw 'mutation exists before BASE lifecycle'}
}

Assert-Test '2 hard deadline created once' {
    $matches=[regex]::Matches($source,'\$script:HardDeadline\s*=')
    if($matches.Count-ne1){throw "count=$($matches.Count)"}
    if($source-notmatch '\$script:StartTime\.AddMinutes\(20\)'){throw 'absolute 20-minute expression missing'}
}

Assert-Test '3 candidate cannot reset deadline' {
    if($source-match 'HardDeadline\s*=\s*\[?datetime\]?::UtcNow\.Add'){throw 'deadline reset found'}
    if($source-match 'HardDeadline\s*=\s*\(Get-Date\)'){throw 'deadline reset found'}
}

Assert-Test '4 NO_TIME_FOR_SAFE_CANDIDATE' {
    $saved=$script:HardDeadline
    try{$script:HardDeadline=[datetime]::UtcNow.AddSeconds(30);if(Test-CanStartCandidate){throw 'candidate incorrectly allowed'}}finally{$script:HardDeadline=$saved}
}

Assert-Test '5 Python 3.14 detection' {
    Initialize-Python
    if(-not$script:PythonExe){throw 'launcher missing'}
}

Assert-Test '6 loadgen bounded queue/concurrency' {
    foreach($token in 'HARD_MAX_WORKERS = 64','HARD_MAX_CONNECTIONS = 96','HARD_MAX_QUEUE = 256','asyncio.Queue(maxsize=queue_size)','TCPConnector'){if($loadgenSource-notmatch[regex]::Escape($token)){throw "missing $token"}}
}

Assert-Test '7 queue overflow contract' {
    foreach($token in 'asyncio.QueueFull','dropped_one','QUEUE_FULL','generator_limited'){if($loadgenSource-notmatch[regex]::Escape($token)){throw "missing $token"}}
}

Assert-Test '8 node evidence schema' {
    foreach($token in 'AllocatableCpuM','AllocatableMemoryMi','RequestedCpuM','RequestedMemoryMi','AppRequestedCpuM','AppRequestedMemoryMi','InsufficientCpu','CniError'){if($source-notmatch$token){throw "missing $token"}}
}

Assert-Test '9 HPA max candidate' {
    $config=New-TestConfig
    $samples=@((New-TestSample -Current 6 -Desired 6 -Max 6 -Util 100 -Target 50 -Ready 6),(New-TestSample -Current 6 -Desired 6 -Max 6 -Util 100 -Target 50 -Ready 6),(New-TestSample -Current 6 -Desired 6 -Max 6 -Util 100 -Target 50 -Ready 6))
    $eval=New-TestEvaluation $config stress 50 50 50 $samples
    $rec=Get-Recommendation $eval
    if($rec.Axis-ne'HPA_MAX'-or$rec.To-lt8-or$rec.To-gt8){throw ($rec|ConvertTo-Json -Compress)}
}

Assert-Test '10 HPA target candidate' {
    $config=New-TestConfig
    $samples=@((New-TestSample -Current 2 -Desired 3 -Max 6 -Util 80 -Target 50 -Ready 2),(New-TestSample -Current 2 -Desired 3 -Max 6 -Util 80 -Target 50 -Ready 2),(New-TestSample -Current 3 -Desired 4 -Max 6 -Util 80 -Target 50 -Ready 3))
    $eval=New-TestEvaluation $config stress 50 50 50 $samples
    $rec=Get-Recommendation $eval
    if($rec.Axis-ne'HPA_TARGET'-or$rec.To-ge50){throw ($rec|ConvertTo-Json -Compress)}
}

Assert-Test '11 min +1 candidate' {
    $config=New-TestConfig
    $samples=@((New-TestSample -Current 1 -Desired 2 -Max 6 -Util 40 -Target 50 -Ready 1),(New-TestSample -Current 2 -Desired 3 -Max 6 -Util 40 -Target 50 -Ready 2),(New-TestSample -Current 3 -Desired 3 -Max 6 -Util 40 -Target 50 -Ready 3))
    $eval=New-TestEvaluation $config stress 80 70 100 $samples
    $rec=Get-Recommendation $eval
    if($rec.Axis-ne'MIN_UP'-or$rec.To-ne2){throw ($rec|ConvertTo-Json -Compress)}
}

Assert-Test '12 min -1 candidate' {
    $config=New-TestConfig -UserMin 2
    $config.user.requestCpuM=600;$config.user.requestMemoryMi=600;$config.Fingerprint=Get-ConfigFingerprint $config
    $samples=@((New-TestSample -Current 2 -Desired 2 -Max 6 -Util 20 -Target 50 -Ready 2 -LowLoad),(New-TestSample -Current 2 -Desired 2 -Max 6 -Util 20 -Target 50 -Ready 2 -LowLoad),(New-TestSample -Current 2 -Desired 2 -Max 6 -Util 20 -Target 50 -Ready 2 -LowLoad))
    $eval=New-TestEvaluation $config stress 100 100 100 $samples
    $rec=Get-Recommendation $eval
    if($rec.Axis-ne'MIN_DOWN'-or$rec.App-ne'user'-or$rec.To-ne1){throw ($rec|ConvertTo-Json -Compress)}
}

Assert-Test '13 request control-point candidate' {
    $config=New-TestConfig;$config.user.hpaTarget=30;$config.Fingerprint=Get-ConfigFingerprint $config
    $samples=@((New-TestSample -Current 1 -Desired 1 -Max 6 -Util 20 -Target 30 -Ready 1 -CpuPerPod 10),(New-TestSample -Current 1 -Desired 1 -Max 6 -Util 20 -Target 30 -Ready 1 -CpuPerPod 10),(New-TestSample -Current 1 -Desired 1 -Max 6 -Util 20 -Target 30 -Ready 1 -CpuPerPod 10))
    $eval=New-TestEvaluation $config stress 100 100 100 $samples
    $rec=Get-Recommendation $eval
    $candidate=New-CandidateFromBest $eval $rec 'CANDIDATE'
    $old=100*30/100.0;$new=$candidate[$rec.App].requestCpuM*$candidate[$rec.App].hpaTarget/100.0
    if($rec.Axis-ne'REQUEST_CONTROL_POINT'-or[math]::Abs($old-$new)-gt1){throw ($rec|ConvertTo-Json -Compress)}
}

Assert-Test '14 ONE_DELTA_VIOLATION' {
    $config=New-TestConfig;$eval=New-TestEvaluation $config stress 50 50 50 @((New-TestSample),(New-TestSample),(New-TestSample))
    $rec=[pscustomobject]@{Axis='HPA_MAX';App='stress';To=8}
    $candidate=New-CandidateFromBest $eval $rec 'OK'
    $candidate.user.minReplicas++
    $threw=$false
    try{Assert-OneLogicalDelta $eval.Config $candidate $rec}catch{if($_.Exception.Message-eq'ONE_DELTA_VIOLATION'){$threw=$true}else{throw}}
    if(-not$threw){throw 'ONE_DELTA_VIOLATION was not thrown'}
}

Assert-Test '15 candidate always from BEST' {
    $config=New-TestConfig;$eval=New-TestEvaluation $config stress 50 50 50 @((New-TestSample),(New-TestSample),(New-TestSample))
    $candidate=New-CandidateFromBest $eval ([pscustomobject]@{Axis='HPA_MAX';App='stress';To=8}) 'C'
    if($candidate.ParentFingerprint-ne$eval.ConfigFingerprint){throw 'parent fingerprint mismatch'}
}

Assert-Test '16 REJECT exact rollback path' {
    if(-not $source.Contains("Set-ConfigExact `$bestConfig 'ROLLBACK'")){throw 'exact rollback call missing'}
}

Assert-Test '17 rollback live snapshot equality' {
    if(-not $source.Contains("if (`$Mode -eq 'ROLLBACK') { 'ROLLBACK_DRIFT' }")){throw 'rollback drift code missing'}
    if(-not $source.Contains('Assert-LiveConfig $Expected $errorCode')){throw 'live equality verification missing'}
}

Assert-Test '18 FINAL is measured BEST' {
    if(-not $source.Contains("Set-ConfigExact `$bestConfig 'BEST_APPLY'")){throw 'BEST apply missing'}
    if(-not $source.Contains("Invoke-Measurement `$bestConfig 'FINAL_FRESH'")){throw 'fresh measured final missing'}
    if($source-match 'FinalResourceOverride|hidden overlay'){throw 'hidden final overlay found'}
}

Assert-Test '18b NodePool limit becomes bounded request candidate' {
    $config=New-TestConfig
    $sample=New-TestSample
    $sample.Pending=@([pscustomobject]@{App='stress';Reason='Unschedulable'})
    $sample.Scheduling.NodePoolLimit=$true
    $sample.Scheduling.Reasons='all available instance types exceed limits for nodepool "stress"'
    $eval=New-TestEvaluation $config stress 0 0 0 @($sample,$sample,$sample)
    if($null-ne(Get-InfrastructureStop $eval)){throw 'NodePool limit incorrectly invalidated measurement'}
    $rec=Get-Recommendation $eval
    if($rec.Axis-ne'REQUEST_CONTROL_POINT'-or$rec.App-ne'stress'-or$rec.To-ne90-or$rec.NewTarget-ne56){throw ($rec|ConvertTo-Json -Compress)}
}

Assert-Test '18c k6-compatible Python ramp contract' {
    $spec=Get-ProfileSpec 'Ramp'
    $phases=@($spec.phases)
    if($script:ProfileNames.Count-ne1-or$script:ProfileNames[0]-ne'Ramp'){throw 'single ramp profile missing'}
    if((($phases.duration_sec|Measure-Object -Sum).Sum)-ne240){throw 'profile is not 240 seconds'}
    if(($phases.rps-join',')-ne'10,20,30,40,50,60,60,0,0'){throw "rates=$($phases.rps-join',')"}
    if(($phases.kind-join',')-ne'warmup,ramp,ramp,ramp,ramp,ramp,steady,cooldown,cooldown'){throw "kinds=$($phases.kind-join',')"}
    if(($phases.start_rps-join',')-ne'10,10,20,30,40,50,60,60,0'){throw "startRates=$($phases.start_rps-join',')"}
    if($spec.apps.stress.body.length-ne256){throw 'stress length differs from old k6 contract'}
}

Assert-Test '18d terminal CNI evidence still skips FINAL' {
    $config=New-TestConfig;$sample=New-TestSample
    $sample.Pending=@([pscustomobject]@{App='stress';Reason='ContainerCreating'})
    $sample.Scheduling.CniError=$true
    $eval=New-TestEvaluation $config stress 0 0 0 @($sample,$sample,$sample)
    if((Get-InfrastructureStop $eval).Type-ne'CNI_UNRESOLVED'){throw 'CNI did not invalidate measurement'}
    if($source.Contains('CniError=([bool]($allReasons')){throw 'historical CNI events still poison latest Pending'}
    if(-not$source.Contains("`$eventTargetsCurrentPending=`$currentPendingNames.Contains")){throw 'CNI event is not correlated to current Pending Pod'}
    if(-not$source.Contains('if ($skipFinalReason)')-or-not$source.Contains('FINAL_SKIPPED: $skipFinalReason')){throw 'terminal invalid measurement can still run FINAL'}
}

Assert-Test '18e resource rollout drains stale replicas before patch' {
    $start=$source.IndexOf('function Set-ConfigExact')
    $end=$source.IndexOf('function Test-CandidateBetter',$start)
    $block=$source.Substring($start,$end-$start)
    $hpa=$block.IndexOf('Patch-AppHpa')
    $drain=$block.IndexOf('Reset-AppToMinForResourceRollout')
    $resource=$block.IndexOf('Patch-AppResources')
    if($hpa-lt0-or$drain-lt$hpa-or$resource-lt$drain){throw 'unsafe HPA/drain/resource order'}
    if($source-notmatch 'wsi-measured-tune-\$PID-\$\(\[datetime\]::UtcNow'){throw 'run output directory is reused'}
    if(-not$source.Contains("if(`$Name -ne 'BASE'){Prepare-FreshMeasurement `$Config `$Name}")){throw 'candidate/final fresh-start prep missing'}
    if(-not$source.Contains("Prepare-FreshMeasurement `$bestConfig 'SHUTDOWN'")){throw 'normal shutdown replica cleanup missing'}
    if(-not$source.Contains("'delete','pod','-l','app=stress'")){throw 'stress CPU backlog replacement missing'}
}

Assert-Test '19 production contains no PDB mutation' {
    if($source-match "patch[^\r\n]*pdb|Repair-InvalidPdb|Set-CooldownPdb|PROFILE_COOLDOWN_PDB"){throw 'PDB mutation found'}
}

Assert-Test '20 production contains no placement or NodePool mutation' {
    if($source-match "patch[^\r\n]*(nodepool|karpenter)|Ensure-Topology|Restore-InstanceAware|Set-MeasuredWorker|Patch-Placement|Patch-NodePool"){throw 'placement/NodePool mutation found'}
}

Assert-Test '21 no shared-domain packing optimizer' {
    if($source-match 'Get-CostAwarePacking|REQUEST_PACKING_DOMAIN|shared-domain packing'){throw 'shared packing found'}
}

Assert-Test '22 worst-case runtime <= 20 minutes' {
    $seconds=Get-WorstCaseRuntimeSeconds
    if($seconds-ne1185-or$seconds-gt1200){throw "worst-case=$seconds expected=1185"}
}

Write-Host "`nSelf-tests: $pass/$($pass+$fail) passed" -ForegroundColor $(if($fail-eq0){'Green'}else{'Red'})
if($fail){throw "SELF_TEST_FAILED: $fail"}
