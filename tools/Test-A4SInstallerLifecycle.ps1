<#
.SYNOPSIS
Runs the destructive, live per-user installer lifecycle matrix and writes JSON evidence.

.DESCRIPTION
This tool uninstalls any current A4S registration, exercises the frozen 1.0 and
current 1.1 one-file installers, and intentionally leaves 1.1 installed. It
never passes --restart-explorer. Exact pre-test A4S registry values are retained
for failure recovery only; successful completion retains installer-authored 1.1
registration and restores the original DataCache.db bytes (or absence).

.EXAMPLE
.\tools\Test-A4SInstallerLifecycle.ps1 -V1SetupPath C:\fixtures\A4SMenuSetup-1.0.exe `
    -V2SetupPath C:\fixtures\A4SMenuSetup-1.1.exe -AllowInstallMutation

.NOTES
Prerequisites: 64-bit PowerShell, an interactive current-session Explorer,
local non-reparse fixture/evidence paths, exact x64 1.0.0.0 and 1.1.0.0 setup
files, and no active A4S setup/cleanup journal, RunOnce continuation, or helper.
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
$expectedV1 = [Version]'1.0.0.0'
$expectedV2 = [Version]'1.1.0.0'
$script:captureCounter = 0
$script:outstandingProcess = $null
$script:evidence = $null
$script:evidencePath = $null
$script:sessionDirectory = $null

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

function Get-RegistrationSnapshot {
    return [ordered]@{
        Product = Get-RegistryTreeSnapshot -SubKey $stateSubKey
        Uninstall = Get-RegistryTreeSnapshot -SubKey $uninstallSubKey
        Run = Get-RegistryValueSnapshot -SubKey $runSubKey -Name $runValueName
        CleanupRunOnce = Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $cleanupRunOnceName
        RecoveryRunOnce = Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $recoveryRunOnceName
    }
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

function Get-StableRegistrationSnapshot {
    for ($attempt = 1; $attempt -le 3; ++$attempt) {
        $first = Get-RegistrationSnapshot
        Start-Sleep -Milliseconds 100
        $second = Get-RegistrationSnapshot
        if ((Get-ObjectFingerprint $first) -ceq (Get-ObjectFingerprint $second)) {
            return $second
        }
    }
    throw 'The A4S registry state changed repeatedly during preflight; no installation mutation was started.'
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

function Restore-RegistrationSnapshot {
    param([Parameter(Mandatory)] $Snapshot)

    Restore-RegistryTreeSnapshot -ExpectedSubKey $stateSubKey -Snapshot $Snapshot.Product
    Restore-RegistryTreeSnapshot -ExpectedSubKey $uninstallSubKey -Snapshot $Snapshot.Uninstall
    Restore-RegistryValueSnapshot -SubKey $runSubKey -Snapshot $Snapshot.Run
    Restore-RegistryValueSnapshot -SubKey $runOnceSubKey -Snapshot $Snapshot.CleanupRunOnce
    Restore-RegistryValueSnapshot -SubKey $runOnceSubKey -Snapshot $Snapshot.RecoveryRunOnce
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

    public static uint GetShellExplorerProcessId()
    {
        IntPtr taskbar = FindWindowW("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Shell_TrayWnd was not found");
        uint processId;
        if (GetWindowThreadProcessId(taskbar, out processId) == 0 || processId == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The taskbar Explorer PID could not be resolved");
        return processId;
    }
}
'@
}

function Get-ShellExplorerPid {
    $processId = [int][A4SInstallerLifecycleNative]::GetShellExplorerProcessId()
    $process = Get-Process -Id $processId -ErrorAction Stop
    if ($process.ProcessName -ine 'explorer' -or $process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId) {
        throw "Shell_TrayWnd is not owned by the current-session Explorer process: PID $processId"
    }
    return $processId
}

function Get-CleanupProcessRecords {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'A4SMenuCleanup' -ErrorAction SilentlyContinue | Sort-Object Id)) {
        $path = $null
        $started = $null
        try { $path = $process.Path } catch {}
        try { $started = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
        $records.Add([ordered]@{ Id = $process.Id; Path = $path; StartTimeUtc = $started })
    }
    return @($records)
}

function Wait-CleanupProcessQuiescence {
    param([ValidateRange(1, 30)][int] $TimeoutSeconds = 20)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $records = @(Get-CleanupProcessRecords)
        if ($records.Count -eq 0) {
            return [ordered]@{ Quiescent = $true; Processes = @(); WaitedUntilUtc = [DateTime]::UtcNow.ToString('o') }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return [ordered]@{
        Quiescent = $false
        Processes = @(Get-CleanupProcessRecords)
        WaitedUntilUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-Evidence {
    if ($null -eq $script:evidence -or -not $script:evidencePath) { return }
    $script:evidence.LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $json = $script:evidence | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($script:evidencePath, $json, [Text.UTF8Encoding]::new($false))
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
    $run = Get-RegistryValueSnapshot -SubKey $runSubKey -Name $runValueName
    $checkpoint = [ordered]@{
        Label = $Label
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        ExplorerPid = Get-ShellExplorerPid
        ActiveSlotPath = $activePath
        PreviousSlotPath = $previousPath
        InstallVersion = Get-StringRegistryValue -SubKey $stateSubKey -Name 'InstallVersion'
        ActiveSlot = $active
        PreviousSlot = $previous
        RunStartup = $run
        CleanupRunOnce = Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $cleanupRunOnceName
        RecoveryRunOnce = Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $recoveryRunOnceName
        UninstallEntry = Get-RegistryTreeSnapshot -SubKey $uninstallSubKey
        DataCache = Get-DataCacheRecord
        CleanupProcesses = @(Get-CleanupProcessRecords)
    }
    $checkpoint.HostStatus = Get-HostStatusRecord -ActiveSlot $active -Label $Label
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

function Assert-InstalledCheckpoint {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][Version] $ExpectedVersion,
        [Parameter(Mandatory)][string] $ExpectedSetupHash,
        [AllowNull()][string] $ExpectedPreviousSlot
    )

    if ($null -eq $Checkpoint.ActiveSlot) { throw "$($Checkpoint.Label) has no active slot." }
    $versionText = $ExpectedVersion.ToString(4)
    foreach ($file in @($Checkpoint.ActiveSlot.Files.Host, $Checkpoint.ActiveSlot.Files.Menu,
            $Checkpoint.ActiveSlot.Files.Setup)) {
        if ($file.ProductVersion -cne $versionText) {
            throw "$($Checkpoint.Label) active payload version '$($file.ProductVersion)' is not '$versionText'."
        }
    }
    if ($Checkpoint.ActiveSlot.Files.Setup.Sha256 -cne $ExpectedSetupHash) {
        throw "$($Checkpoint.Label) active setup copy does not match the selected installer fixture."
    }
    if ($Checkpoint.InstallVersion -cne $versionText) {
        throw "$($Checkpoint.Label) InstallVersion '$($Checkpoint.InstallVersion)' is not '$versionText'."
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
    if ($Checkpoint.RecoveryRunOnce.Present) {
        throw "$($Checkpoint.Label) left a servicing-recovery RunOnce value after commit."
    }
}

function Assert-UninstalledCheckpoint {
    param([Parameter(Mandatory)] $Checkpoint)
    if ($Checkpoint.ActiveSlotPath -or $Checkpoint.PreviousSlotPath -or $Checkpoint.InstallVersion) {
        throw "$($Checkpoint.Label) retained installed-slot state after uninstall."
    }
    if ($Checkpoint.RunStartup.Present) { throw "$($Checkpoint.Label) retained the Run startup value." }
    foreach ($name in @('DisplayName', 'DisplayVersion', 'UninstallString', 'QuietUninstallString')) {
        if ($null -ne (Get-TreeValue -Tree $Checkpoint.UninstallEntry -RelativePath '' -Name $name)) {
            throw "$($Checkpoint.Label) retained uninstall value '$name'."
        }
    }
    if ($Checkpoint.RecoveryRunOnce.Present) {
        throw "$($Checkpoint.Label) retained a servicing-recovery RunOnce value."
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

$failure = $null
$mutationStarted = $false
$completedSuccessfully = $false
$originalRegistration = $null
$originalDataCache = $null
$v1Identity = $null
$v2Identity = $null

try {
    $v1Identity = Get-BinaryIdentity -Path $V1SetupPath -Description 'frozen V1 setup fixture'
    $v2Identity = Get-BinaryIdentity -Path $V2SetupPath -Description 'current V2 setup fixture'
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
    if ($v1Identity.Sha256 -ceq $v2Identity.Sha256) { throw 'V1 and V2 setup fixtures have the same hash.' }
    foreach ($fixture in @($v1Identity, $v2Identity)) {
        if (Test-PathWithin -Path $fixture.Path -Parent $installRoot) {
            throw "Setup fixtures must remain outside the mutable install root: $($fixture.Path)"
        }
    }

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
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $sessionId = [Guid]::NewGuid().ToString('N')
    $script:sessionDirectory = Join-Path $evidenceRoot "$stamp-$sessionId"
    if (Test-Path -LiteralPath $script:sessionDirectory) { throw 'Evidence session path collision.' }
    [IO.Directory]::CreateDirectory($script:sessionDirectory) | Out-Null
    Assert-NoReparsePointInExistingChain $script:sessionDirectory
    $script:evidencePath = Join-Path $script:sessionDirectory "A4SInstallerLifecycle-$stamp.json"

    Assert-SafeInstallBoundary
    if (Test-Path -LiteralPath ("HKCU:\" + $servicingSubKey)) {
        throw 'A servicing journal already exists. Run the current setup --reconcile --silent, then retry.'
    }
    if ((Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $recoveryRunOnceName).Present -or
        (Get-RegistryValueSnapshot -SubKey $runOnceSubKey -Name $cleanupRunOnceName).Present) {
        throw 'A4S RunOnce recovery/cleanup work is already pending; finish it before this lifecycle test.'
    }
    $servicingProcesses = @(Get-Process -Name 'A4SMenuSetup', 'A4SMenuCleanup' -ErrorAction SilentlyContinue)
    if ($servicingProcesses.Count -ne 0) {
        throw 'Another A4S setup or cleanup process is active; no mutation was started.'
    }

    $originalRegistration = Get-StableRegistrationSnapshot
    $cacheBackupPath = Join-Path $script:sessionDirectory 'DataCache.db.original'
    $originalDataCache = Backup-OriginalDataCache -BackupPath $cacheBackupPath
    $originalCheckpoint = Get-ProductCheckpoint -Label 'original-state'
    $script:evidence = [ordered]@{
        SchemaVersion = 1
        Test = 'A4S one-file installer live lifecycle'
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
        SessionId = $sessionId
        EvidencePath = $script:evidencePath
        Warning = 'LIVE HKCU install mutation; no --restart-explorer command is permitted.'
        CompatibilityNotes = @(
            'Frozen V1 is used only for --verify and the initial documented --install operation; its newer --self-test contract is not required.',
            'Rollback is invoked by the installed V2 setup; V1 is never run over an active V2 registration.',
            'A retained Explorer DLL mapping can leave the final registered V2 host stopped until a manual Explorer restart plus host launch, or the next sign-in.'
        )
        Inputs = [ordered]@{ V1 = $v1Identity; V2 = $v2Identity }
        InstallRoot = $installRoot
        OriginalRegistration = $originalRegistration
        OriginalRegistrationSha256 = Get-ObjectFingerprint $originalRegistration
        OriginalDataCache = $originalDataCache
        OriginalCheckpoint = $originalCheckpoint
        Steps = [Collections.Generic.List[object]]::new()
        CacheRestorations = [Collections.Generic.List[object]]::new()
        Recovery = $null
        FinalState = $null
        Succeeded = $false
        Failure = $null
    }
    Write-Evidence

    # V1 has no compatible servicing self-test. Its documented --verify probe is
    # intentionally the only preflight command used from the frozen fixture.
    $beforeProbe = Get-ObjectFingerprint $originalRegistration
    $probeV1 = Invoke-RecordedSetupStep -Label 'preflight-v1-verify' -SetupIdentity $v1Identity `
        -Arguments @('--verify', '--silent')
    $probeV2 = Invoke-RecordedSetupStep -Label 'preflight-v2-verify' -SetupIdentity $v2Identity `
        -Arguments @('--verify', '--silent')
    $afterProbe = Get-RegistrationSnapshot
    if ((Get-ObjectFingerprint $afterProbe) -cne $beforeProbe) {
        throw 'A read-only installer verification probe changed A4S registration.'
    }
    $cacheAfterProbe = Get-DataCacheRecord
    if ($cacheAfterProbe.Present -ne $originalDataCache.Present -or
        ($cacheAfterProbe.Present -and ($cacheAfterProbe.Sha256 -cne $originalDataCache.Sha256 -or
            $cacheAfterProbe.Length -ne $originalDataCache.Length))) {
        throw 'A read-only installer verification probe changed DataCache.db.'
    }

    $mutationStarted = $true
    $baseline = Invoke-RecordedSetupStep -Label 'baseline-uninstall-v2' -SetupIdentity $v2Identity `
        -Arguments @('--uninstall', '--silent')
    $baselineCheckpoint = Add-CheckpointToStep -Step $baseline -Label 'baseline-uninstalled'
    Assert-UninstalledCheckpoint $baselineCheckpoint

    # If the cleanup helper is already quiescent, restore the original cache
    # before V1 so install/update preservation is exercised. If it is waiting on
    # an Explorer mapping, V1 registration must commit first so that helper can
    # no longer treat the tree as uninstalled.
    $restoreAfterV1 = @($baselineCheckpoint.CleanupProcesses).Count -ne 0
    if (-not $restoreAfterV1) {
        Record-CacheRestoration -Original $originalDataCache -Reason 'before initial V1 install' | Out-Null
    }

    $installV1 = Invoke-RecordedSetupStep -Label 'install-v1-silent' -SetupIdentity $v1Identity `
        -Arguments @('--install', '--silent')
    $v1Checkpoint = Add-CheckpointToStep -Step $installV1 -Label 'installed-v1'
    Assert-InstalledCheckpoint -Checkpoint $v1Checkpoint -ExpectedVersion $expectedV1 `
        -ExpectedSetupHash $v1Identity.Sha256 -ExpectedPreviousSlot $null
    if ($restoreAfterV1) {
        Record-CacheRestoration -Original $originalDataCache -Reason 'after V1 committed over pending cleanup' | Out-Null
    }
    $v1Slot = $v1Checkpoint.ActiveSlotPath

    $upgradeV2 = Invoke-RecordedSetupStep -Label 'upgrade-v1-to-v2-silent' -SetupIdentity $v2Identity `
        -Arguments @('--update', '--silent')
    $v2Checkpoint = Add-CheckpointToStep -Step $upgradeV2 -Label 'upgraded-v2'
    Assert-InstalledCheckpoint -Checkpoint $v2Checkpoint -ExpectedVersion $expectedV2 `
        -ExpectedSetupHash $v2Identity.Sha256 -ExpectedPreviousSlot $v1Slot
    $firstV2Slot = $v2Checkpoint.ActiveSlotPath

    # Rollback is owned by the installed/current V2 setup. An old setup is never
    # run over an active newer registration.
    $installedV2Setup = $v2Checkpoint.ActiveSlot.Files.Setup
    $rollback = Invoke-RecordedSetupStep -Label 'rollback-v2-to-v1-silent' -SetupIdentity $installedV2Setup `
        -Arguments @('--rollback', '--silent')
    $rollbackCheckpoint = Add-CheckpointToStep -Step $rollback -Label 'rolled-back-v1'
    Assert-InstalledCheckpoint -Checkpoint $rollbackCheckpoint -ExpectedVersion $expectedV1 `
        -ExpectedSetupHash $v1Identity.Sha256 -ExpectedPreviousSlot $firstV2Slot
    if (-not $rollbackCheckpoint.ActiveSlotPath.Equals($v1Slot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Rollback did not restore the exact recorded V1 slot.'
    }

    $upgradeAgain = Invoke-RecordedSetupStep -Label 'upgrade-v1-to-v2-again-silent' -SetupIdentity $v2Identity `
        -Arguments @('--update', '--silent')
    $v2AgainCheckpoint = Add-CheckpointToStep -Step $upgradeAgain -Label 'upgraded-v2-again'
    Assert-InstalledCheckpoint -Checkpoint $v2AgainCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedSetupHash $v2Identity.Sha256 -ExpectedPreviousSlot $v1Slot

    $installedRepairSetup = $v2AgainCheckpoint.ActiveSlot.Files.Setup
    $repair = Invoke-RecordedSetupStep -Label 'repair-v2-same-version-silent' -SetupIdentity $installedRepairSetup `
        -Arguments @('--repair', '--silent')
    $repairCheckpoint = Add-CheckpointToStep -Step $repair -Label 'repaired-v2-same-version'
    Assert-InstalledCheckpoint -Checkpoint $repairCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedSetupHash $v2Identity.Sha256 -ExpectedPreviousSlot $v1Slot

    $installedUninstallSetup = $repairCheckpoint.ActiveSlot.Files.Setup
    $uninstall = Invoke-RecordedSetupStep -Label 'uninstall-v2-silent' -SetupIdentity $installedUninstallSetup `
        -Arguments @('--uninstall', '--silent')
    $uninstallCheckpoint = Add-CheckpointToStep -Step $uninstall -Label 'uninstalled-v2'
    Assert-UninstalledCheckpoint $uninstallCheckpoint

    $restoreAfterFinal = @($uninstallCheckpoint.CleanupProcesses).Count -ne 0
    if (-not $restoreAfterFinal) {
        Record-CacheRestoration -Original $originalDataCache -Reason 'before final V2 install' | Out-Null
    }

    $finalInstall = Invoke-RecordedSetupStep -Label 'final-install-v2-silent' -SetupIdentity $v2Identity `
        -Arguments @('--install', '--silent')
    $finalInstallCheckpoint = Add-CheckpointToStep -Step $finalInstall -Label 'final-v2-before-cache-check'
    Assert-InstalledCheckpoint -Checkpoint $finalInstallCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedSetupHash $v2Identity.Sha256 -ExpectedPreviousSlot $null
    if ($restoreAfterFinal) {
        Record-CacheRestoration -Original $originalDataCache -Reason 'after final V2 protected cache from pending cleanup' | Out-Null
    }

    $finalCheckpoint = Get-ProductCheckpoint -Label 'final-v2-with-original-cache'
    Assert-InstalledCheckpoint -Checkpoint $finalCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedSetupHash $v2Identity.Sha256 -ExpectedPreviousSlot $null
    if ($originalDataCache.Present) {
        if (-not $finalCheckpoint.DataCache.Present -or
            $finalCheckpoint.DataCache.Sha256 -cne $originalDataCache.Sha256 -or
            $finalCheckpoint.DataCache.Length -ne $originalDataCache.Length) {
            throw 'Final V2 registration is valid, but DataCache.db does not match the original.'
        }
    }
    elseif ($finalCheckpoint.DataCache.Present) {
        throw 'DataCache.db was originally absent but is present in the final state.'
    }
    if ((Get-ShellExplorerPid) -ne $script:evidence.OriginalCheckpoint.ExplorerPid) {
        throw 'Explorer PID changed somewhere in the lifecycle matrix.'
    }

    $script:evidence.FinalState = $finalCheckpoint
    $script:evidence.Succeeded = $true
    $completedSuccessfully = $true
    Write-Evidence
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
            CleanupQuiescence = $null
            ProtectiveInstall = $null
            RegistrationRestored = $false
            DataCacheRestored = $false
            Errors = [Collections.Generic.List[string]]::new()
        }
        $script:evidence.Recovery = $recovery
        $canRecover = $true
        if ($null -ne $script:outstandingProcess) {
            try { $script:outstandingProcess.Refresh() } catch {}
            if (-not $script:outstandingProcess.HasExited) {
                $canRecover = $false
                $recovery.Errors.Add('A setup process is still running; recovery did not race or force-kill it. Use the evidence and cache backup after it exits.')
            }
        }
        if ($canRecover) {
            try {
                $recovery.SetupUninstall = Invoke-CapturedProcess -Label 'failure-recovery-uninstall-v2' `
                    -FilePath $v2Identity.Path -Arguments @('--uninstall', '--silent') `
                    -ExpectedSha256 $v2Identity.Sha256 -TimeoutSeconds $OperationTimeoutSeconds
                if ($recovery.SetupUninstall.TimedOut) {
                    throw 'Recovery uninstall timed out and was not force-killed.'
                }
            }
            catch {
                $recovery.Errors.Add("Recovery uninstall: $($_.Exception.Message)")
            }
            $recovery.CleanupQuiescence = Wait-CleanupProcessQuiescence -TimeoutSeconds 20
            $originalActive = Get-TreeValue -Tree $originalRegistration.Product `
                -RelativePath '' -Name 'ActiveSlot'
            $originalWasInstalled = $originalRegistration.Run.Present -and $null -ne $originalActive -and
                [string]$originalActive.Data
            $safeToRestore = $recovery.CleanupQuiescence.Quiescent
            if (-not $safeToRestore -and $originalWasInstalled) {
                try {
                    # A committed registration makes a helper still waiting on an
                    # Explorer mapping return without deleting cache/state. The
                    # exact original registration is restored immediately after.
                    $recovery.ProtectiveInstall = Invoke-CapturedProcess `
                        -Label 'failure-recovery-protective-v2-install' -FilePath $v2Identity.Path `
                        -Arguments @('--install', '--silent') -ExpectedSha256 $v2Identity.Sha256 `
                        -TimeoutSeconds $OperationTimeoutSeconds
                    Assert-ProcessSucceededWithoutExplorerRestart $recovery.ProtectiveInstall
                    $safeToRestore = $true
                }
                catch {
                    $recovery.Errors.Add("Protective recovery install: $($_.Exception.Message)")
                }
            }
            elseif (-not $safeToRestore) {
                $recovery.Errors.Add('Cleanup is still waiting and the original state was uninstalled; the script retained the exact registry snapshot and cache backup instead of racing the helper.')
            }
            if ($safeToRestore) {
                try {
                    Restore-RegistrationSnapshot -Snapshot $originalRegistration
                    $restoredRegistration = Get-RegistrationSnapshot
                    if ((Get-ObjectFingerprint $restoredRegistration) -cne
                        (Get-ObjectFingerprint $originalRegistration)) {
                        throw 'The recovered registry value snapshot does not match the original.'
                    }
                    $recovery.RegistrationRestored = $true
                }
                catch {
                    $recovery.Errors.Add("Registry recovery: $($_.Exception.Message)")
                }
                try {
                    Restore-OriginalDataCache -Original $originalDataCache | Out-Null
                    $recovery.DataCacheRestored = $true
                }
                catch {
                    $recovery.Errors.Add("DataCache recovery: $($_.Exception.Message)")
                }
            }
        }
        $recovery.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-Evidence
    }

    if ($null -ne $originalDataCache -and $originalDataCache.Present -and
        $originalDataCache.BackupPath -and (Test-Path -LiteralPath $originalDataCache.BackupPath)) {
        $safeToRemoveBackup = $completedSuccessfully -or
            ($null -ne $script:evidence -and $null -ne $script:evidence.Recovery -and
                $script:evidence.Recovery.DataCacheRestored -and
                $script:evidence.Recovery.RegistrationRestored -and
                $script:evidence.Recovery.Errors.Count -eq 0)
        if ($safeToRemoveBackup) {
            try {
                Assert-RegularFile -Path $originalDataCache.BackupPath -Description 'completed DataCache.db recovery backup' | Out-Null
                [IO.File]::Delete($originalDataCache.BackupPath)
                if ($null -ne $script:evidence) {
                    $script:evidence.OriginalDataCache.BackupRemovedAfterVerifiedRestore = $true
                }
            }
            catch {
                if ($null -ne $script:evidence -and $null -ne $script:evidence.Recovery) {
                    $script:evidence.Recovery.Errors.Add("Backup cleanup: $($_.Exception.Message)")
                }
            }
        }
    }
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
