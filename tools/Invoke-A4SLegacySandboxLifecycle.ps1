<#
.SYNOPSIS
Launches the legacy A4S installer lifecycle matrix in a disposable Windows Sandbox.

.DESCRIPTION
The host side is deliberately fail-closed. It maps this repository and a
per-run control directory read-only, maps only the per-run results directory
read/write, launches Windows Sandbox only with -AllowSandboxLaunch, and verifies
that the host A4S product state and
Explorer PID did not change while the guest ran. It never executes either
installer on the host and never restarts Explorer.

.EXAMPLE
.\tools\Invoke-A4SLegacySandboxLifecycle.ps1 `
    -V2SetupPath .\build\A4SProduct\bin\x64\A4SMenuSetup.exe `
    -ExpectedV2SetupSha256 <sha256> `
    -ExpectedV2HostSha256 <sha256> `
    -ExpectedV2MenuSha256 <sha256> `
    -AllowSandboxLaunch
#>
[CmdletBinding()]
param(
    [string] $V2SetupPath,

    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ExpectedV2SetupSha256,

    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ExpectedV2HostSha256,

    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ExpectedV2MenuSha256,

    [ValidatePattern('^1\.1\.0\.0$')]
    [string] $ExpectedV2Version = '1.1.0.0',

    [string] $EvidenceRoot = (Join-Path $env:LOCALAPPDATA `
        'A4SMenuQualification\LegacySandboxEvidence'),

    [ValidateRange(5, 90)]
    [int] $TimeoutMinutes = 30,

    [ValidateRange(10, 300)]
    [int] $BootstrapTimeoutSeconds = 60,

    [ValidateRange(5, 120)]
    [int] $GuestExitTimeoutSeconds = 15,

    [switch] $AllowSandboxLaunch,

    [switch] $ContractSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bootstrapScriptRelativePath = 'tools\Invoke-A4SLegacySandboxBootstrap.ps1'
$guestScriptRelativePath = 'tools\Invoke-A4SLegacySandboxGuest.ps1'
$v1SetupRelativePath = 'build\test-fixtures\A4SMenu-1.0.0.0\A4SMenuSetup.exe'
$frozenV1 = [ordered]@{
    Version = '1.0.0.0'
    SetupSha256 = 'DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2'
    HostSha256 = '9995676D0B74DE2E68E0C4EACB7E4111BE1AF13AA34C3505499C3925708A0573'
    MenuSha256 = '4C1C9A325FF41A6DD089690874C95DCC8CC8CC5A4561F9B8ECCFA29832C03610'
}

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.Trim().ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{64}$') { throw "Invalid SHA-256: $Value" }
    return $normalized
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Parent
    )
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $parentExact = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ($candidateFull.TrimEnd('\').Equals($parentExact,
            [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $parentFull = $parentExact + '\'
    return $candidateFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-LocalFixedPath {
    param([Parameter(Mandatory)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) {
        throw "Only a normal absolute local path is accepted: $full"
    }
    $driveName = $full.Substring(0, 1)
    $drive = [IO.DriveInfo]::new("${driveName}:\")
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "Only a ready fixed local volume is accepted: $full"
    }
    $psDrive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
    if ($psDrive.DisplayRoot) { throw "Mapped drives are not accepted: $full" }
    return $full
}

function Assert-NoReparsePointInExistingChain {
    param([Parameter(Mandatory)][string] $Path)
    $cursor = Assert-LocalFixedPath $Path
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { throw "No existing ancestor for $Path." }
        $cursor = $parent.FullName
    }
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A reparse point is not accepted in the path chain: $($item.FullName)"
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
}

function Assert-RegularFile {
    param([Parameter(Mandatory)][string] $Path)
    $full = Assert-LocalFixedPath $Path
    Assert-NoReparsePointInExistingChain $full
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Required file is missing: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A fixture may not be a reparse point: $full"
    }
    return $full
}

function Get-FixedProductVersion {
    param([Parameter(Mandatory)][string] $Path)
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return ([Version]::new($info.ProductMajorPart, $info.ProductMinorPart,
        $info.ProductBuildPart, $info.ProductPrivatePart)).ToString(4)
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE image: $Path" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    }
    finally { $stream.Dispose() }
}

function Get-FileIdentity {
    param([Parameter(Mandatory)][string] $Path)
    $full = Assert-RegularFile $Path
    if ((Get-PeMachine $full) -ne 0x8664) { throw "Qualification input is not x64: $full" }
    $item = Get-Item -LiteralPath $full -Force
    return [ordered]@{
        Path = $full
        Length = [long]$item.Length
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToUpperInvariant()
        ProductVersion = Get-FixedProductVersion $full
        OriginalFilename = $item.VersionInfo.OriginalFilename
    }
}

function ConvertTo-RegistryValueRecord {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Name
    )
    $kind = $Key.GetValueKind($Name)
    $value = $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $data = switch ($kind) {
        ([Microsoft.Win32.RegistryValueKind]::Binary) {
            [Convert]::ToBase64String([byte[]]$value); break
        }
        ([Microsoft.Win32.RegistryValueKind]::None) {
            [Convert]::ToBase64String([byte[]]$value); break
        }
        ([Microsoft.Win32.RegistryValueKind]::MultiString) { @([string[]]$value); break }
        default { [string]$value; break }
    }
    return [ordered]@{ Name = $Name; Kind = $kind.ToString(); Data = $data }
}

function Get-RegistryTreeSnapshot {
    param([Parameter(Mandatory)][string] $SubKey)
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    if ($null -eq $root) { return [ordered]@{ Present = $false; Nodes = @() } }
    $nodes = [Collections.Generic.List[object]]::new()
    function Add-Node {
        param(
            [Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key,
            [Parameter(Mandatory)][AllowEmptyString()][string] $Relative
        )
        $values = [Collections.Generic.List[object]]::new()
        foreach ($name in @($Key.GetValueNames() | Sort-Object)) {
            $values.Add((ConvertTo-RegistryValueRecord -Key $Key -Name $name))
        }
        $nodes.Add([ordered]@{ RelativePath = $Relative; Values = @($values) })
        foreach ($name in @($Key.GetSubKeyNames() | Sort-Object)) {
            $child = $Key.OpenSubKey($name, $false)
            if ($null -eq $child) { throw "Registry key disappeared during snapshot: $SubKey\\$name" }
            try {
                $childRelative = if ($Relative) { "$Relative\\$name" } else { $name }
                Add-Node -Key $child -Relative $childRelative
            }
            finally { $child.Dispose() }
        }
    }
    try { Add-Node -Key $root -Relative '' }
    finally { $root.Dispose() }
    return [ordered]@{ Present = $true; Nodes = @($nodes) }
}

function Get-SelectedRegistryValue {
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)][string] $Name
    )
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    if ($null -eq $key) { return [ordered]@{ Present = $false } }
    try {
        $actual = @($key.GetValueNames() | Where-Object { $_ -ieq $Name }) |
            Select-Object -First 1
        if ($null -eq $actual) { return [ordered]@{ Present = $false } }
        return [ordered]@{
            Present = $true
            Value = ConvertTo-RegistryValueRecord -Key $key -Name $actual
        }
    }
    finally { $key.Dispose() }
}

function Get-PathInventory {
    param([Parameter(Mandatory)][string] $Path)
    $full = Assert-LocalFixedPath $Path
    Assert-NoReparsePointInExistingChain $full
    if (-not (Test-Path -LiteralPath $full)) {
        return [ordered]@{ Present = $false; Entries = @() }
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force -Recurse |
            Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Host A4S inventory contains a reparse point: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($full.TrimEnd('\').Length).TrimStart('\')
        if ($item.PSIsContainer) {
            $entries.Add([ordered]@{ RelativePath = $relative; Kind = 'Directory' })
        }
        else {
            $entries.Add([ordered]@{
                RelativePath = $relative
                Kind = 'File'
                Length = [long]$item.Length
                Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToUpperInvariant()
            })
        }
    }
    return [ordered]@{ Present = $true; Entries = @($entries) }
}

function Get-HostProductSnapshot {
    $installRoot = Join-Path $env:LOCALAPPDATA 'A4SMenu'
    return [ordered]@{
        Product = Get-RegistryTreeSnapshot 'Software\A4SMenu'
        Lifecycle = Get-RegistryTreeSnapshot 'Software\A4SMenuLifecycle'
        Uninstall = Get-RegistryTreeSnapshot 'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu'
        Run = Get-SelectedRegistryValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'A4SMenu'
        CleanupRunOnce = Get-SelectedRegistryValue 'Software\Microsoft\Windows\CurrentVersion\RunOnce' '!A4SMenuCleanup'
        RecoveryRunOnce = Get-SelectedRegistryValue 'Software\Microsoft\Windows\CurrentVersion\RunOnce' '!A4SMenuServicingRecovery'
        InstallRoot = Get-PathInventory $installRoot
    }
}

function Get-ObjectSha256 {
    param([Parameter(Mandatory)] $Value)
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-HostExplorerPid {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session })
    if ($explorers.Count -ne 1) {
        throw "Expected exactly one Explorer in host session $session; found $($explorers.Count)."
    }
    return [int]$explorers[0].Id
}

function ConvertTo-GuestRelativePath {
    param([Parameter(Mandatory)][string] $HostPath)
    $full = [IO.Path]::GetFullPath($HostPath)
    if (-not (Test-PathWithin -Candidate $full -Parent $repoRoot)) {
        throw "The V2 setup must be inside the read-only repository mapping: $full"
    }
    return $full.Substring($repoRoot.TrimEnd('\').Length).TrimStart('\')
}

function New-SandboxConfigurationText {
    param(
        [Parameter(Mandatory)][string] $HostRepo,
        [Parameter(Mandatory)][string] $HostControl,
        [Parameter(Mandatory)][string] $HostEvidence,
        [Parameter(Mandatory)][string] $SessionId,
        [Parameter(Mandatory)][string] $Nonce,
        [Parameter(Mandatory)][string] $RequestSha256,
        [Parameter(Mandatory)][string] $BootstrapScriptSha256,
        [Parameter(Mandatory)][string] $GuestScriptSha256
    )
    $repo = [Security.SecurityElement]::Escape($HostRepo)
    $control = [Security.SecurityElement]::Escape($HostControl)
    $evidence = [Security.SecurityElement]::Escape($HostEvidence)
    $command = [Security.SecurityElement]::Escape(
        ('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\A4S\Repo\tools\Invoke-A4SLegacySandboxBootstrap.ps1"' +
        ' -GuestScriptPath "C:\A4S\Repo\tools\Invoke-A4SLegacySandboxGuest.ps1"' +
        ' -RequestPath "C:\A4S\Control\request.json" -EvidenceRoot "C:\A4S\Evidence"' +
        ' -SessionId "' + $SessionId + '"' +
        ' -Nonce "' + $Nonce + '"' +
        ' -RequestSha256 "' + $RequestSha256 + '"' +
        ' -BootstrapScriptSha256 "' + $BootstrapScriptSha256 + '"' +
        ' -GuestScriptSha256 "' + $GuestScriptSha256 + '"'))
    return @"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Disable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <ProtectedClient>Enable</ProtectedClient>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$repo</HostFolder>
      <SandboxFolder>C:\A4S\Repo</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$control</HostFolder>
      <SandboxFolder>C:\A4S\Control</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$evidence</HostFolder>
      <SandboxFolder>C:\A4S\Evidence</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$command</Command>
  </LogonCommand>
</Configuration>
"@
}

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text
    )
    $temporary = "$Path.new"
    if (Test-Path -LiteralPath $temporary) { throw "Temporary output collision: $temporary" }
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path)
}

function Publish-HostResultReplacement {
    param(
        [Parameter(Mandatory)][string] $StagedPath,
        [Parameter(Mandatory)][string] $DestinationPath,
        [scriptblock] $PostPublishValidation
    )

    $stagedFull = [IO.Path]::GetFullPath($StagedPath)
    $destinationFull = [IO.Path]::GetFullPath($DestinationPath)
    $stagedDirectory = [IO.Path]::GetDirectoryName($stagedFull)
    $destinationDirectory = [IO.Path]::GetDirectoryName($destinationFull)
    if (-not $stagedDirectory.Equals($destinationDirectory,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Host-result replacement requires a same-directory staged file.'
    }
    if (-not [IO.File]::Exists($stagedFull) -or
        -not [IO.File]::Exists($destinationFull)) {
        throw 'Host-result replacement requires existing staged and destination files.'
    }

    $stagedItem = Get-Item -LiteralPath $stagedFull -Force
    $expectedLength = [long]$stagedItem.Length
    $expectedSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedFull).Hash.ToUpperInvariant()
    $backupPath = Join-Path $destinationDirectory `
        (([IO.Path]::GetFileName($destinationFull)) + ".backup-$PID-$([Guid]::NewGuid().ToString('N'))")
    $rollbackDiscardPath = Join-Path $destinationDirectory `
        (([IO.Path]::GetFileName($destinationFull)) + ".rollback-discard-$PID-$([Guid]::NewGuid().ToString('N'))")
    $replaced = $false
    $committed = $false
    $rollbackCompleted = $false
    try {
        # .NET Framework's three-argument Replace overload rejects a null
        # backup path. Keep a real same-directory backup until the published
        # bytes have been checked, so every supported Windows PowerShell host
        # has an explicit rollback source.
        [IO.File]::Replace($stagedFull, $destinationFull, $backupPath, $true)
        $replaced = $true
        $publishedItem = Get-Item -LiteralPath $destinationFull -Force
        $publishedSha256 = (Get-FileHash -Algorithm SHA256 `
            -LiteralPath $destinationFull).Hash.ToUpperInvariant()
        if ([long]$publishedItem.Length -ne $expectedLength -or
            $publishedSha256 -cne $expectedSha256) {
            throw 'Published host-result bytes do not match the staged record.'
        }
        if ($PostPublishValidation) { & $PostPublishValidation }
        $committed = $true
    }
    catch {
        $publishFailure = $_
        if ($replaced) {
            try {
                if ([IO.File]::Exists($destinationFull)) {
                    [IO.File]::Replace($backupPath, $destinationFull,
                        $rollbackDiscardPath, $true)
                }
                else {
                    [IO.File]::Move($backupPath, $destinationFull)
                }
                $rollbackCompleted = $true
                if ([IO.File]::Exists($rollbackDiscardPath)) {
                    [IO.File]::Delete($rollbackDiscardPath)
                }
            }
            catch {
                throw "Host-result publication failed: $($publishFailure.Exception.Message) Rollback also failed: $($_.Exception.Message)"
            }
        }
        throw $publishFailure
    }
    finally {
        if ($committed -and [IO.File]::Exists($backupPath)) {
            [IO.File]::Delete($backupPath)
        }
        if ([IO.File]::Exists($stagedFull)) { [IO.File]::Delete($stagedFull) }
        if (($committed -or $rollbackCompleted) -and
            [IO.File]::Exists($rollbackDiscardPath)) {
            [IO.File]::Delete($rollbackDiscardPath)
        }
    }
}

function Read-Utf8JsonSnapshot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1, 16777216)][int] $MaximumBytes = 1048576
    )
    $full = Assert-RegularFile $Path
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 2 -or $stream.Length -gt $MaximumBytes) {
            throw "JSON evidence length is outside the accepted range: $full"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "Unexpected end of JSON evidence: $full" }
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "JSON evidence must be UTF-8 without a BOM: $full"
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $algorithm.Dispose() }
    return [ordered]@{
        Path = $full
        Length = $bytes.Length
        Sha256 = $sha256
        Value = ($text | ConvertFrom-Json -ErrorAction Stop)
    }
}

function Read-Utf8TextSnapshot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1, 1048576)][int] $MaximumBytes = 262144
    )
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Missing UTF-8 diagnostic file: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt $MaximumBytes) {
        throw "UTF-8 diagnostic file is unsafe or exceeds $MaximumBytes bytes: $full"
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "UTF-8 diagnostic files must not contain a BOM: $full"
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [ordered]@{
            Path = $full
            Length = [long]$bytes.Length
            Sha256 = ([BitConverter]::ToString(
                $algorithm.ComputeHash($bytes))).Replace('-', '')
            Text = $encoding.GetString($bytes)
        }
    }
    finally { $algorithm.Dispose() }
}

function Read-AuthenticatedBootstrapStage {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $SessionId,
        [Parameter(Mandatory)][string] $Nonce,
        [Parameter(Mandatory)][string] $RequestSha256,
        [Parameter(Mandatory)][string] $BootstrapScriptSha256,
        [Parameter(Mandatory)][string] $GuestScriptSha256
    )
    $snapshot = Read-Utf8JsonSnapshot -Path $Path -MaximumBytes 65536
    $record = $snapshot.Value
    $properties = @($record.PSObject.Properties.Name | Sort-Object)
    $expected = @('BootstrapScriptSha256', 'CapturedUtc', 'Details',
        'GuestScriptSha256', 'Nonce', 'Ordinal', 'ProcessId', 'RequestSha256',
        'SchemaVersion', 'SessionId', 'Stage') | Sort-Object
    if (($properties -join '|') -cne ($expected -join '|') -or
        [int]$record.SchemaVersion -ne 1 -or
        [string]$record.SessionId -cne $SessionId -or
        [string]$record.Nonce -cne $Nonce -or
        [string]$record.RequestSha256 -cne $RequestSha256 -or
        [string]$record.BootstrapScriptSha256 -cne $BootstrapScriptSha256 -or
        [string]$record.GuestScriptSha256 -cne $GuestScriptSha256 -or
        [int]$record.Ordinal -ne 2 -or
        [string]$record.Stage -cne 'scripts-authenticated' -or
        [int]$record.ProcessId -le 0 -or
        [string]$record.Details.ActualBootstrapScriptSha256 -cne
            $BootstrapScriptSha256 -or
        [string]$record.Details.ActualGuestScriptSha256 -cne $GuestScriptSha256) {
        throw 'The Sandbox bootstrap record does not authenticate this exact reviewed run.'
    }
    [DateTime]::Parse([string]$record.CapturedUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null
    return $record
}

function Read-AuthenticatedGuestExit {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ResultDirectory,
        [Parameter(Mandatory)][string] $SessionId,
        [Parameter(Mandatory)][string] $Nonce,
        [Parameter(Mandatory)][string] $RequestSha256,
        [Parameter(Mandatory)][string] $BootstrapScriptSha256,
        [Parameter(Mandatory)][string] $GuestScriptSha256
    )
    $snapshot = Read-Utf8JsonSnapshot -Path $Path -MaximumBytes 65536
    $record = $snapshot.Value
    $properties = @($record.PSObject.Properties.Name | Sort-Object)
    $expected = @('BootstrapScriptSha256', 'CompletedUtc', 'ConsoleFile',
        'ConsoleLength', 'ConsoleSha256', 'ExitCode', 'GuestScriptSha256',
        'LastStage', 'Nonce', 'RequestSha256', 'SchemaVersion', 'SessionId') |
        Sort-Object
    if (($properties -join '|') -cne ($expected -join '|') -or
        [int]$record.SchemaVersion -ne 1 -or
        [string]$record.SessionId -cne $SessionId -or
        [string]$record.Nonce -cne $Nonce -or
        [string]$record.RequestSha256 -cne $RequestSha256 -or
        [string]$record.BootstrapScriptSha256 -cne $BootstrapScriptSha256 -or
        [string]$record.GuestScriptSha256 -cne $GuestScriptSha256 -or
        [string]$record.ConsoleFile -cne 'guest-console.log' -or
        [string]$record.ConsoleSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'The Sandbox guest-exit record does not authenticate this exact reviewed run.'
    }
    [DateTime]::Parse([string]$record.CompletedUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind) | Out-Null
    $consolePath = Join-Path $ResultDirectory 'guest-console.log'
    $console = Read-Utf8TextSnapshot -Path $consolePath -MaximumBytes 262144
    if ([long]$record.ConsoleLength -ne $console.Length -or
        [string]$record.ConsoleSha256 -cne $console.Sha256) {
        throw 'The Sandbox guest console does not match its exit-record length and SHA-256.'
    }
    $diagnostic = [string]$console.Text
    if ($diagnostic.Length -gt 4096) {
        $diagnostic = '[earlier output omitted] ' +
            $diagnostic.Substring($diagnostic.Length - 4096)
    }
    $diagnostic = [regex]::Replace($diagnostic,
        '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '?')
    return [ordered]@{
        Record = $record
        Diagnostic = $diagnostic
        ExitRecordSha256 = $snapshot.Sha256
    }
}

function Assert-ContractModel {
    $xmlText = New-SandboxConfigurationText -HostRepo 'C:\Qualification\Repo' `
        -HostControl 'D:\Qualification Evidence\Session\control' `
        -HostEvidence 'D:\Qualification Evidence\Session\results' `
        -SessionId '11111111-2222-3333-4444-555555555555' `
        -Nonce ('A' * 64) -RequestSha256 ('B' * 64) `
        -BootstrapScriptSha256 ('C' * 64) -GuestScriptSha256 ('D' * 64)
    [xml]$xml = $xmlText
    if ($xml.Configuration.Networking -cne 'Disable' -or
        $xml.Configuration.ClipboardRedirection -cne 'Disable' -or
        $xml.Configuration.PrinterRedirection -cne 'Disable' -or
        $xml.Configuration.AudioInput -cne 'Disable' -or
        $xml.Configuration.VideoInput -cne 'Disable' -or
        $xml.Configuration.vGPU -cne 'Disable' -or
        $xml.Configuration.ProtectedClient -cne 'Enable') {
        throw 'The in-memory Sandbox isolation contract is incomplete.'
    }
    $mappings = @($xml.Configuration.MappedFolders.MappedFolder)
    $mappedHostFolders = @($mappings | ForEach-Object { [string]$_.HostFolder })
    if ($mappings.Count -ne 3 -or $mappings[0].ReadOnly -cne 'true' -or
        [string]$mappings[0].HostFolder -cne 'C:\Qualification\Repo' -or
        $mappings[0].SandboxFolder -cne 'C:\A4S\Repo' -or
        $mappings[1].ReadOnly -cne 'true' -or
        [string]$mappings[1].HostFolder -cne
            'D:\Qualification Evidence\Session\control' -or
        $mappings[1].SandboxFolder -cne 'C:\A4S\Control' -or
        $mappings[2].ReadOnly -cne 'false' -or
        [string]$mappings[2].HostFolder -cne
            'D:\Qualification Evidence\Session\results' -or
        $mappings[2].SandboxFolder -cne 'C:\A4S\Evidence' -or
        $mappedHostFolders -contains 'D:\Qualification Evidence\Session\host' -or
        $mappedHostFolders -contains 'D:\Qualification Evidence\Session') {
        throw 'The in-memory Sandbox mapping contract is incomplete.'
    }
    $contractHostResult =
        'D:\Qualification Evidence\Session\host\host-result.json'
    if (-not (Test-PathWithin -Candidate $contractHostResult `
            -Parent 'D:\Qualification Evidence\Session\host') -or
        (Test-PathWithin -Candidate $contractHostResult `
            -Parent 'D:\Qualification Evidence\Session\control') -or
        (Test-PathWithin -Candidate $contractHostResult `
            -Parent 'D:\Qualification Evidence\Session\results')) {
        throw 'The in-memory host-result path is not confined to the unmapped host directory.'
    }
    Write-Host 'A4S legacy Sandbox host PS5 unmapped host-result layout contract passed.'
    if ($xml.Configuration.LogonCommand.Command -notmatch
        'Invoke-A4SLegacySandboxBootstrap\.ps1.*Invoke-A4SLegacySandboxGuest\.ps1.*C:\\A4S\\Control\\request\.json') {
        throw 'The guest entry point is missing from the Sandbox configuration.'
    }
    $expectedContractCommand =
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\A4S\Repo\tools\Invoke-A4SLegacySandboxBootstrap.ps1"' +
        ' -GuestScriptPath "C:\A4S\Repo\tools\Invoke-A4SLegacySandboxGuest.ps1"' +
        ' -RequestPath "C:\A4S\Control\request.json" -EvidenceRoot "C:\A4S\Evidence"' +
        ' -SessionId "11111111-2222-3333-4444-555555555555"' +
        ' -Nonce "' + ('A' * 64) + '" -RequestSha256 "' + ('B' * 64) + '"' +
        ' -BootstrapScriptSha256 "' + ('C' * 64) + '"' +
        ' -GuestScriptSha256 "' + ('D' * 64) + '"'
    if ([string]$xml.Configuration.LogonCommand.Command -cne $expectedContractCommand) {
        throw 'The in-memory Sandbox bootstrap command contract is not exact.'
    }
    if (-not (Test-PathWithin -Candidate 'C:\Qualification\Repo' `
            -Parent 'C:\Qualification\Repo')) {
        throw 'Equal paths must be treated as overlapping mappings.'
    }
    $replacementRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('A4SHostResultReplacement-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($replacementRoot) | Out-Null
    try {
        $destination = Join-Path $replacementRoot 'host-result.json'
        $staged = Join-Path $replacementRoot 'host-result.json.started'
        [IO.File]::WriteAllText($destination, '{"state":"before"}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($staged, '{"state":"after"}',
            [Text.UTF8Encoding]::new($false))
        Publish-HostResultReplacement -StagedPath $staged `
            -DestinationPath $destination
        if ([IO.File]::ReadAllText($destination) -cne '{"state":"after"}' -or
            [IO.File]::Exists($staged) -or
            @(Get-ChildItem -LiteralPath $replacementRoot -Force | Where-Object {
                $_.Name -match '\.(?:backup-|rollback-discard-)'
            }).Count -ne 0) {
            throw 'The existing-file host-result replacement contract failed.'
        }
        [IO.File]::WriteAllText($staged, '{"state":"must-rollback"}',
            [Text.UTF8Encoding]::new($false))
        $rollbackObserved = $false
        try {
            Publish-HostResultReplacement -StagedPath $staged `
                -DestinationPath $destination -PostPublishValidation {
                    throw 'synthetic post-publication validation failure'
                }
        }
        catch {
            $rollbackObserved = $_.Exception.Message -match
                'synthetic post-publication validation failure'
        }
        if (-not $rollbackObserved -or
            [IO.File]::ReadAllText($destination) -cne '{"state":"after"}' -or
            [IO.File]::Exists($staged) -or
            @(Get-ChildItem -LiteralPath $replacementRoot -Force | Where-Object {
                $_.Name -match '\.(?:backup-|rollback-discard-)'
            }).Count -ne 0) {
            throw 'The failed host-result replacement did not restore and clean the prior record.'
        }
    }
    finally {
        if ([IO.Directory]::Exists($replacementRoot)) {
            [IO.Directory]::Delete($replacementRoot, $true)
        }
    }

    $diagnosticRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('A4SGuestExitContract-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($diagnosticRoot) | Out-Null
    try {
        $contractSession = '11111111-2222-3333-4444-555555555555'
        $contractNonce = 'A' * 64
        $contractRequest = 'B' * 64
        $contractBootstrap = 'C' * 64
        $contractGuest = 'D' * 64
        $stagePath = Join-Path $diagnosticRoot 'stage-002-scripts-authenticated.json'
        $stageRecord = [ordered]@{
            SchemaVersion = 1; SessionId = $contractSession
            Nonce = $contractNonce; RequestSha256 = $contractRequest
            BootstrapScriptSha256 = $contractBootstrap
            GuestScriptSha256 = $contractGuest; Ordinal = 2
            Stage = 'scripts-authenticated'; ProcessId = $PID
            CapturedUtc = [DateTime]::UtcNow.ToString('o')
            Details = [ordered]@{
                ActualBootstrapScriptSha256 = $contractBootstrap
                ActualGuestScriptSha256 = $contractGuest
            }
        }
        Write-Utf8NoBomAtomic -Path $stagePath `
            -Text ($stageRecord | ConvertTo-Json -Depth 20)
        Read-AuthenticatedBootstrapStage -Path $stagePath `
            -SessionId $contractSession -Nonce $contractNonce `
            -RequestSha256 $contractRequest `
            -BootstrapScriptSha256 $contractBootstrap `
            -GuestScriptSha256 $contractGuest | Out-Null

        $consolePath = Join-Path $diagnosticRoot 'guest-console.log'
        Write-Utf8NoBomAtomic -Path $consolePath -Text 'synthetic PS5 diagnostic'
        $consoleItem = Get-Item -LiteralPath $consolePath -Force
        $exitPath = Join-Path $diagnosticRoot 'guest-exit.json'
        $exitRecord = [ordered]@{
            SchemaVersion = 1; SessionId = $contractSession
            Nonce = $contractNonce; RequestSha256 = $contractRequest
            BootstrapScriptSha256 = $contractBootstrap
            GuestScriptSha256 = $contractGuest; ExitCode = 17
            LastStage = 'synthetic-contract'; ConsoleFile = 'guest-console.log'
            ConsoleLength = [long]$consoleItem.Length
            ConsoleSha256 = (Get-FileHash -Algorithm SHA256 `
                -LiteralPath $consolePath).Hash.ToUpperInvariant()
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-Utf8NoBomAtomic -Path $exitPath `
            -Text ($exitRecord | ConvertTo-Json -Depth 20)
        $validatedExit = Read-AuthenticatedGuestExit -Path $exitPath `
            -ResultDirectory $diagnosticRoot -SessionId $contractSession `
            -Nonce $contractNonce -RequestSha256 $contractRequest `
            -BootstrapScriptSha256 $contractBootstrap `
            -GuestScriptSha256 $contractGuest
        if ([int]$validatedExit.Record.ExitCode -ne 17 -or
            [string]$validatedExit.Diagnostic -cne 'synthetic PS5 diagnostic') {
            throw 'Authenticated guest-exit diagnostic contract failed.'
        }
    }
    finally {
        if ([IO.Directory]::Exists($diagnosticRoot)) {
            [IO.Directory]::Delete($diagnosticRoot, $true)
        }
    }
    Write-Host "A4S legacy Sandbox host in-memory replacement contract passed under Windows PowerShell $($PSVersionTable.PSVersion); authenticated diagnostic contract passed."
}

if ($ContractSelfTest) {
    Assert-ContractModel
    return
}

if (-not $AllowSandboxLaunch) {
    throw 'Windows Sandbox is not launched by default. Review the runner, then pass -AllowSandboxLaunch.'
}
if (-not [Environment]::Is64BitProcess) { throw 'Run this host orchestrator from 64-bit PowerShell.' }
foreach ($required in @($V2SetupPath, $ExpectedV2SetupSha256,
        $ExpectedV2HostSha256, $ExpectedV2MenuSha256)) {
    if ([string]::IsNullOrWhiteSpace($required)) {
        throw 'V2SetupPath and all three reviewed V2 SHA-256 values are required.'
    }
}

$repoRoot = Assert-LocalFixedPath $repoRoot
Assert-NoReparsePointInExistingChain $repoRoot
$bootstrapScript = Assert-RegularFile (Join-Path $repoRoot $bootstrapScriptRelativePath)
$guestScript = Assert-RegularFile (Join-Path $repoRoot $guestScriptRelativePath)
$v1Setup = Assert-RegularFile (Join-Path $repoRoot $v1SetupRelativePath)
$v2Setup = Assert-RegularFile $V2SetupPath
$v2RelativePath = ConvertTo-GuestRelativePath $v2Setup
$evidenceRootFull = Assert-LocalFixedPath $EvidenceRoot
Assert-NoReparsePointInExistingChain $evidenceRootFull
if ((Test-PathWithin -Candidate $evidenceRootFull -Parent $repoRoot) -or
    (Test-PathWithin -Candidate $repoRoot -Parent $evidenceRootFull)) {
    throw 'The writable evidence root must be disjoint from the read-only repository mapping.'
}
$hostInstallRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu'))
if ((Test-PathWithin -Candidate $evidenceRootFull -Parent $hostInstallRoot) -or
    (Test-PathWithin -Candidate $hostInstallRoot -Parent $evidenceRootFull) -or
    $evidenceRootFull.Equals($hostInstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The writable evidence root must be disjoint from the real A4S install root.'
}

$v1Identity = Get-FileIdentity $v1Setup
$v2Identity = Get-FileIdentity $v2Setup
if ($v1Identity.Sha256 -cne $frozenV1.SetupSha256 -or
    $v1Identity.ProductVersion -cne $frozenV1.Version -or
    $v1Identity.OriginalFilename -cne 'A4SMenuSetup.exe') {
    throw 'The frozen V1 setup identity is not the reviewed 1.0.0.0 fixture.'
}
$expectedV2Setup = Normalize-Sha256 $ExpectedV2SetupSha256
if ($v2Identity.Sha256 -cne $expectedV2Setup -or
    $v2Identity.ProductVersion -cne $ExpectedV2Version -or
    $v2Identity.OriginalFilename -cne 'A4SMenuSetup.exe') {
    throw 'The V2 setup identity does not match the reviewed 1.1.0.0 input.'
}

$canonicalSandboxPath = Assert-RegularFile (Join-Path ([Environment]::SystemDirectory) `
    'WindowsSandbox.exe')
if ((Get-PeMachine $canonicalSandboxPath) -ne 0x8664) {
    throw "The canonical Windows Sandbox launcher is not x64: $canonicalSandboxPath"
}
$sandboxCommand = Get-Command WindowsSandbox.exe -CommandType Application -ErrorAction Stop
$resolvedSandboxPath = [IO.Path]::GetFullPath($sandboxCommand.Source)
if (-not $resolvedSandboxPath.Equals($canonicalSandboxPath,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "WindowsSandbox.exe resolved outside the canonical System32 path: $resolvedSandboxPath"
}
$sandboxIdentity = [ordered]@{
    Path = $canonicalSandboxPath
    Length = [long](Get-Item -LiteralPath $canonicalSandboxPath -Force).Length
    Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $canonicalSandboxPath).Hash.ToUpperInvariant()
    ProductVersion = Get-FixedProductVersion $canonicalSandboxPath
}
$existingSandboxes = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '^WindowsSandbox' })
if ($existingSandboxes.Count -ne 0) {
    throw 'Close every existing Windows Sandbox before starting an isolated lifecycle qualification.'
}
$activeA4SProcesses = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '^A4SMenu(?:Host|Setup|Cleanup)' })
if ($activeA4SProcesses.Count -ne 0) {
    throw 'Stop every A4S host/setup/cleanup process before the host-state isolation preflight.'
}
$featureState = 'NotQueried'
if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
    $feature = $null
    try {
        $feature = Get-WindowsOptionalFeature -Online `
            -FeatureName Containers-DisposableClientVM -ErrorAction Stop
        $featureState = [string]$feature.State
    }
    catch { $featureState = 'QueryUnavailableExecutablePresent' }
    if ($null -ne $feature -and $featureState -cne 'Enabled') {
        throw "Windows Sandbox optional feature state is $featureState, not Enabled."
    }
}

$hostExplorerPid = Get-HostExplorerPid
$hostBefore = Get-HostProductSnapshot
$hostBeforeSha256 = Get-ObjectSha256 $hostBefore
Start-Sleep -Milliseconds 500
$hostPreflightConfirmation = Get-HostProductSnapshot
if ((Get-ObjectSha256 $hostPreflightConfirmation) -cne $hostBeforeSha256 -or
    (Get-HostExplorerPid) -ne $hostExplorerPid) {
    throw 'The real A4S profile or Explorer changed during the clean host preflight.'
}
$sessionId = [Guid]::NewGuid().ToString('D')
$nonceBytes = [byte[]]::new(32)
$nonceGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $nonceGenerator.GetBytes($nonceBytes) }
finally { $nonceGenerator.Dispose() }
$nonce = ([BitConverter]::ToString($nonceBytes)).Replace('-', '')
$bootstrapScriptSha256 = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $bootstrapScript).Hash.ToUpperInvariant()
$guestScriptSha256 = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $guestScript).Hash.ToUpperInvariant()
$sessionDirectory = Join-Path $evidenceRootFull $sessionId
if (Test-Path -LiteralPath $sessionDirectory) { throw "Evidence session collision: $sessionDirectory" }
[IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
Assert-NoReparsePointInExistingChain $sessionDirectory
$hostDirectory = Join-Path $sessionDirectory 'host'
$controlDirectory = Join-Path $sessionDirectory 'control'
$resultDirectory = Join-Path $sessionDirectory 'results'
[IO.Directory]::CreateDirectory($hostDirectory) | Out-Null
[IO.Directory]::CreateDirectory($controlDirectory) | Out-Null
[IO.Directory]::CreateDirectory($resultDirectory) | Out-Null
Assert-NoReparsePointInExistingChain $hostDirectory
Assert-NoReparsePointInExistingChain $controlDirectory
Assert-NoReparsePointInExistingChain $resultDirectory
if ((Test-PathWithin -Candidate $hostDirectory -Parent $controlDirectory) -or
    (Test-PathWithin -Candidate $controlDirectory -Parent $hostDirectory) -or
    (Test-PathWithin -Candidate $hostDirectory -Parent $resultDirectory) -or
    (Test-PathWithin -Candidate $resultDirectory -Parent $hostDirectory)) {
    throw 'The mutable host-result directory must be disjoint from every Sandbox mapping.'
}

$request = [ordered]@{
    SchemaVersion = 1
    Purpose = 'A4S frozen-V1 to reviewed-V2 Windows Sandbox lifecycle qualification'
    SessionId = $sessionId
    Nonce = $nonce
    GuestRepoRoot = 'C:\A4S\Repo'
    GuestControlRoot = 'C:\A4S\Control'
    GuestEvidenceRoot = 'C:\A4S\Evidence'
    V1SetupRelativePath = $v1SetupRelativePath
    V2SetupRelativePath = $v2RelativePath
    V1 = $frozenV1
    V2 = [ordered]@{
        Version = $ExpectedV2Version
        SetupSha256 = $expectedV2Setup
        HostSha256 = Normalize-Sha256 $ExpectedV2HostSha256
        MenuSha256 = Normalize-Sha256 $ExpectedV2MenuSha256
    }
    RequiredMatrix = @(
        'install-v1', 'update-v1-to-v2', 'rollback-v2-to-v1',
        'update-v1-to-v2-again', 'repair-v2-same-version', 'uninstall-v2'
    )
    ExplorerRestartAuthorized = $false
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
    HostPreflight = [ordered]@{
        ExplorerPid = $hostExplorerPid
        ProductStateSha256 = $hostBeforeSha256
        WindowsSandboxExecutable = $sandboxIdentity
        OptionalFeatureState = $featureState
        RepositoryPath = $repoRoot
        BootstrapScriptSha256 = $bootstrapScriptSha256
        GuestScriptSha256 = $guestScriptSha256
        V1Setup = $v1Identity
        V2Setup = $v2Identity
    }
}
$requestPath = Join-Path $controlDirectory 'request.json'
Write-Utf8NoBomAtomic -Path $requestPath `
    -Text ($request | ConvertTo-Json -Depth 100)
$requestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $requestPath).Hash.ToUpperInvariant()
$configurationText = New-SandboxConfigurationText -HostRepo $repoRoot `
    -HostControl $controlDirectory -HostEvidence $resultDirectory `
    -SessionId $sessionId -Nonce $nonce -RequestSha256 $requestSha256 `
    -BootstrapScriptSha256 $bootstrapScriptSha256 `
    -GuestScriptSha256 $guestScriptSha256
$configurationPath = Join-Path $controlDirectory 'A4SLegacyLifecycle.wsb'
Write-Utf8NoBomAtomic -Path $configurationPath -Text $configurationText
$configurationSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $configurationPath).Hash.ToUpperInvariant()

$launchRecord = [ordered]@{
    SchemaVersion = 1
    SessionId = $sessionId
    Nonce = $nonce
    RequestSha256 = $requestSha256
    ConfigurationSha256 = $configurationSha256
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    SandboxProcessId = $null
    Bootstrap = $null
    GuestExit = $null
    Completion = $null
    CompletionSha256 = $null
    HostBefore = $hostBefore
    HostAfter = $null
    HostStateUnchanged = $false
    ExplorerPidUnchanged = $false
    Succeeded = $false
    Failure = $null
}
$hostResultPath = Join-Path $hostDirectory 'host-result.json'
Write-Utf8NoBomAtomic -Path $hostResultPath `
    -Text ($launchRecord | ConvertTo-Json -Depth 100)

$completionPath = Join-Path $resultDirectory 'completion.json'
$bootstrapPath = Join-Path $resultDirectory 'stage-002-scripts-authenticated.json'
$guestExitPath = Join-Path $resultDirectory 'guest-exit.json'
$bootstrapPublicationFailurePath = Join-Path $resultDirectory `
    'bootstrap-publication-failure.txt'
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$bootstrapDeadline = [DateTime]::UtcNow.AddSeconds($BootstrapTimeoutSeconds)
$processExitObservedUtc = $null
$completionObservedUtc = $null
$guestExitObservedUtc = $null
$completion = $null
$completionSnapshot = $null
$guestExit = $null
$guestEvidencePath = Join-Path $resultDirectory 'evidence.json'
$hostFailure = $null
try {
    $sandboxProcess = Start-Process -FilePath $sandboxCommand.Source `
        -ArgumentList ('"' + $configurationPath + '"') -PassThru
    $launchRecord.SandboxProcessId = $sandboxProcess.Id
    $startedHostResult = "$hostResultPath.started"
    Write-Utf8NoBomAtomic -Path $startedHostResult `
        -Text ($launchRecord | ConvertTo-Json -Depth 100)
    Publish-HostResultReplacement -StagedPath $startedHostResult `
        -DestinationPath $hostResultPath

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -eq $completion -and
            (Test-Path -LiteralPath $completionPath -PathType Leaf)) {
            try {
                $completionSnapshot = Read-Utf8JsonSnapshot -Path $completionPath `
                    -MaximumBytes 65536
                $completion = $completionSnapshot.Value
                $completionObservedUtc = [DateTime]::UtcNow
            }
            catch {
                # The guest publishes by rename, but tolerate visibility latency
                # in the mapped folder rather than consuming a partial file.
            }
        }
        if ($null -eq $launchRecord.Bootstrap -and
            (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
            $launchRecord.Bootstrap = Read-AuthenticatedBootstrapStage `
                -Path $bootstrapPath -SessionId $sessionId -Nonce $nonce `
                -RequestSha256 $requestSha256 `
                -BootstrapScriptSha256 $bootstrapScriptSha256 `
                -GuestScriptSha256 $guestScriptSha256
        }
        if ($null -eq $guestExit -and
            (Test-Path -LiteralPath $guestExitPath -PathType Leaf)) {
            $guestExit = Read-AuthenticatedGuestExit -Path $guestExitPath `
                -ResultDirectory $resultDirectory -SessionId $sessionId `
                -Nonce $nonce -RequestSha256 $requestSha256 `
                -BootstrapScriptSha256 $bootstrapScriptSha256 `
                -GuestScriptSha256 $guestScriptSha256
            $launchRecord.GuestExit = $guestExit.Record
            if ([int]$guestExit.Record.ExitCode -ne 0) {
                throw "Windows Sandbox guest PowerShell exited with code $([int]$guestExit.Record.ExitCode) after '$([string]$guestExit.Record.LastStage)'. Diagnostic (bounded): `"$([string]$guestExit.Diagnostic)`""
            }
            $guestExitObservedUtc = [DateTime]::UtcNow
        }
        if (Test-Path -LiteralPath $bootstrapPublicationFailurePath -PathType Leaf) {
            $publicationFailure = Read-Utf8TextSnapshot `
                -Path $bootstrapPublicationFailurePath -MaximumBytes 262144
            $diagnostic = [string]$publicationFailure.Text
            if ($diagnostic.Length -gt 4096) {
                $diagnostic = '[earlier publication failure detail omitted] ' +
                    $diagnostic.Substring($diagnostic.Length - 4096)
            }
            $diagnostic = [regex]::Replace($diagnostic,
                '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '?')
            throw "Windows Sandbox bootstrap could not publish its authenticated exit record. Diagnostic (bounded): `"$diagnostic`""
        }
        if ($null -ne $guestExit -and $null -eq $completion -and
            ([DateTime]::UtcNow - $guestExitObservedUtc).TotalSeconds -ge
                $GuestExitTimeoutSeconds) {
            throw "Windows Sandbox guest PowerShell exited successfully after '$([string]$guestExit.Record.LastStage)' but did not publish completion.json within $GuestExitTimeoutSeconds seconds. Diagnostic (bounded): `"$([string]$guestExit.Diagnostic)`""
        }
        if ($null -ne $completion -and $null -eq $guestExit -and
            ([DateTime]::UtcNow - $completionObservedUtc).TotalSeconds -ge
                $GuestExitTimeoutSeconds) {
            throw "Windows Sandbox published completion.json but its bootstrap did not publish an authenticated guest-exit record within $GuestExitTimeoutSeconds seconds."
        }
        if ($null -eq $launchRecord.Bootstrap -and
            [DateTime]::UtcNow -ge $bootstrapDeadline) {
            throw "Windows Sandbox did not publish an authenticated bootstrap record within $BootstrapTimeoutSeconds seconds. The guest LogonCommand or writable evidence mapping failed."
        }
        if ($null -ne $completion -and $null -ne $launchRecord.Bootstrap -and
            $null -ne $guestExit -and [int]$guestExit.Record.ExitCode -eq 0) {
            break
        }
        # Windows versions differ on whether the initial launcher remains the
        # long-lived UI process. Since preflight rejected an existing Sandbox,
        # any WindowsSandbox* process now belongs to this one launch.
        $sandboxFamily = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match '^WindowsSandbox' })
        if ($sandboxFamily.Count -ne 0) {
            $processExitObservedUtc = $null
        }
        elseif ($null -eq $processExitObservedUtc) {
            $processExitObservedUtc = [DateTime]::UtcNow
        }
        if ($null -ne $processExitObservedUtc -and
            ([DateTime]::UtcNow - $processExitObservedUtc).TotalSeconds -ge 15) {
            throw 'Windows Sandbox exited without publishing a completion record.'
        }
        Start-Sleep -Milliseconds 500
    }
    if ($null -eq $completion) {
        throw "Timed out after $TimeoutMinutes minutes waiting for the guest completion record after authenticated bootstrap. The runner did not terminate Windows Sandbox."
    }
    if ($null -eq $launchRecord.Bootstrap -or $null -eq $guestExit -or
        [int]$guestExit.Record.ExitCode -ne 0) {
        throw 'The Sandbox result boundary closed without authenticated bootstrap and successful guest-exit records.'
    }
    $completionProperties = @($completion.PSObject.Properties.Name | Sort-Object)
    $expectedCompletionProperties = @('CompletedUtc', 'EvidenceFile',
        'EvidenceSha256', 'Nonce', 'RequestSha256', 'SchemaVersion',
        'SessionId', 'Status') | Sort-Object
    if (($completionProperties -join '|') -cne ($expectedCompletionProperties -join '|')) {
        throw 'The guest completion record schema has unexpected or missing properties.'
    }
    if ([int]$completion.SchemaVersion -ne 1 -or
        [string]$completion.SessionId -cne $sessionId -or
        [string]$completion.Nonce -cne $nonce -or
        [string]$completion.RequestSha256 -cne $requestSha256 -or
        [string]$completion.Status -notin @('Passed', 'Failed') -or
        [string]$completion.EvidenceFile -cne 'evidence.json' -or
        [string]$completion.EvidenceSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'The guest completion record does not authenticate this exact Sandbox request.'
    }
    if (-not (Test-Path -LiteralPath $guestEvidencePath -PathType Leaf)) {
        throw 'The guest completion record names missing evidence.json.'
    }
    $guestEvidenceSnapshot = Read-Utf8JsonSnapshot -Path $guestEvidencePath `
        -MaximumBytes 16777216
    $actualGuestEvidenceSha256 = $guestEvidenceSnapshot.Sha256
    if ($actualGuestEvidenceSha256 -cne [string]$completion.EvidenceSha256) {
        throw 'Guest evidence.json does not match the completion-record SHA-256.'
    }
    $guestEvidence = $guestEvidenceSnapshot.Value
    $guestEvidenceProperties = @($guestEvidence.PSObject.Properties.Name | Sort-Object)
    $requiredGuestEvidenceProperties = @('CompletedUtc', 'Environment', 'Failure',
        'FinalDisposition', 'Inputs', 'LastUpdatedUtc', 'Nonce', 'RequestSha256',
        'SchemaVersion', 'Seed', 'SessionId', 'StartedUtc', 'Steps', 'Succeeded',
        'Test') | Sort-Object
    $allowedGuestEvidenceProperties = @($requiredGuestEvidenceProperties +
        'FailureCheckpoint') | Sort-Object
    $unexpectedEvidenceProperties = @($guestEvidenceProperties |
        Where-Object { $_ -notin $allowedGuestEvidenceProperties })
    $missingEvidenceProperties = @($requiredGuestEvidenceProperties |
        Where-Object { $_ -notin $guestEvidenceProperties })
    if ($unexpectedEvidenceProperties.Count -ne 0 -or
        $missingEvidenceProperties.Count -ne 0) {
        throw 'Guest evidence.json schema has unexpected or missing top-level properties.'
    }
    if ([int]$guestEvidence.SchemaVersion -ne 1 -or
        [string]$guestEvidence.SessionId -cne $sessionId -or
        [string]$guestEvidence.Nonce -cne $nonce -or
        [string]$guestEvidence.RequestSha256 -cne $requestSha256) {
        throw 'Guest evidence content does not correlate to the exact requested Sandbox run.'
    }
    if ([string]$completion.Status -ceq 'Failed') {
        if ([bool]$guestEvidence.Succeeded -or $null -eq $guestEvidence.Failure -or
            [string]::IsNullOrWhiteSpace([string]$guestEvidence.Failure.Message)) {
            throw 'The guest published an inconsistent failure record.'
        }
        throw "The Sandbox guest reported failure: $([string]$guestEvidence.Failure.Message)"
    }
    if (-not [bool]$guestEvidence.Succeeded -or
        $null -ne $guestEvidence.Failure -or
        @($guestEvidenceProperties | Where-Object { $_ -ceq 'FailureCheckpoint' }).Count -ne 0 -or
        -not [bool]$guestEvidence.Environment.Is64BitProcess -or
        [string]$guestEvidence.Environment.WindowsIdentity.Name -notmatch
            '(?i)\\WDAGUtilityAccount$' -or
        [string]$guestEvidence.Environment.WindowsIdentity.Sid -notmatch
            '^S-1-5-21-(?:[0-9]+-){3}504$' -or
        [bool]$guestEvidence.Environment.Network.NetworkAvailable -or
        @($guestEvidence.Environment.Network.OperationalNonLoopbackInterfaces).Count -ne 0 -or
        -not [bool]$guestEvidence.Environment.Configuration.RepositoryReadOnly -or
        -not [bool]$guestEvidence.Environment.Configuration.ControlReadOnly -or
        -not [bool]$guestEvidence.Environment.Configuration.EvidenceWritable -or
        [string]$guestEvidence.Environment.Configuration.Sha256 -cne $configurationSha256 -or
        (@($guestEvidence.Steps | ForEach-Object { [string]$_.Name }) -join '|') -cne
            (@($request.RequiredMatrix) -join '|') -or
        [string]$guestEvidence.FinalDisposition.State -cne
            'LogicallyUninstalledPhysicalCleanupPendingExplorerExit') {
        throw 'Guest evidence content does not prove the exact requested matrix and configuration.'
    }
}
catch {
    $hostFailure = $_
    $launchRecord.Failure = [ordered]@{
        Message = $_.Exception.Message
        Category = [string]$_.CategoryInfo.Category
        ScriptStackTrace = $_.ScriptStackTrace
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

try {
    $hostAfter = Get-HostProductSnapshot
    $hostAfterSha256 = Get-ObjectSha256 $hostAfter
    $hostExplorerAfter = Get-HostExplorerPid
    $launchRecord.HostAfter = $hostAfter
    $launchRecord.HostStateUnchanged = $hostAfterSha256 -ceq $hostBeforeSha256
    $launchRecord.ExplorerPidUnchanged = $hostExplorerAfter -eq $hostExplorerPid
}
catch {
    if ($null -eq $hostFailure) { $hostFailure = $_ }
    if ($null -eq $launchRecord.Failure) {
        $launchRecord.Failure = [ordered]@{
            Message = $_.Exception.Message
            Category = [string]$_.CategoryInfo.Category
            ScriptStackTrace = $_.ScriptStackTrace
            CapturedUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
}
$launchRecord.Completion = $completion
$launchRecord.CompletionSha256 = if ($null -eq $completionSnapshot) {
    $null
} else { [string]$completionSnapshot.Sha256 }
$launchRecord.CompletedUtc = [DateTime]::UtcNow.ToString('o')
$launchRecord.Succeeded = $null -eq $hostFailure -and
    $launchRecord.HostStateUnchanged -and $launchRecord.ExplorerPidUnchanged -and
    $null -ne $launchRecord.Bootstrap -and
    $null -ne $launchRecord.GuestExit -and
    [int]$launchRecord.GuestExit.ExitCode -eq 0 -and
    $null -ne $completion -and [string]$completion.Status -ceq 'Passed'
$updatedHostResult = "$hostResultPath.updated"
Write-Utf8NoBomAtomic -Path $updatedHostResult `
    -Text ($launchRecord | ConvertTo-Json -Depth 100)
Publish-HostResultReplacement -StagedPath $updatedHostResult `
    -DestinationPath $hostResultPath

if ($null -ne $hostFailure) {
    throw "Sandbox qualification host validation failed: $($hostFailure.Exception.Message) Evidence: $hostResultPath"
}
if (-not $launchRecord.HostStateUnchanged) {
    throw "Host A4S product state changed during Sandbox qualification. Evidence: $hostResultPath"
}
if (-not $launchRecord.ExplorerPidUnchanged) {
    throw "Host Explorer PID changed during Sandbox qualification. Evidence: $hostResultPath"
}
if ([string]$completion.Status -cne 'Passed') {
    throw "The Sandbox lifecycle matrix failed. Evidence: $guestEvidencePath"
}

Write-Host "A4S legacy Sandbox lifecycle passed. Evidence: $guestEvidencePath"
Write-Host 'Windows Sandbox is left open for inspection; close it manually when finished.'
