[CmdletBinding(DefaultParameterSetName = 'Offline')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Isolated')]
    [switch] $RunIsolatedDllFailures,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [switch] $IUnderstandThisWillForceCrashExplorerThreeTimesAndRestartItForCleanup,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [ValidateSet('I ACCEPT FOUR EXPLORER TERMINATIONS: THREE GUARDED CRASHES AND ONE CLEANUP RESTART')]
    [string] $ConfirmationText,

    [Parameter(Mandatory, ParameterSetName = 'Recover')]
    [switch] $RecoverHostSafety,

    [Parameter(Mandatory, ParameterSetName = 'Recover')]
    [string] $RecoveryBundle,

    [Parameter(Mandatory, ParameterSetName = 'Isolated')]
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $HostPath,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $DllPath,

    [Parameter(ParameterSetName = 'Isolated')]
    [Parameter(ParameterSetName = 'Live')]
    [string] $EvidencePath,

    [Parameter(ParameterSetName = 'Isolated')]
    [Parameter(ParameterSetName = 'Live')]
    [ValidateRange(15, 60)]
    [int] $HostFailureTimeoutSeconds = 20,

    [Parameter(ParameterSetName = 'Live')]
    [ValidateRange(10, 90)]
    [int] $ReconnectTimeoutSeconds = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$hostSafetySubKey = 'Software\A4SMenu\HostSafety'
$hostSafetyRegPath = 'HKCU\Software\A4SMenu\HostSafety'
$hostSafetyRegistryView = [Microsoft.Win32.RegistryView]::Registry64
$serviceNotActive = 1062
$hostStatusReadyExit = 0
$hostStatusFailed = 4
$hostStatusSafetyDisabled = 6
$crashThreshold = 3
$crashWindowSeconds = 180
$script:Evidence = $null
$script:EvidenceFile = $null
$script:HarnessLease = $null
$script:TrackedHosts = [Collections.ArrayList]::new()

function Initialize-A4SFailureRecoveryNative {
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run executable qualification from 64-bit PowerShell so the x64 taskbar Explorer module list is authoritative.'
    }
    if (-not ('A4SFailureRecoveryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class A4SFailureRecoveryNative
{
    public sealed class PathRecord
    {
        public string FinalPath { get; set; }
        public string Identity { get; set; }
        public uint Attributes { get; set; }
        public uint DriveType { get; set; }
        public string DosDeviceTarget { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindowW(string className, string windowName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr window, StringBuilder className, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileExW(string existingName, string newName, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access,
        uint share, IntPtr security, uint creation, uint flags, IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file,
        StringBuilder path, uint count, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file,
        out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string path);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetDriveTypeW(string rootPathName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint QueryDosDeviceW(string deviceName, StringBuilder target,
        int maxLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle,
        uint processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess,
        out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int tokenClass,
        IntPtr information, int informationLength, out int returnLength);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private const uint INVALID_FILE_ATTRIBUTES = 0xffffffff;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;

    private static string StripExtendedPrefix(string path)
    {
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
            return @"\\" + path.Substring(8);
        if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
            return path.Substring(4);
        return path;
    }

    private static void RejectReparseComponents(string path)
    {
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full);
        string relative = full.Substring(root.Length);
        string current = root.TrimEnd(Path.DirectorySeparatorChar);
        foreach (string component in relative.Split(new[]{Path.DirectorySeparatorChar},
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = current.Length == 2 && current[1] == ':'
                ? current + Path.DirectorySeparatorChar + component
                : Path.Combine(current, component);
            uint attributes = GetFileAttributesW(current);
            if (attributes == INVALID_FILE_ATTRIBUTES)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not inspect path component: " + current);
            if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                throw new InvalidOperationException("Reparse points are forbidden: " + current);
        }
    }

    public static PathRecord InspectExistingPath(string path)
    {
        string requested = Path.GetFullPath(path);
        if (requested.StartsWith(@"\\", StringComparison.Ordinal))
            throw new InvalidOperationException("UNC paths are forbidden: " + requested);
        RejectReparseComponents(requested);
        const uint FILE_READ_ATTRIBUTES = 0x80;
        const uint SHARE_ALL = 0x1 | 0x2 | 0x4;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        using (SafeFileHandle file = CreateFileW(requested, FILE_READ_ATTRIBUTES,
            SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS,
            IntPtr.Zero))
        {
            if (file.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not open path for final-handle validation: " + requested);
            StringBuilder finalName = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(file, finalName,
                (uint)finalName.Capacity, 0);
            if (length == 0 || length >= finalName.Capacity)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not obtain a final path: " + requested);
            string finalPath = Path.GetFullPath(StripExtendedPrefix(finalName.ToString()));
            if (finalPath.StartsWith(@"\\", StringComparison.Ordinal))
                throw new InvalidOperationException("Network final paths are forbidden: " + finalPath);
            RejectReparseComponents(finalPath);
            string root = Path.GetPathRoot(finalPath);
            uint driveType = GetDriveTypeW(root);
            if (driveType != 3)
                throw new InvalidOperationException("Path is not on a fixed local volume: " + finalPath);
            string drive = root.TrimEnd(Path.DirectorySeparatorChar);
            StringBuilder device = new StringBuilder(32768);
            if (QueryDosDeviceW(drive, device, device.Capacity) == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not validate DOS device mapping for " + drive);
            string deviceTarget = device.ToString();
            if (deviceTarget.StartsWith(@"\??\", StringComparison.OrdinalIgnoreCase) ||
                deviceTarget.IndexOf("LanmanRedirector", StringComparison.OrdinalIgnoreCase) >= 0 ||
                deviceTarget.IndexOf("Mup", StringComparison.OrdinalIgnoreCase) >= 0 ||
                !deviceTarget.StartsWith(@"\Device\HarddiskVolume", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Mapped, SUBST, or network drives are forbidden: " + drive);
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(file, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not obtain path identity: " + finalPath);
            return new PathRecord {
                FinalPath = finalPath,
                Identity = String.Format("{0:X8}:{1:X8}:{2:X8}",
                    info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow),
                Attributes = info.FileAttributes,
                DriveType = driveType,
                DosDeviceTarget = deviceTarget
            };
        }
    }

    public static string GetProcessOwnerSid(uint processId)
    {
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        const uint TOKEN_QUERY = 0x8;
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not open process " + processId + " for owner validation.");
        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not open process token for " + processId + ".");
            try
            {
                int needed;
                GetTokenInformation(token, 1, IntPtr.Zero, 0, out needed);
                IntPtr buffer = Marshal.AllocHGlobal(needed);
                try
                {
                    if (!GetTokenInformation(token, 1, buffer, needed, out needed))
                        throw new Win32Exception(Marshal.GetLastWin32Error(),
                            "Could not read process token owner for " + processId + ".");
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    return new SecurityIdentifier(sid).Value;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }

    public static uint GetTaskbarProcessId()
    {
        IntPtr taskbar = FindWindowW("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero)
            throw new InvalidOperationException("Shell_TrayWnd was not found.");
        uint processId;
        if (GetWindowThreadProcessId(taskbar, out processId) == 0 || processId == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not resolve the taskbar Explorer process.");
        return processId;
    }

    public static uint GetHostWindowProcessId()
    {
        IntPtr window = FindWindowW("A4SMenu.Host.Window.v1", "A4SMenuHost");
        if (window == IntPtr.Zero)
            return 0;
        uint processId;
        if (GetWindowThreadProcessId(window, out processId) == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not resolve the A4S host singleton window process.");
        return processId;
    }

    public static int CountVisibleMenuWindows(uint expectedProcessId)
    {
        int count = 0;
        if (!EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window))
                return true;
            uint ownerProcessId;
            StringBuilder className = new StringBuilder(256);
            if (GetWindowThreadProcessId(window, out ownerProcessId) != 0 &&
                ownerProcessId == expectedProcessId &&
                GetClassNameW(window, className, className.Capacity) > 0 &&
                String.Equals(className.ToString(), "A4SMenu.CMenuContainer",
                    StringComparison.Ordinal))
                count++;
            return true;
        }, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not enumerate top-level windows.");
        return count;
    }

    public static void ReplaceFileAtomically(string source, string destination)
    {
        const uint MOVEFILE_REPLACE_EXISTING = 0x1;
        const uint MOVEFILE_WRITE_THROUGH = 0x8;
        if (!MoveFileExW(source, destination,
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not atomically publish the evidence file.");
    }

    public static bool IsLoadableNonProductDll(string path)
    {
        const uint LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x100;
        const uint LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x800;
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (module == IntPtr.Zero)
            return false;
        try
        {
            return GetProcAddress(module, "A4SMenu_GetApi") == IntPtr.Zero &&
                GetProcAddress(module, "A4SMenu_HookInject") == IntPtr.Zero;
        }
        finally
        {
            FreeLibrary(module);
        }
    }
}
'@
    }
}

function Get-UtcText {
    return [DateTime]::UtcNow.ToString('o')
}

function Resolve-RegularFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description
    )

    $record = Get-CanonicalPathRecord -Path $Path -Description $Description -Kind File
    return $record.finalPath
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent
    )

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $candidate.Length -gt $root.Length -and
        $candidate.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathsOverlap {
    param(
        [Parameter(Mandatory)][string] $First,
        [Parameter(Mandatory)][string] $Second
    )
    $firstFull = [IO.Path]::GetFullPath($First).TrimEnd('\')
    $secondFull = [IO.Path]::GetFullPath($Second).TrimEnd('\')
    return [StringComparer]::OrdinalIgnoreCase.Equals($firstFull, $secondFull) -or
        (Test-PathWithin -Path $firstFull -Parent $secondFull) -or
        (Test-PathWithin -Path $secondFull -Parent $firstFull)
}

function Assert-NoShortPathAlias {
    param([Parameter(Mandatory)][string] $Path)
    if ($Path -match '(?i)(^|\\)[^\\]*~[0-9]+(?:\\|$)') {
        throw "8.3 short-path aliases are forbidden: $Path"
    }
}

function Get-CanonicalPathRecord {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description,
        [ValidateSet('File', 'Directory', 'Either')][string] $Kind = 'Either'
    )

    Assert-NoShortPathAlias -Path $Path
    $requested = [IO.Path]::GetFullPath($Path)
    $native = [A4SFailureRecoveryNative]::InspectExistingPath($requested)
    Assert-NoShortPathAlias -Path $native.FinalPath
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
        $requested.TrimEnd('\'), $native.FinalPath.TrimEnd('\'))) {
        throw "$Description does not resolve to its literal final-handle path: '$requested' -> '$($native.FinalPath)'."
    }
    $isDirectory = ([uint32]$native.Attributes -band 0x10) -ne 0
    if (($Kind -eq 'File' -and $isDirectory) -or
        ($Kind -eq 'Directory' -and -not $isDirectory)) {
        throw "$Description has the wrong filesystem kind: $requested"
    }
    return [pscustomobject][ordered]@{
        finalPath = $native.FinalPath
        identity = $native.Identity
        attributes = [uint32]$native.Attributes
        driveType = [uint32]$native.DriveType
        dosDeviceTarget = $native.DosDeviceTarget
        kind = if ($isDirectory) { 'directory' } else { 'file' }
    }
}

function Assert-PathOutsideRepository {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description
    )
    $repo = Get-CanonicalPathRecord -Path $repoRoot -Description 'source repository' -Kind Directory
    if (Test-PathsOverlap -First $Path -Second $repo.finalPath) {
        throw "$Description must not overlap the source repository: $Path"
    }
}

function New-SafeFreshDirectory {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory)][string] $ExpectedParent
    )

    $parent = Get-CanonicalPathRecord -Path $ExpectedParent `
        -Description "$Description parent" -Kind Directory
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoShortPathAlias -Path $fullPath
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
        (Split-Path -Parent $fullPath).TrimEnd('\'), $parent.finalPath.TrimEnd('\'))) {
        throw "$Description must be a direct child of its validated parent: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        throw "$Description must be fresh and absent: $fullPath"
    }
    [void](New-Item -ItemType Directory -LiteralPath $fullPath -ErrorAction Stop)
    $created = Get-CanonicalPathRecord -Path $fullPath -Description $Description -Kind Directory
    if (-not (Test-PathWithin -Path $created.finalPath -Parent $parent.finalPath)) {
        throw "$Description escaped its validated parent after creation: $($created.finalPath)"
    }
    Assert-PathOutsideRepository -Path $created.finalPath -Description $Description
    return $created
}

function Assert-SafeTemporaryRoot {
    param([Parameter(Mandatory)][object] $Root)

    $tempRoot = Get-CanonicalPathRecord -Path ([IO.Path]::GetTempPath()) `
        -Description 'OS temporary directory' -Kind Directory
    $current = Get-CanonicalPathRecord -Path ([string]$Root.finalPath) `
        -Description 'A4S temporary root' -Kind Directory
    if (-not (Test-PathWithin -Path $current.finalPath -Parent $tempRoot.finalPath)) {
        throw "Refusing a temporary operation outside the final OS temporary directory: $($current.finalPath)"
    }
    if ([IO.Path]::GetFileName($current.finalPath) -notlike 'A4SFailureRecovery-*') {
        throw "Refusing a temporary operation without the A4SFailureRecovery prefix: $($current.finalPath)"
    }
    if (-not [StringComparer]::Ordinal.Equals([string]$Root.identity, $current.identity) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [string]$Root.finalPath, $current.finalPath)) {
        throw 'The temporary root path identity changed after it was created.'
    }
    return $current
}

function New-A4STemporaryRoot {
    $temp = Get-CanonicalPathRecord -Path ([IO.Path]::GetTempPath()) `
        -Description 'OS temporary directory' -Kind Directory
    $path = Join-Path $temp.finalPath ('A4SFailureRecovery-' + [Guid]::NewGuid().ToString('N'))
    return New-SafeFreshDirectory -Path $path -Description 'A4S temporary root' `
        -ExpectedParent $temp.finalPath
}

function Remove-A4STemporaryRoot {
    param([Parameter(Mandatory)][object] $Root)

    $safe = Assert-SafeTemporaryRoot -Root $Root
    $children = @(Get-ChildItem -LiteralPath $safe.finalPath -Force -Recurse -ErrorAction Stop)
    foreach ($child in $children) {
        $kind = if ($child.PSIsContainer) { 'Directory' } else { 'File' }
        $validated = Get-CanonicalPathRecord -Path $child.FullName `
            -Description 'temporary cleanup descendant' -Kind $kind
        if (-not (Test-PathWithin -Path $validated.finalPath -Parent $safe.finalPath)) {
            throw "Temporary cleanup descendant escaped the validated root: $($validated.finalPath)"
        }
    }
    $safeAgain = Assert-SafeTemporaryRoot -Root $Root
    if ($safeAgain.identity -cne $safe.identity -or
        $safeAgain.finalPath -ine $safe.finalPath) {
        throw 'The temporary root changed after descendant validation.'
    }
    # This is the sole recursive deletion in the harness. The root handle identity
    # and every descendant final path were revalidated immediately above.
    Remove-Item -LiteralPath $safe.finalPath -Recurse -Force -ErrorAction Stop
}

function Write-DurableNewText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoShortPathAlias -Path $fullPath
    $parent = Get-CanonicalPathRecord -Path (Split-Path -Parent $fullPath) `
        -Description 'new durable asset parent' -Kind Directory
    if (Test-Path -LiteralPath $fullPath) {
        throw "Refusing to overwrite a recovery asset: $fullPath"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    $created = Get-CanonicalPathRecord -Path $fullPath -Description 'new durable asset' -Kind File
    if (-not (Test-PathWithin -Path $created.finalPath -Parent $parent.finalPath)) {
        throw "Durable asset escaped its validated parent: $($created.finalPath)"
    }
}

function Write-DurableText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text
    )

    $destination = Get-CanonicalPathRecord -Path $Path `
        -Description 'durable evidence destination' -Kind File
    $directory = Split-Path -Parent $destination.finalPath
    $temporary = Join-Path $directory ('.a4s-atomic-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-DurableNewText -Path $temporary -Text $Text
        [A4SFailureRecoveryNative]::ReplaceFileAtomically($temporary, $destination.finalPath)
        $published = Get-CanonicalPathRecord -Path $destination.finalPath `
            -Description 'published evidence destination' -Kind File
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $published.finalPath, $destination.finalPath)) {
            throw 'Atomic evidence publication changed the final target path.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-Evidence {
    if ($null -eq $script:Evidence -or [string]::IsNullOrWhiteSpace($script:EvidenceFile)) {
        return
    }
    $script:Evidence.updatedUtc = Get-UtcText
    $json = $script:Evidence | ConvertTo-Json -Depth 16
    Write-DurableText -Path $script:EvidenceFile -Text $json
}

function Add-EvidenceCheckpoint {
    param([Parameter(Mandatory)][object] $Checkpoint)

    [void]$script:Evidence.checkpoints.Add($Checkpoint)
    Save-Evidence
}

function New-EvidenceBundle {
    param(
        [Parameter(Mandatory)][string] $Mode,
        [string] $RequestedPath
    )

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        $base = (Get-CanonicalPathRecord -Path $env:LOCALAPPDATA `
            -Description 'LocalAppData evidence parent' -Kind Directory).finalPath
        $bundle = Join-Path $base ('A4SMenuFailureRecovery-' +
            (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
        $file = Join-Path $bundle 'evidence.json'
    }
    else {
        $file = [IO.Path]::GetFullPath($RequestedPath)
        $bundle = Split-Path -Parent $file
        $base = Split-Path -Parent $bundle
        if (-not (Test-Path -LiteralPath $base -PathType Container)) {
            throw "The custom evidence bundle parent must already exist: $base"
        }
    }
    if (Test-Path -LiteralPath $bundle) {
        throw "The evidence bundle directory must be fresh and absent: $bundle"
    }
    $temp = Get-CanonicalPathRecord -Path ([IO.Path]::GetTempPath()) `
        -Description 'OS temporary directory' -Kind Directory
    $baseRecord = Get-CanonicalPathRecord -Path $base `
        -Description 'evidence bundle parent' -Kind Directory
    if (Test-PathsOverlap -First $bundle -Second $temp.finalPath) {
        throw 'HostSafety recovery data must be durable and cannot overlap the temporary directory.'
    }
    Assert-PathOutsideRepository -Path $bundle -Description 'failure/recovery evidence bundle'
    $bundleRecord = New-SafeFreshDirectory -Path $bundle `
        -Description 'failure/recovery evidence bundle' -ExpectedParent $baseRecord.finalPath
    $script:EvidenceFile = Join-Path $bundleRecord.finalPath ([IO.Path]::GetFileName($file))
    Assert-NoShortPathAlias -Path $script:EvidenceFile
    $sourceCommit = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Out-String).Trim()
    if ($sourceCommit -notmatch '\A[A-Fa-f0-9]{40,64}\z') {
        throw 'Could not bind qualification evidence to an exact source commit.'
    }
    $script:Evidence = [ordered]@{
        schemaVersion = 2
        mode = $Mode
        startedUtc = Get-UtcText
        updatedUtc = Get-UtcText
        sourceCommit = $sourceCommit
        sourceWorktree = @(& git -C $repoRoot status --porcelain=v1 2>$null)
        harnessSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        machine = $env:COMPUTERNAME
        user = [Environment]::UserName
        userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        harnessLease = if ($script:HarnessLease) { $script:HarnessLease.name } else { $null }
        outcome = 'running'
        nativeStart = [ordered]@{
            status = 'manual-deferred'
            mechanicalPassPermitted = $false
            reason = 'The harness does not synthesize Windows-key input or claim that the native Start UI was observed.'
        }
        binaries = [ordered]@{}
        checkpoints = [Collections.ArrayList]::new()
        cases = [Collections.ArrayList]::new()
        recovery = [ordered]@{}
        errors = [Collections.ArrayList]::new()
    }
    Write-DurableNewText -Path $script:EvidenceFile `
        -Text ($script:Evidence | ConvertTo-Json -Depth 16)
    return $bundleRecord.finalPath
}

function Get-RegistryValueRecord {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key,
        [Parameter(Mandatory)][string] $Name
    )

    $kind = $Key.GetValueKind($Name)
    $value = $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $encoded = switch ($kind.ToString()) {
        'Binary' { [Convert]::ToBase64String([byte[]]$value); break }
        'None' { [Convert]::ToBase64String([byte[]]$value); break }
        'Unknown' { [Convert]::ToBase64String([byte[]]$value); break }
        'MultiString' { @([string[]]$value); break }
        'DWord' { [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$value), 0); break }
        'QWord' { [BitConverter]::ToUInt64([BitConverter]::GetBytes([int64]$value), 0); break }
        default { [string]$value; break }
    }
    return [ordered]@{ name = $Name; kind = $kind.ToString(); value = $encoded }
}

function Get-RegistryKeyTreeRecord {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key)

    $values = @($Key.GetValueNames() | Sort-Object | ForEach-Object {
        Get-RegistryValueRecord -Key $Key -Name $_
    })
    $subkeys = @($Key.GetSubKeyNames() | Sort-Object | ForEach-Object {
        $name = $_
        $child = $Key.OpenSubKey($name, $false)
        if ($null -eq $child) { throw "Registry subkey disappeared during snapshot: $name" }
        try {
            $tree = Get-RegistryKeyTreeRecord -Key $child
            [ordered]@{ name = $name; values = $tree.values; subkeys = $tree.subkeys }
        }
        finally { $child.Dispose() }
    })
    return [ordered]@{ values = $values; subkeys = $subkeys }
}

function Get-HostSafetySnapshot {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
    try {
        $key = $base.OpenSubKey($hostSafetySubKey, $false)
        if ($null -eq $key) {
            return [ordered]@{ exists = $false; values = @(); subkeys = @() }
        }
        try {
            $tree = Get-RegistryKeyTreeRecord -Key $key
            return [ordered]@{ exists = $true; values = $tree.values; subkeys = $tree.subkeys }
        }
        finally { $key.Dispose() }
    }
    finally { $base.Dispose() }
}

function Compare-HostSafetySnapshot {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )
    return (($Expected | ConvertTo-Json -Depth 8 -Compress) -ceq
        ($Actual | ConvertTo-Json -Depth 8 -Compress))
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory)][object] $Object,
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][string] $Description
    )
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join "`0") -cne ($expected -join "`0")) {
        throw "$Description has an unexpected property set: $($actual -join ', ')."
    }
}

function Assert-ValidRegistryTree {
    param(
        [Parameter(Mandatory)][object] $Tree,
        [Parameter(Mandatory)][bool] $IsRoot,
        [int] $Depth = 0
    )
    if ($Depth -gt 16) { throw 'HostSafety backup registry tree is too deep.' }
    $expected = if ($IsRoot) { @('exists', 'values', 'subkeys') } else { @('name', 'values', 'subkeys') }
    Assert-ExactPropertySet -Object $Tree -Names $expected -Description 'HostSafety snapshot node'
    if ($IsRoot) {
        if ($Tree.exists -isnot [bool]) { throw 'HostSafety snapshot exists must be Boolean.' }
        if (-not $Tree.exists -and (@($Tree.values).Count -ne 0 -or @($Tree.subkeys).Count -ne 0)) {
            throw 'An absent HostSafety snapshot cannot contain values or subkeys.'
        }
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Tree.name) -or
        [string]$Tree.name -match '[\\/]') {
        throw 'HostSafety backup contains an invalid subkey name.'
    }
    $valueNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($Tree.values)) {
        Assert-ExactPropertySet -Object $value -Names @('name', 'kind', 'value') `
            -Description 'HostSafety snapshot value'
        if ([string]$value.name -match '[\\/]') { throw 'HostSafety backup contains an invalid value name.' }
        if (-not $valueNames.Add([string]$value.name)) { throw 'HostSafety backup contains duplicate value names.' }
        $kind = [string]$value.kind
        if ($kind -notin @('None', 'Unknown', 'String', 'ExpandString', 'Binary',
                'DWord', 'MultiString', 'QWord')) {
            throw "HostSafety backup contains unsupported registry kind '$kind'."
        }
        if ($kind -in @('Binary', 'None', 'Unknown')) {
            if ($value.value -isnot [string]) {
                throw "HostSafety backup $kind value is not an encoded string."
            }
            try { [void][Convert]::FromBase64String([string]$value.value) }
            catch { throw 'HostSafety backup contains invalid Base64 registry data.' }
        }
        elseif ($kind -eq 'MultiString') {
            if ($value.value -isnot [array] -or
                @($value.value | Where-Object { $_ -isnot [string] }).Count -ne 0) {
                throw 'HostSafety backup MultiString value is not a string array.'
            }
        }
        elseif ($kind -in @('String', 'ExpandString') -and $value.value -isnot [string]) {
            throw "HostSafety backup $kind value is not a string."
        }
        elseif ($kind -in @('DWord', 'QWord')) {
            if ($value.value -is [array] -or $value.value -is [Management.Automation.PSCustomObject]) {
                throw "HostSafety backup $kind value is not scalar."
            }
            try {
                if ($kind -eq 'DWord') { [void][Convert]::ToUInt32($value.value) }
                else { [void][Convert]::ToUInt64($value.value) }
            }
            catch { throw "HostSafety backup $kind value is out of range." }
        }
    }
    $subkeyNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($subkey in @($Tree.subkeys)) {
        if (-not $subkeyNames.Add([string]$subkey.name)) { throw 'HostSafety backup contains duplicate subkey names.' }
        Assert-ValidRegistryTree -Tree $subkey -IsRoot $false -Depth ($Depth + 1)
    }
}

function Assert-RegistryExportTargetsHostSafety {
    param([Parameter(Mandatory)][string] $Path)

    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($text -notmatch '^Windows Registry Editor Version 5\.00') {
        throw 'HostSafety.reg has an unsupported registry export header.'
    }
    if ($text -match '(?m)^(?:@|"[^"]*")=-\s*$') {
        throw 'HostSafety.reg contains a registry value deletion directive.'
    }
    $headers = @([Regex]::Matches($text, '(?m)^\[([^\]]+)\]\s*$') | ForEach-Object {
        $_.Groups[1].Value
    })
    $root = 'HKEY_CURRENT_USER\Software\A4SMenu\HostSafety'
    if ($headers.Count -eq 0 -or -not ($headers -contains $root)) {
        throw 'HostSafety.reg does not contain the exact expected root key.'
    }
    foreach ($header in $headers) {
        if ($header.StartsWith('-') -or
            ($header -cne $root -and -not $header.StartsWith($root + '\',
                [StringComparison]::Ordinal))) {
            throw "HostSafety.reg targets an unexpected or deleting registry key: [$header]"
        }
    }
}

function Get-ValidatedRecoveryBundle {
    param([Parameter(Mandatory)][string] $Bundle)

    $record = Get-CanonicalPathRecord -Path $Bundle `
        -Description 'HostSafety recovery bundle' -Kind Directory
    Assert-PathOutsideRepository -Path $record.finalPath -Description 'HostSafety recovery bundle'
    $temp = Get-CanonicalPathRecord -Path ([IO.Path]::GetTempPath()) `
        -Description 'OS temporary directory' -Kind Directory
    if (Test-PathsOverlap -First $record.finalPath -Second $temp.finalPath) {
        throw 'HostSafety recovery bundles cannot overlap the temporary directory.'
    }
    return $record
}

function Read-ValidatedHostSafetyBackup {
    param([Parameter(Mandatory)][string] $Bundle)

    $bundleRecord = Get-ValidatedRecoveryBundle -Bundle $Bundle
    $manifestPath = Join-Path $bundleRecord.finalPath 'HostSafetyBackup.json'
    $manifestRecord = Get-CanonicalPathRecord -Path $manifestPath `
        -Description 'HostSafety recovery manifest' -Kind File
    if (-not (Test-PathWithin -Path $manifestRecord.finalPath -Parent $bundleRecord.finalPath)) {
        throw 'HostSafety recovery manifest escaped its bundle.'
    }
    if ((Get-Item -LiteralPath $manifestRecord.finalPath -Force).Length -gt 1048576) {
        throw 'HostSafety recovery manifest exceeds the 1 MiB safety limit.'
    }
    try { $manifest = Get-Content -LiteralPath $manifestRecord.finalPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "HostSafety recovery manifest is not valid JSON: $($_.Exception.Message)" }
    Assert-ExactPropertySet -Object $manifest -Names @('schemaVersion', 'backupId',
        'createdUtc', 'registryHive', 'registryPath', 'registrySubKey', 'registryView',
        'snapshot', 'regExport') -Description 'HostSafety recovery manifest'
    if ($manifest.schemaVersion -ne 2 -or
        [string]$manifest.registryHive -cne 'HKEY_CURRENT_USER' -or
        [string]$manifest.registryPath -cne $hostSafetyRegPath -or
        [string]$manifest.registrySubKey -cne $hostSafetySubKey -or
        [string]$manifest.registryView -cne 'Registry64') {
        throw 'HostSafety recovery manifest has an unsupported schema, hive, target, or registry view.'
    }
    $backupId = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$manifest.backupId, 'N', [ref]$backupId)) {
        throw 'HostSafety recovery manifest has an invalid backup ID.'
    }
    $created = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$manifest.createdUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$created)) {
        throw 'HostSafety recovery manifest has an invalid creation timestamp.'
    }
    if ($created.Kind -ne [DateTimeKind]::Utc) {
        throw 'HostSafety recovery manifest creation timestamp is not explicitly UTC.'
    }
    Assert-ValidRegistryTree -Tree $manifest.snapshot -IsRoot $true
    $regFile = $null
    if ([bool]$manifest.snapshot.exists) {
        if ($null -eq $manifest.regExport) { throw 'Existing HostSafety backup lacks a registry export record.' }
        Assert-ExactPropertySet -Object $manifest.regExport `
            -Names @('relativePath', 'sha256', 'length') -Description 'HostSafety registry export record'
        if ([string]$manifest.regExport.relativePath -cne 'HostSafety.reg') {
            throw 'HostSafety registry export must use the exact direct-child filename HostSafety.reg.'
        }
        if ([string]$manifest.regExport.sha256 -notmatch '\A[A-Fa-f0-9]{64}\z') {
            throw 'HostSafety registry export has an invalid SHA-256 value.'
        }
        $regFile = Join-Path $bundleRecord.finalPath 'HostSafety.reg'
        $regRecord = Get-CanonicalPathRecord -Path $regFile `
            -Description 'HostSafety registry export' -Kind File
        if (-not (Test-PathWithin -Path $regRecord.finalPath -Parent $bundleRecord.finalPath)) {
            throw 'HostSafety registry export escaped its bundle.'
        }
        $length = (Get-Item -LiteralPath $regRecord.finalPath -Force).Length
        if ($length -gt 16777216) {
            throw 'HostSafety registry export exceeds the 16 MiB safety limit.'
        }
        if ([uint64]$manifest.regExport.length -ne [uint64]$length) {
            throw 'HostSafety registry export length does not match the manifest.'
        }
        $actualHash = (Get-FileHash -LiteralPath $regRecord.finalPath -Algorithm SHA256).Hash
        if ($actualHash -cne ([string]$manifest.regExport.sha256).ToUpperInvariant()) {
            throw 'HostSafety registry export hash does not match the manifest.'
        }
        Assert-RegistryExportTargetsHostSafety -Path $regRecord.finalPath
        $regFile = $regRecord.finalPath
    }
    elseif ($null -ne $manifest.regExport) {
        throw 'Absent HostSafety backup unexpectedly contains a registry export record.'
    }
    return [pscustomobject][ordered]@{
        validated = $true
        bundle = $bundleRecord.finalPath
        bundleIdentity = $bundleRecord.identity
        manifestPath = $manifestRecord.finalPath
        manifestIdentity = $manifestRecord.identity
        manifestSha256 = (Get-FileHash -LiteralPath $manifestRecord.finalPath -Algorithm SHA256).Hash
        manifest = $manifest
        regFile = $regFile
    }
}

function Backup-HostSafety {
    param([Parameter(Mandatory)][string] $Bundle)

    $bundleRecord = Get-ValidatedRecoveryBundle -Bundle $Bundle
    $manifestPath = Join-Path $bundleRecord.finalPath 'HostSafetyBackup.json'
    $regFile = Join-Path $bundleRecord.finalPath 'HostSafety.reg'
    if ((Test-Path -LiteralPath $manifestPath) -or (Test-Path -LiteralPath $regFile)) {
        throw 'Recovery backup assets must be fresh; overwrite is forbidden.'
    }
    $snapshot = Get-HostSafetySnapshot
    $snapshotRoundTrip = $snapshot | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    Assert-ValidRegistryTree -Tree $snapshotRoundTrip -IsRoot $true
    $regExport = $null
    if ($snapshot.exists) {
        $regExe = Resolve-RegularFile -Path (Join-Path $env:SystemRoot 'System32\reg.exe') `
            -Description '64-bit Registry Console Tool'
        $output = & $regExe export $hostSafetyRegPath $regFile /reg:64 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not durably export HostSafety: $($output -join ' ')"
        }
        $regRecord = Get-CanonicalPathRecord -Path $regFile `
            -Description 'new HostSafety registry export' -Kind File
        $stream = [IO.File]::Open($regRecord.finalPath, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        Assert-RegistryExportTargetsHostSafety -Path $regRecord.finalPath
        $item = Get-Item -LiteralPath $regRecord.finalPath -Force
        $regExport = [ordered]@{
            relativePath = 'HostSafety.reg'
            sha256 = (Get-FileHash -LiteralPath $regRecord.finalPath -Algorithm SHA256).Hash
            length = [uint64]$item.Length
        }
    }
    $postExportSnapshot = Get-HostSafetySnapshot
    if (-not (Compare-HostSafetySnapshot -Expected $snapshot -Actual $postExportSnapshot)) {
        throw 'HostSafety changed while its recovery bundle was being prepared; no Explorer crash is permitted.'
    }
    $manifest = [ordered]@{
        schemaVersion = 2
        backupId = [Guid]::NewGuid().ToString('N')
        createdUtc = Get-UtcText
        registryHive = 'HKEY_CURRENT_USER'
        registryPath = $hostSafetyRegPath
        registrySubKey = $hostSafetySubKey
        registryView = 'Registry64'
        snapshot = $snapshot
        regExport = $regExport
    }
    Write-DurableNewText -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 16)
    return Read-ValidatedHostSafetyBackup -Bundle $bundleRecord.finalPath
}

function Remove-HostSafetyRegistryTree {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
    try { $base.DeleteSubKeyTree($hostSafetySubKey, $false) }
    finally { $base.Dispose() }
}

function Import-ValidatedHostSafetyBackup {
    param(
        [Parameter(Mandatory)][object] $Validated,
        [string] $ProbeHost
    )

    if ($Validated.validated -ne $true) { throw 'Unvalidated HostSafety backup cannot be imported.' }
    # Close the validation/use gap: validate the manifest, view, target, export
    # identity, length, content target, and hash again before any deletion.
    $current = Read-ValidatedHostSafetyBackup -Bundle $Validated.bundle
    if ($current.bundleIdentity -cne $Validated.bundleIdentity -or
        $current.manifestIdentity -cne $Validated.manifestIdentity -or
        $current.manifestSha256 -cne $Validated.manifestSha256) {
        throw 'HostSafety backup identity changed between validation and use.'
    }
    Assert-AllTrackedHostsStopped -ProbeHost $ProbeHost
    $beforeImport = Get-HostSafetySnapshot
    if (Compare-HostSafetySnapshot -Expected $current.manifest.snapshot -Actual $beforeImport) {
        return $beforeImport
    }
    Remove-HostSafetyRegistryTree
    if ($current.manifest.snapshot.exists) {
        $regExe = Resolve-RegularFile -Path (Join-Path $env:SystemRoot 'System32\reg.exe') `
            -Description '64-bit Registry Console Tool'
        $output = & $regExe import $current.regFile /reg:64 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not restore HostSafety.reg: $($output -join ' ')"
        }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
        $restoredKey = $base.OpenSubKey($hostSafetySubKey, $true)
        if ($null -eq $restoredKey) {
            $base.Dispose()
            throw 'HostSafety.reg import reported success but the registry key is absent.'
        }
        try { $restoredKey.Flush() } finally { $restoredKey.Dispose(); $base.Dispose() }
    }
    $restored = Get-HostSafetySnapshot
    if (-not (Compare-HostSafetySnapshot -Expected $current.manifest.snapshot -Actual $restored)) {
        throw 'HostSafety restore did not reproduce the exact pre-test value set.'
    }
    return $restored
}

function Restore-HostSafety {
    param(
        [Parameter(Mandatory)][string] $Bundle,
        [string] $ProbeHost
    )

    Assert-AllTrackedHostsStopped -ProbeHost $ProbeHost
    $validated = Read-ValidatedHostSafetyBackup -Bundle $Bundle
    $rollbackPath = Join-Path $validated.bundle ('Rollback-' + [Guid]::NewGuid().ToString('N'))
    $rollbackRecord = New-SafeFreshDirectory -Path $rollbackPath `
        -Description 'HostSafety transactional rollback bundle' -ExpectedParent $validated.bundle
    $rollback = Backup-HostSafety -Bundle $rollbackRecord.finalPath
    try {
        $restored = Import-ValidatedHostSafetyBackup -Validated $validated -ProbeHost $ProbeHost
        return [ordered]@{
            snapshot = $restored
            transaction = 'committed'
            rollbackBundle = $rollback.bundle
            rollbackManifestSha256 = $rollback.manifestSha256
        }
    }
    catch {
        $primary = $_
        try {
            Assert-AllTrackedHostsStopped -ProbeHost $ProbeHost
            [void](Import-ValidatedHostSafetyBackup -Validated $rollback)
        }
        catch {
            throw "HostSafety restore failed ('$($primary.Exception.Message)') and transactional rollback also failed ('$($_.Exception.Message)'). Both bundles were retained: '$($validated.bundle)' and '$($rollback.bundle)'."
        }
        throw "HostSafety restore failed but the exact immediate pre-restore state was rolled back successfully. Primary error: $($primary.Exception.Message). Rollback bundle retained at '$($rollback.bundle)'."
    }
}

function Get-A4SModuleRecords {
    param([Parameter(Mandatory)][uint32] $ExplorerProcessId)

    $process = [Diagnostics.Process]::GetProcessById([int]$ExplorerProcessId)
    try {
        return @($process.Modules | ForEach-Object {
            if ([IO.Path]::GetFileName($_.FileName) -ieq 'A4SMenu.dll') {
                [ordered]@{
                    path = [IO.Path]::GetFullPath($_.FileName)
                    baseAddress = ('0x{0:X}' -f $_.BaseAddress.ToInt64())
                    moduleMemorySize = $_.ModuleMemorySize
                }
            }
        })
    }
    finally { $process.Dispose() }
}

function Get-TaskbarExplorerIdentity {
    $processId = [A4SFailureRecoveryNative]::GetTaskbarProcessId()
    $process = [Diagnostics.Process]::GetProcessById([int]$processId)
    try {
        $process.Refresh()
        if ($process.HasExited -or $process.ProcessName -ine 'explorer') {
            throw "Taskbar PID $processId is not a live Explorer process."
        }
        $path = [IO.Path]::GetFullPath($process.MainModule.FileName)
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe'))
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($path, $expectedPath)) {
            throw "Taskbar PID $processId is not the canonical Windows Explorer: $path"
        }
        $currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
        if ($process.SessionId -ne $currentSession) {
            throw "Taskbar Explorer belongs to session $($process.SessionId), not current session $currentSession."
        }
        return [ordered]@{
            pid = [uint32]$process.Id
            startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            path = $path
            sessionId = $process.SessionId
        }
    }
    finally { $process.Dispose() }
}

function Assert-SameExplorerIdentity {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Expected.pid -ne $Actual.pid -or $Expected.startTimeUtc -cne $Actual.startTimeUtc) {
        throw "$Label changed Explorer identity: PID/start '$($Expected.pid)/$($Expected.startTimeUtc)' -> '$($Actual.pid)/$($Actual.startTimeUtc)'."
    }
}

function Test-A4SPathEqual {
    param(
        [Parameter(Mandatory)][string] $First,
        [Parameter(Mandatory)][string] $Second
    )
    return [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath($First), [IO.Path]::GetFullPath($Second))
}

function Enter-A4SHarnessLease {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = 'Global\A4SMenu.FailureRecoveryHarness.v2.' + $sid.Replace('-', '_')
    $created = $false
    $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0, $false) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw "Another failure/recovery harness owned by this Windows user is active in some session ($name)."
        }
        return [pscustomobject][ordered]@{ name = $name; mutex = $mutex; acquired = $true }
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Exit-A4SHarnessLease {
    param([object] $Lease)
    if ($Lease -and $Lease.acquired) {
        try { $Lease.mutex.ReleaseMutex() }
        finally { $Lease.mutex.Dispose(); $Lease.acquired = $false }
    }
}

function Get-BinaryBinding {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role,
        [switch] $QueryHostVersion
    )

    $record = Get-CanonicalPathRecord -Path $Path -Description "$Role binary" -Kind File
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($record.finalPath)
    $reported = $null
    if ($QueryHostVersion) {
        $versionResult = Invoke-A4SHostCommand -Executable $record.finalPath -Argument '--version'
        if ($versionResult.exitCode -ne 0) {
            throw "$Role --version failed with exit $($versionResult.exitCode)."
        }
        $reported = $versionResult.stdout
    }
    return [ordered]@{
        role = $Role
        path = $record.finalPath
        pathIdentity = $record.identity
        sha256 = (Get-FileHash -LiteralPath $record.finalPath -Algorithm SHA256).Hash
        length = [uint64](Get-Item -LiteralPath $record.finalPath -Force).Length
        fileVersion = $version.FileVersion
        productVersion = $version.ProductVersion
        reportedVersion = $reported
        sourceCommit = $script:Evidence.sourceCommit
    }
}

function Assert-BinaryCopyBinding {
    param(
        [Parameter(Mandatory)][object] $Source,
        [Parameter(Mandatory)][object] $Copy
    )
    if ($Source.sha256 -cne $Copy.sha256 -or $Source.length -ne $Copy.length -or
        $Source.fileVersion -cne $Copy.fileVersion -or
        $Source.productVersion -cne $Copy.productVersion) {
        throw "$($Copy.role) is not an exact version/hash copy of $($Source.role)."
    }
}

function Invoke-A4SHostCommand {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string] $Argument,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 8
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Argument
    $startInfo.WorkingDirectory = Split-Path -Parent $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process) {
        throw "Could not start '$Executable $Argument'."
    }
    [void](Register-TrackedHost -Process $process -Executable $Executable `
        -Role "command host $Argument")
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "'$Executable $Argument' did not exit within $TimeoutSeconds seconds; it was not force-killed."
        }
        Set-TrackedHostStopped -Process $process `
            -Proof "command '$Argument' exited with code $($process.ExitCode)"
        return [ordered]@{
            exitCode = $process.ExitCode
            stdout = $process.StandardOutput.ReadToEnd().Trim()
            stderr = $process.StandardError.ReadToEnd().Trim()
        }
    }
    finally { $process.Dispose() }
}

function Get-A4SHostStatus {
    param([Parameter(Mandatory)][string] $Executable)
    return Invoke-A4SHostCommand -Executable $Executable -Argument '--status'
}

function Get-SameUserA4SHostProcesses {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $records = [Collections.ArrayList]::new()
    $processes = @(Get-Process -Name 'A4SMenuHost' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try {
            $process.Refresh()
            if ($process.HasExited) { continue }
            $owner = [A4SFailureRecoveryNative]::GetProcessOwnerSid([uint32]$process.Id)
            if ($owner -cne $sid) { continue }
            $path = Get-CanonicalPathRecord -Path $process.MainModule.FileName `
                -Description "resident A4S host PID $($process.Id)" -Kind File
            [void]$records.Add([ordered]@{
                pid = $process.Id
                sessionId = $process.SessionId
                startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
                path = $path.finalPath
                pathIdentity = $path.identity
                sha256 = (Get-FileHash -LiteralPath $path.finalPath -Algorithm SHA256).Hash
            })
        }
        catch [ArgumentException] { continue }
        finally { $process.Dispose() }
    }
    return @($records)
}

function Register-TrackedHost {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string] $Role
    )
    $record = Get-CanonicalPathRecord -Path $Executable -Description "$Role executable" -Kind File
    $Process.Refresh()
    [void]$script:TrackedHosts.Add([ordered]@{
        pid = $Process.Id
        sessionId = $Process.SessionId
        startTimeUtc = $Process.StartTime.ToUniversalTime().ToString('o')
        path = $record.finalPath
        pathIdentity = $record.identity
        sha256 = (Get-FileHash -LiteralPath $record.finalPath -Algorithm SHA256).Hash
        role = $Role
        stopped = $false
        stoppedUtc = $null
        stopProof = $null
    })
    return $script:TrackedHosts[$script:TrackedHosts.Count - 1]
}

function Set-TrackedHostStopped {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [string] $Proof = 'supported --exit plus singleton/status absence'
    )
    foreach ($tracked in $script:TrackedHosts) {
        if ($tracked.pid -eq $Process.Id -and
            $tracked.startTimeUtc -ceq $Process.StartTime.ToUniversalTime().ToString('o')) {
            $tracked.stopped = $true
            $tracked.stoppedUtc = Get-UtcText
            $tracked.stopProof = $Proof
            return
        }
    }
    throw "Stopped host PID $($Process.Id) was not registered by this harness."
}

function Assert-ExactResidentHost {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string] $Label
    )
    $expectedPath = Get-CanonicalPathRecord -Path $Executable `
        -Description "$Label expected host" -Kind File
    $expectedHash = (Get-FileHash -LiteralPath $expectedPath.finalPath -Algorithm SHA256).Hash
    $resident = @(Get-SameUserA4SHostProcesses)
    if ($resident.Count -ne 1 -or $resident[0].pid -ne $Process.Id -or
        $resident[0].sessionId -ne $Process.SessionId -or
        -not (Test-A4SPathEqual -First $resident[0].path -Second $expectedPath.finalPath) -or
        $resident[0].sha256 -cne $expectedHash -or
        $resident[0].startTimeUtc -cne $Process.StartTime.ToUniversalTime().ToString('o')) {
        throw "$Label did not have exactly one same-user cross-session host with the expected PID/path/hash/start identity."
    }
    $singletonPid = [A4SFailureRecoveryNative]::GetHostWindowProcessId()
    if ($singletonPid -ne [uint32]$Process.Id) {
        throw "$Label singleton window belongs to PID $singletonPid instead of exact host PID $($Process.Id)."
    }
    return $resident[0]
}

function Assert-NoResidentA4SHost {
    param([string] $ProbeHost)

    if (-not [string]::IsNullOrWhiteSpace($ProbeHost)) {
        $status = Get-A4SHostStatus -Executable $ProbeHost
        if ($status.exitCode -ne $serviceNotActive) {
            throw "An A4S host singleton is already active (status exit $($status.exitCode), '$($status.stdout)')."
        }
    }
    $resident = @(Get-SameUserA4SHostProcesses)
    if ($resident.Count -ne 0) {
        throw "Found $($resident.Count) same-user A4SMenuHost process(es) across Windows sessions despite stopped status."
    }
    $singletonPid = [A4SFailureRecoveryNative]::GetHostWindowProcessId()
    if ($singletonPid -ne 0) {
        throw "Found an A4S host singleton window owned by PID $singletonPid despite stopped process checks."
    }
}

function Assert-AllTrackedHostsStopped {
    param([string] $ProbeHost)
    foreach ($tracked in $script:TrackedHosts) {
        $originalStillAlive = $false
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$tracked.pid)
            try {
                $process.Refresh()
                if (-not $process.HasExited -and
                    $process.StartTime.ToUniversalTime().ToString('o') -ceq $tracked.startTimeUtc) {
                    $originalStillAlive = $true
                }
            }
            finally { $process.Dispose() }
        }
        catch [ArgumentException] { }
        if ($originalStillAlive) {
            throw "Tracked $($tracked.role) PID $($tracked.pid) is still resident."
        }
        if (-not $tracked.stopped) {
            $tracked.stopped = $true
            $tracked.stoppedUtc = Get-UtcText
            $tracked.stopProof = 'original PID/start identity conclusively absent'
        }
    }
    Assert-NoResidentA4SHost -ProbeHost $ProbeHost
}

function Assert-NoA4SMapping {
    param(
        [Parameter(Mandatory)][object] $Explorer,
        [Parameter(Mandatory)][string] $Label
    )

    $mappings = @(Get-A4SModuleRecords -ExplorerProcessId $Explorer.pid)
    if ($mappings.Count -ne 0) {
        throw "$Label found an existing A4SMenu.dll mapping in Explorer PID $($Explorer.pid): $($mappings.path -join '; ')"
    }
    $windowCount = [A4SFailureRecoveryNative]::CountVisibleMenuWindows($Explorer.pid)
    if ($windowCount -ne 0) {
        throw "$Label found $windowCount visible A4S menu window(s) without an allowed injection."
    }
    return [ordered]@{ mappings = $mappings; visibleMenuWindowCount = $windowCount }
}

function Assert-CleanA4SSession {
    param([Parameter(Mandatory)][string] $ProbeHost)

    Assert-NoResidentA4SHost -ProbeHost $ProbeHost
    $explorer = Get-TaskbarExplorerIdentity
    $noInjection = Assert-NoA4SMapping -Explorer $explorer -Label 'Clean-session preflight'
    return [ordered]@{ explorer = $explorer; injection = $noInjection; hostSafety = Get-HostSafetySnapshot }
}

function Start-A4STestHost {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [string] $Arguments = '',
        [string] $Role = 'test host'
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = Split-Path -Parent $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process) {
        throw "Could not start isolated host: $Executable"
    }
    [void](Register-TrackedHost -Process $process -Executable $Executable -Role $Role)
    return $process
}

function Wait-A4SHostStatus {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][int] $ExpectedExitCode,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Diagnostics.Process] $ResidentProcess
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($ResidentProcess) {
            $ResidentProcess.Refresh()
            if ($ResidentProcess.HasExited) {
                throw "The resident test host exited unexpectedly with code $($ResidentProcess.ExitCode)."
            }
        }
        $last = Get-A4SHostStatus -Executable $Executable
        if ($last.exitCode -eq $ExpectedExitCode) {
            if ($ResidentProcess) {
                [void](Assert-ExactResidentHost -Process $ResidentProcess `
                    -Executable $Executable -Label 'host status convergence')
            }
            return $last
        }
        Start-Sleep -Milliseconds 150
    }
    $lastText = if ($last) { "exit $($last.exitCode), '$($last.stdout)'" } else { 'no status sample' }
    throw "Host did not reach expected status exit $ExpectedExitCode within $TimeoutSeconds seconds ($lastText)."
}

function Stop-A4STestHost {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][Diagnostics.Process] $ResidentProcess,
        [ValidateRange(3, 30)][int] $TimeoutSeconds = 12
    )

    $ResidentProcess.Refresh()
    if ($ResidentProcess.HasExited) {
        throw "The resident test host exited before the supported --exit boundary (code $($ResidentProcess.ExitCode))."
    }
    if (-not $ResidentProcess.HasExited) {
        $exit = Invoke-A4SHostCommand -Executable $Executable -Argument '--exit'
        if ($exit.exitCode -ne 0) {
            throw "Supported host --exit failed with exit $($exit.exitCode); the resident host was not force-killed."
        }
        if (-not $ResidentProcess.WaitForExit($TimeoutSeconds * 1000)) {
            throw 'The test host did not stop after --exit and was deliberately not force-killed.'
        }
    }
    $stopped = Get-A4SHostStatus -Executable $Executable
    if ($stopped.exitCode -ne $serviceNotActive) {
        throw "Host shutdown was not clean; --status returned $($stopped.exitCode)."
    }
    Set-TrackedHostStopped -Process $ResidentProcess
    $remaining = @(Get-SameUserA4SHostProcesses)
    if ($remaining.Count -ne 0) {
        throw 'A supported host stop completed but a same-user A4S host remains in some Windows session.'
    }
    return $stopped
}

function Get-A4SCheckpoint {
    param(
        [Parameter(Mandatory)][string] $Label,
        [string] $HostExecutable,
        [int] $KnownHostProcessId = 0
    )

    $explorer = Get-TaskbarExplorerIdentity
    $status = if ($HostExecutable) { Get-A4SHostStatus -Executable $HostExecutable } else { $null }
    $record = [ordered]@{
        utc = Get-UtcText
        label = $Label
        explorer = $explorer
        a4sMappings = @(Get-A4SModuleRecords -ExplorerProcessId $explorer.pid)
        visibleMenuWindowCount = [A4SFailureRecoveryNative]::CountVisibleMenuWindows($explorer.pid)
        host = if ($status) {
            [ordered]@{ processId = $KnownHostProcessId; statusExitCode = $status.exitCode; statusText = $status.stdout }
        } else { $null }
        hostSafety = Get-HostSafetySnapshot
    }
    $record.observedFileTimeUtc = [uint64][DateTime]::UtcNow.ToFileTimeUtc()
    return $record
}

function Wait-A4SCondition {
    param(
        [Parameter(Mandatory)][scriptblock] $Condition,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [ValidateRange(20, 1000)][int] $PollMilliseconds = 100
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    return [bool](& $Condition)
}

function Assert-ExactA4SMapping {
    param(
        [Parameter(Mandatory)][object] $Checkpoint,
        [Parameter(Mandatory)][string] $ExpectedDll
    )
    if ($Checkpoint.a4sMappings.Count -ne 1 -or
        -not (Test-A4SPathEqual -First $Checkpoint.a4sMappings[0].path -Second $ExpectedDll)) {
        throw "Expected one exact '$ExpectedDll' mapping in Explorer PID $($Checkpoint.explorer.pid); found $($Checkpoint.a4sMappings.path -join '; ')."
    }
}

function Assert-RollingCrashGuardStage {
    param(
        [Parameter(Mandatory)][object] $Snapshot,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int] $ExpectedCount,
        [Parameter(Mandatory)][bool] $ExpectedDisabled,
        [Parameter(Mandatory)][object[]] $Boundaries,
        [uint64[]] $PriorTimestamps = @()
    )

    if (-not $Snapshot.exists) {
        throw "Crash guard did not persist HostSafety after abnormal Explorer exit $ExpectedCount."
    }
    $lookup = @{}
    foreach ($record in $Snapshot.values) { $lookup[[string]$record.name] = $record }
    foreach ($name in @('InjectionDisabled', 'AbnormalExplorerExitCount',
            'AbnormalExplorerExitTimes', 'LastExplorerExitCode')) {
        if (-not $lookup.ContainsKey($name)) { throw "Crash guard omitted HostSafety value '$name'." }
    }
    foreach ($name in @('InjectionDisabled', 'AbnormalExplorerExitCount', 'LastExplorerExitCode')) {
        if ([string]$lookup[$name].kind -cne 'DWord') {
            throw "Crash guard value '$name' is not Registry DWord."
        }
    }
    if ([string]$lookup['AbnormalExplorerExitTimes'].kind -cne 'Binary') {
        throw 'Crash guard timestamps are not Registry Binary.'
    }
    $disabled = [uint32]$lookup['InjectionDisabled'].value
    $expectedDisabledValue = if ($ExpectedDisabled) { 1 } else { 0 }
    if ($disabled -ne $expectedDisabledValue -or
        [uint32]$lookup['AbnormalExplorerExitCount'].value -ne $ExpectedCount) {
        throw "The rolling crash guard did not persist exact stage $ExpectedCount/$expectedDisabledValue."
    }
    $bytes = [Convert]::FromBase64String([string]$lookup['AbnormalExplorerExitTimes'].value)
    if ($bytes.Length -ne 24) { throw 'AbnormalExplorerExitTimes is not the exact three-QWORD record.' }
    $times = @(0, 8, 16 | ForEach-Object { [BitConverter]::ToUInt64($bytes, $_) })
    if ((@($times | Select-Object -First $ExpectedCount | Where-Object { $_ -eq 0 })).Count -ne 0 -or
        (@($times | Select-Object -Skip $ExpectedCount | Where-Object { $_ -ne 0 })).Count -ne 0) {
        throw "The rolling crash timestamp occupancy does not equal stage $ExpectedCount."
    }
    $nonzero = @($times | Select-Object -First $ExpectedCount)
    for ($index = 1; $index -lt $nonzero.Count; $index++) {
        if ($nonzero[$index] -lt $nonzero[$index - 1]) {
            throw 'The rolling crash timestamps are not ordered.'
        }
    }
    if ($PriorTimestamps.Count -gt 0 -and
        (($nonzero | Select-Object -First $PriorTimestamps.Count) -join ',') -cne
        ($PriorTimestamps -join ',')) {
        throw "Crash stage $ExpectedCount rewrote an earlier observed timestamp."
    }
    if ($Boundaries.Count -ne $ExpectedCount) {
        throw "Crash stage $ExpectedCount does not have exactly $ExpectedCount observed boundaries."
    }
    for ($index = 0; $index -lt $ExpectedCount; $index++) {
        $issued = [uint64]$Boundaries[$index].issuedFileTimeUtc
        $observed = [uint64]$Boundaries[$index].observedFileTimeUtc
        if ($issued -eq 0 -or $observed -lt $issued -or
            $nonzero[$index] -lt $issued -or $nonzero[$index] -gt $observed) {
            throw "Crash timestamp $($index + 1) does not correspond to its observed termination/replacement boundary."
        }
    }
    $windowTicks = [uint64]$crashWindowSeconds * [uint64]10000000
    if ($nonzero[-1] -lt $nonzero[0] -or $nonzero[-1] - $nonzero[0] -gt $windowTicks) {
        throw "The $ExpectedCount crash timestamps do not fall inside the 180-second rolling guard window."
    }
    if ([uint32]$lookup['LastExplorerExitCode'].value -eq 0) {
        throw "Guarded Explorer termination $ExpectedCount was recorded as a clean exit."
    }
    return [ordered]@{
        expectedCount = $ExpectedCount
        disabled = [bool]$ExpectedDisabled
        timestamps100ns = $nonzero
        span100ns = $nonzero[-1] - $nonzero[0]
        boundaries = @($Boundaries)
    }
}

function Invoke-IsolatedDllFailureQualification {
    param(
        [Parameter(Mandatory)][string] $SourceHost,
        [string] $RequestedEvidencePath
    )

    $script:TrackedHosts.Clear()
    $sourceHost = Resolve-RegularFile -Path $SourceHost -Description 'A4SMenuHost test input'
    $bundle = New-EvidenceBundle -Mode 'isolated-dll-failures' -RequestedPath $RequestedEvidencePath
    $temporaryRoot = New-A4STemporaryRoot
    $initial = $null
    $backupPrepared = $false
    $hostsStopped = $false
    $noInjectionConclusive = $false
    $safetyRestored = $false
    $operationError = $null
    try {
        $sourceBinding = Get-BinaryBinding -Path $sourceHost -Role 'source A4SMenuHost' `
            -QueryHostVersion
        $script:Evidence.binaries.sourceHost = $sourceBinding
        Save-Evidence
        $initial = Assert-CleanA4SSession -ProbeHost $sourceHost
        Add-EvidenceCheckpoint ([ordered]@{
            utc = Get-UtcText
            label = 'isolated-preflight'
            explorer = $initial.explorer
            a4sMappings = @()
            visibleMenuWindowCount = 0
            host = [ordered]@{ statusExitCode = $serviceNotActive; statusText = 'stopped' }
            hostSafety = $initial.hostSafety
        })

        $backup = Backup-HostSafety -Bundle $bundle
        $backupPrepared = $true
        $script:Evidence.recovery = [ordered]@{
            bundle = $bundle
            manifest = $backup.manifestPath
            manifestSha256 = $backup.manifestSha256
            registryView = 'Registry64'
            preparedBeforeFirstHost = $true
            restored = $false
            retainedTemporaryRoot = $null
            cleanupInstructions = $null
        }
        Save-Evidence

        $caseNames = @('missing', 'corrupt', 'incompatible')
        foreach ($caseName in $caseNames) {
            $caseDirectory = New-SafeFreshDirectory `
                -Path (Join-Path $temporaryRoot.finalPath $caseName) `
                -Description "isolated $caseName case directory" `
                -ExpectedParent $temporaryRoot.finalPath
            $caseHost = Join-Path $caseDirectory.finalPath 'A4SMenuHost.exe'
            $caseDll = Join-Path $caseDirectory.finalPath 'A4SMenu.dll'
            Copy-Item -LiteralPath $sourceHost -Destination $caseHost -ErrorAction Stop
            $caseHostBinding = Get-BinaryBinding -Path $caseHost `
                -Role "isolated $caseName A4SMenuHost"
            Assert-BinaryCopyBinding -Source $sourceBinding -Copy $caseHostBinding

            if ($caseName -eq 'corrupt') {
                $bytes = [Text.Encoding]::ASCII.GetBytes(
                    'A4S deliberate corrupt-DLL qualification input')
                $stream = [IO.File]::Open($caseDll, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write, [IO.FileShare]::Read)
                try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
                finally { $stream.Dispose() }
            }
            elseif ($caseName -eq 'incompatible') {
                $systemDll = Resolve-RegularFile -Path (Join-Path $env:SystemRoot 'System32\version.dll') `
                    -Description 'known-loadable non-product DLL'
                Copy-Item -LiteralPath $systemDll -Destination $caseDll -ErrorAction Stop
                if (-not [A4SFailureRecoveryNative]::IsLoadableNonProductDll($caseDll)) {
                    throw 'The incompatible case is not a loadable PE without the A4S exports.'
                }
            }
            $caseDllBinding = if (Test-Path -LiteralPath $caseDll) {
                Get-BinaryBinding -Path $caseDll -Role "isolated $caseName DLL input"
            } else { $null }

            $resident = $null
            $stopped = $true
            try {
                Assert-NoResidentA4SHost -ProbeHost $caseHost
                Assert-SameExplorerIdentity -Expected $initial.explorer `
                    -Actual (Get-TaskbarExplorerIdentity) -Label "$caseName pre-start"
                [void](Assert-NoA4SMapping -Explorer $initial.explorer -Label "$caseName pre-start")
                $resident = Start-A4STestHost -Executable $caseHost `
                    -Role "isolated $caseName host"
                $stopped = $false
                $failedStatus = Wait-A4SHostStatus -Executable $caseHost `
                    -ExpectedExitCode $hostStatusFailed -TimeoutSeconds $HostFailureTimeoutSeconds `
                    -ResidentProcess $resident
                $during = Get-A4SCheckpoint -Label "isolated-$caseName-failed" `
                    -HostExecutable $caseHost -KnownHostProcessId $resident.Id
                Assert-SameExplorerIdentity -Expected $initial.explorer -Actual $during.explorer `
                    -Label "$caseName failure host"
                if ($during.a4sMappings.Count -ne 0 -or $during.visibleMenuWindowCount -ne 0) {
                    throw "$caseName sibling-DLL failure reached Explorer despite pre-injection validation."
                }
                Add-EvidenceCheckpoint $during

                [void](Stop-A4STestHost -Executable $caseHost -ResidentProcess $resident)
                $stopped = $true
                $after = Get-A4SCheckpoint -Label "isolated-$caseName-stopped"
                Assert-SameExplorerIdentity -Expected $initial.explorer -Actual $after.explorer `
                    -Label "$caseName cleanup"
                if ($after.a4sMappings.Count -ne 0 -or $after.visibleMenuWindowCount -ne 0) {
                    throw "$caseName cleanup observed an A4S injection."
                }
                Add-EvidenceCheckpoint $after
                $finalCaseHostBinding = Get-BinaryBinding -Path $caseHost `
                    -Role "final isolated $caseName A4SMenuHost"
                Assert-BinaryCopyBinding -Source $caseHostBinding -Copy $finalCaseHostBinding
                $finalCaseDllBinding = $null
                if ($caseDllBinding) {
                    $finalCaseDllBinding = Get-BinaryBinding -Path $caseDll `
                        -Role "final isolated $caseName DLL input"
                    Assert-BinaryCopyBinding -Source $caseDllBinding -Copy $finalCaseDllBinding
                }
                [void]$script:Evidence.cases.Add([ordered]@{
                    name = $caseName
                    result = 'pass'
                    hostProcessId = $resident.Id
                    terminalStatusExitCode = $failedStatus.exitCode
                    terminalStatusText = $failedStatus.stdout
                    hostBinding = $caseHostBinding
                    dllBinding = $caseDllBinding
                    finalHostBinding = $finalCaseHostBinding
                    finalDllBinding = $finalCaseDllBinding
                    explorerPidUnchanged = $true
                    injectedModuleCount = 0
                    stoppedCleanly = $true
                })
                Save-Evidence
            }
            finally {
                if ($resident) {
                    $resident.Refresh()
                    if (-not $resident.HasExited -and -not $stopped) {
                        try {
                            [void](Stop-A4STestHost -Executable $caseHost -ResidentProcess $resident)
                            $stopped = $true
                        }
                        catch {
                            [void]$script:Evidence.errors.Add(
                                "Isolated $caseName host did not stop cleanly: $($_.Exception.Message)")
                            Save-Evidence
                        }
                    }
                    $resident.Dispose()
                }
                if (-not $stopped) {
                    throw "The isolated $caseName test host is not proven stopped; temporary files were retained at '$($caseDirectory.finalPath)'."
                }
            }
        }

        $finalExplorer = Get-TaskbarExplorerIdentity
        Assert-SameExplorerIdentity -Expected $initial.explorer -Actual $finalExplorer `
            -Label 'isolated matrix final'
        [void](Assert-NoA4SMapping -Explorer $finalExplorer -Label 'isolated matrix final')
        $noInjectionConclusive = $true
    }
    catch {
        [void]$script:Evidence.errors.Add($_.Exception.Message)
        $operationError = $_
    }
    finally {
        try {
            Assert-AllTrackedHostsStopped -ProbeHost $sourceHost
            $hostsStopped = $true
        }
        catch {
            [void]$script:Evidence.errors.Add(
                "Not every spawned/reset/resident host is proven stopped: $($_.Exception.Message)")
            if ($null -eq $operationError) { $operationError = $_ }
        }
        if ($hostsStopped) {
            try {
                $finalExplorer = Get-TaskbarExplorerIdentity
                if ($initial) {
                    Assert-SameExplorerIdentity -Expected $initial.explorer -Actual $finalExplorer `
                        -Label 'isolated final no-injection proof'
                }
                [void](Assert-NoA4SMapping -Explorer $finalExplorer `
                    -Label 'isolated final no-injection proof')
                $noInjectionConclusive = $true
            }
            catch {
                $noInjectionConclusive = $false
                [void]$script:Evidence.errors.Add(
                    "No-injection state is not conclusive: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        if ($backupPrepared -and $hostsStopped) {
            try {
                $restoreResult = Restore-HostSafety -Bundle $bundle -ProbeHost $sourceHost
                $safetyRestored = $true
                $script:Evidence.recovery.restored = $true
                $script:Evidence.recovery.restoredUtc = Get-UtcText
                $script:Evidence.recovery.transactionRollbackBundle = $restoreResult.rollbackBundle
                $script:Evidence.recovery.transactionRollbackManifestSha256 =
                    $restoreResult.rollbackManifestSha256
            }
            catch {
                [void]$script:Evidence.errors.Add("HostSafety restore failed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        elseif ($backupPrepared) {
            [void]$script:Evidence.errors.Add(
                'HostSafety was not restored because every tracked host is not proven stopped.')
        }

        if ($noInjectionConclusive -and $hostsStopped -and $safetyRestored) {
            try { Remove-A4STemporaryRoot -Root $temporaryRoot }
            catch {
                [void]$script:Evidence.errors.Add("Temporary case cleanup failed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            $script:Evidence.recovery.retainedTemporaryRoot = $temporaryRoot.finalPath
            $script:Evidence.recovery.cleanupInstructions = if ($backupPrepared) {
                "DO NOT DELETE '$($temporaryRoot.finalPath)' yet. Stop every A4SMenuHost with the matching host's --exit command; inspect Explorer for zero A4SMenu.dll mappings and zero A4S menu windows; if a mapping is pinned, restart Explorer manually; run -RecoverHostSafety -RecoveryBundle '$bundle'; only then delete the retained root manually."
            } else {
                "DO NOT DELETE '$($temporaryRoot.finalPath)' until every A4SMenuHost is stopped and Explorer is conclusively free of A4SMenu.dll mappings/windows. No HostSafety backup was completed, so do not use this bundle for recovery."
            }
        }
        $script:Evidence.trackedHosts = @($script:TrackedHosts)
        $script:Evidence.outcome = if ($null -eq $operationError -and
            $noInjectionConclusive -and $hostsStopped -and $safetyRestored) { 'pass' } else { 'fail' }
        Save-Evidence
    }

    if ($operationError) { throw $operationError }
    Write-Host 'PASS: isolated missing, corrupt, and incompatible DLL failures never injected; all tracked hosts stopped and Registry64 HostSafety was restored transactionally.'
    Write-Host 'Native Start behavior remains MANUAL/DEFERRED; this harness does not claim a mechanical pass.'
    Write-Host "Evidence: $script:EvidenceFile"
}

function Request-ValidatedExplorerTermination {
    param(
        [Parameter(Mandatory)][object] $ExpectedExplorer,
        [Parameter(Mandatory)][string] $Label
    )

    $current = Get-TaskbarExplorerIdentity
    Assert-SameExplorerIdentity -Expected $ExpectedExplorer -Actual $current -Label "$Label validation"
    $process = [Diagnostics.Process]::GetProcessById([int]$current.pid)
    try {
        $process.Refresh()
        $actualPath = [IO.Path]::GetFullPath($process.MainModule.FileName)
        if ($process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals($actualPath,
                [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe')))) {
            throw "$Label refused to terminate an unvalidated process."
        }
        $issuedFileTime = [uint64][DateTime]::UtcNow.ToFileTimeUtc()
        $process.Kill()
        $killReturnedFileTime = [uint64][DateTime]::UtcNow.ToFileTimeUtc()
        return [pscustomobject][ordered]@{
            label = $Label
            requestedUtc = Get-UtcText
            issuedFileTimeUtc = $issuedFileTime
            killReturnedFileTimeUtc = $killReturnedFileTime
            oldExplorer = $current
            process = $process
        }
    }
    catch { $process.Dispose(); throw }
}

function Complete-ValidatedExplorerTermination {
    param([Parameter(Mandatory)][object] $Request)
    try {
        if (-not $Request.process.WaitForExit(15000)) {
            throw "$($Request.label) Explorer PID $($Request.oldExplorer.pid) did not exit after the explicit termination request."
        }
        return [ordered]@{
            label = $Request.label
            requestedUtc = $Request.requestedUtc
            issuedFileTimeUtc = $Request.issuedFileTimeUtc
            killReturnedFileTimeUtc = $Request.killReturnedFileTimeUtc
            oldExplorer = $Request.oldExplorer
            observedExitUtc = Get-UtcText
            observedExitCode = $Request.process.ExitCode
        }
    }
    finally { $Request.process.Dispose() }
}

function Wait-ReplacementExplorer {
    param(
        [Parameter(Mandatory)][uint32] $OldProcessId,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $fallbackStarted = $false
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $candidate = Get-TaskbarExplorerIdentity
            if ($candidate.pid -ne $OldProcessId) {
                return [ordered]@{ explorer = $candidate; fallbackLaunchUsed = $fallbackStarted }
            }
        }
        catch { }
        if (-not $fallbackStarted -and $timer.Elapsed.TotalSeconds -ge 10) {
            $explorerPath = Resolve-RegularFile -Path (Join-Path $env:WINDIR 'explorer.exe') `
                -Description 'Windows Explorer recovery executable'
            $fallbackProcess = Start-Process -FilePath $explorerPath -PassThru
            if ($fallbackProcess) { $fallbackProcess.Dispose() }
            $fallbackStarted = $true
        }
        Start-Sleep -Milliseconds 150
    }
    throw "No replacement Shell_TrayWnd Explorer appeared within $TimeoutSeconds seconds after PID $OldProcessId exited."
}

function Invoke-OneMenuAssertion {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][uint32] $ExplorerProcessId
    )

    $open = Invoke-A4SHostCommand -Executable $Executable -Argument '--toggle'
    if ($open.exitCode -ne 0 -or -not (Wait-A4SCondition -TimeoutSeconds 8 -Condition {
        [A4SFailureRecoveryNative]::CountVisibleMenuWindows($ExplorerProcessId) -eq 1
    })) {
        throw 'Reconnect toggle did not produce exactly one visible A4S menu window.'
    }
    $close = Invoke-A4SHostCommand -Executable $Executable -Argument '--toggle'
    if ($close.exitCode -ne 0 -or -not (Wait-A4SCondition -TimeoutSeconds 8 -Condition {
        [A4SFailureRecoveryNative]::CountVisibleMenuWindows($ExplorerProcessId) -eq 0
    })) {
        throw 'Reconnect toggle did not close the single A4S menu window.'
    }
    return [ordered]@{ openExitCode = $open.exitCode; closeExitCode = $close.exitCode; exactWindowCount = 1 }
}

function Invoke-LiveFailureRecoveryQualification {
    param(
        [Parameter(Mandatory)][string] $SourceHost,
        [Parameter(Mandatory)][string] $SourceDll,
        [string] $RequestedEvidencePath
    )

    $script:TrackedHosts.Clear()
    $sourceHost = Resolve-RegularFile -Path $SourceHost -Description 'A4SMenuHost live-test input'
    $sourceDll = Resolve-RegularFile -Path $SourceDll -Description 'A4SMenu.dll live-test input'
    $bundle = New-EvidenceBundle -Mode 'live-explorer-crash-guard' -RequestedPath $RequestedEvidencePath
    $temporaryRoot = New-A4STemporaryRoot
    $backupPrepared = $false
    $hostStopped = $true
    $cleanupRestartComplete = $false
    $resident = $null
    $runtimeHost = $null
    $runtimeDll = $null
    $operationError = $null
    $allTrackedStopped = $false
    $noInjectionConclusive = $false
    $safetyRestored = $false

    try {
        $sourceHostBinding = Get-BinaryBinding -Path $sourceHost -Role 'source A4SMenuHost' `
            -QueryHostVersion
        $sourceDllBinding = Get-BinaryBinding -Path $sourceDll -Role 'source A4SMenu.dll'
        $script:Evidence.binaries.sourceHost = $sourceHostBinding
        $script:Evidence.binaries.sourceDll = $sourceDllBinding
        Save-Evidence
        $initial = Assert-CleanA4SSession -ProbeHost $sourceHost
        Add-EvidenceCheckpoint ([ordered]@{
            utc = Get-UtcText
            label = 'live-preflight-clean'
            explorer = $initial.explorer
            a4sMappings = @()
            visibleMenuWindowCount = 0
            host = [ordered]@{ statusExitCode = $serviceNotActive; statusText = 'stopped' }
            hostSafety = $initial.hostSafety
        })

        $backup = Backup-HostSafety -Bundle $bundle
        $backupPrepared = $true
        $script:Evidence.recovery = [ordered]@{
            bundle = $bundle
            manifest = $backup.manifestPath
            manifestSha256 = $backup.manifestSha256
            registryView = 'Registry64'
            preparedBeforeFirstCrash = $true
            originalHostSafetyExists = [bool]$backup.manifest.snapshot.exists
            restored = $false
            retainedTemporaryRoot = $null
            cleanupInstructions = "Run this script with -RecoverHostSafety -RecoveryBundle '$bundle' only after every same-user A4SMenuHost in every Windows session is stopped."
        }
        Save-Evidence

        # Establish an empty crash-guard baseline without loading a valid DLL or
        # installing a hook. This host copy has no sibling A4SMenu.dll.
        $resetDirectory = New-SafeFreshDirectory `
            -Path (Join-Path $temporaryRoot.finalPath 'safety-reset-no-dll') `
            -Description 'no-DLL safety-reset directory' -ExpectedParent $temporaryRoot.finalPath
        $resetHost = Join-Path $resetDirectory.finalPath 'A4SMenuHost.exe'
        Copy-Item -LiteralPath $sourceHost -Destination $resetHost -ErrorAction Stop
        $resetBinding = Get-BinaryBinding -Path $resetHost -Role 'safety-reset A4SMenuHost'
        Assert-BinaryCopyBinding -Source $sourceHostBinding -Copy $resetBinding
        $resetProcess = Start-A4STestHost -Executable $resetHost -Arguments '--reset-safety' `
            -Role 'safety-reset no-DLL host'
        $resetStopped = $false
        try {
            [void](Wait-A4SHostStatus -Executable $resetHost -ExpectedExitCode $hostStatusFailed `
                -TimeoutSeconds $HostFailureTimeoutSeconds -ResidentProcess $resetProcess)
            [void](Stop-A4STestHost -Executable $resetHost -ResidentProcess $resetProcess)
            $resetStopped = $true
        }
        finally {
            if (-not $resetStopped) {
                $resetProcess.Refresh()
                if (-not $resetProcess.HasExited) {
                    [void](Stop-A4STestHost -Executable $resetHost -ResidentProcess $resetProcess)
                }
            }
            $resetProcess.Dispose()
        }
        $emptySafety = Get-HostSafetySnapshot
        if ($emptySafety.exists) {
            throw 'The isolated no-DLL --reset-safety preparation did not clear HostSafety.'
        }
        Assert-SameExplorerIdentity -Expected $initial.explorer `
            -Actual (Get-TaskbarExplorerIdentity) -Label 'HostSafety reset preparation'
        [void](Assert-NoA4SMapping -Explorer $initial.explorer -Label 'HostSafety reset preparation')
        Add-EvidenceCheckpoint (Get-A4SCheckpoint -Label 'crash-guard-reset-without-injection')

        $runtimeDirectory = New-SafeFreshDirectory `
            -Path (Join-Path $temporaryRoot.finalPath 'valid-runtime') `
            -Description 'valid isolated runtime directory' -ExpectedParent $temporaryRoot.finalPath
        $runtimeHost = Join-Path $runtimeDirectory.finalPath 'A4SMenuHost.exe'
        $runtimeDll = Join-Path $runtimeDirectory.finalPath 'A4SMenu.dll'
        Copy-Item -LiteralPath $sourceHost -Destination $runtimeHost -ErrorAction Stop
        Copy-Item -LiteralPath $sourceDll -Destination $runtimeDll -ErrorAction Stop
        $runtimeHostBinding = Get-BinaryBinding -Path $runtimeHost -Role 'runtime A4SMenuHost'
        $runtimeDllBinding = Get-BinaryBinding -Path $runtimeDll -Role 'runtime A4SMenu.dll'
        Assert-BinaryCopyBinding -Source $sourceHostBinding -Copy $runtimeHostBinding
        Assert-BinaryCopyBinding -Source $sourceDllBinding -Copy $runtimeDllBinding
        $script:Evidence.binaries.runtimeHost = $runtimeHostBinding
        $script:Evidence.binaries.runtimeDll = $runtimeDllBinding
        $script:Evidence.runtime = [ordered]@{ isolatedDirectory = $runtimeDirectory.finalPath }
        Save-Evidence

        $resident = Start-A4STestHost -Executable $runtimeHost -Role 'live crash-guard host'
        $hostStopped = $false
        [void](Wait-A4SHostStatus -Executable $runtimeHost -ExpectedExitCode $hostStatusReadyExit `
            -TimeoutSeconds $ReconnectTimeoutSeconds -ResidentProcess $resident)
        $ready = Get-A4SCheckpoint -Label 'initial-ready' -HostExecutable $runtimeHost `
            -KnownHostProcessId $resident.Id
        Assert-ExactA4SMapping -Checkpoint $ready -ExpectedDll $runtimeDll
        Add-EvidenceCheckpoint $ready

        $crashBoundaries = [Collections.ArrayList]::new()
        [uint64[]]$priorGuardTimes = @()
        for ($crashIndex = 1; $crashIndex -le $crashThreshold; $crashIndex++) {
            $before = Get-A4SCheckpoint -Label "crash-$crashIndex-armed" `
                -HostExecutable $runtimeHost -KnownHostProcessId $resident.Id
            Assert-ExactA4SMapping -Checkpoint $before -ExpectedDll $runtimeDll
            if ($before.host.statusExitCode -ne $hostStatusReadyExit) {
                throw "Host was not READY before guarded crash $crashIndex."
            }
            Add-EvidenceCheckpoint $before

            # Persist intent before the destructive boundary. If PowerShell is
            # interrupted, evidence plus HostSafetyBackup.json remains sufficient
            # for an explicit -RecoverHostSafety run.
            [void]$script:Evidence.cases.Add([ordered]@{
                name = "guarded-explorer-crash-$crashIndex"
                armedUtc = Get-UtcText
                oldExplorerPid = $before.explorer.pid
                result = 'armed'
            })
            Save-Evidence

            $terminationRequest = Request-ValidatedExplorerTermination `
                -ExpectedExplorer $before.explorer `
                -Label "guarded crash $crashIndex of $crashThreshold"
            # This durable checkpoint is intentionally published immediately after
            # Process.Kill returns and before WaitForExit or replacement polling.
            try {
                Add-EvidenceCheckpoint ([ordered]@{
                    utc = Get-UtcText
                    label = "crash-$crashIndex-termination-issued"
                    sequence = 'post-kill-pre-wait'
                    issuedFileTimeUtc = $terminationRequest.issuedFileTimeUtc
                    killReturnedFileTimeUtc = $terminationRequest.killReturnedFileTimeUtc
                    oldExplorer = $terminationRequest.oldExplorer
                    hostProcessId = $resident.Id
                    recoveryManifestSha256 = $script:Evidence.recovery.manifestSha256
                })
            }
            catch {
                $terminationRequest.process.Dispose()
                throw
            }
            $termination = Complete-ValidatedExplorerTermination -Request $terminationRequest
            $replacement = Wait-ReplacementExplorer -OldProcessId $before.explorer.pid `
                -TimeoutSeconds $ReconnectTimeoutSeconds
            if ($replacement.explorer.pid -eq $before.explorer.pid) {
                throw "Guarded crash $crashIndex did not cross an Explorer PID boundary."
            }

            if ($crashIndex -lt $crashThreshold) {
                [void](Wait-A4SHostStatus -Executable $runtimeHost `
                    -ExpectedExitCode $hostStatusReadyExit -TimeoutSeconds $ReconnectTimeoutSeconds `
                    -ResidentProcess $resident)
                $after = Get-A4SCheckpoint -Label "crash-$crashIndex-reconnected" `
                    -HostExecutable $runtimeHost -KnownHostProcessId $resident.Id
                Assert-ExactA4SMapping -Checkpoint $after -ExpectedDll $runtimeDll
                if ($after.explorer.pid -ne $replacement.explorer.pid) {
                    throw "Guarded crash $crashIndex status and replacement taskbar refer to different Explorer processes."
                }
                if ($crashIndex -eq 1) {
                    $after.oneMenuAssertion = Invoke-OneMenuAssertion -Executable $runtimeHost `
                        -ExplorerProcessId $after.explorer.pid
                }
            }
            else {
                [void](Wait-A4SHostStatus -Executable $runtimeHost `
                    -ExpectedExitCode $hostStatusSafetyDisabled `
                    -TimeoutSeconds $ReconnectTimeoutSeconds -ResidentProcess $resident)
                $after = Get-A4SCheckpoint -Label 'crash-3-safety-disabled' `
                    -HostExecutable $runtimeHost -KnownHostProcessId $resident.Id
                if ($after.explorer.pid -ne $replacement.explorer.pid -or
                    $after.a4sMappings.Count -ne 0 -or $after.visibleMenuWindowCount -ne 0) {
                    throw 'The third crash did not leave the replacement Explorer uninjected and without A4S UI.'
                }
                $after.nativeStart = [ordered]@{
                    status = 'manual-deferred'
                    mechanicalPassPermitted = $false
                    observation = 'No A4S mapping or visible A4S menu window was present; native Start UI was not synthetically invoked.'
                }
            }
            [void]$crashBoundaries.Add([ordered]@{
                index = $crashIndex
                issuedFileTimeUtc = [uint64]$termination.issuedFileTimeUtc
                observedFileTimeUtc = [uint64]$after.observedFileTimeUtc
                oldExplorerPid = $before.explorer.pid
                newExplorerPid = $after.explorer.pid
            })
            $after.rollingGuard = Assert-RollingCrashGuardStage `
                -Snapshot $after.hostSafety -ExpectedCount $crashIndex `
                -ExpectedDisabled ($crashIndex -eq $crashThreshold) `
                -Boundaries @($crashBoundaries) -PriorTimestamps $priorGuardTimes
            [uint64[]]$priorGuardTimes = @($after.rollingGuard.timestamps100ns)
            $after.termination = $termination
            $after.replacementFallbackLaunchUsed = $replacement.fallbackLaunchUsed
            Add-EvidenceCheckpoint $after
            $case = $script:Evidence.cases[$script:Evidence.cases.Count - 1]
            $case.result = 'pass'
            $case.newExplorerPid = $after.explorer.pid
            $case.hostStatusExitCode = $after.host.statusExitCode
            $case.mappingCount = $after.a4sMappings.Count
            Save-Evidence
        }

        # The real host reset must clear SAFETY_DISABLED and recover a READY exact
        # mapping. This intentionally occurs only inside the explicitly consented
        # live mode and is followed by a supported logical stop.
        $resetResult = Invoke-A4SHostCommand -Executable $runtimeHost -Argument '--reset-safety'
        if ($resetResult.exitCode -ne 0) {
            throw "Resident --reset-safety failed with exit $($resetResult.exitCode)."
        }
        [void](Wait-A4SHostStatus -Executable $runtimeHost -ExpectedExitCode $hostStatusReadyExit `
            -TimeoutSeconds $ReconnectTimeoutSeconds -ResidentProcess $resident)
        $recovered = Get-A4SCheckpoint -Label 'safety-reset-recovered-ready' `
            -HostExecutable $runtimeHost -KnownHostProcessId $resident.Id
        Assert-ExactA4SMapping -Checkpoint $recovered -ExpectedDll $runtimeDll
        if ($recovered.hostSafety.exists) {
            throw '--reset-safety recovered injection but retained crash-guard registry state.'
        }
        Add-EvidenceCheckpoint $recovered

        [void](Stop-A4STestHost -Executable $runtimeHost -ResidentProcess $resident)
        $hostStopped = $true
        $resident.Dispose()
        $resident = $null

        # A logically disarmed DLL remains pinned by Explorer. The separately
        # acknowledged cleanup restart is the only way this harness unloads that
        # exact temporary image before deleting its directory.
        $cleanupBefore = Get-A4SCheckpoint -Label 'cleanup-restart-armed'
        Assert-ExactA4SMapping -Checkpoint $cleanupBefore -ExpectedDll $runtimeDll
        Add-EvidenceCheckpoint $cleanupBefore
        $cleanupRequest = Request-ValidatedExplorerTermination `
            -ExpectedExplorer $cleanupBefore.explorer -Label 'post-recovery cleanup restart'
        try {
            Add-EvidenceCheckpoint ([ordered]@{
                utc = Get-UtcText
                label = 'cleanup-termination-issued'
                sequence = 'post-kill-pre-wait'
                issuedFileTimeUtc = $cleanupRequest.issuedFileTimeUtc
                killReturnedFileTimeUtc = $cleanupRequest.killReturnedFileTimeUtc
                oldExplorer = $cleanupRequest.oldExplorer
                hostState = 'proven-stopped'
                recoveryManifestSha256 = $script:Evidence.recovery.manifestSha256
            })
        }
        catch {
            $cleanupRequest.process.Dispose()
            throw
        }
        $cleanupTermination = Complete-ValidatedExplorerTermination -Request $cleanupRequest
        $cleanupReplacement = Wait-ReplacementExplorer -OldProcessId $cleanupBefore.explorer.pid `
            -TimeoutSeconds $ReconnectTimeoutSeconds
        $cleanupAfter = Get-A4SCheckpoint -Label 'cleanup-restart-complete'
        if ($cleanupAfter.explorer.pid -ne $cleanupReplacement.explorer.pid -or
            $cleanupAfter.a4sMappings.Count -ne 0 -or
            $cleanupAfter.visibleMenuWindowCount -ne 0) {
            throw 'The acknowledged cleanup restart did not leave a clean replacement Explorer.'
        }
        $cleanupAfter.termination = $cleanupTermination
        $cleanupAfter.replacementFallbackLaunchUsed = $cleanupReplacement.fallbackLaunchUsed
        Add-EvidenceCheckpoint $cleanupAfter
        $cleanupRestartComplete = $true
        $noInjectionConclusive = $true
    }
    catch {
        $operationError = $_
        [void]$script:Evidence.errors.Add($_.Exception.Message)
    }
    finally {
        if ($resident) {
            try {
                $resident.Refresh()
                if (-not $resident.HasExited) {
                    [void](Stop-A4STestHost -Executable $runtimeHost -ResidentProcess $resident)
                }
                $hostStopped = $true
            }
            catch {
                $hostStopped = $false
                [void]$script:Evidence.errors.Add(
                    "Live host cleanup could not prove a logical stop: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
            finally { $resident.Dispose() }
        }

        try {
            Assert-AllTrackedHostsStopped -ProbeHost $sourceHost
            $allTrackedStopped = $true
            $hostStopped = $true
        }
        catch {
            $allTrackedStopped = $false
            [void]$script:Evidence.errors.Add(
                "Not every spawned/reset/resident host is proven stopped: $($_.Exception.Message)")
            if ($null -eq $operationError) { $operationError = $_ }
        }

        # Never add an unconfirmed fifth Explorer termination after a failed run.
        # Absence must be positively established; enumeration failure and a pinned
        # mapping both retain the root with explicit manual cleanup instructions.
        if ($allTrackedStopped) {
            try {
                $current = Get-TaskbarExplorerIdentity
                $finalInjection = Assert-NoA4SMapping -Explorer $current `
                    -Label 'live final no-injection proof'
                $noInjectionConclusive = $finalInjection.mappings.Count -eq 0 -and
                    $finalInjection.visibleMenuWindowCount -eq 0
            }
            catch {
                $noInjectionConclusive = $false
                [void]$script:Evidence.errors.Add(
                    "No-injection state is not conclusive: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }

        if ($runtimeHost -or $runtimeDll) {
            try {
                if (-not $runtimeHost -or -not $runtimeDll -or
                    -not (Test-Path -LiteralPath $runtimeHost -PathType Leaf) -or
                    -not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) {
                    throw 'One or both bound runtime binaries disappeared before final verification.'
                }
                $finalHostBinding = Get-BinaryBinding -Path $runtimeHost `
                    -Role 'final runtime A4SMenuHost'
                $finalDllBinding = Get-BinaryBinding -Path $runtimeDll `
                    -Role 'final runtime A4SMenu.dll'
                Assert-BinaryCopyBinding -Source $script:Evidence.binaries.runtimeHost `
                    -Copy $finalHostBinding
                Assert-BinaryCopyBinding -Source $script:Evidence.binaries.runtimeDll `
                    -Copy $finalDllBinding
                $script:Evidence.binaries.finalRuntimeHost = $finalHostBinding
                $script:Evidence.binaries.finalRuntimeDll = $finalDllBinding
            }
            catch {
                [void]$script:Evidence.errors.Add("Runtime binary binding changed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }

        if ($backupPrepared -and $allTrackedStopped) {
            try {
                $restoreResult = Restore-HostSafety -Bundle $bundle -ProbeHost $sourceHost
                $safetyRestored = $true
                $script:Evidence.recovery.restored = $true
                $script:Evidence.recovery.restoredUtc = Get-UtcText
                $script:Evidence.recovery.transactionRollbackBundle = $restoreResult.rollbackBundle
                $script:Evidence.recovery.transactionRollbackManifestSha256 =
                    $restoreResult.rollbackManifestSha256
            }
            catch {
                [void]$script:Evidence.errors.Add("HostSafety restore failed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        elseif ($backupPrepared) {
            [void]$script:Evidence.errors.Add(
                'HostSafety was not restored because every tracked same-user host is not proven stopped; use the durable recovery command in evidence.')
        }

        if ($cleanupRestartComplete -and $noInjectionConclusive -and
            $allTrackedStopped -and $safetyRestored) {
            try { Remove-A4STemporaryRoot -Root $temporaryRoot }
            catch {
                [void]$script:Evidence.errors.Add("Temporary runtime cleanup failed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            $script:Evidence.recovery.retainedTemporaryRoot = $temporaryRoot.finalPath
            $script:Evidence.recovery.cleanupInstructions = if ($backupPrepared) {
                "DO NOT DELETE '$($temporaryRoot.finalPath)' yet. Stop every same-user A4SMenuHost in every Windows session through --exit; verify the taskbar Explorer has zero A4SMenu.dll mappings and zero A4S menu windows; if a mapping is pinned or inspection is inconclusive, restart Explorer manually; run -RecoverHostSafety -RecoveryBundle '$bundle'; only then delete the retained root manually."
            } else {
                "DO NOT DELETE '$($temporaryRoot.finalPath)' until every same-user A4SMenuHost is stopped and Explorer is conclusively free of A4SMenu.dll mappings/windows. No HostSafety backup was completed, so do not use this bundle for recovery."
            }
        }

        $script:Evidence.trackedHosts = @($script:TrackedHosts)
        $script:Evidence.outcome = if ($null -eq $operationError -and
            $cleanupRestartComplete -and $noInjectionConclusive -and
            $allTrackedStopped -and $safetyRestored) { 'pass' } else { 'fail' }
        Save-Evidence
    }

    if ($operationError) { throw $operationError }
    Write-Host 'PASS: exact reconnect mappings, one-menu behavior, ordered 1/2/3 crash-guard boundaries, reset recovery, tracked-host shutdown, no-injection cleanup, and transactional Registry64 restoration were verified.'
    Write-Host 'Native Start behavior remains MANUAL/DEFERRED; this harness does not claim a mechanical pass.'
    Write-Host "Evidence: $script:EvidenceFile"
}

if ($PSCmdlet.ParameterSetName -eq 'Offline') {
    & (Join-Path $PSScriptRoot 'Test-A4SFailureRecoveryContracts.ps1')
    Write-Host 'OFFLINE GO: no runtime, registry, Explorer, staging, or evidence changes were made.'
    Write-Host 'ISOLATED/LIVE NO-GO: neither executable mode was run; both remain deferred pending explicit review and authorization.'
    Write-Host 'Live N6/N9 additionally requires the conspicuous crash switch and exact confirmation text.'
    Write-Host 'Native Start UI behavior is a manual/deferred observation, never a mechanical harness PASS.'
}
else {
    Initialize-A4SFailureRecoveryNative
    $script:HarnessLease = Enter-A4SHarnessLease
    try {
        switch ($PSCmdlet.ParameterSetName) {
            'Isolated' {
                Invoke-IsolatedDllFailureQualification -SourceHost $HostPath `
                    -RequestedEvidencePath $EvidencePath
            }
            'Live' {
                if (-not $IUnderstandThisWillForceCrashExplorerThreeTimesAndRestartItForCleanup -or
                    $ConfirmationText -cne 'I ACCEPT FOUR EXPLORER TERMINATIONS: THREE GUARDED CRASHES AND ONE CLEANUP RESTART') {
                    throw 'The exact destructive Explorer confirmation was not supplied.'
                }
                Invoke-LiveFailureRecoveryQualification -SourceHost $HostPath `
                    -SourceDll $DllPath -RequestedEvidencePath $EvidencePath
            }
            'Recover' {
                # Initialize-A4SFailureRecoveryNative above enforces x64 before
                # recovery validation, process checks, or registry deletion.
                Assert-AllTrackedHostsStopped
                $restoreResult = Restore-HostSafety -Bundle $RecoveryBundle
                Write-Host "HostSafety restored transactionally from the validated Registry64 bundle: $RecoveryBundle"
                Write-Host "Immediate pre-restore rollback bundle retained at: $($restoreResult.rollbackBundle)"
            }
            default { throw "Unsupported parameter set: $($PSCmdlet.ParameterSetName)" }
        }
    }
    finally {
        Exit-A4SHarnessLease -Lease $script:HarnessLease
        $script:HarnessLease = $null
    }
}
