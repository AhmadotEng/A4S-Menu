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
    [string] $BaselinePath,
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
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string deviceName, int modeNumber, ref DEVMODE mode);

    [DllImport("dwmapi.dll")]
    public static extern int DwmFlush();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessIoCounters(IntPtr process, out IO_COUNTERS counters);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

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

    public static IntPtr[] VisibleMenuWindows()
    {
        List<IntPtr> matches = new List<IntPtr>();
        if (!EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window)) return true;
            StringBuilder name = new StringBuilder(256);
            if (GetClassNameW(window, name, name.Capacity) > 0 &&
                String.Equals(name.ToString(), "A4SMenu.CMenuContainer", StringComparison.Ordinal))
                matches.Add(window);
            return true;
        }, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
        return matches.ToArray();
    }

    public static RECT WindowRect(IntPtr window)
    {
        RECT rect;
        if (!GetWindowRect(window, out rect))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowRect failed");
        return rect;
    }

    public static uint RefreshRate(IntPtr window)
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
        return mode.DisplayFrequency;
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
        [Parameter(Mandatory)][int] $TimeoutMilliseconds
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $windows = @([A4SPerformanceNative]::VisibleMenuWindows())
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

function Save-WindowCapture {
    param([Parameter(Mandatory)][IntPtr] $Window, [Parameter(Mandatory)][string] $Path)
    Add-Type -AssemblyName System.Drawing
    $rect = [A4SPerformanceNative]::WindowRect($Window)
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { throw 'The visible menu has an invalid capture rectangle.' }
    $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy) }
        finally { $graphics.Dispose() }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stageDirectory = Join-Path $repoRoot 'build\stage\A4SProduct'
$expectedDll = [IO.Path]::GetFullPath((Join-Path $stageDirectory 'A4SMenu.dll'))
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
$mappedDlls = @($explorerProcess.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' } | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) })
if ($mappedDlls.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals($mappedDlls[0], $expectedDll)) {
    throw "Expected exactly one staged A4SMenu.dll mapping in Explorer PID $explorerProcessId; found '$($mappedDlls -join '; ')'."
}

$visibleBefore = @([A4SPerformanceNative]::VisibleMenuWindows())
if ($visibleBefore.Count -ne 0) {
    throw 'Close the A4S menu before starting the performance probe. The tool will not guess the current menu state.'
}

if (-not $OutputPath) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $OutputPath = Join-Path $repoRoot "build\test-results\A4S-performance-$stamp.json"
}
$resolvedOutput = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$baselineComparison = $null
if ($BaselinePath) {
    $resolvedBaseline = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BaselinePath))
    $baseline = Get-Content -LiteralPath $resolvedBaseline -Raw | ConvertFrom-Json
    if ($baseline.explorer.pid -ne $explorerProcessId) { throw "Baseline Explorer PID $($baseline.explorer.pid) does not match current PID $explorerProcessId." }
    if (@($baseline.product.mappedDllPaths).Count -ne 0 -or $baseline.product.residentHost) { throw 'The baseline was not captured in a clean pre-injection state.' }
    $currentMetrics = Get-ProcessMetrics -Process $explorerProcess
    $baselineComparison = [ordered]@{
        source = $resolvedBaseline
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

try {
    for ($index = 0; $index -lt $WarmSamples; $index++) {
        if ($SettleMilliseconds) { Start-Sleep -Milliseconds $SettleMilliseconds }
        $ioBefore = [A4SPerformanceNative]::ProcessIo($explorerProcessId)
        $openTimer = [Diagnostics.Stopwatch]::StartNew()
        [A4SPerformanceNative]::Toggle($hostWindow, 2500)
        $visible = Wait-MenuVisibility -Visible $true -TimeoutMilliseconds $TransitionTimeoutMilliseconds
        $visibilityMilliseconds = $openTimer.Elapsed.TotalMilliseconds
        [void][A4SPerformanceNative]::DwmFlush()
        $presentMilliseconds = $openTimer.Elapsed.TotalMilliseconds
        $menuWindow = [IntPtr]$visible.windows[0]
        if (-not $refreshRate) { $refreshRate = [A4SPerformanceNative]::RefreshRate($menuWindow) }
        $ioAfter = [A4SPerformanceNative]::ProcessIo($explorerProcessId)

        if ($CapturePopInEvidence -and $index -eq 0) {
            $firstCapturePath = Join-Path $outputDirectory 'A4S-popin-first-visible.png'
            $settledCapturePath = Join-Path $outputDirectory 'A4S-popin-settled.png'
            Save-WindowCapture -Window $menuWindow -Path $firstCapturePath
            if ($SettleMilliseconds) { Start-Sleep -Milliseconds $SettleMilliseconds }
            [void][A4SPerformanceNative]::DwmFlush()
            Save-WindowCapture -Window $menuWindow -Path $settledCapturePath
            $firstCaptureHash = (Get-FileHash -LiteralPath $firstCapturePath -Algorithm SHA256).Hash
            $settledCaptureHash = (Get-FileHash -LiteralPath $settledCapturePath -Algorithm SHA256).Hash
        }

        $closeTimer = [Diagnostics.Stopwatch]::StartNew()
        [A4SPerformanceNative]::Toggle($hostWindow, 2500)
        [void](Wait-MenuVisibility -Visible $false -TimeoutMilliseconds $TransitionTimeoutMilliseconds)
        [void][A4SPerformanceNative]::DwmFlush()
        $closeMilliseconds = $closeTimer.Elapsed.TotalMilliseconds

        $samples.Add([ordered]@{
            index = $index + 1
            classification = if ($index -eq 0 -and $OperatorAttestsFirstOpenIsCold) { 'operator-attested-first-open' } else { 'warm' }
            openVisibleMilliseconds = [Math]::Round($visibilityMilliseconds, 3)
            openPresentedMilliseconds = [Math]::Round($presentMilliseconds, 3)
            closePresentedMilliseconds = [Math]::Round($closeMilliseconds, 3)
            explorerIoDuringOpen = Get-IoDelta -Before $ioBefore -After $ioAfter
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

    $warm = @($samples | Where-Object classification -eq 'warm')
    $openValues = [double[]]@($warm | ForEach-Object { $_.openPresentedMilliseconds })
    $closeValues = [double[]]@($samples | ForEach-Object { $_.closePresentedMilliseconds })
    $frameMilliseconds = if ($refreshRate -gt 0) { 1000.0 / $refreshRate } else { $null }
    $diskQuietSamples = @($warm | Where-Object {
        $_.explorerIoDuringOpen.readOperations -eq 0 -and
        $_.explorerIoDuringOpen.writeOperations -eq 0 -and
        $_.explorerIoDuringOpen.readBytes -eq 0 -and
        $_.explorerIoDuringOpen.writeBytes -eq 0
    }).Count

    $summary = [ordered]@{
        warmOpenP50Milliseconds = [Math]::Round((Get-Percentile $openValues 0.50), 3)
        warmOpenP95Milliseconds = [Math]::Round((Get-Percentile $openValues 0.95), 3)
        warmOpenMaximumMilliseconds = [Math]::Round((($openValues | Measure-Object -Maximum).Maximum), 3)
        closeP50Milliseconds = [Math]::Round((Get-Percentile $closeValues 0.50), 3)
        closeP95Milliseconds = [Math]::Round((Get-Percentile $closeValues 0.95), 3)
        closeMaximumMilliseconds = [Math]::Round((($closeValues | Measure-Object -Maximum).Maximum), 3)
        refreshRateHz = $refreshRate
        displayFrameMilliseconds = if ($frameMilliseconds) { [Math]::Round($frameMilliseconds, 3) } else { $null }
        warmOpenAtOrBelowTarget = (Get-Percentile $openValues 0.95) -le $WarmOpenTargetMilliseconds
        closeWithinOneFrame = if ($frameMilliseconds) { (Get-Percentile $closeValues 0.95) -le $frameMilliseconds } else { $null }
        warmOpenDiskQuietSamples = $diskQuietSamples
        warmOpenDiskQuietTotal = $warm.Count
        allWarmOpensProcessIoQuiet = $diskQuietSamples -eq $warm.Count
        hostIdleCpuPercent = [Math]::Round($hostIdlePercent, 6)
        explorerProcessIdleCpuPercent = [Math]::Round($explorerIdlePercent, 6)
        hostEffectivelyIdle = $hostIdlePercent -le $HostIdleCpuTargetPercent
    }

    $result = [ordered]@{
        schemaVersion = 1
        capturedUtc = [DateTime]::UtcNow.ToString('o')
        measurementScope = [ordered]@{
            commandPath = 'resident-host SendMessageTimeout to first visible menu plus DwmFlush'
            explorerIo = 'process-wide; background Explorer activity can create false positives'
            explorerCpu = 'process-wide; not attributable to A4S without ETW markers'
            coldClassification = if ($OperatorAttestsFirstOpenIsCold) { 'operator attestation only' } else { 'not measured' }
        }
        processes = [ordered]@{ hostPid = $residentHostProcessId; explorerPid = $explorerProcessId; mappedDll = $mappedDlls[0] }
        targets = [ordered]@{ warmOpenMilliseconds = $WarmOpenTargetMilliseconds; closeFrames = 1; hostIdleCpuPercent = $HostIdleCpuTargetPercent; warmOpenDiskBytes = 0 }
        baselineComparison = $baselineComparison
        summary = $summary
        popInEvidence = if ($CapturePopInEvidence) { [ordered]@{
            firstVisiblePath = $firstCapturePath
            settledPath = $settledCapturePath
            firstVisibleSha256 = $firstCaptureHash
            settledSha256 = $settledCaptureHash
            pixelStableByExactPngHash = $firstCaptureHash -eq $settledCaptureHash
            qualification = 'Different hashes are inconclusive because acrylic/background/cursor changes also alter pixels; visually compare both images.'
        } } else { $null }
        samples = $samples
    }

    $json = $result | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote A4S performance evidence: $resolvedOutput"
    Write-Host ("Warm open p95={0:N3} ms; close p95={1:N3} ms; host idle CPU={2:N6}%; disk-quiet warm opens={3}/{4}" -f
        $summary.warmOpenP95Milliseconds, $summary.closeP95Milliseconds, $summary.hostIdleCpuPercent,
        $summary.warmOpenDiskQuietSamples, $summary.warmOpenDiskQuietTotal)

    if ($EnforceTargets) {
        $failures = [Collections.Generic.List[string]]::new()
        if (-not $summary.warmOpenAtOrBelowTarget) { $failures.Add("warm-open p95 exceeds $WarmOpenTargetMilliseconds ms") }
        if ($null -eq $summary.closeWithinOneFrame) { $failures.Add('display refresh rate was unavailable, so one-frame close could not be proved') }
        elseif (-not $summary.closeWithinOneFrame) { $failures.Add('close p95 exceeds one display frame') }
        if (-not $summary.hostEffectivelyIdle) { $failures.Add("host idle CPU exceeds $HostIdleCpuTargetPercent percent") }
        if (-not $summary.allWarmOpensProcessIoQuiet) { $failures.Add('Explorer process I/O changed during one or more warm opens') }
        if ($failures.Count) { throw "A4S performance gate failed: $($failures -join '; '). Evidence was preserved at $resolvedOutput" }
    }
}
finally {
    $residentHostProcess.Dispose()
    $explorerProcess.Dispose()
}
