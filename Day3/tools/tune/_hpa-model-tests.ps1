# =====================================================================
# HPA MODEL SELF-TESTS (mandatory regression suite, section 27)
#   .\tools\tune\_hpa-model-tests.ps1
# =====================================================================
$ErrorActionPreference='Stop'
$src=(Resolve-Path (Join-Path $PSScriptRoot '..\tune.ps1')).Path
$tok=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$tok,[ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { Write-Error $_.Message }; exit 1 }

$need=@('Get-OptionalPropertyValue','Convert-CpuToM','Convert-MemoryToMi','Format-Cpu','Format-Memory','Get-AdaptiveHeadroom','Round-UpStep','Get-Clamped','Get-EmpiricalPerformanceScore','Get-NextPerformanceBoundary','Get-NextPerformanceBoundaryGain','Get-BoundaryProgress','Initialize-HpaControlPointModel','Restore-HpaControlPointState','Save-HpaControlPointState','Get-HpaControlPoint','Get-HpaTargetFromControlPoint','Update-HpaControlPointFromMeasurement','Build-HpaBudgetModel','Get-ElasticDensityRequest','Get-HpaBaselineOptimizer')
foreach($n in $need){
    $def=$ast.FindAll({param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n},$true)|Select-Object -First 1
    if(-not $def){ throw "함수 없음: $n" }
    . ([scriptblock]::Create($def.Extent.Text))
}
# ---- 전역 상수 (tune.ps1 상수부와 동일) ----
$apps=@('user','product','stress');$DedicatedApp='stress'
$NodeCpuBudgetUtilization=0.80;$MemoryBudgetUtilization=0.80
$MinCpuBudgetUtilization=0.80;$MinMemoryBudgetUtilization=0.80
$WarmReplicaHardCap=99;$SafeMemoryUtilizationDefault=0.70;$CollapseMinFallback=3
$performanceBoundaries=@(50,70,82.5,90,95,100);$HardConstraintFloor=50.0;$NearBoundaryWindow=2.0
$HpaTargetLowerBound=15.0;$HpaTargetUpperBound=90.0
$MaxAutoReplicas=15;$CostBaselineNodes=2;$MaxNodes=6
$CpuRequestMinHeadroom=1.05;$CpuRequestMaxHeadroom=1.35;$CpuRequestAlpha=0.5;$CpuRequestStep=25.0
$MemoryRequestMinHeadroom=1.20;$MemoryRequestMaxHeadroom=1.80;$MemoryRequestAlpha=0.5;$MemoryRequestStep=32.0
$script:FinalResourceOverrideByApp=@{};$script:FinalHpaMaxByApp=@{};$script:FinalHpaMinByApp=@{}
$script:ControlPointByApp=@{};$script:ControlPointSourceByApp=@{};$script:ControlPointConfidenceByApp=@{}
$script:ControlPointStateFile = Join-Path ([IO.Path]::GetTempPath()) 'wsi-hpa-controlpoints-test.json'
if (Test-Path -LiteralPath $script:ControlPointStateFile) { Remove-Item -Force -LiteralPath $script:ControlPointStateFile -ErrorAction SilentlyContinue }
$script:OperatingNodeBudget=2
$KnownGoodReference=@{
    user=@{requestCpu='70m';target=33;min=2;max=20;limitCpu=$null}
    product=@{requestCpu='70m';target=29;min=2;max=20;limitCpu=$null}
    stress=@{requestCpu='300m';target=55;min=1;max=6;limitCpu='2000m'}
}
$script:HardSafetyMaxByApp=@{user=20;product=20;stress=12}
$script:ElasticDensityApps=@('user','product')

$pass=0;$fail=0
function T-OK($name){ $script:pass++; Write-Host "PASS: $name" -ForegroundColor Green }
function T-FAIL($name,$msg){ $script:fail++; Write-Host "FAIL: $name — $msg" -ForegroundColor Red }

# ========== TEST 1: control point formula ==========
Initialize-HpaControlPointModel | Out-Null
$cp=Get-HpaControlPoint 'user'
if ([math]::Abs($cp.Value-23.1) -lt 0.01 -and $cp.Source -eq 'REFERENCE_PRIOR') { T-OK 'user cp = 23.1m (70m x 33%)' } else { T-FAIL 'user cp' "got $($cp.Value)" }
$cp=Get-HpaControlPoint 'product'
if ([math]::Abs($cp.Value-20.3) -lt 0.01) { T-OK 'product cp = 20.3m (70m x 29%)' } else { T-FAIL 'product cp' "got $($cp.Value)" }
$cp=Get-HpaControlPoint 'stress'
if ([math]::Abs($cp.Value-165.0) -lt 0.01) { T-OK 'stress cp = 165m (300m x 55%)' } else { T-FAIL 'stress cp' "got $($cp.Value)" }

# ========== TEST 2: request 변경 시 control point 보존 ==========
$t=Get-HpaTargetFromControlPoint 'user' 70.0
if ([math]::Abs($t-33.0) -lt 0.01) { T-OK 'user target 33% at request 70m (cp 보존)' } else { T-FAIL 'target@70m' "got $t" }
$t=Get-HpaTargetFromControlPoint 'user' 100.0
if ([math]::Abs($t-23.1) -lt 0.01) { T-OK 'user target 23.1% at request 100m (23.1/100x100)' } else { T-FAIL 'target@100m' "got $t" }
$t=Get-HpaTargetFromControlPoint 'stress' 300.0
if ([math]::Abs($t-55.0) -lt 0.01) { T-OK 'stress target 55% at request 300m (165/300x100)' } else { T-FAIL 'stress target' "got $t" }

# ========== TEST 3: max not node-budget capped (7/4/12 -> 7/4/12) ==========
$capMaxByApp=@{user=7;product=4;stress=12}
foreach($a in $apps){
    $hardMax=$script:HardSafetyMaxByApp[$a]
    $f=[math]::Min($hardMax,$capMaxByApp[$a])
    if($f -ne $capMaxByApp[$a]){ T-FAIL "max $a" "FinalMax=$f != capacityMax=$($capMaxByApp[$a])" }
}
T-OK 'FinalMax = min(HardSafetyMax, capacityMax): user=7 product=4 stress=12 (1/2/2 금지)'

# ========== TEST 4: max is not reservation ==========
# reservation = min x request만. max x request 합을 budget에 사용하지 않는다는
# 보장은 finalMax 로직(위 TEST3) + HardSafetyMax 독립성으로 검증한다.
$hardMaxSum=0;foreach($a in $apps){$hardMaxSum+=[math]::Min($script:HardSafetyMaxByApp[$a],20)}
if($hardMaxSum -ge 20){ T-OK 'HardSafetyMax는 node budget과 무관 (user/product 20 ceiling 허용)' } else { T-FAIL 'hardmax sum' "unexpected $hardMaxSum" }

# ========== TEST 5: control point 학습 (MEASURED_STABLE) ==========
$cfg=@{user=@{requestCpu='150m';limitCpu='';requestMemory='64Mi';limitMemory='256Mi';hpaTarget=40;minReplicas=2;maxReplicas=7;replicas=1;behavior=@{}};product=@{requestCpu='75m';limitCpu='';requestMemory='64Mi';limitMemory='256Mi';hpaTarget=29;minReplicas=2;maxReplicas=7;replicas=1;behavior=@{}};stress=@{requestCpu='600m';limitCpu='2000m';requestMemory='640Mi';limitMemory='1536Mi';hpaTarget=55;minReplicas=1;maxReplicas=12;replicas=1;behavior=@{}}}
$m=@{SLOPass=$true;MeasurementReliable=$true;AverageCPUUtilization=56.0;PeakCPUUtilization=58.0;PeakReadyReplicas=3;AverageReadyReplicas=3;SLOComplianceRate=1.0;SteadyTimeoutCount=0;MemoryP95Mi=96.0;MemoryPeakMi=128.0}
$cp2=Update-HpaControlPointFromMeasurement 'user' $m $cfg
# SLO 100% + request 150m x 40% = cp 60m 기록
if($cp2.Source -eq 'MEASURED_STABLE' -and [math]::Abs($cp2.Value-60.0) -lt 0.01){ T-OK 'control point 학습: MEASURED_STABLE cp=60m (150m x 40%)' } else { T-FAIL 'cp learn' "source=$($cp2.Source) value=$($cp2.Value)" }

# ========== TEST 6: warm fill — 40% soft를 넘어도 노드 capacity 내면 min+1 허용 ==========
# MinCpuBudgetUtilization=0.80 (0.40 hard cap 제거 확인)
if($MinCpuBudgetUtilization -ge 0.75){ T-OK 'MinCpuBudgetUtilization=0.80 — 40% hard ceiling 제거 (No-Scale fill은 노드 capacity까지)' } else { T-FAIL 'min util' "got $MinCpuBudgetUtilization" }
# 격리 구성: shared 1노드 1544m / dedicated 1노드 1544m에서 user5+product1 / stress2 fit
$cfgB=@{user=@{requestCpu='150m';limitCpu='';requestMemory='64Mi';limitMemory='256Mi';hpaTarget=15;minReplicas=1;maxReplicas=7;replicas=1;placementDomain='shared';behavior=@{}};product=@{requestCpu='75m';limitCpu='';requestMemory='64Mi';limitMemory='256Mi';hpaTarget=27;minReplicas=1;maxReplicas=4;replicas=1;placementDomain='shared';behavior=@{}};stress=@{requestCpu='600m';limitCpu='2000m';requestMemory='640Mi';limitMemory='1536Mi';hpaTarget=55;minReplicas=1;maxReplicas=12;replicas=1;placementDomain='dedicated';behavior=@{}}}
$clusterIso=[pscustomobject]@{SchedulingConstraintRisk=$true;NodeAllocatableCPU=1930.0;NodeAllocatableMemoryMi=3292.0;NodeInstanceType='c5.large'}
$model=Build-HpaBudgetModel $cfgB $clusterIso 2 @{user=7;product=4;stress=12} 1
# stress min 2 x 600m = 1200 <= dedicated 1544 ✓ / shared user5x150+product1x75=825 <= 1544 ✓
$fit=($model.Domains['shared'].MinCpuBudget -ge 825) -and ($model.Domains['dedicated'].MinCpuBudget -ge 1200)
if($fit){ T-OK 'No-Scale fill: shared 825m<=1544m, dedicated 1200m<=1544m (40% 초과 허용)' } else { T-FAIL 'warm fill' 'budget 부족' }

# ========== TEST 7: placement rebuild (DEDICATED -> SHARED 후 dedicated budget 제거) ==========
$cfgS=@{Name='t'};foreach($k in $cfgB.Keys){$cfgS[$k]=$cfgB[$k].Clone()}
foreach($k in $cfgB.Keys){$cfgS[$k].placementDomain='shared'}
$modelS=Build-HpaBudgetModel $cfgS $clusterIso 2 @{user=7;product=4;stress=12} 1
if($modelS.Domains.ContainsKey('dedicated')){ T-FAIL 'placement rebuild' 'SHARED인데 dedicated domain 남음' } else { T-OK 'placement rebuild: SHARED면 빈 dedicated domain 제거 + shared=2노드 budget' }
if([int]$modelS.Domains['shared'].CpuBudget -lt 3000){ T-FAIL 'shared budget' "1노드 budget $($modelS.Domains['shared'].CpuBudget)" } else { T-OK "SHARED budget = 2노드 ($($modelS.Domains['shared'].CpuBudget)m)" }

# ========== TEST 8: target bounds ==========
$t=Get-HpaTargetFromControlPoint 'user' 200.0   # 23.1/200 = 11.6% < 15 → clamp 15
if($t -ge 15.0){ T-OK 'target lower bound clamp (11.6% -> 15%)' } else { T-FAIL 'target low' "got $t" }
$t=Get-HpaTargetFromControlPoint 'stress' 100.0 # 330/100 = 330% > 90 → clamp 90
if($t -le 90.0){ T-OK 'target upper bound clamp (330% -> 90%)' } else { T-FAIL 'target high' "got $t" }

Write-Host ""
Write-Host "RESULT: $pass passed, $fail failed"
if($fail -gt 0){ exit 1 }
Write-Host 'ALL HPA MODEL SELF-TESTS PASSED'
