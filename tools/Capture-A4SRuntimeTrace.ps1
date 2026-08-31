[CmdletBinding()]
param(
    [switch]$AllowMenuAutomation,
    [ValidateRange(1, 500)]
    [int]$CapturedCycles = 20,
    [ValidateRange(0, 20)]
    [int]$WarmupCycles = 1,
    [switch]$OperatorAttestsFirstCapturedCycleIsCold,
    [ValidateRange(500, 10000)]
    [int]$TransitionTimeoutMilliseconds = 3000,
    [ValidateRange(0, 2000)]
    [int]$VisibleSettleMilliseconds = 75,
    [ValidateRange(0, 2000)]
    [int]$HiddenSettleMilliseconds = 25,
    [ValidateRange(1, 250)]
    [double]$WarmOpenTargetMilliseconds = 50,
    [ValidateRange(0, 1000)]
    [double]$RefreshRateHz = 0,
    [string]$ProductDirectory,
    [string]$OutputDirectory,
    [switch]$EnforceTargets
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $AllowMenuAutomation) {
    throw @'
This tool visibly opens and closes an already-running A4S menu and creates a
custom-provider ETW session. It never starts the host, injects Explorer, or
restarts Explorer. Re-run explicitly with -AllowMenuAutomation only after the
exact staged resident host reports READY.
'@
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run this tool from 64-bit PowerShell so Explorer module validation is authoritative.'
}
if ($OperatorAttestsFirstCapturedCycleIsCold -and $WarmupCycles -ne 0) {
    throw '-OperatorAttestsFirstCapturedCycleIsCold requires -WarmupCycles 0.'
}

if (-not ('A4SRuntimeTraceNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class A4SRuntimeTraceNative
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public uint Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public ushort SpecVersion, DriverVersion, Size, DriverExtra;
        public uint Fields;
        public int PositionX, PositionY;
        public uint DisplayOrientation, DisplayFixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public ushort LogPixels;
        public uint BitsPerPel, PelsWidth, PelsHeight, DisplayFlags, DisplayFrequency;
        public uint IcmMethod, IcmIntent, MediaType, DitherType, Reserved1, Reserved2;
        public uint PanningWidth, PanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowW(string className, string windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessageW(string message);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, UIntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out UIntPtr result);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr window, StringBuilder className, int count);

    [DllImport("dwmapi.dll")]
    private static extern int DwmFlush();

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string deviceName, int modeNumber, ref DEVMODE mode);

    public static IntPtr HostWindow()
    {
        return FindWindowW("A4SMenu.Host.Window.v1", "A4SMenuHost");
    }

    private static UIntPtr SendHostControl(IntPtr hostWindow, uint command, uint timeoutMilliseconds)
    {
        uint message = RegisterWindowMessageW("A4SMenu.Host.Control.v1");
        if (message == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterWindowMessage failed");
        UIntPtr result;
        if (SendMessageTimeoutW(hostWindow, message, new UIntPtr(command), IntPtr.Zero,
            0x0002 | 0x0001, timeoutMilliseconds, out result) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "A4S host control request failed");
        return result;
    }

    public static uint HostStatus(IntPtr hostWindow, uint timeoutMilliseconds)
    {
        return unchecked((uint)SendHostControl(hostWindow, 4, timeoutMilliseconds).ToUInt64());
    }

    public static void Toggle(IntPtr hostWindow, uint timeoutMilliseconds)
    {
        if (SendHostControl(hostWindow, 1, timeoutMilliseconds) == UIntPtr.Zero)
            throw new InvalidOperationException("The READY A4S host rejected the toggle request.");
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
                if (ownerProcessId == 0 || processId == ownerProcessId) matches.Add(window);
            }
            return true;
        }, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
        return matches.ToArray();
    }

    public static void FlushDwm()
    {
        int result = DwmFlush();
        if (result < 0) Marshal.ThrowExceptionForHR(result);
    }

    public static uint NominalRefreshRate(IntPtr window)
    {
        IntPtr monitor = MonitorFromWindow(window, 2);
        MONITORINFOEX info = new MONITORINFOEX();
        info.Size = (uint)Marshal.SizeOf(typeof(MONITORINFOEX));
        if (monitor == IntPtr.Zero || !GetMonitorInfoW(monitor, ref info)) return 0;
        DEVMODE mode = new DEVMODE();
        mode.Size = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettingsW(info.DeviceName, -1, ref mode)) return 0;
        return mode.DisplayFrequency >= 20 && mode.DisplayFrequency <= 1000 ? mode.DisplayFrequency : 0;
    }
}
'@
}

function Resolve-A4SUnresolvedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Wait-A4SMenuVisibility {
    param(
        [Parameter(Mandatory)][bool]$Visible,
        [Parameter(Mandatory)][uint32]$ExplorerProcessId,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $windows = @([A4SRuntimeTraceNative]::VisibleMenuWindows($ExplorerProcessId))
        if ($Visible -and $windows.Count -gt 1) { throw "Found $($windows.Count) visible A4S menu windows; expected exactly one." }
        if (($Visible -and $windows.Count -eq 1) -or (-not $Visible -and $windows.Count -eq 0)) { return $windows }
        [Threading.Thread]::Sleep(1)
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw "A4S menu did not become $(if ($Visible) { 'visible' } else { 'hidden' }) within $TimeoutMilliseconds ms."
}

function Invoke-A4SToggleCycle {
    param(
        [Parameter(Mandatory)][IntPtr]$HostWindow,
        [Parameter(Mandatory)][uint32]$ExplorerProcessId
    )
    if ([A4SRuntimeTraceNative]::HostStatus($HostWindow, 2500) -ne 3) { throw 'A4SMenuHost left READY before a toggle cycle.' }
    $currentTaskbar = [A4SRuntimeTraceNative]::FindWindowW('Shell_TrayWnd', $null)
    [uint32]$currentExplorerProcessId = 0
    if ($currentTaskbar -eq [IntPtr]::Zero) { throw 'Explorer taskbar disappeared before a toggle cycle.' }
    [void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($currentTaskbar, [ref]$currentExplorerProcessId)
    if ($currentExplorerProcessId -ne $ExplorerProcessId) { throw "Explorer changed from PID $ExplorerProcessId to PID $currentExplorerProcessId during capture." }
    [A4SRuntimeTraceNative]::Toggle($HostWindow, 2500)
    $windows = @(Wait-A4SMenuVisibility -Visible $true -ExplorerProcessId $ExplorerProcessId -TimeoutMilliseconds $TransitionTimeoutMilliseconds)
    [uint32]$visibleOwnerProcessId = 0
    [void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($windows[0], [ref]$visibleOwnerProcessId)
    if ($visibleOwnerProcessId -ne $ExplorerProcessId) { throw "The visible A4S menu belongs to PID $visibleOwnerProcessId, not validated Explorer PID $ExplorerProcessId." }
    [A4SRuntimeTraceNative]::FlushDwm()
    if ($VisibleSettleMilliseconds -gt 0) { [Threading.Thread]::Sleep($VisibleSettleMilliseconds) }
    [A4SRuntimeTraceNative]::Toggle($HostWindow, 2500)
    [void](Wait-A4SMenuVisibility -Visible $false -ExplorerProcessId $ExplorerProcessId -TimeoutMilliseconds $TransitionTimeoutMilliseconds)
    [A4SRuntimeTraceNative]::FlushDwm()
    if ($HiddenSettleMilliseconds -gt 0) { [Threading.Thread]::Sleep($HiddenSettleMilliseconds) }
    return $windows[0]
}

function Invoke-A4SLogman {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $logman = Join-Path $env:SystemRoot 'System32\logman.exe'
    if (-not (Test-Path -LiteralPath $logman -PathType Leaf)) { throw "Windows logman.exe was not found at '$logman'." }
    $output = @(& $logman @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ exitCode = $exitCode; output = @($output | ForEach-Object { [string]$_ }) }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ProductDirectory) { $ProductDirectory = Join-Path $repoRoot 'build\stage\A4SProduct' }
$resolvedProductDirectory = Resolve-A4SUnresolvedPath $ProductDirectory
$expectedHost = [IO.Path]::GetFullPath((Join-Path $resolvedProductDirectory 'A4SMenuHost.exe'))
$expectedDll = [IO.Path]::GetFullPath((Join-Path $resolvedProductDirectory 'A4SMenu.dll'))
foreach ($requiredFile in @($expectedHost, $expectedDll)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required staged product binary is missing: '$requiredFile'." }
}

$hostWindow = [A4SRuntimeTraceNative]::HostWindow()
if ($hostWindow -eq [IntPtr]::Zero) { throw 'No resident A4SMenuHost window was found. This tool never starts or injects it.' }
if ([A4SRuntimeTraceNative]::HostStatus($hostWindow, 2500) -ne 3) { throw 'The resident A4SMenuHost is not READY.' }
[uint32]$residentHostProcessId = 0
[void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($hostWindow, [ref]$residentHostProcessId)
$taskbar = [A4SRuntimeTraceNative]::FindWindowW('Shell_TrayWnd', $null)
if ($taskbar -eq [IntPtr]::Zero) { throw 'Explorer taskbar window Shell_TrayWnd was not found.' }
[uint32]$explorerProcessId = 0
[void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($taskbar, [ref]$explorerProcessId)
if ($residentHostProcessId -eq 0 -or $explorerProcessId -eq 0) { throw 'Could not resolve the resident host or taskbar Explorer process.' }

$residentHost = [Diagnostics.Process]::GetProcessById([int]$residentHostProcessId)
$explorer = [Diagnostics.Process]::GetProcessById([int]$explorerProcessId)
$observerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($residentHost.SessionId -ne $observerSessionId -or $explorer.SessionId -ne $observerSessionId) {
    throw "Observer, resident host, and Explorer must share the interactive session. observer=$observerSessionId host=$($residentHost.SessionId) explorer=$($explorer.SessionId)."
}
$actualHost = [IO.Path]::GetFullPath($residentHost.MainModule.FileName)
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualHost, $expectedHost)) {
    throw "The resident host is not the exact staged host. Expected '$expectedHost'; found '$actualHost'."
}
$mappedDlls = @($explorer.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' } | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) })
if ($mappedDlls.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals($mappedDlls[0], $expectedDll)) {
    throw "Expected exactly one staged A4SMenu.dll mapping in Explorer PID $explorerProcessId; found '$($mappedDlls -join '; ')'."
}
if (@([A4SRuntimeTraceNative]::VisibleMenuWindows($explorerProcessId)).Count -ne 0) {
    throw 'Close the A4S menu before capture. The tool refuses to guess or alter the initial state.'
}

if ($RefreshRateHz -eq 0) {
    $RefreshRateHz = [A4SRuntimeTraceNative]::NominalRefreshRate($taskbar)
    if ($RefreshRateHz -eq 0) { throw 'Could not determine the active display refresh rate; pass -RefreshRateHz explicitly.' }
}
if (-not $OutputDirectory) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $OutputDirectory = Join-Path $repoRoot "build\test-results\A4S-runtime-trace-$stamp-$PID"
}
$resolvedOutputDirectory = Resolve-A4SUnresolvedPath $OutputDirectory
if (Test-Path -LiteralPath $resolvedOutputDirectory) { throw "Output directory already exists: '$resolvedOutputDirectory'. Choose a new path so no raw trace can be overwritten." }
New-Item -ItemType Directory -Path $resolvedOutputDirectory | Out-Null
$etlPath = Join-Path $resolvedOutputDirectory 'A4SMenu.Runtime.etl'
$reportPath = Join-Path $resolvedOutputDirectory 'A4SMenu.Runtime.json'
$sessionName = "A4SRuntime-$PID-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$sessionStarted = $false
$captureError = $null
$cleanupError = $null
$stopError = $null
$startedUtc = $null
$stoppedUtc = $null
$completedCycles = 0

try {
    for ($warmup = 0; $warmup -lt $WarmupCycles; $warmup++) {
        [void](Invoke-A4SToggleCycle -HostWindow $hostWindow -ExplorerProcessId $explorerProcessId)
    }
    if ([A4SRuntimeTraceNative]::HostStatus($hostWindow, 2500) -ne 3) { throw 'A4SMenuHost left READY during warm-up.' }
    $startArguments = @(
        'create', 'trace', $sessionName,
        '-ow', '-o', $etlPath,
        '-f', 'bin', '-ct', 'perf', '-bs', '64', '-nb', '16', '128', '-ft', '1',
        '-p', '{74a9f986-c7ab-429a-9571-df0fb7f4a33c}', '0xffffffffffffffff', '5',
        '-rt', '-ets'
    )
    $startedUtc = [DateTimeOffset]::UtcNow
    $startResult = Invoke-A4SLogman -Arguments $startArguments
    $startResult.output | Set-Content -LiteralPath (Join-Path $resolvedOutputDirectory 'session-start.txt') -Encoding UTF8
    if ($startResult.exitCode -ne 0) {
        throw "logman could not start ETW session '$sessionName' (exit $($startResult.exitCode)): $($startResult.output -join ' ')"
    }
    $sessionStarted = $true
    for ($cycle = 0; $cycle -lt $CapturedCycles; $cycle++) {
        [void](Invoke-A4SToggleCycle -HostWindow $hostWindow -ExplorerProcessId $explorerProcessId)
        $completedCycles++
    }
} catch {
    $captureError = $_
} finally {
    try {
        $visible = @([A4SRuntimeTraceNative]::VisibleMenuWindows(0))
        if ($visible.Count -eq 1 -and [A4SRuntimeTraceNative]::HostStatus($hostWindow, 2500) -eq 3) {
            [uint32]$cleanupOwnerProcessId = 0
            [void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($visible[0], [ref]$cleanupOwnerProcessId)
            [A4SRuntimeTraceNative]::Toggle($hostWindow, 2500)
            [void](Wait-A4SMenuVisibility -Visible $false -ExplorerProcessId $cleanupOwnerProcessId -TimeoutMilliseconds $TransitionTimeoutMilliseconds)
        } elseif ($visible.Count -eq 1) {
            throw 'One A4S menu window remains visible, but the resident host is not READY for an unambiguous cleanup toggle.'
        } elseif ($visible.Count -gt 1) {
            throw "Cleanup found $($visible.Count) A4S menu windows and refused an ambiguous toggle."
        }
    } catch { $cleanupError = $_ }
    if ($sessionStarted) {
        try {
            $stopResult = Invoke-A4SLogman -Arguments @('stop', $sessionName, '-ets')
            $stoppedUtc = [DateTimeOffset]::UtcNow
            $stopResult.output | Set-Content -LiteralPath (Join-Path $resolvedOutputDirectory 'session-stop.txt') -Encoding UTF8
            if ($stopResult.exitCode -ne 0) { throw "logman stop failed with exit code $($stopResult.exitCode): $($stopResult.output -join ' ')" }
        } catch { $stopError = $_ }
    }
}

if ($stopError) { throw "ETW session cleanup failed for '$sessionName'. Capture directory: '$resolvedOutputDirectory'. $($stopError.Exception.Message)" }
if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf) -or (Get-Item -LiteralPath $etlPath).Length -eq 0) {
    $reason = if ($captureError) { $captureError.Exception.Message } else { 'The ETW logger produced no file data.' }
    throw "No usable raw ETL was produced. Capture directory: '$resolvedOutputDirectory'. $reason"
}

$coldSampleCount = if ($OperatorAttestsFirstCapturedCycleIsCold) { 1 } else { 0 }
$conversionError = $null
try {
    $conversionArguments = @{
        EtlPath = $etlPath
        ExpectedProcessId = $explorerProcessId
        ColdSampleCount = $coldSampleCount
        WarmOpenTargetMilliseconds = $WarmOpenTargetMilliseconds
        RefreshRateHz = $RefreshRateHz
        OutputPath = $reportPath
    }
    if ($EnforceTargets) { $conversionArguments['EnforceTargets'] = $true }
    [void](& (Join-Path $PSScriptRoot 'Convert-A4SRuntimeTrace.ps1') @conversionArguments)
} catch { $conversionError = $_ }

if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $capture = [pscustomobject][ordered]@{
        sessionName = $sessionName
        providerMode = 'real-time plus sequential ETL file'
        startedUtc = if ($startedUtc) { $startedUtc.ToString('o') } else { $null }
        stoppedUtc = if ($stoppedUtc) { $stoppedUtc.ToString('o') } else { $null }
        requestedCycles = $CapturedCycles
        completedCycles = $completedCycles
        warmupCycles = $WarmupCycles
        explorerProcessId = $explorerProcessId
        residentHostProcessId = $residentHostProcessId
        productDirectory = $resolvedProductDirectory
        hostPath = $expectedHost
        hostSha256 = (Get-FileHash -LiteralPath $expectedHost -Algorithm SHA256).Hash
        dllPath = $expectedDll
        dllSha256 = (Get-FileHash -LiteralPath $expectedDll -Algorithm SHA256).Hash
        captureError = if ($captureError) { $captureError.Exception.Message } else { $null }
        cleanupError = if ($cleanupError) { $cleanupError.Exception.Message } else { $null }
    }
    $report | Add-Member -NotePropertyName capture -NotePropertyValue $capture -Force
    $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}

if ($conversionError) { throw "ETL parsing failed; raw ETL is preserved at '$etlPath'. $($conversionError.Exception.Message)" }
if ($captureError) { throw "Capture ended early after $completedCycles/$CapturedCycles cycles. Raw ETL and partial report are in '$resolvedOutputDirectory'. $($captureError.Exception.Message)" }
if ($cleanupError) { throw "Capture completed but final menu cleanup failed. Artifacts are in '$resolvedOutputDirectory'. $($cleanupError.Exception.Message)" }

Write-Output $reportPath
