[CmdletBinding()]
param()

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
}
if ($performanceSource -match '\b(open|close)PresentedMilliseconds\b|\bcloseWithinOneFrame\b|\bwarmOpenDiskQuiet') {
    throw 'The performance tool contains an overclaimed presentation-frame or physical-disk evidence field.'
}

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this static tool gate from 64-bit PowerShell.'
}
$snapshot = (& (Join-Path $PSScriptRoot 'Get-A4SPerformanceSnapshot.ps1')) | ConvertFrom-Json
if ($snapshot.schemaVersion -ne 1 -or -not $snapshot.explorer.pid -or
    $snapshot.observerSessionId -ne $snapshot.explorer.sessionId -or
    @($snapshot.desktop.monitors).Count -lt 1 -or
    @($snapshot.desktop.monitors | Where-Object primary).Count -ne 1 -or
    @($snapshot.desktop.monitors | Where-Object { -not $_.dpiAvailable }).Count -ne 0 -or
    -not $snapshot.desktop.taskbar.hwnd) {
    throw 'The read-only observation smoke test returned an incomplete snapshot.'
}

Write-Host 'PASS: performance/stability tools parse, fresh native-helper copies compile with verified interop layouts, explicit automation gates and process ownership checks are present, the curated mutation denylist is clear, and the read-only observation smoke test is valid.'
