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
    [string] $ExpectedManifestSha256,

    [Parameter(Mandatory, ParameterSetName = 'Recover')]
    [ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
    [string] $ExpectedCurrentHostSafetySha256,

    [Parameter(Mandatory, ParameterSetName = 'Isolated')]
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $HostPath,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [string] $DllPath,

    [Parameter(Mandatory, ParameterSetName = 'Isolated')]
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
$script:A4SInvocationParameterSet = $PSCmdlet.ParameterSetName

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
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class A4SFailureRecoveryNative
{
    public sealed class ProductMutationBoundary : IDisposable
    {
        private Mutex lifecycle;
        private Mutex setup;
        private Mutex safety;
        private Mutex host;
        private bool lifecycleOwned;
        private bool setupOwned;
        private bool safetyOwned;
        private bool hostOwned;

        internal ProductMutationBoundary(Mutex lifecycle, bool lifecycleOwned,
            Mutex setup, bool setupOwned, Mutex safety, bool safetyOwned,
            Mutex host, bool hostOwned, string lifecycleName, string setupName,
            string safetyName, string hostName)
        {
            this.lifecycle = lifecycle;
            this.lifecycleOwned = lifecycleOwned;
            this.setup = setup;
            this.setupOwned = setupOwned;
            this.safety = safety;
            this.safetyOwned = safetyOwned;
            this.host = host;
            this.hostOwned = hostOwned;
            LifecycleMutexName = lifecycleName;
            SetupMutexName = setupName;
            HostSafetyMutexName = safetyName;
            HostMutexName = hostName;
        }

        public string LifecycleMutexName { get; private set; }
        public string SetupMutexName { get; private set; }
        public string HostSafetyMutexName { get; private set; }
        public string HostMutexName { get; private set; }
        public bool IsHeld { get { return lifecycleOwned && setupOwned &&
            safetyOwned && hostOwned; } }

        public void Dispose()
        {
            if (hostOwned) { host.ReleaseMutex(); hostOwned = false; }
            if (host != null) { host.Dispose(); host = null; }
            if (safetyOwned) { safety.ReleaseMutex(); safetyOwned = false; }
            if (safety != null) { safety.Dispose(); safety = null; }
            if (setupOwned) { setup.ReleaseMutex(); setupOwned = false; }
            if (setup != null) { setup.Dispose(); setup = null; }
            if (lifecycleOwned) { lifecycle.ReleaseMutex(); lifecycleOwned = false; }
            if (lifecycle != null) { lifecycle.Dispose(); lifecycle = null; }
        }
    }

    public sealed class MutationContext
    {
        internal ProductMutationBoundary Boundary { get; private set; }
        public string TargetIdentifier { get; private set; }
        public string Nonce { get; private set; }
        public string Kind { get; private set; }

        internal MutationContext(ProductMutationBoundary boundary, string target,
            string nonce, string kind)
        {
            Boundary = boundary;
            TargetIdentifier = target;
            Nonce = nonce;
            Kind = kind;
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

    public sealed class TaskbarWindowRecord
    {
        public uint ProcessId { get; set; }
        public uint ThreadId { get; set; }
        public long WindowHandle { get; set; }
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
    private static extern bool CreateDirectoryW(string path, IntPtr securityAttributes);

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

    private static string LifecycleMutexName()
    {
        return @"Global\A4SMenu.Lifecycle.v1." +
            WindowsIdentity.GetCurrent().User.Value;
    }

    private static string HostSafetyMutexName()
    {
        return @"Global\A4SMenu.HostSafety.v1." +
            WindowsIdentity.GetCurrent().User.Value;
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
        string lifecycleName = LifecycleMutexName();
        string setupName = SetupMutexName();
        string safetyName = HostSafetyMutexName();
        string hostName = HostMutexName();
        Mutex lifecycle = null;
        Mutex setup = null;
        Mutex safety = null;
        Mutex host = null;
        bool lifecycleOwned = false;
        bool setupOwned = false;
        bool safetyOwned = false;
        bool hostOwned = false;
        try
        {
            // Fixed global order shared with product servicing:
            // Lifecycle -> Setup -> HostSafety -> current-desktop Host.
            lifecycle = new Mutex(false, lifecycleName);
            lifecycleOwned = WaitMutex(lifecycle);
            if (!lifecycleOwned)
                throw new InvalidOperationException(
                    "The A4S product lifecycle mutex is already owned.");
            setup = new Mutex(false, setupName);
            setupOwned = WaitMutex(setup);
            if (!setupOwned)
                throw new InvalidOperationException(
                    "The A4S product servicing mutex is already owned.");
            safety = new Mutex(false, safetyName);
            safetyOwned = WaitMutex(safety);
            if (!safetyOwned)
                throw new InvalidOperationException(
                    "The A4S HostSafety mutation mutex is already owned.");
            host = new Mutex(false, hostName);
            hostOwned = WaitMutex(host);
            if (!hostOwned)
                throw new InvalidOperationException(
                    "The current desktop A4S host mutex is already owned.");
            return new ProductMutationBoundary(lifecycle, lifecycleOwned,
                setup, setupOwned, safety, safetyOwned, host, hostOwned,
                lifecycleName, setupName, safetyName, hostName);
        }
        catch
        {
            if (hostOwned) host.ReleaseMutex();
            if (host != null) host.Dispose();
            if (safetyOwned) safety.ReleaseMutex();
            if (safety != null) safety.Dispose();
            if (setupOwned) setup.ReleaseMutex();
            if (setup != null) setup.Dispose();
            if (lifecycleOwned) lifecycle.ReleaseMutex();
            if (lifecycle != null) lifecycle.Dispose();
            throw;
        }
    }

    private static bool IsContractTarget(string target)
    {
        return Regex.IsMatch(target ?? String.Empty,
            @"\ASoftware\\A4SMenuFailureRecoveryContract_[A-Fa-f0-9]{32}\z",
            RegexOptions.CultureInvariant);
    }

    public static MutationContext CreateProductMutationContext(
        ProductMutationBoundary boundary, string target, string nonce)
    {
        if (boundary == null || !boundary.IsHeld)
            throw new InvalidOperationException(
                "A held product boundary is required for a mutation context.");
        if (!String.Equals(target, @"Software\A4SMenu\HostSafety",
            StringComparison.Ordinal))
            throw new InvalidOperationException("The product mutation target is not exact.");
        if (!Regex.IsMatch(nonce ?? String.Empty, @"\A[A-Fa-f0-9]{32}\z"))
            throw new InvalidOperationException("The mutation-context nonce is invalid.");
        return new MutationContext(boundary, target, nonce, "product");
    }

    public static MutationContext CreateContractMutationContext(string target,
        string nonce)
    {
        if (!IsContractTarget(target))
            throw new InvalidOperationException(
                "A contract mutation context cannot target product HostSafety.");
        if (!Regex.IsMatch(nonce ?? String.Empty, @"\A[A-Fa-f0-9]{32}\z"))
            throw new InvalidOperationException("The mutation-context nonce is invalid.");
        return new MutationContext(null, target, nonce, "contract-sandbox");
    }

    public static void ValidateMutationContext(MutationContext context,
        string target, string expectedNonce, bool requireProductBoundary)
    {
        if (context == null || !String.Equals(context.TargetIdentifier, target,
                StringComparison.Ordinal) ||
            !String.Equals(context.Nonce, expectedNonce, StringComparison.Ordinal))
            throw new InvalidOperationException(
                "The opaque mutation context target or nonce is invalid.");
        if (requireProductBoundary)
        {
            if (!String.Equals(context.Kind, "product", StringComparison.Ordinal) ||
                context.Boundary == null || !context.Boundary.IsHeld ||
                !String.Equals(target, @"Software\A4SMenu\HostSafety",
                    StringComparison.Ordinal))
                throw new InvalidOperationException(
                    "The product mutation context no longer holds every required mutex.");
        }
        else if (!String.Equals(context.Kind, "contract-sandbox",
                StringComparison.Ordinal) || !IsContractTarget(target))
            throw new InvalidOperationException(
                "The contract mutation context is invalid or targets production.");
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

    public static TaskbarWindowRecord GetTaskbarWindowRecord()
    {
        IntPtr taskbar = FindWindowW("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero)
            throw new InvalidOperationException("Shell_TrayWnd was not found.");
        uint processId;
        uint threadId = GetWindowThreadProcessId(taskbar, out processId);
        if (threadId == 0 || processId == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not resolve the taskbar Explorer process.");
        return new TaskbarWindowRecord {
            ProcessId = processId,
            ThreadId = threadId,
            WindowHandle = taskbar.ToInt64()
        };
    }

    public static uint GetTaskbarProcessId()
    {
        return GetTaskbarWindowRecord().ProcessId;
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

    public static void CreateFreshDirectory(string path)
    {
        if (!CreateDirectoryW(path, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not atomically create the fresh directory: " + path);
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
    [A4SFailureRecoveryNative]::CreateFreshDirectory($fullPath)
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
    $allowedDirectoryFiles = @{
        missing = @('A4SMenuHost.exe')
        corrupt = @('A4SMenuHost.exe', 'A4SMenu.dll')
        incompatible = @('A4SMenuHost.exe', 'A4SMenu.dll')
        'safety-reset-no-dll' = @('A4SMenuHost.exe')
        'valid-runtime' = @('A4SMenuHost.exe', 'A4SMenu.dll')
    }
    $allowedDirectories = @($allowedDirectoryFiles.Keys)
    $allowedRootFiles = @('HostSafetyBackup.json', 'HostSafety.reg')
    $files = [Collections.ArrayList]::new()
    $directories = [Collections.ArrayList]::new()

    foreach ($child in @(Get-ChildItem -LiteralPath $safe.finalPath -Force -ErrorAction Stop)) {
        if ($child.PSIsContainer) {
            if ([string]$child.Name -match '\Acontract-transaction-[A-Fa-f0-9]{32}\z') {
                $allowedDirectoryFiles[[string]$child.Name] = @(
                    'A4SRegistryRollback.json', 'A4SRegistryTransaction.json')
                $allowedDirectories = @($allowedDirectoryFiles.Keys)
            }
            if ([string]$child.Name -notin $allowedDirectories) {
                throw "Temporary cleanup found an unknown direct directory: $($child.FullName)"
            }
            $directory = Get-CanonicalPathRecord -Path $child.FullName `
                -Description 'temporary cleanup direct directory' -Kind Directory
            if (-not (Test-PathWithin -Path $directory.finalPath -Parent $safe.finalPath)) {
                throw "Temporary cleanup directory escaped the validated root: $($directory.finalPath)"
            }
            foreach ($grandchild in @(Get-ChildItem -LiteralPath $directory.finalPath `
                    -Force -ErrorAction Stop)) {
                if ($grandchild.PSIsContainer -or
                    [string]$grandchild.Name -notin @($allowedDirectoryFiles[$child.Name])) {
                    throw "Temporary cleanup permits only exact known files one level below the root: $($grandchild.FullName)"
                }
                $file = Get-CanonicalPathRecord -Path $grandchild.FullName `
                    -Description 'temporary cleanup known file' -Kind File
                if (-not (Test-PathWithin -Path $file.finalPath -Parent $directory.finalPath)) {
                    throw "Temporary cleanup file escaped its validated direct directory: $($file.finalPath)"
                }
                [void]$files.Add([ordered]@{ record=$file; parent=$directory })
            }
            [void]$directories.Add($directory)
        }
        else {
            if ([string]$child.Name -notin $allowedRootFiles) {
                throw "Temporary cleanup found an unknown direct file: $($child.FullName)"
            }
            $file = Get-CanonicalPathRecord -Path $child.FullName `
                -Description 'temporary cleanup known direct file' -Kind File
            if (-not (Test-PathWithin -Path $file.finalPath -Parent $safe.finalPath)) {
                throw "Temporary cleanup direct file escaped the validated root: $($file.finalPath)"
            }
            [void]$files.Add([ordered]@{ record=$file; parent=$safe })
        }
    }

    foreach ($entry in @($files)) {
        $parentNow = Get-CanonicalPathRecord -Path $entry.parent.finalPath `
            -Description 'temporary cleanup immediate file parent' -Kind Directory
        $fileNow = Get-CanonicalPathRecord -Path $entry.record.finalPath `
            -Description 'temporary cleanup immediate known file' -Kind File
        if ($parentNow.identity -cne $entry.parent.identity -or
            $fileNow.identity -cne $entry.record.identity -or
            -not (Test-PathWithin -Path $fileNow.finalPath -Parent $parentNow.finalPath)) {
            throw 'A temporary cleanup file or its parent changed identity immediately before deletion.'
        }
        Remove-Item -LiteralPath $fileNow.finalPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $fileNow.finalPath) {
            throw "Temporary cleanup could not prove exact file deletion: $($fileNow.finalPath)"
        }
    }

    foreach ($directory in @($directories)) {
        $directoryNow = Get-CanonicalPathRecord -Path $directory.finalPath `
            -Description 'temporary cleanup immediate direct directory' -Kind Directory
        if ($directoryNow.identity -cne $directory.identity -or
            @(Get-ChildItem -LiteralPath $directoryNow.finalPath -Force -ErrorAction Stop).Count -ne 0) {
            throw 'A temporary direct directory changed identity or was not empty immediately before deletion.'
        }
        Remove-Item -LiteralPath $directoryNow.finalPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $directoryNow.finalPath) {
            throw "Temporary cleanup could not prove exact directory deletion: $($directoryNow.finalPath)"
        }
    }

    $safeAgain = Assert-SafeTemporaryRoot -Root $Root
    if ($safeAgain.identity -cne $safe.identity -or
        @(Get-ChildItem -LiteralPath $safeAgain.finalPath -Force -ErrorAction Stop).Count -ne 0) {
        throw 'The temporary root changed identity or was not empty immediately before deletion.'
    }
    Remove-Item -LiteralPath $safeAgain.finalPath -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $safeAgain.finalPath) {
        throw "Temporary cleanup could not prove exact root deletion: $($safeAgain.finalPath)"
    }
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
        [string] $Bundle,
        [object] $AuthorizedState,
        [string] $ProbeHost
    )

    if ($null -eq $script:Evidence.recovery) {
        $script:Evidence.recovery = [ordered]@{}
    }
    $rootFullPath = [IO.Path]::GetFullPath($Root)
    $quotedRoot = $rootFullPath.Replace("'", "''")
    $script:Evidence.recovery['retainedTemporaryRoot'] = $rootFullPath
    $script:Evidence.recovery['retentionReason'] = $Reason
    if ($BackupPrepared) {
        $script:Evidence.recovery['freshKnownCurrentHostSafetySha256'] = $null
        $script:Evidence.recovery['freshKnownCurrentStateUtc'] = $null
        $script:Evidence.recovery['recoveryCommand'] = $null
        $known = $null
        try {
            if ($null -eq $AuthorizedState) {
                throw 'No harness-produced authorized state sequence is available.'
            }
            $known = Get-A4SConfirmedRecoveryAuthorization `
                -State $AuthorizedState -ProbeHost $ProbeHost
            $script:Evidence.recovery['freshKnownCurrentHostSafetySha256'] = $known.sha256
            $script:Evidence.recovery['freshKnownCurrentStateUtc'] = $known.observedUtc
        }
        catch {
            [void]$script:Evidence.errors.Add(
                "Recovery state could not be re-confirmed under the product mutation boundary: $($_.Exception.Message)")
        }
        $manifestHash = if ($script:Evidence.recovery.Contains('manifestSha256')) {
            [string]$script:Evidence.recovery['manifestSha256']
        } else { $null }
        $recoveryStep = if ($null -ne $known -and
            $manifestHash -match '\A[A-Fa-f0-9]{64}\z' -and
            -not [string]::IsNullOrWhiteSpace($Bundle)) {
            $quotedBundle = $Bundle.Replace("'", "''")
            $command = "run this harness with -RecoverHostSafety -RecoveryBundle '$quotedBundle' -ExpectedManifestSha256 '$manifestHash' -ExpectedCurrentHostSafetySha256 '$($known.sha256)'"
            $script:Evidence.recovery['recoveryCommand'] = $command
            $command
        }
        else {
            'do not run automated recovery: preserve the bundle and obtain a manual registry/state review because current HostSafety could not be matched to the last harness-authorized state under the product mutation boundary'
        }
        $script:Evidence.recovery['cleanupInstructions'] =
            "DO NOT DELETE '$quotedRoot'. Stop every same-user A4SMenuHost in every Windows session; verify the taskbar Explorer has zero A4SMenu.dll mappings and zero A4S menu windows; restart Explorer manually if an image remains pinned; then $recoveryStep. Recovery authenticates the exact manifest and aborts if HostSafety differs from the freshly confirmed aggregate. Delete the retained root only after exact restoration and clean-state inspection."
    }
    else {
        $script:Evidence.recovery['cleanupInstructions'] =
            "DO NOT DELETE '$quotedRoot' until every same-user A4SMenuHost is stopped and Explorer is conclusively free of A4SMenu.dll mappings/windows. No HostSafety backup completed, so this bundle cannot authorize recovery."
    }
    Save-Evidence
}

function Clear-RetainedTemporaryRootEvidence {
    if ($null -ne $script:Evidence.recovery) {
        $script:Evidence.recovery['retainedTemporaryRoot'] = $null
        $script:Evidence.recovery['retentionReason'] = $null
        $script:Evidence.recovery['cleanupInstructions'] = $null
        $script:Evidence.recovery['recoveryCommand'] = $null
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
    return [pscustomobject][ordered]@{
        name = $Name; kind = $kind.ToString(); value = $encoded
    }
}

function Get-RegistryKeyTreeRecord {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey] $Key)

    $values = @($Key.GetValueNames() | Sort-Object | ForEach-Object {
        Get-RegistryValueRecord -Key $Key -Name $_
    })
    $subkeyNames = @($Key.GetSubKeyNames())
    if ($subkeyNames.Count -ne 0) {
        throw ('The flat HostSafety schema forbids registry subkeys; found: ' +
            (($subkeyNames | Sort-Object) -join ', '))
    }
    return [pscustomobject][ordered]@{ values = $values; subkeys = @() }
}

function Get-RegistrySnapshot {
    param([Parameter(Mandatory)][string] $RegistrySubKey)

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
    try {
        $key = $base.OpenSubKey($RegistrySubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject][ordered]@{
                exists = $false; values = @(); subkeys = @()
            }
        }
        try {
            $tree = Get-RegistryKeyTreeRecord -Key $key
            return [pscustomobject][ordered]@{
                exists = $true; values = $tree.values; subkeys = $tree.subkeys
            }
        }
        finally { $key.Dispose() }
    }
    finally { $base.Dispose() }
}

function Get-HostSafetySnapshot {
    return Get-RegistrySnapshot -RegistrySubKey $hostSafetySubKey
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

function Get-RegistryAggregateRecord {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [object] $Snapshot
    )
    if ($null -eq $Snapshot) {
        $Snapshot = Get-RegistrySnapshot -RegistrySubKey $RegistrySubKey
    }
    Assert-ValidRegistryTree -Tree $Snapshot -IsRoot $true
    $json = $Snapshot | ConvertTo-Json -Depth 32 -Compress
    return [pscustomobject][ordered]@{
        snapshot = $Snapshot
        canonicalJson = $json
        sha256 = Get-TextSha256 -Text $json
    }
}

function Get-HostSafetyAggregateRecord {
    param([object] $Snapshot)
    return Get-RegistryAggregateRecord -RegistrySubKey $hostSafetySubKey -Snapshot $Snapshot
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

function New-A4SAuthorizedHostSafetyState {
    param(
        [Parameter(Mandatory)][object] $InitialSnapshot,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $InitialSha256,
        [Parameter(Mandatory)][string] $Action,
        [AllowEmptyCollection()][string[]] $ExpectedMutationActions = @()
    )

    $aggregate = Get-HostSafetyAggregateRecord -Snapshot $InitialSnapshot
    [void](Assert-AuthorizedHostSafetyAggregate -Current $aggregate `
        -ExpectedSnapshot $InitialSnapshot -ExpectedSha256 $InitialSha256 `
        -Boundary 'authorized state initialization')
    return [pscustomobject][ordered]@{
        sequence = 0
        snapshot = Copy-RegistrySnapshotObject -Snapshot $aggregate.snapshot
        sha256 = $aggregate.sha256
        lastAction = $Action
        expectedMutationActions = @($ExpectedMutationActions)
        nextMutationIndex = 0
        restored = $false
        history = [Collections.ArrayList]::new()
    }
}

function Publish-A4SAuthorizedHostSafetyState {
    param([Parameter(Mandatory)][object] $State)

    if ($null -ne $script:Evidence -and $null -ne $script:Evidence.recovery) {
        $script:Evidence.recovery['authorizedCurrentHostSafetySha256'] = $State.sha256
        $script:Evidence.recovery['authorizedStateSequence'] = $State.sequence
        $script:Evidence.recovery['authorizedStateLastAction'] = $State.lastAction
        $script:Evidence.recovery['expectedMutationActions'] = @($State.expectedMutationActions)
        $script:Evidence.recovery['nextExpectedMutationIndex'] = $State.nextMutationIndex
        $script:Evidence.recovery['authorizedStateRestored'] = $State.restored
        $script:Evidence.recovery['authorizedStateHistory'] = @($State.history)
        Save-Evidence
    }
}

function Assert-A4SAuthorizedHostSafetySnapshot {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][object] $Snapshot,
        [Parameter(Mandatory)][string] $Label
    )

    $observed = Get-HostSafetyAggregateRecord -Snapshot $Snapshot
    [void](Assert-AuthorizedHostSafetyAggregate -Current $observed `
        -ExpectedSnapshot $State.snapshot -ExpectedSha256 $State.sha256 -Boundary $Label)
    return $observed
}

function Assert-A4SAuthorizedCurrentHostSafety {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][string] $Label
    )
    $current = Get-HostSafetyAggregateRecord
    [void](Assert-A4SAuthorizedHostSafetySnapshot -State $State `
        -Snapshot $current.snapshot -Label $Label)
    return $current
}

function Get-A4SExpectedAuthorizedActionAdvance {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][string] $Action
    )

    if ([bool]$State.restored) {
        throw "$Action tried to advance a HostSafety authorization that was already restored."
    }
    $isRestore = $Action -ceq 'restore-validated-manifest'
    $nextIndex = [int]$State.nextMutationIndex
    if (-not $isRestore) {
        if ($nextIndex -ge @($State.expectedMutationActions).Count -or
            [string]$State.expectedMutationActions[$nextIndex] -cne $Action) {
            $expected = if ($nextIndex -lt @($State.expectedMutationActions).Count) {
                [string]$State.expectedMutationActions[$nextIndex]
            } else { '<restore only>' }
            throw "$Action is not the next authorized harness mutation; expected $expected."
        }
    }
    return [pscustomobject][ordered]@{
        isRestore = $isRestore
        nextMutationIndex = if ($isRestore) { $nextIndex } else { $nextIndex + 1 }
    }
}

function Set-A4SAuthorizedHostSafetyTransition {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedPreviousSha256,
        [Parameter(Mandatory)][object] $ObservedSnapshot,
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][object] $Proof
    )

    if ($State.sha256 -cne $ExpectedPreviousSha256.ToUpperInvariant()) {
        throw "$Action tried to advance from a stale harness authorization."
    }
    $advance = Get-A4SExpectedAuthorizedActionAdvance -State $State -Action $Action
    $observed = Get-HostSafetyAggregateRecord -Snapshot $ObservedSnapshot
    $current = Get-HostSafetyAggregateRecord
    [void](Assert-AuthorizedHostSafetyAggregate -Current $current `
        -ExpectedSnapshot $observed.snapshot -ExpectedSha256 $observed.sha256 `
        -Boundary "$Action post-transition current-state proof")
    $previous = $State.sha256
    $State.sequence = [int]$State.sequence + 1
    $State.snapshot = Copy-RegistrySnapshotObject -Snapshot $observed.snapshot
    $State.sha256 = $observed.sha256
    $State.lastAction = $Action
    if ($advance.isRestore) { $State.restored = $true }
    else { $State.nextMutationIndex = $advance.nextMutationIndex }
    [void]$State.history.Add([ordered]@{
        sequence = $State.sequence
        utc = Get-UtcText
        action = $Action
        previousSha256 = $previous
        authorizedSha256 = $observed.sha256
        proof = $Proof
    })
    Publish-A4SAuthorizedHostSafetyState -State $State
    return $observed
}

function Confirm-A4SResetSafetyTransition {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedPreviousSha256,
        [Parameter(Mandatory)][object] $ObservedSnapshot,
        [Parameter(Mandatory)][string] $Action
    )
    if ([bool]$ObservedSnapshot.exists -or @($ObservedSnapshot.values).Count -ne 0 -or
        @($ObservedSnapshot.subkeys).Count -ne 0) {
        throw "$Action did not produce the exact known absent HostSafety state."
    }
    return Set-A4SAuthorizedHostSafetyTransition -State $State `
        -ExpectedPreviousSha256 $ExpectedPreviousSha256 `
        -ObservedSnapshot $ObservedSnapshot -Action $Action `
        -Proof ([ordered]@{ transition='ResetSafetyState'; exactAbsent=$true })
}

function Confirm-A4SCrashGuardTransition {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedPreviousSha256,
        [Parameter(Mandatory)][object] $ObservedSnapshot,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int] $Stage,
        [Parameter(Mandatory)][object[]] $Boundaries,
        [uint64[]] $PriorTimestamps = @()
    )
    $proof = Assert-RollingCrashGuardStage -Snapshot $ObservedSnapshot `
        -ExpectedCount $Stage -ExpectedDisabled ($Stage -eq $crashThreshold) `
        -Boundaries $Boundaries -PriorTimestamps $PriorTimestamps
    [void](Set-A4SAuthorizedHostSafetyTransition -State $State `
        -ExpectedPreviousSha256 $ExpectedPreviousSha256 `
        -ObservedSnapshot $ObservedSnapshot -Action "guarded-explorer-crash-$Stage" `
        -Proof $proof)
    return $proof
}

function Confirm-A4SRestoreTransition {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][object] $RestoreResult,
        [Parameter(Mandatory)][object] $DesiredSnapshot,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedManifestSha256
    )
    $desired = Get-HostSafetyAggregateRecord -Snapshot $DesiredSnapshot
    if ([string]$RestoreResult.transaction -cne 'committed' -or
        [string]$RestoreResult.authorizedPreRestoreSha256 -cne $State.sha256 -or
        [string]$RestoreResult.snapshotSha256 -cne $desired.sha256 -or
        [string]$RestoreResult.manifestSha256 -cne $ExpectedManifestSha256.ToUpperInvariant()) {
        throw 'Committed restore result does not prove the exact authorized manifest transition.'
    }
    return Set-A4SAuthorizedHostSafetyTransition -State $State `
        -ExpectedPreviousSha256 $State.sha256 -ObservedSnapshot $DesiredSnapshot `
        -Action 'restore-validated-manifest' -Proof ([ordered]@{
            transition='journaled-restore'
            manifestSha256=$ExpectedManifestSha256.ToUpperInvariant()
            mutationStepCount=$RestoreResult.mutationStepCount
        })
}

function Get-A4SConfirmedRecoveryAuthorization {
    param(
        [Parameter(Mandatory)][object] $State,
        [string] $ProbeHost
    )

    Assert-AllTrackedHostsStopped -ProbeHost $ProbeHost
    $boundary = Enter-A4SProductMutationBoundary
    try {
        [void](Assert-A4SProductMutationBoundary -Boundary $boundary `
            -Label 'retained-root recovery authorization')
        $current = Assert-A4SAuthorizedCurrentHostSafety -State $State `
            -Label 'retained-root recovery authorization'
        return [pscustomobject][ordered]@{
            snapshot = Copy-RegistrySnapshotObject -Snapshot $current.snapshot
            sha256 = $current.sha256
            authorizedSequence = $State.sequence
            authorizedAction = $State.lastAction
            observedUtc = Get-UtcText
            lifecycleMutexName = $boundary.LifecycleMutexName
            setupMutexName = $boundary.SetupMutexName
            hostSafetyMutexName = $boundary.HostSafetyMutexName
            hostMutexName = $boundary.HostMutexName
        }
    }
    finally { Exit-A4SProductMutationBoundary -Boundary $boundary }
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
        if (@($Tree.subkeys).Count -ne 0) {
            throw 'HostSafety recovery supports the exact flat product schema only; subkeys are forbidden.'
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
}

function Read-LockedFileBytesRecord {
    [CmdletBinding(DefaultParameterSetName = 'Expected')]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory, ParameterSetName = 'Expected')]
        [ValidatePattern('\A[A-Fa-f0-9]{64}\z')][string] $ExpectedSha256,
        [Parameter(Mandatory, ParameterSetName = 'Capture')][switch] $CaptureSha256,
        [Parameter(Mandatory)][ValidateRange(1, 16777216)][int] $MaximumBytes
    )

    $record = Get-CanonicalPathRecord -Path $Path -Description $Description -Kind File
    $stream = [IO.File]::Open($record.finalPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $locked = Get-CanonicalPathRecord -Path $record.finalPath `
            -Description "$Description locked identity" -Kind File
        if ($locked.identity -cne $record.identity -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                $locked.finalPath, $record.finalPath)) {
            throw "$Description changed identity before its locked read."
        }
        if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) {
            throw "$Description is empty or exceeds the $MaximumBytes-byte safety limit."
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Description ended during its locked read." }
            $offset += $read
        }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $sha256 = ([BitConverter]::ToString(
                $algorithm.ComputeHash($bytes))).Replace('-', '')
        }
        finally { $algorithm.Dispose() }
        if ($PSCmdlet.ParameterSetName -eq 'Expected' -and
            $sha256 -cne $ExpectedSha256.ToUpperInvariant()) {
            throw "$Description SHA-256 differs from its previously authorized value."
        }
        return [pscustomobject][ordered]@{
            path = $record.finalPath
            pathIdentity = $record.identity
            sha256 = $sha256
            length = [uint64]$bytes.Length
            bytes = $bytes
        }
    }
    finally { $stream.Dispose() }
}

function Read-LockedUtf8JsonRecord {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedSha256
    )

    $raw = Read-LockedFileBytesRecord -Path $Path -Description $Description `
        -ExpectedSha256 $ExpectedSha256 -MaximumBytes 1048576
    $offset = if ($raw.bytes.Length -ge 3 -and $raw.bytes[0] -eq 0xEF -and
        $raw.bytes[1] -eq 0xBB -and $raw.bytes[2] -eq 0xBF) { 3 } else { 0 }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString(
            $raw.bytes, $offset, $raw.bytes.Length - $offset)
    }
    catch { throw "$Description is not strict UTF-8: $($_.Exception.Message)" }
    try { $value = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$Description is not valid JSON: $($_.Exception.Message)" }
    $raw | Add-Member -NotePropertyName value -NotePropertyValue $value
    return $raw
}

function Assert-RegistryExportTargetsHostSafety {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $memory = [IO.MemoryStream]::new($Bytes, $false)
    $reader = [IO.StreamReader]::new($memory, [Text.Encoding]::Unicode,
        $true, 4096, $false)
    try { $text = $reader.ReadToEnd() }
    finally { $reader.Dispose(); $memory.Dispose() }
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

function Assert-ValidatedHostSafetyManifestObject {
    param([Parameter(Mandatory)][object] $Manifest)

    Assert-ExactPropertySet -Object $Manifest -Names @('schemaVersion', 'backupId',
        'createdUtc', 'registryHive', 'registryPath', 'registrySubKey', 'registryView',
        'snapshot', 'snapshotSha256', 'regExport') -Description 'HostSafety recovery manifest'
    if ($Manifest.schemaVersion -ne 3 -or
        [string]$Manifest.registryHive -cne 'HKEY_CURRENT_USER' -or
        [string]$Manifest.registryPath -cne $hostSafetyRegPath -or
        [string]$Manifest.registrySubKey -cne $hostSafetySubKey -or
        [string]$Manifest.registryView -cne 'Registry64') {
        throw 'HostSafety recovery manifest has an unsupported schema, hive, target, or registry view.'
    }
    $backupId = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$Manifest.backupId, 'N', [ref]$backupId)) {
        throw 'HostSafety recovery manifest has an invalid backup ID.'
    }
    $created = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$Manifest.createdUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$created)) {
        throw 'HostSafety recovery manifest has an invalid creation timestamp.'
    }
    if ($created.Kind -ne [DateTimeKind]::Utc) {
        throw 'HostSafety recovery manifest creation timestamp is not explicitly UTC.'
    }
    Assert-ValidRegistryTree -Tree $Manifest.snapshot -IsRoot $true
    $snapshotAggregate = Get-HostSafetyAggregateRecord -Snapshot $Manifest.snapshot
    if ([string]$Manifest.snapshotSha256 -notmatch '\A[A-Fa-f0-9]{64}\z' -or
        $snapshotAggregate.sha256 -cne ([string]$Manifest.snapshotSha256).ToUpperInvariant()) {
        throw 'HostSafety recovery manifest snapshot aggregate hash is invalid.'
    }
    if ([bool]$Manifest.snapshot.exists) {
        if ($null -eq $Manifest.regExport) {
            throw 'Existing HostSafety backup lacks a registry export record.'
        }
        Assert-ExactPropertySet -Object $Manifest.regExport `
            -Names @('relativePath', 'sha256', 'length') `
            -Description 'HostSafety registry export record'
        if ([string]$Manifest.regExport.relativePath -cne 'HostSafety.reg') {
            throw 'HostSafety registry export must use the exact direct-child filename HostSafety.reg.'
        }
        if ([string]$Manifest.regExport.sha256 -notmatch '\A[A-Fa-f0-9]{64}\z') {
            throw 'HostSafety registry export has an invalid SHA-256 value.'
        }
        try { [void][uint64]$Manifest.regExport.length }
        catch { throw 'HostSafety registry export has an invalid length.' }
    }
    elseif ($null -ne $Manifest.regExport) {
        throw 'Absent HostSafety backup unexpectedly contains a registry export record.'
    }
    return $snapshotAggregate
}

function Read-ValidatedHostSafetyBackup {
    param(
        [Parameter(Mandatory)][string] $Bundle,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedManifestSha256
    )

    $bundleRecord = Get-ValidatedRecoveryBundle -Bundle $Bundle
    $manifestPath = Join-Path $bundleRecord.finalPath 'HostSafetyBackup.json'
    $lockedManifest = Read-LockedUtf8JsonRecord -Path $manifestPath `
        -Description 'HostSafety recovery manifest' `
        -ExpectedSha256 $ExpectedManifestSha256
    if (-not (Test-PathWithin -Path $lockedManifest.path -Parent $bundleRecord.finalPath)) {
        throw 'HostSafety recovery manifest escaped its bundle.'
    }
    $manifest = $lockedManifest.value
    $snapshotAggregate = Assert-ValidatedHostSafetyManifestObject -Manifest $manifest
    $regFile = $null
    if ([bool]$manifest.snapshot.exists) {
        $regFile = Join-Path $bundleRecord.finalPath 'HostSafety.reg'
        $regRecord = Read-LockedFileBytesRecord -Path $regFile `
            -Description 'HostSafety registry export' `
            -ExpectedSha256 ([string]$manifest.regExport.sha256) `
            -MaximumBytes 16777216
        if (-not (Test-PathWithin -Path $regRecord.path -Parent $bundleRecord.finalPath)) {
            throw 'HostSafety registry export escaped its bundle.'
        }
        if ([uint64]$manifest.regExport.length -ne [uint64]$regRecord.length) {
            throw 'HostSafety registry export length does not match the manifest.'
        }
        Assert-RegistryExportTargetsHostSafety -Bytes $regRecord.bytes
        $regFile = $regRecord.path
    }
    return [pscustomobject][ordered]@{
        validated = $true
        bundle = $bundleRecord.finalPath
        bundleIdentity = $bundleRecord.identity
        manifestPath = $lockedManifest.path
        manifestIdentity = $lockedManifest.pathIdentity
        manifestSha256 = $lockedManifest.sha256
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
        $lockedExport = Read-LockedFileBytesRecord -Path $regRecord.finalPath `
            -Description 'new HostSafety registry export' -CaptureSha256 `
            -MaximumBytes 16777216
        Assert-RegistryExportTargetsHostSafety -Bytes $lockedExport.bytes
        $regExport = [ordered]@{
            relativePath = 'HostSafety.reg'
            sha256 = $lockedExport.sha256
            length = $lockedExport.length
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
    $manifestText = $manifest | ConvertTo-Json -Depth 32
    $manifestSha256 = Get-TextSha256 -Text $manifestText
    Write-DurableNewText -Path $manifestPath -Text $manifestText
    return Read-ValidatedHostSafetyBackup -Bundle $bundleRecord.finalPath `
        -ExpectedManifestSha256 $manifestSha256
}

function Enter-A4SProductMutationBoundary {
    if ([string]$script:A4SInvocationParameterSet -notin @(
        'Isolated', 'Live', 'Recover')) {
        throw 'Product mutation authority is unavailable in ContractLibrary and Offline modes.'
    }
    $boundary = [A4SFailureRecoveryNative]::AcquireProductMutationBoundary()
    if (-not $boundary -or -not $boundary.IsHeld) {
        if ($boundary) { $boundary.Dispose() }
        throw 'Could not acquire the exact Lifecycle/Setup/HostSafety/host mutation boundary.'
    }
    return $boundary
}

function Assert-A4SProductMutationMode {
    param([Parameter(Mandatory)][string] $Label)
    if ([string]$script:A4SInvocationParameterSet -notin @(
        'Isolated', 'Live', 'Recover')) {
        throw "$Label is forbidden outside an explicitly selected product execution mode."
    }
    return $true
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
    if ($null -eq $Boundary -or
        $Boundary.GetType().FullName -cne
            'A4SFailureRecoveryNative+ProductMutationBoundary' -or
        -not $Boundary.IsHeld -or
        [string]$Boundary.LifecycleMutexName -notmatch
            '\AGlobal\\A4SMenu\.Lifecycle\.v1\.S-\d-(?:\d+-)+\d+\z' -or
        [string]$Boundary.SetupMutexName -notmatch '\AGlobal\\A4SMenu\.Setup\.v1\.[A-F0-9]{32}\z' -or
        [string]$Boundary.HostSafetyMutexName -notmatch
            '\AGlobal\\A4SMenu\.HostSafety\.v1\.S-\d-(?:\d+-)+\d+\z' -or
        [string]$Boundary.HostMutexName -notmatch '\ALocal\\A4SMenu\.Host\.Instance\.v1\.[0-9]+\.[A-F0-9]{16}\z') {
        throw "$Label does not hold the exact product Lifecycle, Setup, HostSafety, and current-desktop host mutexes."
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
        'Binary' { return ,([Convert]::FromBase64String([string]$Record.value)) }
        'None' { return ,([Convert]::FromBase64String([string]$Record.value)) }
        'MultiString' { return ,([string[]]@($Record.value)) }
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

function Test-RegistryAggregateEqual {
    param(
        [Parameter(Mandatory)][object] $First,
        [Parameter(Mandatory)][object] $Second
    )
    return [string]$First.sha256 -ceq [string]$Second.sha256 -and
        (Compare-HostSafetySnapshot -Expected $First.snapshot -Actual $Second.snapshot)
}

function Read-A4SRegistryRollbackBinding {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][string] $Bundle,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedManifestSha256
    )

    if ($TargetKind -ceq 'product') {
        if (-not [StringComparer]::Ordinal.Equals($RegistrySubKey, $hostSafetySubKey)) {
            throw 'A product rollback binding must target the exact HostSafety key.'
        }
        $validated = Read-ValidatedHostSafetyBackup -Bundle $Bundle `
            -ExpectedManifestSha256 $ExpectedManifestSha256
        return [pscustomobject][ordered]@{
            bundle = $validated.bundle
            manifestPath = $validated.manifestPath
            manifestSha256 = $validated.manifestSha256
            snapshot = Copy-RegistrySnapshotObject -Snapshot $validated.manifest.snapshot
            snapshotSha256 = $validated.snapshotSha256
        }
    }

    if ($RegistrySubKey -notmatch
        '\ASoftware\\A4SMenuFailureRecoveryContract_[A-Fa-f0-9]{32}\z') {
        throw 'A contract rollback binding cannot target product HostSafety.'
    }
    $bundleRecord = Get-CanonicalPathRecord -Path $Bundle `
        -Description 'contract registry rollback bundle' -Kind Directory
    $temporary = Get-CanonicalPathRecord -Path ([IO.Path]::GetTempPath()) `
        -Description 'OS temporary directory' -Kind Directory
    if (-not (Test-PathWithin -Path $bundleRecord.finalPath -Parent $temporary.finalPath)) {
        throw 'A contract registry rollback bundle must remain below the OS temporary directory.'
    }
    Assert-PathOutsideRepository -Path $bundleRecord.finalPath `
        -Description 'contract registry rollback bundle'
    $manifestPath = Join-Path $bundleRecord.finalPath 'A4SRegistryRollback.json'
    $locked = Read-LockedUtf8JsonRecord -Path $manifestPath `
        -Description 'contract registry rollback manifest' `
        -ExpectedSha256 $ExpectedManifestSha256
    if (-not (Test-PathWithin -Path $locked.path -Parent $bundleRecord.finalPath)) {
        throw 'The contract rollback manifest escaped its validated bundle.'
    }
    Assert-ExactPropertySet -Object $locked.value -Names @(
        'schemaVersion', 'createdUtc', 'registrySubKey', 'snapshot',
        'snapshotSha256') -Description 'contract registry rollback manifest'
    if ($locked.value.schemaVersion -ne 1 -or
        [string]$locked.value.registrySubKey -cne $RegistrySubKey) {
        throw 'The contract rollback manifest has an unsupported schema or target.'
    }
    $created = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$locked.value.createdUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$created) -or
        $created.Kind -ne [DateTimeKind]::Utc) {
        throw 'The contract rollback manifest timestamp is not explicitly UTC.'
    }
    $aggregate = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $locked.value.snapshot
    if ([string]$locked.value.snapshotSha256 -notmatch '\A[A-Fa-f0-9]{64}\z' -or
        [string]$locked.value.snapshotSha256 -cne $aggregate.sha256) {
        throw 'The contract rollback manifest snapshot hash is invalid.'
    }
    return [pscustomobject][ordered]@{
        bundle = $bundleRecord.finalPath
        manifestPath = $locked.path
        manifestSha256 = $locked.sha256
        snapshot = Copy-RegistrySnapshotObject -Snapshot $locked.value.snapshot
        snapshotSha256 = $aggregate.sha256
    }
}

function Assert-A4SRegistryTransactionDescriptorObject {
    param(
        [Parameter(Mandatory)][object] $Descriptor,
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][object] $RollbackBinding
    )

    Assert-ExactPropertySet -Object $Descriptor -Names @(
        'schemaVersion', 'transactionId', 'createdUtc', 'updatedUtc',
        'targetIdentifier', 'targetKind', 'rollbackBundle',
        'rollbackManifestSha256', 'rollbackSnapshot', 'rollbackSha256',
        'originalDesiredSnapshot', 'originalDesiredSha256', 'desiredSnapshot',
        'desiredSha256', 'expectedSnapshot', 'expectedSha256', 'recoveryIntent',
        'phase', 'step', 'authorizedBeforeSnapshot', 'authorizedBeforeSha256',
        'authorizedAfterSnapshot', 'authorizedAfterSha256') `
        -Description 'registry transaction descriptor'
    $transactionId = [Guid]::Empty
    if ($Descriptor.schemaVersion -ne 1 -or
        -not [Guid]::TryParseExact([string]$Descriptor.transactionId, 'N',
            [ref]$transactionId) -or
        [string]$Descriptor.targetIdentifier -cne $RegistrySubKey -or
        [string]$Descriptor.targetKind -cne $TargetKind) {
        throw 'The registry transaction descriptor has an unsupported schema, ID, or target.'
    }
    foreach ($property in @('createdUtc', 'updatedUtc')) {
        $timestamp = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$Descriptor.$property,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp) -or
            $timestamp.Kind -ne [DateTimeKind]::Utc) {
            throw "The registry transaction descriptor $property is not explicitly UTC."
        }
    }
    if (-not (Test-A4SPathEqual -First ([string]$Descriptor.rollbackBundle) `
        -Second ([string]$RollbackBinding.bundle)) -or
        [string]$Descriptor.rollbackManifestSha256 -cne
            [string]$RollbackBinding.manifestSha256) {
        throw 'The registry transaction descriptor is not bound to its locked rollback manifest.'
    }
    foreach ($pair in @(
        @('rollbackSnapshot', 'rollbackSha256'),
        @('originalDesiredSnapshot', 'originalDesiredSha256'),
        @('desiredSnapshot', 'desiredSha256'),
        @('expectedSnapshot', 'expectedSha256'))) {
        $aggregate = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
            -Snapshot $Descriptor.($pair[0])
        if ([string]$Descriptor.($pair[1]) -notmatch '\A[A-Fa-f0-9]{64}\z' -or
            [string]$Descriptor.($pair[1]) -cne $aggregate.sha256) {
            throw "The registry transaction descriptor $($pair[1]) is invalid."
        }
    }
    if ([string]$Descriptor.rollbackSha256 -cne
        [string]$RollbackBinding.snapshotSha256 -or
        -not (Compare-HostSafetySnapshot -Expected $Descriptor.rollbackSnapshot `
            -Actual $RollbackBinding.snapshot)) {
        throw 'The descriptor rollback aggregate differs from its locked manifest.'
    }
    if ([string]$Descriptor.recoveryIntent -notin @(
        'apply-desired', 'resume-desired', 'rollback-immediate') -or
        [string]$Descriptor.phase -notin @(
        'prepared', 'recovery-prepared', 'before-primitive', 'after-primitive',
        'before-rollback', 'after-rollback', 'committed', 'rolled-back') -or
        [int]$Descriptor.step -lt 0) {
        throw 'The registry transaction descriptor has an unsupported intent, phase, or step.'
    }
    $authorizationNull = $null -eq $Descriptor.authorizedBeforeSnapshot -and
        $null -eq $Descriptor.authorizedBeforeSha256 -and
        $null -eq $Descriptor.authorizedAfterSnapshot -and
        $null -eq $Descriptor.authorizedAfterSha256
    if (-not $authorizationNull) {
        if ($null -eq $Descriptor.authorizedBeforeSnapshot -or
            $null -eq $Descriptor.authorizedAfterSnapshot) {
            throw 'The descriptor contains a partial primitive authorization.'
        }
        foreach ($pair in @(
            @('authorizedBeforeSnapshot', 'authorizedBeforeSha256'),
            @('authorizedAfterSnapshot', 'authorizedAfterSha256'))) {
            $aggregate = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
                -Snapshot $Descriptor.($pair[0])
            if ([string]$Descriptor.($pair[1]) -cne $aggregate.sha256) {
                throw "The registry transaction descriptor $($pair[1]) is invalid."
            }
        }
    }
    return $true
}

function Read-A4SRegistryTransactionDescriptor {
    [CmdletBinding(DefaultParameterSetName='Capture')]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][string] $RollbackBundle,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $RollbackManifestSha256,
        [Parameter(Mandatory, ParameterSetName='Expected')]
        [ValidatePattern('\A[A-Fa-f0-9]{64}\z')][string] $ExpectedDescriptorSha256,
        [Parameter(Mandatory, ParameterSetName='Capture')][switch] $CaptureSha256
    )

    $rollback = Read-A4SRegistryRollbackBinding -RegistrySubKey $RegistrySubKey `
        -TargetKind $TargetKind -Bundle $RollbackBundle `
        -ExpectedManifestSha256 $RollbackManifestSha256
    $requestedDescriptor = [IO.Path]::GetFullPath($Path)
    $descriptorParent = Get-CanonicalPathRecord `
        -Path (Split-Path -Parent $requestedDescriptor) `
        -Description 'registry transaction descriptor parent' -Kind Directory
    $expectedName = if ($TargetKind -ceq 'product') {
        'HostSafetyTransaction.json'
    } else { 'A4SRegistryTransaction.json' }
    if (-not (Test-A4SPathEqual -First $descriptorParent.finalPath `
        -Second $rollback.bundle) -or
        [IO.Path]::GetFileName($requestedDescriptor) -cne $expectedName) {
        throw 'The transaction descriptor is not the exact direct child of its rollback bundle.'
    }
    $locked = if ($PSCmdlet.ParameterSetName -ceq 'Expected') {
        Read-LockedUtf8JsonRecord -Path $Path `
            -Description 'registry transaction descriptor' `
            -ExpectedSha256 $ExpectedDescriptorSha256
    } else {
        $raw = Read-LockedFileBytesRecord -Path $Path `
            -Description 'registry transaction descriptor' -CaptureSha256 `
            -MaximumBytes 1048576
        $offset = if ($raw.bytes.Length -ge 3 -and $raw.bytes[0] -eq 0xEF -and
            $raw.bytes[1] -eq 0xBB -and $raw.bytes[2] -eq 0xBF) { 3 } else { 0 }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString(
                $raw.bytes, $offset, $raw.bytes.Length - $offset)
            $value = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch { throw "Registry transaction descriptor is invalid UTF-8 JSON: $($_.Exception.Message)" }
        $raw | Add-Member -NotePropertyName value -NotePropertyValue $value
        $raw
    }
    if (-not (Test-PathWithin -Path $locked.path -Parent $rollback.bundle) -or
        -not (Test-A4SPathEqual -First (Split-Path -Parent $locked.path) `
            -Second $rollback.bundle)) {
        throw 'The registry transaction descriptor escaped its rollback bundle.'
    }
    [void](Assert-A4SRegistryTransactionDescriptorObject -Descriptor $locked.value `
        -RegistrySubKey $RegistrySubKey -TargetKind $TargetKind `
        -RollbackBinding $rollback)
    return [pscustomobject][ordered]@{
        path = $locked.path
        pathIdentity = $locked.pathIdentity
        sha256 = $locked.sha256
        value = $locked.value
        rollback = $rollback
    }
}

function New-A4SRegistryTransactionDescriptor {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][object] $Desired,
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $RollbackBinding
    )

    $rollbackAggregate = [pscustomobject]@{
        snapshot=$RollbackBinding.snapshot
        sha256=$RollbackBinding.snapshotSha256
    }
    if (-not (Test-RegistryAggregateEqual -First $Expected `
        -Second $rollbackAggregate)) {
        throw 'The transaction expected aggregate differs from its locked immediate rollback manifest.'
    }
    $fullDescriptorPath = [IO.Path]::GetFullPath($Path)
    $descriptorParent = Get-CanonicalPathRecord `
        -Path (Split-Path -Parent $fullDescriptorPath) `
        -Description 'new registry transaction descriptor parent' -Kind Directory
    $expectedName = if ($TargetKind -ceq 'product') {
        'HostSafetyTransaction.json'
    } else { 'A4SRegistryTransaction.json' }
    if (-not (Test-A4SPathEqual -First $descriptorParent.finalPath `
        -Second $RollbackBinding.bundle) -or
        [IO.Path]::GetFileName($fullDescriptorPath) -cne $expectedName) {
        throw 'A new transaction descriptor must be the exact direct child of its locked rollback bundle.'
    }
    $now = Get-UtcText
    $descriptor = [ordered]@{
        schemaVersion = 1
        transactionId = [Guid]::NewGuid().ToString('N')
        createdUtc = $now
        updatedUtc = $now
        targetIdentifier = $RegistrySubKey
        targetKind = $TargetKind
        rollbackBundle = $RollbackBinding.bundle
        rollbackManifestSha256 = $RollbackBinding.manifestSha256
        rollbackSnapshot = Copy-RegistrySnapshotObject -Snapshot $RollbackBinding.snapshot
        rollbackSha256 = $RollbackBinding.snapshotSha256
        originalDesiredSnapshot = Copy-RegistrySnapshotObject -Snapshot $Desired.snapshot
        originalDesiredSha256 = $Desired.sha256
        desiredSnapshot = Copy-RegistrySnapshotObject -Snapshot $Desired.snapshot
        desiredSha256 = $Desired.sha256
        expectedSnapshot = Copy-RegistrySnapshotObject -Snapshot $Expected.snapshot
        expectedSha256 = $Expected.sha256
        recoveryIntent = 'apply-desired'
        phase = 'prepared'
        step = 0
        authorizedBeforeSnapshot = $null
        authorizedBeforeSha256 = $null
        authorizedAfterSnapshot = $null
        authorizedAfterSha256 = $null
    }
    Write-DurableNewText -Path $fullDescriptorPath `
        -Text ($descriptor | ConvertTo-Json -Depth 32)
    return Read-A4SRegistryTransactionDescriptor -Path $fullDescriptorPath `
        -RegistrySubKey $RegistrySubKey -TargetKind $TargetKind `
        -RollbackBundle $RollbackBinding.bundle `
        -RollbackManifestSha256 $RollbackBinding.manifestSha256 -CaptureSha256
}

function Set-A4SRegistryTransactionDescriptor {
    param(
        [Parameter(Mandatory)][object] $Record,
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][hashtable] $Changes
    )

    $current = Read-A4SRegistryTransactionDescriptor -Path $Record.path `
        -RegistrySubKey $RegistrySubKey -TargetKind $TargetKind `
        -RollbackBundle $Record.rollback.bundle `
        -RollbackManifestSha256 $Record.rollback.manifestSha256 `
        -ExpectedDescriptorSha256 $Record.sha256
    $next = $current.value | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    foreach ($name in $Changes.Keys) {
        if ($name -notin @($next.PSObject.Properties.Name)) {
            throw "A descriptor update tried to add unsupported property '$name'."
        }
        $next.$name = $Changes[$name]
    }
    $next.updatedUtc = Get-UtcText
    [void](Assert-A4SRegistryTransactionDescriptorObject -Descriptor $next `
        -RegistrySubKey $RegistrySubKey -TargetKind $TargetKind `
        -RollbackBinding $current.rollback)
    Write-DurableText -Path $current.path -Text ($next | ConvertTo-Json -Depth 32)
    return Read-A4SRegistryTransactionDescriptor -Path $current.path `
        -RegistrySubKey $RegistrySubKey -TargetKind $TargetKind `
        -RollbackBundle $current.rollback.bundle `
        -RollbackManifestSha256 $current.rollback.manifestSha256 -CaptureSha256
}

function Throw-A4SSimulatedHardInterruption {
    param(
        [Parameter(Mandatory)][string] $ConfiguredPhase,
        [Parameter(Mandatory)][string] $CurrentPhase
    )
    if ($ConfiguredPhase -ceq $CurrentPhase) {
        throw "A4S_SIMULATED_HARD_INTERRUPTION:$CurrentPhase"
    }
}

function Assert-A4SRegistryTransactionTarget {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [switch] $ContractRegistrySandbox
    )
    if ([StringComparer]::OrdinalIgnoreCase.Equals($RegistrySubKey, $hostSafetySubKey)) {
        if ($ContractRegistrySandbox) {
            throw 'The contract-sandbox switch is forbidden for the production HostSafety key.'
        }
        return 'product'
    }
    if ($ContractRegistrySandbox -and
        $RegistrySubKey -match '\ASoftware\\A4SMenuFailureRecoveryContract_[A-Fa-f0-9]{32}\z') {
        return 'contract-sandbox'
    }
    throw "Registry transaction target is not the exact product key or an isolated contract sandbox: $RegistrySubKey"
}

function Invoke-A4SRegistryPrimitive {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][object] $MutationContext,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{32}\z')]
        [string] $ContextNonce,
        [Parameter(Mandatory)][ValidateSet('CreateKey', 'DeleteKey', 'SetValue', 'DeleteValue')]
        [string] $Operation,
        [object] $ValueRecord
    )

    if ([StringComparer]::Ordinal.Equals($RegistrySubKey, $hostSafetySubKey)) {
        [void](Assert-A4SProductMutationMode -Label 'HostSafety registry primitive')
    }
    [A4SFailureRecoveryNative]::ValidateMutationContext($MutationContext,
        $RegistrySubKey, $ContextNonce,
        [StringComparer]::Ordinal.Equals($RegistrySubKey, $hostSafetySubKey))
    $separator = $RegistrySubKey.LastIndexOf('\')
    if ($separator -le 0 -or $separator -ge $RegistrySubKey.Length - 1) {
        throw "Registry transaction target is not an exact child key: $RegistrySubKey"
    }
    $parentPath = $RegistrySubKey.Substring(0, $separator)
    $leafName = $RegistrySubKey.Substring($separator + 1)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser, $hostSafetyRegistryView)
    try {
        switch ($Operation) {
            'CreateKey' {
                $parent = $base.OpenSubKey($parentPath, $true)
                if (-not $parent) {
                    throw "Registry parent is absent; creating paths outside the exact target is forbidden: $parentPath"
                }
                try {
                    $existing = $parent.OpenSubKey($leafName, $false)
                    if ($existing) {
                        $existing.Dispose()
                        throw "Registry key already exists: $RegistrySubKey"
                    }
                    $key = $parent.CreateSubKey($leafName, $true)
                    if (-not $key) { throw "Could not create registry key: $RegistrySubKey" }
                    try { $key.Flush() } finally { $key.Dispose() }
                    $parent.Flush()
                }
                finally { $parent.Dispose() }
            }
            'DeleteKey' {
                $parent = $base.OpenSubKey($parentPath, $true)
                if (-not $parent) {
                    throw "Registry parent is absent before exact key deletion: $parentPath"
                }
                try {
                    $key = $parent.OpenSubKey($leafName, $false)
                    if (-not $key) {
                        throw "Registry key is absent before exact deletion: $RegistrySubKey"
                    }
                    try {
                        if ($key.ValueCount -ne 0 -or $key.SubKeyCount -ne 0) {
                            throw "Registry key is not empty before exact non-recursive deletion: $RegistrySubKey"
                        }
                    }
                    finally { $key.Dispose() }
                    $parent.DeleteSubKey($leafName, $true)
                    $parent.Flush()
                }
                finally { $parent.Dispose() }
            }
            'SetValue' {
                if ($null -eq $ValueRecord) { throw 'SetValue requires an exact value record.' }
                $key = $base.OpenSubKey($RegistrySubKey, $true)
                if (-not $key) { throw "Registry key is absent before exact value creation: $RegistrySubKey" }
                try {
                    if (@($key.GetValueNames() | Where-Object {
                            [StringComparer]::OrdinalIgnoreCase.Equals($_, [string]$ValueRecord.name)
                        }).Count -ne 0) {
                        throw "Registry value already exists before exact creation: $($ValueRecord.name)"
                    }
                    $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                        [Microsoft.Win32.RegistryValueKind], [string]$ValueRecord.kind, $false)
                    $key.SetValue([string]$ValueRecord.name,
                        (Convert-RegistryValueForWrite -Record $ValueRecord), $kind)
                    $key.Flush()
                }
                finally { $key.Dispose() }
            }
            'DeleteValue' {
                if ($null -eq $ValueRecord) { throw 'DeleteValue requires an exact value record.' }
                $key = $base.OpenSubKey($RegistrySubKey, $true)
                if (-not $key) { throw "Registry key is absent before exact value deletion: $RegistrySubKey" }
                try {
                    if (@($key.GetValueNames() | Where-Object {
                            [StringComparer]::OrdinalIgnoreCase.Equals($_, [string]$ValueRecord.name)
                        }).Count -ne 1) {
                        throw "Registry value is absent before exact deletion: $($ValueRecord.name)"
                    }
                    $key.DeleteValue([string]$ValueRecord.name, $true)
                    $key.Flush()
                }
                finally { $key.Dispose() }
            }
        }
    }
    finally { $base.Dispose() }
}

function Invoke-A4SRegistryJournaledStep {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][object] $MutationContext,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{32}\z')]
        [string] $ContextNonce,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][ref] $DescriptorRecord,
        [Parameter(Mandatory)][ref] $CurrentAggregate,
        [Parameter(Mandatory)][object] $AfterSnapshot,
        [Parameter(Mandatory)][ValidateSet('CreateKey', 'DeleteKey', 'SetValue', 'DeleteValue')]
        [string] $Operation,
        [object] $ValueRecord,
        [Parameter(Mandatory)][ValidateSet('CreateKey', 'DeleteKey', 'SetValue', 'DeleteValue')]
        [string] $InverseOperation,
        [object] $InverseValueRecord,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.ArrayList] $Journal,
        [Parameter(Mandatory)][ref] $StepNumber,
        [Parameter(Mandatory)][scriptblock] $ValidateBoundary,
        [int] $InjectFailureAfterStep = 0,
        [string] $InjectHardInterruptionPhase = 'none'
    )

    $StepNumber.Value = [int]$StepNumber.Value + 1
    $step = [int]$StepNumber.Value
    [A4SFailureRecoveryNative]::ValidateMutationContext($MutationContext,
        $RegistrySubKey, $ContextNonce, $TargetKind -ceq 'product')
    [void](& $ValidateBoundary "registry mutation step $step preflight")
    $before = $CurrentAggregate.Value
    $observedBefore = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
    if (-not (Test-RegistryAggregateEqual -First $before -Second $observedBefore)) {
        throw "A4S_UNKNOWN_REGISTRY_STATE: step $step preflight differs from the authorized journal state."
    }
    $after = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $AfterSnapshot
    $entry = [pscustomobject][ordered]@{
        step = $step
        operation = $Operation
        inverseOperation = $InverseOperation
        inverseValueRecord = if ($InverseValueRecord) {
            Copy-RegistrySnapshotObject -Snapshot $InverseValueRecord
        } else { $null }
        before = $before
        after = $after
    }
    $DescriptorRecord.Value = Set-A4SRegistryTransactionDescriptor `
        -Record $DescriptorRecord.Value -RegistrySubKey $RegistrySubKey `
        -TargetKind $TargetKind -Changes @{
            phase='before-primitive'; step=$step
            authorizedBeforeSnapshot=(Copy-RegistrySnapshotObject -Snapshot $before.snapshot)
            authorizedBeforeSha256=$before.sha256
            authorizedAfterSnapshot=(Copy-RegistrySnapshotObject -Snapshot $after.snapshot)
            authorizedAfterSha256=$after.sha256
        }
    Throw-A4SSimulatedHardInterruption `
        -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'before-primitive'
    $journaled = $false
    try {
        Invoke-A4SRegistryPrimitive -RegistrySubKey $RegistrySubKey `
            -MutationContext $MutationContext -ContextNonce $ContextNonce `
            -Operation $Operation -ValueRecord $ValueRecord
        [void](& $ValidateBoundary "registry mutation step $step postflight")
        $observedAfter = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
        if (-not (Test-RegistryAggregateEqual -First $after -Second $observedAfter)) {
            throw "A4S_UNKNOWN_REGISTRY_STATE: step $step produced an unplanned aggregate."
        }
        $DescriptorRecord.Value = Set-A4SRegistryTransactionDescriptor `
            -Record $DescriptorRecord.Value -RegistrySubKey $RegistrySubKey `
            -TargetKind $TargetKind -Changes @{
                phase='after-primitive'; step=$step
                authorizedBeforeSnapshot=(Copy-RegistrySnapshotObject -Snapshot $before.snapshot)
                authorizedBeforeSha256=$before.sha256
                authorizedAfterSnapshot=(Copy-RegistrySnapshotObject -Snapshot $after.snapshot)
                authorizedAfterSha256=$after.sha256
            }
        [void]$Journal.Add($entry)
        $journaled = $true
        $CurrentAggregate.Value = $observedAfter
        Throw-A4SSimulatedHardInterruption `
            -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'after-primitive'
        if ($InjectFailureAfterStep -eq $step) {
            throw "A4S_INJECTED_REGISTRY_FAILURE: after mutation step $step"
        }
        return $observedAfter
    }
    catch {
        $primary = $_
        $observedFailure = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
        if (Test-RegistryAggregateEqual -First $after -Second $observedFailure) {
            if (-not $journaled) { [void]$Journal.Add($entry) }
            $CurrentAggregate.Value = $observedFailure
        }
        elseif (Test-RegistryAggregateEqual -First $before -Second $observedFailure) {
            $CurrentAggregate.Value = $observedFailure
        }
        else {
            throw "A4S_UNKNOWN_REGISTRY_STATE: step $step failed and left neither its authorized before nor after aggregate. Primary error: $($primary.Exception.Message)"
        }
        throw $primary
    }
}

function Undo-A4SRegistryJournal {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][object] $MutationContext,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{32}\z')]
        [string] $ContextNonce,
        [Parameter(Mandatory)][ValidateSet('product', 'contract-sandbox')]
        [string] $TargetKind,
        [Parameter(Mandatory)][ref] $DescriptorRecord,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.ArrayList] $Journal,
        [Parameter(Mandatory)][scriptblock] $ValidateBoundary,
        [string] $InjectHardInterruptionPhase = 'none'
    )

    for ($index = $Journal.Count - 1; $index -ge 0; $index--) {
        $entry = $Journal[$index]
        [A4SFailureRecoveryNative]::ValidateMutationContext($MutationContext,
            $RegistrySubKey, $ContextNonce, $TargetKind -ceq 'product')
        [void](& $ValidateBoundary "registry rollback step $($entry.step) preflight")
        $current = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
        if (-not (Test-RegistryAggregateEqual -First $entry.after -Second $current)) {
            throw "A4S_UNKNOWN_REGISTRY_STATE: rollback step $($entry.step) would overwrite an intervening aggregate."
        }
        $DescriptorRecord.Value = Set-A4SRegistryTransactionDescriptor `
            -Record $DescriptorRecord.Value -RegistrySubKey $RegistrySubKey `
            -TargetKind $TargetKind -Changes @{
                phase='before-rollback'; step=[int]$entry.step
                authorizedBeforeSnapshot=(Copy-RegistrySnapshotObject -Snapshot $entry.after.snapshot)
                authorizedBeforeSha256=$entry.after.sha256
                authorizedAfterSnapshot=(Copy-RegistrySnapshotObject -Snapshot $entry.before.snapshot)
                authorizedAfterSha256=$entry.before.sha256
            }
        Throw-A4SSimulatedHardInterruption `
            -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'before-rollback'
        $inverseError = $null
        try {
            Invoke-A4SRegistryPrimitive -RegistrySubKey $RegistrySubKey `
                -MutationContext $MutationContext -ContextNonce $ContextNonce `
                -Operation $entry.inverseOperation -ValueRecord $entry.inverseValueRecord
        }
        catch { $inverseError = $_ }
        [void](& $ValidateBoundary "registry rollback step $($entry.step) postflight")
        $restored = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
        if (-not (Test-RegistryAggregateEqual -First $entry.before -Second $restored)) {
            $detail = if ($inverseError) { $inverseError.Exception.Message } else { 'no primitive error' }
                throw "Registry rollback step $($entry.step) did not restore its exact before aggregate ($detail)."
        }
        $DescriptorRecord.Value = Set-A4SRegistryTransactionDescriptor `
            -Record $DescriptorRecord.Value -RegistrySubKey $RegistrySubKey `
            -TargetKind $TargetKind -Changes @{
                phase='after-rollback'; step=[int]$entry.step
                authorizedBeforeSnapshot=(Copy-RegistrySnapshotObject -Snapshot $entry.after.snapshot)
                authorizedBeforeSha256=$entry.after.sha256
                authorizedAfterSnapshot=(Copy-RegistrySnapshotObject -Snapshot $entry.before.snapshot)
                authorizedAfterSha256=$entry.before.sha256
            }
        Throw-A4SSimulatedHardInterruption `
            -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'after-rollback'
    }
    $final = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
    $DescriptorRecord.Value = Set-A4SRegistryTransactionDescriptor `
        -Record $DescriptorRecord.Value -RegistrySubKey $RegistrySubKey `
        -TargetKind $TargetKind -Changes @{
            phase='rolled-back'; step=0
            authorizedBeforeSnapshot=$null; authorizedBeforeSha256=$null
            authorizedAfterSnapshot=$null; authorizedAfterSha256=$null
        }
    Throw-A4SSimulatedHardInterruption `
        -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'rolled-back'
    return $final
}

function Invoke-A4SRegistrySnapshotTransaction {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][object] $DesiredSnapshot,
        [Parameter(Mandatory)][object] $ExpectedCurrent,
        [object] $ProductBoundary,
        [scriptblock] $ValidateBoundary,
        [switch] $ContractRegistrySandbox,
        [string] $TransactionDescriptorPath,
        [string] $RollbackBundle,
        [ValidatePattern('\A[A-Fa-f0-9]{64}\z')][string] $RollbackManifestSha256,
        [object] $ExistingDescriptorRecord,
        [ValidateRange(0, 1024)][int] $InjectFailureAfterStep = 0,
        [ValidateSet('none', 'prepared', 'recovery-prepared', 'before-primitive',
            'after-primitive', 'committed', 'before-rollback', 'after-rollback',
            'rolled-back')]
        [string] $InjectHardInterruptionPhase = 'none'
    )

    $targetKind = Assert-A4SRegistryTransactionTarget -RegistrySubKey $RegistrySubKey `
        -ContractRegistrySandbox:$ContractRegistrySandbox
    if ($targetKind -ceq 'product') {
        [void](Assert-A4SProductMutationMode -Label 'HostSafety registry transaction')
        if ($null -eq $ProductBoundary -or $null -ne $ValidateBoundary) {
            throw 'A product transaction requires the real product boundary object and forbids a caller-supplied validator.'
        }
        $effectiveBoundaryValidator = {
            param([string] $Label)
            Assert-A4SProductMutationBoundary -Boundary $ProductBoundary -Label $Label
        }.GetNewClosure()
    }
    else {
        if ($null -ne $ProductBoundary -or $null -eq $ValidateBoundary) {
            throw 'A contract-sandbox transaction requires only its explicit test validator.'
        }
        $effectiveBoundaryValidator = $ValidateBoundary
    }
    Assert-ValidRegistryTree -Tree $DesiredSnapshot -IsRoot $true
    Assert-ValidRegistryTree -Tree $ExpectedCurrent.snapshot -IsRoot $true
    [void](& $effectiveBoundaryValidator 'registry transaction entry')
    $initial = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
    if (-not (Test-RegistryAggregateEqual -First $ExpectedCurrent -Second $initial)) {
        throw 'A4S_UNKNOWN_REGISTRY_STATE: transaction entry differs from the previously authorized aggregate.'
    }
    $desired = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $DesiredSnapshot
    if (Test-RegistryAggregateEqual -First $initial -Second $desired) {
        return [pscustomobject][ordered]@{
            snapshot=$initial.snapshot; snapshotSha256=$initial.sha256
            mutationStepCount=0; journalEntryCount=0; transaction='committed'
            transactionDescriptorPath=$null
            transactionDescriptorSha256=$null
        }
    }

    if ([string]::IsNullOrWhiteSpace($TransactionDescriptorPath) -or
        [string]::IsNullOrWhiteSpace($RollbackBundle) -or
        $RollbackManifestSha256 -notmatch '\A[A-Fa-f0-9]{64}\z') {
        throw 'Every mutating registry transaction requires a durable descriptor path and a locked rollback-manifest binding.'
    }
    $rollbackBinding = Read-A4SRegistryRollbackBinding `
        -RegistrySubKey $RegistrySubKey -TargetKind $targetKind `
        -Bundle $RollbackBundle -ExpectedManifestSha256 $RollbackManifestSha256
    $nonce = [Guid]::NewGuid().ToString('N')
    $mutationContext = if ($targetKind -ceq 'product') {
        [A4SFailureRecoveryNative]::CreateProductMutationContext(
            $ProductBoundary, $RegistrySubKey, $nonce)
    }
    else {
        [A4SFailureRecoveryNative]::CreateContractMutationContext(
            $RegistrySubKey, $nonce)
    }
    [A4SFailureRecoveryNative]::ValidateMutationContext($mutationContext,
        $RegistrySubKey, $nonce, $targetKind -ceq 'product')

    $descriptor = if ($null -eq $ExistingDescriptorRecord) {
        New-A4SRegistryTransactionDescriptor -Path $TransactionDescriptorPath `
            -RegistrySubKey $RegistrySubKey -TargetKind $targetKind `
            -Desired $desired -Expected $initial -RollbackBinding $rollbackBinding
    }
    else {
        $existing = Read-A4SRegistryTransactionDescriptor `
            -Path $TransactionDescriptorPath -RegistrySubKey $RegistrySubKey `
            -TargetKind $targetKind -RollbackBundle $RollbackBundle `
            -RollbackManifestSha256 $RollbackManifestSha256 `
            -ExpectedDescriptorSha256 $ExistingDescriptorRecord.sha256
        $descriptorExpected = Get-RegistryAggregateRecord `
            -RegistrySubKey $RegistrySubKey -Snapshot $existing.value.expectedSnapshot
        $descriptorDesired = Get-RegistryAggregateRecord `
            -RegistrySubKey $RegistrySubKey -Snapshot $existing.value.desiredSnapshot
        if (-not (Test-RegistryAggregateEqual -First $initial -Second $descriptorExpected) -or
            -not (Test-RegistryAggregateEqual -First $desired -Second $descriptorDesired) -or
            [string]$existing.value.phase -cne 'recovery-prepared') {
            throw 'The existing recovery descriptor does not authorize this exact expected-to-desired transaction.'
        }
        $existing
    }
    Throw-A4SSimulatedHardInterruption `
        -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'prepared'

    $journal = [Collections.ArrayList]::new()
    $current = $initial
    $step = 0
    try {
        foreach ($value in @($initial.snapshot.values)) {
            $afterSnapshot = Copy-RegistrySnapshotObject -Snapshot $current.snapshot
            $afterSnapshot.values = @($afterSnapshot.values | Where-Object {
                -not [StringComparer]::OrdinalIgnoreCase.Equals(
                    [string]$_.name, [string]$value.name)
            })
            [void](Invoke-A4SRegistryJournaledStep -RegistrySubKey $RegistrySubKey `
                -MutationContext $mutationContext -ContextNonce $nonce `
                -TargetKind $targetKind -DescriptorRecord ([ref]$descriptor) `
                -CurrentAggregate ([ref]$current) -AfterSnapshot $afterSnapshot `
                -Operation DeleteValue -ValueRecord $value `
                -InverseOperation SetValue -InverseValueRecord $value `
                -Journal $journal -StepNumber ([ref]$step) `
                -ValidateBoundary $effectiveBoundaryValidator `
                -InjectFailureAfterStep $InjectFailureAfterStep `
                -InjectHardInterruptionPhase $InjectHardInterruptionPhase)
        }
        if ([bool]$current.snapshot.exists -and -not [bool]$DesiredSnapshot.exists) {
            $absent = [pscustomobject][ordered]@{ exists=$false; values=@(); subkeys=@() }
            [void](Invoke-A4SRegistryJournaledStep -RegistrySubKey $RegistrySubKey `
                -MutationContext $mutationContext -ContextNonce $nonce `
                -TargetKind $targetKind -DescriptorRecord ([ref]$descriptor) `
                -CurrentAggregate ([ref]$current) -AfterSnapshot $absent `
                -Operation DeleteKey -InverseOperation CreateKey `
                -Journal $journal -StepNumber ([ref]$step) `
                -ValidateBoundary $effectiveBoundaryValidator `
                -InjectFailureAfterStep $InjectFailureAfterStep `
                -InjectHardInterruptionPhase $InjectHardInterruptionPhase)
        }
        elseif ([bool]$DesiredSnapshot.exists) {
            if (-not [bool]$current.snapshot.exists) {
                $empty = [pscustomobject][ordered]@{ exists=$true; values=@(); subkeys=@() }
                [void](Invoke-A4SRegistryJournaledStep -RegistrySubKey $RegistrySubKey `
                    -MutationContext $mutationContext -ContextNonce $nonce `
                    -TargetKind $targetKind -DescriptorRecord ([ref]$descriptor) `
                    -CurrentAggregate ([ref]$current) -AfterSnapshot $empty `
                    -Operation CreateKey -InverseOperation DeleteKey `
                    -Journal $journal -StepNumber ([ref]$step) `
                    -ValidateBoundary $effectiveBoundaryValidator `
                    -InjectFailureAfterStep $InjectFailureAfterStep `
                    -InjectHardInterruptionPhase $InjectHardInterruptionPhase)
            }
            foreach ($value in @($DesiredSnapshot.values)) {
                $afterSnapshot = Copy-RegistrySnapshotObject -Snapshot $current.snapshot
                $afterSnapshot.values = @($afterSnapshot.values) + @(
                    Copy-RegistrySnapshotObject -Snapshot $value)
                [void](Invoke-A4SRegistryJournaledStep -RegistrySubKey $RegistrySubKey `
                    -MutationContext $mutationContext -ContextNonce $nonce `
                    -TargetKind $targetKind -DescriptorRecord ([ref]$descriptor) `
                    -CurrentAggregate ([ref]$current) -AfterSnapshot $afterSnapshot `
                    -Operation SetValue -ValueRecord $value `
                    -InverseOperation DeleteValue -InverseValueRecord $value `
                    -Journal $journal -StepNumber ([ref]$step) `
                    -ValidateBoundary $effectiveBoundaryValidator `
                    -InjectFailureAfterStep $InjectFailureAfterStep `
                    -InjectHardInterruptionPhase $InjectHardInterruptionPhase)
            }
        }
        $final = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
        if (-not (Test-RegistryAggregateEqual -First $desired -Second $final)) {
            throw 'A4S_UNKNOWN_REGISTRY_STATE: transaction final aggregate differs from the desired snapshot.'
        }
        $descriptor = Set-A4SRegistryTransactionDescriptor -Record $descriptor `
            -RegistrySubKey $RegistrySubKey -TargetKind $targetKind -Changes @{
                phase='committed'; step=$step
                authorizedBeforeSnapshot=$null; authorizedBeforeSha256=$null
                authorizedAfterSnapshot=$null; authorizedAfterSha256=$null
            }
        Throw-A4SSimulatedHardInterruption `
            -ConfiguredPhase $InjectHardInterruptionPhase -CurrentPhase 'committed'
        return [pscustomobject][ordered]@{
            snapshot=$final.snapshot; snapshotSha256=$final.sha256
            mutationStepCount=$step; journalEntryCount=$journal.Count; transaction='committed'
            transactionDescriptorPath=$descriptor.path
            transactionDescriptorSha256=$descriptor.sha256
        }
    }
    catch {
        $primary = $_
        if ($primary.Exception.Message.StartsWith('A4S_SIMULATED_HARD_INTERRUPTION:',
            [StringComparison]::Ordinal)) {
            throw $primary
        }
        if ($primary.Exception.Message.StartsWith('A4S_UNKNOWN_REGISTRY_STATE:',
            [StringComparison]::Ordinal)) {
            throw $primary
        }
        try {
            $rolledBack = Undo-A4SRegistryJournal -RegistrySubKey $RegistrySubKey `
                -MutationContext $mutationContext -ContextNonce $nonce `
                -TargetKind $targetKind -DescriptorRecord ([ref]$descriptor) `
                -Journal $journal -ValidateBoundary $effectiveBoundaryValidator `
                -InjectHardInterruptionPhase $InjectHardInterruptionPhase
        }
        catch {
            throw "Registry transaction failed ('$($primary.Exception.Message)') and deterministic journal rollback failed ('$($_.Exception.Message)')."
        }
        if (-not (Test-RegistryAggregateEqual -First $initial -Second $rolledBack)) {
            throw "Registry transaction failed ('$($primary.Exception.Message)') and journal rollback did not restore the exact immediate prestate."
        }
        throw "Registry transaction failed and journal rollback restored the exact immediate prestate: $($primary.Exception.Message)"
    }
}

function Invoke-A4SRegistryTransactionRecovery {
    param(
        [Parameter(Mandatory)][string] $RegistrySubKey,
        [Parameter(Mandatory)][string] $TransactionDescriptorPath,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedTransactionDescriptorSha256,
        [Parameter(Mandatory)][string] $RollbackBundle,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $RollbackManifestSha256,
        [object] $ProductBoundary,
        [scriptblock] $ValidateBoundary,
        [switch] $ContractRegistrySandbox,
        [ValidateSet('none', 'prepared', 'recovery-prepared', 'before-primitive',
            'after-primitive', 'committed', 'before-rollback', 'after-rollback',
            'rolled-back')]
        [string] $InjectHardInterruptionPhase = 'none'
    )

    $targetKind = Assert-A4SRegistryTransactionTarget -RegistrySubKey $RegistrySubKey `
        -ContractRegistrySandbox:$ContractRegistrySandbox
    if ($targetKind -ceq 'product') {
        [void](Assert-A4SProductMutationMode -Label 'HostSafety transaction recovery')
        if ($null -eq $ProductBoundary -or $null -ne $ValidateBoundary) {
            throw 'Product transaction recovery requires the real product boundary and forbids a caller validator.'
        }
        $effectiveBoundaryValidator = {
            param([string] $Label)
            Assert-A4SProductMutationBoundary -Boundary $ProductBoundary -Label $Label
        }.GetNewClosure()
    }
    else {
        if ($null -ne $ProductBoundary -or $null -eq $ValidateBoundary) {
            throw 'Contract transaction recovery requires only its explicit sandbox validator.'
        }
        $effectiveBoundaryValidator = $ValidateBoundary
    }
    [void](& $effectiveBoundaryValidator 'registry recovery descriptor discovery')
    $descriptor = Read-A4SRegistryTransactionDescriptor `
        -Path $TransactionDescriptorPath -RegistrySubKey $RegistrySubKey `
        -TargetKind $targetKind -RollbackBundle $RollbackBundle `
        -RollbackManifestSha256 $RollbackManifestSha256 `
        -ExpectedDescriptorSha256 $ExpectedTransactionDescriptorSha256
    $current = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey
    $expected = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $descriptor.value.expectedSnapshot
    $desired = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $descriptor.value.desiredSnapshot
    $originalDesired = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $descriptor.value.originalDesiredSnapshot
    $rollback = Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
        -Snapshot $descriptor.value.rollbackSnapshot
    $phase = [string]$descriptor.value.phase
    $intent = [string]$descriptor.value.recoveryIntent

    if ($phase -ceq 'committed') {
        if (-not (Test-RegistryAggregateEqual -First $desired -Second $current)) {
            throw 'A4S_UNKNOWN_REGISTRY_STATE: committed descriptor does not match current state.'
        }
        return [pscustomobject][ordered]@{
            snapshot=$current.snapshot; snapshotSha256=$current.sha256
            mutationStepCount=0; journalEntryCount=0; transaction='committed'
            recoveryDisposition='already-committed'
        }
    }
    if ($phase -ceq 'rolled-back') {
        if (-not (Test-RegistryAggregateEqual -First $rollback -Second $current)) {
            throw 'A4S_UNKNOWN_REGISTRY_STATE: rolled-back descriptor does not match its locked immediate prestate.'
        }
        return [pscustomobject][ordered]@{
            snapshot=$current.snapshot; snapshotSha256=$current.sha256
            mutationStepCount=0; journalEntryCount=0; transaction='rolled-back'
            recoveryDisposition='already-rolled-back'
        }
    }

    $allowed = @($expected)
    if ($null -ne $descriptor.value.authorizedBeforeSnapshot) {
        $allowed += Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
            -Snapshot $descriptor.value.authorizedBeforeSnapshot
        $allowed += Get-RegistryAggregateRecord -RegistrySubKey $RegistrySubKey `
            -Snapshot $descriptor.value.authorizedAfterSnapshot
    }
    if (@($allowed | Where-Object {
            Test-RegistryAggregateEqual -First $_ -Second $current
        }).Count -eq 0) {
        throw 'A4S_UNKNOWN_REGISTRY_STATE: recovery state is outside every descriptor-authorized aggregate.'
    }

    if ($phase -ceq 'prepared') {
        $goal = $originalDesired
        $nextIntent = 'resume-desired'
    }
    elseif ($phase -ceq 'recovery-prepared' -or $intent -in @(
        'resume-desired', 'rollback-immediate')) {
        $goal = $desired
        $nextIntent = $intent
    }
    else {
        # An interrupted initial apply never guesses how far it progressed:
        # exact-CAS it back to the manifest-bound immediate prestate.
        $goal = $rollback
        $nextIntent = 'rollback-immediate'
    }
    [void](& $effectiveBoundaryValidator 'registry recovery exact CAS')
    if (Test-RegistryAggregateEqual -First $goal -Second $current) {
        $terminal = if ($nextIntent -ceq 'rollback-immediate') {
            'rolled-back'
        } else { 'committed' }
        $descriptor = Set-A4SRegistryTransactionDescriptor -Record $descriptor `
            -RegistrySubKey $RegistrySubKey -TargetKind $targetKind -Changes @{
                desiredSnapshot=(Copy-RegistrySnapshotObject -Snapshot $goal.snapshot)
                desiredSha256=$goal.sha256
                expectedSnapshot=(Copy-RegistrySnapshotObject -Snapshot $current.snapshot)
                expectedSha256=$current.sha256
                recoveryIntent=$nextIntent; phase=$terminal; step=0
                authorizedBeforeSnapshot=$null; authorizedBeforeSha256=$null
                authorizedAfterSnapshot=$null; authorizedAfterSha256=$null
            }
        return [pscustomobject][ordered]@{
            snapshot=$current.snapshot; snapshotSha256=$current.sha256
            mutationStepCount=0; journalEntryCount=0; transaction=$terminal
            recoveryDisposition=$nextIntent
            transactionDescriptorSha256=$descriptor.sha256
        }
    }
    $descriptor = Set-A4SRegistryTransactionDescriptor -Record $descriptor `
        -RegistrySubKey $RegistrySubKey -TargetKind $targetKind -Changes @{
            desiredSnapshot=(Copy-RegistrySnapshotObject -Snapshot $goal.snapshot)
            desiredSha256=$goal.sha256
            expectedSnapshot=(Copy-RegistrySnapshotObject -Snapshot $current.snapshot)
            expectedSha256=$current.sha256
            recoveryIntent=$nextIntent; phase='recovery-prepared'; step=0
            authorizedBeforeSnapshot=$null; authorizedBeforeSha256=$null
            authorizedAfterSnapshot=$null; authorizedAfterSha256=$null
        }
    Throw-A4SSimulatedHardInterruption `
        -ConfiguredPhase $InjectHardInterruptionPhase `
        -CurrentPhase 'recovery-prepared'
    $result = Invoke-A4SRegistrySnapshotTransaction `
        -RegistrySubKey $RegistrySubKey -DesiredSnapshot $goal.snapshot `
        -ExpectedCurrent $current -ProductBoundary $ProductBoundary `
        -ValidateBoundary $ValidateBoundary `
        -ContractRegistrySandbox:$ContractRegistrySandbox `
        -TransactionDescriptorPath $descriptor.path `
        -RollbackBundle $descriptor.rollback.bundle `
        -RollbackManifestSha256 $descriptor.rollback.manifestSha256 `
        -ExistingDescriptorRecord $descriptor `
        -InjectHardInterruptionPhase $InjectHardInterruptionPhase
    $result | Add-Member -NotePropertyName recoveryDisposition `
        -NotePropertyValue $nextIntent
    return $result
}

function Read-A4SDiscoveredHostSafetyTransaction {
    param([Parameter(Mandatory)][string] $Path)

    $raw = Read-LockedFileBytesRecord -Path $Path `
        -Description 'discovered HostSafety transaction descriptor' `
        -CaptureSha256 -MaximumBytes 1048576
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($raw.bytes)
        $candidate = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "Discovered HostSafety descriptor is invalid UTF-8 JSON: $($_.Exception.Message)" }
    if ([string]$candidate.targetIdentifier -cne $hostSafetySubKey -or
        [string]$candidate.targetKind -cne 'product' -or
        [string]$candidate.rollbackManifestSha256 -notmatch '\A[A-Fa-f0-9]{64}\z') {
        throw 'A discovered transaction descriptor does not identify exact product HostSafety.'
    }
    $parent = Get-CanonicalPathRecord -Path (Split-Path -Parent $raw.path) `
        -Description 'discovered transaction rollback directory' -Kind Directory
    if (-not (Test-A4SPathEqual -First $parent.finalPath `
        -Second ([string]$candidate.rollbackBundle))) {
        throw 'A discovered transaction descriptor names a different rollback directory.'
    }
    return Read-A4SRegistryTransactionDescriptor -Path $raw.path `
        -RegistrySubKey $hostSafetySubKey -TargetKind product `
        -RollbackBundle $parent.finalPath `
        -RollbackManifestSha256 ([string]$candidate.rollbackManifestSha256) `
        -ExpectedDescriptorSha256 $raw.sha256
}

function Get-A4SPendingHostSafetyTransaction {
    param([Parameter(Mandatory)][string] $RecoveryBundle)

    $bundle = Get-ValidatedRecoveryBundle -Bundle $RecoveryBundle
    $pending = [Collections.ArrayList]::new()
    foreach ($child in @(Get-ChildItem -LiteralPath $bundle.finalPath -Directory -Force `
        -ErrorAction Stop | Where-Object { $_.Name -match '\ARollback-[A-Fa-f0-9]{32}\z' })) {
        $record = Get-CanonicalPathRecord -Path $child.FullName `
            -Description 'HostSafety rollback transaction directory' -Kind Directory
        if (-not (Test-PathWithin -Path $record.finalPath -Parent $bundle.finalPath)) {
            throw 'A rollback transaction directory escaped the recovery bundle.'
        }
        $descriptorPath = Join-Path $record.finalPath 'HostSafetyTransaction.json'
        if (Test-Path -LiteralPath $descriptorPath -PathType Leaf) {
            $descriptor = Read-A4SDiscoveredHostSafetyTransaction -Path $descriptorPath
            if ([string]$descriptor.value.phase -notin @('committed', 'rolled-back')) {
                [void]$pending.Add($descriptor)
            }
        }
    }
    if ($pending.Count -gt 1) {
        throw 'Multiple nonterminal HostSafety transactions exist; automatic recovery is ambiguous.'
    }
    return if ($pending.Count -eq 1) { $pending[0] } else { $null }
}

function Restore-HostSafety {
    param(
        [Parameter(Mandatory)][string] $Bundle,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedManifestSha256,
        [string] $ProbeHost,
        [object] $ExpectedCurrentHostSafetySnapshot,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')]
        [string] $ExpectedCurrentHostSafetySha256
    )

    Assert-AllTrackedHostsStopped -ProbeHost $ProbeHost
    # Manifest authentication is completed from one locked byte stream before
    # the product mutation boundary is entered or any registry state can change.
    $validated = Read-ValidatedHostSafetyBackup -Bundle $Bundle `
        -ExpectedManifestSha256 $ExpectedManifestSha256
    $pending = Get-A4SPendingHostSafetyTransaction `
        -RecoveryBundle $validated.bundle
    $boundary = Enter-A4SProductMutationBoundary
    $rollback = $null
    try {
        [void](Assert-A4SProductMutationBoundary -Boundary $boundary -Label 'restore authorization')
        $immediate = Get-HostSafetyAggregateRecord
        [void](Assert-AuthorizedHostSafetyAggregate -Current $immediate `
            -ExpectedSnapshot $ExpectedCurrentHostSafetySnapshot `
            -ExpectedSha256 $ExpectedCurrentHostSafetySha256 `
            -Boundary 'restore authorization')
        if ($null -ne $pending) {
            $originalDesired = Get-HostSafetyAggregateRecord `
                -Snapshot $pending.value.originalDesiredSnapshot
            if ($originalDesired.sha256 -cne $validated.snapshotSha256 -or
                -not (Compare-HostSafetySnapshot -Expected $validated.manifest.snapshot `
                    -Actual $pending.value.originalDesiredSnapshot)) {
                throw 'Pending HostSafety transaction is not bound to the requested desired backup.'
            }
            $recovered = Invoke-A4SRegistryTransactionRecovery `
                -RegistrySubKey $hostSafetySubKey `
                -TransactionDescriptorPath $pending.path `
                -ExpectedTransactionDescriptorSha256 $pending.sha256 `
                -RollbackBundle $pending.rollback.bundle `
                -RollbackManifestSha256 $pending.rollback.manifestSha256 `
                -ProductBoundary $boundary
            return [ordered]@{
                snapshot = $recovered.snapshot
                snapshotSha256 = $recovered.snapshotSha256
                transaction = $recovered.transaction
                recoveryDisposition = $recovered.recoveryDisposition
                authorizedPreRestoreSha256 = $immediate.sha256
                manifestSha256 = $validated.manifestSha256
                mutationStepCount = $recovered.mutationStepCount
                lifecycleMutexName = $boundary.LifecycleMutexName
                setupMutexName = $boundary.SetupMutexName
                hostSafetyMutexName = $boundary.HostSafetyMutexName
                hostMutexName = $boundary.HostMutexName
                rollbackBundle = $pending.rollback.bundle
                rollbackManifestSha256 = $pending.rollback.manifestSha256
                transactionDescriptorPath = $pending.path
            }
        }
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
        $restored = Invoke-A4SRegistrySnapshotTransaction `
            -RegistrySubKey $hostSafetySubKey `
            -DesiredSnapshot $validated.manifest.snapshot `
            -ExpectedCurrent $immediate -ProductBoundary $boundary `
            -TransactionDescriptorPath (Join-Path $rollback.bundle 'HostSafetyTransaction.json') `
            -RollbackBundle $rollback.bundle `
            -RollbackManifestSha256 $rollback.manifestSha256
        return [ordered]@{
            snapshot = $restored.snapshot
            snapshotSha256 = $restored.snapshotSha256
            transaction = $restored.transaction
            authorizedPreRestoreSha256 = $immediate.sha256
            manifestSha256 = $validated.manifestSha256
            mutationStepCount = $restored.mutationStepCount
            lifecycleMutexName = $boundary.LifecycleMutexName
            setupMutexName = $boundary.SetupMutexName
            hostSafetyMutexName = $boundary.HostSafetyMutexName
            hostMutexName = $boundary.HostMutexName
            rollbackBundle = $rollback.bundle
            rollbackManifestSha256 = $rollback.manifestSha256
            transactionDescriptorPath = $restored.transactionDescriptorPath
            transactionDescriptorSha256 = $restored.transactionDescriptorSha256
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
    $taskbar = [A4SFailureRecoveryNative]::GetTaskbarWindowRecord()
    $processId = [uint32]$taskbar.ProcessId
    $process = [Diagnostics.Process]::GetProcessById([int]$processId)
    try {
        $process.Refresh()
        if ($process.HasExited -or $process.ProcessName -ine 'explorer') {
            throw "Taskbar PID $processId is not a live Explorer process."
        }
        $pathRecord = Get-CanonicalPathRecord -Path $process.MainModule.FileName `
            -Description 'taskbar Explorer image' -Kind File
        $path = $pathRecord.finalPath
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe'))
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($path, $expectedPath)) {
            throw "Taskbar PID $processId is not the canonical Windows Explorer: $path"
        }
        $currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
        if ($process.SessionId -ne $currentSession) {
            throw "Taskbar Explorer belongs to session $($process.SessionId), not current session $currentSession."
        }
        return [pscustomobject][ordered]@{
            pid = [uint32]$process.Id
            startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            path = $path
            pathIdentity = $pathRecord.identity
            sessionId = $process.SessionId
            threadId = [uint32]$taskbar.ThreadId
            taskbarWindowHandle = [int64]$taskbar.WindowHandle
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
    if ([uint32]$Expected.pid -ne [uint32]$Actual.pid -or
        [string]$Expected.startTimeUtc -cne [string]$Actual.startTimeUtc -or
        [int]$Expected.sessionId -ne [int]$Actual.sessionId -or
        [uint32]$Expected.threadId -ne [uint32]$Actual.threadId -or
        [string]$Expected.pathIdentity -cne [string]$Actual.pathIdentity -or
        -not (Test-A4SPathEqual -First $Expected.path -Second $Actual.path)) {
        throw "$Label changed the exact Explorer PID/start/path/session/taskbar-thread identity."
    }
}

function Get-RetainedExplorerProcessIdentity {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)

    $Process.Refresh()
    if ($Process.HasExited -or $Process.ProcessName -ine 'explorer') {
        throw 'The retained Explorer process handle no longer identifies a live Explorer.'
    }
    $handleValue = $Process.Handle.ToInt64()
    $path = Get-CanonicalPathRecord -Path $Process.MainModule.FileName `
        -Description 'retained Explorer process image' -Kind File
    return [pscustomobject][ordered]@{
        pid = [uint32]$Process.Id
        startTimeUtc = $Process.StartTime.ToUniversalTime().ToString('o')
        path = $path.finalPath
        pathIdentity = $path.identity
        sessionId = $Process.SessionId
        processHandleValue = [int64]$handleValue
    }
}

function Assert-ExplorerTerminationIdentityPredicate {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $RetainedProcess,
        [Parameter(Mandatory)][object] $ImmediateTaskbarOwner,
        [Parameter(Mandatory)][string] $Label
    )

    if ([uint32]$Expected.pid -ne [uint32]$RetainedProcess.pid -or
        [string]$Expected.startTimeUtc -cne [string]$RetainedProcess.startTimeUtc -or
        [int]$Expected.sessionId -ne [int]$RetainedProcess.sessionId -or
        [string]$Expected.pathIdentity -cne [string]$RetainedProcess.pathIdentity -or
        -not (Test-A4SPathEqual -First $Expected.path -Second $RetainedProcess.path) -or
        [int64]$RetainedProcess.processHandleValue -eq 0 -or
        [uint32]$ImmediateTaskbarOwner.pid -ne [uint32]$Expected.pid -or
        [string]$ImmediateTaskbarOwner.startTimeUtc -cne
            [string]$Expected.startTimeUtc -or
        [int]$ImmediateTaskbarOwner.sessionId -ne [int]$Expected.sessionId -or
        [string]$ImmediateTaskbarOwner.pathIdentity -cne
            [string]$Expected.pathIdentity -or
        -not (Test-A4SPathEqual -First $ImmediateTaskbarOwner.path `
            -Second $Expected.path) -or
        [uint32]$ImmediateTaskbarOwner.threadId -ne [uint32]$Expected.threadId -or
        [int64]$ImmediateTaskbarOwner.taskbarWindowHandle -ne
            [int64]$Expected.taskbarWindowHandle) {
        throw "$Label refused an Explorer termination identity mismatch."
    }
    return $true
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
        [Parameter(Mandatory)][object] $HostBinding,
        [Parameter(Mandatory)][object] $Dll
    )

    [void](Assert-ValidA4SReleaseRecord -Record $Release.record)
    if ($HostBinding.sha256 -cne ([string]$Release.record.hostSha256).ToUpperInvariant() -or
        $Dll.sha256 -cne ([string]$Release.record.dllSha256).ToUpperInvariant() -or
        $HostBinding.fileVersion -cne [string]$Release.record.hostFileVersion -or
        $Dll.fileVersion -cne [string]$Release.record.dllFileVersion) {
        throw 'The supplied static host/DLL identities do not match the verified immutable release record.'
    }
    return $true
}

function Assert-HostBindingMatchesReleaseRecord {
    param(
        [Parameter(Mandatory)][object] $Release,
        [Parameter(Mandatory)][object] $HostBinding
    )

    [void](Assert-ValidA4SReleaseRecord -Record $Release.record)
    if ($HostBinding.sha256 -cne ([string]$Release.record.hostSha256).ToUpperInvariant() -or
        $HostBinding.fileVersion -cne [string]$Release.record.hostFileVersion) {
        throw 'The supplied static host identity does not match the verified immutable release record.'
    }
    return $true
}

function Assert-StaticPeImageBytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $Role
    )

    if ($Bytes.Length -lt 256 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) {
        throw "$Role is not a complete PE image with an MZ header."
    }
    $peOffset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($peOffset -lt 0x40 -or $peOffset -gt $Bytes.Length - 26 -or
        $Bytes[$peOffset] -ne 0x50 -or $Bytes[$peOffset + 1] -ne 0x45 -or
        $Bytes[$peOffset + 2] -ne 0 -or $Bytes[$peOffset + 3] -ne 0) {
        throw "$Role has an invalid static PE signature offset."
    }
    $machine = [BitConverter]::ToUInt16($Bytes, $peOffset + 4)
    $optionalSize = [BitConverter]::ToUInt16($Bytes, $peOffset + 20)
    if ($machine -ne 0x8664 -or $optionalSize -lt 112 -or
        $peOffset + 24 + $optionalSize -gt $Bytes.Length -or
        [BitConverter]::ToUInt16($Bytes, $peOffset + 24) -ne 0x20B) {
        throw "$Role is not a complete x64 PE32+ image."
    }
    return [pscustomobject][ordered]@{
        machine = 'AMD64'
        peOffset = $peOffset
        optionalHeaderSize = $optionalSize
        format = 'PE32+'
    }
}

function Get-BinaryBinding {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role
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
        if ($stream.Length -le 0 -or $stream.Length -gt 268435456) {
            throw "$Role binary is empty or exceeds the 256-MiB static-authentication limit."
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Role binary ended during its locked static read." }
            $offset += $read
        }
        $pe = Assert-StaticPeImageBytes -Bytes $bytes -Role $Role
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $sha256 = ([BitConverter]::ToString(
                $algorithm.ComputeHash($bytes))).Replace('-', '')
        }
        finally { $algorithm.Dispose() }
        # FileVersionInfo reads the fixed PE version resource without loading or
        # executing the image. The no-write/no-delete stream remains held.
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($record.finalPath)
        if ([string]::IsNullOrWhiteSpace([string]$version.FileVersion)) {
            throw "$Role has no static fixed file-version resource."
        }
        return [pscustomobject][ordered]@{
            role = $Role
            path = $locked.finalPath
            pathIdentity = $locked.identity
            sha256 = $sha256
            length = [uint64]$bytes.Length
            fileVersion = [string]$version.FileVersion
            productVersion = [string]$version.ProductVersion
            fixedVersionReadMode = 'static-locked-pe-resource'
            pe = $pe
            reportedVersion = $null
            sourceBinding = $null
            verifiedSourceCommit = $null
        }
    }
    finally { $stream.Dispose() }
}

function Confirm-A4SAuthenticatedHostReportedVersion {
    param(
        [Parameter(Mandatory)][object] $Release,
        [Parameter(Mandatory)][object] $AuthenticatedHostBinding
    )

    [void](Assert-HostBindingMatchesReleaseRecord -Release $Release `
        -HostBinding $AuthenticatedHostBinding)
    $outerLock = [IO.File]::Open([string]$AuthenticatedHostBinding.path,
        [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $current = Get-BinaryBinding -Path $AuthenticatedHostBinding.path `
            -Role 'authenticated source A4SMenuHost recheck'
        Assert-BinaryCopyBinding -Source $AuthenticatedHostBinding -Copy $current
        [void](Assert-HostBindingMatchesReleaseRecord -Release $Release `
            -HostBinding $current)
        $versionResult = Invoke-A4SHostCommand `
            -Executable $AuthenticatedHostBinding.path -Argument '--version'
        if ($versionResult.exitCode -ne 0 -or
            $versionResult.stdout -cne [string]$Release.record.hostReportedVersion) {
            throw 'Authenticated A4SMenuHost --version does not match the verified release record.'
        }
        $AuthenticatedHostBinding.reportedVersion = $versionResult.stdout
        return $versionResult
    }
    finally { $outerLock.Dispose() }
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

function Get-StaticArtifactBinding {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role
    )
    $locked = Read-LockedFileBytesRecord -Path $Path `
        -Description $Role -CaptureSha256 -MaximumBytes 16777216
    return [pscustomobject][ordered]@{
        role=$Role; path=$locked.path; pathIdentity=$locked.pathIdentity
        sha256=$locked.sha256; length=$locked.length
        bindingMode='static-locked-artifact-bytes'
    }
}

function Assert-ArtifactCopyBinding {
    param(
        [Parameter(Mandatory)][object] $Source,
        [Parameter(Mandatory)][object] $Copy
    )
    if ([string]$Source.sha256 -cne [string]$Copy.sha256 -or
        [uint64]$Source.length -ne [uint64]$Copy.length) {
        throw "$($Copy.role) is not an exact hash/length copy of $($Source.role)."
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

    # Never execute a caller path merely to probe singleton state. Cross-session
    # process ownership plus the native singleton window are authoritative.
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
    $requiredNames = @('AbnormalExplorerExitCount', 'AbnormalExplorerExitTimes',
        'AbnormalExplorerWindowStart', 'InjectionDisabled', 'LastExplorerExitCode')
    $actualNames = @($Snapshot.values | ForEach-Object { [string]$_.name } | Sort-Object)
    if ($actualNames.Count -ne 5 -or
        ($actualNames -join "`0") -cne (($requiredNames | Sort-Object) -join "`0")) {
        throw 'Crash guard HostSafety must contain five and only five exact values.'
    }
    $lookup = @{}
    foreach ($record in $Snapshot.values) { $lookup[[string]$record.name] = $record }
    foreach ($name in @('InjectionDisabled', 'AbnormalExplorerExitCount',
            'AbnormalExplorerWindowStart', 'AbnormalExplorerExitTimes',
            'LastExplorerExitCode')) {
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
    if ([string]$lookup['AbnormalExplorerWindowStart'].kind -cne 'QWord') {
        throw 'Crash guard window start is not Registry QWord.'
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
    $windowStart = [uint64]$lookup['AbnormalExplorerWindowStart'].value
    if ($windowStart -eq 0 -or $windowStart -ne [uint64]$nonzero[0]) {
        throw 'AbnormalExplorerWindowStart is not the exact first nonzero crash timestamp.'
    }
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
        windowStart100ns = $windowStart
        timestamps100ns = $nonzero
        span100ns = $nonzero[-1] - $nonzero[0]
        boundaries = @($Boundaries)
    }
}

function Invoke-IsolatedDllFailureQualification {
    param(
        [Parameter(Mandatory)][string] $SourceHost,
        [Parameter(Mandatory)][string] $VerifiedReleaseRecordPath,
        [string] $RequestedEvidencePath
    )

    $script:TrackedHosts.Clear()
    # The committed release record is authenticated before the caller-supplied
    # HostPath is even considered for execution.
    $release = Read-VerifiedA4SReleaseRecord -Path $VerifiedReleaseRecordPath
    $sourceHost = Resolve-RegularFile -Path $SourceHost -Description 'A4SMenuHost test input'
    $sourceBinding = Get-BinaryBinding -Path $sourceHost -Role 'source A4SMenuHost'
    [void](Assert-HostBindingMatchesReleaseRecord -Release $release `
        -HostBinding $sourceBinding)
    [void](Confirm-A4SAuthenticatedHostReportedVersion -Release $release `
        -AuthenticatedHostBinding $sourceBinding)
    $bundle = New-EvidenceBundle -Mode 'isolated-dll-failures' -RequestedPath $RequestedEvidencePath
    $temporaryRoot = New-A4STemporaryRoot
    $initial = $null
    $backupPrepared = $false
    $hostsStopped = $false
    $noInjectionConclusive = $false
    $finalMappingCount = -1
    $finalWindowCount = -1
    $safetyRestored = $false
    $backup = $null
    $authorizedState = $null
    $operationError = $null
    try {
        $script:Evidence.sourceBinding = 'verified-release-record'
        $script:Evidence.verifiedSourceCommit =
            ([string]$release.record.sourceCommit).ToLowerInvariant()
        $script:Evidence.releaseRecord = [ordered]@{
            path = $release.path
            pathIdentity = $release.pathIdentity
            gitRelativePath = $release.gitRelativePath
            recordCommit = $release.recordCommit
            recordBlob = $release.recordBlob
            recordSha256 = $release.recordSha256
        }
        $sourceBinding.sourceBinding = $script:Evidence.sourceBinding
        $sourceBinding.verifiedSourceCommit = $script:Evidence.verifiedSourceCommit
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
            authorizedStateSequence = $null
            authorizedStateLastAction = $null
            authorizedStateHistory = @()
            freshKnownCurrentHostSafetySha256 = $null
            freshKnownCurrentStateUtc = $null
            recoveryCommand = $null
            cleanupInstructions = $null
        }
        Save-Evidence
        $authorizedState = New-A4SAuthorizedHostSafetyState `
            -InitialSnapshot $backup.manifest.snapshot `
            -InitialSha256 $backup.snapshotSha256 -Action 'initial-backup' `
            -ExpectedMutationActions @()
        Publish-A4SAuthorizedHostSafetyState -State $authorizedState

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
                Get-StaticArtifactBinding -Path $caseDll `
                    -Role "isolated $caseName DLL input"
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
                [void](Assert-A4SAuthorizedHostSafetySnapshot -State $authorizedState `
                    -Snapshot $during.hostSafety `
                    -Label "isolated $caseName failed-host HostSafety checkpoint")
                Add-EvidenceCheckpoint $during

                [void](Stop-A4STestHost -Executable $caseHost -ResidentProcess $resident)
                $stopped = $true
                $after = Get-A4SCheckpoint -Label "isolated-$caseName-stopped"
                Assert-SameExplorerIdentity -Expected $initial.explorer -Actual $after.explorer `
                    -Label "$caseName cleanup"
                if ($after.a4sMappings.Count -ne 0 -or $after.visibleMenuWindowCount -ne 0) {
                    throw "$caseName cleanup observed an A4S injection."
                }
                [void](Assert-A4SAuthorizedHostSafetySnapshot -State $authorizedState `
                    -Snapshot $after.hostSafety `
                    -Label "isolated $caseName stopped HostSafety checkpoint")
                Add-EvidenceCheckpoint $after
                $finalCaseHostBinding = Get-BinaryBinding -Path $caseHost `
                    -Role "final isolated $caseName A4SMenuHost"
                Assert-BinaryCopyBinding -Source $caseHostBinding -Copy $finalCaseHostBinding
                $finalCaseDllBinding = $null
                if ($caseDllBinding) {
                    $finalCaseDllBinding = Get-StaticArtifactBinding -Path $caseDll `
                        -Role "final isolated $caseName DLL input"
                    Assert-ArtifactCopyBinding -Source $caseDllBinding `
                        -Copy $finalCaseDllBinding
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
        [void](Assert-A4SAuthorizedCurrentHostSafety -State $authorizedState `
            -Label 'isolated matrix final HostSafety checkpoint')
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
                $restoreAuthorization = Assert-A4SAuthorizedCurrentHostSafety `
                    -State $authorizedState -Label 'isolated restore prior authorization'
                Add-EvidenceCheckpoint ([ordered]@{
                    utc = Get-UtcText
                    label = 'isolated-restore-previously-authorized'
                    authorizedStateSequence = $authorizedState.sequence
                    authorizedStateLastAction = $authorizedState.lastAction
                    hostSafetySha256 = $restoreAuthorization.sha256
                })
                $restoreResult = Restore-HostSafety -Bundle $bundle -ProbeHost $sourceHost `
                    -ExpectedManifestSha256 $backup.manifestSha256 `
                    -ExpectedCurrentHostSafetySnapshot $authorizedState.snapshot `
                    -ExpectedCurrentHostSafetySha256 $authorizedState.sha256
                [void](Confirm-A4SRestoreTransition -State $authorizedState `
                    -RestoreResult $restoreResult -DesiredSnapshot $backup.manifest.snapshot `
                    -ExpectedManifestSha256 $backup.manifestSha256)
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
                    -AuthorizedState $authorizedState -ProbeHost $sourceHost `
                    -Reason 'Validated flat cleanup was authorized and is in progress.'
                Remove-A4STemporaryRoot -Root $temporaryRoot
                Clear-RetainedTemporaryRootEvidence
            }
            catch {
                [void]$script:Evidence.errors.Add("Temporary case cleanup failed: $($_.Exception.Message)")
                Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                    -BackupPrepared $backupPrepared -Bundle $bundle `
                    -AuthorizedState $authorizedState -ProbeHost $sourceHost `
                    -Reason "Validated flat cleanup threw or only partially removed the root: $($_.Exception.Message)"
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                -BackupPrepared $backupPrepared -Bundle $bundle `
                -AuthorizedState $authorizedState -ProbeHost $sourceHost `
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
        # Force and retain this exact OS process handle, then revalidate every
        # process identity field and Shell_TrayWnd ownership immediately before Kill.
        $retainedIdentity = Get-RetainedExplorerProcessIdentity -Process $process
        $issuedFileTime = [uint64][DateTime]::UtcNow.ToFileTimeUtc()
        $immediateTaskbar = Get-TaskbarExplorerIdentity
        [void](Assert-ExplorerTerminationIdentityPredicate -Expected $current `
            -RetainedProcess $retainedIdentity -ImmediateTaskbarOwner $immediateTaskbar `
            -Label $Label)
        $process.Kill()
        $killReturnedFileTime = [uint64][DateTime]::UtcNow.ToFileTimeUtc()
        return [pscustomobject][ordered]@{
            label = $Label
            requestedUtc = Get-UtcText
            issuedFileTimeUtc = $issuedFileTime
            killReturnedFileTimeUtc = $killReturnedFileTime
            oldExplorer = $current
            retainedProcessIdentity = $retainedIdentity
            immediateTaskbarOwner = $immediateTaskbar
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
    # Authenticate the immutable committed record first, then statically bind
    # both caller-supplied images before HostPath is ever executed.
    $release = Read-VerifiedA4SReleaseRecord -Path $VerifiedReleaseRecordPath
    $sourceHost = Resolve-RegularFile -Path $SourceHost -Description 'A4SMenuHost live-test input'
    $sourceDll = Resolve-RegularFile -Path $SourceDll -Description 'A4SMenu.dll live-test input'
    $sourceHostBinding = Get-BinaryBinding -Path $sourceHost -Role 'source A4SMenuHost'
    $sourceDllBinding = Get-BinaryBinding -Path $sourceDll -Role 'source A4SMenu.dll'
    [void](Assert-BinaryBindingsMatchReleaseRecord -Release $release `
        -HostBinding $sourceHostBinding -Dll $sourceDllBinding)
    [void](Confirm-A4SAuthenticatedHostReportedVersion -Release $release `
        -AuthenticatedHostBinding $sourceHostBinding)
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
    $backup = $null
    $authorizedState = $null

    try {
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
            authorizedStateSequence = $null
            authorizedStateLastAction = $null
            authorizedStateHistory = @()
            freshKnownCurrentHostSafetySha256 = $null
            freshKnownCurrentStateUtc = $null
            recoveryCommand = $null
            cleanupInstructions = $null
        }
        Save-Evidence
        $authorizedState = New-A4SAuthorizedHostSafetyState `
            -InitialSnapshot $backup.manifest.snapshot `
            -InitialSha256 $backup.snapshotSha256 -Action 'initial-backup' `
            -ExpectedMutationActions @('no-DLL-reset-safety',
                'guarded-explorer-crash-1', 'guarded-explorer-crash-2',
                'guarded-explorer-crash-3', 'resident-reset-safety')
        Publish-A4SAuthorizedHostSafetyState -State $authorizedState

        # Establish an empty crash-guard baseline without loading a valid DLL or
        # installing a hook. This host copy has no sibling A4SMenu.dll.
        $resetDirectory = New-SafeFreshDirectory `
            -Path (Join-Path $temporaryRoot.finalPath 'safety-reset-no-dll') `
            -Description 'no-DLL safety-reset directory' -ExpectedParent $temporaryRoot.finalPath
        $resetHost = Join-Path $resetDirectory.finalPath 'A4SMenuHost.exe'
        Copy-Item -LiteralPath $sourceHost -Destination $resetHost -ErrorAction Stop
        $resetBinding = Get-BinaryBinding -Path $resetHost -Role 'safety-reset A4SMenuHost'
        Assert-BinaryCopyBinding -Source $sourceHostBinding -Copy $resetBinding
        [void](Assert-A4SAuthorizedCurrentHostSafety -State $authorizedState `
            -Label 'no-DLL reset pre-action authorization')
        $preResetAuthorizedSha256 = $authorizedState.sha256
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
        [void](Confirm-A4SResetSafetyTransition -State $authorizedState `
            -ExpectedPreviousSha256 $preResetAuthorizedSha256 `
            -ObservedSnapshot $emptySafety -Action 'no-DLL-reset-safety')
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
        [void](Assert-A4SAuthorizedHostSafetySnapshot -State $authorizedState `
            -Snapshot $ready.hostSafety -Label 'initial-ready HostSafety checkpoint')
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
            [void](Assert-A4SAuthorizedHostSafetySnapshot -State $authorizedState `
                -Snapshot $before.hostSafety `
                -Label "crash-$crashIndex previously authorized HostSafety")
            $preCrashAuthorizedSha256 = $authorizedState.sha256
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
            $after.rollingGuard = Confirm-A4SCrashGuardTransition `
                -State $authorizedState `
                -ExpectedPreviousSha256 $preCrashAuthorizedSha256 `
                -ObservedSnapshot $after.hostSafety -Stage $crashIndex `
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
        [void](Assert-A4SAuthorizedCurrentHostSafety -State $authorizedState `
            -Label 'resident reset pre-action authorization')
        $preRecoveryResetAuthorizedSha256 = $authorizedState.sha256
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
        [void](Confirm-A4SResetSafetyTransition -State $authorizedState `
            -ExpectedPreviousSha256 $preRecoveryResetAuthorizedSha256 `
            -ObservedSnapshot $recovered.hostSafety -Action 'resident-reset-safety')
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
        [void](Assert-A4SAuthorizedHostSafetySnapshot -State $authorizedState `
            -Snapshot $cleanupAfter.hostSafety `
            -Label 'cleanup restart HostSafety checkpoint')
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
                $restoreAuthorization = Assert-A4SAuthorizedCurrentHostSafety `
                    -State $authorizedState -Label 'live restore prior authorization'
                Add-EvidenceCheckpoint ([ordered]@{
                    utc = Get-UtcText
                    label = 'live-restore-previously-authorized'
                    authorizedStateSequence = $authorizedState.sequence
                    authorizedStateLastAction = $authorizedState.lastAction
                    hostSafetySha256 = $restoreAuthorization.sha256
                })
                $restoreResult = Restore-HostSafety -Bundle $bundle -ProbeHost $sourceHost `
                    -ExpectedManifestSha256 $backup.manifestSha256 `
                    -ExpectedCurrentHostSafetySnapshot $authorizedState.snapshot `
                    -ExpectedCurrentHostSafetySha256 $authorizedState.sha256
                [void](Confirm-A4SRestoreTransition -State $authorizedState `
                    -RestoreResult $restoreResult -DesiredSnapshot $backup.manifest.snapshot `
                    -ExpectedManifestSha256 $backup.manifestSha256)
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
                    -AuthorizedState $authorizedState -ProbeHost $sourceHost `
                    -Reason 'Validated post-restart flat cleanup was authorized and is in progress.'
                Remove-A4STemporaryRoot -Root $temporaryRoot
                Clear-RetainedTemporaryRootEvidence
            }
            catch {
                [void]$script:Evidence.errors.Add("Temporary runtime cleanup failed: $($_.Exception.Message)")
                Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                    -BackupPrepared $backupPrepared -Bundle $bundle `
                    -AuthorizedState $authorizedState -ProbeHost $sourceHost `
                    -Reason "Validated post-restart flat cleanup threw or only partially removed the root: $($_.Exception.Message)"
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            Set-RetainedTemporaryRootEvidence -Root $temporaryRoot.finalPath `
                -BackupPrepared $backupPrepared -Bundle $bundle `
                -AuthorizedState $authorizedState -ProbeHost $sourceHost `
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
    # Return before initialization/dispatch when dot-sourced by the companion.
    # The companion explicitly loads the path helper and confines mutations to
    # its random HKCU contract subtree and validated OS-temp root.
    return
}
elseif ($PSCmdlet.ParameterSetName -eq 'Offline') {
    & (Join-Path $PSScriptRoot 'Test-A4SFailureRecoveryContracts.ps1')
    Write-Host 'OFFLINE GO: only a random HKCU contract-test subtree and a validated OS-temp root were created and transactionally removed; product HostSafety, runtime, Explorer, staging, and evidence were unchanged.'
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
                    -VerifiedReleaseRecordPath $ReleaseRecordPath `
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
                    -ExpectedManifestSha256 $ExpectedManifestSha256 `
                    -ExpectedCurrentHostSafetySha256 $ExpectedCurrentHostSafetySha256
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
