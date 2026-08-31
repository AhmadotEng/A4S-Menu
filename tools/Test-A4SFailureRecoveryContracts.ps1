[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$harnessPath = Join-Path $PSScriptRoot 'Test-A4SFailureRecovery.ps1'
$hostPath = Join-Path $repoRoot 'Src\A4SMenu\Host\A4SMenuHost.cpp'
$identityPath = Join-Path $repoRoot 'Src\A4SMenu\Shared\A4SProductIdentity.h'

foreach ($path in @($harnessPath, $hostPath, $identityPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing failure/recovery contract input: $path"
    }
}

$harness = Get-Content -LiteralPath $harnessPath -Raw
$hostSource = Get-Content -LiteralPath $hostPath -Raw
$identity = Get-Content -LiteralPath $identityPath -Raw

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) { throw "A4S failure/recovery contract failed: $Message" }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Message
    )
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    Assert-Contract $threw $Message
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $harnessPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw ('A4S failure/recovery contract failed: the qualification harness does not parse: ' +
        (($parseErrors | ForEach-Object Message) -join '; '))
}

function Get-FunctionText {
    param([Parameter(Mandatory)][string] $Name)
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $Name
    }, $true)
    Assert-Contract ($null -ne $function) "missing function $Name"
    return $function.Extent.Text
}

function Assert-InOrder {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string[]] $Markers,
        [Parameter(Mandatory)][string] $Message
    )
    $cursor = -1
    foreach ($marker in $Markers) {
        $next = $Text.IndexOf($marker, $cursor + 1, [StringComparison]::Ordinal)
        if ($next -lt 0) { throw "A4S failure/recovery contract failed: $Message (missing '$marker')" }
        $cursor = $next
    }
}

# Static wiring contracts. These prove that the executable models below are
# represented by the real harness, while the models exercise negative cases
# without loading a host, touching registry state, or terminating Explorer.
Assert-Contract ($harness -match "CmdletBinding\(DefaultParameterSetName\s*=\s*'Offline'\)") `
    'default execution is not Offline'
$offlineDispatch = [Regex]::Match($harness,
    '(?s)if \(\$PSCmdlet\.ParameterSetName -eq ''Offline''\).*?\n\}\s*else \{').Value
Assert-Contract (-not [string]::IsNullOrWhiteSpace($offlineDispatch)) `
    'could not isolate the Offline dispatcher'
foreach ($forbidden in @('Initialize-A4SFailureRecoveryNative', 'Enter-A4SHarnessLease',
        'New-EvidenceBundle', 'Backup-HostSafety', 'Start-A4STestHost',
        'Request-ValidatedExplorerTermination', 'Remove-Item', 'New-Item')) {
    Assert-Contract ($offlineDispatch -notmatch [Regex]::Escape($forbidden)) `
        "Offline dispatch contains $forbidden"
}
Assert-Contract ($offlineDispatch -match 'Test-A4SFailureRecoveryContracts\.ps1') `
    'Offline dispatch does not run this companion gate'

foreach ($required in @('Initialize-A4SFailureRecoveryNative', 'Enter-A4SHarnessLease',
        'Exit-A4SHarnessLease', "'Isolated'", "'Live'", "'Recover'")) {
    Assert-Contract ($harness -match [Regex]::Escape($required)) `
        "executable dispatcher omits $required"
}
Assert-Contract ($harness -match '\[Environment\]::Is64BitProcess') `
    'executable and Recover modes do not enforce x64'
Assert-Contract ($harness -match 'Global\\A4SMenu\.FailureRecoveryHarness\.v2\.') `
    'harness lease is not same-user and cross-session'
Assert-Contract ($harness -match [Regex]::Escape(
    'I ACCEPT FOUR EXPLORER TERMINATIONS: THREE GUARDED CRASHES AND ONE CLEANUP RESTART')) `
    'live mode lacks exact high-friction consent'

foreach ($forbidden in @('Stop-Process', 'taskkill', 'Restart-Computer', 'Stop-Computer',
        '--rehook', 'build\stage\A4SProduct', '/y')) {
    Assert-Contract ($harness -notmatch [Regex]::Escape($forbidden)) `
        "harness contains forbidden primitive $forbidden"
}

$requestTermination = Get-FunctionText 'Request-ValidatedExplorerTermination'
$completeTermination = Get-FunctionText 'Complete-ValidatedExplorerTermination'
Assert-Contract (([Regex]::Matches($harness, '\.Kill\(\)')).Count -eq 1) `
    'Process.Kill must occur exactly once in the identity-validated request helper'
foreach ($required in @('Get-TaskbarExplorerIdentity', 'Assert-SameExplorerIdentity',
        'explorer.exe', 'SessionId', '.Kill()', 'killReturnedFileTimeUtc')) {
    Assert-Contract ($requestTermination -match [Regex]::Escape($required)) `
        "termination request omits $required"
}
Assert-Contract ($requestTermination -notmatch 'WaitForExit|Wait-ReplacementExplorer') `
    'termination request waits before callers can persist evidence'
Assert-Contract ($completeTermination -match 'WaitForExit') `
    'termination completion does not observe the exact killed process exit'

$isolated = Get-FunctionText 'Invoke-IsolatedDllFailureQualification'
foreach ($required in @("'missing'", "'corrupt'", "'incompatible'", 'Backup-HostSafety',
        'Restore-HostSafety', 'Assert-AllTrackedHostsStopped', 'Assert-NoA4SMapping',
        'retainedTemporaryRoot', 'cleanupInstructions', 'Get-BinaryBinding')) {
    Assert-Contract ($isolated -match [Regex]::Escape($required)) `
        "isolated qualification omits $required"
}
Assert-Contract ($isolated -notmatch 'Request-ValidatedExplorerTermination|\.Kill\(\)|Start-Process') `
    'isolated DLL qualification can terminate/restart Explorer'

$safePath = Get-FunctionText 'Get-CanonicalPathRecord'
$native = Get-FunctionText 'Initialize-A4SFailureRecoveryNative'
foreach ($required in @('GetFinalPathNameByHandleW', 'GetDriveTypeW', 'QueryDosDeviceW',
        'FILE_ATTRIBUTE_REPARSE_POINT', 'GetFileInformationByHandle',
        'Mapped, SUBST, or network drives are forbidden')) {
    Assert-Contract ($native -match [Regex]::Escape($required)) `
        "final-handle path implementation omits $required"
}
Assert-Contract ($safePath -match '8\.3 short-path aliases are forbidden|Assert-NoShortPathAlias') `
    'canonical path gate does not reject short aliases'
$tempCleanup = Get-FunctionText 'Remove-A4STemporaryRoot'
foreach ($required in @('Assert-SafeTemporaryRoot', 'Get-ChildItem',
        'Get-CanonicalPathRecord', 'Test-PathWithin')) {
    Assert-Contract ($tempCleanup -match $required) `
        "recursive cleanup omits $required"
}
Assert-Contract (([Regex]::Matches($harness, 'Remove-Item[^\r\n]+-Recurse')).Count -eq 1) `
    'recursive deletion exists outside the fully revalidated cleanup helper'

$newWrite = Get-FunctionText 'Write-DurableNewText'
$atomicWrite = Get-FunctionText 'Write-DurableText'
Assert-Contract ($newWrite -match 'FileMode\]::CreateNew' -and $newWrite -match 'Flush\(\$true\)') `
    'new recovery assets are not durable CreateNew files'
Assert-Contract ($atomicWrite -match 'Write-DurableNewText' -and
    $atomicWrite -match 'ReplaceFileAtomically') `
    'subsequent evidence checkpoints are not atomically replaced from CreateNew temporaries'

$backup = Get-FunctionText 'Backup-HostSafety'
$validateBackup = Get-FunctionText 'Read-ValidatedHostSafetyBackup'
$importBackup = Get-FunctionText 'Import-ValidatedHostSafetyBackup'
$restore = Get-FunctionText 'Restore-HostSafety'
foreach ($required in @('/reg:64', 'Registry64', 'HostSafetyBackup.json',
        'HostSafety.reg', 'Get-FileHash', 'Write-DurableNewText')) {
    Assert-Contract ($backup -match [Regex]::Escape($required)) `
        "backup omits $required"
}
foreach ($required in @('Assert-ExactPropertySet', 'Assert-ValidRegistryTree',
        'Assert-RegistryExportTargetsHostSafety', 'registryView', 'sha256',
        'bundleIdentity', 'manifestIdentity')) {
    Assert-Contract ($validateBackup -match [Regex]::Escape($required)) `
        "backup validation omits $required"
}
Assert-InOrder -Text $importBackup -Markers @('Read-ValidatedHostSafetyBackup',
    'Assert-AllTrackedHostsStopped', 'Remove-HostSafetyRegistryTree') `
    -Message 'import can delete HostSafety before final validation and host-stop proof'
foreach ($required in @('Rollback-', 'Backup-HostSafety',
        'Import-ValidatedHostSafetyBackup', 'transactional rollback')) {
    Assert-Contract ($restore -match [Regex]::Escape($required)) `
        "transactional restore omits $required"
}

$hostEnumeration = Get-FunctionText 'Get-SameUserA4SHostProcesses'
$allStopped = Get-FunctionText 'Assert-AllTrackedHostsStopped'
$exactResident = Get-FunctionText 'Assert-ExactResidentHost'
$noResident = Get-FunctionText 'Assert-NoResidentA4SHost'
$hostCommand = Get-FunctionText 'Invoke-A4SHostCommand'
$binaryBinding = Get-FunctionText 'Get-BinaryBinding'
foreach ($required in @('GetProcessOwnerSid', 'sessionId', 'startTimeUtc', 'sha256')) {
    Assert-Contract ($hostEnumeration -match $required) `
        "cross-session exact host enumeration omits $required"
}
foreach ($required in @('TrackedHosts', 'startTimeUtc', 'Assert-NoResidentA4SHost')) {
    Assert-Contract ($allStopped -match $required) `
        "tracked-host stop proof omits $required"
}
Assert-Contract ($exactResident -match 'GetHostWindowProcessId' -and
    $noResident -match 'GetHostWindowProcessId') `
    'exact/current-session singleton window checks are not paired with cross-session process checks'
Assert-Contract ($hostCommand -match 'Register-TrackedHost' -and
    $hostCommand -match 'Set-TrackedHostStopped') `
    'short-lived status/exit/toggle/version command hosts are not tracked through exit'
foreach ($required in @('sha256', 'fileVersion', 'productVersion',
        'reportedVersion', 'sourceCommit', 'pathIdentity')) {
    Assert-Contract ($binaryBinding -match $required) `
        "binary evidence binding omits $required"
}

$live = Get-FunctionText 'Invoke-LiveFailureRecoveryQualification'
Assert-InOrder -Text $live -Markers @('Backup-HostSafety',
    'Request-ValidatedExplorerTermination') `
    -Message 'live mode can terminate Explorer before durable recovery backup'
Assert-Contract (([Regex]::Matches($live, "sequence = 'post-kill-pre-wait'")).Count -eq 2) `
    'both guarded and cleanup terminations do not persist immediate pre-wait evidence'
Assert-Contract (([Regex]::Matches($live, 'Assert-RollingCrashGuardStage')).Count -eq 1) `
    'live loop does not use exact stage validation'
foreach ($required in @('-ExpectedCount $crashIndex', 'crashBoundaries',
        'PriorTimestamps', 'Get-BinaryBinding', 'sourceCommit',
        "status = 'manual-deferred'", 'mechanicalPassPermitted = $false')) {
    Assert-Contract ($live -match [Regex]::Escape($required) -or
        $harness -match [Regex]::Escape($required)) "live evidence omits $required"
}
Assert-Contract ($harness -notmatch "(?i)nativeStart[^\r\n]*(pass|verified)|native Start (available|verified)") `
    'native Start is mislabeled as a mechanical pass instead of manual/deferred'

Assert-Contract ($identity -match 'A4S_HOST_SAFETY_REGISTRY_W\s+L"Software\\\\A4SMenu\\\\HostSafety"') `
    'host and harness no longer agree on HostSafety target'
Assert-Contract ($hostSource -match 'constexpr DWORD kCrashLoopThreshold = 3;') `
    'host crash threshold is not three'
Assert-Contract ($hostSource -match 'constexpr ULONGLONG kCrashLoopWindow100ns = UINT64_C\(180\)') `
    'host rolling crash window is not 180 seconds'
$tryInject = [Regex]::Match($hostSource,
    '(?s)bool TryInject\(\)\s*\{.*?\n\s*\}\s*\n\s*void BeginConnection').Value
Assert-Contract (-not [string]::IsNullOrWhiteSpace($tryInject)) 'could not isolate host TryInject'
Assert-InOrder -Text $tryInject -Markers @('LoadProductDll()', 'FindValidatedExplorer',
    'SetWindowsHookExW') -Message 'host can select/hook Explorer before sibling DLL validation'
foreach ($abiCheck in @('A4S_DLL_GET_API_EXPORT_A', 'A4S_DLL_HOOK_INJECT_EXPORT_A',
        'api->abiVersion != A4S_MENU_ABI_VERSION',
        'api->productVersion != A4S_MENU_PRODUCT_VERSION')) {
    Assert-Contract ($hostSource -match [Regex]::Escape($abiCheck)) `
        "host DLL validation omits $abiCheck"
}

# Executable negative model: final-path policy. Each bad record must be rejected,
# including aliases that appear locally fixed before final-handle inspection.
function Test-PathPolicyModel {
    param([Parameter(Mandatory)][hashtable] $Record)
    if ($Record.requested -match '^\\\\' -or $Record.final -match '^\\\\') {
        throw 'network path'
    }
    if ($Record.requested -match '(?i)(^|\\)[^\\]*~[0-9]+(?:\\|$)' -or
        $Record.final -match '(?i)(^|\\)[^\\]*~[0-9]+(?:\\|$)') {
        throw 'short alias'
    }
    if ($Record.requested.TrimEnd('\') -ine $Record.final.TrimEnd('\')) { throw 'alias resolution' }
    if ($Record.driveType -ne 3) { throw 'not fixed' }
    if ($Record.reparse) { throw 'reparse' }
    if ($Record.device -notmatch '^\\Device\\HarddiskVolume' -or
        $Record.device -match '^\\\?\?\\|Mup|LanmanRedirector') { throw 'mapped device' }
    if ($Record.overlap) { throw 'overlap' }
    return $true
}

$validPath = @{ requested='C:\Data\A4S'; final='C:\Data\A4S'; driveType=3;
    reparse=$false; device='\Device\HarddiskVolume4'; overlap=$false }
Assert-Contract (Test-PathPolicyModel $validPath) 'valid local fixed path model failed'
$pathMutations = @(
    @{ requested='\\server\share\A4S'; final='\\server\share\A4S' },
    @{ requested='C:\DATA~1\A4S'; final='C:\DATA~1\A4S' },
    @{ requested='X:\A4S'; final='C:\Data\A4S' },
    @{ driveType=2 }, @{ reparse=$true }, @{ device='\??\C:\Data' },
    @{ device='\Device\Mup\server' }, @{ overlap=$true }
)
foreach ($mutation in $pathMutations) {
    $candidate = $validPath.Clone()
    foreach ($key in $mutation.Keys) { $candidate[$key] = $mutation[$key] }
    Assert-Throws { [void](Test-PathPolicyModel $candidate) } `
        "unsafe path model was accepted: $($mutation | ConvertTo-Json -Compress)"
}

# Executable negative model: validation must complete before a deletion token can
# be issued. It covers schema, hive/subkey/view, tree shape, export target, length,
# and hash rather than merely checking that those words appear in the harness.
function Invoke-BackupValidationModel {
    param(
        [Parameter(Mandatory)][hashtable] $Manifest,
        [Parameter(Mandatory)][hashtable] $Export,
        [Parameter(Mandatory)][ref] $DeletionCount
    )
    $expectedKeys = @('schemaVersion','registryHive','registrySubKey','registryView',
        'snapshot','exportPath','exportLength','exportSha256') | Sort-Object
    if ((@($Manifest.Keys | Sort-Object) -join ',') -cne ($expectedKeys -join ',')) { throw 'property set' }
    if ($Manifest.schemaVersion -ne 2 -or $Manifest.registryHive -cne 'HKEY_CURRENT_USER' -or
        $Manifest.registrySubKey -cne 'Software\A4SMenu\HostSafety' -or
        $Manifest.registryView -cne 'Registry64') { throw 'target/view' }
    if ($Manifest.snapshot.exists -isnot [bool] -or $Manifest.snapshot.values -isnot [array]) {
        throw 'snapshot shape'
    }
    if ($Manifest.exportPath -cne 'HostSafety.reg' -or
        $Export.target -cne 'HKEY_CURRENT_USER\Software\A4SMenu\HostSafety' -or
        $Export.length -ne $Manifest.exportLength -or
        $Export.sha256 -cne $Manifest.exportSha256) { throw 'export integrity' }
    $DeletionCount.Value++
}

$validManifest = @{
    schemaVersion=2; registryHive='HKEY_CURRENT_USER';
    registrySubKey='Software\A4SMenu\HostSafety'; registryView='Registry64';
    snapshot=@{ exists=$true; values=@() }; exportPath='HostSafety.reg';
    exportLength=44; exportSha256=('A' * 64)
}
$validExport = @{ target='HKEY_CURRENT_USER\Software\A4SMenu\HostSafety';
    length=44; sha256=('A' * 64) }
$deletes = 0
Invoke-BackupValidationModel $validManifest $validExport ([ref]$deletes)
Assert-Contract ($deletes -eq 1) 'valid backup model did not reach deletion boundary'
foreach ($negative in @(
    @{ manifest=@{ registryView='Registry32' }; export=@{} },
    @{ manifest=@{ registrySubKey='Software\A4SMenu\Other' }; export=@{} },
    @{ manifest=@{ schemaVersion=1 }; export=@{} },
    @{ manifest=@{ snapshot=@{exists='yes';values=@()} }; export=@{} },
    @{ manifest=@{ snapshot=@{exists=$true;values='not-an-array'} }; export=@{} },
    @{ manifest=@{ exportPath='..\Other.reg' }; export=@{} },
    @{ manifest=@{ unexpected='field' }; export=@{} },
    @{ manifest=@{}; export=@{ target='HKEY_CURRENT_USER\Software\Other' } },
    @{ manifest=@{}; export=@{ length=45 } },
    @{ manifest=@{}; export=@{ sha256=('B' * 64) } }
)) {
    $manifest = $validManifest.Clone()
    $export = $validExport.Clone()
    foreach ($key in $negative.manifest.Keys) { $manifest[$key] = $negative.manifest[$key] }
    foreach ($key in $negative.export.Keys) { $export[$key] = $negative.export[$key] }
    $negativeDeletes = 0
    Assert-Throws { Invoke-BackupValidationModel $manifest $export ([ref]$negativeDeletes) } `
        'malformed backup model was accepted'
    Assert-Contract ($negativeDeletes -eq 0) `
        'malformed backup model reached deletion before validation'
}

function Invoke-RestoreTransactionModel {
    param([Parameter(Mandatory)][bool] $PrimarySucceeds)
    $state = 'pre-restore'
    $rollback = $state
    try {
        $state = 'deleted'
        if (-not $PrimarySucceeds) { throw 'primary import failed' }
        $state = 'desired'
    }
    catch { $state = $rollback }
    return $state
}
Assert-Contract ((Invoke-RestoreTransactionModel $true) -ceq 'desired') `
    'successful transaction model did not apply desired state'
Assert-Contract ((Invoke-RestoreTransactionModel $false) -ceq 'pre-restore') `
    'failed transaction model did not roll back exact pre-restore state'

# Executable negative model: every tracked host and every same-user resident host,
# including another Windows session, blocks recovery.
function Test-HostStopModel {
    param([object[]] $Tracked, [object[]] $Residents)
    if (@($Tracked | Where-Object { -not $_.stopped }).Count -ne 0) { throw 'tracked host active' }
    if (@($Residents | Where-Object { $_.sameUser }).Count -ne 0) { throw 'same-user resident host' }
    return $true
}
Assert-Contract (Test-HostStopModel @(@{stopped=$true}) @()) 'stopped-host model failed'
Assert-Throws { [void](Test-HostStopModel @(@{stopped=$false}) @()) } `
    'unproven tracked host did not block recovery'
Assert-Throws { [void](Test-HostStopModel @(@{stopped=$true}) `
    @(@{sameUser=$true; sessionId=99})) } `
    'same-user host in another session did not block recovery'

function Assert-ExactHostModel {
    param([hashtable] $Expected, [object[]] $Residents, [int] $SingletonPid)
    if ($Residents.Count -ne 1) { throw 'host count' }
    $actual = $Residents[0]
    foreach ($field in @('pid','path','sha256','startTimeUtc')) {
        if ([string]$actual[$field] -cne [string]$Expected[$field]) { throw "host $field" }
    }
    if ($SingletonPid -ne $Expected.pid) { throw 'singleton PID' }
}
$expectedHost = @{pid=40;path='C:\A4S\A4SMenuHost.exe';sha256=('C' * 64);
    startTimeUtc='2026-09-01T00:00:00.0000000Z'}
Assert-ExactHostModel $expectedHost @($expectedHost.Clone()) 40
foreach ($mutation in @(
    @{pid=41}, @{path='C:\Other\A4SMenuHost.exe'}, @{sha256=('D' * 64)},
    @{startTimeUtc='2026-09-01T00:00:01.0000000Z'}
)) {
    $actual = $expectedHost.Clone()
    foreach ($key in $mutation.Keys) { $actual[$key] = $mutation[$key] }
    Assert-Throws { Assert-ExactHostModel $expectedHost @($actual) 40 } `
        'wrong exact-host identity was accepted'
}
Assert-Throws { Assert-ExactHostModel $expectedHost @($expectedHost.Clone()) 41 } `
    'wrong singleton PID was accepted'
Assert-Throws { Assert-ExactHostModel $expectedHost @(
    $expectedHost.Clone(), $expectedHost.Clone()) 40 } `
    'duplicate same-user host was accepted'

function Enter-LeaseModel {
    param([hashtable] $Owners, [string] $UserSid)
    $name = 'Global\A4SMenu.FailureRecoveryHarness.v2.' + $UserSid
    if ($Owners.ContainsKey($name)) { throw 'lease held' }
    $Owners[$name] = $true
    return $name
}
$leases = @{}
$leaseName = Enter-LeaseModel $leases 'S-1-5-21-100'
Assert-Throws { [void](Enter-LeaseModel $leases 'S-1-5-21-100') } `
    'second harness for the same user acquired the cross-session lease'
Assert-Contract ((Enter-LeaseModel $leases 'S-1-5-21-200') -cne $leaseName) `
    'per-user lease model did not isolate different users'

function New-RecoveryAssetModel {
    param([Collections.Generic.HashSet[string]] $Assets, [string] $Name)
    if (-not $Assets.Add($Name)) { throw 'overwrite' }
}
$assets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
New-RecoveryAssetModel $assets 'HostSafetyBackup.json'
Assert-Throws { New-RecoveryAssetModel $assets 'HOSTSAFETYBACKUP.JSON' } `
    'case-insensitive recovery asset overwrite was accepted instead of CreateNew'

# Executable negative model: evidence must be committed after Kill and before
# waiting/replacement, and all 1/2/3 guard stages must map to their own bounds.
function Assert-TerminationSequenceModel {
    param([string[]] $Events)
    $expected = @('kill-returned','evidence-durable','wait-exit','replacement-observed')
    if (($Events -join ',') -cne ($expected -join ',')) { throw 'event ordering' }
}
Assert-TerminationSequenceModel @('kill-returned','evidence-durable','wait-exit','replacement-observed')
Assert-Throws { Assert-TerminationSequenceModel @(
    'kill-returned','wait-exit','evidence-durable','replacement-observed') } `
    'wait-before-evidence sequence was accepted'

function Assert-GuardStagesModel {
    param([object[]] $Stages)
    for ($index=0; $index -lt 3; $index++) {
        $expected = $index + 1
        $stage = $Stages[$index]
        if ($stage.count -ne $expected -or $stage.disabled -ne ($expected -eq 3) -or
            $stage.times.Count -ne $expected) { throw 'stage count/disable' }
        for ($timeIndex=0; $timeIndex -lt $expected; $timeIndex++) {
            if ($stage.times[$timeIndex] -lt $stage.bounds[$timeIndex].issued -or
                $stage.times[$timeIndex] -gt $stage.bounds[$timeIndex].observed) {
                throw 'timestamp boundary'
            }
        }
    }
}
$bounds = @(@{issued=10;observed=19}, @{issued=20;observed=29}, @{issued=30;observed=39})
$validStages = @(
    @{count=1;disabled=$false;times=@(15);bounds=@($bounds[0])},
    @{count=2;disabled=$false;times=@(15,25);bounds=@($bounds[0..1])},
    @{count=3;disabled=$true;times=@(15,25,35);bounds=@($bounds)}
)
Assert-GuardStagesModel $validStages
$badStages = @($validStages | ForEach-Object { $_.Clone() })
$badStages[1].count = 3
Assert-Throws { Assert-GuardStagesModel $badStages } `
    'incorrect 1/2/3 guard count was accepted'
$badTimes = @($validStages | ForEach-Object { $_.Clone() })
$badTimes[2].times = @(15,25,45)
Assert-Throws { Assert-GuardStagesModel $badTimes } `
    'out-of-bound crash timestamp was accepted'

function Get-CleanupDecisionModel {
    param([bool] $AllHostsStopped, [bool] $MappingInspectionSucceeded,
        [int] $MappingCount, [int] $WindowCount, [bool] $SafetyRestored)
    return $AllHostsStopped -and $MappingInspectionSucceeded -and
        $MappingCount -eq 0 -and $WindowCount -eq 0 -and $SafetyRestored
}
Assert-Contract (Get-CleanupDecisionModel $true $true 0 0 $true) `
    'conclusive cleanup model did not allow deletion'
foreach ($arguments in @(
    @($false,$true,0,0,$true), @($true,$false,0,0,$true),
    @($true,$true,1,0,$true), @($true,$true,0,1,$true),
    @($true,$true,0,0,$false)
)) {
    Assert-Contract (-not (Get-CleanupDecisionModel @arguments)) `
        'inconclusive/pinned cleanup model allowed deletion'
}

function Assert-NativeStartLabelModel {
    param([hashtable] $Observation)
    if ($Observation.status -cne 'manual-deferred' -or
        $Observation.mechanicalPassPermitted) { throw 'native Start overclaim' }
}
Assert-NativeStartLabelModel @{status='manual-deferred';mechanicalPassPermitted=$false}
Assert-Throws { Assert-NativeStartLabelModel @{status='pass';mechanicalPassPermitted=$true} } `
    'native Start mechanical pass label was accepted'

Write-Host 'A4S failure/recovery offline contracts passed: parser/static wiring plus executable negative models for paths, recovery integrity/rollback, host leases, event evidence, exact 1/2/3 guard stages, cleanup retention, and manual native-Start labeling.'
