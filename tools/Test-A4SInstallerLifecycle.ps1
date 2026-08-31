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
$script:lifecycleMutex = $null
$script:lifecycleMutexHeld = $false
$script:lastOwnedAggregate = $null
$script:ownedAggregateLedger = [Collections.Generic.List[object]]::new()
$script:knownPayloadBySlotName = [ordered]@{}

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.Trim().ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{64}$') { throw "Invalid SHA-256 value: $Value" }
    return $normalized
}

function Acquire-LifecycleMutex {
    if ($script:lifecycleMutexHeld) { throw 'The lifecycle mutex is already held by this harness.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $bytes = [Text.Encoding]::UTF8.GetBytes($sid)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $suffix = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').Substring(0, 32) }
    finally { $algorithm.Dispose() }
    $name = "Local\A4SMenuInstallerLifecycle-$suffix"
    $script:lifecycleMutex = [Threading.Mutex]::new($false, $name)
    try {
        try { $acquired = $script:lifecycleMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'Another A4S installer lifecycle harness owns the current-user qualification lock.'
        }
        $script:lifecycleMutexHeld = $true
        return $name
    }
    catch {
        $script:lifecycleMutex.Dispose()
        $script:lifecycleMutex = $null
        throw
    }
}

function Release-LifecycleMutex {
    if ($script:lifecycleMutexHeld -and $null -ne $script:lifecycleMutex) {
        $script:lifecycleMutex.ReleaseMutex()
        $script:lifecycleMutexHeld = $false
    }
    if ($null -ne $script:lifecycleMutex) {
        $script:lifecycleMutex.Dispose()
        $script:lifecycleMutex = $null
    }
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
    if ($tail.Count -ne 0 -and -not (Test-Path -LiteralPath $cursor -PathType Container)) {
        throw "The nearest existing ancestor for $full is not a directory: $cursor"
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
    param([switch] $ExcludeHostSafety)

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
        if ($ExcludeHostSafety -and ($relative -ieq 'HostSafety' -or
                $relative.StartsWith('HostSafety\', [StringComparison]::OrdinalIgnoreCase))) {
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

function Get-LegacyUserStateProjection {
    $full = Get-UserStateProjection
    if (-not $full.Exists) { return $full }
    $nodes = [Collections.Generic.List[object]]::new()
    foreach ($node in @($full.Nodes)) {
        $relative = [string]$node.RelativePath
        $excluded = $false
        foreach ($name in @('Config', 'Menu', 'HostSafety')) {
            if ($relative -ieq $name -or
                $relative.StartsWith($name + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $excluded = $true
                break
            }
        }
        if (-not $excluded) { $nodes.Add($node) }
    }
    $hasContent = @($nodes | Where-Object {
        [string]$_.RelativePath -or @($_.Values).Count -ne 0
    }).Count -ne 0
    if (-not $hasContent) {
        return [ordered]@{ SubKey = $stateSubKey; Exists = $false; Nodes = @() }
    }
    return [ordered]@{ SubKey = $stateSubKey; Exists = $true; Nodes = @($nodes) }
}

function Get-UserStatePartitions {
    return [ordered]@{
        Config = Get-RegistryTreeSnapshot -SubKey ($stateSubKey + '\Config')
        Menu = Get-RegistryTreeSnapshot -SubKey ($stateSubKey + '\Menu')
        Legacy = Get-LegacyUserStateProjection
        HostSafety = Get-RegistryTreeSnapshot -SubKey ($stateSubKey + '\HostSafety')
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

function Get-NamedMemberValue {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string] $Name
    )
    if ($Value -is [Collections.IDictionary]) {
        if (-not $Value.Contains($Name)) { throw "Required member '$Name' is absent." }
        return $Value[$Name]
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Required member '$Name' is absent." }
    return $property.Value
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
using System.Text;

public sealed class A4SPhysicalPathRecord
{
    public string FinalPath { get; set; }
    public uint VolumeSerialNumber { get; set; }
    public ulong FileId { get; set; }
}

public static class A4SInstallerLifecycleNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

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
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder path,
        uint characters, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr file,
        out BY_HANDLE_FILE_INFORMATION information);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

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

    public static A4SPhysicalPathRecord ResolveExistingPath(string path)
    {
        const uint ReadAttributes = 0x80;
        const uint ShareAll = 0x1 | 0x2 | 0x4;
        const uint OpenExisting = 3;
        const uint BackupSemantics = 0x02000000;
        IntPtr handle = CreateFileW(path, ReadAttributes, ShareAll, IntPtr.Zero,
            OpenExisting, BackupSemantics, IntPtr.Zero);
        if (handle == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW failed for physical-path resolution");
        try
        {
            uint needed = GetFinalPathNameByHandleW(handle, null, 0, 0);
            if (needed == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFinalPathNameByHandleW failed");
            StringBuilder finalPath = new StringBuilder(checked((int)needed + 1));
            uint written = GetFinalPathNameByHandleW(handle, finalPath,
                checked((uint)finalPath.Capacity), 0);
            if (written == 0 || written >= finalPath.Capacity)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFinalPathNameByHandleW returned an invalid path");
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed");
            return new A4SPhysicalPathRecord {
                FinalPath = finalPath.ToString(),
                VolumeSerialNumber = information.VolumeSerialNumber,
                FileId = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow
            };
        }
        finally { CloseHandle(handle); }
    }
}
'@
}

function Get-PhysicalPathRecord {
    param([Parameter(Mandatory)][string] $Path)

    $full = Assert-LocalAbsolutePath $Path
    $cursor = $full
    $tail = [Collections.Generic.List[string]]::new()
    while (-not (Test-Path -LiteralPath $cursor)) {
        $leaf = [IO.Path]::GetFileName($cursor.TrimEnd('\'))
        if (-not $leaf) { throw "Could not resolve a nearest existing ancestor for $full." }
        $tail.Insert(0, $leaf)
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { throw "Could not resolve a nearest existing ancestor for $full." }
        $cursor = $parent.FullName
    }
    $resolved = [A4SInstallerLifecycleNative]::ResolveExistingPath($cursor)
    $canonical = [string]$resolved.FinalPath
    foreach ($segment in $tail) { $canonical = $canonical.TrimEnd('\') + '\' + $segment }
    return [ordered]@{
        RequestedPath = $full
        ExistingAncestor = $cursor
        ExistingAncestorFinalPath = [string]$resolved.FinalPath
        ExistingAncestorVolumeSerial = ('{0:X8}' -f [uint32]$resolved.VolumeSerialNumber)
        ExistingAncestorFileId = ('{0:X16}' -f [uint64]$resolved.FileId)
        NonExistingTail = @($tail)
        CanonicalPath = $canonical.TrimEnd('\')
    }
}

function Test-CanonicalPhysicalOverlap {
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right
    )
    if ($Left.ExistingAncestorVolumeSerial -cne $Right.ExistingAncestorVolumeSerial) {
        return $false
    }
    $leftTail = @($Left.NonExistingTail)
    $rightTail = @($Right.NonExistingTail)
    if ($Left.ExistingAncestorFileId -ceq $Right.ExistingAncestorFileId) {
        $leftRelative = ($leftTail -join '\').TrimEnd('\')
        $rightRelative = ($rightTail -join '\').TrimEnd('\')
        $leftContainsRight = -not $leftRelative -or
            $rightRelative.Equals($leftRelative, [StringComparison]::OrdinalIgnoreCase) -or
            $rightRelative.StartsWith($leftRelative + '\',
                [StringComparison]::OrdinalIgnoreCase)
        $rightContainsLeft = -not $rightRelative -or
            $leftRelative.Equals($rightRelative, [StringComparison]::OrdinalIgnoreCase) -or
            $leftRelative.StartsWith($rightRelative + '\',
                [StringComparison]::OrdinalIgnoreCase)
        if ($leftContainsRight -or $rightContainsLeft) { return $true }
    }
    $leftPath = ([string]$Left.CanonicalPath).TrimEnd('\')
    $rightPath = ([string]$Right.CanonicalPath).TrimEnd('\')
    $leftContainsRight = $rightPath.Equals($leftPath, [StringComparison]::OrdinalIgnoreCase) -or
        $rightPath.StartsWith($leftPath + '\', [StringComparison]::OrdinalIgnoreCase)
    $rightContainsLeft = $leftPath.Equals($rightPath, [StringComparison]::OrdinalIgnoreCase) -or
        $leftPath.StartsWith($rightPath + '\', [StringComparison]::OrdinalIgnoreCase)
    return $leftContainsRight -or $rightContainsLeft
}

function Assert-NoPhysicalPathOverlap {
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right,
        [Parameter(Mandatory)][string] $Description
    )
    if (Test-CanonicalPhysicalOverlap -Left $Left -Right $Right) {
        throw "$Description physically overlap after final-handle resolution: '$($Left.CanonicalPath)' and '$($Right.CanonicalPath)'."
    }
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

function Get-ExplorerA4SModuleRecords {
    $explorerPid = Get-ShellExplorerPid
    $records = [Collections.Generic.List[object]]::new()
    $process = Get-Process -Id $explorerPid -ErrorAction Stop
    foreach ($module in @($process.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' } |
            Sort-Object FileName)) {
        $path = [IO.Path]::GetFullPath($module.FileName)
        $sha256 = if (Test-Path -LiteralPath $path -PathType Leaf) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
        } else { $null }
        $records.Add([ordered]@{ Path = $path; Sha256 = $sha256 })
    }
    return @($records)
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
        $sha256 = $null
        $pathError = $null
        try {
            $path = [IO.Path]::GetFullPath($process.Path)
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
            }
        }
        catch { $pathError = $_.Exception.Message }
        $started = $null
        try { $started = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
        $records.Add([ordered]@{
            Name = $process.ProcessName
            Id = $process.Id
            SessionId = $process.SessionId
            Path = $path
            Sha256 = $sha256
            StartTimeUtc = $started
            PathError = $pathError
        })
    }
    return @($records)
}

function Get-CleanupProcessRecords {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'A4SMenuCleanup*' -ErrorAction SilentlyContinue | Sort-Object Id)) {
        $path = $null
        $sha256 = $null
        $errorText = $null
        try {
            $path = [IO.Path]::GetFullPath($process.Path)
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
            }
        }
        catch { $errorText = $_.Exception.Message }
        $started = $null
        try { $started = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
        $records.Add([ordered]@{
            Id = $process.Id
            SessionId = $process.SessionId
            Path = $path
            Sha256 = $sha256
            StartTimeUtc = $started
            Error = $errorText
        })
    }
    return @($records)
}

function Get-CleanupStateOnce {
    $helperFile = [ordered]@{ Present = $false; Path = $cleanupHelperPath }
    if (Test-Path -LiteralPath $cleanupHelperPath) {
        try {
            $item = Get-Item -LiteralPath $cleanupHelperPath -Force
            $helperFile = [ordered]@{
                Present = $true
                Path = $cleanupHelperPath
                IsDirectory = $item.PSIsContainer
                IsReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                Length = if ($item.PSIsContainer) { $null } else { $item.Length }
                Sha256 = if ($item.PSIsContainer) { $null } else {
                    (Get-FileHash -Algorithm SHA256 -LiteralPath $cleanupHelperPath).Hash.ToUpperInvariant()
                }
                Error = $null
            }
        }
        catch {
            $helperFile = [ordered]@{ Present = $true; Path = $cleanupHelperPath; Error = $_.Exception.Message }
        }
    }
    return [ordered]@{
        HelperFile = $helperFile
        Processes = @(Get-CleanupProcessRecords)
    }
}

function Get-VersionsInventory {
    $result = [ordered]@{ Present = $false; Path = $versionsRoot; Entries = @(); Error = $null }
    if (-not (Test-Path -LiteralPath $versionsRoot)) { return $result }
    try {
        $root = Get-Item -LiteralPath $versionsRoot -Force
        $entries = [Collections.Generic.List[object]]::new()
        foreach ($entry in @(Get-ChildItem -LiteralPath $versionsRoot -Force | Sort-Object Name)) {
            $children = [Collections.Generic.List[object]]::new()
            if ($entry.PSIsContainer -and
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                foreach ($child in @(Get-ChildItem -LiteralPath $entry.FullName -Force | Sort-Object Name)) {
                    $hash = $null
                    if (-not $child.PSIsContainer -and
                        ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $child.FullName).Hash.ToUpperInvariant()
                    }
                    $children.Add([ordered]@{
                        Name = $child.Name
                        IsDirectory = $child.PSIsContainer
                        IsReparsePoint = ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                        Length = if ($child.PSIsContainer) { $null } else { $child.Length }
                        Sha256 = $hash
                    })
                }
            }
            $entries.Add([ordered]@{
                Name = $entry.Name
                IsDirectory = $entry.PSIsContainer
                IsReparsePoint = ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                Children = @($children)
            })
        }
        return [ordered]@{
            Present = $true
            Path = $versionsRoot
            IsDirectory = $root.PSIsContainer
            IsReparsePoint = ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            Entries = @($entries)
            Error = $null
        }
    }
    catch {
        $result.Present = $true
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Get-KnownRootFileInventory {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($name in @('DataCache.db', 'DataCache.tmp', 'DataCache.txt', 'StartupLog.txt')) {
        $path = Join-Path $installRoot $name
        if (-not (Test-Path -LiteralPath $path)) {
            $records.Add([ordered]@{ Name = $name; Present = $false })
            continue
        }
        $item = Get-Item -LiteralPath $path -Force
        $records.Add([ordered]@{
            Name = $name
            Present = $true
            IsDirectory = $item.PSIsContainer
            IsReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            Length = if ($item.PSIsContainer) { $null } else { $item.Length }
            Sha256 = if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $null } else {
                (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
            }
        })
    }
    return @($records)
}

function Get-LifecycleAggregateOnce {
    return [ordered]@{
        ExplorerPid = Get-ShellExplorerPid
        InstallerRegistration = Get-InstallerRegistrationSnapshot
        UserState = Get-UserStateProjection
        UserStateWithoutHostSafety = Get-UserStateProjection -ExcludeHostSafety
        UserStatePartitions = Get-UserStatePartitions
        HostSafety = Get-RegistryTreeSnapshot -SubKey ($stateSubKey + '\HostSafety')
        DataCache = Get-DataCacheRecord
        Versions = Get-VersionsInventory
        KnownRootFiles = @(Get-KnownRootFileInventory)
        A4SProcesses = @(Get-A4SProcessRecords)
        ExplorerA4SModules = @(Get-ExplorerA4SModuleRecords)
        Cleanup = Get-CleanupStateOnce
    }
}

function Get-StableLifecycleAggregate {
    param(
        [Parameter(Mandatory)][string] $Label,
        [ValidateRange(2, 10)][int] $RequiredSamples = 2,
        [ValidateRange(1, 10)][int] $TimeoutSeconds = 5
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastFingerprint = $null
    $stableSamples = 0
    do {
        $snapshot = Get-LifecycleAggregateOnce
        $fingerprint = Get-ObjectFingerprint $snapshot
        if ($fingerprint -ceq $lastFingerprint) { ++$stableSamples }
        else { $lastFingerprint = $fingerprint; $stableSamples = 1 }
        if ($stableSamples -ge $RequiredSamples) {
            return [ordered]@{
                Label = $Label
                Fingerprint = $fingerprint
                StableSamples = $stableSamples
                Snapshot = $snapshot
            }
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Label registration/cleanup aggregate did not stabilize inside the bounded interval."
}

function Register-OwnedAggregate {
    param(
        [Parameter(Mandatory)] $Aggregate,
        [Parameter(Mandatory)][ValidateSet('Clean', 'InstalledV1', 'InstalledV2',
            'UninstalledPending', 'UninstalledQuiescent', 'FinalInstalled')] [string] $Kind,
        [Parameter(Mandatory)][string] $Label,
        [AllowNull()] $Validation
    )
    $entry = [ordered]@{
        Label = $Label
        Kind = $Kind
        Fingerprint = [string]$Aggregate.Fingerprint
        Aggregate = $Aggregate
        Validation = $Validation
    }
    $script:ownedAggregateLedger.Add($entry)
    $script:lastOwnedAggregate = $entry
    return $entry
}

function Find-OwnedAggregate {
    param([Parameter(Mandatory)][string] $Fingerprint)
    return @($script:ownedAggregateLedger | Where-Object {
        $_.Fingerprint -ceq $Fingerprint
    }) | Select-Object -Last 1
}

function Assert-AggregateFingerprintImmediatelyBeforeMutation {
    param(
        [Parameter(Mandatory)][string] $ExpectedFingerprint,
        [Parameter(Mandatory)][string] $Label
    )
    $actual = Get-StableLifecycleAggregate -Label ($Label + '-pre-mutation-aggregate')
    if ($actual.Fingerprint -cne $ExpectedFingerprint) {
        throw "$Label detected unknown or concurrent state immediately before mutation."
    }
    return $actual
}

function Assert-LastOwnedAggregateImmediatelyBeforeSetup {
    param([Parameter(Mandatory)][string] $Label)
    if ($null -eq $script:lastOwnedAggregate) {
        throw "$Label has no previously validated harness-owned state."
    }
    $actual = Assert-AggregateFingerprintImmediatelyBeforeMutation `
        -ExpectedFingerprint $script:lastOwnedAggregate.Fingerprint -Label $Label
    return [ordered]@{
        ExpectedOwner = $script:lastOwnedAggregate.Label
        ExpectedKind = $script:lastOwnedAggregate.Kind
        ExpectedFingerprint = $script:lastOwnedAggregate.Fingerprint
        ActualFingerprint = $actual.Fingerprint
        Aggregate = $actual
    }
}

function Test-InstallerOwnedCleanSnapshot {
    param([Parameter(Mandatory)] $Snapshot)
    $registration = $Snapshot.InstallerRegistration
    if ($registration.ActiveSlot.Present -or $registration.PreviousSlot.Present -or
        $registration.InstallVersion.Present -or $registration.Servicing.Exists -or
        $registration.Uninstall.Exists -or $registration.Run.Present -or
        $registration.CleanupRunOnce.Present -or $registration.RecoveryRunOnce.Present) {
        return $false
    }
    if ($Snapshot.Versions.Present -or $Snapshot.Cleanup.HelperFile.Present -or
        @($Snapshot.Cleanup.Processes).Count -ne 0 -or @($Snapshot.A4SProcesses).Count -ne 0 -or
        @($Snapshot.ExplorerA4SModules).Count -ne 0) {
        return $false
    }
    foreach ($file in @($Snapshot.KnownRootFiles | Where-Object { $_.Name -cne 'DataCache.db' })) {
        if ($file.Present) { return $false }
    }
    return $true
}

function Test-ExactPendingCleanupSnapshot {
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)][string] $ExpectedSha256
    )
    $registration = $Snapshot.InstallerRegistration
    if ($registration.ActiveSlot.Present -or $registration.PreviousSlot.Present -or
        $registration.InstallVersion.Present -or $registration.Servicing.Exists -or
        $registration.Uninstall.Exists -or $registration.Run.Present -or
        $registration.RecoveryRunOnce.Present -or -not $registration.CleanupRunOnce.Present -or
        $registration.CleanupRunOnce.Kind -cne 'String' -or
        $registration.CleanupRunOnce.Data -cne $expectedCleanupRunOnce) {
        return $false
    }
    $helper = $Snapshot.Cleanup.HelperFile
    $processes = @($Snapshot.Cleanup.Processes)
    if (-not $helper.Present -or $helper.Error -or $helper.IsDirectory -or $helper.IsReparsePoint -or
        $helper.Sha256 -cne $ExpectedSha256 -or $processes.Count -ne 1) {
        return $false
    }
    $process = $processes[0]
    if ($process.Error -or $process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or
        -not ([string]$process.Path).Equals($cleanupHelperPath, [StringComparison]::OrdinalIgnoreCase) -or
        $process.Sha256 -cne $ExpectedSha256) {
        return $false
    }
    if (@($Snapshot.A4SProcesses | Where-Object { $_.Id -ne $process.Id }).Count -ne 0) {
        return $false
    }
    return $true
}

function Get-RecoveryDecision {
    param(
        [Parameter(Mandatory)][bool] $InstallerOwnedClean,
        [Parameter(Mandatory)][bool] $ExactPendingCleanup,
        [Parameter(Mandatory)][bool] $KnownOwnedRestorableClean,
        [Parameter(Mandatory)][bool] $KnownOwnedInstalled,
        [Parameter(Mandatory)][bool] $KnownOwnedUninstalled
    )
    if ($ExactPendingCleanup) { return 'WaitPendingNoUninstall' }
    if ($InstallerOwnedClean) {
        if ($KnownOwnedRestorableClean) { return 'RestoreCleanNoUninstall' }
        return 'RetainCleanUnknownNoMutation'
    }
    if ($KnownOwnedInstalled) { return 'UninstallKnownOwned' }
    if ($KnownOwnedUninstalled) { return 'ObserveUninstalledNoUninstall' }
    return 'RetainUnknownNoMutation'
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

function Read-VerifiedImmutableManifest {
    param(
        [Parameter(Mandatory)][string] $ExpectedSessionId,
        [Parameter(Mandatory)][string] $ExpectedUserStateSha256,
        [Parameter(Mandatory)][string] $ExpectedLifecycleMutexName
    )
    $path = Assert-RegularFile -Path $script:manifestPath -Description 'immutable pre-mutation manifest'
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
    if ($actualHash -cne $script:manifestSha256) {
        throw 'The immutable pre-mutation manifest hash changed; recovery mutation is forbidden.'
    }
    $sidecarPath = $path + '.sha256'
    Assert-RegularFile -Path $sidecarPath -Description 'immutable manifest SHA-256 sidecar' | Out-Null
    $expectedSidecar = $actualHash + ' *' + [IO.Path]::GetFileName($path) + "`r`n"
    $actualSidecar = [IO.File]::ReadAllText($sidecarPath, [Text.Encoding]::UTF8)
    if ($actualSidecar -cne $expectedSidecar) {
        throw 'The immutable manifest SHA-256 sidecar is not exact; recovery mutation is forbidden.'
    }
    $manifest = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$manifest.SchemaVersion -ne 2 -or [string]$manifest.SessionId -cne $ExpectedSessionId -or
        [int]$manifest.CurrentSessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or
        [string]$manifest.LifecycleMutexName -cne $ExpectedLifecycleMutexName -or
        [string]$manifest.OriginalUserStateSha256 -cne $ExpectedUserStateSha256 -or
        (Get-ObjectFingerprint $manifest.OriginalUserState) -cne $ExpectedUserStateSha256) {
        throw 'The immutable manifest identity does not match this lifecycle session.'
    }
    $manifestCache = $manifest.OriginalDataCache
    if ([string]$manifestCache.Path -cne $dataCachePath) {
        throw 'The immutable manifest names an unexpected DataCache path.'
    }
    if ([bool]$manifestCache.Present) {
        $expectedBackup = [IO.Path]::GetFullPath((Join-Path $script:sessionDirectory 'DataCache.db.original'))
        if (-not ([string]$manifestCache.BackupPath).Equals($expectedBackup,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The immutable manifest names an unexpected DataCache recovery backup.'
        }
        $backup = Assert-RegularFile -Path ([string]$manifestCache.BackupPath) `
            -Description 'immutable-manifest DataCache recovery backup'
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToUpperInvariant() -cne
                [string]$manifestCache.Sha256 -or
            (Get-Item -LiteralPath $backup -Force).Length -ne [int64]$manifestCache.Length) {
            throw 'The DataCache recovery backup no longer matches the immutable manifest.'
        }
    }
    return [ordered]@{ Path = $path; Sha256 = $actualHash; Manifest = $manifest }
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
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $SetupLaunch
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
    # This is deliberately the final operation before process creation. A
    # setup launch never crosses an unverified ownership gap in the harness.
    $preLaunchOwnership = if ($SetupLaunch) {
        Assert-LastOwnedAggregateImmediatelyBeforeSetup -Label $Label
    } else { $null }
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
        PreLaunchOwnership = $preLaunchOwnership
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

function Get-SettledHostStatusRecord {
    param(
        [AllowNull()] $ActiveSlot,
        [Parameter(Mandatory)][string] $Label
    )
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $status = Get-HostStatusRecord -ActiveSlot $ActiveSlot -Label $Label
        if ($status.State -in @('ready', 'stopped', 'failed-native-start-available',
                'safety-disabled-native-start-available')) {
            return $status
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Label host state did not settle inside the bounded interval."
}

function Assert-ExpectedHostState {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][string[]] $KnownMenuSha256,
        [switch] $AllowDeferredStopped,
        [switch] $RequireQuiescentStopped
    )
    $processes = @($Checkpoint.HostProcesses)
    $modules = @($Checkpoint.Aggregate.Snapshot.ExplorerA4SModules)
    if ($RequireQuiescentStopped) {
        if ($Checkpoint.HostStatus.State -cne 'stopped' -or $processes.Count -ne 0) {
            throw "$($Checkpoint.Label) is not in the required host-quiescent stopped state."
        }
        return
    }
    if ($Checkpoint.HostStatus.State -ceq 'ready') {
        if ($processes.Count -ne 1 -or $modules.Count -eq 0) {
            throw "$($Checkpoint.Label) ready host state does not have one exact host and a loaded menu module."
        }
        foreach ($module in $modules) {
            if (-not $module.Sha256 -or $KnownMenuSha256 -notcontains [string]$module.Sha256) {
                throw "$($Checkpoint.Label) ready state has an unknown Explorer DLL mapping."
            }
        }
        return
    }
    if ($AllowDeferredStopped -and $Checkpoint.HostStatus.State -ceq 'stopped' -and
        $processes.Count -eq 0 -and $modules.Count -ne 0) {
        foreach ($module in $modules) {
            if (-not $module.Sha256 -or $KnownMenuSha256 -notcontains [string]$module.Sha256) {
                throw "$($Checkpoint.Label) deferred stopped state has an unknown Explorer DLL mapping."
            }
        }
        return
    }
    throw "$($Checkpoint.Label) has unexpected host/process state '$($Checkpoint.HostStatus.State)' with $($processes.Count) resident host process(es)."
}

function Get-ProductCheckpoint {
    param([Parameter(Mandatory)][string] $Label)

    Assert-SafeInstallBoundary
    $aggregate = Get-StableLifecycleAggregate -Label ($Label + '-aggregate')
    $snapshot = $aggregate.Snapshot
    $installerRegistration = $snapshot.InstallerRegistration
    $activePath = if ($installerRegistration.ActiveSlot.Present) {
        if ($installerRegistration.ActiveSlot.Kind -cne 'String') { throw "$Label ActiveSlot is not REG_SZ." }
        [string]$installerRegistration.ActiveSlot.Data
    } else { '' }
    $previousPath = if ($installerRegistration.PreviousSlot.Present) {
        if ($installerRegistration.PreviousSlot.Kind -cne 'String') { throw "$Label PreviousSlot is not REG_SZ." }
        [string]$installerRegistration.PreviousSlot.Data
    } else { '' }
    $active = Get-SlotRecord -SlotPath $activePath -Role 'active'
    $previous = Get-SlotRecord -SlotPath $previousPath -Role 'previous'
    $checkpoint = [ordered]@{
        Label = $Label
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        ExplorerPid = $snapshot.ExplorerPid
        Aggregate = $aggregate
        ActiveSlotPath = $activePath
        PreviousSlotPath = $previousPath
        InstallVersion = if ($installerRegistration.InstallVersion.Present) {
            [string]$installerRegistration.InstallVersion.Data
        } else { '' }
        ActiveSlot = $active
        PreviousSlot = $previous
        InstallerRegistration = $installerRegistration
        RunStartup = $installerRegistration.Run
        CleanupRunOnce = $installerRegistration.CleanupRunOnce
        RecoveryRunOnce = $installerRegistration.RecoveryRunOnce
        Servicing = $installerRegistration.Servicing
        UninstallEntry = $installerRegistration.Uninstall
        DataCache = $snapshot.DataCache
        UserStateProjection = $snapshot.UserState
        UserStateWithoutHostSafety = $snapshot.UserStateWithoutHostSafety
        UserStatePartitions = $snapshot.UserStatePartitions
        HostSafety = $snapshot.HostSafety
        VersionsInventory = $snapshot.Versions
        KnownRootFiles = $snapshot.KnownRootFiles
        CleanupObservation = [ordered]@{
            Stable = $true
            Quiescent = @($snapshot.Cleanup.Processes).Count -eq 0
            Processes = @($snapshot.Cleanup.Processes)
            HelperFile = $snapshot.Cleanup.HelperFile
            Samples = $aggregate.StableSamples
        }
    }
    $checkpoint.HostStatus = Get-SettledHostStatusRecord -ActiveSlot $active -Label $Label
    $checkpoint.HostProcesses = @(Get-HostProcessRecords -ActiveSlot $active)
    $after = Get-StableLifecycleAggregate -Label ($Label + '-post-status-aggregate')
    if ($after.Fingerprint -cne $aggregate.Fingerprint) {
        throw "$Label registration/cleanup aggregate changed while the checkpoint was captured."
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

function Assert-ExactUninstallMetadata {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][string] $ExpectedVersion
    )
    $tree = $Checkpoint.UninstallEntry
    if (-not $tree.Exists -or @($tree.Nodes).Count -ne 1 -or
        [string]$tree.Nodes[0].RelativePath) {
        throw "$($Checkpoint.Label) uninstall key is absent or contains subkeys."
    }
    $setupPath = [string]$Checkpoint.ActiveSlot.Files.Setup.Path
    $estimated = [Math]::Min([uint64]::MaxValue,
        [uint64][Math]::Ceiling((
            [uint64]$Checkpoint.ActiveSlot.Files.Host.Length +
            [uint64]$Checkpoint.ActiveSlot.Files.Menu.Length +
            [uint64]$Checkpoint.ActiveSlot.Files.Setup.Length) / 1024.0))
    if ($estimated -gt [uint32]::MaxValue) { $estimated = [uint32]::MaxValue }
    $expected = [ordered]@{
        DisplayName = @('String', 'A4S Menu')
        DisplayVersion = @('String', $ExpectedVersion)
        Publisher = @('String', 'A4SMenu Project')
        InstallLocation = @('String', $installRoot)
        DisplayIcon = @('String', ('"' + $setupPath + '"'))
        UninstallString = @('String', ('"' + $setupPath + '" --uninstall'))
        QuietUninstallString = @('String', ('"' + $setupPath + '" --uninstall --silent'))
        ModifyPath = @('String', ('"' + $setupPath + '" --repair'))
        NoModify = @('DWord', '0')
        NoRepair = @('DWord', '0')
        EstimatedSize = @('DWord', ([string][uint32]$estimated))
    }
    $values = @($tree.Nodes[0].Values)
    if ($values.Count -ne $expected.Count) {
        throw "$($Checkpoint.Label) uninstall metadata value count is not exact."
    }
    foreach ($name in $expected.Keys) {
        $actual = @($values | Where-Object { $_.Name -ceq $name }) | Select-Object -First 1
        if ($null -eq $actual -or $actual.Kind -cne $expected[$name][0] -or
            [string]$actual.Data -cne [string]$expected[$name][1]) {
            throw "$($Checkpoint.Label) uninstall metadata '$name' has the wrong type or data."
        }
    }
}

function Assert-ExactVersionsInventory {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][string[]] $ExpectedSlotPaths
    )
    $inventory = $Checkpoint.VersionsInventory
    if (-not $inventory.Present -or $inventory.Error -or -not $inventory.IsDirectory -or
        $inventory.IsReparsePoint) {
        throw "$($Checkpoint.Label) versions inventory is absent or unsafe."
    }
    $expectedNames = @($ExpectedSlotPaths | ForEach-Object { [IO.Path]::GetFileName($_) } |
        Sort-Object -Unique)
    $entries = @($inventory.Entries)
    $actualNames = @($entries | ForEach-Object Name | Sort-Object -Unique)
    if ($entries.Count -ne $expectedNames.Count -or (Compare-Object $expectedNames $actualNames)) {
        throw "$($Checkpoint.Label) versions inventory contains a staging/orphan/unknown slot."
    }
    foreach ($entry in $entries) {
        if (-not $entry.IsDirectory -or $entry.IsReparsePoint -or
            $entry.Name.StartsWith('.stage-', [StringComparison]::OrdinalIgnoreCase) -or
            $entry.Name.Contains('.repair-')) {
            throw "$($Checkpoint.Label) versions inventory contains a staging, repair, file, or reparse entry."
        }
        $children = @($entry.Children)
        $childNames = @($children | ForEach-Object Name | Sort-Object)
        $expectedChildren = @('A4SMenu.dll', 'A4SMenuHost.exe', 'A4SMenuSetup.exe')
        if ($children.Count -ne 3 -or (Compare-Object $expectedChildren $childNames) -or
            @($children | Where-Object { $_.IsDirectory -or $_.IsReparsePoint -or -not $_.Sha256 }).Count) {
            throw "$($Checkpoint.Label) slot '$($entry.Name)' is not an exact three-file payload."
        }
    }
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
        if ($Checkpoint.CleanupRunOnce.Present -or $Checkpoint.CleanupObservation.HelperFile.Present -or
            @($Checkpoint.CleanupObservation.Processes).Count -ne 0) {
            throw "$($Checkpoint.Label) retained cleanup RunOnce/process/file outside explicit uninstall."
        }
        return
    }

    if ($Checkpoint.CleanupRunOnce.Present) {
        if ($Checkpoint.CleanupRunOnce.Kind -cne 'String' -or
            $Checkpoint.CleanupRunOnce.Data -cne $expectedCleanupRunOnce) {
            throw "$($Checkpoint.Label) has a non-canonical pending cleanup command."
        }
        if (-not (Test-ExactPendingCleanupSnapshot -Snapshot $Checkpoint.Aggregate.Snapshot `
                -ExpectedSha256 $script:expectedCleanupHash)) {
            throw "$($Checkpoint.Label) pending cleanup is not backed by one exact, current-session helper."
        }
    }
    elseif (-not $Checkpoint.CleanupObservation.Quiescent -or
        $Checkpoint.CleanupObservation.HelperFile.Present) {
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
    Assert-ExactUninstallMetadata -Checkpoint $Checkpoint -ExpectedVersion $versionText
    $expectedSlots = @($ExpectedActiveSlot)
    if ($ExpectedPreviousSlot) { $expectedSlots += $ExpectedPreviousSlot }
    Assert-ExactVersionsInventory -Checkpoint $Checkpoint -ExpectedSlotPaths $expectedSlots
    Assert-NoTransientServicingState -Checkpoint $Checkpoint
}

function Assert-UninstalledCheckpoint {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][string[]] $AllowedSlotPaths
    )
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
    if ($Checkpoint.CleanupRunOnce.Present) {
        $expectedNames = @($AllowedSlotPaths | ForEach-Object { [IO.Path]::GetFileName($_) } |
            Sort-Object -Unique)
        $inventory = $Checkpoint.VersionsInventory
        if (-not $inventory.Present -or $inventory.Error -or
            @($inventory.Entries).Count -ne $expectedNames.Count -or
            (Compare-Object $expectedNames @($inventory.Entries | ForEach-Object Name | Sort-Object -Unique))) {
            throw "$($Checkpoint.Label) pending cleanup retained an unexpected versions inventory."
        }
        foreach ($entry in @($inventory.Entries)) {
            if (-not $entry.IsDirectory -or $entry.IsReparsePoint -or
                $entry.Name.StartsWith('.stage-', [StringComparison]::OrdinalIgnoreCase) -or
                $entry.Name.Contains('.repair-')) {
                throw "$($Checkpoint.Label) pending cleanup contains staging/orphan/reparse content."
            }
            $payload = $script:knownPayloadBySlotName[[string]$entry.Name]
            if ($null -eq $payload) {
                throw "$($Checkpoint.Label) pending cleanup contains an unowned slot '$($entry.Name)'."
            }
            $expectedHashes = [ordered]@{
                'A4SMenu.dll' = $payload.Menu.Sha256
                'A4SMenuHost.exe' = $payload.Host.Sha256
                'A4SMenuSetup.exe' = $payload.Setup.Sha256
            }
            $children = @($entry.Children)
            if ($children.Count -ne 3) {
                throw "$($Checkpoint.Label) pending slot '$($entry.Name)' is not an exact three-file payload."
            }
            foreach ($child in $children) {
                if (-not $expectedHashes.Contains([string]$child.Name) -or
                    $child.IsDirectory -or $child.IsReparsePoint -or
                    $child.Sha256 -cne $expectedHashes[[string]$child.Name]) {
                    throw "$($Checkpoint.Label) pending slot '$($entry.Name)' has unknown payload content."
                }
            }
        }
    }
    else {
        if ($Checkpoint.VersionsInventory.Present) {
            throw "$($Checkpoint.Label) is quiescent but retained the installer-owned versions directory."
        }
        if (@($Checkpoint.KnownRootFiles | Where-Object Present).Count -ne 0) {
            throw "$($Checkpoint.Label) quiescent uninstall retained a known product cache/log file."
        }
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
        -TimeoutSeconds $OperationTimeoutSeconds -SetupLaunch
    $script:evidence.Steps.Add($record)
    Assert-ProcessSucceededWithoutExplorerRestart $record
    return $record
}

function Add-CheckpointToStep {
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)][string] $Label
    )
    $Step.Checkpoint = Get-ProductCheckpoint -Label $Label
    return $Step.Checkpoint
}

function Record-CacheRestoration {
    param(
        [Parameter(Mandatory)] $Original,
        [Parameter(Mandatory)][string] $Reason,
        [AllowNull()] $ExpectedAggregate
    )
    if ($null -ne $ExpectedAggregate) {
        Assert-AggregateFingerprintImmediatelyBeforeMutation `
            -ExpectedFingerprint $ExpectedAggregate.Fingerprint `
            -Label 'DataCache restoration' | Out-Null
    }
    $restored = Restore-OriginalDataCache -Original $Original
    $record = [ordered]@{
        Reason = $Reason
        RestoredUtc = [DateTime]::UtcNow.ToString('o')
        Result = $restored
    }
    $script:evidence.CacheRestorations.Add($record)
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
        VersionsInventory = $Checkpoint.VersionsInventory
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

function Assert-UserStateAndCacheInvariant {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)] $OriginalPartitions,
        [Parameter(Mandatory)] $OriginalDataCache,
        [switch] $AllowExplicitRepairHostSafetyReset
    )
    Assert-DataCacheMatches -Actual $Checkpoint.DataCache -Expected $OriginalDataCache `
        -Label $Checkpoint.Label
    foreach ($partitionName in @('Config', 'Menu', 'Legacy')) {
        $expected = Get-ObjectFingerprint (Get-NamedMemberValue $OriginalPartitions $partitionName)
        $actual = Get-ObjectFingerprint $Checkpoint.UserStatePartitions[$partitionName]
        if ($actual -cne $expected) {
            throw "$($Checkpoint.Label) changed the byte-exact $partitionName user-state partition."
        }
    }
    $expectedSafety = Get-ObjectFingerprint (Get-NamedMemberValue $OriginalPartitions 'HostSafety')
    $actualSafety = Get-ObjectFingerprint $Checkpoint.UserStatePartitions.HostSafety
    if (-not $AllowExplicitRepairHostSafetyReset) {
        if ($actualSafety -cne $expectedSafety) {
            throw "$($Checkpoint.Label) changed HostSafety outside explicit --repair."
        }
    }
    elseif ($Checkpoint.UserStatePartitions.HostSafety.Exists) {
        throw "$($Checkpoint.Label) explicit --repair did not narrowly clear only HostSafety."
    }
    foreach ($file in @($Checkpoint.KnownRootFiles | Where-Object { $_.Name -cne 'DataCache.db' })) {
        if ($file.Present) {
            throw "$($Checkpoint.Label) created or retained unexpected known cache/log '$($file.Name)'."
        }
    }
}

function Get-CleanStartRecord {
    Assert-SafeInstallBoundary
    $aggregate = Get-StableLifecycleAggregate -Label 'clean-start-preflight'
    if (-not (Test-InstallerOwnedCleanSnapshot -Snapshot $aggregate.Snapshot)) {
        throw 'Clean-start preflight requires no installer registration, versions, A4S process/module, cleanup helper, or non-DataCache known runtime file.'
    }
    return [ordered]@{
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        ExplorerPid = $aggregate.Snapshot.ExplorerPid
        InstallerRegistration = $aggregate.Snapshot.InstallerRegistration
        VersionsDirectoryPresent = $false
        CleanupHelperPath = $cleanupHelperPath
        CleanupHelperPresent = $false
        A4SProcesses = @()
        ExplorerA4SModules = @()
        Aggregate = $aggregate
    }
}

function Wait-ForInstalledCleanupCancellation {
    param([ValidateRange(1, 30)][int] $TimeoutSeconds = 8)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $aggregate = Get-StableLifecycleAggregate -Label 'installed-cleanup-cancellation' `
            -RequiredSamples 2 -TimeoutSeconds 2
        $registration = $aggregate.Snapshot.InstallerRegistration
        if (-not $registration.CleanupRunOnce.Present -and
            -not $aggregate.Snapshot.Cleanup.HelperFile.Present -and
            @($aggregate.Snapshot.Cleanup.Processes).Count -eq 0) {
            return $aggregate
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'A successful reinstall did not cancel and self-delete the stale cleanup helper inside the bounded interval.'
}

function Wait-ForPendingCleanupResolution {
    param(
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 8
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $aggregate = Get-StableLifecycleAggregate -Label 'recovery-pending-cleanup-observation' `
            -RequiredSamples 2 -TimeoutSeconds 2
        if (Test-InstallerOwnedCleanSnapshot -Snapshot $aggregate.Snapshot) {
            return [ordered]@{ State = 'Clean'; Aggregate = $aggregate }
        }
        if (-not (Test-ExactPendingCleanupSnapshot -Snapshot $aggregate.Snapshot `
                -ExpectedSha256 $ExpectedSha256)) {
            return [ordered]@{ State = 'Unknown'; Aggregate = $aggregate }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return [ordered]@{ State = 'Pending'; Aggregate = $aggregate }
}

function Restore-VerifiedCleanOriginalState {
    param(
        [Parameter(Mandatory)] $OriginalUserState,
        [Parameter(Mandatory)] $OriginalPartitions,
        [Parameter(Mandatory)] $OriginalDataCache,
        [Parameter(Mandatory)] $ExpectedAggregate
    )
    Assert-AggregateFingerprintImmediatelyBeforeMutation `
        -ExpectedFingerprint $ExpectedAggregate.Fingerprint `
        -Label 'clean-state restoration' | Out-Null
    Restore-CleanUserStateProjection -OriginalProjection $OriginalUserState | Out-Null
    Restore-OriginalDataCache -Original $OriginalDataCache | Out-Null
    $aggregate = Get-StableLifecycleAggregate -Label 'recovered-clean-original-state'
    if (-not (Test-InstallerOwnedCleanSnapshot -Snapshot $aggregate.Snapshot)) {
        throw 'Recovered state is not installer-owned clean.'
    }
    foreach ($name in @('Config', 'Menu', 'Legacy', 'HostSafety')) {
        if ((Get-ObjectFingerprint $aggregate.Snapshot.UserStatePartitions[$name]) -cne
            (Get-ObjectFingerprint (Get-NamedMemberValue $OriginalPartitions $name))) {
            throw "Recovered $name user-state partition does not match the immutable original."
        }
    }
    Assert-DataCacheMatches -Actual $aggregate.Snapshot.DataCache -Expected $OriginalDataCache `
        -Label 'Recovered clean state'
    return $aggregate
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
$setupExecutionStarted = $false
$completedSuccessfully = $false
$originalUserState = $null
$originalPartitions = $null
$originalDataCache = $null
$v1Identity = $null
$v2Identity = $null
$v1Payload = $null
$v2Payload = $null
$v1Slot = $null
$v2Slot = $null
$finalPreviousSlot = $null
$finalPreviousPayload = $null
$sessionId = $null
$lifecycleMutexName = $null

try {
    # This independent current-user lock is held continuously through preflight,
    # all process launches, evidence writes, and any recovery decision.
    $lifecycleMutexName = Acquire-LifecycleMutex

    $reviewedV1Hash = Normalize-Sha256 $ExpectedV1SetupSha256
    $reviewedV2Hash = Normalize-Sha256 $ExpectedV2SetupSha256
    if ($reviewedV1Hash -cne $frozenV1SetupSha256) {
        throw "ExpectedV1SetupSha256 must equal the frozen reviewed V1 identity $frozenV1SetupSha256."
    }
    $v1Identity = Get-BinaryIdentity -Path $V1SetupPath -Description 'frozen V1 setup fixture'
    $v2Identity = Get-BinaryIdentity -Path $V2SetupPath -Description 'current V2 setup fixture'
    $script:fixturePaths = @($v1Identity.Path, $v2Identity.Path)
    if ($v1Identity.Sha256 -cne $reviewedV1Hash -or $v2Identity.Sha256 -cne $reviewedV2Hash) {
        throw 'A setup fixture does not match its explicit reviewed SHA-256.'
    }
    foreach ($identity in @($v1Identity, $v2Identity)) {
        if ($identity.OriginalFilename -cne 'A4SMenuSetup.exe') {
            throw "Installer fixture has the wrong OriginalFilename metadata: $($identity.Path)"
        }
    }
    if ([Version]([string]$v1Identity.ProductVersion) -ne $expectedV1 -or
        [Version]([string]$v2Identity.ProductVersion) -ne $expectedV2) {
        throw 'Installer fixtures are not exact x64 1.0.0.0 and 1.1.0.0 products.'
    }
    if ($v1Identity.Sha256 -ceq $v2Identity.Sha256) { throw 'V1 and V2 fixtures have the same hash.' }
    $v1Payload = Get-SetupPayloadIdentity -SetupIdentity $v1Identity `
        -ExpectedHostSha256 $frozenV1HostSha256 -ExpectedMenuSha256 $frozenV1MenuSha256
    $v2Payload = Get-SetupPayloadIdentity -SetupIdentity $v2Identity
    $script:expectedCleanupHash = $v2Identity.Sha256

    $evidenceRoot = Assert-LocalAbsolutePath $EvidenceDirectory
    $installPhysical = Get-PhysicalPathRecord $installRoot
    $v1Physical = Get-PhysicalPathRecord $v1Identity.Path
    $v2Physical = Get-PhysicalPathRecord $v2Identity.Path
    $evidencePhysicalBeforeCreate = Get-PhysicalPathRecord $evidenceRoot
    $helperPhysical = Get-PhysicalPathRecord $cleanupHelperPath
    Assert-NoPhysicalPathOverlap $installPhysical $v1Physical 'Install root and V1 fixture'
    Assert-NoPhysicalPathOverlap $installPhysical $v2Physical 'Install root and V2 fixture'
    Assert-NoPhysicalPathOverlap $installPhysical $evidencePhysicalBeforeCreate 'Install root and evidence root'
    Assert-NoPhysicalPathOverlap $installPhysical $helperPhysical 'Install root and cleanup helper'
    Assert-NoPhysicalPathOverlap $evidencePhysicalBeforeCreate $helperPhysical 'Evidence root and cleanup helper'
    Assert-NoPhysicalPathOverlap $v1Physical $helperPhysical 'V1 fixture and cleanup helper'
    Assert-NoPhysicalPathOverlap $v2Physical $helperPhysical 'V2 fixture and cleanup helper'
    Assert-NoReparsePointInExistingChain $evidenceRoot
    if (-not (Test-Path -LiteralPath $evidenceRoot)) { [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null }
    if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) {
        throw "EvidenceDirectory is not a directory: $evidenceRoot"
    }
    Assert-NoReparsePointInExistingChain $evidenceRoot
    $evidencePhysical = Get-PhysicalPathRecord $evidenceRoot
    Assert-NoPhysicalPathOverlap $installPhysical $evidencePhysical 'Install root and created evidence root'

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $sessionId = [Guid]::NewGuid().ToString('N')
    $script:sessionDirectory = Join-Path $evidenceRoot "$stamp-$sessionId"
    if (Test-Path -LiteralPath $script:sessionDirectory) { throw 'Evidence session path collision.' }
    [IO.Directory]::CreateDirectory($script:sessionDirectory) | Out-Null
    Assert-NoReparsePointInExistingChain $script:sessionDirectory
    $script:evidencePath = Join-Path $script:sessionDirectory "A4SInstallerLifecycle-$stamp.json"
    $script:manifestPath = Join-Path $script:sessionDirectory 'pre-mutation-manifest.json'

    $cleanStart = Get-CleanStartRecord
    $originalUserState = $cleanStart.Aggregate.Snapshot.UserState
    $originalPartitions = $cleanStart.Aggregate.Snapshot.UserStatePartitions
    $originalUserFingerprint = Get-ObjectFingerprint $originalUserState
    $cacheBackupPath = Join-Path $script:sessionDirectory 'DataCache.db.original'
    $originalDataCache = Backup-OriginalDataCache -BackupPath $cacheBackupPath
    Assert-DataCacheMatches -Actual $cleanStart.Aggregate.Snapshot.DataCache `
        -Expected $originalDataCache -Label 'Pre-mutation backup'

    $preMutationManifest = [ordered]@{
        SchemaVersion = 2
        Purpose = 'Immutable recovery manifest captured before any installer execution'
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        SessionId = $sessionId
        CurrentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        LifecycleMutexName = $lifecycleMutexName
        PhysicalPaths = [ordered]@{
            InstallRoot = $installPhysical
            V1Fixture = $v1Physical
            V2Fixture = $v2Physical
            EvidenceRoot = $evidencePhysical
            CleanupHelper = $helperPhysical
        }
        InstallRoot = $installRoot
        VersionsRoot = $versionsRoot
        CleanupHelperPath = $cleanupHelperPath
        ExpectedCleanupRunOnce = $expectedCleanupRunOnce
        Inputs = [ordered]@{ V1 = $v1Payload; V2 = $v2Payload }
        CleanStart = $cleanStart
        OriginalUserState = $originalUserState
        OriginalUserStatePartitions = $originalPartitions
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
        LifecycleMutexName = $lifecycleMutexName
        EvidencePath = $script:evidencePath
        ImmutableManifest = $manifestRecord
        Warning = 'LIVE HKCU install mutation; no --restart-explorer command is permitted.'
        Inputs = [ordered]@{ V1 = $v1Payload; V2 = $v2Payload }
        OriginalUserStateSha256 = $originalUserFingerprint
        OriginalDataCache = $originalDataCache
        CleanStart = $cleanStart
        OwnedAggregates = $script:ownedAggregateLedger
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
    Register-OwnedAggregate -Aggregate $cleanStart.Aggregate -Kind Clean `
        -Label 'clean-start' -Validation $cleanStart | Out-Null
    Write-Evidence

    # Even verification is treated as external mutation risk. Recovery first
    # classifies a stable aggregate; clean state can never select uninstall.
    $setupExecutionStarted = $true
    $probeV1 = Invoke-RecordedSetupStep -Label 'preflight-v1-verify' -SetupIdentity $v1Identity `
        -Arguments @('--verify', '--silent')
    $afterV1Probe = Get-CleanStartRecord
    if ($afterV1Probe.Aggregate.Fingerprint -cne $cleanStart.Aggregate.Fingerprint) {
        throw 'The V1 verification probe changed the clean lifecycle aggregate.'
    }
    $probeV1.CleanStartAfter = $afterV1Probe
    Register-OwnedAggregate -Aggregate $afterV1Probe.Aggregate -Kind Clean `
        -Label 'after-v1-verify' -Validation $afterV1Probe | Out-Null
    Write-Evidence

    $probeV2 = Invoke-RecordedSetupStep -Label 'preflight-v2-verify' -SetupIdentity $v2Identity `
        -Arguments @('--verify', '--silent')
    $afterV2Probe = Get-CleanStartRecord
    if ($afterV2Probe.Aggregate.Fingerprint -cne $cleanStart.Aggregate.Fingerprint) {
        throw 'The V2 verification probe changed the clean lifecycle aggregate.'
    }
    $probeV2.CleanStartAfter = $afterV2Probe
    Register-OwnedAggregate -Aggregate $afterV2Probe.Aggregate -Kind Clean `
        -Label 'after-v2-verify' -Validation $afterV2Probe | Out-Null
    Write-Evidence

    $knownMenuHashes = @($v1Payload.Menu.Sha256, $v2Payload.Menu.Sha256)
    $installV1 = Invoke-RecordedSetupStep -Label 'install-v1-silent' -SetupIdentity $v1Identity `
        -Arguments @('--install', '--silent')
    $v1Checkpoint = Add-CheckpointToStep -Step $installV1 -Label 'installed-v1'
    $v1Slot = $v1Checkpoint.ActiveSlotPath
    $script:knownPayloadBySlotName[[IO.Path]::GetFileName($v1Slot)] = $v1Payload
    Assert-InstalledCheckpoint -Checkpoint $v1Checkpoint -ExpectedVersion $expectedV1 `
        -ExpectedPayload $v1Payload -ExpectedActiveSlot $v1Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null
    Assert-ExpectedHostState -Checkpoint $v1Checkpoint -KnownMenuSha256 $knownMenuHashes
    Assert-UserStateAndCacheInvariant -Checkpoint $v1Checkpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    Register-OwnedAggregate -Aggregate $v1Checkpoint.Aggregate -Kind InstalledV1 `
        -Label 'installed-v1' -Validation $v1Checkpoint | Out-Null
    Write-Evidence

    $upgradeV2 = Invoke-RecordedSetupStep -Label 'upgrade-v1-to-v2-silent' -SetupIdentity $v2Identity `
        -Arguments @('--update', '--silent')
    $v2Checkpoint = Add-CheckpointToStep -Step $upgradeV2 -Label 'upgraded-v2'
    $v2Slot = $v2Checkpoint.ActiveSlotPath
    $script:knownPayloadBySlotName[[IO.Path]::GetFileName($v2Slot)] = $v2Payload
    Assert-InstalledCheckpoint -Checkpoint $v2Checkpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $v1Slot -ExpectedPreviousPayload $v1Payload
    Assert-ExpectedHostState -Checkpoint $v2Checkpoint -KnownMenuSha256 $knownMenuHashes -AllowDeferredStopped
    Assert-UserStateAndCacheInvariant -Checkpoint $v2Checkpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    Register-OwnedAggregate -Aggregate $v2Checkpoint.Aggregate -Kind InstalledV2 `
        -Label 'upgraded-v2' -Validation $v2Checkpoint | Out-Null
    Write-Evidence

    $rollback = Invoke-RecordedSetupStep -Label 'rollback-v2-to-v1-silent' `
        -SetupIdentity $v2Checkpoint.ActiveSlot.Files.Setup -Arguments @('--rollback', '--silent')
    $rollbackCheckpoint = Add-CheckpointToStep -Step $rollback -Label 'rolled-back-v1'
    Assert-InstalledCheckpoint -Checkpoint $rollbackCheckpoint -ExpectedVersion $expectedV1 `
        -ExpectedPayload $v1Payload -ExpectedActiveSlot $v1Slot `
        -ExpectedPreviousSlot $v2Slot -ExpectedPreviousPayload $v2Payload
    Assert-ExpectedHostState -Checkpoint $rollbackCheckpoint -KnownMenuSha256 $knownMenuHashes -AllowDeferredStopped
    Assert-UserStateAndCacheInvariant -Checkpoint $rollbackCheckpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    Register-OwnedAggregate -Aggregate $rollbackCheckpoint.Aggregate -Kind InstalledV1 `
        -Label 'rolled-back-v1' -Validation $rollbackCheckpoint | Out-Null
    Write-Evidence

    $upgradeAgain = Invoke-RecordedSetupStep -Label 'upgrade-v1-to-v2-again-silent' `
        -SetupIdentity $v2Identity -Arguments @('--update', '--silent')
    $v2AgainCheckpoint = Add-CheckpointToStep -Step $upgradeAgain -Label 'upgraded-v2-again'
    Assert-InstalledCheckpoint -Checkpoint $v2AgainCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $v1Slot -ExpectedPreviousPayload $v1Payload
    Assert-ExpectedHostState -Checkpoint $v2AgainCheckpoint -KnownMenuSha256 $knownMenuHashes -AllowDeferredStopped
    Assert-UserStateAndCacheInvariant -Checkpoint $v2AgainCheckpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    Register-OwnedAggregate -Aggregate $v2AgainCheckpoint.Aggregate -Kind InstalledV2 `
        -Label 'upgraded-v2-again' -Validation $v2AgainCheckpoint | Out-Null
    Write-Evidence

    $beforeRepairFingerprint = Get-ObjectFingerprint (Get-InstallerCheckpointProjection $v2AgainCheckpoint)
    $repair = Invoke-RecordedSetupStep -Label 'repair-v2-same-version-silent' `
        -SetupIdentity $v2AgainCheckpoint.ActiveSlot.Files.Setup -Arguments @('--repair', '--silent')
    $repairCheckpoint = Add-CheckpointToStep -Step $repair -Label 'repaired-v2-same-version'
    Assert-InstalledCheckpoint -Checkpoint $repairCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $v1Slot -ExpectedPreviousPayload $v1Payload
    Assert-ExpectedHostState -Checkpoint $repairCheckpoint -KnownMenuSha256 $knownMenuHashes -AllowDeferredStopped
    Assert-UserStateAndCacheInvariant -Checkpoint $repairCheckpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache `
        -AllowExplicitRepairHostSafetyReset
    $afterRepairFingerprint = Get-ObjectFingerprint (Get-InstallerCheckpointProjection $repairCheckpoint)
    if ($afterRepairFingerprint -cne $beforeRepairFingerprint) {
        throw 'Same-version repair changed canonical installer registration, slot hashes, or inventory.'
    }
    $repair.RepairNoChangeSha256 = $afterRepairFingerprint
    Register-OwnedAggregate -Aggregate $repairCheckpoint.Aggregate -Kind InstalledV2 `
        -Label 'repaired-v2-same-version' -Validation $repairCheckpoint | Out-Null
    Write-Evidence

    $uninstall = Invoke-RecordedSetupStep -Label 'uninstall-v2-silent' `
        -SetupIdentity $repairCheckpoint.ActiveSlot.Files.Setup -Arguments @('--uninstall', '--silent')
    $uninstallCheckpoint = Add-CheckpointToStep -Step $uninstall -Label 'uninstalled-v2'
    Assert-UninstalledCheckpoint -Checkpoint $uninstallCheckpoint -AllowedSlotPaths @($v1Slot, $v2Slot)
    if ($uninstallCheckpoint.CleanupRunOnce.Present) {
        Assert-DataCacheMatches -Actual $uninstallCheckpoint.DataCache -Expected $originalDataCache `
            -Label 'Pending uninstall'
        foreach ($name in @('Config', 'Menu', 'Legacy')) {
            if ((Get-ObjectFingerprint $uninstallCheckpoint.UserStatePartitions[$name]) -cne
                (Get-ObjectFingerprint $originalPartitions[$name])) {
                throw "Pending uninstall changed $name before its Explorer blocker exited."
            }
        }
        $knownMappedSlots = @(
            [ordered]@{ Slot = $v1Slot; Payload = $v1Payload },
            [ordered]@{ Slot = $v2Slot; Payload = $v2Payload }
        )
        $mappedKnown = [Collections.Generic.List[object]]::new()
        foreach ($module in @($uninstallCheckpoint.Aggregate.Snapshot.ExplorerA4SModules)) {
            foreach ($known in $knownMappedSlots) {
                $expectedPath = [IO.Path]::GetFullPath(
                    (Join-Path $known.Slot 'A4SMenu.dll'))
                if ($module.Sha256 -ceq $known.Payload.Menu.Sha256 -and
                    ([IO.Path]::GetFullPath([string]$module.Path)).Equals($expectedPath,
                        [StringComparison]::OrdinalIgnoreCase)) {
                    $mappedKnown.Add($known)
                }
            }
        }
        if ($mappedKnown.Count -ne 1) {
            throw 'Pending uninstall cleanup is not explained by one exact mapped known menu DLL.'
        }
        if (-not ([IO.Path]::GetFullPath([string]$mappedKnown[0].Slot)).Equals(
                ([IO.Path]::GetFullPath($v2Slot)), [StringComparison]::OrdinalIgnoreCase)) {
            $finalPreviousSlot = $mappedKnown[0].Slot
            $finalPreviousPayload = $mappedKnown[0].Payload
        }
        $uninstallKind = 'UninstalledPending'
    }
    else { $uninstallKind = 'UninstalledQuiescent' }
    Register-OwnedAggregate -Aggregate $uninstallCheckpoint.Aggregate -Kind $uninstallKind `
        -Label 'uninstalled-v2' -Validation $uninstallCheckpoint | Out-Null
    Write-Evidence

    $finalInstall = Invoke-RecordedSetupStep -Label 'final-install-v2-silent' `
        -SetupIdentity $v2Identity -Arguments @('--install', '--silent')
    $finalInstall.CleanupCancellation = Wait-ForInstalledCleanupCancellation
    $finalInstallCheckpoint = Add-CheckpointToStep -Step $finalInstall -Label 'final-v2-before-restoration'
    Assert-InstalledCheckpoint -Checkpoint $finalInstallCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $finalPreviousSlot -ExpectedPreviousPayload $finalPreviousPayload
    Assert-ExpectedHostState -Checkpoint $finalInstallCheckpoint -KnownMenuSha256 $knownMenuHashes -AllowDeferredStopped
    Register-OwnedAggregate -Aggregate $finalInstallCheckpoint.Aggregate -Kind FinalInstalled `
        -Label 'final-v2-before-restoration' -Validation $finalInstallCheckpoint | Out-Null
    Write-Evidence

    $script:evidence.FinalHostQuiescence = Stop-FinalHostQuiescent -Checkpoint $finalInstallCheckpoint
    $quiescentCheckpoint = Get-ProductCheckpoint -Label 'final-v2-host-quiescent-before-restoration'
    Assert-InstalledCheckpoint -Checkpoint $quiescentCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $finalPreviousSlot -ExpectedPreviousPayload $finalPreviousPayload
    Assert-ExpectedHostState -Checkpoint $quiescentCheckpoint -KnownMenuSha256 $knownMenuHashes `
        -RequireQuiescentStopped
    Register-OwnedAggregate -Aggregate $quiescentCheckpoint.Aggregate -Kind FinalInstalled `
        -Label 'final-v2-host-quiescent' -Validation $quiescentCheckpoint | Out-Null
    Write-Evidence

    $finalInstallerRegistration = $quiescentCheckpoint.InstallerRegistration
    Assert-AggregateFingerprintImmediatelyBeforeMutation `
        -ExpectedFingerprint $quiescentCheckpoint.Aggregate.Fingerprint `
        -Label 'final user-state restoration' | Out-Null
    $script:evidence.UserStateRestoration = Restore-UserStateProjection `
        -OriginalProjection $originalUserState -FinalInstallerRegistration $finalInstallerRegistration
    $preCacheRestoration = Get-StableLifecycleAggregate -Label 'final-pre-cache-restoration'
    Record-CacheRestoration -Original $originalDataCache `
        -Reason 'after final V2 host became quiescent' `
        -ExpectedAggregate $preCacheRestoration | Out-Null
    $restoredCheckpoint = Get-ProductCheckpoint -Label 'final-v2-restored-and-quiescent'
    Assert-InstalledCheckpoint -Checkpoint $restoredCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $finalPreviousSlot -ExpectedPreviousPayload $finalPreviousPayload
    Assert-ExpectedHostState -Checkpoint $restoredCheckpoint -KnownMenuSha256 $knownMenuHashes `
        -RequireQuiescentStopped
    Assert-UserStateAndCacheInvariant -Checkpoint $restoredCheckpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    if ((Get-ObjectFingerprint $restoredCheckpoint.UserStateProjection) -cne $originalUserFingerprint) {
        throw 'Final user-owned registry fingerprint does not match the immutable manifest.'
    }
    $restoredInstallerFingerprint = Get-ObjectFingerprint (Get-InstallerCheckpointProjection $restoredCheckpoint)
    Register-OwnedAggregate -Aggregate $restoredCheckpoint.Aggregate -Kind FinalInstalled `
        -Label 'final-v2-restored-and-quiescent' -Validation $restoredCheckpoint | Out-Null
    Write-Evidence

    if ($finalQuiescenceVerificationMilliseconds -le $preloadDebounceMilliseconds) {
        throw 'Final verification interval must be longer than the product preload debounce.'
    }
    Start-Sleep -Milliseconds $finalQuiescenceVerificationMilliseconds
    $stableCheckpoint = Get-ProductCheckpoint -Label 'final-v2-after-quiescence-interval'
    Assert-InstalledCheckpoint -Checkpoint $stableCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $finalPreviousSlot -ExpectedPreviousPayload $finalPreviousPayload
    Assert-ExpectedHostState -Checkpoint $stableCheckpoint -KnownMenuSha256 $knownMenuHashes `
        -RequireQuiescentStopped
    Assert-UserStateAndCacheInvariant -Checkpoint $stableCheckpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    if ((Get-ObjectFingerprint (Get-InstallerCheckpointProjection $stableCheckpoint)) -cne
        $restoredInstallerFingerprint) {
        throw 'Final installer-owned registration changed during the quiescence interval.'
    }
    if ((Get-ShellExplorerPid) -ne $cleanStart.ExplorerPid) {
        throw 'Explorer PID changed somewhere in the lifecycle matrix.'
    }
    Register-OwnedAggregate -Aggregate $stableCheckpoint.Aggregate -Kind FinalInstalled `
        -Label 'final-v2-after-quiescence-interval' -Validation $stableCheckpoint | Out-Null
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
        try { Write-Evidence } catch {}
    }
}
finally {
    try {
        if (-not $completedSuccessfully -and $setupExecutionStarted -and $null -ne $script:evidence) {
            $recovery = [ordered]@{
                StartedUtc = [DateTime]::UtcNow.ToString('o')
                ManifestVerification = $null
                InitialAggregate = $null
                OwnedMatch = $null
                Decision = $null
                SetupUninstall = $null
                UninstalledCheckpoint = $null
                CleanupResolution = $null
                OriginalStateRestored = $false
                MutationPerformed = $false
                DurableBundleRetained = $true
                Errors = [Collections.Generic.List[string]]::new()
            }
            $script:evidence.Recovery = $recovery
            $canClassify = $true
            if ($null -ne $script:outstandingProcess) {
                try { $script:outstandingProcess.Refresh() } catch {}
                if (-not $script:outstandingProcess.HasExited) {
                    $canClassify = $false
                    $recovery.Errors.Add('A setup process is still running; recovery performed no mutation and retained the immutable bundle.')
                }
            }
            if ($canClassify) {
                try {
                    $recovery.ManifestVerification = Read-VerifiedImmutableManifest `
                        -ExpectedSessionId $sessionId -ExpectedUserStateSha256 $originalUserFingerprint `
                        -ExpectedLifecycleMutexName $lifecycleMutexName
                    $recoveryUserState = $recovery.ManifestVerification.Manifest.OriginalUserState
                    $recoveryPartitions =
                        $recovery.ManifestVerification.Manifest.OriginalUserStatePartitions
                    $recoveryDataCache = $recovery.ManifestVerification.Manifest.OriginalDataCache
                    $current = Get-StableLifecycleAggregate -Label 'failure-recovery-initial-aggregate'
                    $recovery.InitialAggregate = $current
                    $owned = Find-OwnedAggregate -Fingerprint $current.Fingerprint
                    $recovery.OwnedMatch = $owned
                    $installerClean = Test-InstallerOwnedCleanSnapshot -Snapshot $current.Snapshot
                    $exactPending = Test-ExactPendingCleanupSnapshot -Snapshot $current.Snapshot `
                        -ExpectedSha256 $script:expectedCleanupHash
                    $knownInstalled = $null -ne $owned -and $owned.Kind -in @('InstalledV1', 'InstalledV2', 'FinalInstalled') -and
                        $null -ne $owned.Validation
                    $knownUninstalled = $null -ne $owned -and $owned.Kind -in @('UninstalledPending', 'UninstalledQuiescent')
                    $knownRestorableClean = $null -ne $owned -and
                        $owned.Kind -in @('Clean', 'UninstalledQuiescent')
                    $recovery.Decision = Get-RecoveryDecision -InstallerOwnedClean $installerClean `
                        -ExactPendingCleanup $exactPending `
                        -KnownOwnedRestorableClean $knownRestorableClean `
                        -KnownOwnedInstalled $knownInstalled `
                        -KnownOwnedUninstalled $knownUninstalled
                }
                catch {
                    $canClassify = $false
                    $recovery.Errors.Add("Manifest/aggregate classification: $($_.Exception.Message)")
                }
            }
            if ($canClassify) {
                switch ($recovery.Decision) {
                    'RestoreCleanNoUninstall' {
                        try {
                            Restore-VerifiedCleanOriginalState -OriginalUserState $recoveryUserState `
                                -OriginalPartitions $recoveryPartitions -OriginalDataCache $recoveryDataCache `
                                -ExpectedAggregate $current | Out-Null
                            $recovery.OriginalStateRestored = $true
                            $recovery.MutationPerformed = $true
                        }
                        catch { $recovery.Errors.Add("Clean-state restoration: $($_.Exception.Message)") }
                    }
                    'WaitPendingNoUninstall' {
                        try {
                            $resolution = Wait-ForPendingCleanupResolution `
                                -ExpectedSha256 $script:expectedCleanupHash
                            $recovery.CleanupResolution = $resolution
                            if ($resolution.State -ceq 'Clean') {
                                Restore-VerifiedCleanOriginalState -OriginalUserState $recoveryUserState `
                                    -OriginalPartitions $recoveryPartitions -OriginalDataCache $recoveryDataCache `
                                    -ExpectedAggregate $resolution.Aggregate | Out-Null
                                $recovery.OriginalStateRestored = $true
                                $recovery.MutationPerformed = $true
                            }
                            elseif ($resolution.State -ceq 'Pending') {
                                $recovery.Errors.Add('Exact cleanup remains blocked; recovery retained the immutable bundle and did not race it.')
                            }
                            else {
                                $recovery.Errors.Add('Pending cleanup changed to unknown/concurrent state; recovery performed no mutation.')
                            }
                        }
                        catch { $recovery.Errors.Add("Pending-cleanup observation: $($_.Exception.Message)") }
                    }
                    'UninstallKnownOwned' {
                        try {
                            $script:lastOwnedAggregate = $owned
                            $recovery.SetupUninstall = Invoke-CapturedProcess `
                                -Label 'failure-recovery-uninstall-v2' -FilePath $v2Identity.Path `
                                -Arguments @('--uninstall', '--silent') -ExpectedSha256 $v2Identity.Sha256 `
                                -TimeoutSeconds $OperationTimeoutSeconds -SetupLaunch
                            Assert-ProcessSucceededWithoutExplorerRestart $recovery.SetupUninstall
                            $recovery.MutationPerformed = $true
                            $recovery.UninstalledCheckpoint = Get-ProductCheckpoint `
                                -Label 'failure-recovery-uninstalled'
                            $allowedSlots = @($v1Slot, $v2Slot) | Where-Object { $_ }
                            Assert-UninstalledCheckpoint -Checkpoint $recovery.UninstalledCheckpoint `
                                -AllowedSlotPaths $allowedSlots
                            $canRestoreOriginalState = $true
                            $restoreAggregate = $recovery.UninstalledCheckpoint.Aggregate
                            if ($recovery.UninstalledCheckpoint.CleanupRunOnce.Present) {
                                $resolution = Wait-ForPendingCleanupResolution `
                                    -ExpectedSha256 $script:expectedCleanupHash
                                $recovery.CleanupResolution = $resolution
                                if ($resolution.State -cne 'Clean') {
                                    $recovery.Errors.Add('Recovery uninstall cleanup remains pending/unknown; the bundle was retained and original state was not raced.')
                                    $canRestoreOriginalState = $false
                                }
                                else { $restoreAggregate = $resolution.Aggregate }
                            }
                            if ($canRestoreOriginalState) {
                                Restore-VerifiedCleanOriginalState -OriginalUserState $recoveryUserState `
                                    -OriginalPartitions $recoveryPartitions -OriginalDataCache $recoveryDataCache `
                                    -ExpectedAggregate $restoreAggregate | Out-Null
                                $recovery.OriginalStateRestored = $true
                            }
                        }
                        catch { $recovery.Errors.Add("Owned-state recovery uninstall: $($_.Exception.Message)") }
                    }
                    'ObserveUninstalledNoUninstall' {
                        $recovery.Errors.Add('Previously owned uninstalled state is no longer exact pending/clean; recovery performed no mutation.')
                    }
                    default {
                        $recovery.Errors.Add('Unknown or concurrent lifecycle state; recovery performed no mutation and retained the immutable bundle.')
                    }
                }
            }
            $recovery.CompletedUtc = [DateTime]::UtcNow.ToString('o')
            try { Write-Evidence } catch {}
        }
        # Recovery files are retained on every path. They are the only authority
        # when cleanup remains blocked or any aggregate becomes unknown.
        try { Write-Evidence } catch {}
    }
    finally {
        Release-LifecycleMutex
    }
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
