[CmdletBinding()]
param(
    [switch] $AllowMenuAutomation,
    [ValidateRange(3, 200)]
    [int] $WarmSamples = 20,
    [ValidateRange(2, 60)]
    [int] $IdleSeconds = 10,
    [ValidateRange(500, 10000)]
    [int] $TransitionTimeoutMilliseconds = 3000,
    [ValidateRange(0, 2000)]
    [int] $SettleMilliseconds = 250,
    [string] $ProductDirectory,
    [string] $BaselinePath,
    [ValidateRange(1, 60)]
    [int] $MaximumBaselineAgeMinutes = 10,
    [string] $OutputPath,
    [switch] $OperatorAttestsFirstOpenIsCold,
    [switch] $CapturePopInEvidence,
    [switch] $EnforceTargets,
    [ValidateRange(1, 250)]
    [double] $WarmOpenTargetMilliseconds = 50,
    [ValidateRange(0, 5)]
    [double] $HostIdleCpuTargetPercent = 0.05
)

$ErrorActionPreference = 'Stop'

if (-not $AllowMenuAutomation) {
    throw @'
This probe visibly opens and closes the already-running A4S menu. It never
starts the host, injects Explorer, restarts Explorer, or changes the session.
Re-run explicitly with -AllowMenuAutomation after A4SMenuHost reports READY.
'@
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run this probe from 64-bit PowerShell so Explorer metrics and modules are authoritative.'
}
if ($EnforceTargets -and -not $BaselinePath) {
    throw '-EnforceTargets requires -BaselinePath from a fresh exact-product clean snapshot.'
}
if ($EnforceTargets -and $WarmSamples -lt 20) {
    throw '-EnforceTargets requires at least 20 warm samples.'
}
if ($EnforceTargets -and $IdleSeconds -lt 10) {
    throw '-EnforceTargets requires at least 10 seconds of idle observation.'
}

Import-Module (Join-Path $PSScriptRoot 'A4SBinaryIdentity.psm1') -Force
$qualificationAutomationMutex = Enter-A4SQualificationAutomationLock
try {

if (-not ('A4SPerformanceNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class A4SPerformanceNative
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        private const int CchDeviceName = 32;
        private const int CchFormName = 32;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CchDeviceName)] public string DeviceName;
        public ushort SpecVersion;
        public ushort DriverVersion;
        public ushort Size;
        public ushort DriverExtra;
        public uint Fields;
        public int PositionX;
        public int PositionY;
        public uint DisplayOrientation;
        public uint DisplayFixedOutput;
        public short Color;
        public short Duplex;
        public short YResolution;
        public short TTOption;
        public short Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CchFormName)] public string FormName;
        public ushort LogPixels;
        public uint BitsPerPel;
        public uint PelsWidth;
        public uint PelsHeight;
        public uint DisplayFlags;
        public uint DisplayFrequency;
        public uint IcmMethod;
        public uint IcmIntent;
        public uint MediaType;
        public uint DitherType;
        public uint Reserved1;
        public uint Reserved2;
        public uint PanningWidth;
        public uint PanningHeight;
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessageW(string message);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, UIntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out UIntPtr result);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr window, StringBuilder className, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out RECT rect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string deviceName, int modeNumber, ref DEVMODE mode);

    [DllImport("dwmapi.dll")]
    private static extern int DwmFlush();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessIoCounters(IntPtr process, out IO_COUNTERS counters);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

    private static IntPtr EnterPhysicalCoordinates()
    {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadDpiAwarenessContext failed");
        return previous;
    }

    private static void RestoreDpiContext(IntPtr previous)
    {
        if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
    }

    public static IntPtr EnterPhysicalCapture()
    {
        return EnterPhysicalCoordinates();
    }

    public static void LeavePhysicalCapture(IntPtr previous)
    {
        RestoreDpiContext(previous);
    }

    public static IntPtr HostWindow()
    {
        return FindWindowW("A4SMenu.Host.Window.v1", "A4SMenuHost");
    }

    public static uint HostStatus(IntPtr hostWindow, uint timeoutMilliseconds)
    {
        uint message = RegisterWindowMessageW("A4SMenu.Host.Control.v1");
        if (message == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterWindowMessage failed");
        UIntPtr result;
        if (SendMessageTimeoutW(hostWindow, message, new UIntPtr(4), IntPtr.Zero,
            0x0002 | 0x0001, timeoutMilliseconds, out result) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "A4S host status request failed");
        return unchecked((uint)result.ToUInt64());
    }

    public static void Toggle(IntPtr hostWindow, uint timeoutMilliseconds)
    {
        uint message = RegisterWindowMessageW("A4SMenu.Host.Control.v1");
        if (message == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterWindowMessage failed");
        UIntPtr result;
        if (SendMessageTimeoutW(hostWindow, message, new UIntPtr(1), IntPtr.Zero,
            0x0002 | 0x0001, timeoutMilliseconds, out result) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "A4S host toggle request failed");
        if (result == UIntPtr.Zero)
            throw new InvalidOperationException("The A4S host rejected the toggle request.");
    }

    public static IntPtr[] VisibleMenuWindows(uint ownerProcessId)
    {
        List<IntPtr> matches = new List<IntPtr>();
        if (!EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window)) return true;
            StringBuilder name = new StringBuilder(256);
            if (GetClassNameW(window, name, name.Capacity) > 0 &&
                String.Equals(name.ToString(), "A4SMenu.CMenuContainer", StringComparison.Ordinal))
            {
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                if (processId == ownerProcessId)
                    matches.Add(window);
            }
            return true;
        }, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
        return matches.ToArray();
    }

    public static RECT WindowRect(IntPtr window)
    {
        IntPtr previous = EnterPhysicalCoordinates();
        try
        {
            RECT rect;
            if (!GetWindowRect(window, out rect))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowRect failed");
            return rect;
        }
        finally { RestoreDpiContext(previous); }
    }

    public static uint NominalRefreshRate(IntPtr window)
    {
        IntPtr previous = EnterPhysicalCoordinates();
        try
        {
            IntPtr monitor = MonitorFromWindow(window, 2);
            MONITORINFOEX info = new MONITORINFOEX();
            info.Size = (uint)Marshal.SizeOf(typeof(MONITORINFOEX));
            if (monitor == IntPtr.Zero || !GetMonitorInfoW(monitor, ref info))
                return 0;
            DEVMODE mode = new DEVMODE();
            mode.Size = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettingsW(info.DeviceName, -1, ref mode))
                return 0;
            return mode.DisplayFrequency >= 20 && mode.DisplayFrequency <= 1000 ? mode.DisplayFrequency : 0;
        }
        finally { RestoreDpiContext(previous); }
    }

    public static void FlushDwmChecked()
    {
        int result = DwmFlush();
        if (result < 0)
            Marshal.ThrowExceptionForHR(result);
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
}
'@
}

function Wait-MenuVisibility {
    param(
        [Parameter(Mandatory)][bool] $Visible,
        [Parameter(Mandatory)][int] $TimeoutMilliseconds,
        [Parameter(Mandatory)][uint32] $OwnerProcessId
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $windows = @([A4SPerformanceNative]::VisibleMenuWindows($OwnerProcessId))
        if (($Visible -and $windows.Count -gt 0) -or (-not $Visible -and $windows.Count -eq 0)) {
            return [ordered]@{ elapsedMilliseconds = $timer.Elapsed.TotalMilliseconds; windows = $windows }
        }
        [Threading.Thread]::Sleep(1)
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw "A4S menu did not become $(if($Visible){'visible'}else{'hidden'}) within $TimeoutMilliseconds ms."
}

function Get-IoDelta {
    param($Before, $After)
    [ordered]@{
        readOperations = [uint64]($After.ReadOperations - $Before.ReadOperations)
        writeOperations = [uint64]($After.WriteOperations - $Before.WriteOperations)
        otherOperations = [uint64]($After.OtherOperations - $Before.OtherOperations)
        readBytes = [uint64]($After.ReadBytes - $Before.ReadBytes)
        writeBytes = [uint64]($After.WriteBytes - $Before.WriteBytes)
        otherBytes = [uint64]($After.OtherBytes - $Before.OtherBytes)
    }
}

function Get-Percentile {
    param([double[]] $Values, [double] $Percentile)
    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) { return $null }
    $rank = [Math]::Ceiling($Percentile * $ordered.Count) - 1
    if ($rank -lt 0) { $rank = 0 }
    [double]$ordered[[Math]::Min($rank, $ordered.Count - 1)]
}

function Get-ProcessMetrics {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    $Process.Refresh()
    [ordered]@{
        privateBytes = $Process.PrivateMemorySize64
        workingSetBytes = $Process.WorkingSet64
        handleCount = $Process.HandleCount
        threadCount = $Process.Threads.Count
        cpuTicks = $Process.TotalProcessorTime.Ticks
    }
}

function Get-StableFileEvidence {
    param([Parameter(Mandatory)][string] $Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $sha.Dispose() }
        [pscustomobject][ordered]@{ path = $resolved; length = $stream.Length; sha256 = $hash }
    }
    finally { $stream.Dispose() }
}

function Write-DurableJsonCreateNew {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Json)

    if (Test-Path -LiteralPath $Path) { throw "Evidence output already exists: '$Path'. Choose a new path; qualification evidence is never overwritten." }
    $temporary = "$Path.partial-$PID-$([Guid]::NewGuid().ToString('N'))"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json + [Environment]::NewLine)
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    [IO.File]::Move($temporary, $Path)
}

function Assert-A4SResidentContext {
    param(
        [Parameter(Mandatory)][IntPtr] $ExpectedHostWindow,
        [Parameter(Mandatory)][uint32] $ExpectedHostProcessId,
        [Parameter(Mandatory)][int64] $ExpectedHostStartTicks,
        [Parameter(Mandatory)][uint32] $ExpectedExplorerProcessId,
        [Parameter(Mandatory)][int64] $ExpectedExplorerStartTicks,
        [Parameter(Mandatory)][string] $ExpectedLogonId
    )

    $currentHostWindow = [A4SPerformanceNative]::HostWindow()
    if ($currentHostWindow -eq [IntPtr]::Zero -or $currentHostWindow -ne $ExpectedHostWindow) {
        throw 'The validated resident host window disappeared or was replaced during measurement.'
    }
    [uint32]$currentHostProcessId = 0
    [void][A4SPerformanceNative]::GetWindowThreadProcessId($currentHostWindow, [ref]$currentHostProcessId)
    if ($currentHostProcessId -ne $ExpectedHostProcessId) { throw 'The validated resident host process changed during measurement.' }
    $currentTaskbar = [A4SPerformanceNative]::FindWindowW('Shell_TrayWnd', $null)
    [uint32]$currentExplorerProcessId = 0
    if ($currentTaskbar -eq [IntPtr]::Zero -or
        [A4SPerformanceNative]::GetWindowThreadProcessId($currentTaskbar, [ref]$currentExplorerProcessId) -eq 0 -or
        $currentExplorerProcessId -ne $ExpectedExplorerProcessId) {
        throw 'The taskbar Explorer process changed during measurement.'
    }
    $currentHost = [Diagnostics.Process]::GetProcessById([int]$currentHostProcessId)
    $currentExplorer = [Diagnostics.Process]::GetProcessById([int]$currentExplorerProcessId)
    try {
        if ($currentHost.StartTime.ToUniversalTime().Ticks -ne $ExpectedHostStartTicks -or
            $currentExplorer.StartTime.ToUniversalTime().Ticks -ne $ExpectedExplorerStartTicks) {
            throw 'A validated process exited and its PID was reused during measurement.'
        }
        if ((Get-A4SProcessLogonId -ProcessId $currentHostProcessId) -ne $ExpectedLogonId -or
            (Get-A4SProcessLogonId -ProcessId $currentExplorerProcessId) -ne $ExpectedLogonId) {
            throw 'The resident host or Explorer logon-session identity changed during measurement.'
        }
    }
    finally {
        $currentHost.Dispose()
        $currentExplorer.Dispose()
    }
    if ([A4SPerformanceNative]::HostStatus($currentHostWindow, 2500) -ne 3) {
        throw 'A4SMenuHost left READY during measurement.'
    }
}

function Save-WindowCapture {
    param([Parameter(Mandatory)][IntPtr] $Window, [Parameter(Mandatory)][string] $Path)
    Add-Type -AssemblyName System.Drawing
    if ([IO.File]::Exists($Path)) { throw "Pop-in evidence already exists: '$Path'." }
    $temporary = "$Path.partial-$PID-$([Guid]::NewGuid().ToString('N')).png"
    $previousDpiContext = [A4SPerformanceNative]::EnterPhysicalCapture()
    try {
        $rect = [A4SPerformanceNative]::WindowRect($Window)
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -le 0 -or $height -le 0) { throw 'The visible menu has an invalid capture rectangle.' }
        $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try { $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy) }
            finally { $graphics.Dispose() }
            $bitmap.Save($temporary, [Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $bitmap.Dispose() }
        [IO.File]::Move($temporary, $Path)
    }
    finally {
        try { [A4SPerformanceNative]::LeavePhysicalCapture($previousDpiContext) }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ProductDirectory) { $ProductDirectory = Join-Path $repoRoot 'build\stage\A4SProduct' }
$resolvedProductDirectory = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProductDirectory))
$productRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
$expectedHost = [IO.Path]::GetFullPath((Join-Path $resolvedProductDirectory 'A4SMenuHost.exe'))
$expectedDll = [IO.Path]::GetFullPath((Join-Path $resolvedProductDirectory 'A4SMenu.dll'))
foreach ($requiredFile in @($expectedHost, $expectedDll)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required product binary is missing: '$requiredFile'." }
}
$hostWindow = [A4SPerformanceNative]::HostWindow()
if ($hostWindow -eq [IntPtr]::Zero) { throw 'No resident A4SMenuHost window was found. This tool never starts or injects the host.' }
if ([A4SPerformanceNative]::HostStatus($hostWindow, 2500) -ne 3) { throw 'A4SMenuHost is not READY.' }

[uint32]$residentHostProcessId = 0
[void][A4SPerformanceNative]::GetWindowThreadProcessId($hostWindow, [ref]$residentHostProcessId)
$taskbar = [A4SPerformanceNative]::FindWindowW('Shell_TrayWnd', $null)
if ($taskbar -eq [IntPtr]::Zero) { throw 'Shell_TrayWnd was not found.' }
[uint32]$explorerProcessId = 0
[void][A4SPerformanceNative]::GetWindowThreadProcessId($taskbar, [ref]$explorerProcessId)
if (-not $explorerProcessId -or -not $residentHostProcessId) { throw 'Could not resolve the A4S host or taskbar Explorer process.' }

$explorerProcess = [Diagnostics.Process]::GetProcessById([int]$explorerProcessId)
$residentHostProcess = [Diagnostics.Process]::GetProcessById([int]$residentHostProcessId)
$explorerStartTicks = $explorerProcess.StartTime.ToUniversalTime().Ticks
$hostStartTicks = $residentHostProcess.StartTime.ToUniversalTime().Ticks
$observerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($explorerProcess.SessionId -ne $observerSessionId -or $residentHostProcess.SessionId -ne $observerSessionId) {
    throw "The observer, Explorer, and A4S host must share one interactive session. observer=$observerSessionId explorer=$($explorerProcess.SessionId) host=$($residentHostProcess.SessionId)."
}
$observerLogonId = Get-A4SProcessLogonId -ProcessId ([uint32][Diagnostics.Process]::GetCurrentProcess().Id)
$hostLogonId = Get-A4SProcessLogonId -ProcessId $residentHostProcessId
$explorerLogonId = Get-A4SProcessLogonId -ProcessId $explorerProcessId
if ($hostLogonId -ne $observerLogonId -or $explorerLogonId -ne $observerLogonId) {
    throw "The observer, Explorer, and A4S host must share one logon identity. observer=$observerLogonId explorer=$explorerLogonId host=$hostLogonId."
}
$actualHostPath = [IO.Path]::GetFullPath($residentHostProcess.MainModule.FileName)
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualHostPath, $expectedHost)) {
    throw "The resident host is not the product directory under test. Expected '$expectedHost'; found '$actualHostPath'."
}
$mappedDllModules = @($explorerProcess.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' })
$competingStartMenuModules = @($explorerProcess.Modules | Where-Object { $_.ModuleName -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
$mappedDlls = @($mappedDllModules | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) })
if ($mappedDllModules.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals($mappedDlls[0], $expectedDll)) {
    throw "Expected exactly one A4SMenu.dll mapping from the product directory under test in Explorer PID $explorerProcessId; found '$($mappedDlls -join '; ')'."
}
if ($competingStartMenuModules.Count -ne 0) {
    throw "A competing StartAllBack/StartIsBack/Open-Shell module remains mapped in Explorer: '$(@($competingStartMenuModules.FileName) -join '; ')'."
}
$hostFileEvidence = Get-StableFileEvidence $expectedHost
$dllFileEvidence = Get-StableFileEvidence $expectedDll
$hostFileIdentity = Get-A4SFileImageIdentity $expectedHost
$hostLoadedIdentity = Get-A4SLoadedImageIdentity -ProcessId $residentHostProcessId -BaseAddress $residentHostProcess.MainModule.BaseAddress
$dllFileIdentity = Get-A4SFileImageIdentity $expectedDll
$dllLoadedIdentity = Get-A4SLoadedImageIdentity -ProcessId $explorerProcessId -BaseAddress $mappedDllModules[0].BaseAddress
if ($hostFileIdentity -ne $hostLoadedIdentity -or $dllFileIdentity -ne $dllLoadedIdentity) {
    throw "A resident product image differs from the file currently at the validated path. host(file='$hostFileIdentity', memory='$hostLoadedIdentity'); dll(file='$dllFileIdentity', memory='$dllLoadedIdentity')."
}
[void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
    -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
    -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)

$visibleBefore = @([A4SPerformanceNative]::VisibleMenuWindows($explorerProcessId))
if ($visibleBefore.Count -ne 0) {
    throw 'Close the A4S menu before starting the performance probe. The tool will not guess the current menu state.'
}

if (-not $OutputPath) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $OutputPath = Join-Path $repoRoot "build\test-results\A4S-performance-$stamp-$PID.json"
}
$resolvedOutput = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Evidence output already exists: '$resolvedOutput'. Choose a new path; qualification evidence is never overwritten."
}
$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$baselineComparison = $null
if ($BaselinePath) {
    $resolvedBaseline = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BaselinePath))
    $baseline = Get-Content -LiteralPath $resolvedBaseline -Raw | ConvertFrom-Json
    if ($baseline.schemaVersion -ne 3) { throw "Unsupported clean-baseline schema in '$resolvedBaseline'. Capture a new explicit clean baseline with this toolset." }
    if (-not $baseline.product.directory -or -not $baseline.product.registration) {
        throw 'The clean baseline predates exact product-directory/registration binding; capture a new baseline with this toolset.'
    }
    $baselineExplorerAgeSeconds = [double]$baseline.qualification.explorerAgeSeconds
    $baselineMaximumExplorerAgeSeconds = [double]$baseline.qualification.maximumExplorerAgeSeconds
    if (-not $baseline.qualification -or $baseline.qualification.cleanProductStateVerified -ne $true -or
        $null -eq $baseline.qualification.explorerAgeSeconds -or
        $null -eq $baseline.qualification.maximumExplorerAgeSeconds -or
        [double]::IsNaN($baselineExplorerAgeSeconds) -or [double]::IsInfinity($baselineExplorerAgeSeconds) -or
        [double]::IsNaN($baselineMaximumExplorerAgeSeconds) -or [double]::IsInfinity($baselineMaximumExplorerAgeSeconds) -or
        $baselineExplorerAgeSeconds -lt 0 -or
        $baselineMaximumExplorerAgeSeconds -le 0 -or
        $baselineMaximumExplorerAgeSeconds -gt 120 -or
        $baselineExplorerAgeSeconds -gt $baselineMaximumExplorerAgeSeconds) {
        throw 'The baseline was not captured with the explicit fresh pre-injection clean-state contract (maximum Explorer age 120 seconds).'
    }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$baseline.machine, [Environment]::MachineName) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$baseline.user, [Environment]::UserName)) {
        throw 'The clean baseline belongs to a different machine or user.'
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not [StringComparer]::Ordinal.Equals([string]$baseline.userSid, $currentSid)) {
        throw 'The clean baseline belongs to a different Windows security principal.'
    }
    $baselineCaptured = [DateTimeOffset]::Parse([string]$baseline.capturedUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    $baselineAge = [DateTimeOffset]::UtcNow - $baselineCaptured
    if ($baselineAge.TotalSeconds -lt -5 -or $baselineAge.TotalMinutes -gt $MaximumBaselineAgeMinutes) {
        throw "The clean baseline is not temporally valid for this run (age=$([Math]::Round($baselineAge.TotalMinutes, 3)) minutes; maximum=$MaximumBaselineAgeMinutes)."
    }
    if ($baseline.explorer.pid -ne $explorerProcessId) { throw "Baseline Explorer PID $($baseline.explorer.pid) does not match current PID $explorerProcessId." }
    if ($baseline.explorer.startTimeUtc -ne $explorerProcess.StartTime.ToUniversalTime().ToString('o')) { throw 'The baseline Explorer start time does not match the current Explorer process.' }
    if ($baseline.observerSessionId -ne $observerSessionId -or $baseline.explorer.sessionId -ne $observerSessionId) { throw 'The clean baseline belongs to a different interactive session.' }
    if ([string]$baseline.observerLogonId -ne $observerLogonId -or [string]$baseline.explorer.logonId -ne $explorerLogonId) {
        throw 'The clean baseline belongs to a different Windows logon session.'
    }
    if (@($baseline.product.mappedDllPaths).Count -ne 0 -or $baseline.product.residentHost -or
        @($baseline.product.hostProcesses).Count -ne 0 -or
        @($baseline.product.competingStartMenuModulePaths).Count -ne 0) { throw 'The baseline was not captured in a clean pre-injection state.' }
    if (-not $baseline.product.selectedHost -or -not $baseline.product.selectedDll -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$baseline.product.directory), $resolvedProductDirectory) -or
        [string]$baseline.product.registration.kind -ne [string]$productRegistration.kind -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$baseline.product.registration.activeSlot, [string]$productRegistration.activeSlot) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$baseline.product.selectedHost.path), $expectedHost) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$baseline.product.selectedDll.path), $expectedDll) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$baseline.product.selectedHost.sha256, [string]$hostFileEvidence.sha256) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$baseline.product.selectedDll.sha256, [string]$dllFileEvidence.sha256) -or
        [int64]$baseline.product.selectedHost.length -ne [int64]$hostFileEvidence.length -or
        [int64]$baseline.product.selectedDll.length -ne [int64]$dllFileEvidence.length) {
        throw 'The staged payload differs from the exact host/DLL recorded by the clean baseline.'
    }
    $currentMetrics = Get-ProcessMetrics -Process $explorerProcess
    $baselineComparison = [ordered]@{
        source = $resolvedBaseline
        baselineCapturedUtc = $baselineCaptured.ToString('o')
        baselineAgeSeconds = [Math]::Round($baselineAge.TotalSeconds, 3)
        explorerPrivateBytesDelta = [int64]$currentMetrics.privateBytes - [int64]$baseline.explorer.privateBytes
        explorerWorkingSetBytesDelta = [int64]$currentMetrics.workingSetBytes - [int64]$baseline.explorer.workingSetBytes
        explorerHandleCountDelta = [int]$currentMetrics.handleCount - [int]$baseline.explorer.handleCount
        explorerThreadCountDelta = [int]$currentMetrics.threadCount - [int]$baseline.explorer.threadCount
    }
}

$samples = [Collections.Generic.List[object]]::new()
$refreshRate = 0
$firstCapturePath = $null
$settledCapturePath = $null
$firstCaptureHash = $null
$settledCaptureHash = $null
$automationMenuExpectedVisible = $false
$automationMenuWindow = [IntPtr]::Zero

try {
    # A run that does not claim a cold first sample gets an explicit, unmeasured
    # opening first. This prevents an accidentally cold opening from being
    # classified as a warm sample.
    if (-not $OperatorAttestsFirstOpenIsCold) {
        [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
            -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
            -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
        [A4SPerformanceNative]::Toggle($hostWindow, 2500)
        $preconditioned = Wait-MenuVisibility -Visible $true -TimeoutMilliseconds $TransitionTimeoutMilliseconds -OwnerProcessId $explorerProcessId
        if ($preconditioned.windows.Count -ne 1) { throw "Warm-up found $($preconditioned.windows.Count) visible A4S menu windows; expected one." }
        $automationMenuWindow = [IntPtr]$preconditioned.windows[0]
        $automationMenuExpectedVisible = $true
        [A4SPerformanceNative]::FlushDwmChecked()
        [A4SPerformanceNative]::Toggle($hostWindow, 2500)
        [void](Wait-MenuVisibility -Visible $false -TimeoutMilliseconds $TransitionTimeoutMilliseconds -OwnerProcessId $explorerProcessId)
        $automationMenuExpectedVisible = $false
        [A4SPerformanceNative]::FlushDwmChecked()
    }

    $sampleCount = $WarmSamples + $(if ($OperatorAttestsFirstOpenIsCold) { 1 } else { 0 })
    for ($index = 0; $index -lt $sampleCount; $index++) {
        if ($SettleMilliseconds) { Start-Sleep -Milliseconds $SettleMilliseconds }
        [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
            -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
            -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
        if (@([A4SPerformanceNative]::VisibleMenuWindows($explorerProcessId)).Count -ne 0) {
            throw "Sample $($index + 1) did not begin from a uniquely validated hidden-menu state."
        }
        $ioBefore = [A4SPerformanceNative]::ProcessIo($explorerProcessId)
        $openTimer = [Diagnostics.Stopwatch]::StartNew()
        [A4SPerformanceNative]::Toggle($hostWindow, 2500)
        $visible = Wait-MenuVisibility -Visible $true -TimeoutMilliseconds $TransitionTimeoutMilliseconds -OwnerProcessId $explorerProcessId
        $visibilityMilliseconds = $openTimer.Elapsed.TotalMilliseconds
        if ($visible.windows.Count -ne 1) { throw "Sample $($index + 1) found $($visible.windows.Count) visible A4S menu windows; expected one." }
        $menuWindow = [IntPtr]$visible.windows[0]
        $automationMenuWindow = $menuWindow
        $automationMenuExpectedVisible = $true
        [A4SPerformanceNative]::FlushDwmChecked()
        $afterDwmFlushMilliseconds = $openTimer.Elapsed.TotalMilliseconds
        if ([A4SPerformanceNative]::GetForegroundWindow() -ne $menuWindow) {
            throw "Sample $($index + 1) is invalid because the opened A4S menu was not the foreground top-level window."
        }
        $sampleRefreshRate = [A4SPerformanceNative]::NominalRefreshRate($menuWindow)
        if ($sampleRefreshRate -eq 0) {
            throw "Sample $($index + 1) could not resolve the actual menu monitor's nominal refresh rate."
        }
        if ($refreshRate -ne 0 -and $sampleRefreshRate -ne $refreshRate) {
            throw "Performance samples crossed menu monitors with different nominal refresh rates ($refreshRate and $sampleRefreshRate Hz). Run each monitor/rate separately."
        }
        $refreshRate = $sampleRefreshRate
        $ioAfter = [A4SPerformanceNative]::ProcessIo($explorerProcessId)

        if ($CapturePopInEvidence -and $index -eq 0) {
            $captureBase = [IO.Path]::GetFileNameWithoutExtension($resolvedOutput)
            $firstCapturePath = Join-Path $outputDirectory "$captureBase.popin-after-dwm-flush.png"
            $settledCapturePath = Join-Path $outputDirectory "$captureBase.popin-settled.png"
            if ((Test-Path -LiteralPath $firstCapturePath) -or (Test-Path -LiteralPath $settledCapturePath)) {
                throw 'A pop-in evidence image already exists; qualification evidence is never overwritten.'
            }
            Save-WindowCapture -Window $menuWindow -Path $firstCapturePath
            if ($SettleMilliseconds) { Start-Sleep -Milliseconds $SettleMilliseconds }
            [A4SPerformanceNative]::FlushDwmChecked()
            Save-WindowCapture -Window $menuWindow -Path $settledCapturePath
            $firstCaptureHash = (Get-FileHash -LiteralPath $firstCapturePath -Algorithm SHA256).Hash
            $settledCaptureHash = (Get-FileHash -LiteralPath $settledCapturePath -Algorithm SHA256).Hash
        }

        $closeTimer = [Diagnostics.Stopwatch]::StartNew()
        [A4SPerformanceNative]::Toggle($hostWindow, 2500)
        [void](Wait-MenuVisibility -Visible $false -TimeoutMilliseconds $TransitionTimeoutMilliseconds -OwnerProcessId $explorerProcessId)
        $automationMenuExpectedVisible = $false
        $closeVisibilityMilliseconds = $closeTimer.Elapsed.TotalMilliseconds
        [A4SPerformanceNative]::FlushDwmChecked()
        $closeAfterDwmFlushMilliseconds = $closeTimer.Elapsed.TotalMilliseconds

        $samples.Add([ordered]@{
            index = $index + 1
            classification = if ($index -eq 0 -and $OperatorAttestsFirstOpenIsCold) { 'operator-attested-first-open' } else { 'warm' }
            # Keep the raw Stopwatch double for target evaluation. Rounded
            # summary fields below are display-only and cannot flip a strict
            # one-frame boundary result.
            openVisibilityObservedMilliseconds = $visibilityMilliseconds
            openAfterDwmFlushMilliseconds = $afterDwmFlushMilliseconds
            closeVisibilityObservedMilliseconds = $closeVisibilityMilliseconds
            closeAfterDwmFlushMilliseconds = $closeAfterDwmFlushMilliseconds
            explorerProcessIoCountersDuringOpen = Get-IoDelta -Before $ioBefore -After $ioAfter
        })
    }

    $hostCpuBefore = $residentHostProcess.TotalProcessorTime
    $explorerCpuBefore = $explorerProcess.TotalProcessorTime
    $idleTimer = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $IdleSeconds
    $residentHostProcess.Refresh()
    $explorerProcess.Refresh()
    $idleTimer.Stop()
    $hostCpuDelta = ($residentHostProcess.TotalProcessorTime - $hostCpuBefore).TotalSeconds
    $explorerCpuDelta = ($explorerProcess.TotalProcessorTime - $explorerCpuBefore).TotalSeconds
    $normalizer = $idleTimer.Elapsed.TotalSeconds * [Environment]::ProcessorCount
    $hostIdlePercent = if ($normalizer -gt 0) { 100.0 * $hostCpuDelta / $normalizer } else { 0 }
    $explorerIdlePercent = if ($normalizer -gt 0) { 100.0 * $explorerCpuDelta / $normalizer } else { 0 }

    [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
        -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
        -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
    $postHostEvidence = Get-StableFileEvidence $expectedHost
    $postDllEvidence = Get-StableFileEvidence $expectedDll
    $postProductRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
    $postMappedDllModules = @($explorerProcess.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' })
    $postCompetingModules = @($explorerProcess.Modules | Where-Object { $_.ModuleName -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
    if ($postProductRegistration.kind -ne $productRegistration.kind -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$postProductRegistration.activeSlot, [string]$productRegistration.activeSlot) -or
        $postMappedDllModules.Count -ne 1 -or $postCompetingModules.Count -ne 0 -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($postMappedDllModules[0].FileName), $expectedDll) -or
        $postHostEvidence.length -ne $hostFileEvidence.length -or $postDllEvidence.length -ne $dllFileEvidence.length -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($postHostEvidence.sha256, $hostFileEvidence.sha256) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($postDllEvidence.sha256, $dllFileEvidence.sha256) -or
        (Get-A4SLoadedImageIdentity -ProcessId $residentHostProcessId -BaseAddress $residentHostProcess.MainModule.BaseAddress) -ne $hostLoadedIdentity -or
        (Get-A4SLoadedImageIdentity -ProcessId $explorerProcessId -BaseAddress $postMappedDllModules[0].BaseAddress) -ne $dllLoadedIdentity) {
        throw 'The staged or resident product identity changed during performance measurement.'
    }

    $warm = @($samples | Where-Object classification -eq 'warm')
    if ($warm.Count -ne $WarmSamples) { throw "Internal sample-classification error: expected $WarmSamples warm samples, found $($warm.Count)." }
    $attestedCold = @($samples | Where-Object classification -eq 'operator-attested-first-open')
    $openVisibilityValues = [double[]]@($warm | ForEach-Object { $_.openVisibilityObservedMilliseconds })
    $openAfterFlushValues = [double[]]@($warm | ForEach-Object { $_.openAfterDwmFlushMilliseconds })
    $closeVisibilityValues = [double[]]@($warm | ForEach-Object { $_.closeVisibilityObservedMilliseconds })
    $closeAfterFlushValues = [double[]]@($warm | ForEach-Object { $_.closeAfterDwmFlushMilliseconds })
    $frameMilliseconds = if ($refreshRate -gt 0) { 1000.0 / $refreshRate } else { $null }
    $ioCounterQuietSamples = @($warm | Where-Object {
        $_.explorerProcessIoCountersDuringOpen.readOperations -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.writeOperations -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.readBytes -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.writeBytes -eq 0
    }).Count
    $allIoCounterQuietSamples = @($warm | Where-Object {
        $_.explorerProcessIoCountersDuringOpen.readOperations -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.writeOperations -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.otherOperations -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.readBytes -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.writeBytes -eq 0 -and
        $_.explorerProcessIoCountersDuringOpen.otherBytes -eq 0
    }).Count

    $summary = [ordered]@{
        operatorAttestedColdOpenVisibilityObservedMilliseconds = if ($attestedCold.Count -eq 1) { $attestedCold[0].openVisibilityObservedMilliseconds } else { $null }
        operatorAttestedColdOpenAfterDwmFlushMilliseconds = if ($attestedCold.Count -eq 1) { $attestedCold[0].openAfterDwmFlushMilliseconds } else { $null }
        warmOpenVisibilityObservedP50Milliseconds = [Math]::Round((Get-Percentile $openVisibilityValues 0.50), 3)
        warmOpenVisibilityObservedP95Milliseconds = [Math]::Round((Get-Percentile $openVisibilityValues 0.95), 3)
        warmOpenAfterDwmFlushP50Milliseconds = [Math]::Round((Get-Percentile $openAfterFlushValues 0.50), 3)
        warmOpenAfterDwmFlushP95Milliseconds = [Math]::Round((Get-Percentile $openAfterFlushValues 0.95), 3)
        warmOpenAfterDwmFlushMaximumMilliseconds = [Math]::Round((($openAfterFlushValues | Measure-Object -Maximum).Maximum), 3)
        closeVisibilityObservedP95Milliseconds = [Math]::Round((Get-Percentile $closeVisibilityValues 0.95), 3)
        closeAfterDwmFlushP50Milliseconds = [Math]::Round((Get-Percentile $closeAfterFlushValues 0.50), 3)
        closeAfterDwmFlushP95Milliseconds = [Math]::Round((Get-Percentile $closeAfterFlushValues 0.95), 3)
        closeAfterDwmFlushMaximumMilliseconds = [Math]::Round((($closeAfterFlushValues | Measure-Object -Maximum).Maximum), 3)
        nominalRefreshRateHz = $refreshRate
        nominalDisplayFrameMilliseconds = if ($frameMilliseconds) { [Math]::Round($frameMilliseconds, 3) } else { $null }
        warmOpenProxyAtOrBelowTarget = (Get-Percentile $openAfterFlushValues 0.95) -le $WarmOpenTargetMilliseconds
        closeProxyWithinOneNominalFrame = if ($frameMilliseconds) { (Get-Percentile $closeAfterFlushValues 0.95) -le $frameMilliseconds } else { $null }
        warmOpenIoCounterQuietSamples = $ioCounterQuietSamples
        warmOpenIoCounterQuietTotal = $warm.Count
        allWarmOpensExplorerIoCountersQuiet = $ioCounterQuietSamples -eq $warm.Count
        warmOpenAllIoCounterQuietSamples = $allIoCounterQuietSamples
        allWarmOpensExplorerAllIoCountersQuiet = $allIoCounterQuietSamples -eq $warm.Count
        hostIdleCpuPercent = [Math]::Round($hostIdlePercent, 6)
        explorerProcessIdleCpuPercent = [Math]::Round($explorerIdlePercent, 6)
        hostEffectivelyIdle = $hostIdlePercent -le $HostIdleCpuTargetPercent
    }

    $result = [ordered]@{
        schemaVersion = 2
        capturedUtc = [DateTime]::UtcNow.ToString('o')
        measurementScope = [ordered]@{
            commandPath = 'resident-host SendMessageTimeout to an Explorer-owned visible-window observation, followed by DwmFlush in the observer process'
            presentationLimit = 'IsWindowVisible and observer-process DwmFlush are timing proxies; neither proves the exact first or last presented menu frame'
            pollingLimit = 'EnumWindows polling and scheduler granularity can add measurement latency and therefore create false timing failures'
            explorerIo = 'process-wide I/O counters; background Explorer activity can create false positives, while cache, paging, and memory-mapped activity can create false negatives for physical disk access'
            explorerCpu = 'process-wide; not attributable to A4S without ETW markers'
            coldClassification = if ($OperatorAttestsFirstOpenIsCold) { 'operator attestation only; excluded from warm summary' } else { 'not measured; an unmeasured warm-up cycle ran before all samples' }
        }
        product = [ordered]@{
            directory = $resolvedProductDirectory
            registration = $productRegistration
            hostSha256 = $hostFileEvidence.sha256
            hostLength = $hostFileEvidence.length
            hostFileIdentity = $hostFileIdentity
            hostLoadedIdentity = $hostLoadedIdentity
            dllSha256 = $dllFileEvidence.sha256
            dllLength = $dllFileEvidence.length
            dllFileIdentity = $dllFileIdentity
            dllLoadedIdentity = $dllLoadedIdentity
        }
        processes = [ordered]@{
            observerSessionId = $observerSessionId
            observerLogonId = $observerLogonId
            hostPid = $residentHostProcessId
            hostStartTimeUtc = $residentHostProcess.StartTime.ToUniversalTime().ToString('o')
            hostPath = $actualHostPath
            explorerPid = $explorerProcessId
            explorerStartTimeUtc = $explorerProcess.StartTime.ToUniversalTime().ToString('o')
            mappedDll = $mappedDlls[0]
        }
        targets = [ordered]@{ warmOpenProxyMilliseconds = $WarmOpenTargetMilliseconds; closeProxyNominalFrames = 1; hostIdleCpuPercent = $HostIdleCpuTargetPercent; warmOpenExplorerReadWriteIoCounterChanges = 0 }
        baselineComparison = $baselineComparison
        summary = $summary
        popInEvidence = if ($CapturePopInEvidence) { [ordered]@{
            captureAfterDwmFlushPath = $firstCapturePath
            settledPath = $settledCapturePath
            captureAfterDwmFlushSha256 = $firstCaptureHash
            settledSha256 = $settledCaptureHash
            pixelStableByExactPngHash = $firstCaptureHash -eq $settledCaptureHash
            qualification = 'The first capture occurs after an observer-process DwmFlush and can miss short-lived pop-in. Equal hashes show only sampled-image equality. Different hashes are inconclusive because acrylic, wallpaper, cursor, and desktop animation also alter pixels.'
        } } else { $null }
        samples = $samples
    }

    $json = $result | ConvertTo-Json -Depth 10
    Write-DurableJsonCreateNew -Path $resolvedOutput -Json $json
    Write-Host "Wrote A4S performance evidence: $resolvedOutput"
    Write-Host ("Warm-open proxy p95={0:N3} ms; close proxy p95={1:N3} ms; host idle CPU={2:N6}%; Explorer-I/O-counter-quiet warm opens={3}/{4}" -f
        $summary.warmOpenAfterDwmFlushP95Milliseconds, $summary.closeAfterDwmFlushP95Milliseconds, $summary.hostIdleCpuPercent,
        $summary.warmOpenIoCounterQuietSamples, $summary.warmOpenIoCounterQuietTotal)

    if ($EnforceTargets) {
        $failures = [Collections.Generic.List[string]]::new()
        if (-not $summary.warmOpenProxyAtOrBelowTarget) { $failures.Add("warm-open external proxy p95 exceeds $WarmOpenTargetMilliseconds ms") }
        if ($null -eq $summary.closeProxyWithinOneNominalFrame) { $failures.Add('nominal display refresh rate was unavailable, so the external close proxy could not be compared with one nominal frame') }
        elseif (-not $summary.closeProxyWithinOneNominalFrame) { $failures.Add('close external proxy p95 exceeds one nominal display frame') }
        if (-not $summary.hostEffectivelyIdle) { $failures.Add("host idle CPU exceeds $HostIdleCpuTargetPercent percent") }
        if (-not $summary.allWarmOpensExplorerIoCountersQuiet) { $failures.Add('Explorer process read/write I/O counters changed during one or more warm opens') }
        if ($failures.Count) { throw "A4S performance gate failed: $($failures -join '; '). Evidence was preserved at $resolvedOutput" }
    }
}
finally {
    try {
        if ($automationMenuExpectedVisible) {
            $leftVisible = @([A4SPerformanceNative]::VisibleMenuWindows($explorerProcessId))
            if ($leftVisible.Count -eq 1 -and [IntPtr]$leftVisible[0] -eq $automationMenuWindow) {
            [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
                -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
                -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
            [A4SPerformanceNative]::Toggle($hostWindow, 2500)
            [void](Wait-MenuVisibility -Visible $false -TimeoutMilliseconds $TransitionTimeoutMilliseconds -OwnerProcessId $explorerProcessId)
                $automationMenuExpectedVisible = $false
            } elseif ($leftVisible.Count -eq 1) {
                throw 'Cleanup found one visible menu, but it was not the exact window opened by this probe; refusing a stale toggle.'
            } elseif ($leftVisible.Count -gt 1) {
                throw "Cleanup found $($leftVisible.Count) visible menu windows and refused an ambiguous toggle."
            }
        }
    } catch {
        Write-Warning "Could not confirm menu cleanup after the probe: $($_.Exception.Message)"
    }
    $residentHostProcess.Dispose()
    $explorerProcess.Dispose()
}
} finally {
    Exit-A4SQualificationAutomationLock -Mutex $qualificationAutomationMutex
}
