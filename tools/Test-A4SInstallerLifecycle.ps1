<#
.SYNOPSIS
Runs the destructive, live per-user installer lifecycle matrix and writes JSON evidence.

.DESCRIPTION
This tool requires a clean installer-owned starting state, exercises the frozen
1.0 and current 1.1 one-file installers, and intentionally leaves 1.1 installed
but quiescent. It never passes --restart-explorer. Every pre-existing user-owned
value below HKCU\Software\A4SMenu is restored byte-for-byte after the final V2
registration commits, including Config, Menu, InstallPath, and Enabled. The
original DataCache.db bytes (or absence) are also restored.

.EXAMPLE
.\tools\Test-A4SInstallerLifecycle.ps1 -V1SetupPath C:\fixtures\A4SMenuSetup-1.0.exe `
    -V2SetupPath C:\fixtures\A4SMenuSetup-1.1.exe `
    -ExpectedV1SetupSha256 DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2 `
    -ExpectedV2SetupSha256 <reviewed-sha256> -AllowInstallMutation

.NOTES
Prerequisites: 64-bit PowerShell, an interactive current-session Explorer,
local fixed, non-mapped, non-reparse fixture/evidence paths, exact reviewed x64
1.0.0.0 and 1.1.0.0 setup files, no installer-owned registration or versions
tree, and no active A4S host/setup/cleanup process, journal, RunOnce, or helper.
If Explorer retains a disarmed old DLL, final 1.1 activation requires a later
manual Explorer restart plus host launch, or the next sign-in. This script
records that stopped/native-fallback state and never performs the restart.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $V1SetupPath,

    [Parameter(Mandatory)]
    [string] $V2SetupPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ExpectedV1SetupSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ExpectedV2SetupSha256,

    [switch] $AllowInstallMutation,

    [string] $EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\evidence\installer-lifecycle'),

    [ValidateRange(30, 600)]
    [int] $OperationTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $AllowInstallMutation) {
    throw 'This is a LIVE per-user installer test. Re-run with -AllowInstallMutation only after reviewing the script and closing unrelated setup processes.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run the live installer lifecycle test from 64-bit PowerShell.'
}

$stateSubKey = 'Software\A4SMenu'
$servicingSubKey = 'Software\A4SMenu\Servicing'
$uninstallSubKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu'
$runSubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$runOnceSubKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runValueName = 'A4SMenu'
$cleanupRunOnceName = '!A4SMenuCleanup'
$recoveryRunOnceName = '!A4SMenuServicingRecovery'
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu'))
$versionsRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'versions'))
$dataCachePath = [IO.Path]::GetFullPath((Join-Path $installRoot 'DataCache.db'))
$cleanupHelperPath = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'A4SMenuCleanup.exe'))
$expectedCleanupRunOnce = '"' + $cleanupHelperPath + '" --cleanup --silent'
$expectedV1 = [Version]'1.0.0.0'
$expectedV2 = [Version]'1.1.0.0'
$frozenV1SetupSha256 = 'DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2'
$frozenV1HostSha256 = '9995676D0B74DE2E68E0C4EACB7E4111BE1AF13AA34C3505499C3925708A0573'
$frozenV1MenuSha256 = '4C1C9A325FF41A6DD089690874C95DCC8CC8CC5A4561F9B8ECCFA29832C03610'
$installerOwnedRootValues = @('ActiveSlot', 'PreviousSlot', 'InstallVersion')
$preloadDebounceMilliseconds = 2000
$finalQuiescenceVerificationMilliseconds = 3000
$script:captureCounter = 0
$script:outstandingProcess = $null
$script:evidence = $null
$script:evidencePath = $null
$script:sessionDirectory = $null
$script:manifestPath = $null
$script:manifestSha256 = $null
$script:expectedCleanupHash = $null
$script:fixturePaths = @()

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.Trim().ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{64}$') { throw "Invalid SHA-256 value: $Value" }
    return $normalized
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent
    )

    $childFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase) -or
        $childFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-LocalAbsolutePath {
    param([Parameter(Mandatory)][string] $Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') {
        throw "Only an absolute path on a local drive is accepted: $full"
    }
    if ($full.Substring(2).Contains(':')) {
        throw "Alternate-data-stream paths are not accepted: $full"
    }
    $driveName = $full.Substring(0, 1)
    $drive = [IO.DriveInfo]::new("${driveName}:\")
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "Only a ready fixed local volume is accepted; remote and removable paths are rejected: $full"
    }
    $psDrive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
    if ($psDrive.DisplayRoot) {
        throw "Mapped filesystem drives are not accepted: $full (maps to $($psDrive.DisplayRoot))"
    }
    return $full
}

function Assert-NoReparsePointInExistingChain {
    param([Parameter(Mandatory)][string] $Path)

    $cursor = Assert-LocalAbsolutePath $Path
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) {
            throw "No existing ancestor could be validated for $Path."
        }
        $cursor = $parent.FullName
    }
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use a path whose existing chain contains a reparse point: $($item.FullName)"
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
}

function Assert-RegularFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description
    )

    $full = Assert-LocalAbsolutePath $Path
    Assert-NoReparsePointInExistingChain $full
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Description is not a regular file: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point: $full"
    }
    return $full
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "$Path is not a PE image." }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "$Path has an invalid PE signature." }
        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-FixedProductVersion {
    param([Parameter(Mandatory)][string] $Path)

    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($info.ProductMajorPart -lt 0 -or $info.ProductMinorPart -lt 0 -or
        $info.ProductBuildPart -lt 0 -or $info.ProductPrivatePart -lt 0) {
        throw "The product version is incomplete: $Path"
    }
    return [Version]::new($info.ProductMajorPart, $info.ProductMinorPart,
        $info.ProductBuildPart, $info.ProductPrivatePart)
}

function Get-BinaryIdentity {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description
    )

    $full = Assert-RegularFile -Path $Path -Description $Description
    if ((Get-PeMachine -Path $full) -ne 0x8664) {
        throw "$Description is not an x64 PE image: $full"
    }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($full)
    return [ordered]@{
        Path = $full
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToUpperInvariant()
        Length = (Get-Item -LiteralPath $full).Length
        ProductVersion = (Get-FixedProductVersion -Path $full).ToString(4)
        OriginalFilename = $info.OriginalFilename
    }
}

function Assert-SafeInstallBoundary {
    Assert-NoReparsePointInExistingChain $installRoot
    if (Test-Path -LiteralPath $installRoot) {
        if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
            throw "The expected install root is not a directory: $installRoot"
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $installRoot -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to service an install root containing a direct reparse point: $($child.FullName)"
            }
        }
    }
    if (Test-Path -LiteralPath $versionsRoot) {
        if (-not (Test-Path -LiteralPath $versionsRoot -PathType Container)) {
            throw "The versions path is not a directory: $versionsRoot"
        }
        foreach ($slot in @(Get-ChildItem -LiteralPath $versionsRoot -Force)) {
            if (($slot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to service a versions directory containing a reparse point: $($slot.FullName)"
            }
        }
    }
    if (Test-Path -LiteralPath $dataCachePath) {
        Assert-RegularFile -Path $dataCachePath -Description 'A4S DataCache.db' | Out-Null
    }
}

function ConvertTo-EncodedRegistryValue {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Name
    )

    $kind = $Key.GetValueKind($Name)
    $value = $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $data = switch ($kind) {
        ([Microsoft.Win32.RegistryValueKind]::String) { [string]$value; break }
        ([Microsoft.Win32.RegistryValueKind]::ExpandString) { [string]$value; break }
        ([Microsoft.Win32.RegistryValueKind]::MultiString) { @([string[]]$value); break }
        ([Microsoft.Win32.RegistryValueKind]::Binary) {
            $bytes = if ($null -eq $value) { [byte[]]@() } else { [byte[]]$value }
            [Convert]::ToBase64String($bytes); break
        }
        ([Microsoft.Win32.RegistryValueKind]::None) {
            $bytes = if ($null -eq $value) { [byte[]]@() } else { [byte[]]$value }
            [Convert]::ToBase64String($bytes); break
        }
        ([Microsoft.Win32.RegistryValueKind]::DWord) { [string]([int]$value); break }
        ([Microsoft.Win32.RegistryValueKind]::QWord) { [string]([long]$value); break }
        default { throw "Unsupported registry value kind '$kind' at $($Key.Name)\$Name." }
    }
    return [ordered]@{
        Name = $Name
        Kind = $kind.ToString()
        Data = $data
    }
}

function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Name
    )

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    if ($null -eq $key) {
        return [ordered]@{ Present = $false; Name = $Name; Kind = $null; Data = $null }
    }
    try {
        $actualName = @($key.GetValueNames() | Where-Object { $_ -ieq $Name }) |
            Select-Object -First 1
        if ($null -eq $actualName) {
            return [ordered]@{ Present = $false; Name = $Name; Kind = $null; Data = $null }
        }
        $encoded = ConvertTo-EncodedRegistryValue -Key $key -Name $actualName
        return [ordered]@{
            Present = $true
            Name = $actualName
            Kind = $encoded.Kind
            Data = $encoded.Data
        }
    }
    finally {
        $key.Dispose()
    }
}

function Add-RegistryTreeNodes {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key,
        [Parameter(Mandatory)][AllowEmptyString()][string] $RelativePath,
        [Parameter(Mandatory)][Collections.Generic.List[object]] $Nodes
    )

    $values = [Collections.Generic.List[object]]::new()
    foreach ($name in @($Key.GetValueNames() | Sort-Object)) {
        $values.Add((ConvertTo-EncodedRegistryValue -Key $Key -Name $name))
    }
    $Nodes.Add([ordered]@{ RelativePath = $RelativePath; Values = @($values) })
    foreach ($childName in @($Key.GetSubKeyNames() | Sort-Object)) {
        $child = $Key.OpenSubKey($childName, $false)
        if ($null -eq $child) { throw "A registry subtree disappeared while it was being captured: $($Key.Name)\$childName" }
        try {
            $childRelative = if ($RelativePath) { "$RelativePath\$childName" } else { $childName }
            Add-RegistryTreeNodes -Key $child -RelativePath $childRelative -Nodes $Nodes
        }
        finally {
            $child.Dispose()
        }
    }
}

function Get-RegistryTreeSnapshot {
    param([Parameter(Mandatory)][string] $SubKey)

    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    if ($null -eq $root) {
        return [ordered]@{ SubKey = $SubKey; Exists = $false; Nodes = @() }
    }
    try {
        $nodes = [Collections.Generic.List[object]]::new()
        Add-RegistryTreeNodes -Key $root -RelativePath '' -Nodes $nodes
        return [ordered]@{ SubKey = $SubKey; Exists = $true; Nodes = @($nodes) }
    }
    finally {
        $root.Dispose()
    }
}

function Get-InstallerRegistrationSnapshot {
    return [ordered]@{
        ActiveSlot = Get-RegistryValueSnapshot -SubKey $stateSubKey -Name 'ActiveSlot'
        PreviousSlot = Get-RegistryValueSnapshot -SubKey $stateSubKey -Name 'PreviousSlot'
        InstallVersion = Get-RegistryValueSnapshot -SubKey $stateSubKey -Name 'InstallVersion'
        Servicing = Get-RegistryTreeSnapshot -SubKey $servicingSubKey
        Uninstall = Get-RegistryTreeSnapshot -SubKey $uninstallSubKey
        Run = Get-RegistryValueSnapshot -SubKey $runSubKey -Name $runValueName
        CleanupRunOnce = Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $cleanupRunOnceName
        RecoveryRunOnce = Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $recoveryRunOnceName
    }
}

function Get-UserStateProjection {
    $tree = Get-RegistryTreeSnapshot -SubKey $stateSubKey
    if (-not $tree.Exists) {
        return [ordered]@{ SubKey = $stateSubKey; Exists = $false; Nodes = @() }
    }

    $nodes = [Collections.Generic.List[object]]::new()
    foreach ($node in @($tree.Nodes)) {
        $relative = [string]$node.RelativePath
        if ($relative -ieq 'Servicing' -or $relative.StartsWith('Servicing\',
                [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $values = @($node.Values)
        if (-not $relative) {
            $values = @($values | Where-Object {
                $name = [string]$_.Name
                -not ($installerOwnedRootValues | Where-Object { $_ -ieq $name })
            })
        }
        if ($relative -or $values.Count -ne 0) {
            $nodes.Add([ordered]@{ RelativePath = $relative; Values = @($values) })
        }
    }
    if ($nodes.Count -eq 0) {
        return [ordered]@{ SubKey = $stateSubKey; Exists = $false; Nodes = @() }
    }
    if (-not (@($nodes | Where-Object { -not $_.RelativePath }).Count)) {
        $nodes.Insert(0, [ordered]@{ RelativePath = ''; Values = @() })
    }
    return [ordered]@{ SubKey = $stateSubKey; Exists = $true; Nodes = @($nodes) }
}

function Get-ObjectFingerprint {
    param([Parameter(Mandatory)] $Value)

    $json = $Value | ConvertTo-Json -Depth 32 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-StableUserStateProjection {
    for ($attempt = 1; $attempt -le 3; ++$attempt) {
        $first = Get-UserStateProjection
        Start-Sleep -Milliseconds 100
        $second = Get-UserStateProjection
        if ((Get-ObjectFingerprint $first) -ceq (Get-ObjectFingerprint $second)) {
            return $second
        }
    }
    throw 'The user-owned A4S registry state changed repeatedly during preflight; no installation mutation was started.'
}

function ConvertFrom-EncodedRegistryData {
    param([Parameter(Mandatory)] $Value)

    $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
        [Microsoft.Win32.RegistryValueKind], [string]$Value.Kind, $false)
    switch ($kind) {
        ([Microsoft.Win32.RegistryValueKind]::String) { return [string]$Value.Data }
        ([Microsoft.Win32.RegistryValueKind]::ExpandString) { return [string]$Value.Data }
        ([Microsoft.Win32.RegistryValueKind]::MultiString) { return [string[]]@($Value.Data) }
        ([Microsoft.Win32.RegistryValueKind]::Binary) { return [Convert]::FromBase64String([string]$Value.Data) }
        ([Microsoft.Win32.RegistryValueKind]::None) { return [Convert]::FromBase64String([string]$Value.Data) }
        ([Microsoft.Win32.RegistryValueKind]::DWord) { return [int]::Parse([string]$Value.Data, [Globalization.CultureInfo]::InvariantCulture) }
        ([Microsoft.Win32.RegistryValueKind]::QWord) { return [long]::Parse([string]$Value.Data, [Globalization.CultureInfo]::InvariantCulture) }
        default { throw "Unsupported registry value kind in recovery snapshot: $($Value.Kind)" }
    }
}

function Restore-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)] $Snapshot
    )

    if (-not $Snapshot.Present) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $true)
        if ($null -ne $key) {
            try { $key.DeleteValue([string]$Snapshot.Name, $false); $key.Flush() }
            finally { $key.Dispose() }
        }
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey, $true)
    if ($null -eq $key) { throw "Could not create HKCU\$SubKey during recovery." }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
            [Microsoft.Win32.RegistryValueKind], [string]$Snapshot.Kind, $false)
        # Remove case-insensitively before recreating so the original value-name
        # casing is restored as well as its native kind and bytes.
        $key.DeleteValue([string]$Snapshot.Name, $false)
        $key.SetValue([string]$Snapshot.Name, (ConvertFrom-EncodedRegistryData $Snapshot), $kind)
        $key.Flush()
    }
    finally {
        $key.Dispose()
    }
}

function Restore-RegistryTreeSnapshot {
    param(
        [Parameter(Mandatory)][string] $ExpectedSubKey,
        [Parameter(Mandatory)] $Snapshot
    )

    if ([string]$Snapshot.SubKey -cne $ExpectedSubKey) {
        throw "Recovery snapshot path mismatch: expected HKCU\$ExpectedSubKey."
    }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($ExpectedSubKey, $false)
    if (-not $Snapshot.Exists) { return }
    foreach ($node in @($Snapshot.Nodes)) {
        $relative = [string]$node.RelativePath
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..') {
            throw "Unsafe relative registry path in recovery snapshot: $relative"
        }
        $subKey = if ($relative) { "$ExpectedSubKey\$relative" } else { $ExpectedSubKey }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey, $true)
        if ($null -eq $key) { throw "Could not restore HKCU\$subKey." }
        try {
            foreach ($value in @($node.Values)) {
                $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                    [Microsoft.Win32.RegistryValueKind], [string]$value.Kind, $false)
                $key.SetValue([string]$value.Name, (ConvertFrom-EncodedRegistryData $value), $kind)
            }
            $key.Flush()
        }
        finally {
            $key.Dispose()
        }
    }
}

function Restore-UserStateProjection {
    param(
        [Parameter(Mandatory)] $OriginalProjection,
        [Parameter(Mandatory)] $FinalInstallerRegistration
    )

    foreach ($name in $installerOwnedRootValues) {
        $snapshot = $FinalInstallerRegistration[$name]
        if ($null -eq $snapshot -or -not $snapshot.Present) {
            throw "Cannot merge user state without the final installer-owned $name value."
        }
    }

    # Rebuild only the product state key. The final installer-owned root values
    # are captured first and then merged with the exact original user projection;
    # Run and uninstall registration are deliberately left untouched.
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($stateSubKey, $false)
    if ($OriginalProjection.Exists) {
        Restore-RegistryTreeSnapshot -ExpectedSubKey $stateSubKey -Snapshot $OriginalProjection
    }
    foreach ($name in $installerOwnedRootValues) {
        Restore-RegistryValueSnapshot -SubKey $stateSubKey -Snapshot $FinalInstallerRegistration[$name]
    }

    $actualProjection = Get-UserStateProjection
    $expectedFingerprint = Get-ObjectFingerprint $OriginalProjection
    $actualFingerprint = Get-ObjectFingerprint $actualProjection
    if ($actualFingerprint -cne $expectedFingerprint) {
        throw 'The merged user-owned A4S registry projection is not byte-exact.'
    }
    $actualInstaller = Get-InstallerRegistrationSnapshot
    $expectedInstallerFingerprint = Get-ObjectFingerprint $FinalInstallerRegistration
    $actualInstallerFingerprint = Get-ObjectFingerprint $actualInstaller
    if ($actualInstallerFingerprint -cne $expectedInstallerFingerprint) {
        throw 'Merging user state changed final installer-owned registration.'
    }
    return [ordered]@{
        ExpectedSha256 = $expectedFingerprint
        ActualSha256 = $actualFingerprint
        InstallerRegistrationSha256 = $actualInstallerFingerprint
        Projection = $actualProjection
    }
}

function Restore-CleanUserStateProjection {
    param([Parameter(Mandatory)] $OriginalProjection)
    Restore-RegistryTreeSnapshot -ExpectedSubKey $stateSubKey -Snapshot $OriginalProjection
    $actual = Get-UserStateProjection
    $expectedFingerprint = Get-ObjectFingerprint $OriginalProjection
    $actualFingerprint = Get-ObjectFingerprint $actual
    if ($actualFingerprint -cne $expectedFingerprint) {
        throw 'Clean-state recovery did not restore the exact user-owned registry projection.'
    }
    return [ordered]@{
        ExpectedSha256 = $expectedFingerprint
        ActualSha256 = $actualFingerprint
        Projection = $actual
    }
}

function Get-DataCacheRecord {
    Assert-SafeInstallBoundary
    if (-not (Test-Path -LiteralPath $dataCachePath)) {
        return [ordered]@{ Present = $false; Path = $dataCachePath }
    }
    $item = Get-Item -LiteralPath $dataCachePath -Force
    return [ordered]@{
        Present = $true
        Path = $dataCachePath
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $dataCachePath).Hash.ToUpperInvariant()
        Length = $item.Length
        CreationTimeUtc = $item.CreationTimeUtc.ToString('o')
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        Attributes = [int]$item.Attributes
    }
}

function Backup-OriginalDataCache {
    param([Parameter(Mandatory)][string] $BackupPath)

    $record = Get-DataCacheRecord
    $record.BackupPath = $null
    if (-not $record.Present) { return $record }
    if (Test-Path -LiteralPath $BackupPath) { throw "Refusing to overwrite a cache backup: $BackupPath" }
    $source = [IO.File]::Open($dataCachePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $destination = [IO.File]::Open($BackupPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $source.CopyTo($destination); $destination.Flush($true) }
        finally { $destination.Dispose() }
    }
    finally {
        $source.Dispose()
    }
    Assert-RegularFile -Path $BackupPath -Description 'DataCache.db recovery backup' | Out-Null
    $backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $BackupPath).Hash.ToUpperInvariant()
    if ($backupHash -cne $record.Sha256) {
        throw 'The DataCache.db recovery backup does not match the original bytes.'
    }
    $record.BackupPath = $BackupPath
    return $record
}

function Restore-OriginalDataCache {
    param([Parameter(Mandatory)] $Original)

    Assert-SafeInstallBoundary
    if (-not $Original.Present) {
        if (Test-Path -LiteralPath $dataCachePath) {
            Assert-RegularFile -Path $dataCachePath -Description 'test-created DataCache.db' | Out-Null
            [IO.File]::Delete($dataCachePath)
        }
        return Get-DataCacheRecord
    }
    $backup = Assert-RegularFile -Path ([string]$Original.BackupPath) -Description 'DataCache.db recovery backup'
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToUpperInvariant() -cne $Original.Sha256) {
        throw 'The DataCache.db recovery backup changed; refusing restoration.'
    }
    Assert-NoReparsePointInExistingChain $installRoot
    if (-not (Test-Path -LiteralPath $installRoot)) {
        [IO.Directory]::CreateDirectory($installRoot) | Out-Null
    }
    Assert-SafeInstallBoundary
    $temporary = Join-Path $installRoot ('.DataCache.restore.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    if (Test-Path -LiteralPath $temporary) { throw "Unexpected restoration path collision: $temporary" }
    try {
        [IO.File]::Copy($backup, $temporary, $false)
        Assert-RegularFile -Path $temporary -Description 'temporary DataCache.db restoration file' | Out-Null
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $temporary).Hash.ToUpperInvariant() -cne $Original.Sha256) {
            throw 'The temporary DataCache.db restoration copy failed verification.'
        }
        if (Test-Path -LiteralPath $dataCachePath) {
            Assert-RegularFile -Path $dataCachePath -Description 'existing DataCache.db restoration target' | Out-Null
            [IO.File]::Replace($temporary, $dataCachePath, $null, $true)
        }
        else {
            [IO.File]::Move($temporary, $dataCachePath)
        }
        [IO.File]::SetCreationTimeUtc($dataCachePath, [DateTime]::Parse([string]$Original.CreationTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))
        [IO.File]::SetLastWriteTimeUtc($dataCachePath, [DateTime]::Parse([string]$Original.LastWriteTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))
        [IO.File]::SetAttributes($dataCachePath, [IO.FileAttributes][int]$Original.Attributes)
        $committed = [IO.File]::Open($dataCachePath, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try { $committed.Flush($true) }
        finally { $committed.Dispose() }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Assert-RegularFile -Path $temporary -Description 'temporary DataCache.db restoration file' | Out-Null
            [IO.File]::Delete($temporary)
        }
    }
    $restored = Get-DataCacheRecord
    if (-not $restored.Present -or $restored.Sha256 -cne $Original.Sha256 -or
        $restored.Length -ne $Original.Length) {
        throw 'The restored DataCache.db does not match the original.'
    }
    return $restored
}

if (-not ('A4SInstallerLifecycleNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class A4SInstallerLifecycleNative
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindowW(string className, string windowName);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resourceData);
    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);

    public static uint GetShellExplorerProcessId()
    {
        IntPtr taskbar = FindWindowW("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Shell_TrayWnd was not found");
        uint processId;
        if (GetWindowThreadProcessId(taskbar, out processId) == 0 || processId == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The taskbar Explorer PID could not be resolved");
        return processId;
    }

    public static byte[] ReadRcData(string path, int identifier)
    {
        const uint AsImageResource = 0x20;
        const uint AsDatafileExclusive = 0x40;
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, AsImageResource | AsDatafileExclusive);
        if (module == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryExW failed");
        try
        {
            IntPtr resource = FindResourceW(module, new IntPtr(identifier), new IntPtr(10));
            if (resource == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "FindResourceW failed");
            uint size = SizeofResource(module, resource);
            IntPtr loaded = LoadResource(module, resource);
            IntPtr data = loaded == IntPtr.Zero ? IntPtr.Zero : LockResource(loaded);
            if (size == 0 || data == IntPtr.Zero)
                throw new InvalidOperationException("Embedded payload resource is empty.");
            byte[] bytes = new byte[size];
            Marshal.Copy(data, bytes, 0, checked((int)size));
            return bytes;
        }
        finally { FreeLibrary(module); }
    }
}
'@
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-PeMachineFromBytes {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    if ($Bytes.Length -lt 64 -or [BitConverter]::ToUInt16($Bytes, 0) -ne 0x5A4D) {
        throw 'An embedded setup payload is not a PE image.'
    }
    $offset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($offset -lt 0 -or $offset + 6 -gt $Bytes.Length -or
        [BitConverter]::ToUInt32($Bytes, $offset) -ne 0x00004550) {
        throw 'An embedded setup payload has an invalid PE header.'
    }
    return [BitConverter]::ToUInt16($Bytes, $offset + 4)
}

function Get-SetupPayloadIdentity {
    param(
        [Parameter(Mandatory)] $SetupIdentity,
        [AllowNull()][string] $ExpectedHostSha256,
        [AllowNull()][string] $ExpectedMenuSha256
    )

    $hostBytes = [A4SInstallerLifecycleNative]::ReadRcData($SetupIdentity.Path, 201)
    $menuBytes = [A4SInstallerLifecycleNative]::ReadRcData($SetupIdentity.Path, 202)
    if ((Get-PeMachineFromBytes $hostBytes) -ne 0x8664 -or
        (Get-PeMachineFromBytes $menuBytes) -ne 0x8664) {
        throw "Embedded host or menu payload is not x64: $($SetupIdentity.Path)"
    }
    $hostHash = Get-BytesSha256 $hostBytes
    $menuHash = Get-BytesSha256 $menuBytes
    if ($ExpectedHostSha256 -and $hostHash -cne (Normalize-Sha256 $ExpectedHostSha256)) {
        throw "The frozen V1 setup embeds an unexpected host payload: $hostHash"
    }
    if ($ExpectedMenuSha256 -and $menuHash -cne (Normalize-Sha256 $ExpectedMenuSha256)) {
        throw "The frozen V1 setup embeds an unexpected menu payload: $menuHash"
    }
    return [ordered]@{
        Setup = $SetupIdentity
        Host = [ordered]@{ ResourceId = 201; Sha256 = $hostHash; Length = $hostBytes.Length }
        Menu = [ordered]@{ ResourceId = 202; Sha256 = $menuHash; Length = $menuBytes.Length }
    }
}

function Get-ShellExplorerPid {
    $processId = [int][A4SInstallerLifecycleNative]::GetShellExplorerProcessId()
    $process = Get-Process -Id $processId -ErrorAction Stop
    if ($process.ProcessName -ine 'explorer' -or $process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId) {
        throw "Shell_TrayWnd is not owned by the current-session Explorer process: PID $processId"
    }
    return $processId
}

function Get-A4SProcessRecords {
    $records = [Collections.Generic.List[object]]::new()
    $byId = [ordered]@{}
    foreach ($process in @(Get-Process -Name 'A4SMenuHost*', 'A4SMenuSetup*', 'A4SMenuCleanup*' `
            -ErrorAction SilentlyContinue)) {
        $byId[[string]$process.Id] = $process
    }
    if ($script:fixturePaths.Count -ne 0) {
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            try { $candidatePath = [IO.Path]::GetFullPath($process.Path) }
            catch { continue }
            if (@($script:fixturePaths | Where-Object {
                    $candidatePath.Equals($_, [StringComparison]::OrdinalIgnoreCase)
                }).Count -ne 0) {
                $byId[[string]$process.Id] = $process
            }
        }
    }
    $processes = @($byId.Values | Sort-Object Id)
    foreach ($process in $processes) {
        $path = $null
        try { $path = $process.Path } catch {}
        $records.Add([ordered]@{
            Name = $process.ProcessName
            Id = $process.Id
            SessionId = $process.SessionId
            Path = $path
        })
    }
    return @($records)
}

function Get-CleanupProcessRecords {
    param([Parameter(Mandatory)][string] $ExpectedSha256)

    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'A4SMenuCleanup' -ErrorAction SilentlyContinue | Sort-Object Id)) {
        try { $path = [IO.Path]::GetFullPath($process.Path) }
        catch { throw "Could not resolve cleanup helper process $($process.Id): $($_.Exception.Message)" }
        if (-not $path.Equals($cleanupHelperPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Cleanup helper process $($process.Id) uses an unexpected path: $path"
        }
        if ($process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId) {
            throw "Cleanup helper process $($process.Id) is not in the current interactive session."
        }
        $identity = Get-BinaryIdentity -Path $path -Description 'active cleanup helper'
        if ($identity.Sha256 -cne $ExpectedSha256) {
            throw "Cleanup helper process $($process.Id) does not match the exact expected setup hash."
        }
        $started = $null
        try { $started = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
        $records.Add([ordered]@{
            Id = $process.Id
            SessionId = $process.SessionId
            Path = $path
            Sha256 = $identity.Sha256
            StartTimeUtc = $started
        })
    }
    return @($records)
}

function Get-StableCleanupObservation {
    param(
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastFingerprint = $null
    $stableSamples = 0
    do {
        $records = @(Get-CleanupProcessRecords -ExpectedSha256 $ExpectedSha256)
        if ($records.Count -gt 1) {
            throw 'More than one exact cleanup helper is active.'
        }
        $helperFile = $null
        if (Test-Path -LiteralPath $cleanupHelperPath) {
            $helperFile = Get-BinaryIdentity -Path $cleanupHelperPath -Description 'cleanup helper file'
            if ($helperFile.Sha256 -cne $ExpectedSha256) {
                throw 'The cleanup helper file does not match the exact expected setup hash.'
            }
        }
        $sample = [ordered]@{ Processes = @($records); HelperFile = $helperFile }
        $fingerprint = Get-ObjectFingerprint $sample
        if ($fingerprint -ceq $lastFingerprint) { ++$stableSamples }
        else { $lastFingerprint = $fingerprint; $stableSamples = 1 }
        if ($stableSamples -ge 3) {
            return [ordered]@{
                Stable = $true
                Quiescent = $records.Count -eq 0
                Processes = @($records)
                HelperFile = $helperFile
                Samples = $stableSamples
                ObservedUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The cleanup-helper process set did not become stable inside the bounded observation window.'
}

function Write-DurableNewText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Write-ImmutableManifest {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value
    )
    $json = $Value | ConvertTo-Json -Depth 50
    Write-DurableNewText -Path $Path -Text $json
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
    $sidecar = $Path + '.sha256'
    Write-DurableNewText -Path $sidecar -Text ($hash + ' *' + [IO.Path]::GetFileName($Path) + "`r`n")
    return [ordered]@{ Path = $Path; Sha256 = $hash; SidecarPath = $sidecar }
}

function Write-Evidence {
    if ($null -eq $script:evidence -or -not $script:evidencePath) { return }
    $script:evidence.LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $json = $script:evidence | ConvertTo-Json -Depth 40
    $temporary = Join-Path $script:sessionDirectory ('.evidence.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Write-DurableNewText -Path $temporary -Text $json
    if (Test-Path -LiteralPath $script:evidencePath -PathType Leaf) {
        [IO.File]::Replace($temporary, $script:evidencePath, $null, $true)
    }
    else {
        [IO.File]::Move($temporary, $script:evidencePath)
    }
    $stream = [IO.File]::Open($script:evidencePath, [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Read-CapturedText {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
    catch { return "<capture unavailable: $($_.Exception.Message)>" }
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $full = Assert-RegularFile -Path $FilePath -Description "$Label executable"
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToUpperInvariant()
    if ($actualHash -cne $ExpectedSha256) {
        throw "$Label executable changed after preflight: $full"
    }
    if ($Arguments -icontains '--restart-explorer') {
        throw 'The lifecycle harness never authorizes an Explorer restart.'
    }
    $beforeExplorer = Get-ShellExplorerPid
    $index = ++$script:captureCounter
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $stdoutPath = Join-Path $script:sessionDirectory ('{0:D2}-{1}.stdout.txt' -f $index, $safeLabel)
    $stderrPath = Join-Path $script:sessionDirectory ('{0:D2}-{1}.stderr.txt' -f $index, $safeLabel)
    $startedUtc = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $startError = $null
    try {
        $process = Start-Process -FilePath $full -ArgumentList $Arguments -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    }
    catch {
        $startError = $_.Exception.Message
    }
    $timedOut = $false
    $exitCode = $null
    if ($null -ne $process) {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $script:outstandingProcess = $process
        }
        else {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $process.Dispose()
        }
    }
    $watch.Stop()
    $afterExplorer = Get-ShellExplorerPid
    return [ordered]@{
        Label = $Label
        Executable = $full
        ExecutableSha256 = $actualHash
        Arguments = @($Arguments)
        StartedUtc = $startedUtc.ToString('o')
        DurationMilliseconds = $watch.ElapsedMilliseconds
        StartError = $startError
        TimedOut = $timedOut
        ExitCode = $exitCode
        StandardOutput = Read-CapturedText $stdoutPath
        StandardError = Read-CapturedText $stderrPath
        StandardOutputPath = $stdoutPath
        StandardErrorPath = $stderrPath
        ExplorerPidBefore = $beforeExplorer
        ExplorerPidAfter = $afterExplorer
        ExplorerPidUnchanged = $beforeExplorer -eq $afterExplorer
    }
}

function Assert-ProcessSucceededWithoutExplorerRestart {
    param([Parameter(Mandatory)] $Record)
    if ($Record.StartError) { throw "$($Record.Label) could not start: $($Record.StartError)" }
    if ($Record.TimedOut) { throw "$($Record.Label) did not exit inside the bounded timeout; it was not force-killed." }
    if ($Record.ExitCode -ne 0) { throw "$($Record.Label) failed with exit code $($Record.ExitCode)." }
    if (-not $Record.ExplorerPidUnchanged) {
        throw "$($Record.Label) changed Explorer from PID $($Record.ExplorerPidBefore) to $($Record.ExplorerPidAfter)."
    }
}

function Get-StringRegistryValue {
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)][string] $Name
    )
    $snapshot = Get-RegistryValueSnapshot -SubKey $SubKey -Name $Name
    if (-not $snapshot.Present) { return '' }
    if ($snapshot.Kind -cne 'String' -and $snapshot.Kind -cne 'ExpandString') {
        throw "HKCU\$SubKey\$Name is not a string value."
    }
    return [string]$snapshot.Data
}

function Get-SlotRecord {
    param(
        [AllowEmptyString()][string] $SlotPath,
        [Parameter(Mandatory)][string] $Role
    )

    if (-not $SlotPath) { return $null }
    $full = Assert-LocalAbsolutePath $SlotPath
    $parent = [IO.Directory]::GetParent($full)
    if ($null -eq $parent -or -not $parent.FullName.TrimEnd('\').Equals(
            $versionsRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role slot is not a direct child of the validated versions root: $full"
    }
    Assert-NoReparsePointInExistingChain $full
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$Role slot does not exist: $full"
    }
    $files = [ordered]@{}
    foreach ($spec in @(
        @{ Key = 'Host'; Name = 'A4SMenuHost.exe' },
        @{ Key = 'Menu'; Name = 'A4SMenu.dll' },
        @{ Key = 'Setup'; Name = 'A4SMenuSetup.exe' })) {
        $path = Join-Path $full $spec.Name
        $identity = Get-BinaryIdentity -Path $path -Description "$Role slot $($spec.Name)"
        $files[$spec.Key] = $identity
    }
    return [ordered]@{
        Path = $full
        Name = [IO.Path]::GetFileName($full)
        Files = $files
        Entries = @((Get-ChildItem -LiteralPath $full -Force | Sort-Object Name | ForEach-Object {
            [ordered]@{
                Name = $_.Name
                IsDirectory = $_.PSIsContainer
                IsReparsePoint = ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }
        }))
    }
}

function Get-HostProcessRecords {
    param([AllowNull()] $ActiveSlot)

    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'A4SMenuHost' -ErrorAction SilentlyContinue | Sort-Object Id)) {
        if ($null -eq $ActiveSlot) { throw 'An A4SMenuHost process exists without an active slot.' }
        try { $path = [IO.Path]::GetFullPath($process.Path) }
        catch { throw "Could not resolve A4SMenuHost process $($process.Id): $($_.Exception.Message)" }
        if (-not $path.Equals([string]$ActiveSlot.Files.Host.Path,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "A4SMenuHost process $($process.Id) is not the exact active host: $path"
        }
        if ($process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId) {
            throw "A4SMenuHost process $($process.Id) is not in the current interactive session."
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
        if ($hash -cne [string]$ActiveSlot.Files.Host.Sha256) {
            throw "A4SMenuHost process $($process.Id) does not match the active host hash."
        }
        $records.Add([ordered]@{
            Id = $process.Id
            SessionId = $process.SessionId
            Path = $path
            Sha256 = $hash
        })
    }
    if ($records.Count -gt 1) { throw 'More than one resident A4SMenuHost process is active.' }
    return @($records)
}

function Get-HostStatusRecord {
    param(
        [AllowNull()] $ActiveSlot,
        [Parameter(Mandatory)][string] $Label
    )

    if ($null -eq $ActiveSlot) {
        return [ordered]@{ Available = $false; State = 'no-active-slot' }
    }
    $host = $ActiveSlot.Files.Host
    $probe = Invoke-CapturedProcess -Label ($Label + '-host-status') -FilePath $host.Path `
        -Arguments @('--status') -ExpectedSha256 $host.Sha256 -TimeoutSeconds 10
    if ($probe.StartError) { throw "$Label host-status probe could not start: $($probe.StartError)" }
    if ($probe.TimedOut) { throw "$Label host-status probe timed out and was not force-killed." }
    if (-not $probe.ExplorerPidUnchanged) { throw "$Label host-status probe changed Explorer." }
    $validExitCodes = @(0, 1, 2, 4, 5, 6, 1062)
    if ($validExitCodes -notcontains [int]$probe.ExitCode) {
        throw "$Label host-status probe returned unsupported exit code $($probe.ExitCode)."
    }
    $state = switch ($probe.ExitCode) {
        0 { 'ready'; break }
        1 { 'starting'; break }
        2 { 'injecting'; break }
        4 { 'failed-native-start-available'; break }
        5 { 'stopping'; break }
        6 { 'safety-disabled-native-start-available'; break }
        1062 { 'stopped'; break }
        default { if ($probe.TimedOut) { 'timeout' } else { 'other' } }
    }
    return [ordered]@{
        Available = $true
        State = $state
        Probe = $probe
    }
}

function Get-ProductCheckpoint {
    param([Parameter(Mandatory)][string] $Label)

    Assert-SafeInstallBoundary
    $activePath = Get-StringRegistryValue -SubKey $stateSubKey -Name 'ActiveSlot'
    $previousPath = Get-StringRegistryValue -SubKey $stateSubKey -Name 'PreviousSlot'
    $active = Get-SlotRecord -SlotPath $activePath -Role 'active'
    $previous = Get-SlotRecord -SlotPath $previousPath -Role 'previous'
    $installerRegistration = Get-InstallerRegistrationSnapshot
    $checkpoint = [ordered]@{
        Label = $Label
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        ExplorerPid = Get-ShellExplorerPid
        ActiveSlotPath = $activePath
        PreviousSlotPath = $previousPath
        InstallVersion = Get-StringRegistryValue -SubKey $stateSubKey -Name 'InstallVersion'
        ActiveSlot = $active
        PreviousSlot = $previous
        InstallerRegistration = $installerRegistration
        RunStartup = $installerRegistration.Run
        CleanupRunOnce = $installerRegistration.CleanupRunOnce
        RecoveryRunOnce = $installerRegistration.RecoveryRunOnce
        Servicing = $installerRegistration.Servicing
        UninstallEntry = $installerRegistration.Uninstall
        DataCache = Get-DataCacheRecord
        UserStateProjection = Get-UserStateProjection
    }
    $checkpoint.HostStatus = Get-HostStatusRecord -ActiveSlot $active -Label $Label
    $checkpoint.HostProcesses = @(Get-HostProcessRecords -ActiveSlot $active)
    $checkpoint.CleanupObservation = if ($script:expectedCleanupHash) {
        Get-StableCleanupObservation -ExpectedSha256 $script:expectedCleanupHash
    } else {
        [ordered]@{ Stable = $true; Quiescent = $true; Processes = @(); Samples = 0 }
    }
    return $checkpoint
}

function Get-TreeValue {
    param(
        [Parameter(Mandatory)] $Tree,
        [Parameter(Mandatory)][AllowEmptyString()][string] $RelativePath,
        [Parameter(Mandatory)][string] $Name
    )
    if (-not $Tree.Exists) { return $null }
    $node = @($Tree.Nodes | Where-Object { $_.RelativePath -ceq $RelativePath }) | Select-Object -First 1
    if ($null -eq $node) { return $null }
    return @($node.Values | Where-Object { $_.Name -ceq $Name }) | Select-Object -First 1
}

function Assert-NoTransientServicingState {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [switch] $AllowExactPendingCleanup
    )
    if ($Checkpoint.Servicing.Exists) {
        throw "$($Checkpoint.Label) retained HKCU\$servicingSubKey."
    }
    if ($Checkpoint.RecoveryRunOnce.Present) {
        throw "$($Checkpoint.Label) retained the servicing-recovery RunOnce value."
    }
    if (-not $AllowExactPendingCleanup) {
        if ($Checkpoint.CleanupRunOnce.Present) {
            throw "$($Checkpoint.Label) retained the cleanup RunOnce value outside explicit uninstall."
        }
        return
    }

    if ($Checkpoint.CleanupRunOnce.Present) {
        if ($Checkpoint.CleanupRunOnce.Kind -cne 'String' -or
            $Checkpoint.CleanupRunOnce.Data -cne $expectedCleanupRunOnce) {
            throw "$($Checkpoint.Label) has a non-canonical pending cleanup command."
        }
        if ($null -eq $Checkpoint.CleanupObservation.HelperFile -or
            @($Checkpoint.CleanupObservation.Processes).Count -ne 1) {
            throw "$($Checkpoint.Label) pending cleanup is not backed by one exact, current-session helper."
        }
    }
    elseif (-not $Checkpoint.CleanupObservation.Quiescent -or
        $null -ne $Checkpoint.CleanupObservation.HelperFile) {
        throw "$($Checkpoint.Label) has cleanup artifacts without the exact pending RunOnce state."
    }
}

function Assert-ExactSlotPayload {
    param(
        [Parameter(Mandatory)] $Slot,
        [Parameter(Mandatory)] $ExpectedPayload,
        [Parameter(Mandatory)][string] $Description
    )
    $expectedFiles = [ordered]@{
        Host = $ExpectedPayload.Host
        Menu = $ExpectedPayload.Menu
        Setup = $ExpectedPayload.Setup
    }
    foreach ($key in @('Host', 'Menu', 'Setup')) {
        $actual = $Slot.Files[$key]
        $expected = $expectedFiles[$key]
        if ($actual.Sha256 -cne $expected.Sha256 -or $actual.Length -ne $expected.Length) {
            throw "$Description $key does not match the exact reviewed embedded payload identity."
        }
    }
    $entries = @($Slot.Entries)
    $expectedNames = @('A4SMenu.dll', 'A4SMenuHost.exe', 'A4SMenuSetup.exe')
    $actualNames = @($entries | ForEach-Object Name | Sort-Object)
    if ($entries.Count -ne 3 -or (Compare-Object $expectedNames $actualNames)) {
        throw "$Description contains files outside the exact three-file product slot."
    }
    if (@($entries | Where-Object { $_.IsDirectory -or $_.IsReparsePoint }).Count -ne 0) {
        throw "$Description contains a directory or reparse point."
    }
}

function Assert-InstalledCheckpoint {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][Version] $ExpectedVersion,
        [Parameter(Mandatory)] $ExpectedPayload,
        [Parameter(Mandatory)][string] $ExpectedActiveSlot,
        [AllowNull()][string] $ExpectedPreviousSlot,
        [AllowNull()] $ExpectedPreviousPayload
    )

    if ($null -eq $Checkpoint.ActiveSlot) { throw "$($Checkpoint.Label) has no active slot." }
    $versionText = $ExpectedVersion.ToString(4)
    foreach ($file in @($Checkpoint.ActiveSlot.Files.Host, $Checkpoint.ActiveSlot.Files.Menu,
            $Checkpoint.ActiveSlot.Files.Setup)) {
        if ($file.ProductVersion -cne $versionText) {
            throw "$($Checkpoint.Label) active payload version '$($file.ProductVersion)' is not '$versionText'."
        }
    }
    $actualActive = [IO.Path]::GetFullPath($Checkpoint.ActiveSlotPath).TrimEnd('\')
    $expectedActive = [IO.Path]::GetFullPath($ExpectedActiveSlot).TrimEnd('\')
    if (-not $actualActive.Equals($expectedActive, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$($Checkpoint.Label) active slot does not match the exact expected path."
    }
    Assert-ExactSlotPayload -Slot $Checkpoint.ActiveSlot -ExpectedPayload $ExpectedPayload `
        -Description "$($Checkpoint.Label) active slot"
    if ($Checkpoint.InstallVersion -cne $versionText) {
        throw "$($Checkpoint.Label) InstallVersion '$($Checkpoint.InstallVersion)' is not '$versionText'."
    }
    foreach ($name in $installerOwnedRootValues) {
        $rawValue = $Checkpoint.InstallerRegistration[$name]
        if (-not $rawValue.Present -or $rawValue.Kind -cne 'String') {
            throw "$($Checkpoint.Label) installer-owned root value '$name' is absent or not REG_SZ."
        }
    }
    if ($Checkpoint.InstallerRegistration.ActiveSlot.Data -cne $Checkpoint.ActiveSlotPath -or
        $Checkpoint.InstallerRegistration.PreviousSlot.Data -cne $Checkpoint.PreviousSlotPath -or
        $Checkpoint.InstallerRegistration.InstallVersion.Data -cne $versionText) {
        throw "$($Checkpoint.Label) raw installer-owned root values are not canonical."
    }
    if ($null -eq $ExpectedPreviousSlot -or $ExpectedPreviousSlot -eq '') {
        if ($Checkpoint.PreviousSlotPath) { throw "$($Checkpoint.Label) unexpectedly recorded a previous slot." }
    }
    else {
        $expectedPrevious = [IO.Path]::GetFullPath($ExpectedPreviousSlot).TrimEnd('\')
        $actualPrevious = [IO.Path]::GetFullPath($Checkpoint.PreviousSlotPath).TrimEnd('\')
        if (-not $actualPrevious.Equals($expectedPrevious, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$($Checkpoint.Label) previous slot mismatch."
        }
        if ($null -eq $ExpectedPreviousPayload -or $null -eq $Checkpoint.PreviousSlot) {
            throw "$($Checkpoint.Label) cannot validate the expected previous payload."
        }
        Assert-ExactSlotPayload -Slot $Checkpoint.PreviousSlot -ExpectedPayload $ExpectedPreviousPayload `
            -Description "$($Checkpoint.Label) previous slot"
    }
    $expectedRun = '"' + $Checkpoint.ActiveSlot.Files.Host.Path + '"'
    if (-not $Checkpoint.RunStartup.Present -or $Checkpoint.RunStartup.Kind -cne 'String' -or
        $Checkpoint.RunStartup.Data -cne $expectedRun) {
        throw "$($Checkpoint.Label) Run startup command is not the exact active host path."
    }
    $displayVersion = Get-TreeValue -Tree $Checkpoint.UninstallEntry -RelativePath '' -Name 'DisplayVersion'
    $uninstallString = Get-TreeValue -Tree $Checkpoint.UninstallEntry -RelativePath '' -Name 'UninstallString'
    $expectedUninstall = '"' + $Checkpoint.ActiveSlot.Files.Setup.Path + '" --uninstall'
    if ($null -eq $displayVersion -or $displayVersion.Data -cne $versionText -or
        $null -eq $uninstallString -or $uninstallString.Data -cne $expectedUninstall) {
        throw "$($Checkpoint.Label) uninstall metadata does not match the active slot."
    }
    Assert-NoTransientServicingState -Checkpoint $Checkpoint
}

function Assert-UninstalledCheckpoint {
    param([Parameter(Mandatory)] $Checkpoint)
    if ($Checkpoint.ActiveSlotPath -or $Checkpoint.PreviousSlotPath -or $Checkpoint.InstallVersion -or
        $Checkpoint.InstallerRegistration.ActiveSlot.Present -or
        $Checkpoint.InstallerRegistration.PreviousSlot.Present -or
        $Checkpoint.InstallerRegistration.InstallVersion.Present) {
        throw "$($Checkpoint.Label) retained installed-slot state after uninstall."
    }
    if ($Checkpoint.RunStartup.Present) { throw "$($Checkpoint.Label) retained the Run startup value." }
    if ($Checkpoint.UninstallEntry.Exists) {
        throw "$($Checkpoint.Label) retained the installer-owned uninstall key."
    }
    Assert-NoTransientServicingState -Checkpoint $Checkpoint -AllowExactPendingCleanup
    if (-not $Checkpoint.CleanupRunOnce.Present -and (Test-Path -LiteralPath $versionsRoot)) {
        throw "$($Checkpoint.Label) is quiescent but retained the installer-owned versions directory."
    }
}

function Invoke-RecordedSetupStep {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)] $SetupIdentity,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $record = Invoke-CapturedProcess -Label $Label -FilePath $SetupIdentity.Path `
        -Arguments $Arguments -ExpectedSha256 $SetupIdentity.Sha256 `
        -TimeoutSeconds $OperationTimeoutSeconds
    $script:evidence.Steps.Add($record)
    Write-Evidence
    Assert-ProcessSucceededWithoutExplorerRestart $record
    return $record
}

function Add-CheckpointToStep {
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)][string] $Label
    )
    $Step.Checkpoint = Get-ProductCheckpoint -Label $Label
    Write-Evidence
    return $Step.Checkpoint
}

function Record-CacheRestoration {
    param(
        [Parameter(Mandatory)] $Original,
        [Parameter(Mandatory)][string] $Reason
    )
    $restored = Restore-OriginalDataCache -Original $Original
    $record = [ordered]@{
        Reason = $Reason
        RestoredUtc = [DateTime]::UtcNow.ToString('o')
        Result = $restored
    }
    $script:evidence.CacheRestorations.Add($record)
    Write-Evidence
    return $record
}

function Get-InstallerCheckpointProjection {
    param([Parameter(Mandatory)] $Checkpoint)
    return [ordered]@{
        ActiveSlotPath = $Checkpoint.ActiveSlotPath
        PreviousSlotPath = $Checkpoint.PreviousSlotPath
        InstallVersion = $Checkpoint.InstallVersion
        InstallerRegistration = $Checkpoint.InstallerRegistration
        ActiveSlot = $Checkpoint.ActiveSlot
        PreviousSlot = $Checkpoint.PreviousSlot
        RunStartup = $Checkpoint.RunStartup
        CleanupRunOnce = $Checkpoint.CleanupRunOnce
        RecoveryRunOnce = $Checkpoint.RecoveryRunOnce
        Servicing = $Checkpoint.Servicing
        UninstallEntry = $Checkpoint.UninstallEntry
    }
}

function Assert-DataCacheMatches {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Actual.Present -ne $Expected.Present -or
        ($Expected.Present -and ($Actual.Sha256 -cne $Expected.Sha256 -or
            $Actual.Length -ne $Expected.Length))) {
        throw "$Label DataCache.db does not match the original bytes/absence."
    }
}

function Get-CleanStartRecord {
    Assert-SafeInstallBoundary
    $registration = Get-InstallerRegistrationSnapshot
    foreach ($name in $installerOwnedRootValues) {
        if ($registration[$name].Present) {
            throw "Clean-start preflight requires installer-owned root value '$name' to be absent."
        }
    }
    if ($registration.Servicing.Exists) {
        throw 'Clean-start preflight requires the servicing journal to be absent.'
    }
    if ($registration.Uninstall.Exists) {
        throw 'Clean-start preflight requires the A4S uninstall key to be absent.'
    }
    if ($registration.Run.Present) {
        throw 'Clean-start preflight requires the A4S Run value to be absent.'
    }
    if ($registration.CleanupRunOnce.Present -or $registration.RecoveryRunOnce.Present) {
        throw 'Clean-start preflight requires both A4S RunOnce values to be absent.'
    }
    if (Test-Path -LiteralPath $versionsRoot) {
        throw 'Clean-start preflight requires the installer-owned versions directory to be absent.'
    }
    if (Test-Path -LiteralPath $cleanupHelperPath) {
        throw "Clean-start preflight requires the cleanup helper file to be absent: $cleanupHelperPath"
    }
    $processes = @(Get-A4SProcessRecords)
    if ($processes.Count -ne 0) {
        throw ('Clean-start preflight found an A4S host/setup/helper process: ' +
            (($processes | ForEach-Object { "$($_.Name) PID $($_.Id)" }) -join ', '))
    }
    return [ordered]@{
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        ExplorerPid = Get-ShellExplorerPid
        InstallerRegistration = $registration
        VersionsDirectoryPresent = $false
        CleanupHelperPath = $cleanupHelperPath
        CleanupHelperPresent = $false
        A4SProcesses = @()
    }
}

function Stop-FinalHostQuiescent {
    param([Parameter(Mandatory)] $Checkpoint)
    $result = [ordered]@{
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        Before = $Checkpoint.HostStatus
        Exit = $null
        After = $null
    }
    if ($Checkpoint.HostStatus.State -cne 'stopped' -or
        @($Checkpoint.HostProcesses).Count -ne 0) {
        $host = $Checkpoint.ActiveSlot.Files.Host
        $result.Exit = Invoke-CapturedProcess -Label 'final-host-exit' -FilePath $host.Path `
            -Arguments @('--exit') -ExpectedSha256 $host.Sha256 -TimeoutSeconds 10
        Assert-ProcessSucceededWithoutExplorerRestart $result.Exit
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            if (@(Get-HostProcessRecords -ActiveSlot $Checkpoint.ActiveSlot).Count -eq 0) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (@(Get-HostProcessRecords -ActiveSlot $Checkpoint.ActiveSlot).Count -ne 0) {
            throw 'The final resident host did not become quiescent inside the bounded interval.'
        }
    }
    $result.After = Get-HostStatusRecord -ActiveSlot $Checkpoint.ActiveSlot -Label 'final-quiescent'
    if ($result.After.State -cne 'stopped') {
        throw "Final host state is '$($result.After.State)', not stopped."
    }
    $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    return $result
}

$failure = $null
$mutationStarted = $false
$completedSuccessfully = $false
$originalUserState = $null
$originalDataCache = $null
$v1Identity = $null
$v2Identity = $null
$v1Payload = $null
$v2Payload = $null

try {
    $reviewedV1Hash = Normalize-Sha256 $ExpectedV1SetupSha256
    $reviewedV2Hash = Normalize-Sha256 $ExpectedV2SetupSha256
    if ($reviewedV1Hash -cne $frozenV1SetupSha256) {
        throw "ExpectedV1SetupSha256 must equal the frozen reviewed V1 identity $frozenV1SetupSha256."
    }

    $v1Identity = Get-BinaryIdentity -Path $V1SetupPath -Description 'frozen V1 setup fixture'
    $v2Identity = Get-BinaryIdentity -Path $V2SetupPath -Description 'current V2 setup fixture'
    $script:fixturePaths = @($v1Identity.Path, $v2Identity.Path)
    if ($v1Identity.Sha256 -cne $reviewedV1Hash) {
        throw 'The V1 setup fixture does not match ExpectedV1SetupSha256.'
    }
    if ($v2Identity.Sha256 -cne $reviewedV2Hash) {
        throw 'The V2 setup fixture does not match ExpectedV2SetupSha256.'
    }
    foreach ($identity in @($v1Identity, $v2Identity)) {
        if ($identity.OriginalFilename -cne 'A4SMenuSetup.exe') {
            throw "Installer fixture has the wrong OriginalFilename metadata: $($identity.Path)"
        }
    }
    if ([Version]([string]$v1Identity.ProductVersion) -ne $expectedV1) {
        throw "V1SetupPath must be the frozen 1.0.0.0 setup; found $($v1Identity.ProductVersion)."
    }
    if ([Version]([string]$v2Identity.ProductVersion) -ne $expectedV2) {
        throw "V2SetupPath must be the current 1.1.0.0 setup; found $($v2Identity.ProductVersion)."
    }
    if ($v1Identity.Sha256 -ceq $v2Identity.Sha256) {
        throw 'V1 and V2 setup fixtures have the same hash.'
    }
    foreach ($fixture in @($v1Identity, $v2Identity)) {
        if (Test-PathWithin -Path $fixture.Path -Parent $installRoot) {
            throw "Setup fixtures must remain outside the mutable install root: $($fixture.Path)"
        }
    }
    $v1Payload = Get-SetupPayloadIdentity -SetupIdentity $v1Identity `
        -ExpectedHostSha256 $frozenV1HostSha256 -ExpectedMenuSha256 $frozenV1MenuSha256
    $v2Payload = Get-SetupPayloadIdentity -SetupIdentity $v2Identity
    $script:expectedCleanupHash = $v2Identity.Sha256

    $evidenceRoot = Assert-LocalAbsolutePath $EvidenceDirectory
    if (Test-PathWithin -Path $evidenceRoot -Parent $installRoot) {
        throw 'Evidence and recovery data must remain outside the mutable A4S install root.'
    }
    Assert-NoReparsePointInExistingChain $evidenceRoot
    if (-not (Test-Path -LiteralPath $evidenceRoot)) {
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
    }
    if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) {
        throw "EvidenceDirectory is not a directory: $evidenceRoot"
    }
    Assert-NoReparsePointInExistingChain $evidenceRoot
    Assert-LocalAbsolutePath $cleanupHelperPath | Out-Null
    Assert-NoReparsePointInExistingChain $cleanupHelperPath

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $sessionId = [Guid]::NewGuid().ToString('N')
    $script:sessionDirectory = Join-Path $evidenceRoot "$stamp-$sessionId"
    if (Test-Path -LiteralPath $script:sessionDirectory) { throw 'Evidence session path collision.' }
    [IO.Directory]::CreateDirectory($script:sessionDirectory) | Out-Null
    Assert-NoReparsePointInExistingChain $script:sessionDirectory
    $script:evidencePath = Join-Path $script:sessionDirectory "A4SInstallerLifecycle-$stamp.json"
    $script:manifestPath = Join-Path $script:sessionDirectory 'pre-mutation-manifest.json'

    $cleanStart = Get-CleanStartRecord
    $originalUserState = Get-StableUserStateProjection
    $originalUserFingerprint = Get-ObjectFingerprint $originalUserState
    $cacheBackupPath = Join-Path $script:sessionDirectory 'DataCache.db.original'
    $originalDataCache = Backup-OriginalDataCache -BackupPath $cacheBackupPath
    $preMutationManifest = [ordered]@{
        SchemaVersion = 2
        Purpose = 'Immutable recovery manifest captured before any installer execution'
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        SessionId = $sessionId
        CurrentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        InstallRoot = $installRoot
        VersionsRoot = $versionsRoot
        CleanupHelperPath = $cleanupHelperPath
        ExpectedCleanupRunOnce = $expectedCleanupRunOnce
        Inputs = [ordered]@{ V1 = $v1Payload; V2 = $v2Payload }
        CleanStart = $cleanStart
        OriginalUserState = $originalUserState
        OriginalUserStateSha256 = $originalUserFingerprint
        OriginalDataCache = $originalDataCache
        ExplorerPid = $cleanStart.ExplorerPid
    }
    $manifestRecord = Write-ImmutableManifest -Path $script:manifestPath -Value $preMutationManifest
    $script:manifestSha256 = $manifestRecord.Sha256

    $script:evidence = [ordered]@{
        SchemaVersion = 2
        Test = 'A4S one-file installer clean-start live lifecycle'
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
        SessionId = $sessionId
        EvidencePath = $script:evidencePath
        ImmutableManifest = $manifestRecord
        Warning = 'LIVE HKCU install mutation; no --restart-explorer command is permitted.'
        CompatibilityNotes = @(
            'Frozen V1 uses only its documented --verify and --install commands; --self-test is intentionally not required.',
            'Rollback is invoked by the installed V2 setup; V1 is never run over an active V2 registration.',
            'Final V2 is deliberately left registered but host-quiescent; this harness does not restart Explorer or relaunch the host.'
        )
        Inputs = [ordered]@{ V1 = $v1Payload; V2 = $v2Payload }
        OriginalUserStateSha256 = $originalUserFingerprint
        OriginalDataCache = $originalDataCache
        CleanStart = $cleanStart
        Steps = [Collections.Generic.List[object]]::new()
        CacheRestorations = [Collections.Generic.List[object]]::new()
        UserStateRestoration = $null
        FinalHostQuiescence = $null
        FinalStability = $null
        Recovery = $null
        FinalState = $null
        Succeeded = $false
        Failure = $null
    }
    Write-Evidence

    # Any external installer execution is treated as a mutation risk, including
    # read-only verification. The immutable manifest already exists at this point.
    $mutationStarted = $true
    $probeV1 = Invoke-RecordedSetupStep -Label 'preflight-v1-verify' -SetupIdentity $v1Identity `
        -Arguments @('--verify', '--silent')
    $afterV1Probe = Get-CleanStartRecord
    $probeV1.CleanStartAfter = $afterV1Probe
    if ((Get-ObjectFingerprint (Get-UserStateProjection)) -cne $originalUserFingerprint) {
        throw 'The V1 verification probe changed user-owned A4S registry state.'
    }
    Assert-DataCacheMatches -Actual (Get-DataCacheRecord) -Expected $originalDataCache -Label 'V1 verification probe'
    Write-Evidence

    $probeV2 = Invoke-RecordedSetupStep -Label 'preflight-v2-verify' -SetupIdentity $v2Identity `
        -Arguments @('--verify', '--silent')
    $afterV2Probe = Get-CleanStartRecord
    $probeV2.CleanStartAfter = $afterV2Probe
    if ((Get-ObjectFingerprint (Get-UserStateProjection)) -cne $originalUserFingerprint) {
        throw 'The V2 verification probe changed user-owned A4S registry state.'
    }
    Assert-DataCacheMatches -Actual (Get-DataCacheRecord) -Expected $originalDataCache -Label 'V2 verification probe'
    Write-Evidence

    $installV1 = Invoke-RecordedSetupStep -Label 'install-v1-silent' -SetupIdentity $v1Identity `
        -Arguments @('--install', '--silent')
    $v1Checkpoint = Add-CheckpointToStep -Step $installV1 -Label 'installed-v1'
    $v1Slot = $v1Checkpoint.ActiveSlotPath
    Assert-InstalledCheckpoint -Checkpoint $v1Checkpoint -ExpectedVersion $expectedV1 `
        -ExpectedPayload $v1Payload -ExpectedActiveSlot $v1Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null

    $upgradeV2 = Invoke-RecordedSetupStep -Label 'upgrade-v1-to-v2-silent' -SetupIdentity $v2Identity `
        -Arguments @('--update', '--silent')
    $v2Checkpoint = Add-CheckpointToStep -Step $upgradeV2 -Label 'upgraded-v2'
    $v2Slot = $v2Checkpoint.ActiveSlotPath
    Assert-InstalledCheckpoint -Checkpoint $v2Checkpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $v1Slot -ExpectedPreviousPayload $v1Payload

    $installedV2Setup = $v2Checkpoint.ActiveSlot.Files.Setup
    $rollback = Invoke-RecordedSetupStep -Label 'rollback-v2-to-v1-silent' -SetupIdentity $installedV2Setup `
        -Arguments @('--rollback', '--silent')
    $rollbackCheckpoint = Add-CheckpointToStep -Step $rollback -Label 'rolled-back-v1'
    Assert-InstalledCheckpoint -Checkpoint $rollbackCheckpoint -ExpectedVersion $expectedV1 `
        -ExpectedPayload $v1Payload -ExpectedActiveSlot $v1Slot `
        -ExpectedPreviousSlot $v2Slot -ExpectedPreviousPayload $v2Payload

    $upgradeAgain = Invoke-RecordedSetupStep -Label 'upgrade-v1-to-v2-again-silent' -SetupIdentity $v2Identity `
        -Arguments @('--update', '--silent')
    $v2AgainCheckpoint = Add-CheckpointToStep -Step $upgradeAgain -Label 'upgraded-v2-again'
    Assert-InstalledCheckpoint -Checkpoint $v2AgainCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $v1Slot -ExpectedPreviousPayload $v1Payload

    $beforeRepairProjection = Get-InstallerCheckpointProjection $v2AgainCheckpoint
    $beforeRepairFingerprint = Get-ObjectFingerprint $beforeRepairProjection
    $installedRepairSetup = $v2AgainCheckpoint.ActiveSlot.Files.Setup
    $repair = Invoke-RecordedSetupStep -Label 'repair-v2-same-version-silent' -SetupIdentity $installedRepairSetup `
        -Arguments @('--repair', '--silent')
    $repairCheckpoint = Add-CheckpointToStep -Step $repair -Label 'repaired-v2-same-version'
    Assert-InstalledCheckpoint -Checkpoint $repairCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $v1Slot -ExpectedPreviousPayload $v1Payload
    $afterRepairFingerprint = Get-ObjectFingerprint (Get-InstallerCheckpointProjection $repairCheckpoint)
    if ($afterRepairFingerprint -cne $beforeRepairFingerprint) {
        throw 'Same-version repair changed the canonical installer registration or slot identities.'
    }
    $repair.RepairNoChangeSha256 = $afterRepairFingerprint
    Write-Evidence

    $installedUninstallSetup = $repairCheckpoint.ActiveSlot.Files.Setup
    $uninstall = Invoke-RecordedSetupStep -Label 'uninstall-v2-silent' -SetupIdentity $installedUninstallSetup `
        -Arguments @('--uninstall', '--silent')
    $uninstallCheckpoint = Add-CheckpointToStep -Step $uninstall -Label 'uninstalled-v2'
    Assert-UninstalledCheckpoint $uninstallCheckpoint

    $finalInstall = Invoke-RecordedSetupStep -Label 'final-install-v2-silent' -SetupIdentity $v2Identity `
        -Arguments @('--install', '--silent')
    $finalInstallCheckpoint = Add-CheckpointToStep -Step $finalInstall -Label 'final-v2-before-restoration'
    Assert-InstalledCheckpoint -Checkpoint $finalInstallCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null

    $script:evidence.FinalHostQuiescence = Stop-FinalHostQuiescent -Checkpoint $finalInstallCheckpoint
    Write-Evidence
    $finalInstallerRegistration = Get-InstallerRegistrationSnapshot
    $script:evidence.UserStateRestoration = Restore-UserStateProjection `
        -OriginalProjection $originalUserState -FinalInstallerRegistration $finalInstallerRegistration
    Record-CacheRestoration -Original $originalDataCache -Reason 'after final V2 host became quiescent' | Out-Null

    $restoredCheckpoint = Get-ProductCheckpoint -Label 'final-v2-restored-and-quiescent'
    Assert-InstalledCheckpoint -Checkpoint $restoredCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null
    if ($restoredCheckpoint.HostStatus.State -cne 'stopped' -or
        @($restoredCheckpoint.HostProcesses).Count -ne 0) {
        throw 'Final host was not quiescent at the restoration checkpoint.'
    }
    if ((Get-ObjectFingerprint $restoredCheckpoint.UserStateProjection) -cne $originalUserFingerprint) {
        throw 'Final user-owned registry fingerprint does not match the immutable manifest.'
    }
    Assert-DataCacheMatches -Actual $restoredCheckpoint.DataCache -Expected $originalDataCache -Label 'Final restoration'
    $restoredInstallerFingerprint = Get-ObjectFingerprint (Get-InstallerCheckpointProjection $restoredCheckpoint)

    if ($finalQuiescenceVerificationMilliseconds -le $preloadDebounceMilliseconds) {
        throw 'Final verification interval must be longer than the product preload debounce.'
    }
    Start-Sleep -Milliseconds $finalQuiescenceVerificationMilliseconds
    $stableCheckpoint = Get-ProductCheckpoint -Label 'final-v2-after-quiescence-interval'
    Assert-InstalledCheckpoint -Checkpoint $stableCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null
    if ($stableCheckpoint.HostStatus.State -cne 'stopped' -or
        @($stableCheckpoint.HostProcesses).Count -ne 0) {
        throw 'The host restarted during the post-restoration quiescence interval.'
    }
    if ((Get-ObjectFingerprint (Get-InstallerCheckpointProjection $stableCheckpoint)) -cne
        $restoredInstallerFingerprint) {
        throw 'Final installer-owned registration changed during the quiescence interval.'
    }
    if ((Get-ObjectFingerprint $stableCheckpoint.UserStateProjection) -cne $originalUserFingerprint) {
        throw 'Final user-owned registry state changed during the quiescence interval.'
    }
    Assert-DataCacheMatches -Actual $stableCheckpoint.DataCache -Expected $originalDataCache `
        -Label 'Post-quiescence verification'
    if ((Get-ShellExplorerPid) -ne $cleanStart.ExplorerPid) {
        throw 'Explorer PID changed somewhere in the lifecycle matrix.'
    }

    $script:evidence.FinalStability = [ordered]@{
        VerificationMilliseconds = $finalQuiescenceVerificationMilliseconds
        PreloadDebounceMilliseconds = $preloadDebounceMilliseconds
        InstallerProjectionSha256 = $restoredInstallerFingerprint
        UserStateSha256 = $originalUserFingerprint
        Checkpoint = $stableCheckpoint
        HostWasNotRestarted = $true
    }
    $script:evidence.FinalState = $stableCheckpoint
    $script:evidence.Succeeded = $true
    Write-Evidence
    $completedSuccessfully = $true
}
catch {
    $failure = $_
    if ($null -ne $script:evidence) {
        $script:evidence.Failure = [ordered]@{
            Message = $_.Exception.Message
            Category = [string]$_.CategoryInfo.Category
            ScriptStackTrace = $_.ScriptStackTrace
            CapturedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-Evidence
    }
}
finally {
    if (-not $completedSuccessfully -and $mutationStarted -and $null -ne $script:evidence) {
        $recovery = [ordered]@{
            StartedUtc = [DateTime]::UtcNow.ToString('o')
            SetupUninstall = $null
            UninstalledCheckpoint = $null
            CleanupObservation = $null
            UserStateRestored = $false
            DataCacheRestored = $false
            DurableBundleRetained = $true
            Errors = [Collections.Generic.List[string]]::new()
        }
        $script:evidence.Recovery = $recovery
        $canRecover = $true
        if ($null -ne $script:outstandingProcess) {
            try { $script:outstandingProcess.Refresh() } catch {}
            if (-not $script:outstandingProcess.HasExited) {
                $canRecover = $false
                $recovery.Errors.Add('A setup process is still running; recovery did not race or force-kill it. The immutable manifest and cache backup were retained.')
            }
        }
        if ($canRecover) {
            try {
                $recovery.SetupUninstall = Invoke-CapturedProcess -Label 'failure-recovery-uninstall-v2' `
                    -FilePath $v2Identity.Path -Arguments @('--uninstall', '--silent') `
                    -ExpectedSha256 $v2Identity.Sha256 -TimeoutSeconds $OperationTimeoutSeconds
                Assert-ProcessSucceededWithoutExplorerRestart $recovery.SetupUninstall
                $recovery.UninstalledCheckpoint = Get-ProductCheckpoint -Label 'failure-recovery-uninstalled'
                Assert-UninstalledCheckpoint $recovery.UninstalledCheckpoint
                Assert-NoTransientServicingState -Checkpoint $recovery.UninstalledCheckpoint `
                    -AllowExactPendingCleanup
                $recovery.CleanupObservation = $recovery.UninstalledCheckpoint.CleanupObservation
            }
            catch {
                $canRecover = $false
                $recovery.Errors.Add("Recovery uninstall/journal verification: $($_.Exception.Message)")
            }
        }
        if ($canRecover) {
            $cleanupPending = $recovery.UninstalledCheckpoint.CleanupRunOnce.Present -or
                -not $recovery.CleanupObservation.Quiescent -or
                $null -ne $recovery.CleanupObservation.HelperFile
            if ($cleanupPending) {
                $recovery.Errors.Add('Exact deferred cleanup is still pending; user state and DataCache were not raced. Use the immutable recovery bundle after cleanup completes.')
            }
            else {
                try {
                    Get-CleanStartRecord | Out-Null
                    Restore-CleanUserStateProjection -OriginalProjection $originalUserState | Out-Null
                    $recovery.UserStateRestored = $true
                    Restore-OriginalDataCache -Original $originalDataCache | Out-Null
                    $recovery.DataCacheRestored = $true
                    Get-CleanStartRecord | Out-Null
                    if ((Get-ObjectFingerprint (Get-UserStateProjection)) -cne
                            (Get-ObjectFingerprint $originalUserState)) {
                        throw 'Recovery user-owned registry fingerprint mismatch.'
                    }
                    Assert-DataCacheMatches -Actual (Get-DataCacheRecord) -Expected $originalDataCache `
                        -Label 'Failure recovery'
                }
                catch {
                    $recovery.Errors.Add("Clean-state restoration: $($_.Exception.Message)")
                }
            }
        }
        $recovery.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-Evidence
    }
    # Recovery files are intentionally retained. On any uncertainty they are the
    # only durable authority; on success they preserve an auditable qualification.
    Write-Evidence
}

if ($null -ne $failure) {
    $suffix = if ($script:evidencePath) { " Evidence: $script:evidencePath" } else { '' }
    $recoverySuffix = ''
    if ($null -ne $script:evidence -and $null -ne $script:evidence.Recovery -and
        $script:evidence.Recovery.Errors.Count -ne 0) {
        $recoverySuffix = ' Recovery warnings: ' + ($script:evidence.Recovery.Errors -join ' | ')
    }
    throw "A4S installer lifecycle qualification failed: $($failure.Exception.Message)$recoverySuffix$suffix"
}

Write-Host "A4S installer lifecycle qualification passed. Evidence: $script:evidencePath"
