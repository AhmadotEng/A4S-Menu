<#
.SYNOPSIS
Validates the destructive lifecycle harness contract without executing it.

.DESCRIPTION
This test parses and reads Test-A4SInstallerLifecycle.ps1 as data. It never
dot-sources the harness, launches a binary, writes product state, or touches the
staged A4S product. It is suitable for build/CI validation of the safety rails
that must be reviewed before a separate, explicitly authorized live run.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) { throw "A4S lifecycle harness contract failed: $Message" }
}

function Assert-ContainsOrdinal {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Marker,
        [Parameter(Mandatory)][string] $Message
    )
    Assert-Contract ($Text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) $Message
}

function Assert-OrderedMarkers {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string[]] $Markers,
        [Parameter(Mandatory)][string] $Description
    )
    $cursor = -1
    foreach ($marker in $Markers) {
        $next = $Text.IndexOf($marker, $cursor + 1, [StringComparison]::Ordinal)
        Assert-Contract ($next -gt $cursor) "$Description is missing or reorders '$marker'"
        $cursor = $next
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$harnessPath = Join-Path $PSScriptRoot 'Test-A4SInstallerLifecycle.ps1'
$itemManagerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'
Assert-Contract (Test-Path -LiteralPath $harnessPath -PathType Leaf) 'lifecycle harness is missing'
Assert-Contract (Test-Path -LiteralPath $itemManagerPath -PathType Leaf) 'ItemManager.cpp is missing'

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $harnessPath, [ref]$tokens, [ref]$parseErrors)
Assert-Contract ($parseErrors.Count -eq 0) ('PowerShell parse errors: ' +
    (($parseErrors | ForEach-Object Message) -join ' | '))
$source = [IO.File]::ReadAllText($harnessPath)

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($requiredParameter in @('V1SetupPath', 'V2SetupPath',
        'ExpectedV1SetupSha256', 'ExpectedV2SetupSha256', 'AllowInstallMutation')) {
    Assert-Contract ($parameterNames -ccontains $requiredParameter) "missing parameter $requiredParameter"
}

foreach ($identity in @(
        'DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2',
        '9995676D0B74DE2E68E0C4EACB7E4111BE1AF13AA34C3505499C3925708A0573',
        '4C1C9A325FF41A6DD089690874C95DCC8CC8CC5A4561F9B8ECCFA29832C03610')) {
    Assert-ContainsOrdinal $source $identity "frozen V1 identity $identity is not pinned"
}
foreach ($marker in @(
        '[A4SInstallerLifecycleNative]::ReadRcData($SetupIdentity.Path, 201)',
        '[A4SInstallerLifecycleNative]::ReadRcData($SetupIdentity.Path, 202)',
        'ExpectedV1SetupSha256',
        'ExpectedV2SetupSha256',
        'Assert-ExactSlotPayload')) {
    Assert-ContainsOrdinal $source $marker "payload identity contract is missing '$marker'"
}

foreach ($marker in @(
        'Get-CleanStartRecord',
        'installer-owned versions directory to be absent',
        'A4S host/setup/helper process',
        'Get-StableUserStateProjection',
        'Restore-UserStateProjection',
        'OriginalUserStateSha256',
        'Final user-owned registry fingerprint does not match the immutable manifest')) {
    Assert-ContainsOrdinal $source $marker "clean-start/user-state contract is missing '$marker'"
}
Assert-Contract ($source.IndexOf('baseline-uninstall', [StringComparison]::OrdinalIgnoreCase) -lt 0) `
    'the retired baseline-uninstall behavior is still present'

foreach ($marker in @(
        '[IO.FileMode]::CreateNew',
        '$stream.Flush($true)',
        '[IO.File]::Replace($temporary, $script:evidencePath, $null, $true)',
        'Write-ImmutableManifest',
        'pre-mutation-manifest.json',
        '$script:manifestSha256')) {
    Assert-ContainsOrdinal $source $marker "durable evidence contract is missing '$marker'"
}
Assert-OrderedMarkers $source @(
    '$manifestRecord = Write-ImmutableManifest',
    '$mutationStarted = $true',
    "-Label 'preflight-v1-verify'") 'pre-mutation manifest boundary'

foreach ($marker in @(
        '$expectedCleanupRunOnce',
        'Get-StableCleanupObservation',
        'current interactive session',
        'exact expected setup hash',
        'Assert-NoTransientServicingState')) {
    Assert-ContainsOrdinal $source $marker "cleanup/journal contract is missing '$marker'"
}
Assert-OrderedMarkers $source @(
    "-Label 'failure-recovery-uninstall-v2'",
    'Assert-ProcessSucceededWithoutExplorerRestart $recovery.SetupUninstall',
    "-Label 'failure-recovery-uninstalled'",
    'Assert-UninstalledCheckpoint $recovery.UninstalledCheckpoint',
    'Assert-NoTransientServicingState -Checkpoint $recovery.UninstalledCheckpoint') `
    'failure recovery verification'

Assert-OrderedMarkers $source @(
    "-Label 'install-v1-silent'",
    "-Label 'upgrade-v1-to-v2-silent'",
    "-Label 'rollback-v2-to-v1-silent'",
    "-Label 'upgrade-v1-to-v2-again-silent'",
    "-Label 'repair-v2-same-version-silent'",
    "-Label 'uninstall-v2-silent'",
    "-Label 'final-install-v2-silent'",
    'Stop-FinalHostQuiescent',
    'Restore-UserStateProjection',
    'Start-Sleep -Milliseconds $finalQuiescenceVerificationMilliseconds') `
    'installer lifecycle sequence'
foreach ($marker in @(
        'Same-version repair changed the canonical installer registration or slot identities.',
        'validExitCodes = @(0, 1, 2, 4, 5, 6, 1062)',
        "Final host state is '",
        'HostWasNotRestarted = $true')) {
    Assert-ContainsOrdinal $source $marker "repair/host contract is missing '$marker'"
}

$startCommands = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Start-Process'
}, $true))
Assert-Contract ($startCommands.Count -eq 1) 'Start-Process must have exactly one centralized call site'
$invokeFunction = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Invoke-CapturedProcess'
}, $true))
Assert-Contract ($invokeFunction.Count -eq 1) 'Invoke-CapturedProcess must be defined exactly once'
$startOffset = $startCommands[0].Extent.StartOffset
Assert-Contract ($startOffset -ge $invokeFunction[0].Extent.StartOffset -and
    $startOffset -le $invokeFunction[0].Extent.EndOffset) `
    'Start-Process escaped Invoke-CapturedProcess'

foreach ($forbiddenCommand in @('Stop-Process', 'Restart-Computer', 'Restart-Service')) {
    $matches = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ieq $forbiddenCommand
    }.GetNewClosure(), $true))
    Assert-Contract ($matches.Count -eq 0) "forbidden command $forbiddenCommand is present"
}
foreach ($forbiddenText in @('taskkill', 'TerminateProcess(', 'baseline-uninstall-v2')) {
    Assert-Contract ($source.IndexOf($forbiddenText, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "forbidden lifecycle text '$forbiddenText' is present"
}

$preloadSource = [IO.File]::ReadAllText($itemManagerPath)
$preloadMatch = [regex]::Match($preloadSource,
    'WaitForSingleObject\(m_ExitEvent,(?<delay>[0-9]+)\)==WAIT_OBJECT_0')
Assert-Contract $preloadMatch.Success 'could not resolve the product preload debounce'
$harnessDebounce = [regex]::Match($source,
    '\$preloadDebounceMilliseconds\s*=\s*(?<delay>[0-9]+)')
$harnessVerification = [regex]::Match($source,
    '\$finalQuiescenceVerificationMilliseconds\s*=\s*(?<delay>[0-9]+)')
Assert-Contract ($harnessDebounce.Success -and $harnessVerification.Success) `
    'harness debounce/verification constants are missing'
$sourceDelay = [int]$preloadMatch.Groups['delay'].Value
$recordedDelay = [int]$harnessDebounce.Groups['delay'].Value
$verificationDelay = [int]$harnessVerification.Groups['delay'].Value
Assert-Contract ($recordedDelay -eq $sourceDelay) `
    "harness preload debounce $recordedDelay does not match ItemManager $sourceDelay"
Assert-Contract ($verificationDelay -gt $sourceDelay) `
    "final quiescence interval $verificationDelay is not longer than preload debounce $sourceDelay"

Write-Host 'A4S installer lifecycle harness offline contracts passed.'
