[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$harnessPath = Join-Path $PSScriptRoot 'Test-A4SFailureRecovery.ps1'
$hostPath = Join-Path $repoRoot 'Src\A4SMenu\Host\A4SMenuHost.cpp'
$identityPath = Join-Path $repoRoot 'Src\A4SMenu\Shared\A4SProductIdentity.h'
$setupPath = Join-Path $repoRoot 'Src\A4SMenu\Setup\A4SMenuSetup.cpp'

foreach ($path in @($harnessPath, $hostPath, $identityPath, $setupPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing failure/recovery contract input: $path"
    }
}

$harness = Get-Content -LiteralPath $harnessPath -Raw
$hostSource = Get-Content -LiteralPath $hostPath -Raw
$identity = Get-Content -LiteralPath $identityPath -Raw
$setupSource = Get-Content -LiteralPath $setupPath -Raw

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
        if ($next -lt 0) {
            throw "A4S failure/recovery contract failed: $Message (missing '$marker')"
        }
        $cursor = $next
    }
}

# Load the harness itself as a side-effect-free function library. Every executable
# negative case below calls the same validator used by Isolated/Live/Recover; no
# duplicate toy schema or transaction model is allowed here.
$library = New-Module -Name A4SFailureRecoveryContractLibrary -ScriptBlock {
    param([string] $Path)
    . $Path -ContractLibrary
} -ArgumentList $harnessPath

try {
    Assert-Contract ($harness -match "CmdletBinding\(DefaultParameterSetName\s*=\s*'Offline'\)") `
        'default execution is not Offline'
    Assert-InOrder -Text $harness -Markers @(
        "if (`$PSCmdlet.ParameterSetName -eq 'ContractLibrary')",
        "elseif (`$PSCmdlet.ParameterSetName -eq 'Offline')",
        'Initialize-A4SFailureRecoveryNative') `
        -Message 'the safe ContractLibrary/Offline dispatch does not precede executable setup'
    $offlineDispatch = [Regex]::Match($harness,
        '(?s)elseif \(\$PSCmdlet\.ParameterSetName -eq ''Offline''\).*?\n\}\s*else \{').Value
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
            '--rehook', 'build\stage\A4SProduct', '/y', 'reg.exe import')) {
        Assert-Contract ($harness -notmatch [Regex]::Escape($forbidden)) `
            "harness contains forbidden primitive $forbidden"
    }

    $requestTermination = Get-FunctionText 'Request-ValidatedExplorerTermination'
    $completeTermination = Get-FunctionText 'Complete-ValidatedExplorerTermination'
    $terminationGate = Get-FunctionText 'Assert-TerminationRequestReadyForWait'
    Assert-Contract (([Regex]::Matches($harness, '\.Kill\(\)')).Count -eq 1) `
        'Process.Kill must occur exactly once in the identity-validated request helper'
    foreach ($required in @('Get-TaskbarExplorerIdentity', 'Assert-SameExplorerIdentity',
            'explorer.exe', 'SessionId', '.Kill()', 'killReturnedFileTimeUtc',
            'evidencePersisted = $false')) {
        Assert-Contract ($requestTermination -match [Regex]::Escape($required)) `
            "termination request omits $required"
    }
    Assert-Contract ($requestTermination -notmatch 'WaitForExit|Wait-ReplacementExplorer') `
        'termination request waits before callers can persist evidence'
    Assert-InOrder -Text $completeTermination -Markers @(
        'Assert-TerminationRequestReadyForWait', 'WaitForExit') `
        -Message 'termination completion can wait before validating durable evidence'
    Assert-Contract ($terminationGate -match 'evidencePersisted') `
        'termination wait validator does not require persisted evidence'

    $isolated = Get-FunctionText 'Invoke-IsolatedDllFailureQualification'
    foreach ($required in @("'missing'", "'corrupt'", "'incompatible'", 'Backup-HostSafety',
            'Restore-HostSafety', 'Assert-AllTrackedHostsStopped', 'Assert-NoA4SMapping',
            'Set-RetainedTemporaryRootEvidence', 'Get-BinaryBinding')) {
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
        Assert-Contract ($tempCleanup -match $required) "recursive cleanup omits $required"
    }
    Assert-Contract (([Regex]::Matches($harness, 'Remove-Item[^\r\n]+-Recurse')).Count -eq 1) `
        'recursive deletion exists outside the fully revalidated cleanup helper'

    $backup = Get-FunctionText 'Backup-HostSafety'
    $validateBackup = Get-FunctionText 'Read-ValidatedHostSafetyBackup'
    $restore = Get-FunctionText 'Restore-HostSafety'
    $restoreStep = Get-FunctionText 'Invoke-AuthorizedHostSafetyMutationStep'
    $exactRestore = Get-FunctionText 'Set-HostSafetySnapshotExactly'
    foreach ($required in @('/reg:64', 'Registry64', 'HostSafetyBackup.json',
            'HostSafety.reg', 'snapshotSha256', 'schemaVersion = 3',
            'Get-FileHash', 'Write-DurableNewText')) {
        Assert-Contract ($backup -match [Regex]::Escape($required)) "backup omits $required"
    }
    foreach ($required in @('Assert-ExactPropertySet', 'Assert-ValidRegistryTree',
            'Assert-RegistryExportTargetsHostSafety', 'snapshotSha256', 'registryView',
            'sha256', 'bundleIdentity', 'manifestIdentity')) {
        Assert-Contract ($validateBackup -match [Regex]::Escape($required)) `
            "backup validation omits $required"
    }
    Assert-InOrder -Text $restore -Markers @(
        'Read-ValidatedHostSafetyBackup', 'Enter-A4SProductMutationBoundary',
        'Get-HostSafetyAggregateRecord', 'Assert-AuthorizedHostSafetyAggregate',
        'Backup-HostSafety', 'Set-HostSafetySnapshotExactly') `
        -Message 'restore does not authorize the immediate aggregate under product locks before mutation'
    foreach ($required in @('AuthorizedCurrentSha256', 'rollback',
            'Get-KnownMutationAggregate', 'unknown/intervening', 'Exit-A4SProductMutationBoundary')) {
        Assert-Contract ($restore -match [Regex]::Escape($required)) `
            "transactional restore omits $required"
    }
    Assert-InOrder -Text $restoreStep -Markers @(
        'Assert-A4SProductMutationBoundary', 'Get-HostSafetyAggregateRecord',
        'Assert-AuthorizedHostSafetyAggregate', '& $Mutation',
        'Get-HostSafetyAggregateRecord', 'Assert-AuthorizedHostSafetyAggregate') `
        -Message 'an exact registry step is not compare-and-swap guarded before and after mutation'
    Assert-Contract ($exactRestore -match 'Remove-HostSafetyRegistryTree' -and
        $exactRestore -match 'Invoke-AuthorizedHostSafetyMutationStep') `
        'exact restore can delete outside the authorized mutation-step gate'

    foreach ($required in @('AcquireProductMutationBoundary', 'SetupMutexName',
            'HostMutexName', 'SHA256.Create', '14695981039346656037UL',
            'GetUserObjectInformationW', 'Process.GetCurrentProcess().SessionId')) {
        Assert-Contract ($native -match [Regex]::Escape($required)) `
            "native mutation boundary omits $required"
    }
    Assert-Contract ($setupSource -match 'Global\\\\A4SMenu\.Setup\.v1\.' -and
        $setupSource -match 'GetLengthSid' -and $setupSource -match 'HashBytes') `
        'harness servicing mutex no longer matches Setup ownership'
    Assert-Contract ($identity -match 'A4S_HOST_MUTEX_PREFIX_W\s+L"Local\\\\A4SMenu\.Host\.Instance\.v1"') `
        'harness host mutex prefix no longer matches product identity'
    foreach ($required in @('BuildInstanceMutexName', 'GetLengthSid',
            'GetUserObjectInformationW', 'ProcessIdToSessionId', 'HashBytes')) {
        Assert-Contract ($hostSource -match [Regex]::Escape($required)) `
            "host instance mutex construction omits $required"
    }

    $hostEnumeration = Get-FunctionText 'Get-SameUserA4SHostProcesses'
    $allStopped = Get-FunctionText 'Assert-AllTrackedHostsStopped'
    $exactResident = Get-FunctionText 'Assert-ExactResidentHost'
    $exactObservation = Get-FunctionText 'Assert-ExactHostObservation'
    $noResident = Get-FunctionText 'Assert-NoResidentA4SHost'
    foreach ($required in @('GetProcessOwnerSid', 'sessionId', 'startTimeUtc', 'sha256')) {
        Assert-Contract ($hostEnumeration -match $required) `
            "cross-session exact host enumeration omits $required"
    }
    foreach ($required in @('TrackedHosts', 'startTimeUtc', 'Assert-NoResidentA4SHost')) {
        Assert-Contract ($allStopped -match $required) "tracked-host stop proof omits $required"
    }
    Assert-Contract ($exactResident -match 'Assert-ExactHostObservation' -and
        $exactObservation -match 'sessionId' -and $exactObservation -match 'sha256' -and
        $noResident -match 'GetHostWindowProcessId') `
        'real exact-host identity validator is not wired to resident/singleton checks'

    $newEvidence = Get-FunctionText 'New-EvidenceBundle'
    $binaryBinding = Get-FunctionText 'Get-BinaryBinding'
    $readRelease = Get-FunctionText 'Read-VerifiedA4SReleaseRecord'
    $live = Get-FunctionText 'Invoke-LiveFailureRecoveryQualification'
    foreach ($required in @("sourceBinding = 'unverified'", 'verifiedSourceCommit = $null',
            'repositoryHead = $repositoryHead', 'releaseRecord = $null')) {
        Assert-Contract ($newEvidence -match [Regex]::Escape($required)) `
            "unverified evidence labeling omits $required"
    }
    Assert-Contract ($newEvidence -notmatch 'sourceCommit\s*=\s*\$repositoryHead') `
        'repository HEAD is falsely asserted as binary source provenance'
    foreach ($required in @('sha256', 'fileVersion', 'reportedVersion',
            'sourceBinding', 'verifiedSourceCommit', 'pathIdentity')) {
        Assert-Contract ($binaryBinding -match $required) "binary evidence binding omits $required"
    }
    foreach ($required in @('Assert-ValidA4SReleaseRecord', 'ls-files', 'cat-file',
            'merge-base', 'rev-parse', 'hash-object', 'recordCommit', 'recordBlob')) {
        Assert-Contract ($readRelease -match [Regex]::Escape($required)) `
            "immutable release-record validation omits $required"
    }
    Assert-InOrder -Text $live -Markers @(
        'Read-VerifiedA4SReleaseRecord', 'Get-BinaryBinding',
        'Assert-BinaryBindingsMatchReleaseRecord',
        "sourceBinding = 'verified-release-record'", 'Save-Evidence',
        'Request-ValidatedExplorerTermination') `
        -Message 'live mode can crash Explorer before verified binary/source binding is persisted'
    Assert-Contract ($harness -match [Regex]::Escape(
        '[Parameter(Mandatory, ParameterSetName = ''Live'')]') -and
        $harness -match '\[string\] \$ReleaseRecordPath') `
        'live gate does not require a release-record path'

    Assert-InOrder -Text $live -Markers @('Backup-HostSafety',
        'Request-ValidatedExplorerTermination') `
        -Message 'live mode can terminate Explorer before durable recovery backup'
    Assert-Contract (([Regex]::Matches($live, "sequence = 'post-kill-pre-wait'")).Count -eq 2) `
        'both guarded and cleanup terminations do not persist immediate pre-wait evidence'
    Assert-Contract (([Regex]::Matches($live, 'evidencePersisted = \$true')).Count -eq 2) `
        'both termination requests are not unlocked only after durable evidence'
    Assert-Contract ($live -notmatch '\$crashIndex -eq 1') `
        'one-menu reconnect testing is still limited to only the first crash'
    Assert-Contract (([Regex]::Matches($live, 'Invoke-OneMenuAssertion')).Count -eq 3) `
        'initial READY, every READY reconnect, and reset recovery are not all one-menu tested'
    Assert-Contract (([Regex]::Matches($live, 'Assert-A4SReadyBoundary')).Count -ge 4) `
        'READY boundaries do not all carry exact mapping and host uniqueness proof'
    Assert-Contract ($live -match 'Assert-A4SSafetyDisabledBoundary') `
        'third-crash safety-disabled boundary lacks exact zero mapping and host proof'
    $oneMenu = Get-FunctionText 'Invoke-OneMenuAssertion'
    foreach ($required in @('Assert-A4SReadyBoundary', 'exactWindowCount = 1',
            'exactMappingCount = 1', 'exactHostCount = 1',
            'oneMenuOneHookObservable = $true')) {
        Assert-Contract ($oneMenu -match [Regex]::Escape($required)) `
            "one-menu/one-hook observable omits $required"
    }

    $retention = Get-FunctionText 'Set-RetainedTemporaryRootEvidence'
    foreach ($required in @('retainedTemporaryRoot', 'retentionReason',
            'cleanupInstructions', 'authorizedCurrentHostSafetySha256', 'Save-Evidence')) {
        Assert-Contract ($retention -match $required) "retention evidence omits $required"
    }
    Assert-Contract (([Regex]::Matches($isolated,
        'Set-RetainedTemporaryRootEvidence')).Count -ge 3) `
        'isolated cleanup does not persist retention before and after cleanup failure'
    Assert-Contract (([Regex]::Matches($live,
        'Set-RetainedTemporaryRootEvidence')).Count -ge 3) `
        'live cleanup does not persist retention before and after cleanup failure'
    Assert-Contract ($harness -match '-ExpectedCurrentHostSafetySha256' -and
        $harness -match '-AuthorizedCurrentSha256 \$ExpectedCurrentHostSafetySha256') `
        'manual recovery lacks explicit immediate aggregate authorization'

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

    # Actual path predicates.
    Assert-Contract (& $library {
        Test-PathsOverlap -First 'C:\A4S\root' -Second 'c:\a4s\root\child'
    }) 'real overlap predicate rejected a nested path'
    Assert-Contract (-not (& $library {
        Test-PathsOverlap -First 'C:\A4S\one' -Second 'C:\A4S\two'
    })) 'real overlap predicate accepted siblings'
    Assert-Throws { & $library { Assert-NoShortPathAlias -Path 'C:\PROGRA~1\A4S' } } `
        'real short-alias validator accepted an 8.3 path'

    # Actual registry-tree, aggregate authorization, and rollback-known-state validators.
    $validTree = [pscustomobject][ordered]@{
        exists = $true
        values = @([pscustomobject][ordered]@{ name='InjectionDisabled'; kind='DWord'; value=0 })
        subkeys = @()
    }
    & $library { param($tree) Assert-ValidRegistryTree -Tree $tree -IsRoot $true } $validTree
    $duplicateTree = $validTree | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $duplicateTree.values = @($duplicateTree.values[0], $duplicateTree.values[0])
    Assert-Throws {
        & $library { param($tree) Assert-ValidRegistryTree -Tree $tree -IsRoot $true } $duplicateTree
    } 'real registry-tree validator accepted duplicate value names'
    $badTree = $validTree | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $badTree.values[0].kind = 'AlienKind'
    Assert-Throws {
        & $library { param($tree) Assert-ValidRegistryTree -Tree $tree -IsRoot $true } $badTree
    } 'real registry-tree validator accepted an unsupported kind'
    $unknownTree = $validTree | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $unknownTree.values[0].kind = 'Unknown'
    Assert-Throws {
        & $library { param($tree) Assert-ValidRegistryTree -Tree $tree -IsRoot $true } $unknownTree
    } 'real registry-tree validator accepted an unrestorable unknown value kind'

    $authorized = & $library { param($tree) Get-HostSafetyAggregateRecord -Snapshot $tree } $validTree
    [void](& $library {
        param($aggregate, $tree)
        Assert-AuthorizedHostSafetyAggregate -Current $aggregate `
            -ExpectedSnapshot $tree -ExpectedSha256 $aggregate.sha256 -Boundary 'contract'
    } $authorized $validTree)
    [void](& $library {
        param($aggregate)
        Assert-AuthorizedHostSafetyAggregate -Current $aggregate `
            -ExpectedSha256 $aggregate.sha256 -Boundary 'contract hash-only recovery'
    } $authorized)
    $intervening = $validTree | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $intervening.values[0].value = 1
    $interveningAggregate = & $library {
        param($tree) Get-HostSafetyAggregateRecord -Snapshot $tree
    } $intervening
    Assert-Throws {
        & $library {
            param($current, $expected, $hash)
            Assert-AuthorizedHostSafetyAggregate -Current $current `
                -ExpectedSnapshot $expected -ExpectedSha256 $hash -Boundary 'contract intervention'
        } $interveningAggregate $validTree $authorized.sha256
    } 'real aggregate authorization accepted intervening HostSafety state'
    $knownState = [pscustomobject][ordered]@{ allowed=@($authorized); inFlight=$false }
    [void](& $library {
        param($state, $current)
        Get-KnownMutationAggregate -MutationState $state -Current $current -Boundary 'known'
    } $knownState $authorized)
    Assert-Throws {
        & $library {
            param($state, $current)
            Get-KnownMutationAggregate -MutationState $state -Current $current -Boundary 'unknown'
        } $knownState $interveningAggregate
    } 'real rollback gate accepted an unknown/intervening aggregate'

    # Actual immutable-record and binary-binding validators.
    $releaseRecord = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'A4SMenu'
        sourceCommit = ('a' * 40)
        hostSha256 = ('B' * 64)
        dllSha256 = ('C' * 64)
        hostFileVersion = '1.2.3.4'
        dllFileVersion = '1.2.3.4'
        hostReportedVersion = 'A4SMenuHost 1.2.3.4'
    }
    [void](& $library {
        param($record) Assert-ValidA4SReleaseRecord -Record $record
    } $releaseRecord)
    $release = [pscustomobject]@{ record=$releaseRecord }
    $hostBinding = [pscustomobject]@{
        sha256=('B' * 64); fileVersion='1.2.3.4'; reportedVersion='A4SMenuHost 1.2.3.4'
    }
    $dllBinding = [pscustomobject]@{ sha256=('C' * 64); fileVersion='1.2.3.4' }
    [void](& $library {
        param($release, $host, $dll)
        Assert-BinaryBindingsMatchReleaseRecord -Release $release -Host $host -Dll $dll
    } $release $hostBinding $dllBinding)
    $badRecord = $releaseRecord | ConvertTo-Json | ConvertFrom-Json
    $badRecord.hostSha256 = 'not-a-hash'
    Assert-Throws {
        & $library { param($record) Assert-ValidA4SReleaseRecord -Record $record } $badRecord
    } 'real release-record validator accepted a malformed hash'
    $extraRecord = $releaseRecord | ConvertTo-Json | ConvertFrom-Json
    $extraRecord | Add-Member -NotePropertyName untrusted -NotePropertyValue $true
    Assert-Throws {
        & $library { param($record) Assert-ValidA4SReleaseRecord -Record $record } $extraRecord
    } 'real release-record validator accepted an untrusted extra property'
    $badHostBinding = $hostBinding | ConvertTo-Json | ConvertFrom-Json
    $badHostBinding.sha256 = ('D' * 64)
    Assert-Throws {
        & $library {
            param($release, $host, $dll)
            Assert-BinaryBindingsMatchReleaseRecord -Release $release -Host $host -Dll $dll
        } $release $badHostBinding $dllBinding
    } 'real release binding accepted the wrong host binary'

    # Actual exact-host identity validator.
    $expectedHost = [pscustomobject]@{
        pid=40; sessionId=2; path='C:\A4S\A4SMenuHost.exe'; sha256=('E' * 64)
        startTimeUtc='2026-09-01T00:00:00.0000000Z'
    }
    [void](& $library {
        param($expected)
        Assert-ExactHostObservation -Expected $expected -Residents @($expected) `
            -SingletonPid 40 -Label 'contract exact host'
    } $expectedHost)
    $wrongHost = $expectedHost | ConvertTo-Json | ConvertFrom-Json
    $wrongHost.sessionId = 99
    Assert-Throws {
        & $library {
            param($expected, $actual)
            Assert-ExactHostObservation -Expected $expected -Residents @($actual) `
                -SingletonPid 40 -Label 'contract wrong host'
        } $expectedHost $wrongHost
    } 'real exact-host validator accepted the wrong session'
    Assert-Throws {
        & $library {
            param($expected)
            Assert-ExactHostObservation -Expected $expected -Residents @($expected, $expected) `
                -SingletonPid 40 -Label 'contract duplicate host'
        } $expectedHost
    } 'real exact-host validator accepted duplicate same-user hosts'
    Assert-Throws {
        & $library {
            param($expected)
            Assert-ExactHostObservation -Expected $expected -Residents @($expected) `
                -SingletonPid 41 -Label 'contract wrong singleton'
        } $expectedHost
    } 'real exact-host validator accepted the wrong singleton PID'

    # Actual post-kill durable-evidence gate.
    $validTermination = [pscustomobject]@{
        oldExplorer=[pscustomobject]@{pid=400}; issuedFileTimeUtc=[uint64]10
        killReturnedFileTimeUtc=[uint64]11; evidencePersisted=$true
    }
    [void](& $library {
        param($request) Assert-TerminationRequestReadyForWait -Request $request
    } $validTermination)
    $missingEvidence = $validTermination | ConvertTo-Json | ConvertFrom-Json
    $missingEvidence.evidencePersisted = $false
    Assert-Throws {
        & $library {
            param($request) Assert-TerminationRequestReadyForWait -Request $request
        } $missingEvidence
    } 'real termination gate accepted wait-before-evidence'
    $badOrder = $validTermination | ConvertTo-Json | ConvertFrom-Json
    $badOrder.killReturnedFileTimeUtc = 9
    Assert-Throws {
        & $library {
            param($request) Assert-TerminationRequestReadyForWait -Request $request
        } $badOrder
    } 'real termination gate accepted kill-returned before issued'

    # Actual cleanup authorization predicate.
    Assert-Contract (& $library {
        Test-A4STemporaryCleanupAllowed -AllHostsStopped $true `
            -MappingInspectionSucceeded $true -MappingCount 0 -WindowCount 0 `
            -SafetyRestored $true -CleanupRestartRequired $true -CleanupRestartComplete $true
    }) 'real conclusive cleanup predicate denied deletion'
    foreach ($arguments in @(
        @($false,$true,0,0,$true,$true), @($true,$false,0,0,$true,$true),
        @($true,$true,1,0,$true,$true), @($true,$true,0,1,$true,$true),
        @($true,$true,0,0,$false,$true), @($true,$true,0,0,$true,$false)
    )) {
        $values = @($arguments)
        $decision = & $library {
            param($allStopped, $inspected, $mappingCount, $windowCount,
                $restored, $restartComplete)
            Test-A4STemporaryCleanupAllowed -AllHostsStopped $allStopped `
                -MappingInspectionSucceeded $inspected -MappingCount $mappingCount `
                -WindowCount $windowCount -SafetyRestored $restored `
                -CleanupRestartRequired $true -CleanupRestartComplete $restartComplete
        } ($values[0]) ($values[1]) ($values[2]) ($values[3]) ($values[4]) ($values[5])
        Assert-Contract (-not $decision) `
            'real inconclusive/pinned cleanup predicate allowed deletion'
    }

    # Actual 1/2/3 rolling crash-stage validator.
    function New-CrashGuardFixture {
        param([int] $Count, [bool] $Disabled, [uint64[]] $Times)
        $bytes = [byte[]]::new(24)
        for ($index = 0; $index -lt $Times.Count; $index++) {
            [BitConverter]::GetBytes([uint64]$Times[$index]).CopyTo($bytes, $index * 8)
        }
        return [pscustomobject][ordered]@{
            exists=$true
            values=@(
                [pscustomobject]@{name='InjectionDisabled';kind='DWord';value=$(if ($Disabled) {1} else {0})},
                [pscustomobject]@{name='AbnormalExplorerExitCount';kind='DWord';value=$Count},
                [pscustomobject]@{name='AbnormalExplorerExitTimes';kind='Binary';value=[Convert]::ToBase64String($bytes)},
                [pscustomobject]@{name='LastExplorerExitCode';kind='DWord';value=1}
            )
            subkeys=@()
        }
    }
    $bounds = @(
        [pscustomobject]@{issuedFileTimeUtc=[uint64]10;observedFileTimeUtc=[uint64]19},
        [pscustomobject]@{issuedFileTimeUtc=[uint64]20;observedFileTimeUtc=[uint64]29},
        [pscustomobject]@{issuedFileTimeUtc=[uint64]30;observedFileTimeUtc=[uint64]39}
    )
    [uint64[]]$prior = @()
    foreach ($stage in 1..3) {
        [uint64[]]$times = @(15,25,35 | Select-Object -First $stage)
        $result = & $library {
            param($snapshot, $count, $disabled, $boundaries, $priorTimes)
            Assert-RollingCrashGuardStage -Snapshot $snapshot -ExpectedCount $count `
                -ExpectedDisabled $disabled -Boundaries $boundaries -PriorTimestamps $priorTimes
        } (New-CrashGuardFixture -Count $stage -Disabled ($stage -eq 3) -Times $times) `
            $stage ($stage -eq 3) @($bounds | Select-Object -First $stage) $prior
        [uint64[]]$prior = @($result.timestamps100ns)
    }
    Assert-Throws {
        & $library {
            param($snapshot, $boundaries)
            Assert-RollingCrashGuardStage -Snapshot $snapshot -ExpectedCount 2 `
                -ExpectedDisabled $false -Boundaries $boundaries -PriorTimestamps @([uint64]15)
        } (New-CrashGuardFixture -Count 3 -Disabled $false -Times @([uint64]15,[uint64]25)) `
            @($bounds | Select-Object -First 2)
    } 'real crash-stage validator accepted the wrong persisted count'

    Assert-Contract ($harness -notmatch "(?i)nativeStart[^\r\n]*(pass|verified)|native Start (available|verified)") `
        'native Start is mislabeled as a mechanical pass instead of manual/deferred'

    Write-Host 'A4S failure/recovery offline contracts passed: real harness validators cover registry shape, exact aggregate authorization/rollback, immutable release binding, host uniqueness, post-kill evidence, cleanup retention, and exact 1/2/3 reconnect states.'
}
finally {
    Remove-Module -ModuleInfo $library -Force -ErrorAction SilentlyContinue
}
