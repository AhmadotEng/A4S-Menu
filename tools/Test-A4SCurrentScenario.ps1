[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string] $ScenarioName,
    [string] $MatrixPath,
    [ValidateSet('left', 'center')]
    [string] $ExpectedTaskbarAlignment,
    [ValidateSet('left', 'right', 'top', 'bottom')]
    [string] $ExpectedTaskbarEdge,
    [ValidateRange(1, 16)]
    [int] $ExpectedMonitorCount,
    [ValidateSet(100, 125, 150, 175, 200, 225, 250, 300, 350)]
    [int] $ExpectedPrimaryScalePercent,
    [ValidateSet('fullscreen', 'windowed')]
    [string] $ExpectedForegroundMode,
    [ValidateSet('absent', 'resident')]
    [string] $ExpectedHostPresence,
    [ValidateRange(0, 65535)]
    [int] $ExpectedSessionId,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string] $CompareWithScenario,
    [ValidateSet('same', 'changed')]
    [string] $ExpectedExplorerRelationship,
    [ValidateSet('same', 'changed')]
    [string] $ExpectedSessionRelationship,
    [switch] $AllowMenuAutomation,
    [string] $ExpectedMenuMonitor,
    [ValidateSet(100, 125, 150, 175, 200, 225, 250, 300, 350)]
    [int] $ExpectedMenuScalePercent,
    [switch] $ObserveManualFocusDismissal,
    [ValidateRange(2, 60)]
    [int] $DismissalTimeoutSeconds = 15,
    [string] $Notes
)

$ErrorActionPreference = 'Stop'

if ($ObserveManualFocusDismissal -and -not $AllowMenuAutomation) {
    throw '-ObserveManualFocusDismissal also requires -AllowMenuAutomation because the tool must open the menu first.'
}
if (($ExpectedExplorerRelationship -or $ExpectedSessionRelationship) -and -not $CompareWithScenario) {
    throw '-ExpectedExplorerRelationship and -ExpectedSessionRelationship require -CompareWithScenario.'
}
if (($ExpectedMenuMonitor -or $PSBoundParameters.ContainsKey('ExpectedMenuScalePercent')) -and -not $AllowMenuAutomation) {
    throw 'Menu-monitor and menu-scale assertions require -AllowMenuAutomation.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run this scenario probe from 64-bit PowerShell.'
}

if (-not ('A4SScenarioNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class A4SScenarioNative
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public uint Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    }

    public sealed class WindowRecord
    {
        public long Handle;
        public int Left;
        public int Top;
        public int Width;
        public int Height;
        public string Monitor;
        public int MonitorLeft;
        public int MonitorTop;
        public int MonitorWidth;
        public int MonitorHeight;
        public uint Dpi;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindowW(string className, string windowName);

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

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    [DllImport("dwmapi.dll")]
    public static extern int DwmFlush();

    public static IntPtr HostWindow()
    {
        return FindWindowW("A4SMenu.Host.Window.v1", "A4SMenuHost");
    }

    public static uint HostStatus(IntPtr hostWindow)
    {
        return HostControl(hostWindow, 4, false);
    }

    public static void Toggle(IntPtr hostWindow)
    {
        HostControl(hostWindow, 1, true);
    }

    private static uint HostControl(IntPtr hostWindow, uint command, bool requireTrue)
    {
        uint message = RegisterWindowMessageW("A4SMenu.Host.Control.v1");
        if (message == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterWindowMessage failed");
        UIntPtr result;
        if (SendMessageTimeoutW(hostWindow, message, new UIntPtr(command), IntPtr.Zero,
            0x0002 | 0x0001, 2500, out result) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "A4S host command failed");
        uint value = unchecked((uint)result.ToUInt64());
        if (requireTrue && value == 0)
            throw new InvalidOperationException("The A4S host rejected the command.");
        return value;
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

    public static WindowRecord Describe(IntPtr window)
    {
        RECT rect;
        if (!GetWindowRect(window, out rect))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowRect failed");
        IntPtr monitor = MonitorFromWindow(window, 2);
        MONITORINFOEX info = new MONITORINFOEX();
        info.Size = (uint)Marshal.SizeOf(typeof(MONITORINFOEX));
        if (monitor == IntPtr.Zero || !GetMonitorInfoW(monitor, ref info))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetMonitorInfo failed");
        uint dpi = 96;
        try { dpi = GetDpiForWindow(window); }
        catch (EntryPointNotFoundException) { }
        return new WindowRecord {
            Handle = window.ToInt64(),
            Left = rect.Left,
            Top = rect.Top,
            Width = rect.Right - rect.Left,
            Height = rect.Bottom - rect.Top,
            Monitor = info.DeviceName,
            MonitorLeft = info.Monitor.Left,
            MonitorTop = info.Monitor.Top,
            MonitorWidth = info.Monitor.Right - info.Monitor.Left,
            MonitorHeight = info.Monitor.Bottom - info.Monitor.Top,
            Dpi = dpi
        };
    }
}
'@
}

function Wait-MenuState {
    param([bool] $Visible, [int] $TimeoutMilliseconds = 5000)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $windows = @([A4SScenarioNative]::VisibleMenuWindows())
        if (($Visible -and $windows.Count -gt 0) -or (-not $Visible -and $windows.Count -eq 0)) {
            return $windows
        }
        [Threading.Thread]::Sleep(10)
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw "The menu did not become $(if($Visible){'visible'}else{'hidden'}) within $TimeoutMilliseconds ms."
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $MatrixPath) { $MatrixPath = Join-Path $repoRoot 'build\test-results\A4S-stability-matrix.json' }
$resolvedMatrix = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MatrixPath))
$matrix = [ordered]@{ schemaVersion = 1; entries = @() }
if (Test-Path -LiteralPath $resolvedMatrix -PathType Leaf) {
    $existing = Get-Content -LiteralPath $resolvedMatrix -Raw | ConvertFrom-Json
    if ($existing.schemaVersion -ne 1) { throw "Unsupported stability-matrix schema in $resolvedMatrix." }
    $matrix.entries = @($existing.entries)
}
$comparisonEntry = $null
if ($CompareWithScenario) {
    $comparisonEntry = @($matrix.entries | Where-Object scenario -eq $CompareWithScenario | Select-Object -Last 1)
    if ($comparisonEntry.Count -ne 1) { throw "Scenario '$CompareWithScenario' was not found in $resolvedMatrix." }
    $comparisonEntry = $comparisonEntry[0]
}

$snapshotJson = & (Join-Path $PSScriptRoot 'Get-A4SPerformanceSnapshot.ps1')
$snapshot = $snapshotJson | ConvertFrom-Json
$assertions = [Collections.Generic.List[object]]::new()

function Add-Assertion {
    param([string] $Name, [object] $Expected, [object] $Actual, [bool] $Passed)
    $assertions.Add([ordered]@{ name = $Name; expected = $Expected; actual = $Actual; passed = $Passed })
}

if ($PSBoundParameters.ContainsKey('ExpectedMonitorCount')) {
    Add-Assertion 'monitor-count' $ExpectedMonitorCount @($snapshot.desktop.monitors).Count (@($snapshot.desktop.monitors).Count -eq $ExpectedMonitorCount)
}
if ($ExpectedTaskbarAlignment) {
    Add-Assertion 'taskbar-alignment' $ExpectedTaskbarAlignment $snapshot.desktop.taskbar.alignmentRegistryHint ($snapshot.desktop.taskbar.alignmentRegistryHint -eq $ExpectedTaskbarAlignment)
}
if ($ExpectedTaskbarEdge) {
    Add-Assertion 'taskbar-edge' $ExpectedTaskbarEdge $snapshot.desktop.taskbar.edge ($snapshot.desktop.taskbar.edge -eq $ExpectedTaskbarEdge)
}
if ($PSBoundParameters.ContainsKey('ExpectedPrimaryScalePercent')) {
    $primaryMonitor = @($snapshot.desktop.monitors | Where-Object primary)[0]
    Add-Assertion 'primary-scale-percent' $ExpectedPrimaryScalePercent $primaryMonitor.scalePercent ([Math]::Abs([double]$primaryMonitor.scalePercent - $ExpectedPrimaryScalePercent) -lt 0.01)
}
if ($ExpectedForegroundMode) {
    $actualForegroundMode = if ($snapshot.desktop.foreground.coversMonitorBounds) { 'fullscreen' } else { 'windowed' }
    Add-Assertion 'foreground-mode' $ExpectedForegroundMode $actualForegroundMode ($actualForegroundMode -eq $ExpectedForegroundMode)
}
if ($ExpectedHostPresence) {
    $actualHostPresence = if ($snapshot.product.residentHost) { 'resident' } else { 'absent' }
    Add-Assertion 'host-presence' $ExpectedHostPresence $actualHostPresence ($actualHostPresence -eq $ExpectedHostPresence)
}
if ($PSBoundParameters.ContainsKey('ExpectedSessionId')) {
    Add-Assertion 'explorer-session-id' $ExpectedSessionId $snapshot.explorer.sessionId ($snapshot.explorer.sessionId -eq $ExpectedSessionId)
}
if ($ExpectedExplorerRelationship) {
    $actualExplorerRelationship = if ($snapshot.explorer.pid -eq $comparisonEntry.environment.explorer.pid) { 'same' } else { 'changed' }
    Add-Assertion 'explorer-pid-relationship' $ExpectedExplorerRelationship $actualExplorerRelationship ($actualExplorerRelationship -eq $ExpectedExplorerRelationship)
}
if ($ExpectedSessionRelationship) {
    $actualSessionRelationship = if ($snapshot.explorer.sessionId -eq $comparisonEntry.environment.explorer.sessionId) { 'same' } else { 'changed' }
    Add-Assertion 'session-id-relationship' $ExpectedSessionRelationship $actualSessionRelationship ($actualSessionRelationship -eq $ExpectedSessionRelationship)
}

$automation = $null
if ($AllowMenuAutomation) {
    $hostWindow = [A4SScenarioNative]::HostWindow()
    if ($hostWindow -eq [IntPtr]::Zero) { throw 'No resident A4SMenuHost was found. The scenario tool never starts or injects it.' }
    if ([A4SScenarioNative]::HostStatus($hostWindow) -ne 3) { throw 'A4SMenuHost is not READY.' }
    if (@([A4SScenarioNative]::VisibleMenuWindows()).Count -ne 0) { throw 'Close the menu before running scenario automation.' }

    [A4SScenarioNative]::Toggle($hostWindow)
    $visibleWindows = @(Wait-MenuState -Visible $true)
    [void][A4SScenarioNative]::DwmFlush()
    $menu = [A4SScenarioNative]::Describe([IntPtr]$visibleWindows[0])
    $dismissedManually = $false
    if ($ObserveManualFocusDismissal) {
        Write-Host "A4S menu is open. Focus another application within $DismissalTimeoutSeconds seconds; this tool will only observe whether the menu dismisses."
        try {
            [void](Wait-MenuState -Visible $false -TimeoutMilliseconds ($DismissalTimeoutSeconds * 1000))
            $dismissedManually = $true
        } catch {
            if (@([A4SScenarioNative]::VisibleMenuWindows()).Count -gt 0) {
                [A4SScenarioNative]::Toggle($hostWindow)
                [void](Wait-MenuState -Visible $false)
            }
            throw
        }
    } else {
        [A4SScenarioNative]::Toggle($hostWindow)
        [void](Wait-MenuState -Visible $false)
    }
    $automation = [ordered]@{
        openClosePassed = $true
        manualFocusDismissalRequested = [bool]$ObserveManualFocusDismissal
        manualFocusDismissalPassed = if ($ObserveManualFocusDismissal) { $dismissedManually } else { $null }
        menuWindow = [ordered]@{
            hwnd = ('0x{0:X}' -f $menu.Handle)
            rect = [ordered]@{ left = $menu.Left; top = $menu.Top; width = $menu.Width; height = $menu.Height }
            monitor = $menu.Monitor
            monitorBounds = [ordered]@{ left = $menu.MonitorLeft; top = $menu.MonitorTop; width = $menu.MonitorWidth; height = $menu.MonitorHeight }
            dpi = $menu.Dpi
            scalePercent = [Math]::Round($menu.Dpi * 100.0 / 96.0, 2)
        }
    }
    if ($ExpectedMenuMonitor) {
        Add-Assertion 'menu-monitor' $ExpectedMenuMonitor $menu.Monitor ([StringComparer]::OrdinalIgnoreCase.Equals($ExpectedMenuMonitor, $menu.Monitor))
    }
    if ($PSBoundParameters.ContainsKey('ExpectedMenuScalePercent')) {
        $actualMenuScale = [Math]::Round($menu.Dpi * 100.0 / 96.0, 2)
        Add-Assertion 'menu-scale-percent' $ExpectedMenuScalePercent $actualMenuScale ([Math]::Abs($actualMenuScale - $ExpectedMenuScalePercent) -lt 0.01)
    }
}

$entry = [ordered]@{
    scenario = $ScenarioName
    capturedUtc = [DateTime]::UtcNow.ToString('o')
    notes = $Notes
    assertions = $assertions
    assertionsPassed = @($assertions | Where-Object { -not $_.passed }).Count -eq 0
    environment = $snapshot
    automation = $automation
}

$matrix.entries += $entry
$matrixDirectory = Split-Path -Parent $resolvedMatrix
if (-not (Test-Path -LiteralPath $matrixDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $matrixDirectory -Force | Out-Null
}
[IO.File]::WriteAllText($resolvedMatrix, (($matrix | ConvertTo-Json -Depth 15) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

Write-Host "Recorded A4S scenario '$ScenarioName': $resolvedMatrix"
if (-not $entry.assertionsPassed) {
    $failed = @($assertions | Where-Object { -not $_.passed } | ForEach-Object { "$($_.name): expected '$($_.expected)', actual '$($_.actual)'" })
    throw "Scenario environment assertions failed: $($failed -join '; '). Evidence was preserved."
}
