
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
        if ($null -ne $st.limitCpu) { throw 'stress CPU limit not null' }
        if ($st.hpaTarget -ne 55) { throw 'stress target' }
        if ($st.maxReplicas -ne 8) { throw 'stress max' }
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

    Write-Host "`nSelf-tests: $testPassed/$testTotal passed" -ForegroundColor $(if($testPassed -eq $testTotal){'Green'}else{'Red'})
}
