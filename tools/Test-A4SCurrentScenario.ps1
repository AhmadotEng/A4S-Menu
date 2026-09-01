[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string] $ScenarioName,
    [string] $MatrixPath,
    [string] $ProductDirectory,
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
    [ValidateRange(0, 60)]
    [int] $ForegroundObservationDelaySeconds = 0,
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
    [switch] $AllowDisabledStartAllBackModules,
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

Import-Module (Join-Path $PSScriptRoot 'A4SBinaryIdentity.psm1') -Force
$qualificationAutomationMutex = if ($AllowMenuAutomation) { Enter-A4SQualificationAutomationLock } else { $null }
try {

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

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    [DllImport("dwmapi.dll")]
    private static extern int DwmFlush();

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

    public static WindowRecord Describe(IntPtr window)
    {
        IntPtr previous = EnterPhysicalCoordinates();
        try
        {
            RECT rect;
            if (!GetWindowRect(window, out rect))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowRect failed");
            IntPtr monitor = MonitorFromWindow(window, 2);
            MONITORINFOEX info = new MONITORINFOEX();
            info.Size = (uint)Marshal.SizeOf(typeof(MONITORINFOEX));
            if (monitor == IntPtr.Zero || !GetMonitorInfoW(monitor, ref info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetMonitorInfo failed");
            uint dpi = 0;
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
        finally { RestoreDpiContext(previous); }
    }

    public static void FlushDwmChecked()
    {
        int result = DwmFlush();
        if (result < 0)
            Marshal.ThrowExceptionForHR(result);
    }
}
'@
}

function Wait-MenuState {
    param([bool] $Visible, [Parameter(Mandatory)][uint32] $OwnerProcessId, [int] $TimeoutMilliseconds = 5000)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $windows = @([A4SScenarioNative]::VisibleMenuWindows($OwnerProcessId))
        if ($Visible -and $windows.Count -gt 1) { throw "Found $($windows.Count) visible A4S menu windows; expected exactly one." }
        if (($Visible -and $windows.Count -gt 0) -or (-not $Visible -and $windows.Count -eq 0)) {
            return $windows
        }
        [Threading.Thread]::Sleep(10)
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw "The menu did not become $(if($Visible){'visible'}else{'hidden'}) within $TimeoutMilliseconds ms."
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

function Get-DisabledStartAllBackModuleEvidence {
    param(
        [Parameter(Mandatory)][object[]] $Modules,
        [Parameter(Mandatory)][bool] $ExplicitlyAllowed
    )
    $paths = @($Modules | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) } | Sort-Object)
    $evidence = [ordered]@{
        explicitlyAllowed = $ExplicitlyAllowed
        mappedCount = $paths.Count
        accepted = $paths.Count -eq 0
        disabledRegistryKind = $null
        disabledRegistryValue = $null
        files = @()
    }
    if ($paths.Count -eq 0 -or -not $ExplicitlyAllowed) {
        return [pscustomobject]$evidence
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\StartIsBack', $false)
    try {
        if (-not $key -or -not ($key.GetValueNames() -contains 'Disabled')) {
            return [pscustomobject]$evidence
        }
        try { $kind = $key.GetValueKind('Disabled') }
        catch { return [pscustomobject]$evidence }
        $value = $key.GetValue('Disabled', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $evidence.disabledRegistryKind = [string]$kind
        $evidence.disabledRegistryValue = $value
        if ($kind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or [uint32]$value -ne 1) {
            return [pscustomobject]$evidence
        }
    }
    finally {
        if ($key) { $key.Dispose() }
    }

    $installRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'StartAllBack')).TrimEnd('\') + '\'
    $allowedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$allowedNames.Add('StartAllBackLoaderX64.dll')
    [void]$allowedNames.Add('StartAllBackX64.dll')
    foreach ($path in $paths) {
        if (-not $path.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $allowedNames.Contains([IO.Path]::GetFileName($path))) {
            return [pscustomobject]$evidence
        }
    }
    $evidence.files = @($paths | ForEach-Object { Get-StableFileEvidence -Path $_ })
    $evidence.accepted = $true
    return [pscustomobject]$evidence
}

function Write-A4SMatrixAtomically {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)
    $temporary = "$Path.partial-$PID-$([Guid]::NewGuid().ToString('N'))"
    $json = ($Value | ConvertTo-Json -Depth 15) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.backup-$PID-$([Guid]::NewGuid().ToString('N'))"
        $replaced = $false
        try {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            $replaced = $true
        } finally {
            if ($replaced -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        }
    } else {
        [IO.File]::Move($temporary, $Path)
    }
}

function Get-A4SMatrixMutexName {
    param([Parameter(Mandatory)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToUpperInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    "Local\A4SMenu.ScenarioMatrix.v1.$hash"
}

function Assert-A4SScenarioContext {
    param(
        [Parameter(Mandatory)][IntPtr] $ExpectedHostWindow,
        [Parameter(Mandatory)][uint32] $ExpectedHostProcessId,
        [Parameter(Mandatory)][int64] $ExpectedHostStartTicks,
        [Parameter(Mandatory)][uint32] $ExpectedExplorerProcessId,
        [Parameter(Mandatory)][int64] $ExpectedExplorerStartTicks,
        [Parameter(Mandatory)][string] $ExpectedLogonId
    )
    $currentHostWindow = [A4SScenarioNative]::HostWindow()
    [uint32]$currentHostProcessId = 0
    if ($currentHostWindow -eq [IntPtr]::Zero -or $currentHostWindow -ne $ExpectedHostWindow -or
        [A4SScenarioNative]::GetWindowThreadProcessId($currentHostWindow, [ref]$currentHostProcessId) -eq 0 -or
        $currentHostProcessId -ne $ExpectedHostProcessId) { throw 'The validated resident host changed during the scenario.' }
    $taskbar = [A4SScenarioNative]::FindWindowW('Shell_TrayWnd', $null)
    [uint32]$currentExplorerProcessId = 0
    if ($taskbar -eq [IntPtr]::Zero -or
        [A4SScenarioNative]::GetWindowThreadProcessId($taskbar, [ref]$currentExplorerProcessId) -eq 0 -or
        $currentExplorerProcessId -ne $ExpectedExplorerProcessId) { throw 'The taskbar Explorer changed during the scenario.' }
    $hostProcess = [Diagnostics.Process]::GetProcessById([int]$currentHostProcessId)
    $explorerProcess = [Diagnostics.Process]::GetProcessById([int]$currentExplorerProcessId)
    try {
        if ($hostProcess.StartTime.ToUniversalTime().Ticks -ne $ExpectedHostStartTicks -or
            $explorerProcess.StartTime.ToUniversalTime().Ticks -ne $ExpectedExplorerStartTicks) {
            throw 'A validated scenario process exited and its PID was reused.'
        }
        if ((Get-A4SProcessLogonId -ProcessId $currentHostProcessId) -ne $ExpectedLogonId -or
            (Get-A4SProcessLogonId -ProcessId $currentExplorerProcessId) -ne $ExpectedLogonId) {
            throw 'The scenario host or Explorer logon identity changed.'
        }
    } finally { $hostProcess.Dispose(); $explorerProcess.Dispose() }
    if ([A4SScenarioNative]::HostStatus($currentHostWindow) -ne 3) { throw 'A4SMenuHost left READY during the scenario.' }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $MatrixPath) { $MatrixPath = Join-Path $repoRoot 'build\test-results\A4S-stability-matrix.json' }
$resolvedMatrix = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MatrixPath))
if (-not $ProductDirectory) { $ProductDirectory = Join-Path $repoRoot 'build\stage\A4SProduct' }
$resolvedProductDirectory = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProductDirectory))
$productRegistration = if ($AllowMenuAutomation) { Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory } else { $null }
$expectedHost = [IO.Path]::GetFullPath((Join-Path $resolvedProductDirectory 'A4SMenuHost.exe'))
$expectedDll = [IO.Path]::GetFullPath((Join-Path $resolvedProductDirectory 'A4SMenu.dll'))
if ($AllowMenuAutomation) {
    foreach ($requiredFile in @($expectedHost, $expectedDll)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required scenario product binary is missing: '$requiredFile'." }
    }
}
$matrix = [ordered]@{ schemaVersion = 1; entries = @() }
if (Test-Path -LiteralPath $resolvedMatrix -PathType Leaf) {
    $existing = Get-Content -LiteralPath $resolvedMatrix -Raw | ConvertFrom-Json
    if ($existing.schemaVersion -ne 1) { throw "Unsupported stability-matrix schema in $resolvedMatrix." }
    $matrix.entries = @($existing.entries)
}
if (@($matrix.entries | Where-Object scenario -eq $ScenarioName).Count -ne 0) {
    throw "Scenario '$ScenarioName' already exists in $resolvedMatrix. Use a unique name so evidence cannot be silently replaced or made ambiguous."
}
$comparisonEntry = $null
if ($CompareWithScenario) {
    $comparisonEntry = @($matrix.entries | Where-Object scenario -eq $CompareWithScenario | Select-Object -Last 1)
    if ($comparisonEntry.Count -ne 1) { throw "Scenario '$CompareWithScenario' was not found in $resolvedMatrix." }
    $comparisonEntry = $comparisonEntry[0]
}

if ($ForegroundObservationDelaySeconds -gt 0) {
    Write-Host "Foreground observation begins in $ForegroundObservationDelaySeconds seconds. Activate the application state that this scenario should record."
    Start-Sleep -Seconds $ForegroundObservationDelaySeconds
}
$snapshotJson = & (Join-Path $PSScriptRoot 'Get-A4SPerformanceSnapshot.ps1') -ProductDirectory $resolvedProductDirectory
$snapshot = $snapshotJson | ConvertFrom-Json
$assertions = [Collections.Generic.List[object]]::new()
$automation = $null
$scenarioError = $null
$menu = $null
$focusAfterDismissal = $null

try {

function Add-Assertion {
    param([string] $Name, [object] $Expected, [object] $Actual, [bool] $Passed)
    $assertions.Add([ordered]@{ name = $Name; expected = $Expected; actual = $Actual; passed = $Passed })
}

if ($PSBoundParameters.ContainsKey('ExpectedMonitorCount')) {
    Add-Assertion 'monitor-count' $ExpectedMonitorCount @($snapshot.desktop.monitors).Count (@($snapshot.desktop.monitors).Count -eq $ExpectedMonitorCount)
}
if ($ExpectedTaskbarAlignment) {
    Add-Assertion 'taskbar-alignment-registry-hint' $ExpectedTaskbarAlignment $snapshot.desktop.taskbar.alignmentRegistryHint ($snapshot.desktop.taskbar.alignmentRegistryHint -eq $ExpectedTaskbarAlignment)
}
if ($ExpectedTaskbarEdge) {
    Add-Assertion 'taskbar-edge' $ExpectedTaskbarEdge $snapshot.desktop.taskbar.edge ($snapshot.desktop.taskbar.edge -eq $ExpectedTaskbarEdge)
}
if ($PSBoundParameters.ContainsKey('ExpectedPrimaryScalePercent')) {
    $primaryMonitor = @($snapshot.desktop.monitors | Where-Object primary)[0]
    Add-Assertion 'primary-scale-percent' $ExpectedPrimaryScalePercent $primaryMonitor.scalePercent ([Math]::Abs([double]$primaryMonitor.scalePercent - $ExpectedPrimaryScalePercent) -lt 0.01)
}
if ($ExpectedForegroundMode) {
    $actualForegroundMode = if (-not $snapshot.desktop.foreground) {
        'unavailable'
    } elseif ($null -eq $snapshot.desktop.foreground.fullscreenGeometryCandidate) {
        'unavailable'
    } elseif ($snapshot.desktop.foreground.fullscreenGeometryCandidate) {
        'fullscreen'
    } else {
        'windowed'
    }
    Add-Assertion 'foreground-mode-geometry-heuristic' $ExpectedForegroundMode $actualForegroundMode ($actualForegroundMode -eq $ExpectedForegroundMode)
}
if ($ExpectedHostPresence) {
    $actualHostPresence = if ($snapshot.product.residentHost) { 'resident' } else { 'absent' }
    Add-Assertion 'host-presence' $ExpectedHostPresence $actualHostPresence ($actualHostPresence -eq $ExpectedHostPresence)
}
if ($PSBoundParameters.ContainsKey('ExpectedSessionId')) {
    Add-Assertion 'explorer-session-id' $ExpectedSessionId $snapshot.explorer.sessionId ($snapshot.explorer.sessionId -eq $ExpectedSessionId)
}
if ($ExpectedExplorerRelationship) {
    $sameExplorerIdentity = $snapshot.explorer.pid -eq $comparisonEntry.environment.explorer.pid -and
        $snapshot.explorer.startTimeUtc -eq $comparisonEntry.environment.explorer.startTimeUtc
    $actualExplorerRelationship = if ($sameExplorerIdentity) { 'same' } else { 'changed' }
    Add-Assertion 'explorer-process-identity-relationship' $ExpectedExplorerRelationship $actualExplorerRelationship ($actualExplorerRelationship -eq $ExpectedExplorerRelationship)
}
if ($ExpectedSessionRelationship) {
    $actualSessionRelationship = if ([string]$snapshot.explorer.logonId -eq [string]$comparisonEntry.environment.explorer.logonId) { 'same' } else { 'changed' }
    Add-Assertion 'logon-session-identity-relationship' $ExpectedSessionRelationship $actualSessionRelationship ($actualSessionRelationship -eq $ExpectedSessionRelationship)
}

if ($AllowMenuAutomation) {
    [uint32]$explorerProcessId = $snapshot.explorer.pid
    if (-not $explorerProcessId) { throw 'The snapshot did not identify the taskbar Explorer process.' }
    $hostWindow = [A4SScenarioNative]::HostWindow()
    if ($hostWindow -eq [IntPtr]::Zero) { throw 'No resident A4SMenuHost was found. The scenario tool never starts or injects it.' }
    [uint32]$residentHostProcessId = 0
    [void][A4SScenarioNative]::GetWindowThreadProcessId($hostWindow, [ref]$residentHostProcessId)
    if (-not $residentHostProcessId) { throw 'Could not resolve the resident A4S host process.' }
    $residentHostProcess = [Diagnostics.Process]::GetProcessById([int]$residentHostProcessId)
    $explorerProcess = [Diagnostics.Process]::GetProcessById([int]$explorerProcessId)
    try {
        if ($residentHostProcess.SessionId -ne $snapshot.observerSessionId -or $snapshot.explorer.sessionId -ne $snapshot.observerSessionId) {
            throw "The observer, Explorer, and A4S host must share one interactive session. observer=$($snapshot.observerSessionId) explorer=$($snapshot.explorer.sessionId) host=$($residentHostProcess.SessionId)."
        }
        $observerLogonId = [string]$snapshot.observerLogonId
        if ((Get-A4SProcessLogonId -ProcessId $residentHostProcessId) -ne $observerLogonId -or
            (Get-A4SProcessLogonId -ProcessId $explorerProcessId) -ne $observerLogonId) {
            throw 'The observer, Explorer, and A4S host do not share one logon identity.'
        }
        $hostStartTicks = $residentHostProcess.StartTime.ToUniversalTime().Ticks
        $explorerStartTicks = $explorerProcess.StartTime.ToUniversalTime().Ticks
        $actualHostPath = [IO.Path]::GetFullPath($residentHostProcess.MainModule.FileName)
        $mappedDllModules = @($explorerProcess.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' })
        $competingModules = @($explorerProcess.Modules | Where-Object { $_.ModuleName -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
        $mappedDllPaths = @($mappedDllModules | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) })
        $disabledStartAllBackEvidence = Get-DisabledStartAllBackModuleEvidence -Modules $competingModules `
            -ExplicitlyAllowed ([bool]$AllowDisabledStartAllBackModules)
        if (-not $disabledStartAllBackEvidence.accepted) {
            throw "A competing Start-menu module is mapped. Only the exact disabled StartAllBack loader/runtime pair may be accepted with -AllowDisabledStartAllBackModules. Found '$(@($competingModules.FileName) -join '; ')'."
        }
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualHostPath, $expectedHost) -or
            $mappedDllModules.Count -ne 1 -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals($mappedDllPaths[0], $expectedDll)) {
            throw "Scenario automation is not bound to the selected product directory '$resolvedProductDirectory'."
        }
        $hostFileEvidence = Get-StableFileEvidence $expectedHost
        $dllFileEvidence = Get-StableFileEvidence $expectedDll
        $hostFileIdentity = Get-A4SFileImageIdentity $expectedHost
        $hostLoadedIdentity = Get-A4SLoadedImageIdentity -ProcessId $residentHostProcessId -BaseAddress $residentHostProcess.MainModule.BaseAddress
        $dllFileIdentity = Get-A4SFileImageIdentity $expectedDll
        $dllLoadedIdentity = Get-A4SLoadedImageIdentity -ProcessId $explorerProcessId -BaseAddress $mappedDllModules[0].BaseAddress
        if ($hostFileIdentity -ne $hostLoadedIdentity -or $dllFileIdentity -ne $dllLoadedIdentity) {
            throw 'A resident scenario product image differs from the exact file at its selected path.'
        }
    } finally {
        $residentHostProcess.Dispose()
        $explorerProcess.Dispose()
    }
    [void](Assert-A4SScenarioContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
        -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
        -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
    if (@([A4SScenarioNative]::VisibleMenuWindows($explorerProcessId)).Count -ne 0) { throw 'Close the menu before running scenario automation.' }

    $dismissedManually = $false
    $automationMenuExpectedVisible = $false
    $automationMenuWindow = [IntPtr]::Zero
    try {
        [void](Assert-A4SScenarioContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
            -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
            -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
        [A4SScenarioNative]::Toggle($hostWindow)
        $visibleWindows = @(Wait-MenuState -Visible $true -OwnerProcessId $explorerProcessId)
        if ($visibleWindows.Count -ne 1) { throw "Open/close automation found $($visibleWindows.Count) visible A4S menu windows; expected one." }
        $menuWindow = [IntPtr]$visibleWindows[0]
        $automationMenuWindow = $menuWindow
        $automationMenuExpectedVisible = $true
        [A4SScenarioNative]::FlushDwmChecked()
        if ([A4SScenarioNative]::GetForegroundWindow() -ne $menuWindow) { throw 'The opened A4S menu was not the foreground top-level window.' }
        $menu = [A4SScenarioNative]::Describe($menuWindow)
        if ($menu.Dpi -eq 0) { throw 'GetDpiForWindow returned zero for the A4S menu; DPI evidence is unavailable.' }
        if ($ObserveManualFocusDismissal) {
            Write-Host "A4S menu is open. Focus another application within $DismissalTimeoutSeconds seconds; this tool will only observe whether the menu dismisses."
            [void](Wait-MenuState -Visible $false -OwnerProcessId $explorerProcessId -TimeoutMilliseconds ($DismissalTimeoutSeconds * 1000))
            $automationMenuExpectedVisible = $false
            $newForeground = [A4SScenarioNative]::GetForegroundWindow()
            [uint32]$newForegroundProcessId = 0
            if ($newForeground -ne [IntPtr]::Zero) { [void][A4SScenarioNative]::GetWindowThreadProcessId($newForeground, [ref]$newForegroundProcessId) }
            $focusAfterDismissal = [ordered]@{
                hwnd = if ($newForeground -ne [IntPtr]::Zero) { '0x{0:X}' -f $newForeground.ToInt64() } else { $null }
                pid = $newForegroundProcessId
                changedFromMenu = $newForeground -ne [IntPtr]::Zero -and $newForeground -ne $menuWindow
                changedToAnotherProcess = $newForegroundProcessId -ne 0 -and $newForegroundProcessId -ne $explorerProcessId
            }
            if (-not $focusAfterDismissal.changedFromMenu -or -not $focusAfterDismissal.changedToAnotherProcess) {
                throw 'The menu disappeared, but focus in a non-Explorer application was not observed; manual application-focus dismissal was not proved.'
            }
            $dismissedManually = $true
        } else {
            [A4SScenarioNative]::Toggle($hostWindow)
            [void](Wait-MenuState -Visible $false -OwnerProcessId $explorerProcessId)
            $automationMenuExpectedVisible = $false
        }
    } finally {
        # A cleanup toggle is permitted only while the exact window opened by
        # this scenario is still expected to be visible. Once a normal/manual
        # dismissal has been observed, a newly opened menu belongs to the user
        # or another actor and must not be toggled closed by stale cleanup.
        if ($automationMenuExpectedVisible) {
            $leftVisible = @([A4SScenarioNative]::VisibleMenuWindows($explorerProcessId))
            if ($leftVisible.Count -eq 1 -and [IntPtr]$leftVisible[0] -eq $automationMenuWindow) {
            try {
                [void](Assert-A4SScenarioContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
                    -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
                    -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
                [A4SScenarioNative]::Toggle($hostWindow)
                [void](Wait-MenuState -Visible $false -OwnerProcessId $explorerProcessId)
                $automationMenuExpectedVisible = $false
            } catch {
                Write-Warning "Could not confirm menu cleanup after scenario automation: $($_.Exception.Message)"
            }
            } elseif ($leftVisible.Count -eq 1) {
                Write-Warning 'Cleanup found one visible A4S menu, but it was not the exact window opened by this scenario; refusing a stale toggle.'
            } elseif ($leftVisible.Count -gt 1) {
                Write-Warning "Cleanup found $($leftVisible.Count) visible A4S menu windows and refused an ambiguous toggle."
            }
        }
    }
    [void](Assert-A4SScenarioContext -ExpectedHostWindow $hostWindow -ExpectedHostProcessId $residentHostProcessId `
        -ExpectedHostStartTicks $hostStartTicks -ExpectedExplorerProcessId $explorerProcessId `
        -ExpectedExplorerStartTicks $explorerStartTicks -ExpectedLogonId $observerLogonId)
    $postHostEvidence = Get-StableFileEvidence $expectedHost
    $postDllEvidence = Get-StableFileEvidence $expectedDll
    $postProductRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
    $postExplorer = [Diagnostics.Process]::GetProcessById([int]$explorerProcessId)
    $postHost = [Diagnostics.Process]::GetProcessById([int]$residentHostProcessId)
    try {
        $postMapped = @($postExplorer.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' })
        $postCompeting = @($postExplorer.Modules | Where-Object { $_.ModuleName -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
        $postDisabledStartAllBackEvidence = Get-DisabledStartAllBackModuleEvidence -Modules $postCompeting `
            -ExplicitlyAllowed ([bool]$AllowDisabledStartAllBackModules)
        $initialStartAllBackIdentity = $disabledStartAllBackEvidence | ConvertTo-Json -Depth 6 -Compress
        $postStartAllBackIdentity = $postDisabledStartAllBackEvidence | ConvertTo-Json -Depth 6 -Compress
        if ($postProductRegistration.kind -ne $productRegistration.kind -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$postProductRegistration.activeSlot, [string]$productRegistration.activeSlot) -or
            $postMapped.Count -ne 1 -or -not $postDisabledStartAllBackEvidence.accepted -or
            $initialStartAllBackIdentity -cne $postStartAllBackIdentity -or
            $postHostEvidence.length -ne $hostFileEvidence.length -or
            $postDllEvidence.length -ne $dllFileEvidence.length -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($postHost.MainModule.FileName), $expectedHost) -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($postMapped[0].FileName), $expectedDll) -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals($postHostEvidence.sha256, $hostFileEvidence.sha256) -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals($postDllEvidence.sha256, $dllFileEvidence.sha256) -or
            (Get-A4SLoadedImageIdentity -ProcessId $residentHostProcessId -BaseAddress $postHost.MainModule.BaseAddress) -ne $hostLoadedIdentity -or
            (Get-A4SLoadedImageIdentity -ProcessId $explorerProcessId -BaseAddress $postMapped[0].BaseAddress) -ne $dllLoadedIdentity) {
            throw 'The staged or resident product identity changed during scenario automation.'
        }
    } finally { $postExplorer.Dispose(); $postHost.Dispose() }
    $automation = [ordered]@{
        openClosePassed = $true
        manualFocusDismissalRequested = [bool]$ObserveManualFocusDismissal
        manualFocusDismissalPassed = if ($ObserveManualFocusDismissal) { $dismissedManually } else { $null }
        focusAfterDismissal = $focusAfterDismissal
        product = [ordered]@{
            directory = $resolvedProductDirectory
            registration = $productRegistration
            hostPath = $expectedHost
            hostSha256 = $hostFileEvidence.sha256
            hostLength = $hostFileEvidence.length
            hostFileIdentity = $hostFileIdentity
            hostLoadedIdentity = $hostLoadedIdentity
            dllPath = $expectedDll
            dllSha256 = $dllFileEvidence.sha256
            dllLength = $dllFileEvidence.length
            dllFileIdentity = $dllFileIdentity
            dllLoadedIdentity = $dllLoadedIdentity
            disabledStartAllBackModules = $disabledStartAllBackEvidence
            hostPid = $residentHostProcessId
            hostStartTimeUtc = [DateTime]::new($hostStartTicks, [DateTimeKind]::Utc).ToString('o')
            explorerPid = $explorerProcessId
            explorerStartTimeUtc = [DateTime]::new($explorerStartTicks, [DateTimeKind]::Utc).ToString('o')
            logonId = $observerLogonId
        }
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
} catch {
    $scenarioError = $_
    $automation = [ordered]@{
        openClosePassed = $false
        manualFocusDismissalRequested = [bool]$ObserveManualFocusDismissal
        manualFocusDismissalPassed = if ($ObserveManualFocusDismissal) { $false } else { $null }
        focusAfterDismissal = $focusAfterDismissal
        error = $_.Exception.Message
        menuWindow = if ($menu) { [ordered]@{
            hwnd = ('0x{0:X}' -f $menu.Handle)
            rect = [ordered]@{ left = $menu.Left; top = $menu.Top; width = $menu.Width; height = $menu.Height }
            monitor = $menu.Monitor
            dpi = $menu.Dpi
        } } else { $null }
    }
}

$entry = [ordered]@{
    scenario = $ScenarioName
    capturedUtc = [DateTime]::UtcNow.ToString('o')
    notes = $Notes
    assertions = $assertions
    assertionsPassed = -not $scenarioError -and @($assertions | Where-Object { -not $_.passed }).Count -eq 0
    environment = $snapshot
    automation = $automation
    executionError = if ($scenarioError) { $scenarioError.Exception.Message } else { $null }
}

$matrixDirectory = Split-Path -Parent $resolvedMatrix
if (-not (Test-Path -LiteralPath $matrixDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $matrixDirectory -Force | Out-Null
}
$matrixMutex = [Threading.Mutex]::new($false, (Get-A4SMatrixMutexName $resolvedMatrix))
$matrixLockHeld = $false
try {
    try { $matrixLockHeld = $matrixMutex.WaitOne([TimeSpan]::FromSeconds(30)) }
    catch [Threading.AbandonedMutexException] { $matrixLockHeld = $true }
    if (-not $matrixLockHeld) { throw "Timed out waiting to append scenario evidence to '$resolvedMatrix'." }
    $currentMatrix = [ordered]@{ schemaVersion = 1; entries = @() }
    if (Test-Path -LiteralPath $resolvedMatrix -PathType Leaf) {
        $current = Get-Content -LiteralPath $resolvedMatrix -Raw | ConvertFrom-Json
        if ($current.schemaVersion -ne 1) { throw "Unsupported stability-matrix schema in $resolvedMatrix." }
        $currentMatrix.entries = @($current.entries)
    }
    if (@($currentMatrix.entries | Where-Object scenario -eq $ScenarioName).Count -ne 0) {
        throw "Scenario '$ScenarioName' was written concurrently; refusing to replace or duplicate evidence."
    }
    $currentMatrix.entries += $entry
    Write-A4SMatrixAtomically -Path $resolvedMatrix -Value $currentMatrix
} finally {
    if ($matrixLockHeld) { $matrixMutex.ReleaseMutex() }
    $matrixMutex.Dispose()
}

Write-Host "Recorded A4S scenario '$ScenarioName': $resolvedMatrix"
if ($scenarioError) {
    throw "Scenario execution failed: $($scenarioError.Exception.Message). Evidence was preserved."
}
if (-not $entry.assertionsPassed) {
    $failed = @($assertions | Where-Object { -not $_.passed } | ForEach-Object { "$($_.name): expected '$($_.expected)', actual '$($_.actual)'" })
    throw "Scenario environment assertions failed: $($failed -join '; '). Evidence was preserved."
}
} finally {
    if ($qualificationAutomationMutex) {
        Exit-A4SQualificationAutomationLock -Mutex $qualificationAutomationMutex
    }
}
