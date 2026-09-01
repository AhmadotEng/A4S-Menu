[CmdletBinding()]
param(
    [string] $OutputPath,
    [string] $ProductDirectory,
    [switch] $RequireCleanProductState,
    [ValidateRange(10, 900)]
    [int] $MaximumCleanExplorerAgeSeconds = 120
)

$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this probe from 64-bit PowerShell so the x64 Explorer module list is authoritative.'
}

Import-Module (Join-Path $PSScriptRoot 'A4SBinaryIdentity.psm1') -Force

if (-not ('A4SObservationNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class A4SObservationNative
{
    private delegate bool EnumMonitorsProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public uint Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_STATISTICS
    {
        public LUID TokenId;
        public LUID AuthenticationId;
        public long ExpirationTime;
        public int TokenType;
        public int ImpersonationLevel;
        public uint DynamicCharged;
        public uint DynamicAvailable;
        public uint GroupCount;
        public uint PrivilegeCount;
        public LUID ModifiedId;
    }

    public sealed class MonitorRecord
    {
        public string DeviceName;
        public int Left;
        public int Top;
        public int Width;
        public int Height;
        public int WorkLeft;
        public int WorkTop;
        public int WorkWidth;
        public int WorkHeight;
        public bool Primary;
        public uint DpiX;
        public uint DpiY;
        public bool DpiAvailable;
        public uint ScalePercent;
    }

    public sealed class IoRecord
    {
        public ulong ReadOperations;
        public ulong WriteOperations;
        public ulong OtherOperations;
        public ulong ReadBytes;
        public ulong WriteBytes;
        public ulong OtherBytes;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowW(string className, string windowName);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out RECT rect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr window, StringBuilder className, int count);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumMonitorsProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("shcore.dll")]
    private static extern int GetScaleFactorForMonitor(IntPtr monitor, out int scalePercent);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessIoCounters(IntPtr process, out IO_COUNTERS counters);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int informationClass,
        IntPtr information, int informationLength, out int returnLength);

    private static IntPtr EnterPhysicalCoordinates()
    {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. Window and monitor
        // geometry must remain physical across 100-200% qualification runs.
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadDpiAwarenessContext failed");
        return previous;
    }

    private static void RestoreDpiContext(IntPtr previous)
    {
        if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
    }

    public static string WindowClass(IntPtr window)
    {
        StringBuilder name = new StringBuilder(256);
        if (window != IntPtr.Zero && GetClassNameW(window, name, name.Capacity) > 0)
            return name.ToString();
        return String.Empty;
    }

    public static bool WindowIsMinimized(IntPtr window)
    {
        return window != IntPtr.Zero && IsIconic(window);
    }

    public static RECT WindowRect(IntPtr window)
    {
        IntPtr previous = EnterPhysicalCoordinates();
        try
        {
            RECT rect;
            if (window == IntPtr.Zero || !GetWindowRect(window, out rect))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowRect failed");
            return rect;
        }
        finally { RestoreDpiContext(previous); }
    }

    public static MonitorRecord[] Monitors()
    {
        IntPtr previous = EnterPhysicalCoordinates();
        List<MonitorRecord> records = new List<MonitorRecord>();
        try
        {
            if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                delegate(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr parameter)
                {
                MONITORINFOEX info = new MONITORINFOEX();
                info.Size = (uint)Marshal.SizeOf(typeof(MONITORINFOEX));
                if (!GetMonitorInfoW(monitor, ref info))
                    return true;
                uint dpiX = 0, dpiY = 0, scalePercent = 0;
                bool dpiAvailable = false;
                try
                {
                    int reportedScale;
                    int result = GetScaleFactorForMonitor(monitor, out reportedScale);
                    dpiAvailable = result == 0 && reportedScale >= 100 && reportedScale <= 500;
                    if (dpiAvailable)
                    {
                        scalePercent = (uint)reportedScale;
                        dpiX = dpiY = (uint)Math.Round(96.0 * reportedScale / 100.0);
                    }
                }
                catch (DllNotFoundException) { }
                catch (EntryPointNotFoundException) { }
                if (!dpiAvailable) { dpiX = 0; dpiY = 0; }
                records.Add(new MonitorRecord {
                    DeviceName = info.DeviceName,
                    Left = info.Monitor.Left,
                    Top = info.Monitor.Top,
                    Width = info.Monitor.Right - info.Monitor.Left,
                    Height = info.Monitor.Bottom - info.Monitor.Top,
                    WorkLeft = info.Work.Left,
                    WorkTop = info.Work.Top,
                    WorkWidth = info.Work.Right - info.Work.Left,
                    WorkHeight = info.Work.Bottom - info.Work.Top,
                    Primary = (info.Flags & 1) != 0,
                    DpiX = dpiX,
                    DpiY = dpiY,
                    DpiAvailable = dpiAvailable,
                    ScalePercent = scalePercent
                });
                return true;
                }, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumDisplayMonitors failed");
            return records.ToArray();
        }
        finally { RestoreDpiContext(previous); }
    }

    public static IoRecord ProcessIo(uint processId)
    {
        const uint QueryLimitedInformation = 0x1000;
        IntPtr process = OpenProcess(QueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
        try
        {
            IO_COUNTERS counters;
            if (!GetProcessIoCounters(process, out counters))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetProcessIoCounters failed");
            return new IoRecord {
                ReadOperations = counters.ReadOperationCount,
                WriteOperations = counters.WriteOperationCount,
                OtherOperations = counters.OtherOperationCount,
                ReadBytes = counters.ReadTransferCount,
                WriteBytes = counters.WriteTransferCount,
                OtherBytes = counters.OtherTransferCount
            };
        }
        finally { CloseHandle(process); }
    }

    public static string ProcessLogonId(uint processId)
    {
        const uint QueryLimitedInformation = 0x1000;
        const uint TokenQuery = 0x0008;
        const int TokenStatistics = 10;
        IntPtr process = OpenProcess(QueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed for logon identity");
        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, TokenQuery, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
            try
            {
                int length;
                GetTokenInformation(token, TokenStatistics, IntPtr.Zero, 0, out length);
                if (length < Marshal.SizeOf(typeof(TOKEN_STATISTICS)))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetTokenInformation size query failed");
                IntPtr buffer = Marshal.AllocHGlobal(length);
                try
                {
                    if (!GetTokenInformation(token, TokenStatistics, buffer, length, out length))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "GetTokenInformation failed");
                    TOKEN_STATISTICS stats = (TOKEN_STATISTICS)Marshal.PtrToStructure(buffer, typeof(TOKEN_STATISTICS));
                    return String.Format("{0:x8}:{1:x8}", unchecked((uint)stats.AuthenticationId.HighPart), stats.AuthenticationId.LowPart);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@
}

function Get-StableFileEvidence {
    param([Parameter(Mandatory)][string] $Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)) }
        finally { $sha.Dispose() }
        [ordered]@{ path = $resolved; length = $stream.Length; sha256 = $hash }
    }
    finally { $stream.Dispose() }
}

function Write-DurableJsonCreateNew {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Json)
    if (Test-Path -LiteralPath $Path) { throw "Snapshot output already exists: '$Path'. Qualification evidence is never overwritten." }
    $temporary = "$Path.partial-$PID-$([Guid]::NewGuid().ToString('N'))"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json + [Environment]::NewLine)
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    [IO.File]::Move($temporary, $Path)
}

function Get-ProcessRecord {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)

    $Process.Refresh()
    $io = [A4SObservationNative]::ProcessIo([uint32]$Process.Id)
    [ordered]@{
        pid = $Process.Id
        path = $Process.MainModule.FileName
        sessionId = $Process.SessionId
        logonId = [A4SObservationNative]::ProcessLogonId([uint32]$Process.Id)
        startTimeUtc = $Process.StartTime.ToUniversalTime().ToString('o')
        privateBytes = $Process.PrivateMemorySize64
        workingSetBytes = $Process.WorkingSet64
        pagedMemoryBytes = $Process.PagedMemorySize64
        handleCount = $Process.HandleCount
        threadCount = $Process.Threads.Count
        totalProcessorTimeTicks = $Process.TotalProcessorTime.Ticks
        io = [ordered]@{
            readOperations = $io.ReadOperations
            writeOperations = $io.WriteOperations
            otherOperations = $io.OtherOperations
            readBytes = $io.ReadBytes
            writeBytes = $io.WriteBytes
            otherBytes = $io.OtherBytes
        }
    }
}

function Get-A4SHostProcessRecords {
    param(
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $LogonId
    )
    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name A4SMenuHost -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -eq $SessionId -and
                [A4SObservationNative]::ProcessLogonId([uint32]$process.Id) -eq $LogonId) {
                [void]$records.Add((Get-ProcessRecord -Process $process))
            }
        } finally { $process.Dispose() }
    }
    @($records | Sort-Object pid)
}

function Get-ModulePaths {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    @($Process.Modules | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) } | Sort-Object)
}

function Convert-Rect {
    param($Rect)
    [ordered]@{
        left = $Rect.Left
        top = $Rect.Top
        width = $Rect.Right - $Rect.Left
        height = $Rect.Bottom - $Rect.Top
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ProductDirectory) { $ProductDirectory = Join-Path $repoRoot 'build\stage\A4SProduct' }
$resolvedProductDirectory = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProductDirectory))
$productRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
$hostExecutable = Join-Path $resolvedProductDirectory 'A4SMenuHost.exe'
$menuDll = Join-Path $resolvedProductDirectory 'A4SMenu.dll'
$selectedHostEvidence = if (Test-Path -LiteralPath $hostExecutable -PathType Leaf) { Get-StableFileEvidence $hostExecutable } else { $null }
$selectedDllEvidence = if (Test-Path -LiteralPath $menuDll -PathType Leaf) { Get-StableFileEvidence $menuDll } else { $null }
if ($RequireCleanProductState -and (-not $selectedHostEvidence -or -not $selectedDllEvidence)) {
    throw "A clean qualification baseline also requires A4SMenuHost.exe and A4SMenu.dll in the selected product directory '$resolvedProductDirectory' so the later run can be bound to the same payload hashes."
}

$taskbar = [A4SObservationNative]::FindWindowW('Shell_TrayWnd', $null)
if ($taskbar -eq [IntPtr]::Zero) {
    throw 'Shell_TrayWnd was not found.'
}
[uint32]$explorerProcessId = 0
if ([A4SObservationNative]::GetWindowThreadProcessId($taskbar, [ref]$explorerProcessId) -eq 0 -or $explorerProcessId -eq 0) {
    throw 'Could not resolve the taskbar Explorer process.'
}
$explorerProcess = [Diagnostics.Process]::GetProcessById([int]$explorerProcessId)
$explorerStartTicks = $explorerProcess.StartTime.ToUniversalTime().Ticks
$observerProcess = [Diagnostics.Process]::GetCurrentProcess()
$observerSessionId = $observerProcess.SessionId
$observerLogonId = [A4SObservationNative]::ProcessLogonId([uint32]$observerProcess.Id)
$explorerLogonId = [A4SObservationNative]::ProcessLogonId($explorerProcessId)
if ($explorerProcess.SessionId -ne $observerSessionId -or $explorerLogonId -ne $observerLogonId) {
    throw 'The observation process and taskbar Explorer do not share one interactive logon session.'
}
$hostProcessRecords = @(Get-A4SHostProcessRecords -SessionId $observerSessionId -LogonId $observerLogonId)
$cleanExplorerAgeSeconds = $null
if ($RequireCleanProductState) {
    $explorerAgeSeconds = ([DateTime]::UtcNow - $explorerProcess.StartTime.ToUniversalTime()).TotalSeconds
    if ($explorerAgeSeconds -lt 0 -or $explorerAgeSeconds -gt $MaximumCleanExplorerAgeSeconds) {
        throw "A clean resource baseline requires a fresh taskbar Explorer (age=$([Math]::Round($explorerAgeSeconds, 3)) seconds; maximum=$MaximumCleanExplorerAgeSeconds)."
    }
    $cleanExplorerAgeSeconds = $explorerAgeSeconds
}
$modulePaths = @(Get-ModulePaths -Process $explorerProcess)
$a4sMappings = @($modulePaths | Where-Object { [IO.Path]::GetFileName($_) -ieq 'A4SMenu.dll' })
$competingStartMenuMappings = @($modulePaths | Where-Object { [IO.Path]::GetFileName($_) -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })

$residentHostWindow = [A4SObservationNative]::FindWindowW('A4SMenu.Host.Window.v1', 'A4SMenuHost')
$residentHostRecord = $null
if ($residentHostWindow -ne [IntPtr]::Zero) {
    [uint32]$residentHostProcessId = 0
    [void][A4SObservationNative]::GetWindowThreadProcessId($residentHostWindow, [ref]$residentHostProcessId)
    if ($residentHostProcessId) {
        $residentHostProcess = [Diagnostics.Process]::GetProcessById([int]$residentHostProcessId)
        try { $residentHostRecord = Get-ProcessRecord -Process $residentHostProcess }
        finally { $residentHostProcess.Dispose() }
    }
}

if ($RequireCleanProductState -and ($a4sMappings.Count -ne 0 -or $residentHostRecord -or
    $hostProcessRecords.Count -ne 0 -or $competingStartMenuMappings.Count -ne 0)) {
    throw "A clean pre-injection baseline requires no A4SMenu.dll mapping, same-logon A4SMenuHost process/window, or competing StartAllBack/StartIsBack/Open-Shell Explorer module. Found A4S mappings=$($a4sMappings.Count), hostWindow=$([bool]$residentHostRecord), hostProcesses=$($hostProcessRecords.Count), competing='$($competingStartMenuMappings -join '; ')'."
}

$taskbarRect = [A4SObservationNative]::WindowRect($taskbar)
$taskbarWidth = $taskbarRect.Right - $taskbarRect.Left
$taskbarHeight = $taskbarRect.Bottom - $taskbarRect.Top
$monitorRecords = @([A4SObservationNative]::Monitors())
$taskbarMonitor = @($monitorRecords | Sort-Object -Descending {
    $overlapWidth = [Math]::Max(0, [Math]::Min($taskbarRect.Right, $_.Left + $_.Width) - [Math]::Max($taskbarRect.Left, $_.Left))
    $overlapHeight = [Math]::Max(0, [Math]::Min($taskbarRect.Bottom, $_.Top + $_.Height) - [Math]::Max($taskbarRect.Top, $_.Top))
    $overlapWidth * $overlapHeight
})[0]
$taskbarEdge = if ($taskbarWidth -ge $taskbarHeight) {
    if ([Math]::Abs($taskbarRect.Top - $taskbarMonitor.Top) -le
        [Math]::Abs($taskbarRect.Bottom - ($taskbarMonitor.Top + $taskbarMonitor.Height))) { 'top' } else { 'bottom' }
} else {
    if ([Math]::Abs($taskbarRect.Left - $taskbarMonitor.Left) -le
        [Math]::Abs($taskbarRect.Right - ($taskbarMonitor.Left + $taskbarMonitor.Width))) { 'left' } else { 'right' }
}

$foregroundWindow = [A4SObservationNative]::GetForegroundWindow()
$foregroundRecord = $null
if ($foregroundWindow -ne [IntPtr]::Zero) {
    [uint32]$foregroundProcessId = 0
    [void][A4SObservationNative]::GetWindowThreadProcessId($foregroundWindow, [ref]$foregroundProcessId)
    $foregroundRect = $null
    try { $foregroundRect = [A4SObservationNative]::WindowRect($foregroundWindow) } catch {
        # Foreground windows can disappear between GetForegroundWindow and
        # GetWindowRect. Preserve an explicit unavailable classification rather
        # than failing the entire environment snapshot or guessing "windowed".
        $foregroundRecord = [ordered]@{
            hwnd = ('0x{0:X}' -f $foregroundWindow.ToInt64())
            pid = $foregroundProcessId
            fullscreenGeometryCandidate = $null
            classification = 'unavailable-window-changed'
        }
    }
    if ($null -ne $foregroundRect) {
    $foregroundClass = [A4SObservationNative]::WindowClass($foregroundWindow)
    $foregroundMinimized = [A4SObservationNative]::WindowIsMinimized($foregroundWindow)
    $foregroundMonitor = @($monitorRecords | Sort-Object -Descending {
        $overlapWidth = [Math]::Max(0, [Math]::Min($foregroundRect.Right, $_.Left + $_.Width) - [Math]::Max($foregroundRect.Left, $_.Left))
        $overlapHeight = [Math]::Max(0, [Math]::Min($foregroundRect.Bottom, $_.Top + $_.Height) - [Math]::Max($foregroundRect.Top, $_.Top))
        $overlapWidth * $overlapHeight
    })[0]
    $fullscreenTolerance = 2
    $coversMonitor = [Math]::Abs($foregroundRect.Left - $foregroundMonitor.Left) -le $fullscreenTolerance -and
        [Math]::Abs($foregroundRect.Top - $foregroundMonitor.Top) -le $fullscreenTolerance -and
        [Math]::Abs($foregroundRect.Right - ($foregroundMonitor.Left + $foregroundMonitor.Width)) -le $fullscreenTolerance -and
        [Math]::Abs($foregroundRect.Bottom - ($foregroundMonitor.Top + $foregroundMonitor.Height)) -le $fullscreenTolerance
    $shellSurfaceClasses = @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd')
    $fullscreenGeometryCandidate = $foregroundProcessId -ne 0 -and $coversMonitor -and -not $foregroundMinimized -and $foregroundClass -notin $shellSurfaceClasses
    $foregroundProcessName = $null
    $foregroundProcessPath = $null
    if ($foregroundProcessId) {
        try {
            $foregroundProcess = [Diagnostics.Process]::GetProcessById([int]$foregroundProcessId)
            try {
                $foregroundProcessName = $foregroundProcess.ProcessName
                try { $foregroundProcessPath = $foregroundProcess.MainModule.FileName } catch { }
            } finally {
                $foregroundProcess.Dispose()
            }
        } catch { }
    }
    $foregroundRecord = [ordered]@{
        hwnd = ('0x{0:X}' -f $foregroundWindow.ToInt64())
        pid = $foregroundProcessId
        processName = $foregroundProcessName
        processPath = $foregroundProcessPath
        className = $foregroundClass
        minimized = $foregroundMinimized
        rect = Convert-Rect $foregroundRect
        monitor = $foregroundMonitor.DeviceName
        coversMonitorBounds = $coversMonitor
        fullscreenGeometryCandidate = $fullscreenGeometryCandidate
        classification = if ($fullscreenGeometryCandidate) { 'fullscreen-geometry-candidate' } else { 'windowed-or-shell-surface' }
    }
    }
}

$taskbarAlignment = $null
$advancedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
try {
    $taskbarAlignmentValue = (Get-ItemProperty -LiteralPath $advancedKey -Name TaskbarAl -ErrorAction Stop).TaskbarAl
    $taskbarAlignment = if ($taskbarAlignmentValue -eq 0) { 'left' } elseif ($taskbarAlignmentValue -eq 1) { 'center' } else { "unknown:$taskbarAlignmentValue" }
} catch { }

$snapshot = [ordered]@{
    schemaVersion = 3
    capturedUtc = [DateTime]::UtcNow.ToString('o')
    machine = $env:COMPUTERNAME
    user = [Environment]::UserName
    userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    observerSessionId = $observerSessionId
    observerLogonId = $observerLogonId
    qualification = [ordered]@{
        # This explicit proof prevents an ordinary observation that merely
        # happens to look clean from being reused as the required fresh,
        # pre-injection qualification baseline.
        cleanProductStateVerified = [bool]$RequireCleanProductState
        explorerAgeSeconds = if ($RequireCleanProductState) { [Math]::Round($cleanExplorerAgeSeconds, 6) } else { $null }
        maximumExplorerAgeSeconds = if ($RequireCleanProductState) { $MaximumCleanExplorerAgeSeconds } else { $null }
    }
    os = [ordered]@{
        version = [Environment]::OSVersion.Version.ToString()
        logicalProcessors = [Environment]::ProcessorCount
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    product = [ordered]@{
        directory = $resolvedProductDirectory
        registration = $productRegistration
        selectedHost = $selectedHostEvidence
        selectedDll = $selectedDllEvidence
        mappedDllPaths = $a4sMappings
        competingStartMenuModulePaths = $competingStartMenuMappings
        residentHost = $residentHostRecord
        hostProcesses = $hostProcessRecords
    }
    explorer = Get-ProcessRecord -Process $explorerProcess
    desktop = [ordered]@{
        monitors = @($monitorRecords | ForEach-Object {
            [ordered]@{
                device = $_.DeviceName
                primary = $_.Primary
                bounds = [ordered]@{ left = $_.Left; top = $_.Top; width = $_.Width; height = $_.Height }
                workArea = [ordered]@{ left = $_.WorkLeft; top = $_.WorkTop; width = $_.WorkWidth; height = $_.WorkHeight }
                dpiAvailable = $_.DpiAvailable
                dpiSource = if ($_.DpiAvailable) { 'GetScaleFactorForMonitor; effective DPI derived from scale' } else { $null }
                dpiX = if ($_.DpiAvailable) { $_.DpiX } else { $null }
                dpiY = if ($_.DpiAvailable) { $_.DpiY } else { $null }
                scalePercent = if ($_.DpiAvailable) { $_.ScalePercent } else { $null }
            }
        })
        taskbar = [ordered]@{
            hwnd = ('0x{0:X}' -f $taskbar.ToInt64())
            rect = Convert-Rect $taskbarRect
            edge = $taskbarEdge
            alignmentRegistryHint = $taskbarAlignment
        }
        foreground = $foregroundRecord
    }
}

# Fail closed if Explorer, the host, a mapped product image, or either staged
# binary changed while this multi-source snapshot was being assembled.
$finalTaskbar = [A4SObservationNative]::FindWindowW('Shell_TrayWnd', $null)
[uint32]$finalExplorerProcessId = 0
if ($finalTaskbar -eq [IntPtr]::Zero -or $finalTaskbar -ne $taskbar -or
    [A4SObservationNative]::GetWindowThreadProcessId($finalTaskbar, [ref]$finalExplorerProcessId) -eq 0 -or
    $finalExplorerProcessId -ne $explorerProcessId) {
    throw 'The taskbar Explorer identity changed while the observation snapshot was being captured.'
}
$finalExplorer = [Diagnostics.Process]::GetProcessById([int]$finalExplorerProcessId)
try {
    if ($finalExplorer.StartTime.ToUniversalTime().Ticks -ne $explorerStartTicks) {
        throw 'The taskbar Explorer PID was reused while the observation snapshot was being captured.'
    }
    $finalModulePaths = @(Get-ModulePaths -Process $finalExplorer)
    $finalMappings = @($finalModulePaths | Where-Object { [IO.Path]::GetFileName($_) -ieq 'A4SMenu.dll' })
    $finalCompetingMappings = @($finalModulePaths | Where-Object { [IO.Path]::GetFileName($_) -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
    if (($finalMappings -join "`n") -ne ($a4sMappings -join "`n")) {
        throw 'The set of mapped A4SMenu.dll images changed while the observation snapshot was being captured.'
    }
    if (($finalCompetingMappings -join "`n") -ne ($competingStartMenuMappings -join "`n")) {
        throw 'The set of competing StartAllBack/StartIsBack/Open-Shell modules changed while the observation snapshot was being captured.'
    }
} finally { $finalExplorer.Dispose() }
$finalHostWindow = [A4SObservationNative]::FindWindowW('A4SMenu.Host.Window.v1', 'A4SMenuHost')
if ($finalHostWindow -ne $residentHostWindow) {
    throw 'The resident A4S host changed while the observation snapshot was being captured.'
}
$finalHostProcessRecords = @(Get-A4SHostProcessRecords -SessionId $observerSessionId -LogonId $observerLogonId)
$initialHostProcessKeys = @($hostProcessRecords | ForEach-Object { "$($_.pid)|$($_.startTimeUtc)|$($_.path)" } | Sort-Object)
$finalHostProcessKeys = @($finalHostProcessRecords | ForEach-Object { "$($_.pid)|$($_.startTimeUtc)|$($_.path)" } | Sort-Object)
if (($finalHostProcessKeys -join "`n") -ne ($initialHostProcessKeys -join "`n")) {
    throw 'The set of same-logon A4SMenuHost processes changed while the observation snapshot was being captured.'
}
foreach ($evidencePair in @(
    [pscustomobject]@{ before = $selectedHostEvidence; after = $(if ($selectedHostEvidence) { Get-StableFileEvidence $hostExecutable } else { $null }) }
    [pscustomobject]@{ before = $selectedDllEvidence; after = $(if ($selectedDllEvidence) { Get-StableFileEvidence $menuDll } else { $null }) }
)) {
    if ($evidencePair.before -and ($evidencePair.before.length -ne $evidencePair.after.length -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$evidencePair.before.sha256, [string]$evidencePair.after.sha256))) {
        throw 'A staged product binary changed while the observation snapshot was being captured.'
    }
}
$finalProductRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
if ($finalProductRegistration.kind -ne $productRegistration.kind -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$finalProductRegistration.activeSlot, [string]$productRegistration.activeSlot)) {
    throw 'The selected product registration/ActiveSlot changed while the observation snapshot was being captured.'
}

$explorerProcess.Dispose()
$json = $snapshot | ConvertTo-Json -Depth 10
if ($OutputPath) {
    $resolvedOutput = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    Write-DurableJsonCreateNew -Path $resolvedOutput -Json $json
    Write-Host "Wrote A4S observation snapshot: $resolvedOutput"
}
$json
