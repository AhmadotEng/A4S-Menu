[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$hostPath = Join-Path $PSScriptRoot 'Invoke-A4SLegacySandboxLifecycle.ps1'
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

foreach ($path in @($hostPath, $guestPath)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "missing $path"
}
$hostSource = [IO.File]::ReadAllText($hostPath)
$guestSource = [IO.File]::ReadAllText($guestPath)
$hostAst = Parse-Script $hostPath
$guestAst = Parse-Script $guestPath

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
    '[IO.Directory]::CreateDirectory($controlDirectory)',
    '[IO.Directory]::CreateDirectory($resultDirectory)',
    'Start-Process -FilePath $sandboxCommand.Source',
    '$hostAfter = Get-HostProductSnapshot') 'host opt-in and before/after boundary'

foreach ($marker in @(
        '<vGPU>Disable</vGPU>',
        '<Networking>Disable</Networking>',
        '<AudioInput>Disable</AudioInput>',
        '<VideoInput>Disable</VideoInput>',
        '<ProtectedClient>Enable</ProtectedClient>',
        '<PrinterRedirection>Disable</PrinterRedirection>',
        '<ClipboardRedirection>Disable</ClipboardRedirection>',
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '<SandboxFolder>C:\A4S\Repo</SandboxFolder>',
        '<ReadOnly>true</ReadOnly>',
        '<SandboxFolder>C:\A4S\Control</SandboxFolder>',
        '<SandboxFolder>C:\A4S\Evidence</SandboxFolder>',
        '<ReadOnly>false</ReadOnly>')) {
    Assert-ContainsOrdinal $hostSource $marker 'Sandbox isolation configuration'
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
        'Read-Utf8JsonSnapshot -Path $requestFullPath',
        'Assert-SandboxConfiguration',
        'Assert-NetworkDisabled',
        'An operational non-loopback network path is present in Sandbox.',
        'Assert-CleanDisposableStart',
        'The reviewed V1 DLL was not observed in the unchanged taskbar Explorer process.',
        'Explorer PID changed at',
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
Assert-OrderedMarkers $guestSource @(
    '$sandboxIdentity = Get-WindowsSandboxIdentity',
    '$requestSnapshot = Read-Utf8JsonSnapshot',
    'Assert-CleanDisposableStart',
    'Set-SentinelUserState -Nonce',
    "Name = 'install-v1'",
    "Name = 'update-v1-to-v2'",
    "Name = 'rollback-v2-to-v1'",
    "Name = 'update-v1-to-v2-again'",
    "Name = 'repair-v2-same-version'",
    "Name = 'uninstall-v2'",
    "State = 'LogicallyUninstalledPhysicalCleanupPendingExplorerExit'",
    "Join-Path `$script:evidenceRoot 'completion.json'") `
    'guest guard, fixed matrix, and completion publication'

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

& $hostPath -ContractSelfTest
& $guestPath -ContractSelfTest

# Default invocation must fail before it can create evidence or launch anything.
$defaultRejected = $false
try { & $hostPath }
catch {
    $defaultRejected = $_.Exception.Message -match 'not launched by default'
}
Assert-Contract $defaultRejected 'host default invocation did not fail closed on missing opt-in'

Write-Host 'A4S legacy Windows Sandbox lifecycle offline contracts passed.'
