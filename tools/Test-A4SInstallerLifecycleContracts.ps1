<#
.SYNOPSIS
Validates the destructive lifecycle harness contract without executing it.

.DESCRIPTION
This gate parses Test-A4SInstallerLifecycle.ps1 as data, executes only two
side-effect-free functions extracted from its AST, and inspects setup source.
It never dot-sources the harness, launches a binary, writes product state, or
touches the staged/live A4S product.
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

function Get-FunctionAst {
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)][string] $Name
    )
    $matches = @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $Name
    }.GetNewClosure(), $true))
    Assert-Contract ($matches.Count -eq 1) "function $Name must be defined exactly once"
    return $matches[0]
}

function Get-SourceSection {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $StartMarker,
        [Parameter(Mandatory)][string] $EndMarker
    )
    $start = $Text.IndexOf($StartMarker, [StringComparison]::Ordinal)
    Assert-Contract ($start -ge 0) "section start '$StartMarker' is missing"
    $end = $Text.IndexOf($EndMarker, $start + $StartMarker.Length,
        [StringComparison]::Ordinal)
    Assert-Contract ($end -gt $start) "section end '$EndMarker' is missing"
    return $Text.Substring($start, $end - $start)
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$harnessPath = Join-Path $PSScriptRoot 'Test-A4SInstallerLifecycle.ps1'
$setupPath = Join-Path $repoRoot 'Src\A4SMenu\Setup\A4SMenuSetup.cpp'
$itemManagerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'
foreach ($path in @($harnessPath, $setupPath, $itemManagerPath)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "required source is missing: $path"
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $harnessPath, [ref]$tokens, [ref]$parseErrors)
Assert-Contract ($parseErrors.Count -eq 0) ('PowerShell parse errors: ' +
    (($parseErrors | ForEach-Object Message) -join ' | '))
$source = [IO.File]::ReadAllText($harnessPath)
$setupSource = [IO.File]::ReadAllText($setupPath)

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
        'ExpectedV1SetupSha256', 'ExpectedV2SetupSha256', 'Assert-ExactSlotPayload')) {
    Assert-ContainsOrdinal $source $marker "payload identity contract is missing '$marker'"
}

# Physical identity must be based on final handles and the nearest existing
# ancestor. This catches SUBST/8.3 aliases and hard-linked fixture identities.
foreach ($marker in @(
        'GetFinalPathNameByHandleW', 'GetFileInformationByHandle',
        'ExistingAncestorVolumeSerial', 'ExistingAncestorFileId',
        'NonExistingTail', 'Get-PhysicalPathRecord', 'Assert-NoPhysicalPathOverlap',
        "'V1 fixture and cleanup helper'", "'V2 fixture and cleanup helper'")) {
    Assert-ContainsOrdinal $source $marker "physical-path contract is missing '$marker'"
}
Assert-Contract ($source.IndexOf('function Test-PathWithin',
        [StringComparison]::Ordinal) -lt 0) 'retired lexical-only overlap logic remains'

$physicalFunction = Get-FunctionAst -Ast $ast -Name 'Test-CanonicalPhysicalOverlap'
$physicalCommands = @($physicalFunction.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true))
Assert-Contract ($physicalCommands.Count -eq 0) 'physical overlap model is no longer side-effect free'
. ([scriptblock]::Create($physicalFunction.Extent.Text))
$sameAncestorRoot = [pscustomobject]@{
    ExistingAncestorVolumeSerial = '11111111'; ExistingAncestorFileId = 'AAAAAAAAAAAAAAAA'
    NonExistingTail = @(); CanonicalPath = '\\?\C:\physical-root'
}
$sameAncestorChildAlias = [pscustomobject]@{
    ExistingAncestorVolumeSerial = '11111111'; ExistingAncestorFileId = 'AAAAAAAAAAAAAAAA'
    NonExistingTail = @('child'); CanonicalPath = '\\?\X:\alias-root\child'
}
$sameAncestorSibling = [pscustomobject]@{
    ExistingAncestorVolumeSerial = '11111111'; ExistingAncestorFileId = 'AAAAAAAAAAAAAAAA'
    NonExistingTail = @('sibling'); CanonicalPath = '\\?\X:\alias-root\sibling'
}
$differentVolume = [pscustomobject]@{
    ExistingAncestorVolumeSerial = '22222222'; ExistingAncestorFileId = 'AAAAAAAAAAAAAAAA'
    NonExistingTail = @(); CanonicalPath = '\\?\C:\physical-root'
}
$hardLinkAlias = [pscustomobject]@{
    ExistingAncestorVolumeSerial = '11111111'; ExistingAncestorFileId = 'AAAAAAAAAAAAAAAA'
    NonExistingTail = @(); CanonicalPath = '\\?\C:\different-hardlink-name'
}
Assert-Contract (Test-CanonicalPhysicalOverlap $sameAncestorRoot $sameAncestorChildAlias) `
    'same physical ancestor plus nested tail was not detected'
Assert-Contract (Test-CanonicalPhysicalOverlap $sameAncestorRoot $hardLinkAlias) `
    'same-volume file identity alias was not detected'
Assert-Contract (-not (Test-CanonicalPhysicalOverlap $sameAncestorChildAlias $sameAncestorSibling)) `
    'physical siblings were incorrectly treated as overlapping'
Assert-Contract (-not (Test-CanonicalPhysicalOverlap $sameAncestorRoot $differentVolume)) `
    'identical text on different volume identities was treated as overlapping'

# The decision function is executed as an isolated, pure model. In particular,
# clean state always wins over a stale installed label and can never uninstall.
$decisionFunction = Get-FunctionAst -Ast $ast -Name 'Get-RecoveryDecision'
$decisionCommands = @($decisionFunction.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true))
Assert-Contract ($decisionCommands.Count -eq 0) 'recovery decision model is no longer side-effect free'
. ([scriptblock]::Create($decisionFunction.Extent.Text))
function Invoke-RecoveryModel {
    param([bool] $Clean, [bool] $Pending, [bool] $KnownClean,
        [bool] $KnownInstalled, [bool] $KnownUninstalled)
    Get-RecoveryDecision -InstallerOwnedClean $Clean -ExactPendingCleanup $Pending `
        -KnownOwnedRestorableClean $KnownClean -KnownOwnedInstalled $KnownInstalled `
        -KnownOwnedUninstalled $KnownUninstalled
}
Assert-Contract ((Invoke-RecoveryModel $true $false $true $true $false) -ceq
    'RestoreCleanNoUninstall') 'known clean state can select uninstall'
Assert-Contract ((Invoke-RecoveryModel $true $false $false $true $false) -ceq
    'RetainCleanUnknownNoMutation') 'unknown/concurrent clean state is mutated'
Assert-Contract ((Invoke-RecoveryModel $false $true $false $true $false) -ceq
    'WaitPendingNoUninstall') 'exact pending cleanup can select uninstall'
Assert-Contract ((Invoke-RecoveryModel $false $false $false $true $false) -ceq
    'UninstallKnownOwned') 'coherent owned installed state does not select uninstall'
Assert-Contract ((Invoke-RecoveryModel $false $false $false $false $false) -ceq
    'RetainUnknownNoMutation') 'unknown state is not retained without mutation'

# One mutex spans clean preflight, every launch/evidence write, classification,
# recovery, and final evidence. Release occurs only in the outermost finally.
$mainOffset = $source.IndexOf('$failure = $null', [StringComparison]::Ordinal)
Assert-Contract ($mainOffset -ge 0) 'main lifecycle boundary is missing'
$mainSource = $source.Substring($mainOffset)
Assert-OrderedMarkers $mainSource @(
    'Acquire-LifecycleMutex',
    'Get-CleanStartRecord',
    '$manifestRecord = Write-ImmutableManifest',
    'Register-OwnedAggregate -Aggregate $cleanStart.Aggregate',
    '$setupExecutionStarted = $true',
    "-Label 'preflight-v1-verify'",
    "-Label 'final-v2-after-quiescence-interval'",
    "-Label 'failure-recovery-initial-aggregate'",
    'Release-LifecycleMutex') 'lifecycle-wide mutex/preflight/recovery boundary'
$acquireCalls = @($ast.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Acquire-LifecycleMutex'
}, $true))
$releaseCalls = @($ast.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Release-LifecycleMutex'
}, $true))
Assert-Contract ($acquireCalls.Count -eq 1 -and $releaseCalls.Count -eq 1) `
    'lifecycle mutex must have one acquire and one release call site'

# External process creation is centralized. For setup paths, the immediately
# preceding command is the last-owned aggregate check.
$startCommands = @($ast.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Start-Process'
}, $true))
Assert-Contract ($startCommands.Count -eq 1) 'Start-Process must have exactly one centralized call site'
$invokeFunction = Get-FunctionAst -Ast $ast -Name 'Invoke-CapturedProcess'
$startOffset = $startCommands[0].Extent.StartOffset
Assert-Contract ($startOffset -ge $invokeFunction.Extent.StartOffset -and
    $startOffset -le $invokeFunction.Extent.EndOffset) 'Start-Process escaped Invoke-CapturedProcess'
$invokeCommands = @($invokeFunction.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true) | Sort-Object { $_.Extent.StartOffset })
$startIndex = [Array]::IndexOf($invokeCommands, $startCommands[0])
Assert-Contract ($startIndex -gt 0 -and
    $invokeCommands[$startIndex - 1].GetCommandName() -ceq
        'Assert-LastOwnedAggregateImmediatelyBeforeSetup') `
    'last-owned aggregate check is not the final command before Start-Process'
$recordedSetupSource = (Get-FunctionAst -Ast $ast -Name 'Invoke-RecordedSetupStep').Extent.Text
Assert-OrderedMarkers $recordedSetupSource @('Invoke-CapturedProcess', '-SetupLaunch') `
    'recorded setup launch ownership guard'

# Recovery re-reads and hashes the immutable manifest before taking a stable
# aggregate. Only the modeled known-owned branch may launch uninstall.
$recoveryOffset = $mainSource.IndexOf('if (-not $completedSuccessfully',
    [StringComparison]::Ordinal)
Assert-Contract ($recoveryOffset -ge 0) 'failure recovery block is missing'
$recoverySource = $mainSource.Substring($recoveryOffset)
Assert-OrderedMarkers $recoverySource @(
    'Read-VerifiedImmutableManifest',
    "Get-StableLifecycleAggregate -Label 'failure-recovery-initial-aggregate'",
    'Find-OwnedAggregate',
    'Get-RecoveryDecision',
    "'RestoreCleanNoUninstall'",
    "'WaitPendingNoUninstall'",
    "'UninstallKnownOwned'",
    "-Label 'failure-recovery-uninstall-v2'",
    '-SetupLaunch',
    'Assert-UninstalledCheckpoint',
    'Release-LifecycleMutex') 'manifest-first, owned-only recovery flow'
$knownCase = $recoverySource.IndexOf("'UninstallKnownOwned'", [StringComparison]::Ordinal)
$nextCase = $recoverySource.IndexOf("'ObserveUninstalledNoUninstall'", $knownCase,
    [StringComparison]::Ordinal)
$uninstallLabel = $recoverySource.IndexOf("'failure-recovery-uninstall-v2'",
    [StringComparison]::Ordinal)
Assert-Contract ($knownCase -ge 0 -and $uninstallLabel -gt $knownCase -and
    $uninstallLabel -lt $nextCase) 'recovery uninstall escaped the known-owned switch case'
Assert-Contract ([regex]::Matches($recoverySource,
    [regex]::Escape("@('--uninstall', '--silent')")).Count -eq 1) `
    'recovery contains an extra or missing setup uninstall command'
foreach ($marker in @(
        '$actualHash -cne $script:manifestSha256',
        '$actualSidecar -cne $expectedSidecar',
        'ConvertFrom-Json',
        'The DataCache recovery backup no longer matches the immutable manifest',
        'ExpectedAggregate.Fingerprint')) {
    Assert-ContainsOrdinal $source $marker "immutable recovery contract is missing '$marker'"
}

# Registration and cleanup are one repeated stable aggregate, and every
# installed checkpoint forbids helper process/file/RunOnce residue.
$aggregateSource = (Get-FunctionAst -Ast $ast -Name 'Get-LifecycleAggregateOnce').Extent.Text
foreach ($marker in @('InstallerRegistration', 'UserStatePartitions', 'DataCache',
        'Versions', 'KnownRootFiles', 'A4SProcesses', 'ExplorerA4SModules', 'Cleanup')) {
    Assert-ContainsOrdinal $aggregateSource $marker "stable aggregate omits '$marker'"
}
$stableSource = (Get-FunctionAst -Ast $ast -Name 'Get-StableLifecycleAggregate').Extent.Text
Assert-OrderedMarkers $stableSource @('Get-LifecycleAggregateOnce', 'Get-ObjectFingerprint',
    'StableSamples') 'repeated stable aggregate'
$checkpointSource = (Get-FunctionAst -Ast $ast -Name 'Get-ProductCheckpoint').Extent.Text
Assert-Contract ([regex]::Matches($checkpointSource,
    'Get-StableLifecycleAggregate').Count -eq 2) `
    'product checkpoint must bracket host-status observation with stable aggregates'
$installedSource = (Get-FunctionAst -Ast $ast -Name 'Assert-InstalledCheckpoint').Extent.Text
foreach ($marker in @('Assert-ExactUninstallMetadata', 'Assert-ExactVersionsInventory',
        'Assert-NoTransientServicingState')) {
    Assert-ContainsOrdinal $installedSource $marker "installed checkpoint omits '$marker'"
}
$uninstalledSource = (Get-FunctionAst -Ast $ast -Name 'Assert-UninstalledCheckpoint').Extent.Text
foreach ($marker in @('pending cleanup contains staging/orphan/reparse content',
        'pending cleanup contains an unowned slot',
        'quiescent uninstall retained a known product cache/log file')) {
    Assert-ContainsOrdinal $uninstalledSource $marker "uninstall inventory contract omits '$marker'"
}
$invariantSource = (Get-FunctionAst -Ast $ast -Name 'Assert-UserStateAndCacheInvariant').Extent.Text
foreach ($marker in @("@('Config', 'Menu', 'Legacy')", 'HostSafety',
        'AllowExplicitRepairHostSafetyReset', 'Assert-DataCacheMatches')) {
    Assert-ContainsOrdinal $invariantSource $marker "user/cache invariant omits '$marker'"
}

Assert-OrderedMarkers $mainSource @(
    "-Label 'install-v1-silent'", "-Label 'upgrade-v1-to-v2-silent'",
    "-Label 'rollback-v2-to-v1-silent'", "-Label 'upgrade-v1-to-v2-again-silent'",
    "-Label 'repair-v2-same-version-silent'", "-Label 'uninstall-v2-silent'",
    "-Label 'final-install-v2-silent'", 'Wait-ForInstalledCleanupCancellation',
    'Stop-FinalHostQuiescent', 'Restore-UserStateProjection',
    'Start-Sleep -Milliseconds $finalQuiescenceVerificationMilliseconds') `
    'installer lifecycle sequence'
Assert-Contract ([regex]::Matches($mainSource,
    'Register-OwnedAggregate[\s\S]{0,240}?Write-Evidence').Count -ge 10) `
    'validated states are not registered before fallible evidence writes'

# Setup must cancel a stale helper without deleting the reinstalled product,
# and must retain an exact Explorer-mapped old slot as a coherent rollback slot.
$installedRegistrationSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool InstalledRegistrationPresent()' `
    -EndMarker 'enum class CleanupWaitResult'
Assert-ContainsOrdinal $installedRegistrationSource 'ReadRawValue(spec).present' `
    'cleanup does not fail closed on raw installer registration values'
Assert-Contract ($installedRegistrationSource.IndexOf('ReadString(',
        [StringComparison]::Ordinal) -lt 0) `
    'cleanup mistakes malformed/empty installer registration for absence'
$cleanupSource = Get-SourceSection -Text $setupSource -StartMarker 'int Cleanup(' `
    -EndMarker 'bool IsSwitch('
Assert-OrderedMarkers $cleanupSource @(
    'FullPath(CleanupHelperPath())',
    'WaitForProcessId(options.waitProcessId)',
    'WaitForProcessOrInstalledState(options.waitExplorerId)',
    'AcquireSetupMutex()',
    'ReconcilePendingJournal()',
    'InstalledRegistrationPresent()',
    'RegistrationMatchesCommittedSlot(',
    'RemoveCanonicalCleanupStateForHelper()',
    'RequestNativeSelfDelete()',
    'StringValueEquals(kRunOnceKey, kCleanupRunOnceValue, expectedCleanup)',
    'CleanupKnownInstallTree()') 'stale cleanup cancellation and canonical ownership'
Assert-Contract ($cleanupSource.IndexOf('WaitForProcessId(options.waitExplorerId)',
        [StringComparison]::Ordinal) -lt 0) 'cleanup can still wait forever without observing reinstall'
Assert-Contract ($cleanupSource.IndexOf('DeleteValueChecked(kRunOnceKey, kCleanupRunOnceValue)',
        [StringComparison]::Ordinal) -lt 0) 'cleanup directly deletes a non-canonical retry value'
$installSource = Get-SourceSection -Text $setupSource -StartMarker 'int InstallOrRepair(' `
    -EndMarker 'int Rollback('
Assert-OrderedMarkers $installSource @(
    'DeploySlot(payloads, oldState.activeSlot)',
    'InspectExplorerA4SModule(ExplorerProcessId())',
    'previous = mapped.validatedSlot',
    'BeginJournal(',
    'PrepareSlotRegistration(newSlot, previous)',
    'CompleteJournal(journal)',
    'PruneObsoleteSlotsBestEffort') 'mapped rollback-slot retention'
$parseSource = Get-SourceSection -Text $setupSource -StartMarker 'Options ParseOptions(' `
    -EndMarker 'bool Confirm('
Assert-OrderedMarkers $parseSource @('IsSwitch(argument, L"--repair")',
    'options.resetSafety = true', 'IsSwitch(argument, L"--update")') `
    'explicit repair-only HostSafety reset'

foreach ($forbiddenCommand in @('Stop-Process', 'Restart-Computer', 'Restart-Service')) {
    $matches = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ieq $forbiddenCommand
    }.GetNewClosure(), $true))
    Assert-Contract ($matches.Count -eq 0) "forbidden command $forbiddenCommand is present"
}
foreach ($forbiddenText in @('taskkill', 'TerminateProcess(', 'baseline-uninstall-v2',
        'baseline-uninstall')) {
    Assert-Contract ($source.IndexOf($forbiddenText,
            [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "forbidden lifecycle text '$forbiddenText' is present"
}

$preloadSource = [IO.File]::ReadAllText($itemManagerPath)
$preloadMatch = [regex]::Match($preloadSource,
    'WaitForSingleObject\(m_ExitEvent,(?<delay>[0-9]+)\)==WAIT_OBJECT_0')
$harnessDebounce = [regex]::Match($source,
    '\$preloadDebounceMilliseconds\s*=\s*(?<delay>[0-9]+)')
$harnessVerification = [regex]::Match($source,
    '\$finalQuiescenceVerificationMilliseconds\s*=\s*(?<delay>[0-9]+)')
Assert-Contract ($preloadMatch.Success -and $harnessDebounce.Success -and
    $harnessVerification.Success) 'preload debounce/verification constants are missing'
$sourceDelay = [int]$preloadMatch.Groups['delay'].Value
$recordedDelay = [int]$harnessDebounce.Groups['delay'].Value
$verificationDelay = [int]$harnessVerification.Groups['delay'].Value
Assert-Contract ($recordedDelay -eq $sourceDelay) `
    "harness preload debounce $recordedDelay does not match ItemManager $sourceDelay"
Assert-Contract ($verificationDelay -gt $sourceDelay) `
    "final quiescence interval $verificationDelay is not longer than preload debounce $sourceDelay"

Write-Host 'A4S installer lifecycle harness offline contracts passed.'
