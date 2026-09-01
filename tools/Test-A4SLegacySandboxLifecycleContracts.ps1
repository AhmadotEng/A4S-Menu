[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$hostPath = Join-Path $PSScriptRoot 'Invoke-A4SLegacySandboxLifecycle.ps1'
$bootstrapPath = Join-Path $PSScriptRoot 'Invoke-A4SLegacySandboxBootstrap.ps1'
$guestPath = Join-Path $PSScriptRoot 'Invoke-A4SLegacySandboxGuest.ps1'

function Assert-Contract {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "A4S legacy Sandbox contract failed: $Message" }
}

function Parse-Script {
    param([Parameter(Mandatory)][string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell parser errors in $Path`: $($errors -join ' | ')"
    }
    return $ast
}

function Assert-ContainsOrdinal {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Marker,
        [Parameter(Mandatory)][string] $Description
    )
    Assert-Contract ($Text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) `
        "$Description is missing '$Marker'"
}

function Assert-OrderedMarkers {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string[]] $Markers,
        [Parameter(Mandatory)][string] $Description
    )
    $offset = 0
    foreach ($marker in $Markers) {
        $index = $Text.IndexOf($marker, $offset, [StringComparison]::Ordinal)
        Assert-Contract ($index -ge 0) "$Description omits or misorders '$marker'"
        $offset = $index + $marker.Length
    }
}

foreach ($path in @($hostPath, $bootstrapPath, $guestPath)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "missing $path"
}
$hostSource = [IO.File]::ReadAllText($hostPath)
$bootstrapSource = [IO.File]::ReadAllText($bootstrapPath)
$guestSource = [IO.File]::ReadAllText($guestPath)
$hostAst = Parse-Script $hostPath
$bootstrapAst = Parse-Script $bootstrapPath
$guestAst = Parse-Script $guestPath

$guestStageDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Write-GuestStage'
}, $true))
Assert-Contract ($guestStageDefinitions.Count -eq 1) `
    'guest must define exactly one executable Write-GuestStage function'

$exactProcessDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Invoke-ExactProcess'
}, $true))
Assert-Contract ($exactProcessDefinitions.Count -eq 1) `
    'guest must define exactly one executable Invoke-ExactProcess function'
$exactProcessText = $exactProcessDefinitions[0].Extent.Text
foreach ($marker in @(
        '[ValidateRange(1, 300)][int] $TimeoutSeconds = 120',
        '[ValidateRange(100, 10000)][int] $KillWaitMilliseconds = 5000',
        '[ValidateNotNullOrEmpty()][int[]] $AcceptedExitCodes = @(0)',
        '$AcceptedExitCodes.Count -lt 1 -or $AcceptedExitCodes.Count -gt 16',
        '$acceptedExitCodeSet = [Collections.Generic.HashSet[int]]::new()',
        '$acceptedExitCodeSet.Contains([int]$record.ExitCode)',
        '$process.WaitForExit($TimeoutSeconds * 1000)',
        '$failureKind = ''timeout''',
        'throw [TimeoutException]::new(',
        '$causalError = $_',
        '$cleanup = Stop-ExactProcessBounded -Process $process',
        '$causalError.Exception.Data[''A4SExactProcessId''] = $childProcessId',
        '$causalError.Exception.Data[''A4SKillAttempted''] = $cleanup.KillAttempted',
        '$causalError.Exception.Data[''A4SKillReturned''] = $cleanup.KillReturned',
        '$causalError.Exception.Data[''A4SExitConfirmed''] = $cleanup.ExitConfirmed',
        'if ($failureKind -ceq ''timeout'' -and $TimeoutStageOrdinal -ne 0)',
        'Write-GuestStage -Ordinal $TimeoutStageOrdinal -Stage $TimeoutStage',
        'if (-not $cleanup.ExitConfirmed)',
        '$causalError.Exception)',
        'finally {',
        'try { $process.Dispose() }',
        'return $record')) {
    Assert-ContainsOrdinal $exactProcessText $marker 'guest bounded exact-process lifetime'
}
Assert-Contract (-not [regex]::IsMatch($exactProcessText,
        '\.WaitForExit\(\s*\)')) `
    'guest exact-process timeout contains a parameterless unbounded WaitForExit call'
Assert-Contract ([regex]::Matches($exactProcessText,
        '\.WaitForExit\(').Count -eq 1) `
    'guest exact-process runner must contain exactly one bounded primary wait'
Assert-Contract ([regex]::Matches($exactProcessText,
        '\.Kill\(\)').Count -eq 0) `
    'guest exact-process runner must centralize direct-child cleanup in its bounded helper'
Assert-Contract ([regex]::Matches($exactProcessText,
        'Stop-ExactProcessBounded\s+-Process\s+\$process').Count -eq 1) `
    'guest exact-process runner must have exactly one common exceptional cleanup path'

$boundedStopDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Stop-ExactProcessBounded'
}, $true))
Assert-Contract ($boundedStopDefinitions.Count -eq 1) `
    'guest must define exactly one bounded exact-process cleanup helper'
$boundedStopText = $boundedStopDefinitions[0].Extent.Text
foreach ($marker in @(
        '[Diagnostics.Process] $Process',
        '[Parameter(Mandatory)][int] $ProcessId',
        '[ValidateRange(100, 10000)][int] $WaitMilliseconds',
        '$killAttempted = $true',
        '$Process.Kill()',
        '$killReturned = $true',
        '$Process.WaitForExit($WaitMilliseconds)',
        'ExitConfirmed = $exitConfirmed')) {
    Assert-ContainsOrdinal $boundedStopText $marker `
        'guest bounded exact-process cleanup helper'
}
Assert-OrderedMarkers $boundedStopText @(
    '$killAttempted = $true',
    '$Process.Kill()',
    '$Process.WaitForExit($WaitMilliseconds)') `
    'guest exact-process kill attempt and bounded confirmation order'
Assert-Contract (-not [regex]::IsMatch($boundedStopText,
        '\.WaitForExit\(\s*\)')) `
    'guest exact-process cleanup helper contains a parameterless unbounded wait'
Assert-Contract ([regex]::Matches($boundedStopText,
        '\.WaitForExit\(').Count -eq 1 -and
    [regex]::Matches($boundedStopText, '\.Kill\(\)').Count -eq 1) `
    'guest exact-process cleanup helper must have one Kill and one bounded confirmation wait'

$explorerProbeDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Initialize-ExplorerProbe'
}, $true))
Assert-Contract ($explorerProbeDefinitions.Count -eq 1) `
    'guest must define exactly one executable native Explorer probe initializer'
$explorerProbeText = $explorerProbeDefinitions[0].Extent.Text
foreach ($marker in @('OpenProcess', 'EnumProcessModulesEx',
        'GetModuleFileNameExW', 'QueryFullProcessImageNameW',
        'private const int SnapshotAttemptLimit = 8;',
        'private const int MaximumModuleCount = 4096;',
        'private const int MaximumPathCharacters = 32768;',
        'for (int attempt = 0; attempt < SnapshotAttemptLimit; ++attempt)',
        'for (int moduleIndex = 0; moduleIndex < requiredCount; ++moduleIndex)',
        'requiredCount64 > MaximumModuleCount',
        'HashSet<IntPtr> uniqueHandles', 'HashSet<string> uniquePaths',
        '!uniqueHandles.Add(module)', '!uniquePaths.Add(modulePath)',
        'uniqueHandles.Count != requiredCount',
        'uniquePaths.Count != requiredCount',
        'using System.Collections.Generic;', 'using System.Threading;',
        'finally', 'CloseHandle(process)',
        'Explorer PSAPI module snapshot remained unstable after eight attempts')) {
    Assert-ContainsOrdinal $explorerProbeText $marker 'guest native Explorer module snapshot'
}
foreach ($forbiddenProbeMarker in @('CreateToolhelp32Snapshot',
        'Module32First', 'Module32Next', 'TH32CS_SNAPMODULE')) {
    Assert-Contract ($explorerProbeText.IndexOf($forbiddenProbeMarker,
            [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "guest native Explorer module snapshot retained forbidden Toolhelp marker '$forbiddenProbeMarker'"
}
Assert-Contract (-not [regex]::IsMatch($explorerProbeText, '\bwhile\s*\(')) `
    'guest native Explorer module snapshot contains a data-dependent while loop'
$moduleInventoryDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Get-ExplorerModuleInventory'
}, $true))
Assert-Contract ($moduleInventoryDefinitions.Count -eq 1) `
    'guest must define exactly one executable Explorer module inventory function'
$moduleInventoryText = $moduleInventoryDefinitions[0].Extent.Text
Assert-ContainsOrdinal $moduleInventoryText `
    '[A4SSandboxWindowProbe]::ModuleSnapshotForProcess($ExplorerPid)' `
    'guest native Explorer module inventory call'
foreach ($marker in @('$snapshot.TotalModuleCount', '$snapshot.MainModulePath',
        'Join-Path $env:SystemRoot ''explorer.exe''',
        '$mainModulePath.Equals($canonicalExplorerPath',
        '(Get-TaskbarExplorerPid) -ne $ExplorerPid')) {
    Assert-ContainsOrdinal $moduleInventoryText $marker `
        'guest native Explorer module inventory completeness proof'
}
Assert-Contract (-not [regex]::IsMatch($moduleInventoryText,
        '(?i)\.Modules\b')) `
    'guest Explorer inventory regressed to an unbounded Process.Modules enumeration'
Assert-Contract (-not [regex]::IsMatch($guestSource,
        '(?i)\$process\.Modules\b')) `
    'guest contains a forbidden Process.Modules enumeration'

$mappingWaitDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Wait-ForExplorerMenuModule'
}, $true))
Assert-Contract ($mappingWaitDefinitions.Count -eq 1) `
    'guest must define exactly one bounded Explorer menu mapping wait'
$mappingWaitText = $mappingWaitDefinitions[0].Extent.Text
foreach ($marker in @(
        '[Parameter(Mandatory)][string] $ExpectedPath',
        '[ValidateRange(1, 512)][int] $MaximumAttempts = 100',
        'for ($attempt = 1; $attempt -le $MaximumAttempts; ++$attempt)',
        'if ([DateTime]::UtcNow -ge $deadline) { break }',
        '@($inventory.Modules).Count -eq 1',
        '[string]$inventory.Modules[0].Sha256 -ceq $ExpectedSha256',
        '[IO.Path]::GetFullPath([string]$inventory.Modules[0].Path)',
        '$expectedFullPath, [StringComparison]::OrdinalIgnoreCase')) {
    Assert-ContainsOrdinal $mappingWaitText $marker `
        'guest exact bounded Explorer menu mapping wait'
}

$statusModelDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Resolve-V1HostStatus'
}, $true))
Assert-Contract ($statusModelDefinitions.Count -eq 1) `
    'guest must define exactly one strict V1 host status model'
$statusModelText = $statusModelDefinitions[0].Extent.Text
foreach ($marker in @(
        "0 { [ordered]@{ State = 'ready'; Disposition = 'ready'",
        "1 { [ordered]@{ State = 'starting'; Disposition = 'retry'",
        "2 { [ordered]@{ State = 'injecting'; Disposition = 'retry'",
        "4 { [ordered]@{ State = 'failed'; Disposition = 'terminal'",
        "5 { [ordered]@{ State = 'stopping'; Disposition = 'terminal'",
        "6 { [ordered]@{ State = 'safety-disabled'; Disposition = 'terminal'",
        "1062 { [ordered]@{ State = 'service-not-active'; Disposition = 'retry'",
        'A4SMenuHost: ready', 'A4SMenuHost: stopped',
        '$stdout = [string]$Execution.Stdout',
        'if (-not [string]::IsNullOrEmpty([string]$Execution.Stderr))',
        'Where-Object { [string]$_ -ceq $stdout }')) {
    Assert-ContainsOrdinal $statusModelText $marker 'guest strict V1 host status model'
}
Assert-Contract ($statusModelText.IndexOf('TrimEnd',
        [StringComparison]::Ordinal) -lt 0) `
    'guest V1 host status model normalizes rather than exactly validates stdout'

$readinessWaitDefinitions = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Wait-ForV1HostReadiness'
}, $true))
Assert-Contract ($readinessWaitDefinitions.Count -eq 1) `
    'guest must define exactly one bounded V1 host readiness poll'
$readinessWaitText = $readinessWaitDefinitions[0].Extent.Text
foreach ($marker in @(
        '[ValidateRange(1, 64)][int] $MaximumAttempts = 64',
        '[ValidateRange(10, 1000)][int] $RetryDelayMilliseconds = 250',
        'for ($attempt = 1; $attempt -le $MaximumAttempts; ++$attempt)',
        'if ([DateTime]::UtcNow -ge $deadline) { break }',
        '-AcceptedExitCodes @(0, 1, 2, 4, 5, 6, 1062)',
        'if ($status.Disposition -ceq ''ready'')',
        'if ($status.Disposition -ceq ''terminal'')',
        '$Evidence.Attempts.Add($attemptRecord)',
        '$Evidence.FinalStatus = $attemptRecord')) {
    Assert-ContainsOrdinal $readinessWaitText $marker `
        'guest bounded V1 host readiness poll'
}

$hostReplacementDefinitions = @($hostAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Publish-HostResultReplacement'
}, $true))
Assert-Contract ($hostReplacementDefinitions.Count -eq 1) `
    'host must define exactly one Publish-HostResultReplacement helper'
$hostReplacementText = $hostReplacementDefinitions[0].Extent.Text
foreach ($replacementMarker in @('$backupPath', '$rollbackDiscardPath',
        '[IO.File]::Replace($stagedFull, $destinationFull, $backupPath, $true)',
        '[IO.File]::Replace($backupPath, $destinationFull,')) {
    Assert-ContainsOrdinal $hostReplacementText $replacementMarker `
        'host-result transactional replacement'
}
Assert-Contract (-not [regex]::IsMatch($hostSource,
        '(?s)\[IO\.File\]::Replace\([^\)]{0,500}\$null')) `
    'host runner regressed to a null File.Replace backup path'

foreach ($entry in @(
        [ordered]@{ Ast = $hostAst; Name = 'Read-Utf8JsonSnapshot'; Label = 'host' },
        [ordered]@{ Ast = $guestAst; Name = 'Read-Utf8JsonSnapshot'; Label = 'guest' },
        [ordered]@{ Ast = $guestAst; Name = 'Get-WindowsSandboxIdentity'; Label = 'guest' })) {
    $definitions = @($entry.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ieq $entry.Name
    }, $true))
    Assert-Contract ($definitions.Count -eq 1) `
        "$($entry.Label) must define exactly one executable $($entry.Name) function"
    if ($entry.Name -ieq 'Read-Utf8JsonSnapshot') {
        $readerText = $definitions[0].Extent.Text
        foreach ($readerMarker in @('[IO.File]::Open', '[IO.FileShare]::Read',
                'ComputeHash($bytes)', '$text | ConvertFrom-Json')) {
            Assert-ContainsOrdinal $readerText $readerMarker `
                "$($entry.Label) single-read JSON snapshot"
        }
    }
}

foreach ($marker in @(
        '[switch] $AllowSandboxLaunch',
        "if (-not `$AllowSandboxLaunch)",
        "Get-Command WindowsSandbox.exe",
        "Join-Path ([Environment]::SystemDirectory)",
        'resolved outside the canonical System32 path',
        "Where-Object { `$_.ProcessName -match '^WindowsSandbox' }",
        'Get-HostProductSnapshot',
        '$hostBeforeSha256 = Get-ObjectSha256 $hostBefore',
        '$hostAfterSha256 = Get-ObjectSha256 $hostAfter',
        '$launchRecord.HostStateUnchanged',
        '$launchRecord.ExplorerPidUnchanged',
        'RequestSha256',
        'EvidenceSha256',
        'Read-Utf8JsonSnapshot -Path $completionPath',
        'Read-Utf8JsonSnapshot -Path $guestEvidencePath',
        '$guestEvidence.Environment.WindowsIdentity.Sid',
        '$guestEvidence.Environment.Configuration.ControlReadOnly',
        'Read-AuthenticatedBootstrapStage',
        'Read-AuthenticatedGuestExit',
        'guest-exit.json',
        'bootstrap-publication-failure.txt',
        'Diagnostic (bounded):',
        '$BootstrapTimeoutSeconds seconds',
        '$GuestExitTimeoutSeconds seconds',
        "[string]`$completion.Status -ceq 'Failed'",
        'The Sandbox guest reported failure:',
        'Windows Sandbox exited without publishing a completion record',
        'The runner did not terminate Windows Sandbox')) {
    Assert-ContainsOrdinal $hostSource $marker 'host launch/result safety'
}
Assert-OrderedMarkers $hostSource @(
    "if (-not `$AllowSandboxLaunch)",
    '$hostBefore = Get-HostProductSnapshot',
    '[IO.Directory]::CreateDirectory($sessionDirectory)',
    '[IO.Directory]::CreateDirectory($hostDirectory)',
    '[IO.Directory]::CreateDirectory($controlDirectory)',
    '[IO.Directory]::CreateDirectory($resultDirectory)',
    'Start-Process -FilePath $sandboxCommand.Source',
    '$hostAfter = Get-HostProductSnapshot') 'host opt-in and before/after boundary'
Assert-ContainsOrdinal $hostSource `
    "Join-Path `$hostDirectory 'host-result.json'" `
    'unmapped mutable host-result path'
Assert-ContainsOrdinal $hostSource `
    'The mutable host-result directory must be disjoint from every Sandbox mapping.' `
    'host-result mapping separation guard'
Assert-Contract ($hostSource.IndexOf(
        "Join-Path `$controlDirectory 'host-result.json'",
        [StringComparison]::Ordinal) -lt 0) `
    'mutable host-result regressed into the read-only control mapping'
Assert-OrderedMarkers $hostSource @(
    '$hostFailure = $null',
    'try {',
    '$sandboxProcess = Start-Process',
    'Publish-HostResultReplacement -StagedPath $startedHostResult',
    'catch {',
    '$hostFailure = $_') 'post-launch failure capture boundary'
$hostResultWaits = @($hostAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.WhileStatementAst] -and
        $node.Extent.Text.IndexOf('$completionPath',
            [StringComparison]::Ordinal) -ge 0
}, $true))
Assert-Contract ($hostResultWaits.Count -eq 1) `
    'host must define exactly one completion/bootstrap/exit wait state machine'
$hostResultWaitText = $hostResultWaits[0].Extent.Text
$resultWaitBreaks = @($hostResultWaits[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.BreakStatementAst]
}, $true))
Assert-Contract ($resultWaitBreaks.Count -eq 1) `
    'host result wait must break only after the complete authenticated result set'
Assert-OrderedMarkers $hostResultWaitText @(
    '$completion = $completionSnapshot.Value',
    'Read-AuthenticatedBootstrapStage',
    'Read-AuthenticatedGuestExit',
    '$bootstrapPublicationFailurePath',
    '$null -ne $completion',
    '$null -ne $launchRecord.Bootstrap',
    '$null -ne $guestExit',
    'break') 'host authenticated completion/bootstrap/exit state machine'
Assert-OrderedMarkers $hostSource @(
    '$launchRecord.Succeeded =',
    '$null -ne $launchRecord.Bootstrap',
    '$null -ne $launchRecord.GuestExit',
    '[int]$launchRecord.GuestExit.ExitCode -eq 0',
    "[string]`$completion.Status -ceq 'Passed'") `
    'host success requires bootstrap, zero guest exit, and passed completion'

foreach ($marker in @(
        '<vGPU>Disable</vGPU>',
        '<Networking>Disable</Networking>',
        '<AudioInput>Disable</AudioInput>',
        '<VideoInput>Disable</VideoInput>',
        '<ProtectedClient>Enable</ProtectedClient>',
        '<PrinterRedirection>Disable</PrinterRedirection>',
        '<ClipboardRedirection>Disable</ClipboardRedirection>',
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        'Invoke-A4SLegacySandboxBootstrap.ps1',
        '<SandboxFolder>C:\A4S\Repo</SandboxFolder>',
        '<ReadOnly>true</ReadOnly>',
        '<SandboxFolder>C:\A4S\Control</SandboxFolder>',
        '<SandboxFolder>C:\A4S\Evidence</SandboxFolder>',
        '<ReadOnly>false</ReadOnly>')) {
    Assert-ContainsOrdinal $hostSource $marker 'Sandbox isolation configuration'
}
foreach ($hostFolder in @('C:\Qualification\Repo',
        'D:\Qualification Evidence\Session\control',
        'D:\Qualification Evidence\Session\results')) {
    Assert-ContainsOrdinal $hostSource $hostFolder `
        'exact three-folder Sandbox host mapping contract'
}
Assert-ContainsOrdinal $hostSource `
    "throw 'The writable evidence root must be disjoint from the read-only repository mapping.'" `
    'mapping overlap rejection'
Assert-ContainsOrdinal $hostSource `
    'The V2 setup must be inside the read-only repository mapping' `
    'V2 fixture confinement'
Assert-ContainsOrdinal $hostSource `
    'C:\A4S\Control\request.json' 'read-only control-channel request path'
Assert-ContainsOrdinal $hostSource `
    'if ($candidateFull.TrimEnd(' 'mapping equality is rejected as overlap'

foreach ($forbidden in @('Stop-Process', 'Restart-Computer', 'Restart-Service',
        'taskkill', 'shutdown.exe', 'Remove-Item', 'Set-ItemProperty',
        'New-ItemProperty', 'Remove-ItemProperty')) {
    Assert-Contract ($hostSource.IndexOf($forbidden,
            [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "host runner contains forbidden mutation command '$forbidden'"
}
$hostStartProcesses = @($hostAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Start-Process'
}, $true))
Assert-Contract ($hostStartProcesses.Count -eq 1) `
    'host runner must start exactly one process (WindowsSandbox.exe)'
Assert-Contract ($hostStartProcesses[0].Extent.Text.IndexOf('$sandboxCommand.Source',
        [StringComparison]::Ordinal) -ge 0) `
    'host Start-Process target is not the resolved WindowsSandbox.exe'

foreach ($marker in @(
        '[Security.Principal.WindowsIdentity]::GetCurrent()',
        "`$sid -notmatch '^S-1-5-21-(?:[0-9]+-){3}504$'",
        "`$requestFullPath -ine 'C:\A4S\Control\request.json'",
        'Write-GuestStage -Ordinal 10',
        'Write-GuestStage -Ordinal 17',
        'Write-GuestStage -Ordinal 23',
        '@(Get-A4SProcessInventory).Count',
        'Resolve-GuestSetupSources',
        'Join-Path $repoRoot',
        '([string]$request.V1SetupRelativePath)',
        '([string]$request.V2SetupRelativePath)',
        'C:\A4S\Repo\build\fixtures\A4SMenuSetup-v1.exe',
        'C:\A4S\Repo\build\reviewed product\A4SMenuSetup-v2.exe',
        'Read-Utf8JsonSnapshot -Path $requestFullPath',
        'Assert-SandboxConfiguration',
        'Assert-NetworkDisabled',
        'An operational non-loopback network path is present in Sandbox.',
        'Assert-CleanDisposableStart',
        'The reviewed V1 DLL was not observed in the unchanged taskbar Explorer process.',
        'Explorer identity or complete canonical module proof changed at',
        '--restart-explorer is forbidden in the Sandbox lifecycle matrix.',
        'User-owned Config/Menu/legacy state changed',
        'DataCache.db changed',
        'retained an incomplete servicing journal or recovery continuation',
        'Unexpected cleanup continuation at',
        'exact identity-bound cleanup RunOnce command',
        'retained its Windows Settings uninstall registration',
        'LogicallyUninstalledPhysicalCleanupPendingExplorerExit',
        'completion.json')) {
    Assert-ContainsOrdinal $guestSource $marker 'guest isolation/evidence safety'
}
$setupSourceResolvers = @($guestAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq 'Resolve-GuestSetupSources'
}, $true))
Assert-Contract ($setupSourceResolvers.Count -eq 1) `
    'guest must define exactly one shared executable setup-source resolver'
Assert-Contract (-not [regex]::IsMatch($guestSource,
        'Join-Path\s+\$\w+\s+\[string\]\$\w+\.(?:V1|V2)SetupRelativePath')) `
    'guest regressed to the Windows PowerShell unparenthesized cast/Join-Path parse bug'
Assert-Contract (-not [regex]::IsMatch($guestSource,
        '(?<!@)\(Get-A4SProcessInventory\)\.Count')) `
    'guest clean-state inventory regressed to StrictMode-unsafe null .Count access'
Assert-OrderedMarkers $guestSource @(
    '$sandboxIdentity = Get-WindowsSandboxIdentity',
    '$requestSnapshot = Read-Utf8JsonSnapshot',
    'Assert-CleanDisposableStart',
    'Set-SentinelUserState -Nonce',
    "Write-GuestStage -Ordinal 24 -Stage 'install-v1-process-starting'",
    '$installV1Execution = Invoke-ExactProcess',
    "-StartedStageOrdinal 25 -StartedStage 'install-v1-process-started'",
    "-TimeoutStageOrdinal 26 -TimeoutStage 'install-v1-process-timeout'",
    "Write-GuestStage -Ordinal 27 -Stage 'install-v1-process-exited'",
    "Write-GuestStage -Ordinal 28 -Stage 'install-v1-checkpoint-starting'",
    "`$installV1Checkpoint = Get-Checkpoint 'install-v1'",
    "Write-GuestStage -Ordinal 29 -Stage 'install-v1-checkpoint-captured'",
    "Write-GuestStage -Ordinal 30 -Stage 'v1-mapping-wait-starting'",
    '$v1Mapping = Wait-ForExplorerMenuModule',
    '-ExpectedPath ([string]$v1Payload.Menu.Path)',
    "Write-GuestStage -Ordinal 31 -Stage 'v1-mapping-observed'",
    "Write-GuestStage -Ordinal 32 -Stage 'v1-host-status-poll-starting'",
    '$v1Readiness = Wait-ForV1HostReadiness',
    "Write-GuestStage -Ordinal 33 -Stage 'v1-host-status-ready'",
    "Write-GuestStage -Ordinal 34 -Stage 'v1-ready-mapping-recheck-starting'",
    '$v1ReadyMapping = Wait-ForExplorerMenuModule',
    "Write-GuestStage -Ordinal 35 -Stage 'v1-ready-mapping-recheck-completed'",
    "Write-GuestStage -Ordinal 36 -Stage 'v1-host-exit-starting'",
    '$v1Exit = Invoke-ExactProcess',
    "Write-GuestStage -Ordinal 37 -Stage 'v1-host-exit-completed'",
    "Name = 'install-v1'",
    "Name = 'update-v1-to-v2'",
    "Name = 'rollback-v2-to-v1'",
    "Name = 'update-v1-to-v2-again'",
    "Name = 'repair-v2-same-version'",
    "Name = 'uninstall-v2'",
    "State = 'LogicallyUninstalledPhysicalCleanupPendingExplorerExit'",
    "Join-Path `$script:evidenceRoot 'completion.json'") `
    'guest guard, fixed matrix, and completion publication'
Assert-Contract ([regex]::Matches($guestSource,
        'MenuPath\s*=\s*\[string\]\$v1(?:Ready)?Mapping\.Modules\[0\]\.Path').Count -eq 2) `
    'guest mapping stages must publish both exact pre-ready and post-ready DLL paths'

Assert-OrderedMarkers $guestSource @(
    '$failure = $_',
    "Write-GuestStage -Ordinal 38 -Stage 'failure-checkpoint-starting'",
    "`$script:evidence.FailureCheckpoint = Get-Checkpoint 'failure'",
    "Write-GuestStage -Ordinal 39 -Stage 'failure-checkpoint-captured'") `
    'guest authenticated failure-checkpoint boundary'

foreach ($hash in @(
        'DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2',
        '9995676D0B74DE2E68E0C4EACB7E4111BE1AF13AA34C3505499C3925708A0573',
        '4C1C9A325FF41A6DD089690874C95DCC8CC8CC5A4561F9B8ECCFA29832C03610')) {
    Assert-ContainsOrdinal $hostSource $hash 'host frozen-V1 identity'
    Assert-ContainsOrdinal $guestSource $hash 'guest frozen-V1 identity'
}

Assert-Contract (-not [regex]::IsMatch($guestSource,
    '-Arguments\s+@\([^\)]*[''\"]--restart-explorer[''\"]',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [Text.RegularExpressions.RegexOptions]::Singleline)) `
    'guest passes --restart-explorer to a process invocation'
foreach ($forbidden in @('Restart-Computer', 'Restart-Service', 'Stop-Process',
        'taskkill', 'shutdown.exe', 'TerminateProcess(', 'WindowsSandbox.exe')) {
    Assert-Contract ($guestSource.IndexOf($forbidden,
            [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "guest contains forbidden host/session control '$forbidden'"
}
Assert-Contract ($guestSource.IndexOf('NetworkInterfaceType]::Tunnel',
        [StringComparison]::Ordinal) -lt 0) `
    'guest network guard excludes tunnel interfaces from the fail-closed check'

foreach ($marker in @(
        'stage-{0:D3}-{1}.json',
        "-Stage 'bootstrap-entry'",
        "-Stage 'guest-process-starting'",
        "-Stage 'guest-process-exited'",
        'guest-console.log',
        'guest-exit.json',
        'ConsoleSha256',
        'New-FailClosedScriptCommand',
        "`$ErrorActionPreference = 'Stop'",
        "'-EncodedCommand'",
        'Guest PowerShell returned zero but emitted stderr; bootstrap failed closed.',
        'Start-Process -FilePath $windowsPowerShell',
        '$guestProcess.WaitForExit()',
        '-RedirectStandardOutput $stdoutPath',
        '-RedirectStandardError $stderrPath')) {
    Assert-ContainsOrdinal $bootstrapSource $marker 'Sandbox bootstrap diagnostics'
}
Assert-OrderedMarkers $bootstrapSource @(
    "-Stage 'bootstrap-entry'",
    '$actualBootstrapSha256 = Get-FileSha256',
    '$actualGuestSha256 -cne $GuestScriptSha256',
    "-Stage 'scripts-authenticated'",
    "-Stage 'guest-process-starting'",
    '$guestCommand = New-FailClosedScriptCommand',
    "'-EncodedCommand'",
    'Start-Process -FilePath $windowsPowerShell',
    '$guestProcess.WaitForExit()',
    "`$exitCode = 1",
    "-Stage 'guest-process-exited'",
    "Join-Path `$fixedEvidence 'guest-console.log'",
    "Join-Path `$fixedEvidence 'guest-exit.json'") `
    'bootstrap correlation, capture, and exit publication'
$bootstrapStartProcesses = @($bootstrapAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'Start-Process'
}, $true))
Assert-Contract ($bootstrapStartProcesses.Count -eq 1) `
    'bootstrap must start exactly one child process'
Assert-Contract ($bootstrapStartProcesses[0].Extent.Text.IndexOf('$windowsPowerShell',
        [StringComparison]::Ordinal) -ge 0) `
    'bootstrap child process is not canonical Windows PowerShell'
Assert-Contract ($bootstrapStartProcesses[0].Extent.Text.IndexOf('-Wait',
        [StringComparison]::OrdinalIgnoreCase) -lt 0) `
    'bootstrap must not wait for detached guest descendants through Start-Process -Wait'

$windowsPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-Contract ([Environment]::Is64BitProcess) `
    'offline contracts require an x64 parent so System32 resolves to production-bitness Windows PowerShell'
Assert-Contract (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) `
    'canonical Windows PowerShell 5.1 executable is missing'
$guestContractOutput = @(& $windowsPowerShell -NoLogo -NoProfile -NonInteractive `
    -ExecutionPolicy Bypass -File $guestPath -ContractSelfTest 2>&1)
$guestContractExitCode = $LASTEXITCODE
Assert-Contract ($guestContractExitCode -eq 0) `
    "guest contract failed under Windows PowerShell 5.1: $($guestContractOutput -join ' ')"
Assert-Contract (($guestContractOutput -join ' ') -match
        'guest in-memory contract passed') `
    'guest atomic evidence writer was not dynamically exercised by explicit Windows PowerShell 5.1'
Assert-Contract (($guestContractOutput -join ' ') -match
        'guest PS5 setup-source path contract passed') `
    'shared V1/V2 setup-source resolution was not dynamically exercised by explicit Windows PowerShell 5.1'
Assert-Contract (($guestContractOutput -join ' ') -match
        'guest PS5 x64 bounded native PSAPI module snapshot contract passed') `
    'guest bounded PSAPI module enumeration and main-module proof were not dynamically exercised by x64 Windows PowerShell 5.1'
Assert-Contract (($guestContractOutput -join ' ') -match
        'guest PS5 bounded V1 host readiness model contract passed') `
    'guest strict bounded V1 host readiness model was not dynamically exercised by Windows PowerShell 5.1'
Assert-Contract (($guestContractOutput -join ' ') -match
        'guest PS5 bounded process timeout contract passed') `
    'guest direct-child timeout/kill/final-wait bound was not dynamically exercised by explicit Windows PowerShell 5.1'
Assert-Contract (($guestContractOutput -join ' ') -match
        'guest PS5 started-stage failure cleanup contract passed') `
    'guest started-stage publication failure cleanup was not dynamically exercised by explicit Windows PowerShell 5.1'
$bootstrapContractOutput = @(& $windowsPowerShell -NoLogo -NoProfile -NonInteractive `
    -ExecutionPolicy Bypass -File $bootstrapPath -ContractSelfTest 2>&1)
$bootstrapContractExitCode = $LASTEXITCODE
Assert-Contract ($bootstrapContractExitCode -eq 0) `
    "bootstrap contract failed under Windows PowerShell 5.1: $($bootstrapContractOutput -join ' ')"
Assert-Contract (($bootstrapContractOutput -join ' ') -match
        'bootstrap contract passed under Windows PowerShell 5\.1\.') `
    'bootstrap UTF-8 publication was not dynamically exercised by explicit Windows PowerShell 5.1'
Assert-Contract (($bootstrapContractOutput -join ' ') -match
        'bootstrap PS5 fail-closed child exit contract passed') `
    'bootstrap terminating/non-terminating child failures were not dynamically exercised by explicit Windows PowerShell 5.1'
$hostContractOutput = @(& $windowsPowerShell -NoLogo -NoProfile -NonInteractive `
    -ExecutionPolicy Bypass -File $hostPath -ContractSelfTest 2>&1)
$hostContractExitCode = $LASTEXITCODE
Assert-Contract ($hostContractExitCode -eq 0) `
    "host in-memory replacement contract failed under Windows PowerShell 5.1: $($hostContractOutput -join ' ')"
Assert-Contract (($hostContractOutput -join ' ') -match
        'replacement contract passed under Windows PowerShell 5\.1\.') `
    'host existing-file replacement was not dynamically exercised by explicit Windows PowerShell 5.1'
Assert-Contract (($hostContractOutput -join ' ') -match
        'host PS5 unmapped host-result layout contract passed') `
    'host-result confinement outside all Sandbox mappings was not dynamically exercised by explicit Windows PowerShell 5.1'

# Default invocation must fail before it can create evidence or launch anything.
$defaultRejected = $false
try { & $hostPath }
catch {
    $defaultRejected = $_.Exception.Message -match 'not launched by default'
}
Assert-Contract $defaultRejected 'host default invocation did not fail closed on missing opt-in'

Write-Host 'A4S legacy Windows Sandbox lifecycle offline contracts passed.'
