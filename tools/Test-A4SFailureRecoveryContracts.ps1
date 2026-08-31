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
        [Parameter(Mandatory)][string] $Message,
        [string] $MessagePattern
    )
    $caught = $null
    try { & $Action }
    catch { $caught = $_ }
    Assert-Contract ($null -ne $caught) $Message
    if ($null -ne $caught -and -not [string]::IsNullOrWhiteSpace($MessagePattern)) {
        Assert-Contract ($caught.Exception.Message -match $MessagePattern) `
            "$Message (unexpected error: $($caught.Exception.Message))"
    }
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

# Load the production harness as a function library. ContractLibrary returns
# before native initialization or dispatch. The tests explicitly initialize only
# the read-only native helper required for final-handle path validation.
$library = New-Module -Name A4SFailureRecoveryContractLibrary -ScriptBlock {
    param([string] $Path)
    . $Path -ContractLibrary
} -ArgumentList $harnessPath

$sandboxSubKey = 'Software\A4SMenuFailureRecoveryContract_' + [Guid]::NewGuid().ToString('N')
$sandboxAuthorized = $null
$sandboxOwnershipEstablished = $false
$temporaryRoot = $null
$primaryError = $null

try {
    & $library { Initialize-A4SFailureRecoveryNative }

    # Static dispatch and destructive-boundary contracts.
    Assert-Contract ($harness -match "CmdletBinding\(DefaultParameterSetName\s*=\s*'Offline'\)") `
        'default execution is not Offline'
    Assert-InOrder -Text $harness -Markers @(
        "if (`$PSCmdlet.ParameterSetName -eq 'ContractLibrary')",
        "elseif (`$PSCmdlet.ParameterSetName -eq 'Offline')",
        'Initialize-A4SFailureRecoveryNative') `
        -Message 'safe ContractLibrary/Offline dispatch does not precede executable setup'
    foreach ($forbidden in @('Stop-Process', 'taskkill', 'Restart-Computer',
            'Stop-Computer', '--rehook', 'build\stage\A4SProduct', 'reg.exe import',
            'DeleteSubKeyTree')) {
        Assert-Contract ($harness -notmatch [Regex]::Escape($forbidden)) `
            "harness contains forbidden primitive $forbidden"
    }
    Assert-Contract (([Regex]::Matches($harness,
        'Remove-Item[^\r\n]+-Recurse')).Count -eq 0) `
        'recursive filesystem deletion remains in the harness'
    Assert-Contract ($harness -match
        '\[Parameter\(Mandatory, ParameterSetName = ''Recover''\)\][\s\S]*?\$ExpectedManifestSha256') `
        'Recover does not require an expected manifest SHA-256'
    Assert-Contract (([Regex]::Matches($harness,
        '\[Parameter\(Mandatory, ParameterSetName = ''(?:Isolated|Live)''\)\]\s*\r?\n\s*\[Parameter\(Mandatory, ParameterSetName = ''(?:Isolated|Live)''\)\]\s*\r?\n\s*\[string\] \$ReleaseRecordPath')).Count -eq 1) `
        'Isolated and Live do not both require an immutable release record'
    Assert-Contract ($harness -notmatch 'QueryHostVersion') `
        'a caller binary can still be executed during static binding'

    $native = Get-FunctionText 'Initialize-A4SFailureRecoveryNative'
    foreach ($required in @('GetFinalPathNameByHandleW', 'GetDriveTypeW', 'QueryDosDeviceW',
            'FILE_ATTRIBUTE_REPARSE_POINT', 'GetFileInformationByHandle',
            'AcquireProductMutationBoundary', 'LifecycleMutexName', 'SetupMutexName',
            'HostSafetyMutexName', 'HostMutexName', 'MutationContext',
            'ValidateMutationContext', 'GetTaskbarWindowRecord')) {
        Assert-Contract ($native -match [Regex]::Escape($required)) `
            "native safety layer omits $required"
    }
    Assert-Contract ($setupSource -match 'Global\\\\A4SMenu\.Setup\.v1\.' -and
        $setupSource -match 'GetLengthSid' -and $setupSource -match 'HashBytes') `
        'Setup mutex ownership no longer matches the harness boundary'
    Assert-Contract ($identity -match
        'A4S_HOST_MUTEX_PREFIX_W\s+L"Local\\\\A4SMenu\.Host\.Instance\.v1"') `
        'host mutex identity no longer matches the harness boundary'
    Assert-InOrder -Text $native -Markers @('lifecycle = new Mutex',
        'setup = new Mutex', 'safety = new Mutex', 'host = new Mutex') `
        -Message 'product mutation locks are not acquired Lifecycle/Setup/HostSafety/Host'
    foreach ($exactMutex in @('Global\A4SMenu.Lifecycle.v1.',
            'Global\A4SMenu.HostSafety.v1.')) {
        Assert-Contract ($native -match [Regex]::Escape($exactMutex)) `
            "native boundary omits raw-SID mutex $exactMutex"
    }

    $tempCleanup = Get-FunctionText 'Remove-A4STemporaryRoot'
    foreach ($required in @('allowedDirectories', 'allowedDirectoryFiles',
            'allowedRootFiles', 'Get-ChildItem',
            'Get-CanonicalPathRecord', 'Test-PathWithin', 'identity',
            'immediately before deletion')) {
        Assert-Contract ($tempCleanup -match [Regex]::Escape($required)) `
            "flat temporary cleanup omits $required"
    }
    Assert-Contract ($tempCleanup -notmatch '-Recurse') `
        'flat temporary cleanup contains recursive deletion'

    $manifestRead = Get-FunctionText 'Read-ValidatedHostSafetyBackup'
    $lockedRead = Get-FunctionText 'Read-LockedFileBytesRecord'
    $restore = Get-FunctionText 'Restore-HostSafety'
    foreach ($required in @('FileShare]::Read', 'ExpectedSha256', 'ComputeHash',
            'pathIdentity', 'bytes')) {
        Assert-Contract ($lockedRead -match [Regex]::Escape($required)) `
            "locked file read omits $required"
    }
    foreach ($required in @('ExpectedManifestSha256', 'Read-LockedUtf8JsonRecord',
            'Assert-ValidatedHostSafetyManifestObject', 'manifestSha256')) {
        Assert-Contract ($manifestRead -match [Regex]::Escape($required)) `
            "manifest validation omits $required"
    }
    Assert-InOrder -Text $restore -Markers @(
        'Read-ValidatedHostSafetyBackup', 'Enter-A4SProductMutationBoundary',
        'Get-HostSafetyAggregateRecord', 'Assert-AuthorizedHostSafetyAggregate',
        'Backup-HostSafety', 'Invoke-A4SRegistrySnapshotTransaction') `
        -Message 'restore does not authenticate, lock, CAS, back up, then journal'
    foreach ($required in @('ExpectedManifestSha256',
            'ExpectedCurrentHostSafetySha256',
            'manifestSha256', 'mutationStepCount', 'Exit-A4SProductMutationBoundary')) {
        Assert-Contract ($restore -match [Regex]::Escape($required)) `
            "transactional restore omits $required"
    }

    $treeValidator = Get-FunctionText 'Assert-ValidRegistryTree'
    Assert-Contract ($treeValidator -match 'subkeys are forbidden') `
        'HostSafety schema does not explicitly forbid subkeys'
    $transaction = Get-FunctionText 'Invoke-A4SRegistrySnapshotTransaction'
    $transactionRecovery = Get-FunctionText 'Invoke-A4SRegistryTransactionRecovery'
    $journalStep = Get-FunctionText 'Invoke-A4SRegistryJournaledStep'
    $undoJournal = Get-FunctionText 'Undo-A4SRegistryJournal'
    $primitive = Get-FunctionText 'Invoke-A4SRegistryPrimitive'
    foreach ($required in @('ContractRegistrySandbox', 'ExpectedCurrent',
            'A4S_UNKNOWN_REGISTRY_STATE', 'Undo-A4SRegistryJournal',
            'InjectFailureAfterStep', 'mutationStepCount', 'ProductBoundary',
            'forbids a caller-supplied validator',
            'New-A4SRegistryTransactionDescriptor', 'RollbackManifestSha256',
            'CreateProductMutationContext', 'CreateContractMutationContext',
            'A4S_SIMULATED_HARD_INTERRUPTION')) {
        Assert-Contract ($transaction -match [Regex]::Escape($required)) `
            "registry transaction omits $required"
    }
    Assert-InOrder -Text $transaction -Markers @(
        "effectiveBoundaryValidator 'registry transaction entry'",
        'CreateProductMutationContext') `
        -Message 'product mutation context can be created before boundary validation'
    Assert-InOrder -Text $journalStep -Markers @('preflight', 'Get-RegistryAggregateRecord',
        "phase='before-primitive'", 'Invoke-A4SRegistryPrimitive', 'postflight',
        'Get-RegistryAggregateRecord', "phase='after-primitive'",
        'Journal.Add') -Message 'journal step is not CAS-checked before and after mutation'
    Assert-InOrder -Text $undoJournal -Markers @('entry.after', "phase='before-rollback'",
        'Invoke-A4SRegistryPrimitive', 'entry.before', "phase='after-rollback'") `
        -Message 'journal rollback does not verify exact after and before aggregates'
    Assert-InOrder -Text $primitive -Markers @('ValidateMutationContext',
        'OpenBaseKey') -Message 'a registry primitive can open HKCU before opaque-context validation'
    Assert-InOrder -Text $primitive -Markers @('Assert-A4SProductMutationMode',
        'ValidateMutationContext', 'OpenBaseKey') `
        -Message 'ContractLibrary can reach product registry before mode/context validation'
    Assert-InOrder -Text $transactionRecovery -Markers @(
        "phase='recovery-prepared'", 'Throw-A4SSimulatedHardInterruption',
        "CurrentPhase 'recovery-prepared'", 'Invoke-A4SRegistrySnapshotTransaction') `
        -Message 'recovery-prepared is not durable and interruptible before replay mutation'

    $binaryBinding = Get-FunctionText 'Get-BinaryBinding'
    foreach ($required in @('FileShare]::Read', 'Assert-StaticPeImageBytes',
            'ComputeHash', 'FileVersionInfo]::GetVersionInfo',
            'static-locked-pe-resource')) {
        Assert-Contract ($binaryBinding -match [Regex]::Escape($required)) `
            "static binary authentication omits $required"
    }
    Assert-Contract ($binaryBinding -notmatch 'Invoke-A4SHostCommand') `
        'static binding executes the candidate image'
    $reportedVersion = Get-FunctionText 'Confirm-A4SAuthenticatedHostReportedVersion'
    Assert-InOrder -Text $reportedVersion -Markers @(
        'Assert-HostBindingMatchesReleaseRecord', 'FileShare]::Read',
        'Get-BinaryBinding', 'Assert-BinaryCopyBinding',
        'Assert-HostBindingMatchesReleaseRecord', 'Invoke-A4SHostCommand') `
        -Message 'host --version runs before locked static/release authentication'

    $isolated = Get-FunctionText 'Invoke-IsolatedDllFailureQualification'
    $live = Get-FunctionText 'Invoke-LiveFailureRecoveryQualification'
    foreach ($flow in @($isolated, $live)) {
        foreach ($required in @('New-A4SAuthorizedHostSafetyState',
                'Assert-A4SAuthorizedCurrentHostSafety', 'ExpectedManifestSha256',
                'Confirm-A4SRestoreTransition', 'AuthorizedState')) {
            Assert-Contract ($flow -match [Regex]::Escape($required)) `
                "qualification flow omits authorized-state contract $required"
        }
    }
    Assert-InOrder -Text $isolated -Markers @('Read-VerifiedA4SReleaseRecord',
        'Get-BinaryBinding', 'Assert-HostBindingMatchesReleaseRecord',
        'Confirm-A4SAuthenticatedHostReportedVersion', 'New-EvidenceBundle') `
        -Message 'isolated mode executes or creates state before caller host authentication'
    Assert-InOrder -Text $live -Markers @('Read-VerifiedA4SReleaseRecord',
        'Get-BinaryBinding', 'Get-BinaryBinding',
        'Assert-BinaryBindingsMatchReleaseRecord',
        'Confirm-A4SAuthenticatedHostReportedVersion', 'New-EvidenceBundle') `
        -Message 'live mode executes or creates state before exact host/DLL authentication'
    foreach ($required in @('Confirm-A4SResetSafetyTransition',
            'Confirm-A4SCrashGuardTransition', 'preCrashAuthorizedSha256',
            'preRecoveryResetAuthorizedSha256')) {
        Assert-Contract ($live -match [Regex]::Escape($required)) `
            "live known-action authorization sequence omits $required"
    }
    Assert-Contract ($harness -notmatch 'Add-HostSafetyRestoreAuthorizationCheckpoint') `
        'finalization still self-authorizes an arbitrary current HostSafety state'

    $retention = Get-FunctionText 'Set-RetainedTemporaryRootEvidence'
    foreach ($required in @('Get-A4SConfirmedRecoveryAuthorization',
            'freshKnownCurrentHostSafetySha256', 'ExpectedManifestSha256',
            'ExpectedCurrentHostSafetySha256', 'manual registry/state review')) {
        Assert-Contract ($retention -match [Regex]::Escape($required)) `
            "retained cleanup instructions omit $required"
    }

    # Existing crash and source-binding guarantees remain in force.
    Assert-Contract ($hostSource -match 'constexpr DWORD kCrashLoopThreshold = 3;') `
        'host crash threshold is not three'
    Assert-Contract ($hostSource -match
        'constexpr ULONGLONG kCrashLoopWindow100ns = UINT64_C\(180\)') `
        'host rolling crash window is not 180 seconds'
    Assert-InOrder -Text $live -Markers @('Read-VerifiedA4SReleaseRecord',
        'Assert-BinaryBindingsMatchReleaseRecord', 'Backup-HostSafety',
        'Request-ValidatedExplorerTermination') `
        -Message 'live mode reaches Explorer termination before source binding and backup'
    Assert-Contract (([Regex]::Matches($live,
        "sequence = 'post-kill-pre-wait'")).Count -eq 2) `
        'both live termination boundaries do not persist pre-wait evidence'

    # Execute actual path and flat-schema validators.
    Assert-Contract (& $library {
        Test-PathsOverlap -First 'C:\A4S\root' -Second 'c:\a4s\root\child'
    }) 'real overlap predicate rejected a nested path'
    Assert-Contract (-not (& $library {
        Test-PathsOverlap -First 'C:\A4S\one' -Second 'C:\A4S\two'
    })) 'real overlap predicate accepted siblings'
    Assert-Throws { & $library { Assert-NoShortPathAlias -Path 'C:\PROGRA~1\A4S' } } `
        'real short-alias validator accepted an 8.3 path'

    $currentPowerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $staticPeBinding = & $library {
        param($path)
        Get-BinaryBinding -Path $path -Role 'read-only contract PE fixture'
    } $currentPowerShellPath
    Assert-Contract ($staticPeBinding.pe.machine -ceq 'AMD64' -and
        $staticPeBinding.fixedVersionReadMode -ceq 'static-locked-pe-resource' -and
        $null -eq $staticPeBinding.reportedVersion) `
        'real static PE authentication did not remain non-executing and x64-bound'
    Assert-Throws {
        & $library {
            Assert-StaticPeImageBytes -Bytes ([byte[]]::new(256)) `
                -Role 'invalid contract PE fixture'
        }
    } 'static PE parser accepted zero-filled non-PE bytes'

    $absent = [pscustomobject][ordered]@{ exists=$false; values=@(); subkeys=@() }
    $preState = [pscustomobject][ordered]@{
        exists=$true
        values=@(
            [pscustomobject][ordered]@{name='Alpha';kind='DWord';value=[uint32]7},
            [pscustomobject][ordered]@{name='Expand';kind='ExpandString';value='%TEMP%\A4S'},
            [pscustomobject][ordered]@{name='Multi';kind='MultiString';value=@('one','two')},
            [pscustomobject][ordered]@{name='Payload';kind='Binary';value='AQIDBA=='},
            [pscustomobject][ordered]@{name='Qword';kind='QWord';value=[uint64]4294967301},
            [pscustomobject][ordered]@{name='Raw';kind='None';value='BQYHCA=='})
        subkeys=@()
    }
    $desiredState = [pscustomobject][ordered]@{
        exists=$true
        values=@(
            [pscustomobject][ordered]@{name='InjectionDisabled';kind='DWord';value=[uint32]1},
            [pscustomobject][ordered]@{name='LastExplorerExitCode';kind='DWord';value=[uint32]55},
            [pscustomobject][ordered]@{name='Marker';kind='String';value='contract'})
        subkeys=@()
    }
    foreach ($tree in @($absent, $preState, $desiredState)) {
        & $library { param($value) Assert-ValidRegistryTree -Tree $value -IsRoot $true } $tree
    }
    $subkeyTree = $preState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $subkeyTree.subkeys = @([pscustomobject]@{name='Forbidden';values=@();subkeys=@()})
    Assert-Throws {
        & $library { param($value) Assert-ValidRegistryTree -Tree $value -IsRoot $true } `
            $subkeyTree
    } 'real registry schema accepted a HostSafety subkey'
    $duplicateTree = $preState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $duplicateTree.values = @($duplicateTree.values[0], $duplicateTree.values[0])
    Assert-Throws {
        & $library { param($value) Assert-ValidRegistryTree -Tree $value -IsRoot $true } `
            $duplicateTree
    } 'real registry schema accepted duplicate value names'

    $sequenceState = [pscustomobject]@{
        restored=$false
        nextMutationIndex=0
        expectedMutationActions=@('known-action-1', 'known-action-2')
    }
    $advance = & $library {
        param($state)
        Get-A4SExpectedAuthorizedActionAdvance -State $state -Action 'known-action-1'
    } $sequenceState
    Assert-Contract (-not $advance.isRestore -and $advance.nextMutationIndex -eq 1) `
        'real authorized-action sequence did not advance its exact first action'
    Assert-Throws {
        & $library {
            param($state)
            Get-A4SExpectedAuthorizedActionAdvance -State $state -Action 'known-action-2'
        } $sequenceState
    } 'real authorized-action sequence accepted a skipped action'
    $restoreAdvance = & $library {
        param($state)
        Get-A4SExpectedAuthorizedActionAdvance `
            -State $state -Action 'restore-validated-manifest'
    } $sequenceState
    Assert-Contract ($restoreAdvance.isRestore -and
        $restoreAdvance.nextMutationIndex -eq 0) `
        'real authorized-action sequence rejected an early exact restore'
    $sequenceState.restored = $true
    Assert-Throws {
        & $library {
            param($state)
            Get-A4SExpectedAuthorizedActionAdvance -State $state -Action 'known-action-1'
        } $sequenceState
    } 'real authorized-action sequence accepted mutation after restore'

    # Execute the real locked manifest read/hash and production manifest schema.
    $temporaryRoot = & $library { New-A4STemporaryRoot }
    $snapshotAggregate = & $library {
        param($snapshot) Get-HostSafetyAggregateRecord -Snapshot $snapshot
    } $absent
    $manifest = [ordered]@{
        schemaVersion=3
        backupId=[Guid]::NewGuid().ToString('N')
        createdUtc=[DateTime]::UtcNow.ToString('o')
        registryHive='HKEY_CURRENT_USER'
        registryPath='HKCU\Software\A4SMenu\HostSafety'
        registrySubKey='Software\A4SMenu\HostSafety'
        registryView='Registry64'
        snapshot=$absent
        snapshotSha256=$snapshotAggregate.sha256
        regExport=$null
    }
    $manifestText = $manifest | ConvertTo-Json -Depth 32
    $manifestSha = & $library { param($text) Get-TextSha256 -Text $text } $manifestText
    $manifestPath = Join-Path $temporaryRoot.finalPath 'HostSafetyBackup.json'
    & $library {
        param($path, $text) Write-DurableNewText -Path $path -Text $text
    } $manifestPath $manifestText
    $lockedManifest = & $library {
        param($path, $hash)
        Read-LockedUtf8JsonRecord -Path $path -Description 'contract manifest' `
            -ExpectedSha256 $hash
    } $manifestPath $manifestSha
    $validatedManifestAggregate = & $library {
        param($value) Assert-ValidatedHostSafetyManifestObject -Manifest $value
    } $lockedManifest.value
    Assert-Contract ($lockedManifest.sha256 -ceq $manifestSha -and
        $validatedManifestAggregate.sha256 -ceq $snapshotAggregate.sha256) `
        'real locked manifest read did not bind the parsed bytes to the expected hash'
    $tamperedManifest = $manifestText.Replace('Registry64', 'Registry32')
    & $library {
        param($path, $text) Write-DurableText -Path $path -Text $text
    } $manifestPath $tamperedManifest
    Assert-Throws {
        & $library {
            param($path, $hash)
            Read-LockedUtf8JsonRecord -Path $path -Description 'tampered contract manifest' `
                -ExpectedSha256 $hash
        } $manifestPath $manifestSha
    } 'real locked manifest reader accepted bytes that changed after authorization' `
        'SHA-256 differs'
    $runtimeCleanupDirectory = & $library {
        param($path, $parent)
        New-SafeFreshDirectory -Path $path `
            -Description 'contract valid-runtime directory' -ExpectedParent $parent
    } (Join-Path $temporaryRoot.finalPath 'valid-runtime') $temporaryRoot.finalPath
    foreach ($fileName in @('A4SMenuHost.exe', 'A4SMenu.dll')) {
        & $library {
            param($path, $text) Write-DurableNewText -Path $path -Text $text
        } (Join-Path $runtimeCleanupDirectory.finalPath $fileName) 'contract-cleanup-fixture'
    }

    function New-ContractTransactionAssets {
        param([Parameter(Mandatory)][object] $ExpectedAggregate)

        $directory = & $library {
            param($path, $parent)
            New-SafeFreshDirectory -Path $path `
                -Description 'contract registry transaction directory' `
                -ExpectedParent $parent
        } (Join-Path $temporaryRoot.finalPath (
            'contract-transaction-' + [Guid]::NewGuid().ToString('N'))) `
            $temporaryRoot.finalPath
        $rollbackManifest = [ordered]@{
            schemaVersion=1
            createdUtc=[DateTime]::UtcNow.ToString('o')
            registrySubKey=$sandboxSubKey
            snapshot=$ExpectedAggregate.snapshot
            snapshotSha256=$ExpectedAggregate.sha256
        }
        $rollbackText = $rollbackManifest | ConvertTo-Json -Depth 32
        $rollbackSha = & $library {
            param($text) Get-TextSha256 -Text $text
        } $rollbackText
        & $library {
            param($path, $text) Write-DurableNewText -Path $path -Text $text
        } (Join-Path $directory.finalPath 'A4SRegistryRollback.json') $rollbackText
        return [pscustomobject][ordered]@{
            bundle=$directory.finalPath
            rollbackManifestSha256=$rollbackSha
            descriptorPath=(Join-Path $directory.finalPath 'A4SRegistryTransaction.json')
        }
    }

    # Execute the production journal/CAS engine against one random, isolated
    # HKCU subtree. The production HostSafety target remains hard-locked and is
    # never selected by this contract seam.
    $boundary = { param([string] $Label) return $true }
    Assert-Throws {
        & $library {
            param($desired, $expected, $validator)
            Invoke-A4SRegistrySnapshotTransaction `
                -RegistrySubKey 'Software\A4SMenu\HostSafety' `
                -DesiredSnapshot $desired -ExpectedCurrent $expected `
                -ValidateBoundary $validator
        } $absent $snapshotAggregate $boundary
    } 'product HostSafety transaction accepted a contract validator' `
        'forbidden outside|real product boundary object'
    $sandboxAuthorized = & $library {
        param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
    } $sandboxSubKey
    Assert-Contract (-not [bool]$sandboxAuthorized.snapshot.exists) `
        'fresh random registry contract subtree unexpectedly exists'
    $sandboxOwnershipEstablished = $true

    # Opaque mutation capabilities cannot be forged, retargeted, or replayed
    # with a different nonce. All negative operations target only random HKCU
    # contract names and are rejected before OpenBaseKey.
    $contextNonce = [Guid]::NewGuid().ToString('N')
    $contractContext = & $library {
        param($key, $nonce)
        [A4SFailureRecoveryNative]::CreateContractMutationContext($key, $nonce)
    } $sandboxSubKey $contextNonce
    Assert-Throws {
        & $library {
            param($key)
            Invoke-A4SRegistryPrimitive -RegistrySubKey $key -Operation CreateKey
        } $sandboxSubKey
    } 'registry primitive accepted a call without an opaque mutation context'
    Assert-Throws {
        & $library {
            param($key, $context, $nonce)
            Invoke-A4SRegistryPrimitive -RegistrySubKey $key `
                -MutationContext $context -ContextNonce $nonce -Operation CreateKey
        } $sandboxSubKey $contractContext ([Guid]::NewGuid().ToString('N'))
    } 'registry primitive accepted a replayed context with a different nonce' `
        'nonce|context'
    $otherSandboxSubKey = 'Software\A4SMenuFailureRecoveryContract_' +
        [Guid]::NewGuid().ToString('N')
    Assert-Throws {
        & $library {
            param($key, $context, $nonce)
            Invoke-A4SRegistryPrimitive -RegistrySubKey $key `
                -MutationContext $context -ContextNonce $nonce -Operation CreateKey
        } $otherSandboxSubKey $contractContext $contextNonce
    } 'registry primitive accepted a context for a different exact target' `
        'target|context'
    Assert-Throws {
        & $library {
            param($nonce)
            [A4SFailureRecoveryNative]::CreateContractMutationContext(
                'Software\A4SMenu\HostSafety', $nonce)
        } $contextNonce
    } 'ContractLibrary forged a sandbox capability against product HostSafety' `
        'cannot target product'
    Assert-Throws {
        & $library {
            Invoke-A4SRegistryPrimitive `
                -RegistrySubKey 'Software\A4SMenu\HostSafety' `
                -MutationContext ([pscustomobject]@{}) `
                -ContextNonce ([Guid]::NewGuid().ToString('N')) `
                -Operation CreateKey
        }
    } 'ContractLibrary reached a product primitive' `
        'forbidden outside'
    Assert-Throws {
        & $library { Enter-A4SProductMutationBoundary }
    } 'ContractLibrary acquired a product mutation boundary' `
        'unavailable in ContractLibrary'
    $postBypassState = & $library {
        param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
    } $sandboxSubKey
    $otherPostBypassState = & $library {
        param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
    } $otherSandboxSubKey
    Assert-Contract (-not $postBypassState.snapshot.exists -and
        -not $otherPostBypassState.snapshot.exists) `
        'opaque-context bypass negatives mutated a registry sandbox'

    function Invoke-SandboxTransition {
        param(
            [Parameter(Mandatory)][object] $Desired,
            [ValidateRange(0, 1024)][int] $InjectFailureAfterStep = 0
        )
        $assets = New-ContractTransactionAssets -ExpectedAggregate $sandboxAuthorized
        $result = & $library {
            param($key, $desired, $expected, $validator, $inject, $assets)
            Invoke-A4SRegistrySnapshotTransaction -RegistrySubKey $key `
                -DesiredSnapshot $desired -ExpectedCurrent $expected `
                -ValidateBoundary $validator -ContractRegistrySandbox `
                -TransactionDescriptorPath $assets.descriptorPath `
                -RollbackBundle $assets.bundle `
                -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                -InjectFailureAfterStep $inject
        } $sandboxSubKey $Desired $sandboxAuthorized $boundary `
            $InjectFailureAfterStep $assets
        $script:sandboxAuthorized = [pscustomobject][ordered]@{
            snapshot=$result.snapshot; sha256=$result.snapshotSha256
        }
        return $result
    }

    # A stale expected aggregate must reject before mutation.
    $wrongExpected = & $library {
        param($key, $snapshot) Get-RegistryAggregateRecord -RegistrySubKey $key -Snapshot $snapshot
    } $sandboxSubKey $preState
    Assert-Throws {
        & $library {
            param($key, $desired, $expected, $validator)
            Invoke-A4SRegistrySnapshotTransaction -RegistrySubKey $key `
                -DesiredSnapshot $desired -ExpectedCurrent $expected `
                -ValidateBoundary $validator -ContractRegistrySandbox
        } $sandboxSubKey $desiredState $wrongExpected $boundary
    } 'real registry CAS accepted a stale expected aggregate' `
        'previously authorized aggregate'
    $afterRejectedCas = & $library {
        param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
    } $sandboxSubKey
    Assert-Contract ($afterRejectedCas.sha256 -ceq $sandboxAuthorized.sha256) `
        'rejected CAS changed the sandbox subtree'

    $scenarios = @(
        [pscustomobject]@{name='absent-to-values';before=$absent;after=$desiredState},
        [pscustomobject]@{name='replace-values';before=$preState;after=$desiredState},
        [pscustomobject]@{name='values-to-absent';before=$preState;after=$absent}
    )
    foreach ($scenario in $scenarios) {
        [void](Invoke-SandboxTransition -Desired $scenario.before)
        $success = Invoke-SandboxTransition -Desired $scenario.after
        Assert-Contract ($success.mutationStepCount -gt 0) `
            "$($scenario.name) did not exercise a registry mutation"
        [void](Invoke-SandboxTransition -Desired $scenario.before)

        foreach ($step in 1..$success.mutationStepCount) {
            $beforeFailure = $sandboxAuthorized
            Assert-Throws {
                Invoke-SandboxTransition -Desired $scenario.after `
                    -InjectFailureAfterStep $step
            } "$($scenario.name) failure injection step $step did not throw" `
                'rollback restored the exact immediate prestate'
            $afterFailure = & $library {
                param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
            } $sandboxSubKey
            Assert-Contract ($afterFailure.sha256 -ceq $beforeFailure.sha256 -and
                (& $library {
                    param($expected, $actual)
                    Compare-HostSafetySnapshot -Expected $expected -Actual $actual
                } $beforeFailure.snapshot $afterFailure.snapshot)) `
                "$($scenario.name) failure injection step $step did not roll back exactly"
        }
    }

    # A real durable descriptor must make every interruption phase recoverable.
    foreach ($hardPhase in @('prepared', 'before-primitive', 'after-primitive',
            'committed', 'before-rollback', 'after-rollback', 'rolled-back')) {
        [void](Invoke-SandboxTransition -Desired $absent)
        $beforeHard = $sandboxAuthorized
        $assets = New-ContractTransactionAssets -ExpectedAggregate $beforeHard
        $ordinaryFailureStep = if ($hardPhase -in @(
            'before-rollback', 'after-rollback', 'rolled-back')) { 1 } else { 0 }
        Assert-Throws {
            & $library {
                param($key, $desired, $expected, $validator, $assets,
                    $hardPhase, $ordinaryFailureStep)
                Invoke-A4SRegistrySnapshotTransaction -RegistrySubKey $key `
                    -DesiredSnapshot $desired -ExpectedCurrent $expected `
                    -ValidateBoundary $validator -ContractRegistrySandbox `
                    -TransactionDescriptorPath $assets.descriptorPath `
                    -RollbackBundle $assets.bundle `
                    -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                    -InjectFailureAfterStep $ordinaryFailureStep `
                    -InjectHardInterruptionPhase $hardPhase
            } $sandboxSubKey $desiredState $beforeHard $boundary $assets `
                $hardPhase $ordinaryFailureStep
        } "hard interruption phase $hardPhase did not interrupt" `
            'A4S_SIMULATED_HARD_INTERRUPTION'
        $durable = & $library {
            param($key, $assets)
            Read-A4SRegistryTransactionDescriptor -Path $assets.descriptorPath `
                -RegistrySubKey $key -TargetKind contract-sandbox `
                -RollbackBundle $assets.bundle `
                -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                -CaptureSha256
        } $sandboxSubKey $assets
        Assert-Contract ([string]$durable.value.phase -ceq $hardPhase) `
            "hard interruption $hardPhase was not durably phase-marked"
        $recovered = & $library {
            param($key, $validator, $assets, $descriptorSha256)
            Invoke-A4SRegistryTransactionRecovery -RegistrySubKey $key `
                -TransactionDescriptorPath $assets.descriptorPath `
                -ExpectedTransactionDescriptorSha256 $descriptorSha256 `
                -RollbackBundle $assets.bundle `
                -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                -ValidateBoundary $validator -ContractRegistrySandbox
        } $sandboxSubKey $boundary $assets $durable.sha256
        $script:sandboxAuthorized = [pscustomobject][ordered]@{
            snapshot=$recovered.snapshot; sha256=$recovered.snapshotSha256
        }
        $expectedRecovered = if ($hardPhase -in @('prepared', 'committed')) {
            & $library {
                param($key, $snapshot)
                Get-RegistryAggregateRecord -RegistrySubKey $key -Snapshot $snapshot
            } $sandboxSubKey $desiredState
        }
        else { $beforeHard }
        Assert-Contract ($sandboxAuthorized.sha256 -ceq $expectedRecovered.sha256) `
            "hard interruption $hardPhase did not deterministically resume or exact-CAS rollback"
    }

    # Exercise the recovery-only descriptor phase, then interrupt the resumed
    # rollback twice more. This proves replay is repeatable rather than merely
    # able to recover from one interrupted initial transaction.
    [void](Invoke-SandboxTransition -Desired $absent)
    $beforeRepeatedRecovery = $sandboxAuthorized
    $repeatedAssets = New-ContractTransactionAssets `
        -ExpectedAggregate $beforeRepeatedRecovery
    Assert-Throws {
        & $library {
            param($key, $desired, $expected, $validator, $assets)
            Invoke-A4SRegistrySnapshotTransaction -RegistrySubKey $key `
                -DesiredSnapshot $desired -ExpectedCurrent $expected `
                -ValidateBoundary $validator -ContractRegistrySandbox `
                -TransactionDescriptorPath $assets.descriptorPath `
                -RollbackBundle $assets.bundle `
                -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                -InjectHardInterruptionPhase after-primitive
        } $sandboxSubKey $desiredState $beforeRepeatedRecovery $boundary `
            $repeatedAssets
    } 'repeated-recovery fixture did not interrupt its initial apply' `
        'A4S_SIMULATED_HARD_INTERRUPTION:after-primitive'
    $repeatedDescriptor = & $library {
        param($key, $assets)
        Read-A4SRegistryTransactionDescriptor -Path $assets.descriptorPath `
            -RegistrySubKey $key -TargetKind contract-sandbox `
            -RollbackBundle $assets.bundle `
            -RollbackManifestSha256 $assets.rollbackManifestSha256 `
            -CaptureSha256
    } $sandboxSubKey $repeatedAssets
    Assert-Contract ([string]$repeatedDescriptor.value.phase -ceq 'after-primitive') `
        'repeated-recovery fixture did not durably retain its initial interruption'

    Assert-Throws {
        & $library {
            param($key, $validator, $assets, $descriptorSha256)
            Invoke-A4SRegistryTransactionRecovery -RegistrySubKey $key `
                -TransactionDescriptorPath $assets.descriptorPath `
                -ExpectedTransactionDescriptorSha256 $descriptorSha256 `
                -RollbackBundle $assets.bundle `
                -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                -ValidateBoundary $validator -ContractRegistrySandbox `
                -InjectHardInterruptionPhase recovery-prepared
        } $sandboxSubKey $boundary $repeatedAssets $repeatedDescriptor.sha256
    } 'recovery-prepared did not interrupt before replay mutation' `
        'A4S_SIMULATED_HARD_INTERRUPTION:recovery-prepared'
    $repeatedDescriptor = & $library {
        param($key, $assets)
        Read-A4SRegistryTransactionDescriptor -Path $assets.descriptorPath `
            -RegistrySubKey $key -TargetKind contract-sandbox `
            -RollbackBundle $assets.bundle `
            -RollbackManifestSha256 $assets.rollbackManifestSha256 `
            -CaptureSha256
    } $sandboxSubKey $repeatedAssets
    Assert-Contract ([string]$repeatedDescriptor.value.phase -ceq 'recovery-prepared') `
        'recovery-prepared was not durably phase-marked before interruption'

    foreach ($recoveryHardPhase in @('before-primitive', 'after-primitive')) {
        Assert-Throws {
            & $library {
                param($key, $validator, $assets, $descriptorSha256, $hardPhase)
                Invoke-A4SRegistryTransactionRecovery -RegistrySubKey $key `
                    -TransactionDescriptorPath $assets.descriptorPath `
                    -ExpectedTransactionDescriptorSha256 $descriptorSha256 `
                    -RollbackBundle $assets.bundle `
                    -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                    -ValidateBoundary $validator -ContractRegistrySandbox `
                    -InjectHardInterruptionPhase $hardPhase
            } $sandboxSubKey $boundary $repeatedAssets `
                $repeatedDescriptor.sha256 $recoveryHardPhase
        } "recovery replay did not interrupt at $recoveryHardPhase" `
            "A4S_SIMULATED_HARD_INTERRUPTION:$recoveryHardPhase"
        $repeatedDescriptor = & $library {
            param($key, $assets)
            Read-A4SRegistryTransactionDescriptor -Path $assets.descriptorPath `
                -RegistrySubKey $key -TargetKind contract-sandbox `
                -RollbackBundle $assets.bundle `
                -RollbackManifestSha256 $assets.rollbackManifestSha256 `
                -CaptureSha256
        } $sandboxSubKey $repeatedAssets
        Assert-Contract ([string]$repeatedDescriptor.value.phase -ceq $recoveryHardPhase) `
            "recovery replay interruption $recoveryHardPhase was not durable"
    }

    $repeatedRecovery = & $library {
        param($key, $validator, $assets, $descriptorSha256)
        Invoke-A4SRegistryTransactionRecovery -RegistrySubKey $key `
            -TransactionDescriptorPath $assets.descriptorPath `
            -ExpectedTransactionDescriptorSha256 $descriptorSha256 `
            -RollbackBundle $assets.bundle `
            -RollbackManifestSha256 $assets.rollbackManifestSha256 `
            -ValidateBoundary $validator -ContractRegistrySandbox
    } $sandboxSubKey $boundary $repeatedAssets $repeatedDescriptor.sha256
    $sandboxAuthorized = [pscustomobject][ordered]@{
        snapshot=$repeatedRecovery.snapshot; sha256=$repeatedRecovery.snapshotSha256
    }
    Assert-Contract (-not [bool]$sandboxAuthorized.snapshot.exists -and
        $sandboxAuthorized.sha256 -ceq $beforeRepeatedRecovery.sha256) `
        'repeated recovery interruptions did not exact-CAS back to the locked prestate'

    [void](Invoke-SandboxTransition -Desired $absent)
    $sandboxFinal = & $library {
        param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
    } $sandboxSubKey
    Assert-Contract (-not [bool]$sandboxFinal.snapshot.exists) `
        'transactional sandbox cleanup did not remove the test key'

    # Execute real authorization, termination, cleanup, and rolling-guard validators.
    $authorized = & $library {
        param($tree) Get-HostSafetyAggregateRecord -Snapshot $tree
    } $preState
    [void](& $library {
        param($aggregate, $tree)
        Assert-AuthorizedHostSafetyAggregate -Current $aggregate `
            -ExpectedSnapshot $tree -ExpectedSha256 $aggregate.sha256 -Boundary 'contract'
    } $authorized $preState)
    $intervening = $preState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $intervening.values[0].value = 8
    $interveningAggregate = & $library {
        param($tree) Get-HostSafetyAggregateRecord -Snapshot $tree
    } $intervening
    Assert-Throws {
        & $library {
            param($current, $expected, $hash)
            Assert-AuthorizedHostSafetyAggregate -Current $current `
                -ExpectedSnapshot $expected -ExpectedSha256 $hash `
                -Boundary 'contract intervention'
        } $interveningAggregate $preState $authorized.sha256
    } 'real aggregate authorization accepted an intervening state'

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

    $expectedExplorerIdentity = [pscustomobject][ordered]@{
        pid=[uint32]400; startTimeUtc='2026-01-01T00:00:00.0000000Z'
        path='C:\Windows\explorer.exe'; pathIdentity='00000001:00000002:00000003'
        sessionId=1; threadId=[uint32]900; taskbarWindowHandle=[int64]1200
    }
    $retainedExplorerIdentity = [pscustomobject][ordered]@{
        pid=[uint32]400; startTimeUtc='2026-01-01T00:00:00.0000000Z'
        path='C:\Windows\explorer.exe'; pathIdentity='00000001:00000002:00000003'
        sessionId=1; processHandleValue=[int64]44
    }
    $immediateTaskbarIdentity = $expectedExplorerIdentity | ConvertTo-Json | ConvertFrom-Json
    [void](& $library {
        param($expected, $retained, $taskbar)
        Assert-ExplorerTerminationIdentityPredicate -Expected $expected `
            -RetainedProcess $retained -ImmediateTaskbarOwner $taskbar `
            -Label 'contract exact Explorer kill identity'
    } $expectedExplorerIdentity $retainedExplorerIdentity $immediateTaskbarIdentity)
    foreach ($mutation in @(
        [pscustomobject]@{side='retained';field='pid';value=401},
        [pscustomobject]@{side='retained';field='startTimeUtc';value='2026-01-01T00:00:01.0000000Z'},
        [pscustomobject]@{side='retained';field='path';value='C:\Windows\not-explorer.exe'},
        [pscustomobject]@{side='retained';field='pathIdentity';value='different'},
        [pscustomobject]@{side='retained';field='sessionId';value=2},
        [pscustomobject]@{side='retained';field='processHandleValue';value=0},
        [pscustomobject]@{side='taskbar';field='pid';value=401},
        [pscustomobject]@{side='taskbar';field='threadId';value=901},
        [pscustomobject]@{side='taskbar';field='taskbarWindowHandle';value=1201},
        [pscustomobject]@{side='taskbar';field='pathIdentity';value='different'},
        [pscustomobject]@{side='taskbar';field='sessionId';value=2}
    )) {
        $retainedCopy = $retainedExplorerIdentity | ConvertTo-Json | ConvertFrom-Json
        $taskbarCopy = $immediateTaskbarIdentity | ConvertTo-Json | ConvertFrom-Json
        if ($mutation.side -ceq 'retained') {
            $retainedCopy.($mutation.field) = $mutation.value
        } else {
            $taskbarCopy.($mutation.field) = $mutation.value
        }
        Assert-Throws {
            & $library {
                param($expected, $retained, $taskbar)
                Assert-ExplorerTerminationIdentityPredicate -Expected $expected `
                    -RetainedProcess $retained -ImmediateTaskbarOwner $taskbar `
                    -Label 'contract mismatched Explorer kill identity'
            } $expectedExplorerIdentity $retainedCopy $taskbarCopy
        } "Explorer kill predicate accepted mismatched $($mutation.side).$($mutation.field)"
    }

    Assert-Contract (& $library {
        Test-A4STemporaryCleanupAllowed -AllHostsStopped $true `
            -MappingInspectionSucceeded $true -MappingCount 0 -WindowCount 0 `
            -SafetyRestored $true -CleanupRestartRequired $true `
            -CleanupRestartComplete $true
    }) 'real conclusive cleanup predicate denied deletion'

    function New-CrashGuardFixture {
        param(
            [int] $Count,
            [bool] $Disabled,
            [uint64[]] $Times,
            [uint64] $WindowStart = 0
        )
        $bytes = [byte[]]::new(24)
        for ($index = 0; $index -lt $Times.Count; $index++) {
            [BitConverter]::GetBytes([uint64]$Times[$index]).CopyTo($bytes, $index * 8)
        }
        return [pscustomobject][ordered]@{
            exists=$true
            values=@(
                [pscustomobject]@{name='AbnormalExplorerExitCount';kind='DWord';value=$Count},
                [pscustomobject]@{name='AbnormalExplorerExitTimes';kind='Binary';value=[Convert]::ToBase64String($bytes)},
                [pscustomobject]@{name='AbnormalExplorerWindowStart';kind='QWord';value=$(
                    if ($WindowStart) { $WindowStart } else { [uint64]$Times[0] })},
                [pscustomobject]@{name='InjectionDisabled';kind='DWord';value=$(if ($Disabled) {1} else {0})},
                [pscustomobject]@{name='LastExplorerExitCode';kind='DWord';value=1})
            subkeys=@()
        }
    }
    $bounds = @(
        [pscustomobject]@{issuedFileTimeUtc=[uint64]10;observedFileTimeUtc=[uint64]19},
        [pscustomobject]@{issuedFileTimeUtc=[uint64]20;observedFileTimeUtc=[uint64]29},
        [pscustomobject]@{issuedFileTimeUtc=[uint64]30;observedFileTimeUtc=[uint64]39})
    [uint64[]]$prior = @()
    foreach ($stage in 1..3) {
        [uint64[]]$times = @(15,25,35 | Select-Object -First $stage)
        $result = & $library {
            param($snapshot, $count, $disabled, $boundaries, $priorTimes)
            Assert-RollingCrashGuardStage -Snapshot $snapshot -ExpectedCount $count `
                -ExpectedDisabled $disabled -Boundaries $boundaries `
                -PriorTimestamps $priorTimes
        } (New-CrashGuardFixture -Count $stage -Disabled ($stage -eq 3) -Times $times) `
            $stage ($stage -eq 3) @($bounds | Select-Object -First $stage) $prior
        [uint64[]]$prior = @($result.timestamps100ns)
    }
    $validCrash = New-CrashGuardFixture -Count 1 -Disabled $false `
        -Times @([uint64]15)
    foreach ($invalidCrash in @(
        (& {
            $copy = $validCrash | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $copy.values = @($copy.values | Where-Object {
                $_.name -cne 'AbnormalExplorerWindowStart' })
            $copy
        }),
        (& {
            $copy = $validCrash | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $copy.values += [pscustomobject]@{name='Unexpected';kind='DWord';value=0}
            $copy
        }),
        (& {
            $copy = $validCrash | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            ($copy.values | Where-Object name -eq 'AbnormalExplorerWindowStart').kind='DWord'
            $copy
        }),
        (& {
            $copy = $validCrash | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            ($copy.values | Where-Object name -eq 'AbnormalExplorerWindowStart').value=14
            $copy
        }),
        (& {
            $copy = $validCrash | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            ($copy.values | Where-Object name -eq 'AbnormalExplorerExitTimes').value=
                [Convert]::ToBase64String([byte[]]::new(16))
            $copy
        }))) {
        Assert-Throws {
            & $library {
                param($snapshot, $boundaries)
                Assert-RollingCrashGuardStage -Snapshot $snapshot `
                    -ExpectedCount 1 -ExpectedDisabled $false `
                    -Boundaries $boundaries
            } $invalidCrash @($bounds[0])
        } 'exact five-value crash-guard schema accepted an invalid fixture'
    }

    & $library { param($root) Remove-A4STemporaryRoot -Root $root } $temporaryRoot
    Assert-Contract (-not (Test-Path -LiteralPath $temporaryRoot.finalPath)) `
        'real flat temporary cleanup retained its validated root'
    $temporaryRoot = $null

    Write-Host ('A4S failure/recovery offline contracts passed: locked static PE/manifest ' +
        'ordering, exact crash schema, retained Explorer identity predicates, opaque ' +
        'mutation capabilities, stale-CAS rejection, every journal failure point, all ' +
        'durable hard-interruption phases, repeated recovery interruptions, ' +
        'deterministic recovery/rollback, and ' +
        'non-recursive cleanup were executed.')
}
catch {
    $primaryError = $_
}
finally {
    # The isolated random subtree is the sole registry test seam. Clean it with
    # the same journal engine even if a contract assertion failed midway.
    try {
        if ($sandboxOwnershipEstablished) {
            $actual = & $library {
                param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
            } $sandboxSubKey
            if ([bool]$actual.snapshot.exists) {
                $absentCleanup = [pscustomobject][ordered]@{
                    exists=$false; values=@(); subkeys=@()
                }
                $cleanupBoundary = { param([string] $Label) return $true }
                if (-not (Get-Command New-ContractTransactionAssets `
                    -CommandType Function -ErrorAction SilentlyContinue)) {
                    throw 'Contract cleanup cannot create its required durable transaction assets.'
                }
                $cleanupAssets = New-ContractTransactionAssets -ExpectedAggregate $actual
                [void](& $library {
                    param($key, $desired, $expected, $validator, $assets)
                    Invoke-A4SRegistrySnapshotTransaction -RegistrySubKey $key `
                        -DesiredSnapshot $desired -ExpectedCurrent $expected `
                        -ValidateBoundary $validator -ContractRegistrySandbox `
                        -TransactionDescriptorPath $assets.descriptorPath `
                        -RollbackBundle $assets.bundle `
                        -RollbackManifestSha256 $assets.rollbackManifestSha256
                } $sandboxSubKey $absentCleanup $actual $cleanupBoundary $cleanupAssets)
            }
            $confirmedAbsent = & $library {
                param($key) Get-RegistryAggregateRecord -RegistrySubKey $key
            } $sandboxSubKey
            if ([bool]$confirmedAbsent.snapshot.exists) {
                throw 'The isolated registry contract subtree remains after transactional cleanup.'
            }
        }
    }
    catch {
        if ($null -eq $primaryError) { $primaryError = $_ }
        else {
            $primaryError = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new(
                    "$($primaryError.Exception.Message) Cleanup also failed: $($_.Exception.Message)"),
                'A4SContractCleanupFailure',
                [Management.Automation.ErrorCategory]::InvalidResult, $sandboxSubKey)
        }
    }

    if ($null -ne $temporaryRoot -and
        (Test-Path -LiteralPath $temporaryRoot.finalPath -PathType Container)) {
        try { & $library { param($root) Remove-A4STemporaryRoot -Root $root } $temporaryRoot }
        catch {
            if ($null -eq $primaryError) { $primaryError = $_ }
            else {
                $primaryError = [Management.Automation.ErrorRecord]::new(
                    [InvalidOperationException]::new(
                        "$($primaryError.Exception.Message) Temporary cleanup also failed: $($_.Exception.Message)"),
                    'A4SContractTemporaryCleanupFailure',
                    [Management.Automation.ErrorCategory]::InvalidResult,
                    $temporaryRoot.finalPath)
            }
        }
    }
    Remove-Module -ModuleInfo $library -Force -ErrorAction SilentlyContinue
}

if ($primaryError) { throw $primaryError }
