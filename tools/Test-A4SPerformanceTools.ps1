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
    'Remove-Item', 'Move-Item', 'Rename-Item', 'Invoke-CimMethod', 'Invoke-WmiMethod'
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
    if (-not ($classMatch.Groups[1].Value -as [type])) {
        Add-Type -TypeDefinition $typeSources[0].Value
    }
}

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this static tool gate from 64-bit PowerShell.'
}
$snapshot = (& (Join-Path $PSScriptRoot 'Get-A4SPerformanceSnapshot.ps1')) | ConvertFrom-Json
if ($snapshot.schemaVersion -ne 1 -or -not $snapshot.explorer.pid -or
    @($snapshot.desktop.monitors).Count -lt 1 -or -not $snapshot.desktop.taskbar.hwnd) {
    throw 'The read-only observation smoke test returned an incomplete snapshot.'
}

Write-Host 'PASS: performance/stability tools parse, embedded native helpers compile, explicit automation gates are present, forbidden system mutations are absent, and the read-only observation smoke test is valid.'
