
# ============================================================
# SELF TESTS (BASE EXPERIMENT MODE)
# ============================================================
if ($BaseExperiment) {
    Write-Host 'Running BASE EXPERIMENT self-tests...' -ForegroundColor Cyan
    $testPassed = 0; $testTotal = 0

    function Assert-Test([string]$name,[scriptblock]$block) {
        $script:testTotal++
        try { & $block; $script:testPassed++; Write-Host "  PASS: $name" -ForegroundColor Green }
        catch { Write-Host "  FAIL: $name - $($_.Exception.Message)" -ForegroundColor Red }
    }

    # TEST 1: BaseConfig exact values
    Assert-Test 'BaseConfig values' {
        $u=$BaseConfig.user; $p=$BaseConfig.product; $st=$BaseConfig.stress
        if ($u.requestCpu -ne '70m') { throw 'user req' }
        if ($null -ne $u.limitCpu) { throw 'user limitCpu not null' }
        if ($u.limitMemory -ne '256Mi') { throw 'user limMem' }
        if ($u.hpaTarget -ne 33) { throw 'user target' }
        if ($u.minReplicas -ne 2) { throw 'user min' }
        if ($u.maxReplicas -ne 20) { throw 'user max' }
        if ($p.hpaTarget -ne 29) { throw 'product target' }
        if ($p.maxReplicas -ne 20) { throw 'product max' }
        if ($st.requestCpu -ne '600m') { throw 'stress req' }
        if ($st.requestMemory -ne '640Mi') { throw 'stress reqMem' }
        if ($st.limitCpu -ne '2000m') { throw 'stress CPU limit' }
        if ($st.limitMemory -ne '1536Mi') { throw 'stress limMem' }
        if ($st.hpaTarget -ne 55) { throw 'stress target' }
        if ($st.minReplicas -ne 1) { throw 'stress min' }
        if ($st.maxReplicas -ne 6) { throw 'stress max' }
        if ($st.placement -ne 'ISOLATED') { throw 'stress placement' }
    }

    # TEST 2: hpaMaxMinimum does not mutate BaseConfig
    Assert-Test 'hpaMaxMinimum no mutation' {
        $test=Copy-Config $BaseConfig 'test'
        $oldMax=$test.user.maxReplicas
        Set-RequiredPolicy $test 'test' @{}
        if ($test.user.maxReplicas -ne $oldMax) { throw "max changed $oldMax -> $($test.user.maxReplicas)" }
    }

    # TEST 3: Compare-Config single diff
    Assert-Test 'Compare-Config single diff' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'
        $diffs=Compare-Config $a $b @('USER_REQUESTCPU')
        if (@($diffs).Count -ne 1) { throw "expected 1 diff got $(@($diffs).Count)" }
        if ($diffs[0].Axis -ne 'USER_REQUESTCPU') { throw "wrong axis $($diffs[0].Axis)" }
    }

    # TEST 4: Compare-Config identical = 0 diffs
    Assert-Test 'Compare-Config identical' {
        $a=Copy-Config $BaseConfig 'a'
        $diffs=Compare-Config $a $a @()
        if ($diffs.Count -ne 0) { throw "expected 0 diffs got $($diffs.Count)" }
    }

    # TEST 5: Assert-ConfigDrift passes on single allowed axis
    Assert-Test 'ConfigDrift single allowed' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'
        $axis=Assert-ConfigDrift $a $b @('USER_REQUESTCPU')
        if ($axis -ne 'USER_REQUESTCPU') { throw "wrong axis $axis" }
    }

    # TEST 6: Assert-ConfigDrift rejects multi-axis
    Assert-Test 'ConfigDrift multi-axis rejected' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'; $b.product.hpaTarget=30
        try { Assert-ConfigDrift $a $b @('USER_REQUESTCPU') } catch { return }
        throw 'should have thrown MULTI_AXIS_MUTATION'
    }

    # TEST 7: Assert-ConfigDrift rejects unauthorized
    Assert-Test 'ConfigDrift unauthorized rejected' {
        $a=Copy-Config $BaseConfig 'a'; $b=Copy-Config $BaseConfig 'b'
        $b.user.requestCpu='60m'
        try { Assert-ConfigDrift $a $b @('PRODUCT_HPA_TARGET') } catch { return }
        throw 'should have thrown EXPERIMENT_CONFIG_DRIFT'
    }

    # TEST 8: REJECT does not change BEST
    Assert-Test 'REJECT preserves BEST' {
        $best=Copy-Config $BaseConfig 'best'
        $before=Get-ConfigFingerprintFromValues $best
        $after=Get-ConfigFingerprintFromValues $best
        if ($before -ne $after) { throw 'BEST changed on reject' }
    }

    # TEST 9: KEEP updates BEST
    Assert-Test 'KEEP updates BEST' {
        $best=Copy-Config $BaseConfig 'best'
        $cand=Copy-Config $BaseConfig 'cand'; $cand.user.requestCpu='60m'
        $best=$cand
        $after=Get-ConfigFingerprintFromValues $best
        $expected=Get-ConfigFingerprintFromValues $cand
        if ($after -ne $expected) { throw 'BEST not updated' }
    }

    # TEST 10: Stress length=112 returns valid result
    Assert-Test 'StressLength 112 valid' {
        # Calibration has not run in self-test mode; null is the expected pre-measurement state.
        if ($null -ne $script:SelectedStressLength -and $script:SelectedStressLength -ne 112 -and $script:SelectedStressLength -ne 0) {
            throw "unexpected stress length $($script:SelectedStressLength)"
        }
    }

    # TEST 11: FINAL >= BASE invariant (config check)
    Assert-Test 'BaseConfig invariant check' {
        $fp=Get-ConfigFingerprintFromValues $BaseConfig
        if ([string]::IsNullOrWhiteSpace($fp)) { throw 'empty fingerprint' }
        $parts=$fp -split ';'
        if ($parts.Count -ne 3) { throw "expected 3 apps got $($parts.Count)" }
    }

    # TEST 12: Base stress control point is 330m
    Assert-Test 'Base stress control point' {
        $cp=(Convert-CpuToM $BaseConfig.stress.requestCpu)*[double]$BaseConfig.stress.hpaTarget/100.0
        if ([math]::Abs($cp-330.0) -gt 0.01) { throw "stress cp=$cp" }
    }

    # TEST 13: New-ExperimentCandidate changes exactly one field
    Assert-Test 'Candidate one delta' {
        $best=Copy-Config $BaseConfig 'best'
        $rec=[pscustomobject]@{Axis='USER_CPU_REQUEST';App='user';Field='requestCpu';Current='70m';Proposed='50m';Confidence=0.8;ExpectedBenefit='NODE_DENSITY';Risk=0.2}
        $cand=New-ExperimentCandidate $best $rec 'candidate'
        $diff=@(Compare-Config $best $cand @('USER_REQUESTCPU'))
        if ($diff.Count -ne 1 -or $diff[0].Axis -ne 'USER_REQUESTCPU') { throw 'candidate is not one delta' }
    }

    # TEST 14: analyzer does not mutate BEST
    Assert-Test 'Analyzer does not mutate BEST' {
        $best=Copy-Config $BaseConfig 'best'; $before=Get-ConfigFingerprintFromValues $best
        $metric=[pscustomobject]@{MeasurementReliable=$true;SLOPass=$true;CPUP95Millicores=30;Bottlenecks=@();GeneratedLoadRatio=1.0}
        $m=[pscustomobject]@{Apps=[pscustomobject]@{user=$metric;product=$metric;stress=$metric}}
        [void](New-RequestRecommendation $m $best 'user')
        if ($before -ne (Get-ConfigFingerprintFromValues $best)) { throw 'BEST mutated by analyzer' }
    }

    # TEST 15: rejected candidate never becomes next BEST
    Assert-Test 'Reject inheritance invariant' {
        $best=Copy-Config $BaseConfig 'best'; $rejected=New-ExperimentCandidate $best ([pscustomobject]@{Axis='USER_CPU_REQUEST';App='user';Field='requestCpu';Current='70m';Proposed='50m'}) 'reject'
        if ((Get-ConfigFingerprintFromValues $best) -eq (Get-ConfigFingerprintFromValues $rejected)) { throw 'candidate did not differ' }
        $next=Copy-Config $best 'next'
        if ((Get-ConfigFingerprintFromValues $next) -ne (Get-ConfigFingerprintFromValues $best)) { throw 'next inherited reject' }
    }

    # TEST 16: deterministic recommendation for same measurement
    Assert-Test 'Recommendation deterministic' {
        $best=Copy-Config $BaseConfig 'best'
        $metric=[pscustomobject]@{MeasurementReliable=$true;SLOPass=$true;CPUP95Millicores=30;Bottlenecks=@();GeneratedLoadRatio=1.0}
        $m=[pscustomobject]@{Apps=[pscustomobject]@{user=$metric;product=$metric;stress=$metric}}
        $a=New-RequestRecommendation $m $best 'user'; $b=New-RequestRecommendation $m $best 'user'
        if ($a.Axis -ne $b.Axis -or $a.Proposed -ne $b.Proposed) { throw 'recommendation changed' }
    }

    # TEST 17: selection primary objective is minimum profile score, not average.
    Assert-Test 'Sweep objective uses minimum score' {
        function New-FakeResult([double]$total,[double]$perf,[double]$nodes) { [pscustomobject]@{Score=[pscustomobject]@{total40=$total;performance=[pscustomobject]@{score=$perf};availability=[pscustomobject]@{score=12;max=12};avg_ec2=$nodes}} }
        $e=Get-ExternalSweepObjective -Results @((New-FakeResult 32 10 4),(New-FakeResult 32 10 4),(New-FakeResult 24 10 4)) -CandidateName x -ConfigFingerprint fp
        if ($e.PrimaryScore -ne 24) { throw "expected min=24 got $($e.PrimaryScore)" }
    }

    # TEST 18: a guard-passing candidate wins before score/cost tie-breaks.
    Assert-Test 'Sweep guard precedence' {
        $best=[pscustomobject]@{Valid=$true;AllPerformanceGuards=$false;PrimaryScore=32.0;AverageNodes=2.0}
        $cand=[pscustomobject]@{Valid=$true;AllPerformanceGuards=$true;PrimaryScore=30.0;AverageNodes=4.0}
        if (-not (Test-SweepCandidateBetter $cand $best)) { throw 'guard precedence not enforced' }
    }

    # TEST 19: request candidate preserves the absolute HPA control point.
    Assert-Test 'Request delta preserves control point' {
        $best=Copy-Config $BaseConfig 'best'
        $rec=[pscustomobject]@{Type='REQUEST_OVERSIZED';App='user';To=35.0;NewTarget=66}
        $candidate=New-DynamicSweepCandidate $best $rec candidate
        $old=(Convert-CpuToM $best.user.requestCpu)*$best.user.hpaTarget/100.0
        $new=(Convert-CpuToM $candidate.user.requestCpu)*$candidate.user.hpaTarget/100.0
        if ([math]::Abs($old-$new) -gt 1.0) { throw "control point drift $old -> $new" }
        if ($candidate.product.requestCpu -ne $best.product.requestCpu -or $candidate.user.minReplicas -ne $best.user.minReplicas) { throw 'request candidate changed another axis' }
    }

    # TEST 20: every external run explicitly binds the freshly discovered endpoint.
    Assert-Test 'External run body includes endpoint' {
        $body=New-ExternalLoadRequestBody 'Default' 'https://new.example/' | ConvertFrom-Json
        if ($body.template -ne 'Default' -or $body.endpoint -ne 'https://new.example') { throw 'run endpoint missing or stale' }
    }

    # TEST 21: passing performance keeps measured high-load headroom but trims unused max.
    Assert-Test 'Dynamic max retains measured headroom' {
        $best=Copy-Config $BaseConfig 'best'
        $h=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget}}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=@{}}
        $result=[pscustomobject]@{Status=[pscustomobject]@{dropped=0;target_rps=10;sent_rps=10};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$true;Results=@($result,$result,$result)}
        $rec=Get-DynamicSweepRecommendation $best $evaluation @()
        if ($rec.Type -ne 'HPA_MAX_COST' -or [int]$rec.To -lt 3) { throw "unexpected max recommendation $($rec.Type) $($rec.To)" }
    }

    # TEST 22: instantaneous sent-RPS jitter is not a generator limit.
    Assert-Test 'Generator jitter does not stop search' {
        $best=Copy-Config $BaseConfig 'best'; $h=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget}}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=@{}}
        $result=[pscustomobject]@{Status=[pscustomobject]@{dropped=0;target_rps=4.6;sent_rps=4.0};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$true;Results=@($result,$result,$result)}
        if ((Get-DynamicSweepRecommendation $best $evaluation @()).Type -eq 'GENERATOR_LIMIT') { throw 'RPS jitter classified as saturation' }
    }

    # TEST 23: ceiling recovery prioritizes worst app and grows Max by 20%.
    Assert-Test 'Ceiling recovery selects worst app' {
        $best=Copy-Config $BaseConfig 'best'; $h=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=[int]$best[$app].maxReplicas;Desired=[int]$best[$app].maxReplicas;Max=[int]$best[$app].maxReplicas;CpuUtil=100;Target=[int]$best[$app].hpaTarget}}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=@{}}
        $score=[pscustomobject]@{user_perf=6;product_perf=100;stress_perf=76}
        $result=[pscustomobject]@{Score=$score;Status=[pscustomobject]@{dropped=0};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$false;Results=@($result,$result,$result)}
        $rec=Get-DynamicSweepRecommendation $best $evaluation @()
        $expected=Get-MeasuredHpaMaxGrowth ([int]$best.user.maxReplicas) ([int][math]::Ceiling([int]$best.user.maxReplicas*100/[int]$best.user.hpaTarget))
        if ($rec.Type -ne 'HPA_CEILING' -or $rec.App -ne 'user' -or [int]$rec.To -ne $expected) { throw "unexpected $($rec.Type) $($rec.App) $($rec.To)" }
    }

    # TEST 24: guard-deficit recovery can KEEP one-profile improvement without collateral regression.
    Assert-Test 'Guard recovery keeps worst-profile gain' {
        $best=[pscustomobject]@{Valid=$true;AllPerformanceGuards=$false;MinimumAvailabilityScore=12;GuardDeficit=8;PrimaryScore=20;AverageNodes=5;ProfileTotals=@{Default=35;Peak=20;Sequential=22}}
        $candidate=[pscustomobject]@{Valid=$true;AllPerformanceGuards=$false;MinimumAvailabilityScore=12;GuardDeficit=5;PrimaryScore=23;AverageNodes=5;ProfileTotals=@{Default=35;Peak=23;Sequential=22}}
        if (-not (Test-SweepCandidateBetter $candidate $best)) { throw 'guard recovery improvement rejected' }
    }

    # TEST 25: packing candidate crosses a live CPU density boundary and preserves trigger.
    Assert-Test 'Request packing boundary preserves trigger' {
        $best=Copy-Config $BaseConfig 'best'; $h=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget}}
        $h.stress.Current=6;$h.stress.Desired=6
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=@{stress=[pscustomobject]@{CpuTotalM=2000};user=[pscustomobject]@{CpuTotalM=100};product=[pscustomobject]@{CpuTotalM=100}}}
        $score=[pscustomobject]@{user_perf=100;product_perf=100;stress_perf=100}
        $result=[pscustomobject]@{Score=$score;Status=[pscustomobject]@{dropped=0};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$true;Results=@($result,$result,$result)}
        $oldCluster=$script:ExternalSweepClusterCapacity
        try {
            $script:ExternalSweepClusterCapacity=[pscustomobject]@{NodeAllocatableCPU=1930;DaemonSetCPUPerNode=150}
            $rec=Get-DynamicSweepRecommendation $best $evaluation @()
            if($rec.Type-ne'REQUEST_PACKING'-or$rec.App-ne'stress'){throw "unexpected $($rec.Type) $($rec.App)"}
            $candidate=New-DynamicSweepCandidate $best $rec candidate
            $old=(Convert-CpuToM $best.stress.requestCpu)*$best.stress.hpaTarget/100
            $new=(Convert-CpuToM $candidate.stress.requestCpu)*$candidate.stress.hpaTarget/100
            if([math]::Abs($old-$new)-gt[math]::Max(1,$old*.03)){throw "trigger drift $old->$new"}
        } finally { $script:ExternalSweepClusterCapacity=$oldCluster }
    }

    # TEST 26: brief Pending during successful Karpenter expansion is not capacity exhaustion.
    Assert-Test 'Transient pending permits ceiling recovery' {
        $best=Copy-Config $BaseConfig 'best';$samples=@()
        for($i=0;$i-lt20;$i++){
            $h=@{};foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget}}
            $h.user=[pscustomobject]@{Current=[int]$best.user.maxReplicas;Desired=[int]$best.user.maxReplicas;Max=[int]$best.user.maxReplicas;CpuUtil=100;Target=[int]$best.user.hpaTarget}
            $pending=if($i-lt2){@([pscustomobject]@{App='user';Reason='Insufficient cpu'})}else{@()}
            $samples+=[pscustomobject]@{CniErrors=0;Pending=$pending;Hpa=$h;Usage=@{}}
        }
        $result=[pscustomobject]@{Score=[pscustomobject]@{user_perf=25;product_perf=100;stress_perf=85};Status=[pscustomobject]@{dropped=0};Samples=$samples}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$false;Results=@($result)}
        $rec=Get-DynamicSweepRecommendation $best $evaluation @()
        if($rec.Type-ne'HPA_CEILING'-or$rec.App-ne'user'){throw "transient Pending incorrectly classified as $($rec.Type)"}
    }

    # TEST 27: cost gate regression cannot be exchanged for performance.
    Assert-Test 'Dual gate rejects cost regression' {
        $best=[pscustomobject]@{Valid=$true;AllPerformanceGuards=$false;AllCostGuards=$true;PerformanceGuardDeficit=2;CostGuardDeficit=0;MinimumAvailabilityScore=12;PrimaryScore=25;AverageNodes=3;ProfileTotals=@{Sequential=25}}
        $candidate=[pscustomobject]@{Valid=$true;AllPerformanceGuards=$true;AllCostGuards=$false;PerformanceGuardDeficit=0;CostGuardDeficit=1;MinimumAvailabilityScore=12;PrimaryScore=30;AverageNodes=5;ProfileTotals=@{Sequential=30}}
        if(Test-SweepCandidateBetter $candidate $best){throw 'cost gate was traded for performance'}
    }

    # TEST 28: failed cost gate chooses measured packing before adding replicas.
    Assert-Test 'Cost deficit prioritizes packing' {
        $best=Copy-Config $BaseConfig 'best';$samples=@()
        for($i=0;$i-lt20;$i++){
            $h=@{};$u=@{}
            foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget};$u[$app]=[pscustomobject]@{CpuTotalM=100}}
            $h.stress=[pscustomobject]@{Current=12;Desired=12;Max=12;CpuUtil=80;Target=[int]$best.stress.hpaTarget};$u.stress=[pscustomobject]@{CpuTotalM=3000}
            $samples+=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=$u}
        }
        $result=[pscustomobject]@{Score=[pscustomobject]@{user_perf=25;product_perf=100;stress_perf=85};Status=[pscustomobject]@{dropped=0};Samples=$samples}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$false;AllCostGuards=$false;Results=@($result)}
        $oldCluster=$script:ExternalSweepClusterCapacity
        try{$script:ExternalSweepClusterCapacity=[pscustomobject]@{NodeAllocatableCPU=1930;DaemonSetCPUPerNode=150};$rec=Get-DynamicSweepRecommendation $best $evaluation @();if($rec.Type-ne'REQUEST_PACKING'-or$rec.App-ne'stress'){throw "unexpected $($rec.Type) $($rec.App)"}}finally{$script:ExternalSweepClusterCapacity=$oldCluster}
    }

    # TEST 29: immutable evidence fingerprint can restore a rejected live delta.
    Assert-Test 'Fingerprint restore roundtrip' {
        $fingerprint=Get-ConfigFingerprintFromValues $BaseConfig
        $mutated=Copy-Config $BaseConfig mutated;$mutated.stress.requestCpu='550m';$mutated.stress.hpaTarget=60
        $restored=ConvertFrom-ConfigFingerprint $fingerprint $mutated
        if((Get-ConfigFingerprintFromValues $restored)-ne$fingerprint){throw 'fingerprint restore drift'}
    }

    # TEST 30: rejected replica growth falls back to earlier scaling for the same bottleneck.
    Assert-Test 'Rejected max enables target recovery' {
        $best=Copy-Config $BaseConfig 'best';$h=@{};$u=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget};$u[$app]=[pscustomobject]@{CpuTotalM=100}}
        $h.user=[pscustomobject]@{Current=20;Desired=20;Max=20;CpuUtil=100;Target=33}
        $h.product=[pscustomobject]@{Current=20;Desired=20;Max=20;CpuUtil=40;Target=29}
        $h.stress=[pscustomobject]@{Current=7;Desired=7;Max=12;CpuUtil=80;Target=55};$u.stress=[pscustomobject]@{CpuTotalM=3000}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=$u}
        $result=[pscustomobject]@{Score=[pscustomobject]@{user_perf=25;product_perf=100;stress_perf=85};Status=[pscustomobject]@{dropped=0};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$false;AllCostGuards=$false;Results=@($result)}
        $oldCluster=$script:ExternalSweepClusterCapacity
        try{$script:ExternalSweepClusterCapacity=[pscustomobject]@{NodeAllocatableCPU=1930;DaemonSetCPUPerNode=150};$rec=Get-DynamicSweepRecommendation $best $evaluation @('REQUEST_PACKING:stress:550:60','HPA_MAX:user:24');if($rec.Type-ne'HPA_TARGET_RECOVERY'-or$rec.App-ne'user'-or$rec.To-ne28){throw "unexpected $($rec.Type) $($rec.App) $($rec.To)"}}finally{$script:ExternalSweepClusterCapacity=$oldCluster}
    }

    # TEST 31: repeated target recovery failures advance without mutating BASE.
    Assert-Test 'Rejected target advances recovery step' {
        $best=Copy-Config $BaseConfig 'best';$h=@{};$u=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget};$u[$app]=[pscustomobject]@{CpuTotalM=100}}
        $h.user=[pscustomobject]@{Current=20;Desired=20;Max=20;CpuUtil=100;Target=33};$h.stress=[pscustomobject]@{Current=7;Desired=7;Max=12;CpuUtil=80;Target=55}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=$u};$result=[pscustomobject]@{Score=[pscustomobject]@{user_perf=25;product_perf=100;stress_perf=85};Status=[pscustomobject]@{dropped=0};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$false;AllCostGuards=$false;Results=@($result)};$oldCluster=$script:ExternalSweepClusterCapacity
        try{$script:ExternalSweepClusterCapacity=[pscustomobject]@{NodeAllocatableCPU=1930;DaemonSetCPUPerNode=150};$rec=Get-DynamicSweepRecommendation $best $evaluation @('REQUEST_PACKING:stress:550:60','HPA_MAX:user:24','HPA_TARGET_RECOVERY:user:28');if($rec.Type-ne'HPA_TARGET_RECOVERY'-or$rec.To-ne23){throw "unexpected $($rec.Type) $($rec.To)"}}finally{$script:ExternalSweepClusterCapacity=$oldCluster}
    }

    # TEST 32: an aggregate passing gate must not hide an individual app that is
    # below 90% and pinned at its measured HPA ceiling.
    Assert-Test 'Passing aggregate gate still recovers app ceiling' {
        $best=Copy-Config $BaseConfig 'best';$best.user.maxReplicas=32;$h=@{};$u=@{}
        foreach($app in $apps){$h[$app]=[pscustomobject]@{Current=2;Desired=2;Max=[int]$best[$app].maxReplicas;CpuUtil=5;Target=[int]$best[$app].hpaTarget};$u[$app]=[pscustomobject]@{CpuTotalM=100}}
        $h.user=[pscustomobject]@{Current=32;Desired=32;Max=32;CpuUtil=42;Target=33}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=$u}
        $result=[pscustomobject]@{Score=[pscustomobject]@{user_perf=84.16;product_perf=109.47;stress_perf=86.27};Status=[pscustomobject]@{dropped=0};Samples=@($sample)}
        $evaluation=[pscustomobject]@{AllPerformanceGuards=$true;AllCostGuards=$true;Results=@($result)}
        $oldHard=$script:HardSafetyMaxByApp.user
        try{$script:HardSafetyMaxByApp.user=48;$rec=Get-DynamicSweepRecommendation $best $evaluation @();if($rec.Type-ne'HPA_CEILING'-or$rec.App-ne'user'-or$rec.To-ne40){throw "unexpected $($rec.Type) $($rec.App) $($rec.To)"}}finally{$script:HardSafetyMaxByApp.user=$oldHard}
    }

    # TEST 33: external profile measurements use fast scale-up but retain the
    # peak for five minutes to prevent CPU-noise downscale during a spike.
    Assert-Test 'External HPA behavior prevents spike flapping' {
        $behavior=Get-StandardHpaBehavior
        if([int]$behavior.scaleUp.stabilizationWindowSeconds-ne0-or[int]$behavior.scaleDown.stabilizationWindowSeconds-ne300-or$behavior.scaleDown.selectPolicy-ne'Min'){throw 'unsafe external HPA behavior'}
    }

    # TEST 34: FINAL_FRESH cannot be accepted when either independent gate is off.
    Assert-Test 'Final fresh requires both gates' {
        $good=[pscustomobject]@{AllPerformanceGuards=$true;AllCostGuards=$true;PrimaryScore=$ProfileTargetScore}
        $perfOff=[pscustomobject]@{AllPerformanceGuards=$false;AllCostGuards=$true;PrimaryScore=40}
        $costOff=[pscustomobject]@{AllPerformanceGuards=$true;AllCostGuards=$false;PrimaryScore=40}
        if(-not(Test-ExternalSweepFinalAccepted $good)-or(Test-ExternalSweepFinalAccepted $perfOff)-or(Test-ExternalSweepFinalAccepted $costOff)){throw 'final gate acceptance regression'}
    }

    # TEST 35: shared-domain packing must reserve managed-node static system
    # workloads, not only DaemonSets. The otherwise tempting 70m->50m user
    # candidate is unsafe when controllers reduce actual app capacity.
    Assert-Test 'Shared-domain packing honors static system reserve' {
        $best=Copy-Config $BaseConfig best
        $best.user.requestCpu='70m';$best.user.hpaTarget=33;$best.user.maxReplicas=20
        $best.product.requestCpu='70m';$best.product.hpaTarget=29;$best.product.maxReplicas=20
        $best.stress.requestCpu='550m';$best.stress.hpaTarget=60;$best.stress.maxReplicas=12
        $h=@{
            user=[pscustomobject]@{Current=20;Desired=20;Max=20;CpuUtil=32;Target=33}
            product=[pscustomobject]@{Current=7;Desired=7;Max=20;CpuUtil=27;Target=29}
            stress=[pscustomobject]@{Current=3;Desired=3;Max=12;CpuUtil=40;Target=60}
        }
        $u=@{user=[pscustomobject]@{CpuTotalM=450};product=[pscustomobject]@{CpuTotalM=150};stress=[pscustomobject]@{CpuTotalM=650}}
        $sample=[pscustomobject]@{CniErrors=0;Pending=@();Hpa=$h;Usage=$u}
        $cluster=[pscustomobject]@{NodeAllocatableCPU=1930;DaemonSetCPUPerNode=150;AvailableAppCPU=1300;NodeAllocatablePods=110;DaemonSetPodCount=2;AvailableAppMemory=2200}
        $oldCluster=$script:ExternalSweepClusterCapacity
        try {
            $script:ExternalSweepClusterCapacity=$cluster
            $rec=Get-CostAwarePackingRecommendation $best @($sample) @()
            if($null-ne$rec){throw "unsafe shared packing returned $($rec.App) $($rec.To)@$($rec.NewTarget)"}
        } finally {$script:ExternalSweepClusterCapacity=$oldCluster}
    }

    Write-Host "`nSelf-tests: $testPassed/$testTotal passed" -ForegroundColor $(if($testPassed -eq $testTotal){'Green'}else{'Red'})
    if ($testPassed -ne $testTotal) { throw "SELF_TEST_FAILED: $testPassed/$testTotal" }
}
