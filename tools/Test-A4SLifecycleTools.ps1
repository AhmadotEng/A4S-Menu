[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-A4SLifecycleTool {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "A4S lifecycle-tool gate failed: $Message" }
}

$scriptPath = Join-Path $PSScriptRoot 'Test-A4SProductLifecycle.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-A4SLifecycleTool ($parseErrors.Count -eq 0) "PowerShell parse errors: $($parseErrors -join '; ')"

$gateIndex = $source.IndexOf('if (-not $AllowExplorerInjection)', [StringComparison]::Ordinal)
$interopIndex = $source.IndexOf("if (-not ('A4SProductLifecycleNative' -as [type]))", [StringComparison]::Ordinal)
Assert-A4SLifecycleTool ($gateIndex -ge 0 -and $interopIndex -gt $gateIndex) `
    'the explicit injection-consent gate does not precede native helper loading'
Assert-A4SLifecycleTool ($source -match 'GetVisibleTopLevelWindows\(string expectedClassName, uint expectedProcessId\)') `
    'visible menu enumeration has no required owner-process boundary'
Assert-A4SLifecycleTool ($source -match 'ownerProcessId == expectedProcessId') `
    'visible menu enumeration does not enforce the owner-process boundary'
Assert-A4SLifecycleTool ($source -notmatch 'GetVisibleTopLevelWindows\(\s*''A4SMenu\.CMenuContainer''\s*\)') `
    'a call can still enumerate A4S menu windows without a validated Explorer PID'
Assert-A4SLifecycleTool ($source -match '\.Count -eq 1') `
    'toggle-open can pass without exactly one Explorer-owned menu window'

$interopSources = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'public static class A4SProductLifecycleNative'
}, $true))
Assert-A4SLifecycleTool ($interopSources.Count -eq 1) 'could not isolate the embedded native helper source'
if (-not ('A4SProductLifecycleNative' -as [type])) {
    Add-Type -TypeDefinition $interopSources[0].Value
}
Assert-A4SLifecycleTool ($null -ne ('A4SProductLifecycleNative' -as [type])) `
    'the embedded native helper did not compile'

Write-Output 'PASS: lifecycle script parses, requires explicit injection consent, compiles its native helper, and attributes exactly one visible menu to the validated taskbar Explorer.'
