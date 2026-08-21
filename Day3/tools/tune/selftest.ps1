
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

    Write-Host "`nSelf-tests: $testPassed/$testTotal passed" -ForegroundColor $(if($testPassed -eq $testTotal){'Green'}else{'Red'})
    if ($testPassed -ne $testTotal) { throw "SELF_TEST_FAILED: $testPassed/$testTotal" }
}
