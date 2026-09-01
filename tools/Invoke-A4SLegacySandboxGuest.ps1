<#
.SYNOPSIS
Runs the frozen-V1 to reviewed-V2 lifecycle matrix inside Windows Sandbox.

.DESCRIPTION
This is the guest half of Invoke-A4SLegacySandboxLifecycle.ps1. It refuses to
run outside the WDAGUtilityAccount profile, requires a clean disposable A4S
state, authenticates exact setup and embedded payload hashes, never supplies
--restart-explorer, and publishes progress plus a final JSON result through the
single writable evidence mapping.
#>
[CmdletBinding()]
param(
    [string] $RequestPath,
    [string] $ExpectedSessionId,
    [string] $ExpectedNonce,
    [string] $ExpectedRequestSha256,
    [string] $ExpectedGuestScriptSha256,
    [switch] $ContractSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$frozenV1SetupSha256 = 'DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2'
$frozenV1HostSha256 = '9995676D0B74DE2E68E0C4EACB7E4111BE1AF13AA34C3505499C3925708A0573'
$frozenV1MenuSha256 = '4C1C9A325FF41A6DD089690874C95DCC8CC8CC5A4561F9B8ECCFA29832C03610'
$requiredMatrix = @(
    'install-v1',
    'update-v1-to-v2',
    'rollback-v2-to-v1',
    'update-v1-to-v2-again',
    'repair-v2-same-version',
    'uninstall-v2'
)

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.Trim().ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{64}$') { throw "Invalid SHA-256: $Value" }
    return $normalized
}

function Get-RandomHex {
    param([ValidateRange(16, 64)][int] $Bytes = 32)
    $buffer = [byte[]]::new($Bytes)
    $algorithm = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $algorithm.GetBytes($buffer) }
    finally { $algorithm.Dispose() }
    return ([BitConverter]::ToString($buffer)).Replace('-', '')
}

function Get-WindowsSandboxIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($null -eq $identity.User) {
            throw 'The current process token has no user SID.'
        }
        $name = [string]$identity.Name
        $sid = [string]$identity.User.Value
        if ($name -notmatch '(?i)\\WDAGUtilityAccount$' -or
            $sid -notmatch '^S-1-5-21-(?:[0-9]+-){3}504$') {
            throw "The process token is not the Windows Sandbox WDAGUtilityAccount (identity=$name, SID=$sid)."
        }
        if ($env:USERNAME -ine 'WDAGUtilityAccount' -or
            $env:USERPROFILE -inotlike 'C:\Users\WDAGUtilityAccount*') {
            throw 'The Windows Sandbox token and profile environment do not agree.'
        }
        return [ordered]@{ Name = $name; Sid = $sid }
    }
    finally { $identity.Dispose() }
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
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing file: $full" }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A qualification input may not be a reparse point: $full"
    }
    if ((Get-PeMachine $full) -ne 0x8664) { throw "Qualification input is not x64: $full" }
    return [ordered]@{
        Path = $full
        Length = [long]$item.Length
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToUpperInvariant()
        ProductVersion = Get-FixedProductVersion $full
        OriginalFilename = $item.VersionInfo.OriginalFilename
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

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text
    )
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).new"
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
    if (-not ('A4SSandboxAtomicFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class A4SSandboxAtomicFile
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileExW(string existingName, string newName, uint flags);

    public static void Publish(string temporary, string target)
    {
        const uint ReplaceExisting = 0x1;
        const uint WriteThrough = 0x8;
        if (!MoveFileExW(temporary, target, ReplaceExisting | WriteThrough))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Atomic evidence publication failed");
    }
}
'@
    }
    try { [A4SSandboxAtomicFile]::Publish($temporary, $Path) }
    catch {
        try { [IO.File]::Delete($temporary) } catch {}
        throw
    }
}

function Write-GuestStage {
    param(
        [Parameter(Mandatory)][ValidateRange(10, 89)][int] $Ordinal,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string] $Stage,
        [hashtable] $Details
    )
    $record = [ordered]@{
        SchemaVersion = 1
        SessionId = $script:expectedSessionId
        Nonce = $script:expectedNonce
        RequestSha256 = $script:expectedRequestSha256
        GuestScriptSha256 = $script:expectedGuestScriptSha256
        Ordinal = $Ordinal
        Stage = $Stage
        ProcessId = $PID
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ($PSBoundParameters.ContainsKey('Details')) {
        $record.Details = $Details
    }
    $path = Join-Path $script:evidenceRoot `
        ('stage-{0:D3}-{1}.json' -f $Ordinal, $Stage)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($record | ConvertTo-Json -Depth 20))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Read-Utf8JsonSnapshot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1, 16777216)][int] $MaximumBytes = 1048576
    )
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Missing JSON control file: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A JSON control file may not be a reparse point: $full"
    }
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 2 -or $stream.Length -gt $MaximumBytes) {
            throw "JSON control-file length is outside the accepted range: $full"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "Unexpected end of JSON control file: $full" }
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "JSON control files must be UTF-8 without a BOM: $full"
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

function Resolve-GuestSetupSources {
    param(
        [Parameter(Mandatory)][string] $repoRoot,
        [Parameter(Mandatory)][psobject] $request
    )
    return [ordered]@{
        V1 = [IO.Path]::GetFullPath((Join-Path $repoRoot `
            ([string]$request.V1SetupRelativePath)))
        V2 = [IO.Path]::GetFullPath((Join-Path $repoRoot `
            ([string]$request.V2SetupRelativePath)))
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
            if ($null -eq $child) { throw "Registry key disappeared: $SubKey\\$name" }
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

function Get-RegistryValueRecord {
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

function Get-RegistryString {
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)][string] $Name
    )
    $record = Get-RegistryValueRecord -SubKey $SubKey -Name $Name
    if (-not $record.Present) { return $null }
    if ($record.Value.Kind -cne 'String') {
        throw "$SubKey\\$Name is not an exact REG_SZ value."
    }
    return [string]$record.Value.Data
}

function Set-SentinelUserState {
    param([Parameter(Mandatory)][string] $Nonce)
    $config = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
        'Software\A4SMenu\Config', $true)
    try {
        $config.SetValue('SandboxQualificationString', "A4S-$Nonce",
            [Microsoft.Win32.RegistryValueKind]::String)
        $config.SetValue('SandboxQualificationBinary', [byte[]](0, 1, 2, 127, 128, 255),
            [Microsoft.Win32.RegistryValueKind]::Binary)
    }
    finally { $config.Dispose() }
    $menu = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
        'Software\A4SMenu\Menu', $true)
    try {
        $menu.SetValue('SandboxQualificationDword', 0x45A4,
            [Microsoft.Win32.RegistryValueKind]::DWord)
        $menu.SetValue('SandboxQualificationQword', [long]0x1234567890,
            [Microsoft.Win32.RegistryValueKind]::QWord)
    }
    finally { $menu.Dispose() }
    $root = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
        'Software\A4SMenu', $true)
    try {
        $root.SetValue('InstallPath', 'C:\A4S-Sandbox-Sentinel',
            [Microsoft.Win32.RegistryValueKind]::String)
        $root.SetValue('Enabled', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
    }
    finally { $root.Dispose() }
}

function Get-UserStateProjection {
    return [ordered]@{
        Config = Get-RegistryTreeSnapshot 'Software\A4SMenu\Config'
        Menu = Get-RegistryTreeSnapshot 'Software\A4SMenu\Menu'
        InstallPath = Get-RegistryValueRecord 'Software\A4SMenu' 'InstallPath'
        Enabled = Get-RegistryValueRecord 'Software\A4SMenu' 'Enabled'
    }
}

function Get-DataCacheRecord {
    $path = Join-Path $env:LOCALAPPDATA 'A4SMenu\DataCache.db'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{ Present = $false; Path = $path }
    }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'DataCache.db is unexpectedly a reparse point.'
    }
    return [ordered]@{
        Present = $true
        Path = $path
        Length = [long]$item.Length
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
    }
}

function Get-InstallInventory {
    $root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu'))
    if (-not (Test-Path -LiteralPath $root)) {
        return [ordered]@{ Present = $false; Root = $root; Entries = @() }
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse |
            Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The install tree contains a reparse point: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($root.TrimEnd('\').Length).TrimStart('\')
        if ($item.PSIsContainer) {
            $entries.Add([ordered]@{ RelativePath = $relative; Kind = 'Directory' })
        }
        else {
            $entries.Add([ordered]@{
                RelativePath = $relative
                Kind = 'File'
                Length = [long]$item.Length
                Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToUpperInvariant()
                ProductVersion = if ($item.Extension -in @('.exe', '.dll')) {
                    Get-FixedProductVersion $item.FullName
                } else { $null }
            })
        }
    }
    return [ordered]@{ Present = $true; Root = $root; Entries = @($entries) }
}

function Initialize-ExplorerProbe {
    if ('A4SSandboxWindowProbe' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class A4SSandboxModuleSnapshot
{
    public int TotalModuleCount { get; private set; }
    public string MainModulePath { get; private set; }
    public string[] A4SMenuModulePaths { get; private set; }

    public A4SSandboxModuleSnapshot(int totalModuleCount, string mainModulePath,
        string[] a4SMenuModulePaths)
    {
        TotalModuleCount = totalModuleCount;
        MainModulePath = mainModulePath;
        A4SMenuModulePaths = a4SMenuModulePaths;
    }
}

public static class A4SSandboxWindowProbe
{
    private const uint TH32CS_SNAPMODULE = 0x00000008;
    private const uint TH32CS_SNAPMODULE32 = 0x00000010;
    private const int ERROR_BAD_LENGTH = 24;
    private const int ERROR_NO_MORE_FILES = 18;
    private const int ERROR_INVALID_DATA = 13;
    private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MODULEENTRY32
    {
        public uint dwSize;
        public uint th32ModuleID;
        public uint th32ProcessID;
        public uint GlblcntUsage;
        public uint ProccntUsage;
        public IntPtr modBaseAddr;
        public uint modBaseSize;
        public IntPtr hModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExePath;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindowW(string className, string windowName);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Module32FirstW(IntPtr snapshot, ref MODULEENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Module32NextW(IntPtr snapshot, ref MODULEENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public static int TaskbarExplorerPid()
    {
        IntPtr taskbar = FindWindowW("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Shell_TrayWnd was not found");
        uint processId;
        if (GetWindowThreadProcessId(taskbar, out processId) == 0 || processId == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Taskbar Explorer PID was not resolved");
        return checked((int)processId);
    }

    public static A4SSandboxModuleSnapshot ModuleSnapshotForProcess(int processId)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException("processId");
        for (int attempt = 0; attempt < 8; ++attempt)
        {
            IntPtr snapshot = CreateToolhelp32Snapshot(
                TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, checked((uint)processId));
            if (snapshot == InvalidHandleValue)
            {
                int createError = Marshal.GetLastWin32Error();
                if (createError == ERROR_BAD_LENGTH)
                {
                    Thread.Sleep(10);
                    continue;
                }
                throw new Win32Exception(createError, "Explorer module snapshot creation failed");
            }

            bool retry = false;
            try
            {
                List<string> a4SMenuPaths = new List<string>();
                int totalModuleCount = 0;
                string mainModulePath = null;
                MODULEENTRY32 entry = new MODULEENTRY32();
                entry.dwSize = checked((uint)Marshal.SizeOf(typeof(MODULEENTRY32)));
                if (!Module32FirstW(snapshot, ref entry))
                {
                    int firstError = Marshal.GetLastWin32Error();
                    if (firstError == ERROR_NO_MORE_FILES)
                        throw new Win32Exception(firstError,
                            "Explorer module snapshot was unexpectedly empty");
                    if (firstError == ERROR_BAD_LENGTH) retry = true;
                    else throw new Win32Exception(firstError, "Explorer module enumeration failed to start");
                }
                else
                {
                    while (true)
                    {
                        if (entry.th32ProcessID != checked((uint)processId) ||
                            String.IsNullOrWhiteSpace(entry.szExePath))
                            throw new Win32Exception(ERROR_INVALID_DATA,
                                "Explorer returned an invalid module snapshot entry");
                        ++totalModuleCount;
                        if (mainModulePath == null) mainModulePath = entry.szExePath;
                        if (String.Equals(entry.szModule, "A4SMenu.dll",
                                StringComparison.OrdinalIgnoreCase))
                        {
                            a4SMenuPaths.Add(entry.szExePath);
                        }
                        entry.dwSize = checked((uint)Marshal.SizeOf(typeof(MODULEENTRY32)));
                        if (Module32NextW(snapshot, ref entry)) continue;
                        int nextError = Marshal.GetLastWin32Error();
                        if (nextError == ERROR_NO_MORE_FILES)
                        {
                            if (totalModuleCount <= 0 || String.IsNullOrWhiteSpace(mainModulePath))
                                throw new Win32Exception(ERROR_NO_MORE_FILES,
                                    "Explorer module snapshot did not prove a main module");
                            return new A4SSandboxModuleSnapshot(totalModuleCount,
                                mainModulePath, a4SMenuPaths.ToArray());
                        }
                        if (nextError == ERROR_BAD_LENGTH)
                        {
                            retry = true;
                            break;
                        }
                        throw new Win32Exception(nextError, "Explorer module enumeration failed");
                    }
                }
            }
            finally
            {
                CloseHandle(snapshot);
            }
            if (retry)
            {
                Thread.Sleep(10);
                continue;
            }
        }
        throw new Win32Exception(ERROR_BAD_LENGTH,
            "Explorer module snapshot remained unstable after eight attempts");
    }
}
'@
}

function Get-TaskbarExplorerPid {
    Initialize-ExplorerProbe
    return [A4SSandboxWindowProbe]::TaskbarExplorerPid()
}

function Get-ExplorerModuleInventory {
    param([Parameter(Mandatory)][int] $ExplorerPid)
    $modules = [Collections.Generic.List[object]]::new()
    try {
        Initialize-ExplorerProbe
        $snapshot = [A4SSandboxWindowProbe]::ModuleSnapshotForProcess($ExplorerPid)
        if ([int]$snapshot.TotalModuleCount -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$snapshot.MainModulePath)) {
            throw 'The native Explorer module snapshot did not prove a main module.'
        }
        $mainModulePath = [IO.Path]::GetFullPath([string]$snapshot.MainModulePath)
        $canonicalExplorerPath = [IO.Path]::GetFullPath(
            (Join-Path $env:SystemRoot 'explorer.exe'))
        if (-not $mainModulePath.Equals($canonicalExplorerPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The native module snapshot main image is not canonical Explorer.'
        }
        foreach ($modulePath in @($snapshot.A4SMenuModulePaths)) {
            $identity = Get-FileIdentity $modulePath
            $modules.Add($identity)
        }
        if ((Get-TaskbarExplorerPid) -ne $ExplorerPid) {
            throw 'The taskbar Explorer changed while its module snapshot was captured.'
        }
        return [ordered]@{
            Complete = $true
            Error = $null
            TotalModuleCount = [int]$snapshot.TotalModuleCount
            MainModulePath = $mainModulePath
            Modules = @($modules)
        }
    }
    catch {
        return [ordered]@{
            Complete = $false
            Error = $_.Exception.Message
            TotalModuleCount = 0
            MainModulePath = $null
            Modules = @($modules)
        }
    }
}

function Get-A4SProcessInventory {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match '^A4SMenu(?:Host|Setup|Cleanup)' })) {
        $path = $null
        try { $path = $process.Path } catch {}
        $records.Add([ordered]@{
            Id = $process.Id
            Name = $process.ProcessName
            Path = $path
            SessionId = $process.SessionId
        })
    }
    return @($records)
}

function Get-Checkpoint {
    param([Parameter(Mandatory)][string] $Label)
    $explorerPid = Get-TaskbarExplorerPid
    return [ordered]@{
        Label = $Label
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        ExplorerPid = $explorerPid
        ExplorerModules = Get-ExplorerModuleInventory $explorerPid
        Product = Get-RegistryTreeSnapshot 'Software\A4SMenu'
        Lifecycle = Get-RegistryTreeSnapshot 'Software\A4SMenuLifecycle'
        Run = Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\Run' 'A4SMenu'
        CleanupRunOnce = Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\RunOnce' '!A4SMenuCleanup'
        RecoveryRunOnce = Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\RunOnce' '!A4SMenuServicingRecovery'
        Uninstall = Get-RegistryTreeSnapshot 'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu'
        UserState = Get-UserStateProjection
        DataCache = Get-DataCacheRecord
        InstallInventory = Get-InstallInventory
        Processes = Get-A4SProcessInventory
    }
}

function Get-SlotPayload {
    param([Parameter(Mandatory)][string] $SlotPath)
    $slot = [IO.Path]::GetFullPath($SlotPath)
    $versions = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu\versions')).TrimEnd('\') + '\'
    if (-not $slot.StartsWith($versions, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Registered slot is outside the canonical versions root: $slot"
    }
    if (-not (Test-Path -LiteralPath $slot -PathType Container)) {
        throw "Registered slot is missing: $slot"
    }
    $children = @(Get-ChildItem -LiteralPath $slot -Force | Sort-Object Name)
    $expectedNames = @('A4SMenu.dll', 'A4SMenuHost.exe', 'A4SMenuSetup.exe')
    if (($children.Name -join '|') -cne (($expectedNames | Sort-Object) -join '|') -or
        @($children | Where-Object PSIsContainer).Count -ne 0) {
        throw "Slot inventory is not exactly the three product files: $slot"
    }
    return [ordered]@{
        Path = $slot
        Menu = Get-FileIdentity (Join-Path $slot 'A4SMenu.dll')
        Host = Get-FileIdentity (Join-Path $slot 'A4SMenuHost.exe')
        Setup = Get-FileIdentity (Join-Path $slot 'A4SMenuSetup.exe')
    }
}

function Assert-PayloadMatches {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Actual.Setup.Sha256 -cne (Normalize-Sha256 ([string]$Expected.SetupSha256)) -or
        $Actual.Host.Sha256 -cne (Normalize-Sha256 ([string]$Expected.HostSha256)) -or
        $Actual.Menu.Sha256 -cne (Normalize-Sha256 ([string]$Expected.MenuSha256)) -or
        $Actual.Setup.ProductVersion -cne [string]$Expected.Version -or
        $Actual.Host.ProductVersion -cne [string]$Expected.Version -or
        $Actual.Menu.ProductVersion -cne [string]$Expected.Version) {
        throw "$Label payload hashes or fixed versions do not match the reviewed release."
    }
}

function Assert-ExplorerUnchanged {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][int] $InitialExplorerPid
    )
    $canonicalExplorerPath = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'explorer.exe'))
    if ([int]$Checkpoint.ExplorerPid -ne $InitialExplorerPid -or
        -not $Checkpoint.ExplorerModules.Complete -or
        [int]$Checkpoint.ExplorerModules.TotalModuleCount -le 0 -or
        [string]::IsNullOrWhiteSpace(
            [string]$Checkpoint.ExplorerModules.MainModulePath) -or
        -not ([IO.Path]::GetFullPath(
            [string]$Checkpoint.ExplorerModules.MainModulePath).Equals(
                $canonicalExplorerPath,
                [StringComparison]::OrdinalIgnoreCase))) {
        throw "Explorer identity or complete canonical module proof changed at $($Checkpoint.Label); --restart-explorer was not authorized."
    }
}

function Assert-UserStateAndCache {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][string] $ExpectedUserStateSha256,
        [Parameter(Mandatory)][string] $ExpectedCacheSha256
    )
    if ((Get-ObjectSha256 $Checkpoint.UserState) -cne $ExpectedUserStateSha256) {
        throw "User-owned Config/Menu/legacy state changed at $($Checkpoint.Label)."
    }
    if (-not $Checkpoint.DataCache.Present -or
        [string]$Checkpoint.DataCache.Sha256 -cne $ExpectedCacheSha256) {
        throw "DataCache.db changed at $($Checkpoint.Label)."
    }
}

function Assert-NoServicingJournal {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)][string] $Label
    )
    $journalNodes = @($Checkpoint.Product.Nodes | Where-Object {
        [string]$_.RelativePath -ieq 'Servicing' -or
        [string]$_.RelativePath -ilike 'Servicing\*'
    })
    if ($journalNodes.Count -ne 0 -or $Checkpoint.RecoveryRunOnce.Present) {
        throw "$Label retained an incomplete servicing journal or recovery continuation."
    }
}

function Assert-InstalledCheckpoint {
    param(
        [Parameter(Mandatory)] $Checkpoint,
        [Parameter(Mandatory)] $ExpectedActive,
        [AllowNull()] $ExpectedPrevious,
        [Parameter(Mandatory)][int] $ExpectedSlotCount,
        [Parameter(Mandatory)][int] $InitialExplorerPid,
        [Parameter(Mandatory)][string] $ExpectedUserStateSha256,
        [Parameter(Mandatory)][string] $ExpectedCacheSha256
    )
    Assert-ExplorerUnchanged -Checkpoint $Checkpoint -InitialExplorerPid $InitialExplorerPid
    Assert-UserStateAndCache -Checkpoint $Checkpoint `
        -ExpectedUserStateSha256 $ExpectedUserStateSha256 `
        -ExpectedCacheSha256 $ExpectedCacheSha256
    Assert-NoServicingJournal -Checkpoint $Checkpoint -Label $Checkpoint.Label
    if ($Checkpoint.CleanupRunOnce.Present) {
        throw "Unexpected cleanup continuation at $($Checkpoint.Label)."
    }
    $activePath = Get-RegistryString 'Software\A4SMenu' 'ActiveSlot'
    $previousPath = Get-RegistryString 'Software\A4SMenu' 'PreviousSlot'
    $installVersion = Get-RegistryString 'Software\A4SMenu' 'InstallVersion'
    if ([string]::IsNullOrWhiteSpace($activePath) -or
        $installVersion -cne [string]$ExpectedActive.Version) {
        throw "Installed registration is incomplete at $($Checkpoint.Label)."
    }
    $active = Get-SlotPayload $activePath
    Assert-PayloadMatches -Actual $active -Expected $ExpectedActive `
        -Label "$($Checkpoint.Label) active"
    if ($null -eq $ExpectedPrevious) {
        if (-not [string]::IsNullOrEmpty($previousPath)) {
            throw "Unexpected PreviousSlot at $($Checkpoint.Label)."
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($previousPath)) {
            throw "Missing PreviousSlot at $($Checkpoint.Label)."
        }
        $previous = Get-SlotPayload $previousPath
        Assert-PayloadMatches -Actual $previous -Expected $ExpectedPrevious `
            -Label "$($Checkpoint.Label) previous"
    }
    if (-not $Checkpoint.Run.Present) { throw "Run registration is missing at $($Checkpoint.Label)." }
    $expectedRun = '"' + (Join-Path $active.Path 'A4SMenuHost.exe') + '"'
    if ([string]$Checkpoint.Run.Value.Kind -cne 'String' -or
        [string]$Checkpoint.Run.Value.Data -ine $expectedRun) {
        throw "Run registration does not target the exact active host at $($Checkpoint.Label)."
    }
    $uninstallVersion = Get-RegistryString `
        'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu' 'DisplayVersion'
    $uninstallLocation = Get-RegistryString `
        'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu' 'InstallLocation'
    $uninstallCommand = Get-RegistryString `
        'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu' 'QuietUninstallString'
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu'))
    $expectedUninstall = '"' + (Join-Path $active.Path 'A4SMenuSetup.exe') + '" --uninstall --silent'
    if ($uninstallVersion -cne [string]$ExpectedActive.Version -or
        -not $uninstallLocation.Equals($expectedRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        $uninstallCommand -ine $expectedUninstall) {
        throw "Windows Settings registration is not bound to the active slot at $($Checkpoint.Label)."
    }
    $slotDirectories = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'A4SMenu\versions') `
        -Force -Directory)
    if ($slotDirectories.Count -ne $ExpectedSlotCount) {
        throw "Expected $ExpectedSlotCount version slots at $($Checkpoint.Label); found $($slotDirectories.Count)."
    }
    return $active
}

function Assert-QualificationTokenCommitted {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Label
    )
    $lastRecord = Get-RegistryValueRecord 'Software\A4SMenuLifecycle' 'LastOperation'
    $last = if ($lastRecord.Present) { [string]$lastRecord.Value.Data } else { $null }
    $highWater = Get-RegistryValueRecord 'Software\A4SMenuLifecycle' 'ServicingSequence'
    if (-not $lastRecord.Present -or [string]$lastRecord.Value.Kind -cne 'String' -or
        [string]::IsNullOrWhiteSpace($last) -or
        $last -notmatch '^(?<sequence>[0-9]{20}):(?<token>[0-9A-F]{64})$' -or
        $Matches.token -cne $Token -or -not $highWater.Present -or
        [string]$highWater.Value.Kind -cne 'QWord') {
        throw "$Label did not commit its exact qualification token and QWORD ServicingSequence."
    }
    $sequence = [UInt64]::Parse($Matches.sequence,
        [Globalization.CultureInfo]::InvariantCulture)
    $highWaterBits = [UInt64]::Parse([string]$highWater.Value.Data,
        [Globalization.CultureInfo]::InvariantCulture)
    if ($sequence -eq 0 -or $sequence -ne $highWaterBits) {
        throw "$Label LastOperation sequence does not equal ServicingSequence."
    }
    return [ordered]@{
        Sequence = $sequence.ToString([Globalization.CultureInfo]::InvariantCulture)
        Token = $Token
        Encoded = [string]$Matches.sequence + ':' + $Token
    }
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Stop-ExactProcessBounded {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ProcessId,
        [Parameter(Mandatory)][ValidateRange(100, 10000)][int] $WaitMilliseconds
    )
    $killFailure = $null
    $killAttempted = $true
    $killReturned = $false
    try {
        $Process.Kill()
        $killReturned = $true
    }
    catch { $killFailure = $_.Exception.Message }
    $exitConfirmed = $false
    try { $exitConfirmed = $Process.WaitForExit($WaitMilliseconds) }
    catch {
        if ([string]::IsNullOrWhiteSpace($killFailure)) {
            $killFailure = $_.Exception.Message
        }
    }
    return [ordered]@{
        ProcessId = $ProcessId
        KillAttempted = $killAttempted
        KillReturned = $killReturned
        ExitConfirmed = $exitConfirmed
        KillFailure = $killFailure
    }
}

function Invoke-ExactProcess {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Label,
        [ValidateRange(1, 300)][int] $TimeoutSeconds = 120,
        [ValidateRange(100, 10000)][int] $KillWaitMilliseconds = 5000,
        [ValidateRange(0, 89)][int] $StartedStageOrdinal = 0,
        [string] $StartedStage,
        [ValidateRange(0, 89)][int] $TimeoutStageOrdinal = 0,
        [string] $TimeoutStage
    )
    if (@($Arguments | Where-Object { $_ -ieq '--restart-explorer' }).Count -ne 0) {
        throw '--restart-explorer is forbidden in the Sandbox lifecycle matrix.'
    }
    if (($StartedStageOrdinal -eq 0) -ne [string]::IsNullOrWhiteSpace($StartedStage) -or
        ($StartedStageOrdinal -ne 0 -and ($StartedStageOrdinal -lt 10 -or
            $StartedStage -notmatch '^[a-z0-9-]+$')) -or
        ($TimeoutStageOrdinal -eq 0) -ne [string]::IsNullOrWhiteSpace($TimeoutStage) -or
        ($TimeoutStageOrdinal -ne 0 -and ($TimeoutStageOrdinal -lt 10 -or
            $TimeoutStage -notmatch '^[a-z0-9-]+$'))) {
        throw 'Exact-process diagnostic stage parameters are incomplete or malformed.'
    }
    $stdoutPath = Join-Path $script:workRoot "$Label.stdout.txt"
    $stderrPath = Join-Path $script:workRoot "$Label.stderr.txt"
    $started = [DateTime]::UtcNow
    $quotedArguments = @($Arguments | ForEach-Object {
        Quote-ProcessArgument ([string]$_)
    })
    $argumentLine = $quotedArguments -join ' '
    $process = $null
    $record = $null
    $childProcessId = 0
    $failureKind = $null
    try {
        $process = Start-Process -FilePath $Path -ArgumentList $argumentLine `
            -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath -PassThru
        $childProcessId = [int]$process.Id
        if ($StartedStageOrdinal -ne 0) {
            $startedDetails = @{
                Label = $Label
                ChildProcessId = $childProcessId
                TimeoutSeconds = $TimeoutSeconds
                KillWaitMilliseconds = $KillWaitMilliseconds
            }
            Write-GuestStage -Ordinal $StartedStageOrdinal -Stage $StartedStage `
                -Details $startedDetails
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $failureKind = 'timeout'
            throw [TimeoutException]::new(
                "$Label exceeded the $TimeoutSeconds second guest-only timeout.")
        }
        $record = [ordered]@{
            Label = $Label
            Path = [IO.Path]::GetFullPath($Path)
            Arguments = @($Arguments)
            StartedUtc = $started.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            DurationMilliseconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalMilliseconds, 3)
            ExitCode = [int]$process.ExitCode
            Stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { '' }
            Stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { '' }
        }
        if ($record.ExitCode -ne 0) {
            throw "$Label failed with exit code $($record.ExitCode)."
        }
    }
    catch {
        $causalError = $_
        if ($null -ne $process) {
            $cleanup = Stop-ExactProcessBounded -Process $process `
                -ProcessId $childProcessId -WaitMilliseconds $KillWaitMilliseconds
            try {
                $causalError.Exception.Data['A4SExactProcessId'] = $childProcessId
                $causalError.Exception.Data['A4SKillAttempted'] = $cleanup.KillAttempted
                $causalError.Exception.Data['A4SKillReturned'] = $cleanup.KillReturned
                $causalError.Exception.Data['A4SExitConfirmed'] = $cleanup.ExitConfirmed
                $causalError.Exception.Data['A4SKillFailure'] = $cleanup.KillFailure
            }
            catch {}
            if ($failureKind -ceq 'timeout' -and $TimeoutStageOrdinal -ne 0) {
                try {
                    Write-GuestStage -Ordinal $TimeoutStageOrdinal -Stage $TimeoutStage `
                        -Details @{
                            Label = $Label
                            ChildProcessId = $childProcessId
                            TimeoutSeconds = $TimeoutSeconds
                            KillWaitMilliseconds = $KillWaitMilliseconds
                            KillAttempted = $cleanup.KillAttempted
                            KillReturned = $cleanup.KillReturned
                            ExitConfirmed = $cleanup.ExitConfirmed
                            KillFailure = $cleanup.KillFailure
                        }
                }
                catch {
                    try {
                        $causalError.Exception.Data['A4STimeoutStagePublicationFailure'] =
                            $_.Exception.Message
                    }
                    catch {}
                }
            }
            if (-not $cleanup.ExitConfirmed) {
                $cleanupDetail = if ([string]::IsNullOrWhiteSpace($cleanup.KillFailure)) {
                    'the termination request returned without a confirmed exit'
                }
                else { [string]$cleanup.KillFailure }
                $cleanupException = [InvalidOperationException]::new(
                    "$Label failed after starting exact PID $childProcessId, and its exit was not confirmed within $KillWaitMilliseconds milliseconds ($cleanupDetail). Causal error: $($causalError.Exception.Message)",
                    $causalError.Exception)
                throw $cleanupException
            }
        }
        throw
    }
    finally {
        if ($null -ne $process) {
            try { $process.Dispose() }
            catch {}
        }
    }
    return $record
}

function Assert-SetupExtraction {
    param(
        [Parameter(Mandatory)][string] $SetupPath,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Prefix
    )
    $identity = Get-FileIdentity $SetupPath
    if ($identity.Sha256 -cne (Normalize-Sha256 ([string]$Expected.SetupSha256)) -or
        $identity.ProductVersion -cne [string]$Expected.Version -or
        $identity.OriginalFilename -cne 'A4SMenuSetup.exe') {
        throw "$Prefix setup input does not match its reviewed identity."
    }
    $version = Invoke-ExactProcess -Path $SetupPath -Arguments @('--version') `
        -Label "$Prefix-version"
    $verify = Invoke-ExactProcess -Path $SetupPath -Arguments @('--verify', '--silent') `
        -Label "$Prefix-verify"
    $extractPath = Join-Path $script:workRoot "$Prefix-extracted"
    if (Test-Path -LiteralPath $extractPath) { throw "Extract target collision: $extractPath" }
    $extract = Invoke-ExactProcess -Path $SetupPath `
        -Arguments @('--extract-test', $extractPath) -Label "$Prefix-extract"
    $payload = Get-SlotPayloadLikeExtraction -Path $extractPath
    Assert-PayloadMatches -Actual $payload -Expected $Expected -Label "$Prefix extracted"
    return [ordered]@{
        Input = $identity
        VersionProbe = $version
        VerifyProbe = $verify
        ExtractProbe = $extract
        ExtractedPayload = $payload
    }
}

function Get-SlotPayloadLikeExtraction {
    param([Parameter(Mandatory)][string] $Path)
    $children = @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name)
    if (($children.Name -join '|') -cne
        ((@('A4SMenu.dll', 'A4SMenuHost.exe', 'A4SMenuSetup.exe') | Sort-Object) -join '|')) {
        throw "Extracted payload inventory is not exact: $Path"
    }
    return [ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Menu = Get-FileIdentity (Join-Path $Path 'A4SMenu.dll')
        Host = Get-FileIdentity (Join-Path $Path 'A4SMenuHost.exe')
        Setup = Get-FileIdentity (Join-Path $Path 'A4SMenuSetup.exe')
    }
}

function Wait-ForExplorerMenuModule {
    param(
        [Parameter(Mandatory)][int] $ExplorerPid,
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [ValidateRange(5, 60)][int] $TimeoutSeconds = 20
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $inventory = Get-ExplorerModuleInventory $ExplorerPid
        if ($inventory.Complete -and @($inventory.Modules |
                Where-Object { $_.Sha256 -ceq $ExpectedSha256 }).Count -eq 1) {
            return $inventory
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The reviewed V1 DLL was not observed in the unchanged taskbar Explorer process.'
}

function Wait-ForHostExit {
    param([Parameter(Mandatory)][string] $HostPath)
    $expected = [IO.Path]::GetFullPath($HostPath)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $matching = @()
        foreach ($process in @(Get-Process -Name A4SMenuHost -ErrorAction SilentlyContinue)) {
            try {
                if ([IO.Path]::GetFullPath($process.Path).Equals($expected,
                        [StringComparison]::OrdinalIgnoreCase)) { $matching += $process }
            }
            catch {}
        }
        if ($matching.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The V1 host did not become quiescent after its authenticated --exit command.'
}

function Assert-CleanDisposableStart {
    if ((Get-RegistryTreeSnapshot 'Software\A4SMenu').Present -or
        (Get-RegistryTreeSnapshot 'Software\A4SMenuLifecycle').Present -or
        (Get-RegistryTreeSnapshot 'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu').Present -or
        (Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\Run' 'A4SMenu').Present -or
        (Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\RunOnce' '!A4SMenuCleanup').Present -or
        (Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\RunOnce' '!A4SMenuServicingRecovery').Present -or
        (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'A4SMenu')) -or
        (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'A4SMenuCleanup.exe')) -or
        @(Get-A4SProcessInventory).Count -ne 0) {
        throw 'Windows Sandbox did not start with a clean A4S product state.'
    }
    $explorerPid = Get-TaskbarExplorerPid
    $modules = Get-ExplorerModuleInventory $explorerPid
    if (-not $modules.Complete -or @($modules.Modules).Count -ne 0) {
        throw 'Windows Sandbox did not start with a clean taskbar Explorer module state.'
    }
}

function Assert-SandboxConfiguration {
    param([Parameter(Mandatory)][string] $ControlRoot)
    $path = Join-Path $ControlRoot 'A4SLegacyLifecycle.wsb'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'The host Sandbox configuration is not visible in the read-only control mapping.'
    }
    [xml]$xml = Get-Content -Raw -LiteralPath $path
    foreach ($name in @('vGPU', 'Networking', 'AudioInput', 'VideoInput',
            'PrinterRedirection', 'ClipboardRedirection')) {
        if ([string]$xml.Configuration.$name -cne 'Disable') {
            throw "Sandbox integration $name is not disabled."
        }
    }
    if ([string]$xml.Configuration.ProtectedClient -cne 'Enable') {
        throw 'ProtectedClient is not enabled.'
    }
    $expectedLogonCommand =
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\A4S\Repo\tools\Invoke-A4SLegacySandboxBootstrap.ps1"' +
        ' -GuestScriptPath "C:\A4S\Repo\tools\Invoke-A4SLegacySandboxGuest.ps1"' +
        ' -RequestPath "C:\A4S\Control\request.json" -EvidenceRoot "C:\A4S\Evidence"' +
        ' -SessionId "' + [string]$request.SessionId + '"' +
        ' -Nonce "' + [string]$request.Nonce + '"' +
        ' -RequestSha256 "' + $requestSha256 + '"' +
        ' -BootstrapScriptSha256 "' + [string]$request.HostPreflight.BootstrapScriptSha256 + '"' +
        ' -GuestScriptSha256 "' + [string]$request.HostPreflight.GuestScriptSha256 + '"'
    if ([string]$xml.Configuration.LogonCommand.Command -cne $expectedLogonCommand) {
        throw 'Sandbox LogonCommand does not name the exact reviewed guest entry point.'
    }
    $mappings = @($xml.Configuration.MappedFolders.MappedFolder)
    if ($mappings.Count -ne 3 -or
        [string]$mappings[0].SandboxFolder -cne 'C:\A4S\Repo' -or
        [string]$mappings[0].ReadOnly -cne 'true' -or
        [string]$mappings[1].SandboxFolder -cne 'C:\A4S\Control' -or
        [string]$mappings[1].ReadOnly -cne 'true' -or
        [string]$mappings[2].SandboxFolder -cne 'C:\A4S\Evidence' -or
        [string]$mappings[2].ReadOnly -cne 'false') {
        throw 'Sandbox folder mapping permissions do not match the qualification contract.'
    }
    return [ordered]@{
        Path = $path
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
        NetworkingDisabled = $true
        HostIntegrationsDisabled = $true
        RepositoryReadOnly = $true
        ControlReadOnly = $true
        EvidenceWritable = $true
        ProtectedClient = $true
    }
}

function Assert-NetworkDisabled {
    $up = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object {
            $_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up -and
            $_.NetworkInterfaceType -ne
                [Net.NetworkInformation.NetworkInterfaceType]::Loopback
        } | ForEach-Object {
            [ordered]@{ Name = $_.Name; Type = $_.NetworkInterfaceType.ToString() }
        })
    $networkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    if ($up.Count -ne 0 -or $networkAvailable) {
        throw 'An operational non-loopback network path is present in Sandbox.'
    }
    return [ordered]@{ OperationalNonLoopbackInterfaces = @(); NetworkAvailable = $false }
}

function Write-ProgressEvidence {
    if ($null -eq $script:evidence -or [string]::IsNullOrWhiteSpace($script:evidenceRoot)) { return }
    $script:evidence.LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-Utf8NoBomAtomic -Path (Join-Path $script:evidenceRoot 'progress.json') `
        -Text ($script:evidence | ConvertTo-Json -Depth 100)
}

function Assert-ContractModel {
    if (-not [Environment]::Is64BitProcess) {
        throw 'Guest contract self-test requires production-bitness x64 Windows PowerShell.'
    }
    if (($requiredMatrix -join '|') -cne
        'install-v1|update-v1-to-v2|rollback-v2-to-v1|update-v1-to-v2-again|repair-v2-same-version|uninstall-v2') {
        throw 'Guest lifecycle matrix order drifted.'
    }
    foreach ($hash in @($frozenV1SetupSha256, $frozenV1HostSha256, $frozenV1MenuSha256)) {
        Normalize-Sha256 $hash | Out-Null
    }
    $sample = [ordered]@{ Alpha = 1; Beta = @('two', 'three') }
    if ((Get-ObjectSha256 $sample) -notmatch '^[0-9A-F]{64}$') {
        throw 'Deterministic evidence hashing failed.'
    }
    $pathRequest = [pscustomobject]@{
        V1SetupRelativePath = 'build\fixtures\A4SMenuSetup-v1.exe'
        V2SetupRelativePath = 'build\reviewed product\A4SMenuSetup-v2.exe'
    }
    $resolvedSources = Resolve-GuestSetupSources -RepoRoot 'C:\A4S\Repo' `
        -Request $pathRequest
    if ([string]$resolvedSources.V1 -cne
            'C:\A4S\Repo\build\fixtures\A4SMenuSetup-v1.exe' -or
        [string]$resolvedSources.V2 -cne
            'C:\A4S\Repo\build\reviewed product\A4SMenuSetup-v2.exe') {
        throw 'Windows PowerShell setup-source cast/Join-Path contract failed.'
    }
    Write-Host 'A4S legacy Sandbox guest PS5 setup-source path contract passed.'
    $publicationRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('A4SGuestPublicationContract-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($publicationRoot) | Out-Null
    try {
        $publicationPath = Join-Path $publicationRoot 'atomic.json'
        Write-Utf8NoBomAtomic -Path $publicationPath -Text '{"contract":true}'
        if ([IO.File]::ReadAllText($publicationPath) -cne '{"contract":true}') {
            throw 'Guest atomic evidence publication contract failed.'
        }
    }
    finally {
        if ([IO.Directory]::Exists($publicationRoot)) {
            [IO.Directory]::Delete($publicationRoot, $true)
        }
    }
    Initialize-ExplorerProbe
    $windowsPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $nativeSnapshot = [A4SSandboxWindowProbe]::ModuleSnapshotForProcess($PID)
    if ([int]$nativeSnapshot.TotalModuleCount -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$nativeSnapshot.MainModulePath) -or
        -not ([IO.Path]::GetFullPath([string]$nativeSnapshot.MainModulePath)).Equals(
            [IO.Path]::GetFullPath($windowsPowerShell),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native Toolhelp contract did not prove this x64 Windows PowerShell main module.'
    }
    Write-Host 'A4S legacy Sandbox guest PS5 x64 native Toolhelp module snapshot contract passed.'
    $processContractRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('A4SGuestProcessTimeoutContract-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($processContractRoot) | Out-Null
    $script:workRoot = $processContractRoot
    try {
        $childScript = Join-Path $processContractRoot 'bounded-child.ps1'
        $childPidPath = Join-Path $processContractRoot 'bounded-child.pid'
        $childSource = @"
[IO.File]::WriteAllText('$($childPidPath.Replace("'", "''"))', [string]`$PID,
    [Text.UTF8Encoding]::new(`$false))
Start-Sleep -Seconds 30
"@
        [IO.File]::WriteAllText($childScript, $childSource,
            [Text.UTF8Encoding]::new($false))
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $timeoutRejected = $false
        $timeoutCleanupPid = 0
        try {
            Invoke-ExactProcess -Path $windowsPowerShell -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-File', $childScript) -Label 'bounded-timeout-contract' `
                -TimeoutSeconds 1 -KillWaitMilliseconds 5000 | Out-Null
        }
        catch {
            $timeoutRejected =
                $_.Exception -is [TimeoutException] -and
                $_.Exception.Message -ceq
                    'bounded-timeout-contract exceeded the 1 second guest-only timeout.' -and
                [bool]$_.Exception.Data['A4SKillAttempted'] -and
                [bool]$_.Exception.Data['A4SKillReturned'] -and
                [bool]$_.Exception.Data['A4SExitConfirmed']
            $timeoutCleanupPid = [int]$_.Exception.Data['A4SExactProcessId']
        }
        finally { $stopwatch.Stop() }
        if (-not $timeoutRejected -or $stopwatch.Elapsed.TotalSeconds -gt 8 -or
            -not [IO.File]::Exists($childPidPath)) {
            throw 'Bounded exact-process timeout contract did not fail closed in time.'
        }
        $childPid = 0
        if (-not [int]::TryParse([IO.File]::ReadAllText($childPidPath), [ref]$childPid) -or
            $childPid -le 0 -or $childPid -ne $timeoutCleanupPid -or
            $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
            throw 'Bounded exact-process timeout contract left its direct child alive.'
        }

        $stageFailureScript = Join-Path $processContractRoot 'stage-failure-child.ps1'
        [IO.File]::WriteAllText($stageFailureScript, 'Start-Sleep -Seconds 30',
            [Text.UTF8Encoding]::new($false))
        $script:evidenceRoot = $processContractRoot
        $script:expectedSessionId = '00000000-0000-0000-0000-000000000000'
        $script:expectedNonce = '0' * 64
        $script:expectedRequestSha256 = '0' * 64
        $script:expectedGuestScriptSha256 = '0' * 64
        $stageCollisionPath = Join-Path $processContractRoot `
            'stage-025-synthetic-stage-publication.json'
        [IO.File]::WriteAllText($stageCollisionPath, 'collision',
            [Text.UTF8Encoding]::new($false))
        $stageFailureStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $stageFailurePreserved = $false
        $stageFailurePid = 0
        try {
            Invoke-ExactProcess -Path $windowsPowerShell -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-File', $stageFailureScript) `
                -Label 'started-stage-failure-contract' -TimeoutSeconds 30 `
                -KillWaitMilliseconds 5000 -StartedStageOrdinal 25 `
                -StartedStage 'synthetic-stage-publication' | Out-Null
        }
        catch {
            $stageIOException = if ($_.Exception -is [IO.IOException]) {
                $_.Exception
            }
            elseif ($_.Exception.InnerException -is [IO.IOException]) {
                $_.Exception.InnerException
            }
            else { $null }
            $stageFailurePreserved =
                $null -ne $stageIOException -and
                ($stageIOException.HResult -band 0xFFFF) -eq 80 -and
                [bool]$_.Exception.Data['A4SKillAttempted'] -and
                [bool]$_.Exception.Data['A4SKillReturned'] -and
                [bool]$_.Exception.Data['A4SExitConfirmed']
            $stageFailurePid = [int]$_.Exception.Data['A4SExactProcessId']
        }
        finally { $stageFailureStopwatch.Stop() }
        if (-not $stageFailurePreserved -or
            $stageFailureStopwatch.Elapsed.TotalSeconds -gt 8 -or
            $stageFailurePid -le 0 -or
            [IO.File]::ReadAllText($stageCollisionPath) -cne 'collision') {
            throw 'Started-stage publication failure contract was not preserved and bounded.'
        }
        if ($null -ne (Get-Process -Id $stageFailurePid -ErrorAction SilentlyContinue)) {
            throw 'Started-stage publication failure contract left its direct child alive.'
        }
    }
    finally {
        if ([IO.Directory]::Exists($processContractRoot)) {
            [IO.Directory]::Delete($processContractRoot, $true)
        }
    }
    Write-Host 'A4S legacy Sandbox guest PS5 bounded process timeout contract passed.'
    Write-Host 'A4S legacy Sandbox guest PS5 started-stage failure cleanup contract passed.'
    Write-Host 'A4S legacy Sandbox guest in-memory contract passed.'
}

if ($ContractSelfTest) {
    Assert-ContractModel
    return
}

$script:evidenceRoot = 'C:\A4S\Evidence'
$script:expectedSessionId = [string]$ExpectedSessionId
$script:expectedNonce = [string]$ExpectedNonce
$script:expectedRequestSha256 = [string]$ExpectedRequestSha256
$script:expectedGuestScriptSha256 = [string]$ExpectedGuestScriptSha256
if ($script:expectedSessionId -notmatch
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
    $script:expectedNonce -notmatch '^[0-9A-F]{64}$' -or
    $script:expectedRequestSha256 -notmatch '^[0-9A-F]{64}$' -or
    $script:expectedGuestScriptSha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'The bootstrap did not supply valid guest correlation parameters.'
}
Write-GuestStage -Ordinal 10 -Stage 'guest-entry'

if ([string]::IsNullOrWhiteSpace($RequestPath)) { throw '-RequestPath is required in the Sandbox guest.' }
$sandboxIdentity = Get-WindowsSandboxIdentity
if (-not [Environment]::Is64BitProcess) { throw 'The Sandbox guest requires 64-bit PowerShell.' }
Write-GuestStage -Ordinal 11 -Stage 'identity-validated'

$requestFullPath = [IO.Path]::GetFullPath($RequestPath)
if ($requestFullPath -ine 'C:\A4S\Control\request.json') {
    throw 'The request must come from the dedicated read-only Sandbox control mapping.'
}
$requestSnapshot = Read-Utf8JsonSnapshot -Path $requestFullPath -MaximumBytes 1048576
$requestSha256 = [string]$requestSnapshot.Sha256
$request = $requestSnapshot.Value
Write-GuestStage -Ordinal 12 -Stage 'request-read'
$requestProperties = @($request.PSObject.Properties.Name | Sort-Object)
$expectedRequestProperties = @('CreatedUtc', 'ExplorerRestartAuthorized',
    'GuestControlRoot', 'GuestEvidenceRoot', 'GuestRepoRoot', 'HostPreflight',
    'Nonce', 'Purpose', 'RequiredMatrix', 'SchemaVersion', 'SessionId', 'V1',
    'V1SetupRelativePath', 'V2', 'V2SetupRelativePath') | Sort-Object
if (($requestProperties -join '|') -cne ($expectedRequestProperties -join '|')) {
    throw 'The Sandbox request has unexpected or missing top-level properties.'
}
if ([int]$request.SchemaVersion -ne 1 -or
    [string]$request.GuestRepoRoot -cne 'C:\A4S\Repo' -or
    [string]$request.GuestControlRoot -cne 'C:\A4S\Control' -or
    [string]$request.GuestEvidenceRoot -cne 'C:\A4S\Evidence' -or
    [string]$request.SessionId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
    [string]$request.Nonce -notmatch '^[0-9A-F]{64}$' -or
    [bool]$request.ExplorerRestartAuthorized -or
    [string]$request.SessionId -cne $script:expectedSessionId -or
    [string]$request.Nonce -cne $script:expectedNonce -or
    $requestSha256 -cne $script:expectedRequestSha256 -or
    (@($request.RequiredMatrix) -join '|') -cne ($requiredMatrix -join '|')) {
    throw 'The Sandbox request schema or fixed matrix is invalid.'
}
if ([string]$request.V1.Version -cne '1.0.0.0' -or
    [string]$request.V1.SetupSha256 -cne $frozenV1SetupSha256 -or
    [string]$request.V1.HostSha256 -cne $frozenV1HostSha256 -or
    [string]$request.V1.MenuSha256 -cne $frozenV1MenuSha256 -or
    [string]$request.V2.Version -cne '1.1.0.0') {
    throw 'The request does not name the frozen V1 and reviewed V2 version contract.'
}
Write-GuestStage -Ordinal 13 -Stage 'request-validated'
if ([string]$request.HostPreflight.GuestScriptSha256 -notmatch '^[0-9A-F]{64}$' -or
    [string]$request.HostPreflight.GuestScriptSha256 -cne
        $script:expectedGuestScriptSha256 -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $MyInvocation.MyCommand.Path).Hash.ToUpperInvariant() -cne
        [string]$request.HostPreflight.GuestScriptSha256) {
    throw 'The executing guest script does not match the exact host-preflight script hash.'
}
Write-GuestStage -Ordinal 14 -Stage 'script-hash-validated'
foreach ($hash in @($request.V2.SetupSha256, $request.V2.HostSha256, $request.V2.MenuSha256)) {
    Normalize-Sha256 ([string]$hash) | Out-Null
}

$repoRoot = [IO.Path]::GetFullPath([string]$request.GuestRepoRoot).TrimEnd('\')
$controlRoot = [IO.Path]::GetFullPath([string]$request.GuestControlRoot).TrimEnd('\')
$script:evidenceRoot = [IO.Path]::GetFullPath([string]$request.GuestEvidenceRoot).TrimEnd('\')
$setupSources = Resolve-GuestSetupSources -RepoRoot $repoRoot -Request $request
$v1Source = [string]$setupSources.V1
$v2Source = [string]$setupSources.V2
foreach ($source in @($v1Source, $v2Source)) {
    if (-not $source.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A setup path escaped the read-only repository mapping.'
    }
}
Write-GuestStage -Ordinal 15 -Stage 'paths-resolved'

$script:workRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("A4SLegacySandbox-" + [string]$request.Nonce)
if (Test-Path -LiteralPath $script:workRoot) { throw 'Guest work-directory collision.' }
Write-GuestStage -Ordinal 16 -Stage 'workdir-create-start'
[IO.Directory]::CreateDirectory($script:workRoot) | Out-Null
Write-GuestStage -Ordinal 17 -Stage 'workdir-created'
$localV1 = Join-Path $script:workRoot 'A4SMenuSetup-1.0.0.0.exe'
$localV2 = Join-Path $script:workRoot 'A4SMenuSetup-1.1.0.0.exe'
[IO.File]::Copy($v1Source, $localV1, $false)
[IO.File]::Copy($v2Source, $localV2, $false)
Write-GuestStage -Ordinal 18 -Stage 'setup-inputs-copied'

$script:evidence = [ordered]@{
    SchemaVersion = 1
    Test = 'A4S frozen-V1 to reviewed-V2 Windows Sandbox lifecycle'
    SessionId = [string]$request.SessionId
    Nonce = [string]$request.Nonce
    RequestSha256 = $requestSha256
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Environment = $null
    Inputs = [ordered]@{ V1 = $null; V2 = $null }
    Seed = $null
    Steps = [Collections.Generic.List[object]]::new()
    FinalDisposition = $null
    Succeeded = $false
    Failure = $null
}
$failure = $null
Write-GuestStage -Ordinal 19 -Stage 'evidence-initialized'

try {
    Write-GuestStage -Ordinal 20 -Stage 'preflight-started'
    $configuration = Assert-SandboxConfiguration -ControlRoot $controlRoot
    Write-GuestStage -Ordinal 21 -Stage 'configuration-validated'
    $network = Assert-NetworkDisabled
    Write-GuestStage -Ordinal 22 -Stage 'network-validated'
    Assert-CleanDisposableStart
    Write-GuestStage -Ordinal 23 -Stage 'clean-state-validated'
    $initialExplorerPid = Get-TaskbarExplorerPid
    $script:evidence.Environment = [ordered]@{
        UserName = $env:USERNAME
        UserProfile = $env:USERPROFILE
        ComputerName = $env:COMPUTERNAME
        ProcessId = $PID
        SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        ExplorerPid = $initialExplorerPid
        Is64BitProcess = [Environment]::Is64BitProcess
        WindowsIdentity = $sandboxIdentity
        Configuration = $configuration
        Network = $network
    }
    Write-ProgressEvidence

    $script:evidence.Inputs.V1 = Assert-SetupExtraction -SetupPath $localV1 `
        -Expected $request.V1 -Prefix 'v1'
    Assert-CleanDisposableStart
    $script:evidence.Inputs.V2 = Assert-SetupExtraction -SetupPath $localV2 `
        -Expected $request.V2 -Prefix 'v2'
    Assert-CleanDisposableStart
    Write-ProgressEvidence

    Set-SentinelUserState -Nonce ([string]$request.Nonce)
    $seedUserState = Get-UserStateProjection
    $seedUserStateSha256 = Get-ObjectSha256 $seedUserState
    $script:evidence.Seed = [ordered]@{
        UserState = $seedUserState
        UserStateSha256 = $seedUserStateSha256
        CacheSeededAfterV1HostQuiescence = $true
    }

    Write-GuestStage -Ordinal 24 -Stage 'install-v1-process-starting'
    $installV1Execution = Invoke-ExactProcess -Path $localV1 `
        -Arguments @('--install', '--silent') -Label 'install-v1' `
        -StartedStageOrdinal 25 -StartedStage 'install-v1-process-started' `
        -TimeoutStageOrdinal 26 -TimeoutStage 'install-v1-process-timeout'
    Write-GuestStage -Ordinal 27 -Stage 'install-v1-process-exited'
    Write-GuestStage -Ordinal 28 -Stage 'install-v1-checkpoint-starting'
    $installV1Checkpoint = Get-Checkpoint 'install-v1'
    Write-GuestStage -Ordinal 29 -Stage 'install-v1-checkpoint-captured'
    Assert-ExplorerUnchanged $installV1Checkpoint $initialExplorerPid
    if ((Get-ObjectSha256 $installV1Checkpoint.UserState) -cne $seedUserStateSha256) {
        throw 'Frozen V1 install changed seeded Config/Menu/legacy user state.'
    }
    $v1ActivePath = Get-RegistryString 'Software\A4SMenu' 'ActiveSlot'
    $v1Payload = Get-SlotPayload $v1ActivePath
    Assert-PayloadMatches $v1Payload $request.V1 'install-v1 active'
    $v1Mapping = Wait-ForExplorerMenuModule -ExplorerPid $initialExplorerPid `
        -ExpectedSha256 ([string]$request.V1.MenuSha256)
    $v1HostPath = Join-Path $v1ActivePath 'A4SMenuHost.exe'
    $v1Status = Invoke-ExactProcess -Path $v1HostPath `
        -Arguments @('--status') -Label 'v1-host-status'
    $v1Exit = Invoke-ExactProcess -Path $v1HostPath -Arguments @('--exit') `
        -Label 'v1-host-exit'
    Wait-ForHostExit $v1HostPath
    # The legacy injected DLL cannot be unloaded without replacing Explorer.
    # Give its one-shot preload worker time to settle before establishing the
    # cache bytes whose installer preservation is measured below.
    Start-Sleep -Milliseconds 3100

    $cacheBytes = [Text.Encoding]::UTF8.GetBytes(
        ('A4S-SANDBOX-CACHE-V1-BASELINE:' + [string]$request.Nonce + ':' + ('x' * 512)))
    $cachePath = Join-Path $env:LOCALAPPDATA 'A4SMenu\DataCache.db'
    [IO.File]::WriteAllBytes($cachePath, $cacheBytes)
    $cacheBaseline = Get-DataCacheRecord
    $cacheSha256 = [string]$cacheBaseline.Sha256
    Start-Sleep -Milliseconds 1000
    if ([string](Get-DataCacheRecord).Sha256 -cne $cacheSha256) {
        throw 'DataCache.db did not remain quiescent after the V1 host exited.'
    }
    $installV1Checkpoint = Get-Checkpoint 'install-v1-host-quiescent-cache-baseline'
    Assert-InstalledCheckpoint -Checkpoint $installV1Checkpoint -ExpectedActive $request.V1 `
        -ExpectedPrevious $null -ExpectedSlotCount 1 -InitialExplorerPid $initialExplorerPid `
        -ExpectedUserStateSha256 $seedUserStateSha256 -ExpectedCacheSha256 $cacheSha256 | Out-Null
    $script:evidence.Steps.Add([ordered]@{
        Name = 'install-v1'
        Execution = $installV1Execution
        HostStatus = $v1Status
        HostExit = $v1Exit
        ExplorerMapping = $v1Mapping
        Checkpoint = $installV1Checkpoint
    })
    Write-ProgressEvidence

    $updateToken1 = Get-RandomHex
    $update1 = Invoke-ExactProcess -Path $localV2 `
        -Arguments @('--update', '--silent', '--qualification-operation-token', $updateToken1) `
        -Label 'update-v1-to-v2'
    $update1Checkpoint = Get-Checkpoint 'update-v1-to-v2'
    $updateIdentity1 = Assert-QualificationTokenCommitted -Token $updateToken1 `
        -Label 'update-v1-to-v2'
    $v2Active = Assert-InstalledCheckpoint -Checkpoint $update1Checkpoint `
        -ExpectedActive $request.V2 -ExpectedPrevious $request.V1 -ExpectedSlotCount 2 `
        -InitialExplorerPid $initialExplorerPid -ExpectedUserStateSha256 $seedUserStateSha256 `
        -ExpectedCacheSha256 $cacheSha256
    $v2ActivePath = $v2Active.Path
    $script:evidence.Steps.Add([ordered]@{
        Name = 'update-v1-to-v2'; QualificationToken = $updateToken1
        QualificationIdentity = $updateIdentity1
        Execution = $update1; Checkpoint = $update1Checkpoint
    })
    Write-ProgressEvidence

    $rollbackToken = Get-RandomHex
    $rollback = Invoke-ExactProcess -Path (Join-Path $v2ActivePath 'A4SMenuSetup.exe') `
        -Arguments @('--rollback', '--silent', '--qualification-operation-token', $rollbackToken) `
        -Label 'rollback-v2-to-v1'
    $rollbackCheckpoint = Get-Checkpoint 'rollback-v2-to-v1'
    $rollbackIdentity = Assert-QualificationTokenCommitted -Token $rollbackToken `
        -Label 'rollback-v2-to-v1'
    Assert-InstalledCheckpoint -Checkpoint $rollbackCheckpoint -ExpectedActive $request.V1 `
        -ExpectedPrevious $request.V2 -ExpectedSlotCount 2 -InitialExplorerPid $initialExplorerPid `
        -ExpectedUserStateSha256 $seedUserStateSha256 -ExpectedCacheSha256 $cacheSha256 | Out-Null
    $script:evidence.Steps.Add([ordered]@{
        Name = 'rollback-v2-to-v1'; QualificationToken = $rollbackToken
        QualificationIdentity = $rollbackIdentity
        Execution = $rollback; Checkpoint = $rollbackCheckpoint
    })
    Write-ProgressEvidence

    $updateToken2 = Get-RandomHex
    $update2 = Invoke-ExactProcess -Path $localV2 `
        -Arguments @('--update', '--silent', '--qualification-operation-token', $updateToken2) `
        -Label 'update-v1-to-v2-again'
    $update2Checkpoint = Get-Checkpoint 'update-v1-to-v2-again'
    $updateIdentity2 = Assert-QualificationTokenCommitted -Token $updateToken2 `
        -Label 'update-v1-to-v2-again'
    $v2ActiveAgain = Assert-InstalledCheckpoint -Checkpoint $update2Checkpoint `
        -ExpectedActive $request.V2 -ExpectedPrevious $request.V1 -ExpectedSlotCount 2 `
        -InitialExplorerPid $initialExplorerPid -ExpectedUserStateSha256 $seedUserStateSha256 `
        -ExpectedCacheSha256 $cacheSha256
    if (-not $v2ActiveAgain.Path.Equals($v2ActivePath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The second V2 update did not return to the exact reviewed immutable V2 slot.'
    }
    $script:evidence.Steps.Add([ordered]@{
        Name = 'update-v1-to-v2-again'; QualificationToken = $updateToken2
        QualificationIdentity = $updateIdentity2
        Execution = $update2; Checkpoint = $update2Checkpoint
    })
    Write-ProgressEvidence

    $repairToken = Get-RandomHex
    $repairSetup = Join-Path $v2ActiveAgain.Path 'A4SMenuSetup.exe'
    $repair = Invoke-ExactProcess -Path $repairSetup `
        -Arguments @('--repair', '--silent', '--qualification-operation-token', $repairToken) `
        -Label 'repair-v2-same-version'
    $repairCheckpoint = Get-Checkpoint 'repair-v2-same-version'
    $repairIdentity = Assert-QualificationTokenCommitted -Token $repairToken `
        -Label 'repair-v2-same-version'
    $repairedActive = Assert-InstalledCheckpoint -Checkpoint $repairCheckpoint `
        -ExpectedActive $request.V2 -ExpectedPrevious $request.V1 -ExpectedSlotCount 2 `
        -InitialExplorerPid $initialExplorerPid -ExpectedUserStateSha256 $seedUserStateSha256 `
        -ExpectedCacheSha256 $cacheSha256
    if (-not $repairedActive.Path.Equals($v2ActiveAgain.Path,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Same-version repair changed the valid immutable V2 active slot.'
    }
    $script:evidence.Steps.Add([ordered]@{
        Name = 'repair-v2-same-version'; QualificationToken = $repairToken
        QualificationIdentity = $repairIdentity
        Execution = $repair; Checkpoint = $repairCheckpoint
    })
    Write-ProgressEvidence

    $uninstallToken = Get-RandomHex
    $uninstall = Invoke-ExactProcess -Path $repairSetup `
        -Arguments @('--uninstall', '--silent', '--qualification-operation-token', $uninstallToken) `
        -Label 'uninstall-v2'
    Start-Sleep -Milliseconds 750
    $uninstallCheckpoint = Get-Checkpoint 'uninstall-v2-logical-pending-explorer-exit'
    $uninstallIdentity = Assert-QualificationTokenCommitted -Token $uninstallToken `
        -Label 'uninstall-v2'
    Assert-ExplorerUnchanged $uninstallCheckpoint $initialExplorerPid
    Assert-NoServicingJournal -Checkpoint $uninstallCheckpoint -Label 'uninstall-v2'
    Assert-UserStateAndCache -Checkpoint $uninstallCheckpoint `
        -ExpectedUserStateSha256 $seedUserStateSha256 -ExpectedCacheSha256 $cacheSha256
    foreach ($name in @('ActiveSlot', 'PreviousSlot', 'InstallVersion')) {
        if ((Get-RegistryValueRecord 'Software\A4SMenu' $name).Present) {
            throw "Logical uninstall retained installer-owned value $name."
        }
    }
    if ((Get-RegistryValueRecord 'Software\Microsoft\Windows\CurrentVersion\Run' 'A4SMenu').Present) {
        throw 'Logical uninstall retained the A4SMenu Run value.'
    }
    if (-not $uninstallCheckpoint.CleanupRunOnce.Present -or
        $uninstallCheckpoint.RecoveryRunOnce.Present) {
        throw 'Logical uninstall did not leave exactly the expected deferred-cleanup continuation.'
    }
    $expectedCleanupRunOnce = '"' +
        (Join-Path ([IO.Path]::GetTempPath()) 'A4SMenuCleanup.exe') +
        '" --cleanup --silent --cleanup-identity ' + [string]$uninstallIdentity.Encoded
    if ([string]$uninstallCheckpoint.CleanupRunOnce.Value.Kind -cne 'String' -or
        [string]$uninstallCheckpoint.CleanupRunOnce.Value.Data -cne $expectedCleanupRunOnce) {
        throw 'Logical uninstall did not leave the exact identity-bound cleanup RunOnce command.'
    }
    if ($uninstallCheckpoint.Uninstall.Present) {
        throw 'Logical uninstall retained its Windows Settings uninstall registration.'
    }
    $cleanupHelper = Get-FileIdentity (Join-Path ([IO.Path]::GetTempPath()) 'A4SMenuCleanup.exe')
    if ($cleanupHelper.Sha256 -cne (Normalize-Sha256 ([string]$request.V2.SetupSha256)) -or
        $cleanupHelper.ProductVersion -cne [string]$request.V2.Version) {
        throw 'Deferred cleanup helper is not the exact reviewed V2 setup payload.'
    }
    if (@($uninstallCheckpoint.Processes | Where-Object { $_.Name -ieq 'A4SMenuHost' }).Count -ne 0) {
        throw 'A host process remains after logical uninstall.'
    }
    $script:evidence.Steps.Add([ordered]@{
        Name = 'uninstall-v2'; QualificationToken = $uninstallToken
        QualificationIdentity = $uninstallIdentity
        Execution = $uninstall; CleanupHelper = $cleanupHelper
        Checkpoint = $uninstallCheckpoint
    })
    $script:evidence.FinalDisposition = [ordered]@{
        State = 'LogicallyUninstalledPhysicalCleanupPendingExplorerExit'
        Reason = 'The V1 DLL remains mapped in the unchanged Explorer; --restart-explorer is forbidden.'
        ExplorerPid = $initialExplorerPid
        ExplorerRestarted = $false
        UserStateAndCacheStillExactWhileCleanupPending = $true
        SandboxDisposalBoundary = 'All guest state is discarded when Windows Sandbox is closed.'
    }
    $script:evidence.Succeeded = $true
}
catch {
    $failure = $_
    $script:evidence.Failure = [ordered]@{
        Message = $_.Exception.Message
        Category = [string]$_.CategoryInfo.Category
        ScriptStackTrace = $_.ScriptStackTrace
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
    }
    try { $script:evidence.FailureCheckpoint = Get-Checkpoint 'failure' } catch {}
}
finally {
    $script:evidence.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $script:evidence.LastUpdatedUtc = $script:evidence.CompletedUtc
    $evidencePath = Join-Path $script:evidenceRoot 'evidence.json'
    Write-Utf8NoBomAtomic -Path $evidencePath `
        -Text ($script:evidence | ConvertTo-Json -Depth 100)
    $evidenceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToUpperInvariant()
    $completion = [ordered]@{
        SchemaVersion = 1
        SessionId = [string]$request.SessionId
        Nonce = [string]$request.Nonce
        RequestSha256 = $requestSha256
        Status = if ($script:evidence.Succeeded) { 'Passed' } else { 'Failed' }
        EvidenceFile = 'evidence.json'
        EvidenceSha256 = $evidenceSha256
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-Utf8NoBomAtomic -Path (Join-Path $script:evidenceRoot 'completion.json') `
        -Text ($completion | ConvertTo-Json -Depth 20)
}

if ($null -ne $failure) { throw $failure }
Write-Host 'A4S legacy Windows Sandbox lifecycle matrix passed.'
