<#
.SYNOPSIS
Runs the destructive, live per-user installer lifecycle matrix and writes JSON evidence.

.DESCRIPTION
This tool requires a clean installer-owned starting state, verifies frozen 1.0
read-only, exercises current 1.1 install/repair/uninstall, and intentionally
leaves 1.1 installed but quiescent. Frozen-V1 mutation and V1-to-V2
upgrade/rollback are deferred to a disposable profile because V1 predates the
cooperative sequence/token protocol. It never passes --restart-explorer. Every pre-existing user-owned
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

    [string] $EvidenceDirectory,

    [ValidateRange(30, 600)]
    [int] $OperationTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('EvidenceDirectory')) {
    $EvidenceDirectory = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\build\evidence\installer-lifecycle'))
}
if (-not $AllowInstallMutation) {
    throw 'This is a LIVE per-user installer test. Re-run with -AllowInstallMutation only after reviewing the script and closing unrelated setup processes.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run the live installer lifecycle test from 64-bit PowerShell.'
}

$stateSubKey = 'Software\A4SMenu'
$servicingSubKey = 'Software\A4SMenu\Servicing'
$lifecycleSubKey = 'Software\A4SMenuLifecycle'
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
$expectedCleanupRunOncePrefix = '"' + $cleanupHelperPath +
    '" --cleanup --silent --cleanup-identity '
$expectedCleanupRunOnce = $expectedCleanupRunOncePrefix +
    '<20-digit-sequence>:<64-digit-token>'
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
$script:productLifecycleMutexName = $null
$script:productSetupMutexName = $null
$script:pendingProductLocks = $null
$script:pendingSetupOwnership = $null
$script:lastOwnedAggregate = $null
$script:ownedAggregateLedger = [Collections.Generic.List[object]]::new()
$script:knownPayloadBySlotName = [ordered]@{}

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.Trim().ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{64}$') { throw "Invalid SHA-256 value: $Value" }
    return $normalized
}

function Get-CurrentUserSidHashSuffix {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $sid -or $sid.BinaryLength -le 0) {
        throw 'The current-user SID could not be resolved for global servicing coordination.'
    }
    $bytes = [byte[]]::new($sid.BinaryLength)
    $sid.GetBinaryForm($bytes, 0)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').Substring(0, 32)
    }
    finally { $algorithm.Dispose() }
}

function Get-LifecycleMutexNames {
    $suffix = Get-CurrentUserSidHashSuffix
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not $sid -or $sid -notmatch '^S-\d(-\d+)+$') {
        throw 'The raw current-user SID is invalid for product lifecycle coordination.'
    }
    return [ordered]@{
        Harness = "Global\A4SMenu.LifecycleQualification.v1.$suffix"
        ProductLifecycle = "Global\A4SMenu.Lifecycle.v1.$sid"
        ProductSetup = "Global\A4SMenu.Setup.v1.$suffix"
    }
}

function Acquire-LifecycleMutex {
    if ($script:lifecycleMutexHeld) { throw 'The lifecycle mutex is already held by this harness.' }
    $names = Get-LifecycleMutexNames
    $name = $names.Harness
    try {
        # Global scope makes this lease visible to service/session-0 and every
        # interactive session. An existing object whose ACL denies this user is
        # an unknown coordinator, so construction/access failure is fatal.
        $script:lifecycleMutex = [Threading.Mutex]::new($false, $name)
        try { $acquired = $script:lifecycleMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'Another A4S installer lifecycle harness owns the current-user qualification lock.'
        }
        $script:lifecycleMutexHeld = $true
        return $name
    }
    catch {
        if ($null -ne $script:lifecycleMutex) { $script:lifecycleMutex.Dispose() }
        $script:lifecycleMutex = $null
        throw "Could not acquire the fail-closed global A4S lifecycle lease '$name': $($_.Exception.Message)"
    }
}

function Acquire-ProductMutationLocks {
    if ($null -ne $script:pendingProductLocks) {
        throw 'A product mutation-lock lease is already pending acceptance.'
    }
    $names = Get-LifecycleMutexNames
    $script:productLifecycleMutexName = $names.ProductLifecycle
    $script:productSetupMutexName = $names.ProductSetup
    $lifecycle = $null
    $setup = $null
    $lifecycleHeld = $false
    $setupHeld = $false
    try {
        # Fixed order shared with native Setup: Lifecycle, then Setup.
        $lifecycle = [Threading.Mutex]::new($false, $script:productLifecycleMutexName)
        try { $lifecycleHeld = $lifecycle.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $lifecycleHeld = $true }
        if (-not $lifecycleHeld) {
            throw 'Another A4S mutation owns the Global current-user lifecycle mutex.'
        }
        $setup = [Threading.Mutex]::new($false, $script:productSetupMutexName)
        try { $setupHeld = $setup.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $setupHeld = $true }
        if (-not $setupHeld) {
            throw 'Another A4S setup operation owns the Global current-user Setup mutex.'
        }
        return [pscustomobject]@{
            Lifecycle = $lifecycle
            Setup = $setup
            LifecycleHeld = $true
            SetupHeld = $true
            Names = $names
        }
    }
    catch {
        if ($setupHeld -and $null -ne $setup) { $setup.ReleaseMutex() }
        if ($null -ne $setup) { $setup.Dispose() }
        if ($lifecycleHeld -and $null -ne $lifecycle) { $lifecycle.ReleaseMutex() }
        if ($null -ne $lifecycle) { $lifecycle.Dispose() }
        throw "Native A4S product coordination is unavailable or access denied: $($_.Exception.Message)"
    }
}

function Release-ProductMutationLocks {
    param([AllowNull()] $Lease)
    if ($null -eq $Lease) { return }
    if ($Lease.SetupHeld -and $null -ne $Lease.Setup) {
        $Lease.Setup.ReleaseMutex()
        $Lease.SetupHeld = $false
    }
    if ($null -ne $Lease.Setup) { $Lease.Setup.Dispose(); $Lease.Setup = $null }
    if ($Lease.LifecycleHeld -and $null -ne $Lease.Lifecycle) {
        $Lease.Lifecycle.ReleaseMutex()
        $Lease.LifecycleHeld = $false
    }
    if ($null -ne $Lease.Lifecycle) { $Lease.Lifecycle.Dispose(); $Lease.Lifecycle = $null }
}

function Assert-ProductSetupCoordinationAvailable {
    $lease = Acquire-ProductMutationLocks
    try {
        return [ordered]@{
            ProductLifecycle = $lease.Names.ProductLifecycle
            ProductSetup = $lease.Names.ProductSetup
            Available = $true
        }
    }
    finally { Release-ProductMutationLocks $lease }
}

function Release-PendingProductMutationLocks {
    if ($null -ne $script:pendingProductLocks) {
        Release-ProductMutationLocks $script:pendingProductLocks
        $script:pendingProductLocks = $null
    }
    $script:pendingSetupOwnership = $null
}

function Suspend-PendingProductMutationLocks {
    if ($null -eq $script:pendingProductLocks -or $null -eq $script:pendingSetupOwnership) {
        throw 'No accepted Setup operation is waiting for a cooperative continuation.'
    }
    $proof = $script:pendingSetupOwnership
    $lease = $script:pendingProductLocks
    $script:pendingProductLocks = $null
    Release-ProductMutationLocks $lease
    return $proof
}

function Resume-PendingProductMutationLocks {
    param([Parameter(Mandatory)] $Proof)
    $lease = Acquire-ProductMutationLocks
    try {
        $aggregate = Get-StableLifecycleAggregate -Label ($Proof.Label + '-continuation-locked-post')
        Assert-ExactQualificationOperation -Aggregate $aggregate `
            -ExpectedSequence ([uint64]$Proof.ExpectedSequence) `
            -ExpectedToken ([string]$Proof.Token) `
            -Label ($Proof.Label + ' continuation') | Out-Null
        $script:pendingProductLocks = $lease
        $script:pendingSetupOwnership = $Proof
        $lease = $null
        return $aggregate
    }
    finally {
        if ($null -ne $lease) { Release-ProductMutationLocks $lease }
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
        ([Microsoft.Win32.RegistryValueKind]::QWord) {
            # RegistryKey exposes REG_QWORD through signed Int64 even though the
            # registry stores an unsigned 64-bit bit pattern.  Canonicalize the
            # complete bit range as unsigned decimal so lifecycle sequences at
            # or above 2^63 remain parseable and round-trip byte-exactly.
            $bits = [BitConverter]::GetBytes([long]$value)
            [BitConverter]::ToUInt64($bits, 0).ToString(
                [Globalization.CultureInfo]::InvariantCulture); break
        }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Nodes
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
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Microsoft.Win32.RegistryKey] $RegistryRoot = [Microsoft.Win32.Registry]::CurrentUser
    )

    $root = $RegistryRoot.OpenSubKey($SubKey, $false)
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
        ServicingSequence = Get-RegistryValueSnapshot -SubKey $lifecycleSubKey -Name 'ServicingSequence'
        LastOperation = Get-RegistryValueSnapshot -SubKey $lifecycleSubKey -Name 'LastOperation'
        LifecycleMetadata = Get-RegistryTreeSnapshot -SubKey $lifecycleSubKey
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
        Write-Output -NoEnumerate $Value[$Name]
        return
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Required member '$Name' is absent." }
    Write-Output -NoEnumerate $property.Value
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
        ([Microsoft.Win32.RegistryValueKind]::MultiString) {
            Write-Output -NoEnumerate ([string[]]@($Value.Data)); return
        }
        ([Microsoft.Win32.RegistryValueKind]::Binary) {
            Write-Output -NoEnumerate ([Convert]::FromBase64String([string]$Value.Data)); return
        }
        ([Microsoft.Win32.RegistryValueKind]::None) {
            Write-Output -NoEnumerate ([Convert]::FromBase64String([string]$Value.Data)); return
        }
        ([Microsoft.Win32.RegistryValueKind]::DWord) { return [int]::Parse([string]$Value.Data, [Globalization.CultureInfo]::InvariantCulture) }
        ([Microsoft.Win32.RegistryValueKind]::QWord) {
            [uint64]$unsigned = 0
            if (-not [uint64]::TryParse([string]$Value.Data,
                    [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$unsigned)) {
                throw "Encoded registry QWord '$($Value.Name)' is outside the UInt64 range."
            }
            return [BitConverter]::ToInt64([BitConverter]::GetBytes($unsigned), 0)
        }
        default { throw "Unsupported registry value kind in recovery snapshot: $($Value.Kind)" }
    }
}

function Get-ObjectFieldNames {
    param([Parameter(Mandatory)] $Value)

    if ($Value -is [Collections.IDictionary]) {
        return @($Value.Keys | ForEach-Object { [string]$_ })
    }
    return @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-ExactObjectFields {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string[]] $Expected,
        [Parameter(Mandatory)][string] $Description
    )

    $actual = @(Get-ObjectFieldNames $Value | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or
        (Compare-Object -ReferenceObject $wanted -DifferenceObject $actual -CaseSensitive)) {
        throw "$Description does not have the exact recovery schema."
    }
}

function Assert-ValidRegistryTreeSnapshot {
    param(
        [Parameter(Mandatory)][string] $ExpectedSubKey,
        [Parameter(Mandatory)] $Snapshot
    )

    Assert-ExactObjectFields -Value $Snapshot -Expected @('SubKey', 'Exists', 'Nodes') `
        -Description 'Registry tree snapshot'
    if ([string](Get-NamedMemberValue $Snapshot 'SubKey') -cne $ExpectedSubKey) {
        throw "Recovery snapshot path mismatch: expected HKCU\$ExpectedSubKey."
    }
    $exists = Get-NamedMemberValue $Snapshot 'Exists'
    if ($exists -isnot [bool]) {
        throw 'Registry tree snapshot Exists must be a Boolean.'
    }
    $nodesValue = Get-NamedMemberValue $Snapshot 'Nodes'
    if ($null -eq $nodesValue -or $nodesValue -is [string] -or
        $nodesValue -isnot [Collections.IEnumerable]) {
        throw 'Registry tree snapshot Nodes must be an array.'
    }
    $nodes = @($nodesValue)
    if (-not $exists) {
        if ($nodes.Count -ne 0) {
            throw 'A non-existent registry tree snapshot cannot contain nodes.'
        }
        return $Snapshot
    }

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $validatedNodes = [Collections.Generic.List[object]]::new()
    foreach ($node in $nodes) {
        Assert-ExactObjectFields -Value $node -Expected @('RelativePath', 'Values') `
            -Description 'Registry tree node'
        $relativeValue = Get-NamedMemberValue $node 'RelativePath'
        if ($relativeValue -isnot [string]) {
            throw 'Registry node RelativePath must be a string.'
        }
        $relative = [string]$relativeValue
        if ($relative.Contains([char]0) -or [IO.Path]::IsPathRooted($relative) -or
            $relative.StartsWith('\') -or $relative.EndsWith('\') -or
            $relative.Contains('\\') -or
            @($relative.Split('\') | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0) {
            throw "Unsafe relative registry path in recovery snapshot: $relative"
        }
        if (-not $paths.Add($relative)) {
            throw "Duplicate registry node path in recovery snapshot: $relative"
        }
        $valuesValue = Get-NamedMemberValue $node 'Values'
        if ($null -eq $valuesValue -or $valuesValue -is [string] -or
            $valuesValue -isnot [Collections.IEnumerable]) {
            throw "Registry node '$relative' Values must be an array."
        }
        $valueNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($value in @($valuesValue)) {
            Assert-ExactObjectFields -Value $value -Expected @('Name', 'Kind', 'Data') `
                -Description "Registry value in '$relative'"
            $nameValue = Get-NamedMemberValue $value 'Name'
            $kindValue = Get-NamedMemberValue $value 'Kind'
            if ($nameValue -isnot [string] -or ([string]$nameValue).Contains([char]0)) {
                throw "Registry value name in '$relative' is invalid."
            }
            if (-not $valueNames.Add([string]$nameValue)) {
                throw "Duplicate registry value name '$nameValue' in '$relative'."
            }
            if ($kindValue -isnot [string]) {
                throw "Registry value kind for '$nameValue' is invalid."
            }
            $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                [Microsoft.Win32.RegistryValueKind], [string]$kindValue, $false)
            $data = Get-NamedMemberValue $value 'Data'
            switch ($kind) {
                ([Microsoft.Win32.RegistryValueKind]::String) {
                    if ($data -isnot [string]) { throw "REG_SZ '$nameValue' data must be a string." }
                }
                ([Microsoft.Win32.RegistryValueKind]::ExpandString) {
                    if ($data -isnot [string]) { throw "REG_EXPAND_SZ '$nameValue' data must be a string." }
                }
                ([Microsoft.Win32.RegistryValueKind]::MultiString) {
                    if ($null -eq $data -or $data -is [string] -or
                        $data -isnot [Collections.IEnumerable] -or
                        @($data | Where-Object { $_ -isnot [string] }).Count -ne 0) {
                        throw "REG_MULTI_SZ '$nameValue' data must be a string array."
                    }
                }
                default {
                    if ($data -isnot [string]) {
                        throw "Encoded registry data for '$nameValue' must be a string."
                    }
                }
            }
            # Decode every value before any registry mutation. This validates
            # base64, numeric ranges, enum values, and supported native kinds.
            ConvertFrom-EncodedRegistryData $value | Out-Null
        }
        $validatedNodes.Add($node)
    }
    if (-not $paths.Contains('')) {
        throw 'An existing registry tree snapshot must contain exactly one root node.'
    }
    foreach ($node in $validatedNodes) {
        $relative = [string](Get-NamedMemberValue $node 'RelativePath')
        if (-not $relative) { continue }
        $separator = $relative.LastIndexOf('\')
        $parent = if ($separator -lt 0) { '' } else { $relative.Substring(0, $separator) }
        if (-not $paths.Contains($parent)) {
            throw "Registry node '$relative' has no parent node in the snapshot."
        }
    }
    return $Snapshot
}

function Test-RegistryTreeSnapshotsEqual {
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right
    )
    return (Get-ObjectFingerprint $Left) -ceq (Get-ObjectFingerprint $Right)
}

function Invoke-RegistryMutationCheckpoint {
    param(
        [AllowNull()][scriptblock] $Hook,
        [Parameter(Mandatory)][ref] $Counter,
        [Parameter(Mandatory)][string] $Name
    )
    if ($null -eq $Hook) { return }
    $Counter.Value = [int]$Counter.Value + 1
    & $Hook ([int]$Counter.Value) $Name
}

function Apply-ValidatedRegistryTreeSnapshot {
    param(
        [Parameter(Mandatory)][string] $ExpectedSubKey,
        [Parameter(Mandatory)] $Snapshot,
        [Microsoft.Win32.RegistryKey] $RegistryRoot = [Microsoft.Win32.Registry]::CurrentUser,
        [AllowNull()][scriptblock] $MutationHook
    )

    $mutationStep = 0
    Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
        -Name 'BeforeDeleteTree'
    $RegistryRoot.DeleteSubKeyTree($ExpectedSubKey, $false)
    Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
        -Name 'AfterDeleteTree'
    if (-not (Get-NamedMemberValue $Snapshot 'Exists')) { return }
    $snapshotNodes = Get-NamedMemberValue $Snapshot 'Nodes'
    $orderedNodes = @($snapshotNodes | Sort-Object `
        @{ Expression = { if ([string]$_.RelativePath) { ([string]$_.RelativePath).Split('\').Count } else { 0 } } }, `
        @{ Expression = { [string]$_.RelativePath } })
    foreach ($node in $orderedNodes) {
        $relative = [string](Get-NamedMemberValue $node 'RelativePath')
        $subKey = if ($relative) { "$ExpectedSubKey\$relative" } else { $ExpectedSubKey }
        $key = $null
        try {
            Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
                -Name "BeforeCreateKey:$relative"
            $key = $RegistryRoot.CreateSubKey($subKey, $true)
            if ($null -eq $key) { throw "Could not restore HKCU\$subKey." }
            Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
                -Name "AfterCreateKey:$relative"
            $nodeValues = Get-NamedMemberValue $node 'Values'
            foreach ($value in $nodeValues) {
                $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                    [Microsoft.Win32.RegistryValueKind],
                    [string](Get-NamedMemberValue $value 'Kind'), $false)
                $valueName = [string](Get-NamedMemberValue $value 'Name')
                Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
                    -Name "BeforeSetValue:$relative/$valueName"
                $key.SetValue($valueName,
                    (ConvertFrom-EncodedRegistryData $value), $kind)
                Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
                    -Name "AfterSetValue:$relative/$valueName"
            }
            Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
                -Name "BeforeFlush:$relative"
            $key.Flush()
            Invoke-RegistryMutationCheckpoint -Hook $MutationHook -Counter ([ref]$mutationStep) `
                -Name "AfterFlush:$relative"
        }
        finally {
            if ($null -ne $key) { $key.Dispose() }
        }
    }
}

function Restore-RegistryTreeSnapshot {
    param(
        [Parameter(Mandatory)][string] $ExpectedSubKey,
        [Parameter(Mandatory)] $Snapshot,
        [Microsoft.Win32.RegistryKey] $RegistryRoot = [Microsoft.Win32.Registry]::CurrentUser,
        [AllowNull()][scriptblock] $MutationHook
    )

    # Target validation and an exact immediate pre-state capture both happen
    # before the sole destructive primitive is reached.
    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey -Snapshot $Snapshot | Out-Null
    $immediatePreState = Get-RegistryTreeSnapshot -SubKey $ExpectedSubKey -RegistryRoot $RegistryRoot
    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey `
        -Snapshot $immediatePreState | Out-Null
    if (Test-RegistryTreeSnapshotsEqual $immediatePreState $Snapshot) {
        return [ordered]@{ Changed = $false; RolledBack = $false; Snapshot = $immediatePreState }
    }

    try {
        Apply-ValidatedRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey -Snapshot $Snapshot `
            -RegistryRoot $RegistryRoot -MutationHook $MutationHook
        $actual = Get-RegistryTreeSnapshot -SubKey $ExpectedSubKey -RegistryRoot $RegistryRoot
        Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey -Snapshot $actual | Out-Null
        if (-not (Test-RegistryTreeSnapshotsEqual $actual $Snapshot)) {
            throw 'Registry restoration verification did not match the validated target snapshot.'
        }
        return [ordered]@{ Changed = $true; RolledBack = $false; Snapshot = $actual }
    }
    catch {
        $primaryFailure = $_.Exception.Message
        try {
            Apply-ValidatedRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey `
                -Snapshot $immediatePreState -RegistryRoot $RegistryRoot
            $rolledBack = Get-RegistryTreeSnapshot -SubKey $ExpectedSubKey -RegistryRoot $RegistryRoot
            Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $ExpectedSubKey `
                -Snapshot $rolledBack | Out-Null
            if (-not (Test-RegistryTreeSnapshotsEqual $rolledBack $immediatePreState)) {
                throw 'Immediate pre-state rollback verification failed.'
            }
        }
        catch {
            throw "Registry restoration failed ('$primaryFailure') and rollback to the immediate pre-state also failed: $($_.Exception.Message)"
        }
        throw "Registry restoration failed and was rolled back to the exact immediate pre-state: $primaryFailure"
    }
}

function Invoke-RegistryRestoreBackendSelfTest {
    $registryRoot = [Microsoft.Win32.Registry]::CurrentUser
    $sandboxSubKey = 'Software\A4SMenuLifecycleRegistryRestoreTest.' +
        [Guid]::NewGuid().ToString('N').ToUpperInvariant()
    if ($sandboxSubKey -notmatch '^Software\\A4SMenuLifecycleRegistryRestoreTest\.[0-9A-F]{32}$') {
        throw 'The registry-backend self-test generated an unsafe sandbox path.'
    }
    $original = Get-RegistryTreeSnapshot -SubKey $sandboxSubKey -RegistryRoot $registryRoot
    if ($original.Exists) { throw "The unique registry sandbox unexpectedly exists: HKCU\$sandboxSubKey" }

    $baselineTarget = [ordered]@{
        SubKey = $sandboxSubKey
        Exists = $true
        Nodes = @(
            [ordered]@{ RelativePath = ''; Values = @(
                [ordered]@{ Name = 'OldDword'; Kind = 'DWord'; Data = '7' },
                [ordered]@{ Name = 'OldText'; Kind = 'String'; Data = 'baseline' }
            ) },
            [ordered]@{ RelativePath = 'Legacy'; Values = @(
                [ordered]@{ Name = 'Bytes'; Kind = 'Binary'; Data = 'AAECAwQ=' }
            ) }
        )
    }
    $target = [ordered]@{
        SubKey = $sandboxSubKey
        Exists = $true
        Nodes = @(
            [ordered]@{ RelativePath = ''; Values = @(
                [ordered]@{ Name = 'Expand'; Kind = 'ExpandString'; Data = '%TEMP%\A4S' },
                [ordered]@{ Name = 'Qword'; Kind = 'QWord'; Data = '18446744073709551615' }
            ) },
            [ordered]@{ RelativePath = 'Child'; Values = @(
                [ordered]@{ Name = 'Lines'; Kind = 'MultiString'; Data = @('one', 'two') }
            ) },
            [ordered]@{ RelativePath = 'Child\Deep'; Values = @(
                [ordered]@{ Name = 'Payload'; Kind = 'Binary'; Data = 'AP+AQQ==' }
            ) }
        )
    }

    $primaryFailure = $null
    $cleanupFailure = $null
    $testedSteps = 0
    try {
        Restore-RegistryTreeSnapshot -ExpectedSubKey $sandboxSubKey -Snapshot $baselineTarget `
            -RegistryRoot $registryRoot | Out-Null
        $baseline = Get-RegistryTreeSnapshot -SubKey $sandboxSubKey -RegistryRoot $registryRoot

        $noOpHook = { throw 'A byte-exact no-op reached a registry mutation checkpoint.' }
        $noOp = Restore-RegistryTreeSnapshot -ExpectedSubKey $sandboxSubKey -Snapshot $baseline `
            -RegistryRoot $registryRoot -MutationHook $noOpHook
        if ($noOp.Changed -or $noOp.RolledBack) {
            throw 'The production registry backend did not preserve an exact no-op.'
        }

        $trace = [Collections.Generic.List[object]]::new()
        $traceHook = { param($step, $name) $trace.Add([ordered]@{ Step = $step; Name = $name }) }
        $success = Restore-RegistryTreeSnapshot -ExpectedSubKey $sandboxSubKey -Snapshot $target `
            -RegistryRoot $registryRoot -MutationHook $traceHook
        if (-not $success.Changed -or $success.RolledBack -or $trace.Count -eq 0) {
            throw 'The production registry backend success path did not execute mutations.'
        }
        $testedSteps = $trace.Count
        $actualTarget = Get-RegistryTreeSnapshot -SubKey $sandboxSubKey -RegistryRoot $registryRoot
        if (-not (Test-RegistryTreeSnapshotsEqual $actualTarget $target)) {
            throw 'The production registry backend success path is not byte-exact.'
        }

        for ($failureStep = 1; $failureStep -le $testedSteps; ++$failureStep) {
            Restore-RegistryTreeSnapshot -ExpectedSubKey $sandboxSubKey -Snapshot $baseline `
                -RegistryRoot $registryRoot | Out-Null
            $injections = [Collections.Generic.List[int]]::new()
            $injectionHook = {
                param($step, $name)
                if ($step -eq $failureStep) {
                    $injections.Add([int]$step)
                    throw "Injected registry mutation failure at $step ($name)."
                }
            }
            $threw = $false
            try {
                Restore-RegistryTreeSnapshot -ExpectedSubKey $sandboxSubKey -Snapshot $target `
                    -RegistryRoot $registryRoot -MutationHook $injectionHook | Out-Null
            }
            catch { $threw = $true }
            if (-not $threw -or $injections.Count -ne 1 -or
                $injections[0] -ne $failureStep) {
                throw "Registry mutation failure step $failureStep did not fail at its intended seam."
            }
            $afterFailure = Get-RegistryTreeSnapshot -SubKey $sandboxSubKey -RegistryRoot $registryRoot
            if (-not (Test-RegistryTreeSnapshotsEqual $afterFailure $baseline)) {
                throw "Registry mutation failure step $failureStep did not roll back byte-exactly."
            }
        }
    }
    catch { $primaryFailure = $_ }
    finally {
        try {
            Restore-RegistryTreeSnapshot -ExpectedSubKey $sandboxSubKey -Snapshot $original `
                -RegistryRoot $registryRoot | Out-Null
        }
        catch {
            $cleanupFailure = $_
            # This path was generated and regex-validated above; the fallback is
            # bounded to that one unique test key and never touches product state.
            try { $registryRoot.DeleteSubKeyTree($sandboxSubKey, $false) } catch {}
        }
        $final = Get-RegistryTreeSnapshot -SubKey $sandboxSubKey -RegistryRoot $registryRoot
        if (-not (Test-RegistryTreeSnapshotsEqual $final $original)) {
            $cleanupFailure = [Exception]::new('The registry sandbox did not return to its exact original state.')
        }
    }
    if ($null -ne $cleanupFailure) {
        throw "Registry-backend self-test cleanup failed: $($cleanupFailure.Exception.Message)"
    }
    if ($null -ne $primaryFailure) { throw $primaryFailure }
    return [ordered]@{ Passed = $true; MutationStepsTested = $testedSteps; Sandbox = $sandboxSubKey }
}

function New-MergedInstalledStateSnapshot {
    param(
        [Parameter(Mandatory)] $OriginalProjection,
        [Parameter(Mandatory)] $FinalInstallerRegistration
    )

    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
        -Snapshot $OriginalProjection | Out-Null
    $nodes = [Collections.Generic.List[object]]::new()
    $originalNodes = Get-NamedMemberValue $OriginalProjection 'Nodes'
    foreach ($node in $originalNodes) {
        $values = [Collections.Generic.List[object]]::new()
        $originalValues = Get-NamedMemberValue $node 'Values'
        foreach ($value in $originalValues) {
            $values.Add([ordered]@{
                Name = [string](Get-NamedMemberValue $value 'Name')
                Kind = [string](Get-NamedMemberValue $value 'Kind')
                Data = Get-NamedMemberValue $value 'Data'
            })
        }
        $nodes.Add([ordered]@{
            RelativePath = [string](Get-NamedMemberValue $node 'RelativePath')
            Values = @($values)
        })
    }
    $root = @($nodes | Where-Object { -not [string]$_.RelativePath }) | Select-Object -First 1
    if ($null -eq $root) {
        $root = [ordered]@{ RelativePath = ''; Values = @() }
        $nodes.Insert(0, $root)
    }
    $rootValues = [Collections.Generic.List[object]]::new()
    foreach ($value in @($root.Values | Where-Object {
            $existingName = [string]$_.Name
            -not @($installerOwnedRootValues | Where-Object { $_ -ieq $existingName }).Count
        })) {
        $rootValues.Add($value)
    }
    foreach ($name in $installerOwnedRootValues) {
        $snapshot = Get-NamedMemberValue $FinalInstallerRegistration $name
        Assert-ExactObjectFields -Value $snapshot -Expected @('Present', 'Name', 'Kind', 'Data') `
            -Description "Final installer-owned $name snapshot"
        $presentValue = Get-NamedMemberValue $snapshot 'Present'
        $nameValue = Get-NamedMemberValue $snapshot 'Name'
        $kindValue = Get-NamedMemberValue $snapshot 'Kind'
        $dataValue = Get-NamedMemberValue $snapshot 'Data'
        if ($presentValue -isnot [bool] -or -not $presentValue -or
            $nameValue -isnot [string] -or [string]$nameValue -cne $name -or
            $kindValue -isnot [string] -or [string]$kindValue -cne 'String' -or
            $dataValue -isnot [string]) {
            throw "Cannot merge user state without one exact REG_SZ installer-owned $name value."
        }
        $rootValues.Add([ordered]@{
            Name = $name
            Kind = 'String'
            Data = [string]$dataValue
        })
    }
    $root.Values = @($rootValues | Sort-Object { [string]$_.Name })
    $target = [ordered]@{ SubKey = $stateSubKey; Exists = $true; Nodes = @($nodes) }
    Assert-ValidRegistryTreeSnapshot -ExpectedSubKey $stateSubKey -Snapshot $target | Out-Null
    return $target
}

function Restore-UserStateProjection {
    param(
        [Parameter(Mandatory)] $OriginalProjection,
        [Parameter(Mandatory)] $FinalInstallerRegistration
    )

    # Merge into one fully validated target, then transact the whole product
    # state tree. Run and uninstall registration are deliberately untouched.
    $mergedTarget = New-MergedInstalledStateSnapshot -OriginalProjection $OriginalProjection `
        -FinalInstallerRegistration $FinalInstallerRegistration
    $transaction = Restore-RegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
        -Snapshot $mergedTarget

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
        Transaction = $transaction
        Projection = $actualProjection
    }
}

function Restore-CleanUserStateProjection {
    param([Parameter(Mandatory)] $OriginalProjection)
    $transaction = Restore-RegistryTreeSnapshot -ExpectedSubKey $stateSubKey `
        -Snapshot $OriginalProjection
    $actual = Get-UserStateProjection
    $expectedFingerprint = Get-ObjectFingerprint $OriginalProjection
    $actualFingerprint = Get-ObjectFingerprint $actual
    if ($actualFingerprint -cne $expectedFingerprint) {
        throw 'Clean-state recovery did not restore the exact user-owned registry projection.'
    }
    return [ordered]@{
        ExpectedSha256 = $expectedFingerprint
        ActualSha256 = $actualFingerprint
        Transaction = $transaction
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
    if ($tail.Count -ne 0 -and -not (Test-Path -LiteralPath $cursor -PathType Container)) {
        throw "The nearest existing ancestor for $full is not a directory: $cursor"
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
        [Parameter(Mandatory)][ValidateSet('Clean', 'InstalledV2',
            'UninstalledPending', 'UninstalledQuiescent', 'FinalInstalled')] [string] $Kind,
        [Parameter(Mandatory)][string] $Label,
        [AllowNull()] $Validation
    )
    $pending = $script:pendingSetupOwnership
    try {
        if ($null -ne $pending) {
            if ($null -eq $script:pendingProductLocks) {
                throw "$Label lost its product mutation locks before ownership registration."
            }
            $current = Get-StableLifecycleAggregate -Label ($Label + '-locked-registration-cas')
            if ($current.Fingerprint -cne [string]$Aggregate.Fingerprint) {
                throw "$Label changed between validation and ownership registration."
            }
            Assert-ExactQualificationOperation -Aggregate $current `
                -ExpectedSequence ([uint64]$pending.ExpectedSequence) `
                -ExpectedToken ([string]$pending.Token) -Label "$Label ownership CAS" | Out-Null
        }
        $entry = [ordered]@{
            Label = $Label
            Kind = $Kind
            Fingerprint = [string]$Aggregate.Fingerprint
            Aggregate = $Aggregate
            Validation = $Validation
            QualificationOperation = $pending
        }
        $script:ownedAggregateLedger.Add($entry)
        $script:lastOwnedAggregate = $entry
        return $entry
    }
    finally {
        if ($null -ne $pending) { Release-PendingProductMutationLocks }
    }
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
        ProductLifecycleMutex = $script:productLifecycleMutexName
        ProductSetupMutex = $script:productSetupMutexName
    }
}

function New-QualificationOperationToken {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([BitConverter]::ToString($bytes)).Replace('-', '')
}

function Get-LifecycleOperationRecord {
    param(
        [Parameter(Mandatory)] $Aggregate,
        [Parameter(Mandatory)][string] $Label
    )
    $registration = $Aggregate.Snapshot.InstallerRegistration
    $sequenceValue = $registration.ServicingSequence
    $lastValue = $registration.LastOperation
    [uint64]$highWater = 0
    if ($sequenceValue.Present) {
        if ($sequenceValue.Kind -cne 'QWord' -or
            -not [uint64]::TryParse([string]$sequenceValue.Data,
                [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$highWater)) {
            throw "$Label has malformed lifecycle ServicingSequence metadata."
        }
    }
    $lastSequence = [uint64]0
    $lastToken = ''
    if ($lastValue.Present) {
        if ($lastValue.Kind -cne 'String' -or
            [string]$lastValue.Data -notmatch '^(?<Sequence>[0-9]{20}):(?<Token>[0-9A-F]{64})$' -or
            -not [uint64]::TryParse($Matches.Sequence,
                [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$lastSequence) -or
            $lastSequence -eq 0 -or $lastSequence -gt $highWater) {
            throw "$Label has malformed or inconsistent LastOperation metadata."
        }
        $lastToken = $Matches.Token
    }
    return [ordered]@{
        HighWater = $highWater
        LastPresent = [bool]$lastValue.Present
        LastSequence = $lastSequence
        LastToken = $lastToken
    }
}

function Assert-ExactQualificationOperation {
    param(
        [Parameter(Mandatory)] $Aggregate,
        [Parameter(Mandatory)][uint64] $ExpectedSequence,
        [Parameter(Mandatory)][string] $ExpectedToken,
        [Parameter(Mandatory)][string] $Label
    )
    $actual = Get-LifecycleOperationRecord -Aggregate $Aggregate -Label $Label
    if ($actual.HighWater -ne $ExpectedSequence -or -not $actual.LastPresent -or
        $actual.LastSequence -ne $ExpectedSequence -or
        $actual.LastToken -cne $ExpectedToken) {
        throw "$Label was superseded or did not commit its exact qualification operation identity."
    }
    return $actual
}

function Get-ExpectedCleanupRunOnceForSnapshot {
    param([Parameter(Mandatory)] $Snapshot)
    try {
        $operation = Get-LifecycleOperationRecord `
            -Aggregate ([ordered]@{ Snapshot = $Snapshot }) `
            -Label 'pending cleanup identity'
        if (-not $operation.LastPresent -or
            $operation.LastSequence -gt $operation.HighWater) {
            return $null
        }
        $encoded = $operation.LastSequence.ToString('D20',
            [Globalization.CultureInfo]::InvariantCulture) + ':' +
            $operation.LastToken
        return $expectedCleanupRunOncePrefix + $encoded
    }
    catch { return $null }
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
    $expectedCleanup = Get-ExpectedCleanupRunOnceForSnapshot -Snapshot $Snapshot
    if ($registration.ActiveSlot.Present -or $registration.PreviousSlot.Present -or
        $registration.InstallVersion.Present -or $registration.Servicing.Exists -or
        $registration.Uninstall.Exists -or $registration.Run.Present -or
        $registration.RecoveryRunOnce.Present -or -not $registration.CleanupRunOnce.Present -or
        $registration.CleanupRunOnce.Kind -cne 'String' -or
        $null -eq $expectedCleanup -or
        $registration.CleanupRunOnce.Data -cne $expectedCleanup) {
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
        [Parameter(Mandatory)][bool] $KnownOwnedPendingCleanup,
        [Parameter(Mandatory)][bool] $KnownOwnedRestorableClean,
        [Parameter(Mandatory)][bool] $KnownOwnedInstalled,
        [Parameter(Mandatory)][bool] $KnownOwnedUninstalled
    )
    if ($KnownOwnedPendingCleanup) { return 'WaitPendingNoUninstall' }
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
    # State-changing Setup coordination is owned by Invoke-RecordedSetupStep,
    # which releases both native product locks only for the child invocation
    # and reacquires both before accepting its result. This lower-level process
    # helper must not create an independent probe gap.
    $preLaunchOwnership = $null
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
        QualificationOperation = $null
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

function Test-ExactInstalledProcessSet {
    param(
        [Parameter(Mandatory)] $AggregateProcesses,
        [Parameter(Mandatory)] $HostProcesses,
        [Parameter(Mandatory)] $ActiveHost,
        [Parameter(Mandatory)][int] $ExpectedSessionId
    )

    $aggregate = @($AggregateProcesses)
    $hosts = @($HostProcesses)
    if ($aggregate.Count -ne $hosts.Count) { return $false }
    $seen = [Collections.Generic.HashSet[int]]::new()
    foreach ($process in $aggregate) {
        if ([string](Get-NamedMemberValue $process 'Name') -cne 'A4SMenuHost' -or
            (Get-NamedMemberValue $process 'PathError') -or
            [int](Get-NamedMemberValue $process 'SessionId') -ne $ExpectedSessionId) {
            return $false
        }
        $id = [int](Get-NamedMemberValue $process 'Id')
        if (-not $seen.Add($id)) { return $false }
        try {
            $path = [IO.Path]::GetFullPath([string](Get-NamedMemberValue $process 'Path'))
            $expectedPath = [IO.Path]::GetFullPath(
                [string](Get-NamedMemberValue $ActiveHost 'Path'))
        }
        catch { return $false }
        if (-not $path.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase) -or
            [string](Get-NamedMemberValue $process 'Sha256') -cne
                [string](Get-NamedMemberValue $ActiveHost 'Sha256')) {
            return $false
        }
        $matchingHosts = @($hosts | Where-Object {
            [int](Get-NamedMemberValue $_ 'Id') -eq $id
        })
        if ($matchingHosts.Count -ne 1) { return $false }
        $hostRecord = $matchingHosts[0]
        try { $hostPath = [IO.Path]::GetFullPath([string](Get-NamedMemberValue $hostRecord 'Path')) }
        catch { return $false }
        if ([int](Get-NamedMemberValue $hostRecord 'SessionId') -ne $ExpectedSessionId -or
            -not $hostPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase) -or
            [string](Get-NamedMemberValue $hostRecord 'Sha256') -cne
                [string](Get-NamedMemberValue $ActiveHost 'Sha256')) {
            return $false
        }
    }
    return $true
}

function Assert-ExactInstalledProcessSet {
    param([Parameter(Mandatory)] $Checkpoint)

    if (-not (Test-ExactInstalledProcessSet `
            -AggregateProcesses $Checkpoint.Aggregate.Snapshot.A4SProcesses `
            -HostProcesses $Checkpoint.HostProcesses `
            -ActiveHost $Checkpoint.ActiveSlot.Files.Host `
            -ExpectedSessionId ([Diagnostics.Process]::GetCurrentProcess().SessionId))) {
        throw "$($Checkpoint.Label) process inventory is not the exact active-host-only set; an unexpected setup, cleanup, duplicate, wrong-session, path, or hash record is present."
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
    $activeHost = $ActiveSlot.Files.Host
    $probe = Invoke-CapturedProcess -Label ($Label + '-host-status') `
        -FilePath $activeHost.Path -Arguments @('--status') `
        -ExpectedSha256 $activeHost.Sha256 -TimeoutSeconds 10
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
        $expectedCleanup = Get-ExpectedCleanupRunOnceForSnapshot `
            -Snapshot $Checkpoint.Aggregate.Snapshot
        if ($Checkpoint.CleanupRunOnce.Kind -cne 'String' -or
            $null -eq $expectedCleanup -or
            $Checkpoint.CleanupRunOnce.Data -cne $expectedCleanup) {
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
    Assert-ExactInstalledProcessSet -Checkpoint $Checkpoint
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
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $StateChanging
    )

    if (-not $StateChanging) {
        $record = Invoke-CapturedProcess -Label $Label -FilePath $SetupIdentity.Path `
            -Arguments $Arguments -ExpectedSha256 $SetupIdentity.Sha256 `
            -TimeoutSeconds $OperationTimeoutSeconds -SetupLaunch
        $script:evidence.Steps.Add($record)
        Assert-ProcessSucceededWithoutExplorerRestart $record
        return $record
    }
    if ($Arguments -icontains '--qualification-operation-token') {
        throw "$Label attempted to supply its own qualification token."
    }

    $lease = $null
    $record = $null
    try {
        $lease = Acquire-ProductMutationLocks
        $preOwnership = Assert-LastOwnedAggregateImmediatelyBeforeSetup -Label $Label
        $preIdentity = Get-LifecycleOperationRecord -Aggregate $preOwnership.Aggregate `
            -Label "$Label pre-state"
        if ($preIdentity.HighWater -eq [uint64]::MaxValue) {
            throw "$Label cannot advance an exhausted lifecycle sequence."
        }
        [uint64]$expectedSequence = $preIdentity.HighWater + 1
        $token = New-QualificationOperationToken
        $childArguments = @($Arguments) + @('--qualification-operation-token', $token)

        # The child must acquire the same locks itself. The harness releases
        # both, waits for that one child, then reacquires both before observing
        # or accepting any post-state.
        Release-ProductMutationLocks $lease
        $lease = $null
        $record = Invoke-CapturedProcess -Label $Label -FilePath $SetupIdentity.Path `
            -Arguments $childArguments -ExpectedSha256 $SetupIdentity.Sha256 `
            -TimeoutSeconds $OperationTimeoutSeconds -SetupLaunch
        $script:evidence.Steps.Add($record)

        $lease = Acquire-ProductMutationLocks
        $post = Get-StableLifecycleAggregate -Label ($Label + '-locked-post-aggregate')
        $operation = Assert-ExactQualificationOperation -Aggregate $post `
            -ExpectedSequence $expectedSequence -ExpectedToken $token -Label "$Label post-state"
        Assert-ProcessSucceededWithoutExplorerRestart $record
        $record.PreLaunchOwnership = $preOwnership
        $record.QualificationOperation = [ordered]@{
            Token = $token
            ExpectedSequence = $expectedSequence
            Observed = $operation
            LockedPostAggregate = $post
        }
        $script:pendingProductLocks = $lease
        $script:pendingSetupOwnership = [ordered]@{
            Label = $Label
            Token = $token
            ExpectedSequence = $expectedSequence
            InitialPostFingerprint = $post.Fingerprint
        }
        $lease = $null
        return $record
    }
    catch {
        if ($null -ne $lease) { Release-ProductMutationLocks $lease }
        throw
    }
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
    $registration = $Checkpoint.InstallerRegistration
    return [ordered]@{
        ActiveSlotPath = $Checkpoint.ActiveSlotPath
        PreviousSlotPath = $Checkpoint.PreviousSlotPath
        InstallVersion = $Checkpoint.InstallVersion
        # Operation sequence/token intentionally changes on a byte-identical
        # repair. Exclude only that lifecycle proof from the canonical
        # registration no-change comparison.
        InstallerRegistration = [ordered]@{
            ActiveSlot = $registration.ActiveSlot
            PreviousSlot = $registration.PreviousSlot
            InstallVersion = $registration.InstallVersion
            Servicing = $registration.Servicing
            Uninstall = $registration.Uninstall
            Run = $registration.Run
            CleanupRunOnce = $registration.CleanupRunOnce
            RecoveryRunOnce = $registration.RecoveryRunOnce
        }
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
    $proof = $null
    $completed = $false
    if ($null -ne $script:pendingProductLocks) {
        $proof = Suspend-PendingProductMutationLocks
    }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $aggregate = Get-StableLifecycleAggregate -Label 'installed-cleanup-cancellation' `
                -RequiredSamples 2 -TimeoutSeconds 2
            $registration = $aggregate.Snapshot.InstallerRegistration
            if (-not $registration.CleanupRunOnce.Present -and
                -not $aggregate.Snapshot.Cleanup.HelperFile.Present -and
                @($aggregate.Snapshot.Cleanup.Processes).Count -eq 0) {
                $completed = $true
                break
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $completed) {
            throw 'A successful reinstall did not cancel and self-delete the stale cleanup helper inside the bounded interval.'
        }
    }
    finally {
        if ($null -ne $proof) {
            $aggregate = Resume-PendingProductMutationLocks -Proof $proof
        }
    }
    return $aggregate
}

function Wait-ForPendingCleanupResolution {
    param(
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [Parameter(Mandatory)][uint64] $ExpectedSequence,
        [Parameter(Mandatory)][string] $ExpectedToken,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 8
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $aggregate = Get-StableLifecycleAggregate -Label 'recovery-pending-cleanup-observation' `
            -RequiredSamples 2 -TimeoutSeconds 2
        try {
            Assert-ExactQualificationOperation -Aggregate $aggregate `
                -ExpectedSequence $ExpectedSequence -ExpectedToken $ExpectedToken `
                -Label 'recovery-pending-cleanup-observation' | Out-Null
        }
        catch {
            return [ordered]@{ State = 'Unknown'; Aggregate = $aggregate }
        }
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
    $lease = Acquire-ProductMutationLocks
    try {
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
        Register-OwnedAggregate -Aggregate $aggregate -Kind Clean `
            -Label 'recovered-clean-original-state' -Validation $null | Out-Null
        return $aggregate
    }
    finally { Release-ProductMutationLocks $lease }
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
        $activeHost = $Checkpoint.ActiveSlot.Files.Host
        $result.Exit = Invoke-CapturedProcess -Label 'final-host-exit' `
            -FilePath $activeHost.Path -Arguments @('--exit') `
            -ExpectedSha256 $activeHost.Sha256 -TimeoutSeconds 10
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
$v2Slot = $null
$finalPreviousSlot = $null
$finalPreviousPayload = $null
$sessionId = $null
$lifecycleMutexName = $null

try {
    # This independent current-user lock is held continuously through preflight,
    # all process launches, evidence writes, and any recovery decision.
    $lifecycleMutexName = Acquire-LifecycleMutex
    $mutexNames = Get-LifecycleMutexNames
    $script:productLifecycleMutexName = $mutexNames.ProductLifecycle
    $script:productSetupMutexName = $mutexNames.ProductSetup
    $productSetupPreflight = Assert-ProductSetupCoordinationAvailable

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
        ProductLifecycleMutexName = $script:productLifecycleMutexName
        ProductSetupMutexName = $script:productSetupMutexName
        ProductSetupPreflight = $productSetupPreflight
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
        ProductSetupMutexName = $script:productSetupMutexName
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

    # Frozen V1 predates the cooperative lifecycle-token protocol and is
    # deliberately read-only on a real user profile. Upgrade and rollback
    # qualification is deferred to a disposable Sandbox/VM profile.
    $script:evidence.LegacyUpgradeRollback = [ordered]@{
        Status = 'DeferredToDisposableProfile'
        Reason = 'Frozen V1 cannot participate in lifecycle token/sequence ownership.'
        FrozenV1VerifiedReadOnly = $true
    }
    $knownMenuHashes = @($v2Payload.Menu.Sha256)
    $installV2 = Invoke-RecordedSetupStep -Label 'install-v2-silent' -SetupIdentity $v2Identity `
        -Arguments @('--install', '--silent') -StateChanging
    $v2Checkpoint = Add-CheckpointToStep -Step $installV2 -Label 'installed-v2'
    $v2Slot = $v2Checkpoint.ActiveSlotPath
    $script:knownPayloadBySlotName[[IO.Path]::GetFileName($v2Slot)] = $v2Payload
    Assert-InstalledCheckpoint -Checkpoint $v2Checkpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null
    Assert-ExpectedHostState -Checkpoint $v2Checkpoint -KnownMenuSha256 $knownMenuHashes
    Assert-UserStateAndCacheInvariant -Checkpoint $v2Checkpoint `
        -OriginalPartitions $originalPartitions -OriginalDataCache $originalDataCache
    Register-OwnedAggregate -Aggregate $v2Checkpoint.Aggregate -Kind InstalledV2 `
        -Label 'installed-v2' -Validation $v2Checkpoint | Out-Null
    Write-Evidence

    $beforeRepairFingerprint = Get-ObjectFingerprint (Get-InstallerCheckpointProjection $v2Checkpoint)
    $repair = Invoke-RecordedSetupStep -Label 'repair-v2-same-version-silent' `
        -SetupIdentity $v2Checkpoint.ActiveSlot.Files.Setup -Arguments @('--repair', '--silent') `
        -StateChanging
    $repairCheckpoint = Add-CheckpointToStep -Step $repair -Label 'repaired-v2-same-version'
    Assert-InstalledCheckpoint -Checkpoint $repairCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $null -ExpectedPreviousPayload $null
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
        -SetupIdentity $repairCheckpoint.ActiveSlot.Files.Setup `
        -Arguments @('--uninstall', '--silent') -StateChanging
    $uninstallCheckpoint = Add-CheckpointToStep -Step $uninstall -Label 'uninstalled-v2'
    Assert-UninstalledCheckpoint -Checkpoint $uninstallCheckpoint -AllowedSlotPaths @($v2Slot)
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
        -SetupIdentity $v2Identity -Arguments @('--install', '--silent') -StateChanging
    $finalInstall.CleanupCancellation = Wait-ForInstalledCleanupCancellation
    $finalInstallCheckpoint = Add-CheckpointToStep -Step $finalInstall -Label 'final-v2-before-restoration'
    Assert-InstalledCheckpoint -Checkpoint $finalInstallCheckpoint -ExpectedVersion $expectedV2 `
        -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
        -ExpectedPreviousSlot $finalPreviousSlot -ExpectedPreviousPayload $finalPreviousPayload
    Assert-ExpectedHostState -Checkpoint $finalInstallCheckpoint -KnownMenuSha256 $knownMenuHashes -AllowDeferredStopped
    # Prove the final install itself preserved the immediately preceding
    # Config/Menu/Legacy/DataCache state. This check intentionally runs before
    # restoration so the later recovery step cannot mask installer damage.
    Assert-UserStateAndCacheInvariant -Checkpoint $finalInstallCheckpoint `
        -OriginalPartitions $uninstallCheckpoint.UserStatePartitions `
        -OriginalDataCache $uninstallCheckpoint.DataCache
    Register-OwnedAggregate -Aggregate $finalInstallCheckpoint.Aggregate -Kind FinalInstalled `
        -Label 'final-v2-before-restoration' -Validation $finalInstallCheckpoint | Out-Null
    Write-Evidence

    $script:evidence.FinalHostQuiescence = Stop-FinalHostQuiescent -Checkpoint $finalInstallCheckpoint
    $quiescentLease = Acquire-ProductMutationLocks
    try {
        $quiescentPre = Get-StableLifecycleAggregate -Label 'final-v2-quiescent-locked-pre'
        Assert-ExactQualificationOperation -Aggregate $quiescentPre `
            -ExpectedSequence ([uint64]$finalInstall.QualificationOperation.ExpectedSequence) `
            -ExpectedToken ([string]$finalInstall.QualificationOperation.Token) `
            -Label 'final host quiescence' | Out-Null
        $quiescentCheckpoint = Get-ProductCheckpoint -Label 'final-v2-host-quiescent-before-restoration'
        Assert-InstalledCheckpoint -Checkpoint $quiescentCheckpoint -ExpectedVersion $expectedV2 `
            -ExpectedPayload $v2Payload -ExpectedActiveSlot $v2Slot `
            -ExpectedPreviousSlot $finalPreviousSlot -ExpectedPreviousPayload $finalPreviousPayload
        Assert-ExpectedHostState -Checkpoint $quiescentCheckpoint -KnownMenuSha256 $knownMenuHashes `
            -RequireQuiescentStopped
        Register-OwnedAggregate -Aggregate $quiescentCheckpoint.Aggregate -Kind FinalInstalled `
            -Label 'final-v2-host-quiescent' -Validation $quiescentCheckpoint | Out-Null
    }
    finally { Release-ProductMutationLocks $quiescentLease }
    Write-Evidence

    $finalInstallerRegistration = $quiescentCheckpoint.InstallerRegistration
    $restorationLease = Acquire-ProductMutationLocks
    try {
        Assert-AggregateFingerprintImmediatelyBeforeMutation `
            -ExpectedFingerprint $quiescentCheckpoint.Aggregate.Fingerprint `
            -Label 'final user-state restoration' | Out-Null
        $script:evidence.UserStateRestoration = Restore-UserStateProjection `
            -OriginalProjection $originalUserState -FinalInstallerRegistration $finalInstallerRegistration
        Record-CacheRestoration -Original $originalDataCache `
            -Reason 'after final V2 host became quiescent under both product locks' `
            -ExpectedAggregate $null | Out-Null
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
        $restoredRegistrationWithLifecycleFingerprint =
            Get-ObjectFingerprint $restoredCheckpoint.InstallerRegistration
        Register-OwnedAggregate -Aggregate $restoredCheckpoint.Aggregate -Kind FinalInstalled `
            -Label 'final-v2-restored-and-quiescent' -Validation $restoredCheckpoint | Out-Null
    }
    finally { Release-ProductMutationLocks $restorationLease }
    Write-Evidence

    if ($finalQuiescenceVerificationMilliseconds -le $preloadDebounceMilliseconds) {
        throw 'Final verification interval must be longer than the product preload debounce.'
    }
    Start-Sleep -Milliseconds $finalQuiescenceVerificationMilliseconds
    $stabilityLease = Acquire-ProductMutationLocks
    try {
        Assert-AggregateFingerprintImmediatelyBeforeMutation `
            -ExpectedFingerprint $restoredCheckpoint.Aggregate.Fingerprint `
            -Label 'final quiescence ownership check' | Out-Null
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
        if ((Get-ObjectFingerprint $stableCheckpoint.InstallerRegistration) -cne
            $restoredRegistrationWithLifecycleFingerprint) {
            throw 'Final lifecycle sequence/token changed during the quiescence interval.'
        }
        if ((Get-ShellExplorerPid) -ne $cleanStart.ExplorerPid) {
            throw 'Explorer PID changed somewhere in the lifecycle matrix.'
        }
        Register-OwnedAggregate -Aggregate $stableCheckpoint.Aggregate -Kind FinalInstalled `
            -Label 'final-v2-after-quiescence-interval' -Validation $stableCheckpoint | Out-Null
    }
    finally { Release-ProductMutationLocks $stabilityLease }
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
    # A validation failure after a child returned must never retain locks into
    # recovery. The unregistered post-state remains deliberately unowned, so
    # recovery cannot uninstall or restore over a superseding operation.
    Release-PendingProductMutationLocks
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
        Release-PendingProductMutationLocks
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
                    $knownInstalled = $null -ne $owned -and $owned.Kind -in @('InstalledV2', 'FinalInstalled') -and
                        $null -ne $owned.Validation
                    $knownUninstalled = $null -ne $owned -and $owned.Kind -in @('UninstalledPending', 'UninstalledQuiescent')
                    $knownRestorableClean = $null -ne $owned -and
                        $owned.Kind -in @('Clean', 'UninstalledQuiescent')
                    $knownOwnedPending = $exactPending -and $null -ne $owned -and
                        $owned.Kind -ceq 'UninstalledPending' -and
                        $null -ne $owned.Validation -and
                        $null -ne $owned.QualificationOperation
                    if ($knownOwnedPending) {
                        Assert-ExactQualificationOperation -Aggregate $current `
                            -ExpectedSequence ([uint64]$owned.QualificationOperation.ExpectedSequence) `
                            -ExpectedToken ([string]$owned.QualificationOperation.Token) `
                            -Label 'failure-recovery-owned-pending-cleanup' | Out-Null
                    }
                    $recovery.Decision = Get-RecoveryDecision -InstallerOwnedClean $installerClean `
                        -KnownOwnedPendingCleanup $knownOwnedPending `
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
                                -ExpectedSha256 $script:expectedCleanupHash `
                                -ExpectedSequence ([uint64]$owned.QualificationOperation.ExpectedSequence) `
                                -ExpectedToken ([string]$owned.QualificationOperation.Token)
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
                            $recovery.SetupUninstall = Invoke-RecordedSetupStep `
                                -Label 'failure-recovery-uninstall-v2' -SetupIdentity $v2Identity `
                                -Arguments @('--uninstall', '--silent') -StateChanging
                            $recovery.MutationPerformed = $true
                            $recovery.UninstalledCheckpoint = Get-ProductCheckpoint `
                                -Label 'failure-recovery-uninstalled'
                            $allowedSlots = @($v2Slot) | Where-Object { $_ }
                            Assert-UninstalledCheckpoint -Checkpoint $recovery.UninstalledCheckpoint `
                                -AllowedSlotPaths $allowedSlots
                            $recoveryKind = if ($recovery.UninstalledCheckpoint.CleanupRunOnce.Present) {
                                'UninstalledPending'
                            } else { 'UninstalledQuiescent' }
                            Register-OwnedAggregate -Aggregate $recovery.UninstalledCheckpoint.Aggregate `
                                -Kind $recoveryKind -Label 'failure-recovery-uninstalled' `
                                -Validation $recovery.UninstalledCheckpoint | Out-Null
                            $canRestoreOriginalState = $true
                            $restoreAggregate = $recovery.UninstalledCheckpoint.Aggregate
                            if ($recovery.UninstalledCheckpoint.CleanupRunOnce.Present) {
                                $resolution = Wait-ForPendingCleanupResolution `
                                    -ExpectedSha256 $script:expectedCleanupHash `
                                    -ExpectedSequence ([uint64]$recovery.SetupUninstall.QualificationOperation.ExpectedSequence) `
                                    -ExpectedToken ([string]$recovery.SetupUninstall.QualificationOperation.Token)
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
        Release-PendingProductMutationLocks
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
