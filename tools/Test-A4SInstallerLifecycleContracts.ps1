<#
.SYNOPSIS
Validates the destructive lifecycle harness contract without executing it.

.DESCRIPTION
This gate parses Test-A4SInstallerLifecycle.ps1 as data, executes selected
functions extracted from its AST, and inspects setup source. It never
dot-sources the harness, launches a binary, or touches staged/live A4S product
state. Its one write test uses a cryptographically unique HKCU registry sandbox,
injects every production-backend mutation failure, and restores absence.
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

function Assert-ThrowsContract {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Message
    )
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    Assert-Contract $threw $Message
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
$automaticHostReferences = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.VariablePath.UserPath -ieq 'Host'
}, $true))
Assert-Contract ($automaticHostReferences.Count -eq 0) `
    'lifecycle harness declares or references PowerShell automatic variable $Host'
$source = [IO.File]::ReadAllText($harnessPath)
$setupSource = [IO.File]::ReadAllText($setupPath)

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($requiredParameter in @('V1SetupPath', 'V2SetupPath',
        'ExpectedV1SetupSha256', 'ExpectedV2SetupSha256', 'AllowInstallMutation')) {
    Assert-Contract ($parameterNames -ccontains $requiredParameter) "missing parameter $requiredParameter"
}
$evidenceParameters = @($ast.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -ceq 'EvidenceDirectory'
})
Assert-Contract ($evidenceParameters.Count -eq 1 -and
    $null -eq $evidenceParameters[0].DefaultValue) `
    'EvidenceDirectory still evaluates a default expression during parameter binding'
Assert-OrderedMarkers $source @(
    "if (-not `$PSBoundParameters.ContainsKey('EvidenceDirectory'))",
    "(Join-Path `$PSScriptRoot '..\build\evidence\installer-lifecycle')",
    'if (-not $AllowInstallMutation)',
    '$evidenceRoot = Assert-LocalAbsolutePath $EvidenceDirectory') `
    'post-binding evidence default, authorization guard, and path validation order'

# Execute the real script without EvidenceDirectory or mutation authorization.
# It must reach the deliberate authorization boundary before fixture, evidence,
# registry, process, or product-state validation becomes reachable.
$authorizationError = $null
try {
    & $harnessPath `
        -V1SetupPath 'C:\A4S-contract-do-not-create\v1.exe' `
        -V2SetupPath 'C:\A4S-contract-do-not-create\v2.exe' `
        -ExpectedV1SetupSha256 ('0' * 64) `
        -ExpectedV2SetupSha256 ('0' * 64) | Out-Null
}
catch { $authorizationError = $_ }
Assert-Contract ($null -ne $authorizationError -and
    $authorizationError.Exception.Message -ceq
        'This is a LIVE per-user installer test. Re-run with -AllowInstallMutation only after reviewing the script and closing unrelated setup processes.') `
    'omitted EvidenceDirectory did not reach the intended mutation-authorization guard'

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

# Compile the harness's actual native handle resolver and execute its real path
# chain, including the nearest-existing-file rejection. This is intentionally
# read-only and catches StrictMode defects (such as undefined local variables)
# that source-string checks cannot detect.
$typeDefinition = [regex]::Match($source,
    "Add-Type -TypeDefinition @'\r?\n(?<code>[\s\S]*?)\r?\n'@")
Assert-Contract $typeDefinition.Success 'embedded physical-path helper type is missing'
if (-not ('A4SInstallerLifecycleNative' -as [type])) {
    Add-Type -TypeDefinition $typeDefinition.Groups['code'].Value
}
foreach ($functionName in @('Assert-LocalAbsolutePath',
        'Assert-NoReparsePointInExistingChain', 'Get-PhysicalPathRecord')) {
    . ([scriptblock]::Create((Get-FunctionAst -Ast $ast -Name $functionName).Extent.Text))
}
Assert-NoReparsePointInExistingChain $repoRoot
$nonexistentLeaf = '.a4s-offline-path-contract-' + [Guid]::NewGuid().ToString('N')
$nonexistentProbe = Join-Path $repoRoot $nonexistentLeaf
Assert-Contract (-not (Test-Path -LiteralPath $nonexistentProbe)) `
    'read-only path probe unexpectedly exists'
$realPathRecord = Get-PhysicalPathRecord $nonexistentProbe
Assert-Contract (@($realPathRecord.NonExistingTail).Count -eq 1 -and
    [string]$realPathRecord.NonExistingTail[0] -ceq $nonexistentLeaf) `
    'real nearest-existing-ancestor path resolution returned the wrong tail'
$fileAsAncestorProbe = $harnessPath + '\child-that-must-not-exist'
Assert-ThrowsContract { Get-PhysicalPathRecord $fileAsAncestorProbe | Out-Null } `
    'real path-chain helper accepted a non-directory nearest existing ancestor'

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
    param([bool] $Clean, [bool] $KnownOwnedPending, [bool] $KnownClean,
        [bool] $KnownInstalled, [bool] $KnownUninstalled)
    Get-RecoveryDecision -InstallerOwnedClean $Clean `
        -KnownOwnedPendingCleanup $KnownOwnedPending `
        -KnownOwnedRestorableClean $KnownClean -KnownOwnedInstalled $KnownInstalled `
        -KnownOwnedUninstalled $KnownUninstalled
}
Assert-Contract ((Invoke-RecoveryModel $true $false $true $true $false) -ceq
    'RestoreCleanNoUninstall') 'known clean state can select uninstall'
Assert-Contract ((Invoke-RecoveryModel $true $false $false $true $false) -ceq
    'RetainCleanUnknownNoMutation') 'unknown/concurrent clean state is mutated'
Assert-Contract ((Invoke-RecoveryModel $false $false $false $false $false) -ceq
    'RetainUnknownNoMutation') 'external exact-looking pending cleanup is treated as owned'
Assert-Contract ((Invoke-RecoveryModel $false $true $false $false $true) -ceq
    'WaitPendingNoUninstall') 'known-owned pending cleanup is not observed safely'
Assert-Contract ((Invoke-RecoveryModel $false $false $false $true $false) -ceq
    'UninstallKnownOwned') 'coherent owned installed state does not select uninstall'
Assert-Contract ((Invoke-RecoveryModel $false $false $false $false $false) -ceq
    'RetainUnknownNoMutation') 'unknown state is not retained without mutation'

# Execute the exact lifecycle sequence/token proof. An ABA/superseding write is
# represented by an advanced high-water value with the old LastOperation.
foreach ($functionName in @('Get-LifecycleOperationRecord',
        'Assert-ExactQualificationOperation')) {
    . ([scriptblock]::Create((Get-FunctionAst -Ast $ast -Name $functionName).Extent.Text))
}
$operationToken = 'A' * 64
$operationAggregate = [ordered]@{ Snapshot = [ordered]@{
    InstallerRegistration = [ordered]@{
        ServicingSequence = [ordered]@{ Present = $true; Kind = 'QWord'; Data = '7' }
        LastOperation = [ordered]@{
            Present = $true; Kind = 'String'; Data = ('00000000000000000007:' + $operationToken)
        }
    }
} }
Assert-ExactQualificationOperation -Aggregate $operationAggregate `
    -ExpectedSequence 7 -ExpectedToken $operationToken -Label 'contract-valid' | Out-Null
Assert-ThrowsContract {
    Assert-ExactQualificationOperation -Aggregate $operationAggregate `
        -ExpectedSequence 7 -ExpectedToken ('B' * 64) -Label 'contract-token-mismatch'
} 'qualification proof accepted the wrong operation token'
$operationAggregate.Snapshot.InstallerRegistration.ServicingSequence.Data = '8'
Assert-ThrowsContract {
    Assert-ExactQualificationOperation -Aggregate $operationAggregate `
        -ExpectedSequence 7 -ExpectedToken $operationToken -Label 'contract-ABA'
} 'qualification proof accepted an advanced sequence with stale LastOperation'

# Execute the real SID naming seam and require a separate harness lease plus
# both native product locks to be Global/current-user scoped. The contract does
# not acquire any mutex.
foreach ($functionName in @('Get-CurrentUserSidHashSuffix', 'Get-LifecycleMutexNames')) {
    . ([scriptblock]::Create((Get-FunctionAst -Ast $ast -Name $functionName).Extent.Text))
}
$sidHashSource = (Get-FunctionAst -Ast $ast -Name 'Get-CurrentUserSidHashSuffix').Extent.Text
foreach ($marker in @('.GetBinaryForm($bytes, 0)',
        '[Security.Cryptography.SHA256]::Create()', '.Substring(0, 32)')) {
    Assert-ContainsOrdinal $sidHashSource $marker `
        "harness SID hash is incompatible with native setup: missing '$marker'"
}
foreach ($marker in @('GetLengthSid(tokenUser->User.Sid)',
        'ConvertSidToStringSidW', 'HashBytes(CurrentUserSidBytes())',
        'Hex(identity).substr(0, 32)')) {
    Assert-ContainsOrdinal $setupSource $marker `
        "native setup SID hash is incompatible with harness coordination: missing '$marker'"
}
$mutexNames = Get-LifecycleMutexNames
Assert-Contract ([string]$mutexNames.Harness -cmatch
    '^Global\\A4SMenu\.LifecycleQualification\.v1\.[0-9A-F]{32}$') `
    'harness lifecycle lease is not Global and SID scoped'
Assert-Contract ([string]$mutexNames.ProductLifecycle -cmatch
    '^Global\\A4SMenu\.Lifecycle\.v1\.S-\d(-\d+)+$') `
    'product lifecycle coordination name is not the exact Global raw-SID scope'
Assert-Contract ([string]$mutexNames.ProductSetup -cmatch
    '^Global\\A4SMenu\.Setup\.v1\.[0-9A-F]{32}$') `
    'product setup coordination name is not the exact Global SID scope'
Assert-ContainsOrdinal $setupSource 'kSetupMutexPrefix[] = L"Global\\A4SMenu.Setup.v1."' `
    'native setup mutex prefix does not match the harness product-coordination name'
Assert-ContainsOrdinal $setupSource 'kLifecycleMutexPrefix[] = L"Global\\A4SMenu.Lifecycle.v1."' `
    'native lifecycle mutex prefix does not match the harness product-coordination name'
Assert-ContainsOrdinal $setupSource 'A4S_HOST_SAFETY_MUTEX_PREFIX_W' `
    'native setup does not share the raw-SID HostSafety mutex namespace'
$acquireSource = (Get-FunctionAst -Ast $ast -Name 'Acquire-LifecycleMutex').Extent.Text
$productAcquireSource = (Get-FunctionAst -Ast $ast -Name 'Acquire-ProductMutationLocks').Extent.Text
foreach ($leaseSource in @($acquireSource, $productAcquireSource)) {
    Assert-ContainsOrdinal $leaseSource '[Threading.Mutex]::new($false' `
        'coordination lease does not open/create the named mutex explicitly'
    Assert-ContainsOrdinal $leaseSource '.WaitOne(0)' `
        'coordination lease can block instead of failing closed'
    Assert-ContainsOrdinal $leaseSource 'catch' `
        'coordination lease does not fail closed on ACL/access errors'
}
Assert-OrderedMarkers $productAcquireSource @(
    '$lifecycle = [Threading.Mutex]::new', '$lifecycle.WaitOne(0)',
    '$setup = [Threading.Mutex]::new', '$setup.WaitOne(0)') `
    'fixed Lifecycle-then-Setup lock acquisition order'
foreach ($marker in @(
        'constexpr wchar_t kLifecycleKey[] = L"Software\\A4SMenuLifecycle"',
        'constexpr wchar_t kServicingSequenceValue[] = L"ServicingSequence"',
        'constexpr wchar_t kLastOperationValue[] = L"LastOperation"',
        '{ kLifecycleKey, kLastOperationValue }',
        'SetQword(key.get(), kServicingSequenceValue, identity.sequence)',
        'SetString(key.get(), kLastOperationValue, FormatOperationIdentity(identity))',
        'IsSwitch(argument, L"--qualification-operation-token")')) {
    Assert-ContainsOrdinal $setupSource $marker "native lifecycle identity contract omits '$marker'"
}
$journalSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'ServicingJournal BeginJournal(' -EndMarker 'void MarkJournalReady()'
Assert-OrderedMarkers $journalSource @(
    'journal.previous = CaptureRegistration()',
    'journal.operationSequence = identity.sequence',
    'journal.operationToken = identity.token',
    'journal.deployment = *deployment',
    'journal.cleanupHelper = *cleanupHelper',
    'SetDword(key.get(), L"CompletionStarted", 0)',
    'SetDword(key.get(), L"SchemaVersion", 2)',
    'SetQword(key.get(), L"OperationSequence", identity.sequence)',
    'SetString(key.get(), L"OperationToken", identity.token)',
    'WriteJournalOwnedPath(key.get(), L"DeploymentStaging"',
    'WriteJournalOwnedPath(key.get(), L"DeploymentFinal"',
    'WriteJournalOwnedPath(key.get(), L"CleanupHelper"',
    'SetDword(key.get(), L"SnapshotComplete", 1)',
    'RegFlushKey(key.get())') 'journaled sequence/token transaction'
$nativeMainSource = $setupSource.Substring($setupSource.IndexOf('int WINAPI wWinMain('))
Assert-OrderedMarkers $nativeMainSource @(
    'const ProductLocks productLocks = AcquireProductLocks()',
    'ReconcilePendingJournal()',
    'AllocateOperationIdentity(options.qualificationToken)',
    'InstallOrRepair(instance, options, identity)',
    'Uninstall(instance, options, identity)',
    'Rollback(options, identity)') 'normal CLI product-lock and operation identity flow'

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
# External process creation is centralized. State-changing setup orchestration
# owns both locks for pre-CAS, releases both only for the child, reacquires both,
# and proves the exact sequence/token before its result can be registered.
$startCommands = @($ast.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Start-Process'
}, $true))
Assert-Contract ($startCommands.Count -eq 1) 'Start-Process must have exactly one centralized call site'
$invokeFunction = Get-FunctionAst -Ast $ast -Name 'Invoke-CapturedProcess'
$startOffset = $startCommands[0].Extent.StartOffset
Assert-Contract ($startOffset -ge $invokeFunction.Extent.StartOffset -and
    $startOffset -le $invokeFunction.Extent.EndOffset) 'Start-Process escaped Invoke-CapturedProcess'
$recordedSetupSource = (Get-FunctionAst -Ast $ast -Name 'Invoke-RecordedSetupStep').Extent.Text
Assert-OrderedMarkers $recordedSetupSource @(
    '$lease = Acquire-ProductMutationLocks',
    'Assert-LastOwnedAggregateImmediatelyBeforeSetup',
    'New-QualificationOperationToken',
    'Release-ProductMutationLocks $lease',
    'Invoke-CapturedProcess',
    '$lease = Acquire-ProductMutationLocks',
    'Assert-ExactQualificationOperation',
    '$script:pendingProductLocks = $lease') `
    'cooperative setup lock/token handoff and locked acceptance'
$registerSource = (Get-FunctionAst -Ast $ast -Name 'Register-OwnedAggregate').Extent.Text
Assert-OrderedMarkers $registerSource @('Get-StableLifecycleAggregate',
    'Assert-ExactQualificationOperation', '$script:ownedAggregateLedger.Add',
    'Release-PendingProductMutationLocks') 'lock-held ownership registration CAS'
foreach ($forbiddenLegacyMutation in @("-Label 'install-v1-silent'",
        "-Label 'upgrade-v1-to-v2-silent'", "-Label 'rollback-v2-to-v1-silent'")) {
    Assert-Contract ($mainSource.IndexOf($forbiddenLegacyMutation,
            [StringComparison]::Ordinal) -lt 0) `
        "current-profile harness retained legacy state mutation $forbiddenLegacyMutation"
}
Assert-Contract ($mainSource.IndexOf('InstalledV1', [StringComparison]::Ordinal) -lt 0) `
    'current-profile ownership/recovery model retained a legacy V1 installed-state path'
foreach ($currentMutation in @("-Label 'install-v2-silent'",
        "-Label 'repair-v2-same-version-silent'", "-Label 'uninstall-v2-silent'",
        "-Label 'final-install-v2-silent'")) {
    $offset = $mainSource.IndexOf($currentMutation, [StringComparison]::Ordinal)
    Assert-Contract ($offset -ge 0) "current V2 mutation is missing: $currentMutation"
    $following = $mainSource.Substring($offset, [Math]::Min(300, $mainSource.Length - $offset))
    Assert-Contract ($following.IndexOf('-StateChanging', [StringComparison]::Ordinal) -ge 0) `
        "current V2 mutation is not token-qualified: $currentMutation"
}
foreach ($marker in @('NotRunInCurrentProfile',
        'Frozen V1 cannot participate in lifecycle token/sequence ownership; no alternate execution environment is authorized.')) {
    Assert-ContainsOrdinal $mainSource $marker "legacy current-profile exclusion omits '$marker'"
}

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
    '-StateChanging',
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
foreach ($marker in @('$knownOwnedPending = $exactPending',
        '$owned.Kind -ceq ''UninstalledPending''',
        '$null -ne $owned.QualificationOperation',
        "-Label 'failure-recovery-owned-pending-cleanup'",
        '-KnownOwnedPendingCleanup $knownOwnedPending')) {
    Assert-ContainsOrdinal $recoverySource $marker `
        "pending-cleanup ownership proof is missing '$marker'"
}
$pendingWaitSource = (Get-FunctionAst -Ast $ast `
    -Name 'Wait-ForPendingCleanupResolution').Extent.Text
foreach ($marker in @('[uint64] $ExpectedSequence', '[string] $ExpectedToken',
        'Assert-ExactQualificationOperation -Aggregate $aggregate',
        "State = 'Unknown'")) {
    Assert-ContainsOrdinal $pendingWaitSource $marker `
        "pending-cleanup continuity check is missing '$marker'"
}
foreach ($marker in @(
        '-ExpectedSequence ([uint64]$owned.QualificationOperation.ExpectedSequence)',
        '-ExpectedToken ([string]$owned.QualificationOperation.Token)',
        '-ExpectedSequence ([uint64]$recovery.SetupUninstall.QualificationOperation.ExpectedSequence)',
        '-ExpectedToken ([string]$recovery.SetupUninstall.QualificationOperation.Token)')) {
    Assert-ContainsOrdinal $recoverySource $marker `
        "pending-cleanup recovery call is missing '$marker'"
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
        'Assert-ExactInstalledProcessSet', 'Assert-NoTransientServicingState')) {
    Assert-ContainsOrdinal $installedSource $marker "installed checkpoint omits '$marker'"
}
$uninstalledSource = (Get-FunctionAst -Ast $ast -Name 'Assert-UninstalledCheckpoint').Extent.Text
foreach ($marker in @('$exactEmptyPendingPlaceholder',
        '$Checkpoint.CleanupRunOnce.Present',
        '@($uninstallNodes[0].Values).Count -eq 0',
        'empty uninstall key without verified pending cleanup',
        'pending cleanup contains staging/orphan/reparse content',
        'pending cleanup contains an unowned slot',
        'quiescent uninstall retained a known product cache/log file')) {
    Assert-ContainsOrdinal $uninstalledSource $marker "uninstall inventory contract omits '$marker'"
}
$invariantSource = (Get-FunctionAst -Ast $ast -Name 'Assert-UserStateAndCacheInvariant').Extent.Text
foreach ($marker in @("@('Config', 'Menu', 'Legacy')", 'HostSafety',
        'AllowExplicitRepairHostSafetyReset', 'Assert-DataCacheMatches')) {
    Assert-ContainsOrdinal $invariantSource $marker "user/cache invariant omits '$marker'"
}

# Execute the real registry snapshot schema/merge/equality seams with valid and
# adversarial in-memory states, then exercise the same production restoration
# backend against one unique, bounded HKCU sandbox.
foreach ($functionName in @('Get-NamedMemberValue', 'Get-ObjectFingerprint',
        'ConvertTo-EncodedRegistryValue', 'Add-RegistryTreeNodes',
        'Get-RegistryTreeSnapshot', 'ConvertFrom-EncodedRegistryData', 'Get-ObjectFieldNames',
        'Assert-ExactObjectFields', 'Assert-ValidRegistryTreeSnapshot',
        'Test-RegistryTreeSnapshotsEqual', 'Invoke-RegistryMutationCheckpoint',
        'Apply-ValidatedRegistryTreeSnapshot', 'Restore-RegistryTreeSnapshot',
        'Invoke-RegistryRestoreBackendSelfTest', 'New-MergedInstalledStateSnapshot')) {
    . ([scriptblock]::Create((Get-FunctionAst -Ast $ast -Name $functionName).Extent.Text))
}
$stateSubKey = 'Software\A4SContractOfflineOnly'
$installerOwnedRootValues = @('ActiveSlot', 'PreviousSlot', 'InstallVersion')
$validTree = [ordered]@{
    SubKey = $stateSubKey
    Exists = $true
    Nodes = @(
        [ordered]@{ RelativePath = ''; Values = @(
            [ordered]@{ Name = 'UserValue'; Kind = 'DWord'; Data = '7' }
        ) },
        [ordered]@{ RelativePath = 'Config'; Values = @(
            [ordered]@{ Name = 'Bytes'; Kind = 'Binary'; Data = 'AQID' },
            [ordered]@{ Name = 'Names'; Kind = 'MultiString'; Data = @('one', 'two') }
        ) }
    )
}
Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey -Snapshot $validTree | Out-Null
$validAbsentTree = [ordered]@{ SubKey = $stateSubKey; Exists = $false; Nodes = @() }
Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
    -Snapshot $validAbsentTree | Out-Null
$roundTrippedTree = $validTree | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
    -Snapshot $roundTrippedTree | Out-Null
Assert-Contract (Test-RegistryTreeSnapshotsEqual $validTree $validTree) `
    'real registry equality seam rejected identical snapshots'
$finalRegistration = [ordered]@{
    ActiveSlot = [ordered]@{ Present = $true; Name = 'ActiveSlot'; Kind = 'String'; Data = 'C:\A4S\v2' }
    PreviousSlot = [ordered]@{ Present = $true; Name = 'PreviousSlot'; Kind = 'String'; Data = 'C:\A4S\v1' }
    InstallVersion = [ordered]@{ Present = $true; Name = 'InstallVersion'; Kind = 'String'; Data = '1.1.0.0' }
}
$mergedTree = New-MergedInstalledStateSnapshot -OriginalProjection $validTree `
    -FinalInstallerRegistration $finalRegistration
Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey -Snapshot $mergedTree | Out-Null
$mergedRootNames = @($mergedTree.Nodes[0].Values | ForEach-Object { [string]$_.Name })
foreach ($requiredName in @('UserValue', 'ActiveSlot', 'PreviousSlot', 'InstallVersion')) {
    Assert-Contract ($mergedRootNames -ccontains $requiredName) `
        "real registry merge omitted $requiredName"
}
$badFinalRegistration = [ordered]@{
    ActiveSlot = [ordered]@{ Present = $true; Name = 42; Kind = 'String'; Data = 'C:\A4S\v2' }
    PreviousSlot = $finalRegistration.PreviousSlot
    InstallVersion = $finalRegistration.InstallVersion
}
Assert-ThrowsContract {
    New-MergedInstalledStateSnapshot -OriginalProjection $validTree `
        -FinalInstallerRegistration $badFinalRegistration | Out-Null
} 'registry merge accepted a non-string installer-owned value name'
$duplicateNodeTree = [ordered]@{ SubKey = $stateSubKey; Exists = $true; Nodes = @(
    [ordered]@{ RelativePath = ''; Values = @() },
    [ordered]@{ RelativePath = ''; Values = @() }) }
Assert-ThrowsContract {
    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
        -Snapshot $duplicateNodeTree | Out-Null
} 'registry validator accepted duplicate nodes'
$missingParentTree = [ordered]@{ SubKey = $stateSubKey; Exists = $true; Nodes = @(
    [ordered]@{ RelativePath = ''; Values = @() },
    [ordered]@{ RelativePath = 'Missing\Child'; Values = @() }) }
Assert-ThrowsContract {
    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
        -Snapshot $missingParentTree | Out-Null
} 'registry validator accepted a node without its parent'
$badEncodedTree = [ordered]@{ SubKey = $stateSubKey; Exists = $true; Nodes = @(
    [ordered]@{ RelativePath = ''; Values = @(
        [ordered]@{ Name = 'Bad'; Kind = 'Binary'; Data = 'not-base64!' }) }) }
Assert-ThrowsContract {
    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
        -Snapshot $badEncodedTree | Out-Null
} 'registry validator accepted invalid encoded value data'

$restoreTreeSource = (Get-FunctionAst -Ast $ast -Name 'Restore-RegistryTreeSnapshot').Extent.Text
Assert-OrderedMarkers $restoreTreeSource @(
    'Assert-ValidRegistryTreeSnapshot',
    '$immediatePreState = Get-RegistryTreeSnapshot',
    'if (Test-RegistryTreeSnapshotsEqual $immediatePreState $Snapshot)',
    'Apply-ValidatedRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey -Snapshot $Snapshot',
    'catch',
    '-Snapshot $immediatePreState') 'transactional registry validate/no-op/apply/rollback order'
Assert-Contract ([regex]::Matches($source, 'DeleteSubKeyTree\(').Count -eq 2) `
    'registry deletion escaped production apply plus the bounded self-test fallback'
Assert-Contract ([regex]::Matches($source,
    'Apply-ValidatedRegistryTreeSnapshot').Count -eq 3) `
    'validated registry apply primitive has a caller outside target apply/rollback'
$applyTreeSource = (Get-FunctionAst -Ast $ast `
    -Name 'Apply-ValidatedRegistryTreeSnapshot').Extent.Text
Assert-ContainsOrdinal $applyTreeSource 'DeleteSubKeyTree($ExpectedSubKey, $false)' `
    'validated registry apply primitive does not own the sole tree deletion'
Assert-Contract ($source.IndexOf('function Restore-RegistryValueSnapshot',
        [StringComparison]::Ordinal) -lt 0) `
    'legacy per-value destructive restoration remains'
$registryBackendTest = Invoke-RegistryRestoreBackendSelfTest
Assert-Contract ([bool]$registryBackendTest.Passed -and
    [int]$registryBackendTest.MutationStepsTested -gt 0 -and
    [string]$registryBackendTest.Sandbox -match
        '^Software\\A4SMenuLifecycleRegistryRestoreTest\.[0-9A-F]{32}$') `
    'production registry restoration backend no-op/success/failure rollback test failed'

# Execute the installed-process ownership model. Exact active-host records may
# be empty or one matching process; Setup/Cleanup/duplicates/wrong sessions fail.
$processFunction = Get-FunctionAst -Ast $ast -Name 'Test-ExactInstalledProcessSet'
. ([scriptblock]::Create($processFunction.Extent.Text))
$session = 17
$hostIdentity = [ordered]@{ Path = 'C:\A4S\versions\v2\A4SMenuHost.exe'; Sha256 = ('A' * 64) }
$hostProcess = [ordered]@{ Id = 101; SessionId = $session; Path = $hostIdentity.Path; Sha256 = $hostIdentity.Sha256 }
$aggregateHost = [ordered]@{
    Name = 'A4SMenuHost'; Id = 101; SessionId = $session; Path = $hostIdentity.Path
    Sha256 = $hostIdentity.Sha256; StartTimeUtc = $null; PathError = $null
}
Assert-Contract (Test-ExactInstalledProcessSet @($aggregateHost) @($hostProcess) `
    $hostIdentity $session) 'exact active-host process set was rejected'
Assert-Contract (Test-ExactInstalledProcessSet @() @() $hostIdentity $session) `
    'valid quiescent installed process set was rejected'
foreach ($unexpectedName in @('A4SMenuSetup', 'A4SMenuCleanup')) {
    $unexpected = [ordered]@{
        Name = $unexpectedName; Id = 102; SessionId = $session; Path = 'C:\unknown.exe'
        Sha256 = ('B' * 64); StartTimeUtc = $null; PathError = $null
    }
    Assert-Contract (-not (Test-ExactInstalledProcessSet @($aggregateHost, $unexpected) `
        @($hostProcess) $hostIdentity $session)) `
        "installed process model accepted $unexpectedName"
}
$wrongSession = [ordered]@{
    Name = 'A4SMenuHost'; Id = 101; SessionId = $session + 1; Path = $hostIdentity.Path
    Sha256 = $hostIdentity.Sha256; StartTimeUtc = $null; PathError = $null
}
Assert-Contract (-not (Test-ExactInstalledProcessSet @($wrongSession) @($hostProcess) `
    $hostIdentity $session)) 'installed process model accepted a wrong-session host'

# Execute both host-observation call paths with an in-memory process stub. This
# catches collisions with PowerShell's read-only automatic $Host variable while
# proving the exact active-host path/hash is forwarded without launching it.
$hostInteractionModule = New-Module -Name A4SInstallerHostInteractionContract `
    -ScriptBlock {
        param([string] $StatusFunctionSource, [string] $StopFunctionSource)
        $script:CapturedCalls = [Collections.Generic.List[object]]::new()
        function Invoke-CapturedProcess {
            param(
                [Parameter(Mandatory)][string] $Label,
                [Parameter(Mandatory)][string] $FilePath,
                [Parameter(Mandatory)][string[]] $Arguments,
                [Parameter(Mandatory)][string] $ExpectedSha256,
                [Parameter(Mandatory)][int] $TimeoutSeconds
            )
            [void]$script:CapturedCalls.Add([ordered]@{
                Label = $Label
                FilePath = $FilePath
                Arguments = @($Arguments)
                ExpectedSha256 = $ExpectedSha256
                TimeoutSeconds = $TimeoutSeconds
            })
            return [ordered]@{
                Label = $Label
                StartError = $null
                TimedOut = $false
                ExitCode = if ($Arguments -contains '--status') { 1062 } else { 0 }
                ExplorerPidUnchanged = $true
                ExplorerPidBefore = 101
                ExplorerPidAfter = 101
            }
        }
        function Assert-ProcessSucceededWithoutExplorerRestart {
            param([Parameter(Mandatory)] $Record)
            if ($Record.StartError -or $Record.TimedOut -or $Record.ExitCode -ne 0 -or
                -not $Record.ExplorerPidUnchanged) {
                throw 'The in-memory host interaction fixture returned an unexpected result.'
            }
        }
        function Get-HostProcessRecords {
            param([AllowNull()] $ActiveSlot)
            return @()
        }
        . ([scriptblock]::Create($StatusFunctionSource))
        . ([scriptblock]::Create($StopFunctionSource))
    } -ArgumentList `
        (Get-FunctionAst -Ast $ast -Name 'Get-HostStatusRecord').Extent.Text,
        (Get-FunctionAst -Ast $ast -Name 'Stop-FinalHostQuiescent').Extent.Text
$activeSlotFixture = [ordered]@{ Files = [ordered]@{ Host = $hostIdentity } }
$hostInteraction = & $hostInteractionModule {
    param($activeSlot)
    $status = Get-HostStatusRecord -ActiveSlot $activeSlot -Label 'contract-status'
    $checkpoint = [ordered]@{
        HostStatus = [ordered]@{ State = 'ready' }
        HostProcesses = @([ordered]@{ Id = 101 })
        ActiveSlot = $activeSlot
    }
    $stopped = Stop-FinalHostQuiescent -Checkpoint $checkpoint
    return [ordered]@{
        Status = $status
        Stopped = $stopped
        Calls = @($script:CapturedCalls)
    }
} $activeSlotFixture
Assert-Contract ($hostInteraction.Status.State -ceq 'stopped' -and
    $hostInteraction.Stopped.After.State -ceq 'stopped' -and
    $hostInteraction.Stopped.Exit.ExitCode -eq 0) `
    'in-memory host status/quiescence execution returned the wrong state'
Assert-Contract ($hostInteraction.Calls.Count -eq 3 -and
    $hostInteraction.Calls[0].Arguments[0] -ceq '--status' -and
    $hostInteraction.Calls[1].Arguments[0] -ceq '--exit' -and
    $hostInteraction.Calls[2].Arguments[0] -ceq '--status') `
    'host status/quiescence execution did not issue the exact expected commands'
foreach ($call in $hostInteraction.Calls) {
    Assert-Contract ($call.FilePath -ceq $hostIdentity.Path -and
        $call.ExpectedSha256 -ceq $hostIdentity.Sha256 -and
        $call.TimeoutSeconds -eq 10) `
        'host status/quiescence execution did not preserve active-host identity'
}

Assert-OrderedMarkers $mainSource @(
    "-Label 'preflight-v1-verify'", "-Label 'preflight-v2-verify'",
    "-Label 'install-v2-silent'",
    "-Label 'repair-v2-same-version-silent'", "-Label 'uninstall-v2-silent'",
    "-Label 'final-install-v2-silent'", 'Wait-ForInstalledCleanupCancellation',
    'Stop-FinalHostQuiescent', 'Restore-UserStateProjection',
    'Start-Sleep -Milliseconds $finalQuiescenceVerificationMilliseconds') `
    'installer lifecycle sequence'
$finalInstallSection = Get-SourceSection -Text $mainSource `
    -StartMarker '$finalInstall = Invoke-RecordedSetupStep' `
    -EndMarker '$script:evidence.FinalHostQuiescence'
Assert-OrderedMarkers $finalInstallSection @(
    '$finalInstallCheckpoint = Add-CheckpointToStep',
    'Assert-InstalledCheckpoint',
    'Assert-ExpectedHostState',
    'Assert-UserStateAndCacheInvariant',
    '-OriginalPartitions $uninstallCheckpoint.UserStatePartitions',
    '-OriginalDataCache $uninstallCheckpoint.DataCache',
    'Register-OwnedAggregate') `
    'pre-restoration final-install user/cache validation'
Assert-Contract ([regex]::Matches($mainSource,
    'Register-OwnedAggregate[\s\S]{0,240}?Write-Evidence').Count -ge 9) `
    'validated states are not registered before fallible evidence writes'

# Setup must cancel a stale helper without deleting the reinstalled product,
# and must retain an exact Explorer-mapped old slot as a coherent rollback slot.
$installedRegistrationSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool InstalledRegistrationPresent()' `
    -EndMarker 'constexpr bool CleanupMayReconcile'
Assert-ContainsOrdinal $installedRegistrationSource 'ReadRawValue(spec).present' `
    'cleanup does not fail closed on raw installer registration values'
Assert-Contract ($installedRegistrationSource.IndexOf('ReadString(',
        [StringComparison]::Ordinal) -lt 0) `
    'cleanup mistakes malformed/empty installer registration for absence'
Assert-Contract ($installedRegistrationSource.IndexOf('kRecoveryRunOnceValue',
        [StringComparison]::Ordinal) -lt 0) `
    'cleanup still excludes servicing recovery RunOnce from installed-state detection'
$recoveryGateSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'constexpr bool CleanupMayReconcile' `
    -EndMarker 'enum class CleanupWaitResult'
foreach ($marker in @(
        'static_assert(CleanupMayReconcile(false, false))',
        'static_assert(!CleanupMayReconcile(true, false))',
        'static_assert(CleanupMayReconcile(true, true))',
        'bool ServicingRecoveryStateAllowsReconcile()',
        'snapshotComplete == 1U',
        'journal.target == JournalTarget::Installed',
        'journal.targetRecoveryCommand',
        'StringValueEquals(kRunOnceKey, kRecoveryRunOnceValue')) {
    Assert-ContainsOrdinal $recoveryGateSource $marker `
        "servicing recovery fail-closed model omits '$marker'"
}
$cleanupSource = Get-SourceSection -Text $setupSource -StartMarker 'int Cleanup(' `
    -EndMarker 'bool IsSwitch('
Assert-OrderedMarkers $cleanupSource @(
    'FullPath(CleanupHelperPath())',
    'OpenCleanupImageForSelfDelete()',
    'WaitForProcessId(options.waitProcessId)',
    'WaitForProcessOrInstalledState(options.waitExplorerId)',
    'AcquireProductLocks()',
    'ServicingRecoveryStateAllowsReconcile()',
    'ReconcilePendingJournal(&runningCleanupImage)',
    'ReadRawValue(recovery).present',
    'InstalledRegistrationPresent()',
    'RegistrationMatchesCommittedSlot(',
    'RemoveCanonicalCleanupStateForHelper(cleanupIdentity)',
    'RequestNativeSelfDelete(runningCleanupImage)',
    'CleanupContinuationMatches(cleanupIdentity)',
    'CleanupKnownInstallTree()') 'stale cleanup cancellation and canonical ownership'
Assert-Contract ($cleanupSource.IndexOf('WaitForProcessId(options.waitExplorerId)',
        [StringComparison]::Ordinal) -lt 0) 'cleanup can still wait forever without observing reinstall'
Assert-Contract ($cleanupSource.IndexOf('DeleteValueChecked(kRunOnceKey, kCleanupRunOnceValue)',
        [StringComparison]::Ordinal) -lt 0) 'cleanup directly deletes a non-canonical retry value'
$installSource = Get-SourceSection -Text $setupSource -StartMarker 'int InstallOrRepair(' `
    -EndMarker 'int Rollback('
$deploymentSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'DeploymentPlan PlanDeployment(' `
    -EndMarker 'void MaterializeDeployment('
$slotMatchSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool SlotMatchesPayload(' `
    -EndMarker 'bool InspectPlannedDirectory('
foreach ($leafMarker in @(
        'ExactSingleLinkFile(Join(slot, A4S_PRODUCT_HOST_FILENAME_W)',
        'ExactSingleLinkFile(Join(slot, A4S_PRODUCT_DLL_FILENAME_W)',
        'ExactSingleLinkFile(Join(slot, kSetupFilename)')) {
    Assert-ContainsOrdinal $slotMatchSource $leafMarker `
        "immutable-slot reuse accepts an unsafe payload leaf ('$leafMarker')"
}
Assert-OrderedMarkers $deploymentSource @(
    'SlotMatchesPayload(preferredSlot, payloads)',
    'SlotMatchesPayload(fallbackSlot, payloads)',
    'SlotMatchesPayload(canonical, payloads)',
    'payloads.slotName + L".repair-" + suffix') `
    'active, registered previous, canonical, then repair immutable-slot reuse'
Assert-OrderedMarkers $installSource @(
    'PlanDeployment(payloads,',
    'oldState.activeSlot, oldState.previousSlot, identity)',
    'IsDistinctValidSlot(oldState.activeSlot, newSlot)',
    'IsDistinctValidSlot(oldState.previousSlot, newSlot)',
    'InspectExplorerA4SModules(ExplorerProcessId())',
    'mapped.complete && !mapped.unknownA4SModule',
    'mapped.validatedSlots.size() == 1U',
    'previous = mapped.validatedSlots.front()',
    'BeginJournal(',
    'MaterializeDeployment(payloads, deployment, journal)',
    'PrepareSlotRegistration(newSlot, previous, identity)',
    'CompleteJournal(journal)',
    'PruneObsoleteSlotsBestEffort') 'mapped rollback-slot retention'

$rollbackSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void RollBackJournal(ServicingJournal &journal, UniqueHandle *runningCleanupImage)' `
    -EndMarker 'void CompleteJournal(const ServicingJournal &journal) {'
Assert-OrderedMarkers $rollbackSource @(
    'RestoreRegistration(journal.previous)',
    'RegistrationSnapshotMatches(journal.previous)',
    'ReleaseOwnedCleanupHelper(journal, runningCleanupImage)',
    'ReleaseOwnedDeployment(journal, runningCleanupImage)',
    'DeleteJournalDurably()') 'registration-first exact-owned filesystem rollback'

$completeSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void CompleteJournal(const ServicingJournal &journal) {' `
    -EndMarker 'void ReconcilePendingJournal(UniqueHandle *runningCleanupImage) {'
Assert-OrderedMarkers $completeSource @(
    'SetDword(key.get(), L"CompletionStarted", 1)',
    'RegFlushKey(key.get())',
    'ClearSafetyStateChecked()',
    'DeleteJournalDurably()',
    'DeleteValueChecked(kRunOnceKey, kRecoveryRunOnceValue)') `
    'idempotent recovery residue after the journal commit point'

$hostSafetySource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void ClearSafetyStateChecked()' `
    -EndMarker 'void DeleteJournalDurably()'
Assert-OrderedMarkers $hostSafetySource @(
    'AcquireHostSafetyMutex()',
    'DeleteTreeChecked(A4S_HOST_SAFETY_REGISTRY_W)') `
    'Lifecycle-Setup-HostSafety lock nesting'
Assert-Contract ([regex]::Matches($setupSource,
        'DeleteTreeChecked\(A4S_HOST_SAFETY_REGISTRY_W\)').Count -eq 1) `
    'HostSafety has an uncoordinated setup deletion path'

foreach ($marker in @(
        'static_assert(CanDeleteOwnedPath(true, true, false, false, true, false, false))',
        'static_assert(!CanDeleteOwnedPath(true, false, false, false, true, false, false))',
        'static_assert(!CanDeleteOwnedPath(true, true, true, false, true, false, false))',
        'static_assert(!CanDeleteOwnedPath(true, true, false, true, true, false, false))',
        'static_assert(!CanDeleteOwnedPath(true, true, false, false, true, true, false))')) {
    Assert-ContainsOrdinal $setupSource $marker `
        "native owned-path failure decision matrix omits '$marker'"
}
$pinnedDirectorySource = Get-SourceSection -Text $setupSource `
    -StartMarker 'UniqueHandle OpenPinnedOwnedDirectory(' `
    -EndMarker 'UniqueHandle MaterializeOwnedDirectory('
foreach ($marker in @('FILE_SHARE_READ | FILE_SHARE_WRITE',
        'FILE_FLAG_OPEN_REPARSE_POINT',
        'SameFileIdentity(FileIdentityFromHandle(directory.get()), record.identity)')) {
    Assert-ContainsOrdinal $pinnedDirectorySource $marker `
        "pinned deployment-directory ownership omits '$marker'"
}
Assert-Contract ($pinnedDirectorySource.IndexOf(
        'FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE',
        [StringComparison]::Ordinal) -lt 0) `
    'pinned deployment-directory leases permit pathname replacement'
$ownedReleaseSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void ReleaseOwnedDeployment(' `
    -EndMarker 'void ReleaseOwnedCleanupHelper('
foreach ($marker in @(
        'stagingExists && !journal.deployment.staging.identity.valid',
        'finalExists && !finalProof.valid',
        'const bool inspectionComplete = explorer != 0 && inspection.complete',
        '!explorer || inspection.unknownA4SModule')) {
    Assert-ContainsOrdinal $ownedReleaseSource $marker `
        "crash-safe deployment release omits '$marker'"
}
$ownedSlotRemovalSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool RemoveOwnedSlotDirectory(' `
    -EndMarker 'void ReleaseEmptyOwnedDirectory('
foreach ($marker in @('bool allowMissingFiles, bool allowJournaledPartial',
        'if (!allowMissingFiles && (!host || !menu || !setup))',
        'allowJournaledPartial && identityMatches && identityRequired')) {
    Assert-ContainsOrdinal $ownedSlotRemovalSource $marker `
        "retry-safe owned-slot removal omits '$marker'"
}
$normalizedOwnedReleaseSource = $ownedReleaseSource -replace '\s+', ' '
foreach ($marker in @(
        'journal.deployment.staging.identity, journal.deployment, true, true, runningOwnedImage)',
        'finalProof, journal.deployment, true, false, runningOwnedImage)')) {
    Assert-ContainsOrdinal $normalizedOwnedReleaseSource $marker `
        "owned-slot recovery call contract omits '$marker'"
}
$emptyOwnedDirectorySource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void ReleaseEmptyOwnedDirectory(' `
    -EndMarker 'void ReleaseOwnedDeployment('
foreach ($marker in @('if (!record.identity.valid)',
        'FILE_SHARE_READ | FILE_SHARE_WRITE',
        '!SameFileIdentity(FileIdentityFromHandle(directory.get()), record.identity)',
        'record.phase = OwnedPathPhase::Released')) {
    Assert-ContainsOrdinal $emptyOwnedDirectorySource $marker `
        "exact empty-directory recovery omits '$marker'"
}
$helperReleaseSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void ReleaseOwnedCleanupHelper(' `
    -EndMarker 'void RollBackJournal('
Assert-ContainsOrdinal $helperReleaseSource 'if (!helper.identity.valid)' `
    'intent-only cleanup-helper recovery can still delete without identity proof'
$knownSlotCleanupSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool RemoveKnownSlotFilesUnchecked(' `
    -EndMarker 'void RemoveStagingBestEffort('
foreach ($marker in @('FILE_SHARE_READ | FILE_SHARE_WRITE',
        'FILE_FLAG_OPEN_REPARSE_POINT', 'links.nNumberOfLinks != 1U',
        'SlotNameMatchesPayload(leaf, PayloadSlotBase(',
        'SetFileInformationByHandle(file.get(), FileDispositionInfoEx')) {
    Assert-ContainsOrdinal $knownSlotCleanupSource $marker `
        "exact known-slot cleanup omits '$marker'"
}
$cleanupContinuationSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool CleanupContinuationMatches(' `
    -EndMarker 'std::wstring RecoveryCommand('
Assert-OrderedMarkers $cleanupContinuationSource @(
    'ReadLifecycleHighWater() < identity.sequence',
    '!LastOperationMatches(identity)',
    'StringValueEquals(kRunOnceKey, kCleanupRunOnceValue, expected)') `
    'cleanup continuation CAS after an uncommitted high-water advance'
$expectedCleanupSource = (Get-FunctionAst -Ast $ast `
    -Name 'Get-ExpectedCleanupRunOnceForSnapshot').Extent.Text
Assert-ContainsOrdinal $expectedCleanupSource `
    '$operation.LastSequence -gt $operation.HighWater' `
    'pending-cleanup model rejects a valid last commit after a rolled-back sequence advance'
Assert-Contract ($expectedCleanupSource.IndexOf(
        '$operation.LastSequence -ne $operation.HighWater',
        [StringComparison]::Ordinal) -lt 0) `
    'pending-cleanup model still requires last-operation/high-water equality'
$rollbackRecoverySource = Get-SourceSection -Text $setupSource `
    -StartMarker 'std::wstring RollbackRecoverySetup(' `
    -EndMarker 'void QueueJournalRecovery('
Assert-OrderedMarkers $rollbackRecoverySource @(
    'FileProductVersion(targetSetup)',
    'kDurableFilesystemJournalMinimumVersion',
    'ValidateSlotBasic(state.activeSlot)',
    'FileProductVersion(activeSetup)',
    'return activeSetup') 'frozen-v1 rollback schema coordinator'
$nativeReconcileSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void ReconcilePendingJournal(UniqueHandle *runningCleanupImage) {' `
    -EndMarker 'bool StartPreparedCleanup('
Assert-OrderedMarkers $nativeReconcileSource @(
    'journal.completionStarted && ready && completingTargetMatches',
    'CompleteJournal(journal)',
    'journal.deployment.required',
    'FullPath(ModulePath())',
    'OpenCleanupImageForSelfDelete()',
    'rollbackImage = &runningDeploymentImage',
    'RollBackJournal(journal, rollbackImage)') `
    'running recovery image exact self-delete before owned slot release'
$moduleInspectionSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'struct ExplorerModuleInspection' `
    -EndMarker 'bool StartHost('
foreach ($marker in @(
        'bool complete = false', 'bool unknownA4SModule = false',
        'std::vector<std::wstring> modulePaths',
        'std::vector<std::wstring> validatedSlots',
        'static_assert(CanPruneKnownSlot(true, false, false))',
        'static_assert(!CanPruneKnownSlot(false, false, false))',
        'static_assert(!CanPruneKnownSlot(true, true, false))',
        'static_assert(!CanPruneKnownSlot(true, false, true))',
        'result.complete = GetLastError() == ERROR_NO_MORE_FILES',
        'AddUniquePath(result.modulePaths',
        'AddUniquePath(result.validatedSlots',
        'result.unknownA4SModule = true',
        'InspectExplorerA4SModules(ExplorerProcessId())',
        'RemoveKnownSlotFilesUnchecked(canonicalSlot)')) {
    Assert-ContainsOrdinal $moduleInspectionSource $marker `
        "Explorer module fail-closed model omits '$marker'"
}
Assert-Contract ([regex]::Matches($setupSource,
    'RemoveKnownSlotFilesUnchecked\(').Count -eq 2) `
    'unchecked slot removal has a caller outside its checked wrapper'
$cleanupTreeSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'bool CleanupKnownInstallTree()' `
    -EndMarker 'void PruneObsoleteSlotsBestEffort('
Assert-OrderedMarkers $cleanupTreeSource @(
    'InspectExplorerA4SModules(ExplorerProcessId())',
    'CanPruneKnownSlot(inspection.complete',
    '!inspection.modulePaths.empty()',
    'RemoveKnownSlot(slot)') 'uninstall mapped/unknown module deletion guard'
$pruneSource = Get-SourceSection -Text $setupSource `
    -StartMarker 'void PruneObsoleteSlotsBestEffort(' `
    -EndMarker 'std::wstring CleanupHelperPath()'
Assert-OrderedMarkers $pruneSource @(
    'InspectExplorerA4SModules(ExplorerProcessId())',
    'if (!inspection.complete || inspection.unknownA4SModule)',
    'for (const std::wstring &mappedSlot : inspection.validatedSlots)',
    'AddUniquePath(protectedSlots, mappedSlot)',
    'RemoveKnownSlot(slot)') 'pruning retains every validated mapped slot'
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
    'WaitForSingleObject\(m_ExitEvent,(?<delay>[0-9]+)\)')
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
