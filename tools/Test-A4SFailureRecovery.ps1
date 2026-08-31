[CmdletBinding(DefaultParameterSetName = 'Offline')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ContractLibrary')]
    [switch] $ContractLibrary,

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

    [Parameter(Mandatory, ParameterSetName = 'Recover')]
    [ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
    [string] $ExpectedCurrentHostSafetySha256,

    [Parameter(Mandatory, ParameterSetName = 'Isolated')]
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $HostPath,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $DllPath,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $ReleaseRecordPath,

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
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class A4SFailureRecoveryNative
{
    public sealed class ProductMutationBoundary : IDisposable
    {
        private Mutex setup;
        private Mutex host;
        private bool setupOwned;
        private bool hostOwned;

        internal ProductMutationBoundary(Mutex setup, bool setupOwned,
            Mutex host, bool hostOwned, string setupName, string hostName)
        {
            this.setup = setup;
            this.setupOwned = setupOwned;
            this.host = host;
            this.hostOwned = hostOwned;
            SetupMutexName = setupName;
            HostMutexName = hostName;
        }

        public string SetupMutexName { get; private set; }
        public string HostMutexName { get; private set; }
        public bool IsHeld { get { return setupOwned && hostOwned; } }

        public void Dispose()
        {
            if (hostOwned) { host.ReleaseMutex(); hostOwned = false; }
            if (host != null) { host.Dispose(); host = null; }
            if (setupOwned) { setup.ReleaseMutex(); setupOwned = false; }
            if (setup != null) { setup.Dispose(); setup = null; }
        }
    }

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

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetThreadDesktop(uint threadId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetUserObjectInformationW(IntPtr objectHandle,
        int index, IntPtr information, uint length, out uint needed);

    private const uint INVALID_FILE_ATTRIBUTES = 0xffffffff;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;

    private static bool WaitMutex(Mutex mutex)
    {
        try { return mutex.WaitOne(0, false); }
        catch (AbandonedMutexException) { return true; }
    }

    private static byte[] CurrentSidBytes()
    {
        SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
        byte[] bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        return bytes;
    }

    private static string Hex(byte[] bytes)
    {
        StringBuilder text = new StringBuilder(bytes.Length * 2);
        foreach (byte value in bytes)
            text.Append(value.ToString("X2"));
        return text.ToString();
    }

    private static string SetupMutexName()
    {
        using (SHA256 algorithm = SHA256.Create())
            return @"Global\A4SMenu.Setup.v1." +
                Hex(algorithm.ComputeHash(CurrentSidBytes())).Substring(0, 32);
    }

    private static string HostMutexName()
    {
        IntPtr desktop = GetThreadDesktop(GetCurrentThreadId());
        if (desktop == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not identify the current desktop for host serialization.");
        uint needed;
        GetUserObjectInformationW(desktop, 2, IntPtr.Zero, 0, out needed);
        if (needed == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not measure the current desktop name.");
        IntPtr buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!GetUserObjectInformationW(desktop, 2, buffer, needed, out needed))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not read the current desktop name.");
            byte[] desktopBytes = new byte[needed];
            Marshal.Copy(buffer, desktopBytes, 0, (int)needed);
            ulong hash = 14695981039346656037UL;
            unchecked
            {
                foreach (byte value in CurrentSidBytes())
                {
                    hash ^= value;
                    hash *= 1099511628211UL;
                }
                foreach (byte value in desktopBytes)
                {
                    hash ^= value;
                    hash *= 1099511628211UL;
                }
            }
            return String.Format(@"Local\A4SMenu.Host.Instance.v1.{0}.{1:X16}",
                Process.GetCurrentProcess().SessionId, hash);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static ProductMutationBoundary AcquireProductMutationBoundary()
    {
        string setupName = SetupMutexName();
        string hostName = HostMutexName();
        Mutex setup = null;
        Mutex host = null;
        bool setupOwned = false;
        bool hostOwned = false;
        try
        {
            setup = new Mutex(false, setupName);
            setupOwned = WaitMutex(setup);
            if (!setupOwned)
                throw new InvalidOperationException(
                    "The A4S product servicing mutex is already owned.");
            host = new Mutex(false, hostName);
            hostOwned = WaitMutex(host);
            if (!hostOwned)
                throw new InvalidOperationException(
                    "The current desktop A4S host mutex is already owned.");
            return new ProductMutationBoundary(setup, setupOwned,
                host, hostOwned, setupName, hostName);
        }
        catch
        {
            if (hostOwned) host.ReleaseMutex();
            if (host != null) host.Dispose();
            if (setupOwned) setup.ReleaseMutex();
            if (setup != null) setup.Dispose();
            throw;
        }
    }

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

function Test-A4STemporaryCleanupAllowed {
    param(
        [Parameter(Mandatory)][bool] $AllHostsStopped,
        [Parameter(Mandatory)][bool] $MappingInspectionSucceeded,
        [Parameter(Mandatory)][int] $MappingCount,
        [Parameter(Mandatory)][int] $WindowCount,
        [Parameter(Mandatory)][bool] $SafetyRestored,
        [bool] $CleanupRestartRequired = $false,
        [bool] $CleanupRestartComplete = $true
    )
    return $AllHostsStopped -and $MappingInspectionSucceeded -and
        $MappingCount -eq 0 -and $WindowCount -eq 0 -and $SafetyRestored -and
        (-not $CleanupRestartRequired -or $CleanupRestartComplete)
}

function Set-RetainedTemporaryRootEvidence {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][bool] $BackupPrepared,
        [Parameter(Mandatory)][string] $Reason,
        [string] $Bundle
    )

    if ($null -eq $script:Evidence.recovery) {
        $script:Evidence.recovery = [ordered]@{}
    }
    $script:Evidence.recovery['retainedTemporaryRoot'] = [IO.Path]::GetFullPath($Root)
    $script:Evidence.recovery['retentionReason'] = $Reason
    if ($BackupPrepared) {
        if (-not $script:Evidence.recovery.Contains('authorizedCurrentHostSafetySha256') -or
            [string]::IsNullOrWhiteSpace(
                [string]$script:Evidence.recovery.authorizedCurrentHostSafetySha256)) {
            try {
                $aggregate = Get-HostSafetyAggregateRecord
                $script:Evidence.recovery['authorizedCurrentHostSafetySha256'] = $aggregate.sha256
            }
            catch {
                $script:Evidence.recovery['authorizedCurrentHostSafetySha256'] = $null
                [void]$script:Evidence.errors.Add(
                    "Could not record a recovery authorization hash: $($_.Exception.Message)")
            }
        }
        $authorizedHash = [string]$script:Evidence.recovery.authorizedCurrentHostSafetySha256
        $recoveryStep = if ($authorizedHash -match '\A[A-Fa-f0-9]{64}\z') {
            "run this harness with -RecoverHostSafety -RecoveryBundle '$Bundle' -ExpectedCurrentHostSafetySha256 '$authorizedHash'"
        } else {
            'do not run recovery because an exact current HostSafety aggregate hash could not be persisted'
        }
        $script:Evidence.recovery['cleanupInstructions'] =
            "DO NOT DELETE '$([IO.Path]::GetFullPath($Root))'. Stop every same-user A4SMenuHost in every Windows session; verify the taskbar Explorer has zero A4SMenu.dll mappings and zero A4S menu windows; restart Explorer manually if an image remains pinned; then $recoveryStep. Recovery aborts if HostSafety differs from the persisted aggregate. Delete the retained root only after exact restoration and clean-state inspection."
    }
    else {
        $script:Evidence.recovery['cleanupInstructions'] =
            "DO NOT DELETE '$([IO.Path]::GetFullPath($Root))' until every same-user A4SMenuHost is stopped and Explorer is conclusively free of A4SMenu.dll mappings/windows. No HostSafety backup completed, so this bundle cannot authorize recovery."
    }
    Save-Evidence
}

function Clear-RetainedTemporaryRootEvidence {
    if ($null -ne $script:Evidence.recovery) {
        $script:Evidence.recovery['retainedTemporaryRoot'] = $null
        $script:Evidence.recovery['retentionReason'] = $null
        $script:Evidence.recovery['cleanupInstructions'] = $null
        Save-Evidence
    }
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
    $repositoryHead = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Out-String).Trim()
    if ($repositoryHead -notmatch '\A[A-Fa-f0-9]{40,64}\z') {
        throw 'Could not record the informational repository HEAD.'
    }
    $script:Evidence = [ordered]@{
        schemaVersion = 3
        mode = $Mode
        startedUtc = Get-UtcText
        updatedUtc = Get-UtcText
        sourceBinding = 'unverified'
        verifiedSourceCommit = $null
        repositoryHead = $repositoryHead
        releaseRecord = $null
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
    return (($Expected | ConvertTo-Json -Depth 32 -Compress) -ceq
        ($Actual | ConvertTo-Json -Depth 32 -Compress))
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string] $Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-HostSafetyAggregateRecord {
    param([object] $Snapshot)
    if ($null -eq $Snapshot) { $Snapshot = Get-HostSafetySnapshot }
    Assert-ValidRegistryTree -Tree $Snapshot -IsRoot $true
    $json = $Snapshot | ConvertTo-Json -Depth 32 -Compress
    return [ordered]@{
        snapshot = $Snapshot
        canonicalJson = $json
        sha256 = Get-TextSha256 -Text $json
    }
}

function Assert-AuthorizedHostSafetyAggregate {
    param(
        [Parameter(Mandatory)][object] $Current,
        [object] $ExpectedSnapshot,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedSha256,
        [Parameter(Mandatory)][string] $Boundary
    )

    if ($ExpectedSnapshot) {
        $expected = Get-HostSafetyAggregateRecord -Snapshot $ExpectedSnapshot
        if ($expected.sha256 -cne $ExpectedSha256.ToUpperInvariant()) {
            throw "$Boundary expected snapshot does not match its authorized aggregate hash."
        }
        if (-not (Compare-HostSafetySnapshot -Expected $ExpectedSnapshot `
            -Actual $Current.snapshot)) {
            throw "$Boundary observed an intervening HostSafety aggregate; mutation is forbidden."
        }
    }
    if ($Current.sha256 -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$Boundary aggregate hash differs from the authorized immediate state; mutation is forbidden."
    }
    return $true
}

function Add-HostSafetyRestoreAuthorizationCheckpoint {
    param([Parameter(Mandatory)][string] $Label)

    $aggregate = Get-HostSafetyAggregateRecord
    $script:Evidence.recovery['authorizedCurrentHostSafetySha256'] = $aggregate.sha256
    Add-EvidenceCheckpoint ([ordered]@{
        utc = Get-UtcText
        label = $Label
        mutation = 'HostSafety exact restore authorization'
        authorizedCurrentHostSafetySha256 = $aggregate.sha256
        hostSafety = $aggregate.snapshot
    })
    return $aggregate
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
        if ($kind -notin @('None', 'String', 'ExpandString', 'Binary',
                'DWord', 'MultiString', 'QWord')) {
            throw "HostSafety backup contains unsupported registry kind '$kind'."
        }
        if ($kind -in @('Binary', 'None')) {
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
        'snapshot', 'snapshotSha256', 'regExport') -Description 'HostSafety recovery manifest'
    if ($manifest.schemaVersion -ne 3 -or
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
    $snapshotAggregate = Get-HostSafetyAggregateRecord -Snapshot $manifest.snapshot
    if ([string]$manifest.snapshotSha256 -notmatch '\A[A-Fa-f0-9]{64}\z' -or
        $snapshotAggregate.sha256 -cne ([string]$manifest.snapshotSha256).ToUpperInvariant()) {
        throw 'HostSafety recovery manifest snapshot aggregate hash is invalid.'
    }
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
        snapshotSha256 = $snapshotAggregate.sha256
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
    $snapshotAggregate = Get-HostSafetyAggregateRecord -Snapshot $snapshot
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
        schemaVersion = 3
        backupId = [Guid]::NewGuid().ToString('N')
        createdUtc = Get-UtcText
        registryHive = 'HKEY_CURRENT_USER'
        registryPath = $hostSafetyRegPath
        registrySubKey = $hostSafetySubKey
        registryView = 'Registry64'
        snapshot = $snapshot
        snapshotSha256 = $snapshotAggregate.sha256
        regExport = $regExport
    }
    Write-DurableNewText -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 32)
    return Read-ValidatedHostSafetyBackup -Bundle $bundleRecord.finalPath
}

function Remove-HostSafetyRegistryTree {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
    try { $base.DeleteSubKeyTree($hostSafetySubKey, $false) }
    finally { $base.Dispose() }
}

function Enter-A4SProductMutationBoundary {
    $boundary = [A4SFailureRecoveryNative]::AcquireProductMutationBoundary()
    if (-not $boundary -or -not $boundary.IsHeld) {
        if ($boundary) { $boundary.Dispose() }
        throw 'Could not acquire the exact product Setup/host mutation boundary.'
    }
    return $boundary
}

function Exit-A4SProductMutationBoundary {
    param([object] $Boundary)
    if ($Boundary) { $Boundary.Dispose() }
}

function Assert-A4SProductMutationBoundary {
    param(
        [Parameter(Mandatory)][object] $Boundary,
        [Parameter(Mandatory)][string] $Label
    )
    if (-not $Boundary.IsHeld -or
        [string]$Boundary.SetupMutexName -notmatch '\AGlobal\\A4SMenu\.Setup\.v1\.[A-F0-9]{32}\z' -or
        [string]$Boundary.HostMutexName -notmatch '\ALocal\\A4SMenu\.Host\.Instance\.v1\.[0-9]+\.[A-F0-9]{16}\z') {
        throw "$Label does not hold the exact product Setup and current-desktop host mutexes."
    }
    Assert-AllTrackedHostsStopped
    return $true
}

function Copy-RegistrySnapshotObject {
    param([Parameter(Mandatory)][object] $Snapshot)
    return ($Snapshot | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

function Convert-RegistryValueForWrite {
    param([Parameter(Mandatory)][object] $Record)
    switch ([string]$Record.kind) {
        'Binary' { return [Convert]::FromBase64String([string]$Record.value) }
        'None' { return [Convert]::FromBase64String([string]$Record.value) }
        'MultiString' { return [string[]]@($Record.value) }
        'DWord' {
            return [BitConverter]::ToInt32(
                [BitConverter]::GetBytes([uint32]$Record.value), 0)
        }
        'QWord' {
            return [BitConverter]::ToInt64(
                [BitConverter]::GetBytes([uint64]$Record.value), 0)
        }
        'String' { return [string]$Record.value }
        'ExpandString' { return [string]$Record.value }
        default { throw "Unsupported exact registry-write kind '$($Record.kind)'." }
    }
}

function Invoke-AuthorizedHostSafetyMutationStep {
    param(
        [Parameter(Mandatory)][object] $Boundary,
        [Parameter(Mandatory)][object] $Before,
        [Parameter(Mandatory)][object] $AfterSnapshot,
        [Parameter(Mandatory)][scriptblock] $Mutation,
        [Parameter(Mandatory)][ref] $MutationState,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Assert-A4SProductMutationBoundary -Boundary $Boundary -Label "$Label preflight")
    $current = Get-HostSafetyAggregateRecord
    [void](Assert-AuthorizedHostSafetyAggregate -Current $current `
        -ExpectedSnapshot $Before.snapshot -ExpectedSha256 $Before.sha256 `
        -Boundary "$Label preflight")
    $after = Get-HostSafetyAggregateRecord -Snapshot $AfterSnapshot
    $MutationState.Value = [ordered]@{
        label = $Label
        inFlight = $true
        allowed = @($Before, $after)
        lastVerified = $Before
    }
    & $Mutation
    [void](Assert-A4SProductMutationBoundary -Boundary $Boundary -Label "$Label postflight")
    $observed = Get-HostSafetyAggregateRecord
    [void](Assert-AuthorizedHostSafetyAggregate -Current $observed `
        -ExpectedSnapshot $after.snapshot -ExpectedSha256 $after.sha256 `
        -Boundary "$Label postflight")
    $MutationState.Value = [ordered]@{
        label = $Label
        inFlight = $false
        allowed = @($observed)
        lastVerified = $observed
    }
    return $observed
}

function Set-HostSafetyTreeProgressively {
    param(
        [Parameter(Mandatory)][object] $Boundary,
        [Parameter(Mandatory)][object] $DesiredNode,
        [Parameter(Mandatory)][object] $ExpectedRoot,
        [Parameter(Mandatory)][object] $ExpectedNode,
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][ref] $CurrentAggregate,
        [Parameter(Mandatory)][ref] $MutationState
    )

    foreach ($value in @($DesiredNode.values)) {
        $nextRoot = Copy-RegistrySnapshotObject -Snapshot $ExpectedRoot
        $nextNode = $nextRoot
        if (-not [string]::IsNullOrEmpty($RelativePath)) {
            foreach ($component in $RelativePath.Split('\')) {
                $matches = @($nextNode.subkeys | Where-Object { $_.name -ceq $component })
                if ($matches.Count -ne 1) {
                    throw "Exact restore model lost the unique '$component' subkey."
                }
                $nextNode = $matches[0]
            }
        }
        $nextNode.values = @($nextNode.values) + @(Copy-RegistrySnapshotObject -Snapshot $value)
        $keyPath = if ([string]::IsNullOrEmpty($RelativePath)) {
            $hostSafetySubKey
        } else { "$hostSafetySubKey\$RelativePath" }
        $record = $value
        $CurrentAggregate.Value = Invoke-AuthorizedHostSafetyMutationStep `
            -Boundary $Boundary -Before $CurrentAggregate.Value -AfterSnapshot $nextRoot `
            -MutationState $MutationState -Label "set value '$keyPath\$($record.name)'" `
            -Mutation {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
                try {
                    $key = $base.OpenSubKey($keyPath, $true)
                    if ($null -eq $key) { throw "Registry key disappeared before exact write: $keyPath" }
                    try {
                        $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                            [Microsoft.Win32.RegistryValueKind], [string]$record.kind, $false)
                        $key.SetValue([string]$record.name,
                            (Convert-RegistryValueForWrite -Record $record), $kind)
                        $key.Flush()
                    }
                    finally { $key.Dispose() }
                }
                finally { $base.Dispose() }
            }
        $ExpectedRoot = $nextRoot
        $ExpectedNode = $nextNode
    }

    foreach ($desiredChild in @($DesiredNode.subkeys)) {
        $nextRoot = Copy-RegistrySnapshotObject -Snapshot $ExpectedRoot
        $nextParent = $nextRoot
        if (-not [string]::IsNullOrEmpty($RelativePath)) {
            foreach ($component in $RelativePath.Split('\')) {
                $matches = @($nextParent.subkeys | Where-Object { $_.name -ceq $component })
                if ($matches.Count -ne 1) {
                    throw "Exact restore model lost the unique '$component' subkey."
                }
                $nextParent = $matches[0]
            }
        }
        $emptyChild = [pscustomobject][ordered]@{
            name = [string]$desiredChild.name
            values = @()
            subkeys = @()
        }
        $nextParent.subkeys = @($nextParent.subkeys) + @($emptyChild)
        $childRelative = if ([string]::IsNullOrEmpty($RelativePath)) {
            [string]$desiredChild.name
        } else { "$RelativePath\$($desiredChild.name)" }
        $childKeyPath = "$hostSafetySubKey\$childRelative"
        $CurrentAggregate.Value = Invoke-AuthorizedHostSafetyMutationStep `
            -Boundary $Boundary -Before $CurrentAggregate.Value -AfterSnapshot $nextRoot `
            -MutationState $MutationState -Label "create subkey '$childKeyPath'" `
            -Mutation {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
                try {
                    $key = $base.CreateSubKey($childKeyPath, $true)
                    if ($null -eq $key) { throw "Could not create exact registry subkey: $childKeyPath" }
                    try { $key.Flush() } finally { $key.Dispose() }
                }
                finally { $base.Dispose() }
            }
        $ExpectedRoot = $nextRoot
        $ExpectedNode = $emptyChild
        Set-HostSafetyTreeProgressively -Boundary $Boundary `
            -DesiredNode $desiredChild -ExpectedRoot $ExpectedRoot `
            -ExpectedNode $ExpectedNode -RelativePath $childRelative `
            -CurrentAggregate $CurrentAggregate -MutationState $MutationState
        $ExpectedRoot = $CurrentAggregate.Value.snapshot
    }
}

function Set-HostSafetySnapshotExactly {
    param(
        [Parameter(Mandatory)][object] $Boundary,
        [Parameter(Mandatory)][object] $DesiredSnapshot,
        [Parameter(Mandatory)][object] $ExpectedCurrent,
        [Parameter(Mandatory)][ref] $MutationState
    )

    [void](Assert-A4SProductMutationBoundary -Boundary $Boundary -Label 'exact restore entry')
    $current = Get-HostSafetyAggregateRecord
    [void](Assert-AuthorizedHostSafetyAggregate -Current $current `
        -ExpectedSnapshot $ExpectedCurrent.snapshot -ExpectedSha256 $ExpectedCurrent.sha256 `
        -Boundary 'exact restore entry')
    $desired = Get-HostSafetyAggregateRecord -Snapshot $DesiredSnapshot
    if ($current.sha256 -ceq $desired.sha256 -and
        (Compare-HostSafetySnapshot -Expected $DesiredSnapshot -Actual $current.snapshot)) {
        $MutationState.Value = [ordered]@{
            label = 'already exact'; inFlight = $false
            allowed = @($current); lastVerified = $current
        }
        return $current
    }

    $absent = [pscustomobject][ordered]@{ exists = $false; values = @(); subkeys = @() }
    $current = Invoke-AuthorizedHostSafetyMutationStep -Boundary $Boundary `
        -Before $current -AfterSnapshot $absent -MutationState $MutationState `
        -Label 'delete prior HostSafety tree' -Mutation { Remove-HostSafetyRegistryTree }
    if (-not [bool]$DesiredSnapshot.exists) { return $current }

    $empty = [pscustomobject][ordered]@{ exists = $true; values = @(); subkeys = @() }
    $current = Invoke-AuthorizedHostSafetyMutationStep -Boundary $Boundary `
        -Before $current -AfterSnapshot $empty -MutationState $MutationState `
        -Label 'create HostSafety root' -Mutation {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
            try {
                $key = $base.CreateSubKey($hostSafetySubKey, $true)
                if ($null -eq $key) { throw 'Could not create HostSafety root.' }
                try { $key.Flush() } finally { $key.Dispose() }
            }
            finally { $base.Dispose() }
        }
    $currentReference = [ref]$current
    Set-HostSafetyTreeProgressively -Boundary $Boundary -DesiredNode $DesiredSnapshot `
        -ExpectedRoot $empty -ExpectedNode $empty -RelativePath '' `
        -CurrentAggregate $currentReference -MutationState $MutationState
    $final = Get-HostSafetyAggregateRecord
    [void](Assert-AuthorizedHostSafetyAggregate -Current $final `
        -ExpectedSnapshot $DesiredSnapshot -ExpectedSha256 $desired.sha256 `
        -Boundary 'exact restore final aggregate')
    return $final
}

function Get-KnownMutationAggregate {
    param(
        [Parameter(Mandatory)][object] $MutationState,
        [Parameter(Mandatory)][object] $Current,
        [Parameter(Mandatory)][string] $Boundary
    )
    foreach ($allowed in @($MutationState.allowed)) {
        if ($allowed.sha256 -ceq $Current.sha256 -and
            (Compare-HostSafetySnapshot -Expected $allowed.snapshot -Actual $Current.snapshot)) {
            return $Current
        }
    }
    throw "$Boundary observed an unknown/intervening HostSafety aggregate; rollback is forbidden to avoid overwriting external state."
}

function Restore-HostSafety {
    param(
        [Parameter(Mandatory)][string] $Bundle,
        [string] $ProbeHost,
        [object] $AuthorizedCurrentSnapshot,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $AuthorizedCurrentSha256
    )

    Assert-AllTrackedHostsStopped -ProbeHost $ProbeHost
    $validated = Read-ValidatedHostSafetyBackup -Bundle $Bundle
    $boundary = Enter-A4SProductMutationBoundary
    $rollback = $null
    $mutationState = [ordered]@{ label = 'not started'; inFlight = $false; allowed = @(); lastVerified = $null }
    try {
        [void](Assert-A4SProductMutationBoundary -Boundary $boundary -Label 'restore authorization')
        $immediate = Get-HostSafetyAggregateRecord
        [void](Assert-AuthorizedHostSafetyAggregate -Current $immediate `
            -ExpectedSnapshot $AuthorizedCurrentSnapshot `
            -ExpectedSha256 $AuthorizedCurrentSha256 -Boundary 'restore authorization')
        $rollbackPath = Join-Path $validated.bundle ('Rollback-' + [Guid]::NewGuid().ToString('N'))
        $rollbackRecord = New-SafeFreshDirectory -Path $rollbackPath `
            -Description 'HostSafety transactional rollback bundle' -ExpectedParent $validated.bundle
        $rollback = Backup-HostSafety -Bundle $rollbackRecord.finalPath
        if ($rollback.snapshotSha256 -cne $immediate.sha256 -or
            -not (Compare-HostSafetySnapshot -Expected $rollback.manifest.snapshot `
                -Actual $immediate.snapshot)) {
            throw 'Immediate rollback bundle differs from the authorized pre-restore aggregate.'
        }
        [void](Assert-A4SProductMutationBoundary -Boundary $boundary -Label 'post-backup authorization')
        $postBackup = Get-HostSafetyAggregateRecord
        [void](Assert-AuthorizedHostSafetyAggregate -Current $postBackup `
            -ExpectedSnapshot $immediate.snapshot -ExpectedSha256 $immediate.sha256 `
            -Boundary 'post-backup authorization')
        try {
            $restored = Set-HostSafetySnapshotExactly -Boundary $boundary `
                -DesiredSnapshot $validated.manifest.snapshot -ExpectedCurrent $immediate `
                -MutationState ([ref]$mutationState)
            return [ordered]@{
                snapshot = $restored.snapshot
                snapshotSha256 = $restored.sha256
                transaction = 'committed'
                authorizedPreRestoreSha256 = $immediate.sha256
                setupMutexName = $boundary.SetupMutexName
                hostMutexName = $boundary.HostMutexName
                rollbackBundle = $rollback.bundle
                rollbackManifestSha256 = $rollback.manifestSha256
            }
        }
        catch {
            $primary = $_
            [void](Assert-A4SProductMutationBoundary -Boundary $boundary -Label 'rollback authorization')
            $observed = Get-HostSafetyAggregateRecord
            try { $known = Get-KnownMutationAggregate -MutationState $mutationState `
                -Current $observed -Boundary 'rollback authorization' }
            catch {
                throw "HostSafety restore failed ('$($primary.Exception.Message)'). $($_.Exception.Message) Exact pre-restore rollback was not attempted. Bundles retained: '$($validated.bundle)' and '$($rollback.bundle)'."
            }
            $rollbackState = [ordered]@{
                label = 'rollback not started'; inFlight = $false
                allowed = @($known); lastVerified = $known
            }
            try {
                $rolledBack = Set-HostSafetySnapshotExactly -Boundary $boundary `
                    -DesiredSnapshot $rollback.manifest.snapshot -ExpectedCurrent $known `
                    -MutationState ([ref]$rollbackState)
                if ($rolledBack.sha256 -cne $immediate.sha256 -or
                    -not (Compare-HostSafetySnapshot -Expected $immediate.snapshot `
                        -Actual $rolledBack.snapshot)) {
                    throw 'Rollback completed with a non-identical aggregate.'
                }
            }
            catch {
                $rollbackError = $_
                $rollbackObserved = Get-HostSafetyAggregateRecord
                try { [void](Get-KnownMutationAggregate -MutationState $rollbackState `
                    -Current $rollbackObserved -Boundary 'rollback failure') }
                catch {
                    throw "HostSafety restore failed ('$($primary.Exception.Message)'); rollback failed ('$($rollbackError.Exception.Message)'); and an unknown/intervening aggregate was observed ('$($_.Exception.Message)'). No further mutation was attempted."
                }
                throw "HostSafety restore failed ('$($primary.Exception.Message)') and exact rollback failed ('$($rollbackError.Exception.Message)'). Known state was retained; both bundles remain."
            }
            throw "HostSafety restore failed but the exact authorized immediate state was rolled back successfully. Primary error: $($primary.Exception.Message). Rollback bundle retained at '$($rollback.bundle)'."
        }
    }
    finally { Exit-A4SProductMutationBoundary -Boundary $boundary }
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

function Assert-ValidA4SReleaseRecord {
    param([Parameter(Mandatory)][object] $Record)

    Assert-ExactPropertySet -Object $Record -Names @(
        'schemaVersion', 'product', 'sourceCommit', 'hostSha256', 'dllSha256',
        'hostFileVersion', 'dllFileVersion', 'hostReportedVersion') `
        -Description 'A4S immutable release record'
    if ($Record.schemaVersion -isnot [int32] -or [int]$Record.schemaVersion -ne 1 -or
        $Record.product -isnot [string] -or [string]$Record.product -cne 'A4SMenu') {
        throw 'The A4S release record has an unsupported schema or product identity.'
    }
    if ($Record.sourceCommit -isnot [string] -or
        [string]$Record.sourceCommit -notmatch '\A[A-Fa-f0-9]{40,64}\z') {
        throw 'The A4S release record source commit is invalid.'
    }
    foreach ($hashName in @('hostSha256', 'dllSha256')) {
        if ($Record.$hashName -isnot [string] -or
            [string]$Record.$hashName -notmatch '\A[A-Fa-f0-9]{64}\z') {
            throw "The A4S release record $hashName is invalid."
        }
    }
    foreach ($versionName in @('hostFileVersion', 'dllFileVersion', 'hostReportedVersion')) {
        if ($Record.$versionName -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Record.$versionName) -or
            ([string]$Record.$versionName).Length -gt 256) {
            throw "The A4S release record $versionName is invalid."
        }
    }
    return $true
}

function Read-VerifiedA4SReleaseRecord {
    param([Parameter(Mandatory)][string] $Path)

    $recordPath = Get-CanonicalPathRecord -Path $Path `
        -Description 'A4S immutable release record' -Kind File
    $repository = Get-CanonicalPathRecord -Path $repoRoot `
        -Description 'A4S source repository' -Kind Directory
    if (-not (Test-PathWithin -Path $recordPath.finalPath -Parent $repository.finalPath)) {
        throw 'The A4S release record must be a tracked file inside this repository.'
    }
    $prefix = $repository.finalPath.TrimEnd('\') + '\'
    $relative = $recordPath.finalPath.Substring($prefix.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains(':') -or
        $relative -match '(^|/)\.\.(/|$)' -or $relative.StartsWith('/')) {
        throw 'The A4S release record has an unsafe repository-relative path.'
    }
    $stream = [IO.File]::Open($recordPath.finalPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        # The no-write/no-delete sharing boundary stays held from byte capture
        # through the Git blob check, closing the parse/hash/path replacement race.
        $lockedPath = Get-CanonicalPathRecord -Path $recordPath.finalPath `
            -Description 'locked A4S immutable release record' -Kind File
        if ($lockedPath.identity -cne $recordPath.identity -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                $lockedPath.finalPath, $recordPath.finalPath)) {
            throw 'The A4S release record path identity changed before it could be locked.'
        }
        if ($stream.Length -le 0 -or $stream.Length -gt 1048576) {
            throw 'The A4S release record must be between 1 byte and 1 MiB.'
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'The A4S release record ended during its locked read.' }
            $offset += $read
        }
        $textOffset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        try {
            $raw = [Text.UTF8Encoding]::new($false, $true).GetString(
                $bytes, $textOffset, $bytes.Length - $textOffset)
        }
        catch { throw "The A4S release record is not strict UTF-8: $($_.Exception.Message)" }
        try { $record = $raw | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "The A4S release record is not valid JSON: $($_.Exception.Message)" }
        [void](Assert-ValidA4SReleaseRecord -Record $record)

        [void](& git -C $repository.finalPath ls-files --error-unmatch -- $relative 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'The A4S release record is not tracked by Git.' }
        $recordCommit = ((& git -C $repository.finalPath log -1 --format=%H -- `
            $relative 2>$null) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $recordCommit -notmatch '\A[A-Fa-f0-9]{40,64}\z') {
            throw 'Could not bind the release record to an immutable Git commit.'
        }
        [void](& git -C $repository.finalPath cat-file -e `
            "$($record.sourceCommit)^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'The release record source commit does not exist.' }
        [void](& git -C $repository.finalPath merge-base --is-ancestor `
            ([string]$record.sourceCommit) $recordCommit 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw 'The release record commit does not descend from its claimed source commit.'
        }
        $committedBlob = ((& git -C $repository.finalPath rev-parse `
            "$recordCommit`:$relative" 2>$null) | Out-String).Trim()
        $workingBlob = ((& git -C $repository.finalPath hash-object --no-filters -- `
            $recordPath.finalPath 2>$null) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $committedBlob -notmatch '\A[A-Fa-f0-9]{40,64}\z' -or
            $workingBlob -cne $committedBlob) {
            throw 'The locked release record is not byte-identical to its immutable committed blob.'
        }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $recordSha256 = ([BitConverter]::ToString(
                $algorithm.ComputeHash($bytes))).Replace('-', '')
        }
        finally { $algorithm.Dispose() }
        return [pscustomobject][ordered]@{
            path = $recordPath.finalPath
            pathIdentity = $recordPath.identity
            gitRelativePath = $relative
            recordCommit = $recordCommit
            recordBlob = $committedBlob
            recordSha256 = $recordSha256
            record = $record
        }
    }
    finally { $stream.Dispose() }
}

function Assert-BinaryBindingsMatchReleaseRecord {
    param(
        [Parameter(Mandatory)][object] $Release,
        [Parameter(Mandatory)][object] $Host,
        [Parameter(Mandatory)][object] $Dll
    )

    [void](Assert-ValidA4SReleaseRecord -Record $Release.record)
    if ($Host.sha256 -cne ([string]$Release.record.hostSha256).ToUpperInvariant() -or
        $Dll.sha256 -cne ([string]$Release.record.dllSha256).ToUpperInvariant() -or
        $Host.fileVersion -cne [string]$Release.record.hostFileVersion -or
        $Dll.fileVersion -cne [string]$Release.record.dllFileVersion -or
        $Host.reportedVersion -cne [string]$Release.record.hostReportedVersion) {
        throw 'The supplied host/DLL identities do not match the verified immutable release record.'
    }
    return $true
}

function Get-BinaryBinding {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role,
        [switch] $QueryHostVersion
    )

    $record = Get-CanonicalPathRecord -Path $Path -Description "$Role binary" -Kind File
    $stream = [IO.File]::Open($record.finalPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $locked = Get-CanonicalPathRecord -Path $record.finalPath `
            -Description "$Role locked binary" -Kind File
        if ($locked.identity -cne $record.identity -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                $locked.finalPath, $record.finalPath)) {
            throw "$Role binary path identity changed before it could be locked."
        }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $sha256 = ([BitConverter]::ToString(
                $algorithm.ComputeHash($stream))).Replace('-', '')
        }
        finally { $algorithm.Dispose() }
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
            sha256 = $sha256
            length = [uint64]$stream.Length
            fileVersion = $version.FileVersion
            productVersion = $version.ProductVersion
            reportedVersion = $reported
            sourceBinding = $script:Evidence.sourceBinding
            verifiedSourceCommit = $script:Evidence.verifiedSourceCommit
        }
    }
    finally { $stream.Dispose() }
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

function Assert-ExactHostObservation {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object[]] $Residents,
        [Parameter(Mandatory)][uint32] $SingletonPid,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Residents.Count -ne 1) {
        throw "$Label expected exactly one same-user host across all sessions; found $($Residents.Count)."
    }
    $actual = $Residents[0]
    if ([uint32]$actual.pid -ne [uint32]$Expected.pid -or
        [int]$actual.sessionId -ne [int]$Expected.sessionId -or
        [string]$actual.startTimeUtc -cne [string]$Expected.startTimeUtc -or
        -not (Test-A4SPathEqual -First ([string]$actual.path) -Second ([string]$Expected.path)) -or
        [string]$actual.sha256 -cne [string]$Expected.sha256) {
        throw "$Label host PID/session/path/hash/start identity is not exact."
    }
    if ($SingletonPid -ne [uint32]$Expected.pid) {
        throw "$Label singleton window belongs to PID $SingletonPid instead of exact host PID $($Expected.pid)."
    }
    return $actual
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
    $expected = [ordered]@{
        pid = $Process.Id
        sessionId = $Process.SessionId
        startTimeUtc = $Process.StartTime.ToUniversalTime().ToString('o')
        path = $expectedPath.finalPath
        sha256 = $expectedHash
    }
    $resident = @(Get-SameUserA4SHostProcesses)
    $singletonPid = [A4SFailureRecoveryNative]::GetHostWindowProcessId()
    return Assert-ExactHostObservation -Expected $expected -Residents $resident `
        -SingletonPid $singletonPid -Label $Label
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

function Assert-A4SReadyBoundary {
    param(
        [Parameter(Mandatory)][object] $Checkpoint,
        [Parameter(Mandatory)][string] $ExpectedDll,
        [Parameter(Mandatory)][Diagnostics.Process] $ResidentProcess,
        [Parameter(Mandatory)][string] $HostExecutable,
        [Parameter(Mandatory)][string] $Label
    )

    if ([int]$Checkpoint.host.statusExitCode -ne $hostStatusReadyExit) {
        throw "$Label is not a READY host boundary."
    }
    Assert-ExactA4SMapping -Checkpoint $Checkpoint -ExpectedDll $ExpectedDll
    $exactHost = Assert-ExactResidentHost -Process $ResidentProcess `
        -Executable $HostExecutable -Label $Label
    $Checkpoint.host['exactResident'] = $exactHost
    $Checkpoint['mappingUniqueness'] = [ordered]@{
        exactCount = 1
        expectedDll = [IO.Path]::GetFullPath($ExpectedDll)
        explorerPid = $Checkpoint.explorer.pid
        exactHostPid = $exactHost.pid
    }
    return $Checkpoint
}

function Assert-A4SSafetyDisabledBoundary {
    param(
        [Parameter(Mandatory)][object] $Checkpoint,
        [Parameter(Mandatory)][Diagnostics.Process] $ResidentProcess,
        [Parameter(Mandatory)][string] $HostExecutable,
        [Parameter(Mandatory)][string] $Label
    )

    if ([int]$Checkpoint.host.statusExitCode -ne $hostStatusSafetyDisabled -or
        $Checkpoint.a4sMappings.Count -ne 0 -or
        [int]$Checkpoint.visibleMenuWindowCount -ne 0) {
        throw "$Label did not have the exact SAFETY_DISABLED zero-mapping/zero-window state."
    }
    $exactHost = Assert-ExactResidentHost -Process $ResidentProcess `
        -Executable $HostExecutable -Label $Label
    $Checkpoint.host['exactResident'] = $exactHost
    $Checkpoint['mappingUniqueness'] = [ordered]@{
        exactCount = 0
        expectedState = 'SAFETY_DISABLED'
        explorerPid = $Checkpoint.explorer.pid
        exactHostPid = $exactHost.pid
    }
    return $Checkpoint
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
    $finalMappingCount = -1
    $finalWindowCount = -1
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
            retentionReason = $null
            authorizedCurrentHostSafetySha256 = $null
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
                $finalInjection = Assert-NoA4SMapping -Explorer $finalExplorer `
                    -Label 'isolated final no-injection proof'
                $finalMappingCount = @($finalInjection.mappings).Count
                $finalWindowCount = [int]$finalInjection.visibleMenuWindowCount
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
                $restoreAuthorization = Add-HostSafetyRestoreAuthorizationCheckpoint `
                    -Label 'isolated-restore-authorized'
                $restoreResult = Restore-HostSafety -Bundle $bundle -ProbeHost $sourceHost `
                    -AuthorizedCurrentSnapshot $restoreAuthorization.snapshot `
                    -AuthorizedCurrentSha256 $restoreAuthorization.sha256
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

        $cleanupAllowed = Test-A4STemporaryCleanupAllowed `
            -AllHostsStopped $hostsStopped `
            -MappingInspectionSucceeded $noInjectionConclusive `
            -MappingCount $finalMappingCount -WindowCount $finalWindowCount `
            -SafetyRestored $safetyRestored
        if ($cleanupAllowed) {
            try {
                Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                    -BackupPrepared $backupPrepared -Bundle $bundle `
                    -Reason 'Validated recursive cleanup was authorized and is in progress.'
                Remove-A4STemporaryRoot -Root $temporaryRoot
                Clear-RetainedTemporaryRootEvidence
            }
            catch {
                [void]$script:Evidence.errors.Add("Temporary case cleanup failed: $($_.Exception.Message)")
                Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                    -BackupPrepared $backupPrepared -Bundle $bundle `
                    -Reason "Validated recursive cleanup threw or only partially removed the root: $($_.Exception.Message)"
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                -BackupPrepared $backupPrepared -Bundle $bundle `
                -Reason 'Cleanup authorization was denied because host, mapping/window, or HostSafety restoration proof was incomplete.'
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
            evidencePersisted = $false
            process = $process
        }
    }
    catch { $process.Dispose(); throw }
}

function Assert-TerminationRequestReadyForWait {
    param([Parameter(Mandatory)][object] $Request)

    if ($null -eq $Request.oldExplorer -or [uint32]$Request.oldExplorer.pid -eq 0 -or
        [uint64]$Request.issuedFileTimeUtc -eq 0 -or
        [uint64]$Request.killReturnedFileTimeUtc -lt [uint64]$Request.issuedFileTimeUtc -or
        -not [bool]$Request.evidencePersisted) {
        throw 'Explorer termination cannot be awaited before exact post-kill evidence is durably persisted.'
    }
    return $true
}

function Complete-ValidatedExplorerTermination {
    param([Parameter(Mandatory)][object] $Request)
    try {
        [void](Assert-TerminationRequestReadyForWait -Request $Request)
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
        [Parameter(Mandatory)][string] $ExpectedDll,
        [Parameter(Mandatory)][uint32] $ExplorerProcessId,
        [Parameter(Mandatory)][Diagnostics.Process] $ResidentProcess
    )

    $before = Get-A4SCheckpoint -Label 'one-menu-before-toggle' `
        -HostExecutable $Executable -KnownHostProcessId $ResidentProcess.Id
    if ($before.explorer.pid -ne $ExplorerProcessId -or
        [int]$before.visibleMenuWindowCount -ne 0) {
        throw 'One-menu assertion did not start at the expected Explorer with zero visible menus.'
    }
    [void](Assert-A4SReadyBoundary -Checkpoint $before -ExpectedDll $ExpectedDll `
        -ResidentProcess $ResidentProcess -HostExecutable $Executable `
        -Label 'one-menu pre-toggle boundary')
    $open = Invoke-A4SHostCommand -Executable $Executable -Argument '--toggle'
    if ($open.exitCode -ne 0 -or -not (Wait-A4SCondition -TimeoutSeconds 8 -Condition {
        [A4SFailureRecoveryNative]::CountVisibleMenuWindows($ExplorerProcessId) -eq 1
    })) {
        throw 'Reconnect toggle did not produce exactly one visible A4S menu window.'
    }
    $visible = Get-A4SCheckpoint -Label 'one-menu-visible' `
        -HostExecutable $Executable -KnownHostProcessId $ResidentProcess.Id
    if ($visible.explorer.pid -ne $ExplorerProcessId -or
        [int]$visible.visibleMenuWindowCount -ne 1) {
        throw 'One-menu assertion lost the exact one-window state after opening.'
    }
    [void](Assert-A4SReadyBoundary -Checkpoint $visible -ExpectedDll $ExpectedDll `
        -ResidentProcess $ResidentProcess -HostExecutable $Executable `
        -Label 'one-menu visible boundary')
    $close = Invoke-A4SHostCommand -Executable $Executable -Argument '--toggle'
    if ($close.exitCode -ne 0 -or -not (Wait-A4SCondition -TimeoutSeconds 8 -Condition {
        [A4SFailureRecoveryNative]::CountVisibleMenuWindows($ExplorerProcessId) -eq 0
    })) {
        throw 'Reconnect toggle did not close the single A4S menu window.'
    }
    $closed = Get-A4SCheckpoint -Label 'one-menu-closed' `
        -HostExecutable $Executable -KnownHostProcessId $ResidentProcess.Id
    if ($closed.explorer.pid -ne $ExplorerProcessId -or
        [int]$closed.visibleMenuWindowCount -ne 0) {
        throw 'One-menu assertion did not return to the exact zero-window state.'
    }
    [void](Assert-A4SReadyBoundary -Checkpoint $closed -ExpectedDll $ExpectedDll `
        -ResidentProcess $ResidentProcess -HostExecutable $Executable `
        -Label 'one-menu closed boundary')
    return [ordered]@{
        openExitCode = $open.exitCode
        closeExitCode = $close.exitCode
        exactWindowCount = 1
        exactMappingCount = 1
        exactHostCount = 1
        oneMenuOneHookObservable = $true
        before = $before
        visible = $visible
        closed = $closed
    }
}

function Invoke-LiveFailureRecoveryQualification {
    param(
        [Parameter(Mandatory)][string] $SourceHost,
        [Parameter(Mandatory)][string] $SourceDll,
        [Parameter(Mandatory)][string] $VerifiedReleaseRecordPath,
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
    $finalMappingCount = -1
    $finalWindowCount = -1
    $safetyRestored = $false

    try {
        $release = Read-VerifiedA4SReleaseRecord -Path $VerifiedReleaseRecordPath
        $sourceHostBinding = Get-BinaryBinding -Path $sourceHost -Role 'source A4SMenuHost' `
            -QueryHostVersion
        $sourceDllBinding = Get-BinaryBinding -Path $sourceDll -Role 'source A4SMenu.dll'
        [void](Assert-BinaryBindingsMatchReleaseRecord -Release $release `
            -Host $sourceHostBinding -Dll $sourceDllBinding)
        $script:Evidence.sourceBinding = 'verified-release-record'
        $script:Evidence.verifiedSourceCommit = ([string]$release.record.sourceCommit).ToLowerInvariant()
        $script:Evidence.releaseRecord = [ordered]@{
            path = $release.path
            pathIdentity = $release.pathIdentity
            gitRelativePath = $release.gitRelativePath
            recordCommit = $release.recordCommit
            recordBlob = $release.recordBlob
            recordSha256 = $release.recordSha256
        }
        foreach ($binding in @($sourceHostBinding, $sourceDllBinding)) {
            $binding['sourceBinding'] = $script:Evidence.sourceBinding
            $binding['verifiedSourceCommit'] = $script:Evidence.verifiedSourceCommit
        }
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
            retentionReason = $null
            authorizedCurrentHostSafetySha256 = $null
            cleanupInstructions = $null
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
        [void](Assert-A4SReadyBoundary -Checkpoint $ready -ExpectedDll $runtimeDll `
            -ResidentProcess $resident -HostExecutable $runtimeHost -Label 'initial-ready')
        $ready.oneMenuAssertion = Invoke-OneMenuAssertion -Executable $runtimeHost `
            -ExpectedDll $runtimeDll -ExplorerProcessId $ready.explorer.pid `
            -ResidentProcess $resident
        Add-EvidenceCheckpoint $ready

        $crashBoundaries = [Collections.ArrayList]::new()
        [uint64[]]$priorGuardTimes = @()
        for ($crashIndex = 1; $crashIndex -le $crashThreshold; $crashIndex++) {
            $before = Get-A4SCheckpoint -Label "crash-$crashIndex-armed" `
                -HostExecutable $runtimeHost -KnownHostProcessId $resident.Id
            [void](Assert-A4SReadyBoundary -Checkpoint $before -ExpectedDll $runtimeDll `
                -ResidentProcess $resident -HostExecutable $runtimeHost `
                -Label "crash-$crashIndex-armed")
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
                $terminationRequest.evidencePersisted = $true
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
                [void](Assert-A4SReadyBoundary -Checkpoint $after -ExpectedDll $runtimeDll `
                    -ResidentProcess $resident -HostExecutable $runtimeHost `
                    -Label "crash-$crashIndex-reconnected")
                if ($after.explorer.pid -ne $replacement.explorer.pid) {
                    throw "Guarded crash $crashIndex status and replacement taskbar refer to different Explorer processes."
                }
                $after.oneMenuAssertion = Invoke-OneMenuAssertion -Executable $runtimeHost `
                    -ExpectedDll $runtimeDll -ExplorerProcessId $after.explorer.pid `
                    -ResidentProcess $resident
            }
            else {
                [void](Wait-A4SHostStatus -Executable $runtimeHost `
                    -ExpectedExitCode $hostStatusSafetyDisabled `
                    -TimeoutSeconds $ReconnectTimeoutSeconds -ResidentProcess $resident)
                $after = Get-A4SCheckpoint -Label 'crash-3-safety-disabled' `
                    -HostExecutable $runtimeHost -KnownHostProcessId $resident.Id
                if ($after.explorer.pid -ne $replacement.explorer.pid) {
                    throw 'The third crash did not leave the replacement Explorer uninjected and without A4S UI.'
                }
                [void](Assert-A4SSafetyDisabledBoundary -Checkpoint $after `
                    -ResidentProcess $resident -HostExecutable $runtimeHost `
                    -Label 'crash-3-safety-disabled')
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
        [void](Assert-A4SReadyBoundary -Checkpoint $recovered -ExpectedDll $runtimeDll `
            -ResidentProcess $resident -HostExecutable $runtimeHost `
            -Label 'safety-reset-recovered-ready')
        if ($recovered.hostSafety.exists) {
            throw '--reset-safety recovered injection but retained crash-guard registry state.'
        }
        $recovered.oneMenuAssertion = Invoke-OneMenuAssertion -Executable $runtimeHost `
            -ExpectedDll $runtimeDll -ExplorerProcessId $recovered.explorer.pid `
            -ResidentProcess $resident
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
            $cleanupRequest.evidencePersisted = $true
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
                $finalMappingCount = @($finalInjection.mappings).Count
                $finalWindowCount = [int]$finalInjection.visibleMenuWindowCount
                $noInjectionConclusive = $finalMappingCount -eq 0 -and
                    $finalWindowCount -eq 0
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
                $restoreAuthorization = Add-HostSafetyRestoreAuthorizationCheckpoint `
                    -Label 'live-restore-authorized'
                $restoreResult = Restore-HostSafety -Bundle $bundle -ProbeHost $sourceHost `
                    -AuthorizedCurrentSnapshot $restoreAuthorization.snapshot `
                    -AuthorizedCurrentSha256 $restoreAuthorization.sha256
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

        $cleanupAllowed = Test-A4STemporaryCleanupAllowed `
            -AllHostsStopped $allTrackedStopped `
            -MappingInspectionSucceeded $noInjectionConclusive `
            -MappingCount $finalMappingCount -WindowCount $finalWindowCount `
            -SafetyRestored $safetyRestored -CleanupRestartRequired $true `
            -CleanupRestartComplete $cleanupRestartComplete
        if ($cleanupAllowed) {
            try {
                Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                    -BackupPrepared $backupPrepared -Bundle $bundle `
                    -Reason 'Validated post-restart recursive cleanup was authorized and is in progress.'
                Remove-A4STemporaryRoot -Root $temporaryRoot
                Clear-RetainedTemporaryRootEvidence
            }
            catch {
                [void]$script:Evidence.errors.Add("Temporary runtime cleanup failed: $($_.Exception.Message)")
                Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                    -BackupPrepared $backupPrepared -Bundle $bundle `
                    -Reason "Validated post-restart cleanup threw or only partially removed the root: $($_.Exception.Message)"
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                -BackupPrepared $backupPrepared -Bundle $bundle `
                -Reason 'Cleanup authorization was denied because restart, host, mapping/window, or HostSafety restoration proof was incomplete.'
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

if ($PSCmdlet.ParameterSetName -eq 'ContractLibrary') {
    # Dot-sourced by the offline companion so its executable negative cases call
    # the exact production validators without loading native code or mutating state.
    return
}
elseif ($PSCmdlet.ParameterSetName -eq 'Offline') {
    & (Join-Path $PSScriptRoot 'Test-A4SFailureRecoveryContracts.ps1')
    Write-Host 'OFFLINE GO: no runtime, registry, Explorer, staging, or evidence changes were made.'
    Write-Host 'ISOLATED/LIVE NO-GO: neither executable mode was run; both remain deferred pending explicit review and authorization.'
    Write-Host 'Live N6/N9 additionally requires the conspicuous crash switch, exact confirmation text, and a verified immutable release record.'
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
                    -SourceDll $DllPath -VerifiedReleaseRecordPath $ReleaseRecordPath `
                    -RequestedEvidencePath $EvidencePath
            }
            'Recover' {
                # Initialize-A4SFailureRecoveryNative above enforces x64 before
                # recovery validation, process checks, or registry deletion.
                Assert-AllTrackedHostsStopped
                $restoreResult = Restore-HostSafety -Bundle $RecoveryBundle `
                    -AuthorizedCurrentSha256 $ExpectedCurrentHostSafetySha256
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
