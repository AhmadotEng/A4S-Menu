[CmdletBinding()]
param([switch] $SkipObservationSmokeTest)

$ErrorActionPreference = 'Stop'

$toolNames = @(
    'Get-A4SPerformanceSnapshot.ps1',
    'Measure-A4SProductPerformance.ps1',
    'Test-A4SCurrentScenario.ps1'
)
$forbiddenCommands = @(
    'Stop-Process', 'Restart-Computer', 'Stop-Computer', 'Set-ItemProperty',
    'Remove-Item', 'Move-Item', 'Rename-Item', 'Invoke-CimMethod', 'Invoke-WmiMethod',
    'Start-Process', 'Stop-Service', 'Restart-Service', 'Set-Service', 'New-Service',
    'Register-ScheduledTask', 'Unregister-ScheduledTask', 'shutdown', 'logoff',
    'taskkill', 'rundll32'
)
$forbiddenNativeApis = @(
    'ChangeDisplaySettings', 'SetDisplayConfig', 'SetWindowsHookEx', 'SendInput',
    'CreateRemoteThread', 'WriteProcessMemory', 'TerminateProcess', 'ExitWindowsEx',
    'InitiateSystemShutdown', 'SetSuspendState'
)

$windowsPowerShellContractFiles = @(
    'Get-A4SPerformanceSnapshot.ps1',
    'Measure-A4SProductPerformance.ps1',
    'Test-A4SCurrentScenario.ps1',
    'Convert-A4SRuntimeTrace.ps1',
    'Capture-A4SRuntimeTrace.ps1',
    'A4SRuntimeTrace.Core.psm1'
)
foreach ($contractName in $windowsPowerShellContractFiles) {
    $contractSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot $contractName) -Raw
    if ($contractSource -match '\[Convert\]::ToHexString') {
        throw "$contractName uses Convert.ToHexString, which is unavailable in Windows PowerShell 5.1/.NET Framework."
    }
}

foreach ($name in $toolNames) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing performance/stability tool: $path"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) {
        throw "PowerShell parse failure in ${name}: $($parseErrors[0].Message)"
    }

    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    $unsafe = @($commands | Where-Object { $_ -in $forbiddenCommands } | Sort-Object -Unique)
    if ($unsafe.Count) {
        throw "$name contains a forbidden system-mutating command: $($unsafe -join ', ')"
    }

    if ($name -ne 'Get-A4SPerformanceSnapshot.ps1') {
        $source = Get-Content -LiteralPath $path -Raw
        if ($source -notmatch '\[switch\]\s*\$AllowMenuAutomation' -or
            ($source -notmatch 'if\s*\(-not\s+\$AllowMenuAutomation\)' -and
             $source -notmatch 'if\s*\(\$AllowMenuAutomation\)')) {
            throw "$name does not visibly gate menu automation behind -AllowMenuAutomation."
        }
    }

    $typeSources = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'public static class A4S[A-Za-z]+Native'
    }, $true))
    if ($typeSources.Count -ne 1) {
        throw "Expected exactly one embedded A4S native helper in $name; found $($typeSources.Count)."
    }
    $classMatch = [Regex]::Match($typeSources[0].Value, 'public static class (A4S[A-Za-z]+Native)')
    if (-not $classMatch.Success) { throw "Could not identify the embedded helper class in $name." }
    $originalClassName = $classMatch.Groups[1].Value
    $forbiddenNativeMatches = @($forbiddenNativeApis | Where-Object { $typeSources[0].Value -match "\b$([Regex]::Escape($_))\w*\b" })
    if ($forbiddenNativeMatches.Count) {
        throw "$name embeds a forbidden system-mutating native API: $($forbiddenNativeMatches -join ', ')"
    }

    # Always compile a uniquely named copy. Reusing a PowerShell process must
    # not let an already-loaded type hide a newly introduced C# compile error.
    $uniqueClassName = $originalClassName + 'StaticGate' + [Guid]::NewGuid().ToString('N')
    $compileSource = [Regex]::Replace($typeSources[0].Value, "\b$([Regex]::Escape($originalClassName))\b", $uniqueClassName)
    Add-Type -TypeDefinition $compileSource
    $compiledType = $uniqueClassName -as [type]
    if (-not $compiledType) { throw "Could not load uniquely compiled native helper for $name." }

    $bindingFlags = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Public
    $expectedStructSizes = [ordered]@{ RECT = 16; MONITORINFOEX = 104 }
    if ($name -ne 'Test-A4SCurrentScenario.ps1') { $expectedStructSizes.IO_COUNTERS = 48 }
    if ($name -eq 'Measure-A4SProductPerformance.ps1') { $expectedStructSizes.DEVMODE = 220 }
    foreach ($structName in $expectedStructSizes.Keys) {
        $structType = $compiledType.GetNestedType($structName, $bindingFlags)
        if (-not $structType) { throw "$name is missing expected interop structure $structName." }
        $structInstance = [Activator]::CreateInstance($structType)
        $actualSize = [Runtime.InteropServices.Marshal]::SizeOf($structInstance)
        if ($actualSize -ne $expectedStructSizes[$structName]) {
            throw "$name has an invalid $structName layout: expected $($expectedStructSizes[$structName]) bytes, found $actualSize."
        }
    }
}

$performanceSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Measure-A4SProductPerformance.ps1') -Raw
$scenarioSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-A4SCurrentScenario.ps1') -Raw
$snapshotSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Get-A4SPerformanceSnapshot.ps1') -Raw
$resolverPath = Join-Path $PSScriptRoot 'Resolve-A4SInstalledProductDirectory.ps1'
$resolverTokens = $null
$resolverErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($resolverPath, [ref]$resolverTokens, [ref]$resolverErrors)
if ($resolverErrors.Count) { throw "Resolve-A4SInstalledProductDirectory.ps1 has parse errors: $($resolverErrors -join '; ')" }
foreach ($sourceRecord in @(
    @{ name = 'Measure-A4SProductPerformance.ps1'; source = $performanceSource },
    @{ name = 'Test-A4SCurrentScenario.ps1'; source = $scenarioSource }
)) {
    if ($sourceRecord.source -notmatch 'VisibleMenuWindows\(uint ownerProcessId\)') {
        throw "$($sourceRecord.name) does not restrict visible-menu observations to an explicit owner process."
    }
    if ($sourceRecord.source -notmatch 'FlushDwmChecked') {
        throw "$($sourceRecord.name) does not validate DwmFlush failures."
    }
    if ($sourceRecord.source -notmatch 'Enter-A4SQualificationAutomationLock' -or
        $sourceRecord.source -notmatch 'Exit-A4SQualificationAutomationLock') {
        throw "$($sourceRecord.name) is not serialized against other menu qualification automation."
    }
}
if ($performanceSource -match '\b(open|close)PresentedMilliseconds\b|\bcloseWithinOneFrame\b|\bwarmOpenDiskQuiet') {
    throw 'The performance tool contains an overclaimed presentation-frame or physical-disk evidence field.'
}
if ($performanceSource -notmatch 'EnterPhysicalCapture' -or $performanceSource -notmatch 'LeavePhysicalCapture') {
    throw 'Pop-in screen captures are not held under a physical-coordinate DPI context.'
}
if ($performanceSource -notmatch 'Get-A4SLoadedImageIdentity' -or
    $performanceSource -notmatch 'baseline\.product\.selectedHost\.sha256' -or
    $performanceSource -notmatch 'Write-DurableJsonCreateNew' -or
    $performanceSource -notmatch 'Get-A4SProductDirectoryRegistration') {
    throw 'The performance tool is not strongly bound to resident images, the clean-baseline payload hashes, and durable no-overwrite evidence.'
}
if ($performanceSource -notmatch 'automationMenuExpectedVisible' -or
    $performanceSource -notmatch '\[IntPtr\]\$leftVisible\[0\] -eq \$automationMenuWindow') {
    throw 'The performance cleanup path can toggle a newly opened or non-test menu.'
}
if ($performanceSource -notmatch '\$EnforceTargets -and -not \$BaselinePath' -or
    $performanceSource -notmatch '\$EnforceTargets -and \$WarmSamples -lt 20' -or
    $performanceSource -notmatch '\$EnforceTargets -and \$IdleSeconds -lt 10') {
    throw 'Enforced performance qualification can run without a clean baseline, sufficient warm samples, or a meaningful idle interval.'
}
if ($scenarioSource -notmatch 'Get-A4SLoadedImageIdentity' -or
    $scenarioSource -notmatch 'Write-A4SMatrixAtomically' -or
    $scenarioSource -notmatch 'refused an ambiguous toggle' -or
    $scenarioSource -notmatch 'automationMenuExpectedVisible' -or
    $scenarioSource -notmatch '\[IntPtr\]\$leftVisible\[0\] -eq \$automationMenuWindow' -or
    $scenarioSource -match 'File\]::Replace\([^\r\n]*\$null') {
    throw 'The scenario tool lacks exact resident-image binding, atomic matrix persistence, or ambiguous-cleanup protection.'
}
$scenarioVisibleWait = $scenarioSource.IndexOf('$visibleWindows = @(Wait-MenuState -Visible $true', [StringComparison]::Ordinal)
if ($scenarioVisibleWait -lt 0) { throw 'Scenario automation has no authoritative visible-window wait.' }
$scenarioOwnershipRecord = $scenarioSource.IndexOf('$automationMenuWindow = $menuWindow', $scenarioVisibleWait, [StringComparison]::Ordinal)
$scenarioDwmFlush = $scenarioSource.IndexOf('[A4SScenarioNative]::FlushDwmChecked()', $scenarioVisibleWait, [StringComparison]::Ordinal)
if ($scenarioOwnershipRecord -lt 0 -or $scenarioDwmFlush -lt 0 -or
    $scenarioOwnershipRecord -gt $scenarioDwmFlush) {
    throw 'Scenario automation does not record exact HWND cleanup ownership immediately after the visibility wait and before DwmFlush.'
}
if ($snapshotSource -notmatch 'MaximumCleanExplorerAgeSeconds' -or
    $snapshotSource -notmatch 'cleanProductStateVerified' -or
    $performanceSource -notmatch 'baseline\.qualification\.cleanProductStateVerified' -or
    $performanceSource -notmatch 'maximumExplorerAgeSeconds -gt 120' -or
    $snapshotSource -notmatch 'The taskbar Explorer identity changed' -or
    $snapshotSource -notmatch 'ProcessLogonId' -or
    $snapshotSource -notmatch '\[string\]\s*\$ProductDirectory' -or
    $snapshotSource -notmatch 'Get-A4SProductDirectoryRegistration' -or
    $snapshotSource -notmatch 'Get-A4SHostProcessRecords') {
    throw 'The clean snapshot does not enforce freshness and stable Explorer/logon identity.'
}

$identityModulePath = Join-Path $PSScriptRoot 'A4SBinaryIdentity.psm1'
$identityTokens = $null
$identityErrors = $null
$identityAst = [Management.Automation.Language.Parser]::ParseFile($identityModulePath, [ref]$identityTokens, [ref]$identityErrors)
if ($identityErrors.Count) { throw "A4SBinaryIdentity.psm1 has parse errors: $($identityErrors -join '; ')" }
$identityText = Get-Content -LiteralPath $identityModulePath -Raw
if ($identityText -notmatch 'Get-A4SInstalledActiveSlot' -or
    $identityText -notmatch 'one direct child of the canonical versions directory' -or
    $identityText -notmatch 'ReparsePoint' -or
    $identityText -notmatch 'A4SMenu\.QualificationAutomation\.v1' -or
    (Get-Content -LiteralPath $resolverPath -Raw) -notmatch 'Get-A4SInstalledActiveSlot') {
    throw 'Installed ActiveSlot resolution is not canonical, reparse-aware, and shared with the qualification tools.'
}
$identitySources = @($identityAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'public static class A4SBinaryIdentityNative'
}, $true))
if ($identitySources.Count -ne 1) { throw 'Could not uniquely locate the shared binary-identity native helper.' }
$identityClassName = 'A4SBinaryIdentityNativeStaticGate' + [Guid]::NewGuid().ToString('N')
$identityCompileSource = [Regex]::Replace($identitySources[0].Value, '\bA4SBinaryIdentityNative\b', $identityClassName)
Add-Type -TypeDefinition $identityCompileSource
if (-not ($identityClassName -as [type])) { throw 'Could not compile the shared binary-identity native helper.' }

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this static tool gate from 64-bit PowerShell.'
}
if (-not $SkipObservationSmokeTest) {
    $snapshot = (& (Join-Path $PSScriptRoot 'Get-A4SPerformanceSnapshot.ps1')) | ConvertFrom-Json
    if ($snapshot.schemaVersion -ne 3 -or -not $snapshot.explorer.pid -or
        $snapshot.observerSessionId -ne $snapshot.explorer.sessionId -or
        $snapshot.observerLogonId -ne $snapshot.explorer.logonId -or
        @($snapshot.desktop.monitors).Count -lt 1 -or
        @($snapshot.desktop.monitors | Where-Object primary).Count -ne 1 -or
        @($snapshot.desktop.monitors | Where-Object { -not $_.dpiAvailable }).Count -ne 0 -or
        -not $snapshot.desktop.taskbar.hwnd) {
        throw 'The read-only observation smoke test returned an incomplete snapshot.'
    }
}

Write-Host "PASS: performance/stability tools parse under PowerShell $($PSVersionTable.PSVersion), avoid the Windows PowerShell 5.1-incompatible hex API, fresh native-helper copies compile with verified interop layouts, exact resident/payload binding and durable evidence contracts are present, and the curated mutation denylist is clear$(if($SkipObservationSmokeTest){' (observation smoke test intentionally skipped)'}else{'; the read-only observation smoke test is valid'})."
