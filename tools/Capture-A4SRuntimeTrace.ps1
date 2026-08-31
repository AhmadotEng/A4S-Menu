[CmdletBinding()]
param(
    [switch]$AllowMenuAutomation,
    [ValidateRange(0, 500)]
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
    [ValidateRange(0, 300)]
    [int]$ManualInteractionSeconds = 0,
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
if ($CapturedCycles -eq 0 -and $ManualInteractionSeconds -eq 0) {
    throw 'At least one automated captured cycle or a positive -ManualInteractionSeconds window is required.'
}
if ($ManualInteractionSeconds -gt 0 -and $EnforceTargets) {
    throw '-EnforceTargets is reserved for a closed automated-cycle trace; capture manual Programs/search phases in a separate non-enforcing trace.'
}
if ($ManualInteractionSeconds -gt 0 -and $CapturedCycles -ne 0) {
    throw '-ManualInteractionSeconds is a separate phase trace and requires -CapturedCycles 0.'
}
if ($OperatorAttestsFirstCapturedCycleIsCold -and $CapturedCycles -eq 0) {
    throw '-OperatorAttestsFirstCapturedCycleIsCold requires at least one automated captured cycle.'
}
if ($EnforceTargets -and ($CapturedCycles - $(if ($OperatorAttestsFirstCapturedCycleIsCold) { 1 } else { 0 })) -lt 20) {
    throw '-EnforceTargets requires at least 20 warm automated cycles (21 total when the first is classified cold).'
}

Import-Module (Join-Path $PSScriptRoot 'A4SBinaryIdentity.psm1') -Force

if (-not ('A4SRuntimeTraceNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer,
        UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

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

    private static ushort U16(byte[] bytes, int offset)
    {
        if (offset < 0 || offset > bytes.Length - 2) throw new InvalidDataException("Truncated PE image.");
        return BitConverter.ToUInt16(bytes, offset);
    }

    private static uint U32(byte[] bytes, int offset)
    {
        if (offset < 0 || offset > bytes.Length - 4) throw new InvalidDataException("Truncated PE image.");
        return BitConverter.ToUInt32(bytes, offset);
    }

    private static byte[] ReadRemote(IntPtr process, IntPtr address, int count)
    {
        byte[] bytes = new byte[count];
        UIntPtr read;
        if (!ReadProcessMemory(process, address, bytes, new UIntPtr((uint)count), out read) ||
            read.ToUInt64() != (ulong)count)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the resident PE image");
        return bytes;
    }

    private sealed class PeHeaders
    {
        public int PeOffset;
        public int OptionalOffset;
        public int SectionOffset;
        public ushort SectionCount;
        public ushort OptionalSize;
        public uint TimeDateStamp;
        public uint SizeOfImage;
        public uint Checksum;
        public uint DebugRva;
        public uint DebugSize;
    }

    private static PeHeaders ParseHeaders(byte[] bytes)
    {
        if (bytes.Length < 0x100 || U16(bytes, 0) != 0x5a4d)
            throw new InvalidDataException("The image has no valid DOS header.");
        int pe = checked((int)U32(bytes, 0x3c));
        if (pe < 0x40 || pe > bytes.Length - 24 || U32(bytes, pe) != 0x00004550)
            throw new InvalidDataException("The image has no valid PE header.");
        ushort sections = U16(bytes, pe + 6);
        ushort optionalSize = U16(bytes, pe + 20);
        int optional = checked(pe + 24);
        int sectionOffset = checked(optional + optionalSize);
        if (sections == 0 || sections > 96 || sectionOffset > bytes.Length - (sections * 40))
            throw new InvalidDataException("The image has an invalid section table.");
        ushort magic = U16(bytes, optional);
        int directoryBase;
        int directoryCountOffset;
        if (magic == 0x20b) { directoryBase = optional + 112; directoryCountOffset = optional + 108; }
        else if (magic == 0x10b) { directoryBase = optional + 96; directoryCountOffset = optional + 92; }
        else throw new InvalidDataException("The image has an unsupported optional header.");
        uint directoryCount = U32(bytes, directoryCountOffset);
        uint debugRva = 0, debugSize = 0;
        if (directoryCount > 6 && directoryBase + 56 <= optional + optionalSize)
        {
            debugRva = U32(bytes, directoryBase + 48);
            debugSize = U32(bytes, directoryBase + 52);
        }
        return new PeHeaders {
            PeOffset = pe, OptionalOffset = optional, SectionOffset = sectionOffset,
            SectionCount = sections, OptionalSize = optionalSize,
            TimeDateStamp = U32(bytes, pe + 8), SizeOfImage = U32(bytes, optional + 56),
            Checksum = U32(bytes, optional + 64), DebugRva = debugRva, DebugSize = debugSize
        };
    }

    private static int RvaToFileOffset(byte[] bytes, PeHeaders headers, uint rva)
    {
        uint sizeOfHeaders = U32(bytes, headers.OptionalOffset + 60);
        if (rva < sizeOfHeaders) return checked((int)rva);
        for (int index = 0; index < headers.SectionCount; index++)
        {
            int section = headers.SectionOffset + index * 40;
            uint virtualSize = U32(bytes, section + 8);
            uint virtualAddress = U32(bytes, section + 12);
            uint rawSize = U32(bytes, section + 16);
            uint rawOffset = U32(bytes, section + 20);
            uint extent = Math.Max(virtualSize, rawSize);
            if (rva >= virtualAddress && (ulong)rva < (ulong)virtualAddress + extent)
                return checked((int)(rawOffset + (rva - virtualAddress)));
        }
        throw new InvalidDataException("A PE data-directory RVA does not map to a file section.");
    }

    private static string Identity(uint stamp, uint sizeOfImage, uint checksum, byte[] codeView)
    {
        if (codeView == null || codeView.Length < 24 || U32(codeView, 0) != 0x53445352)
            throw new InvalidDataException("The image has no strong RSDS build identity; refusing path-only validation.");
        byte[] guidBytes = new byte[16];
        Buffer.BlockCopy(codeView, 4, guidBytes, 0, 16);
        Guid guid = new Guid(guidBytes);
        uint age = U32(codeView, 20);
        if (guid == Guid.Empty || age == 0)
            throw new InvalidDataException("The image has an invalid RSDS build identity.");
        return String.Format(CultureInfo.InvariantCulture,
            "timestamp={0:x8};size={1:x8};checksum={2:x8};rsds={3:N};age={4}",
            stamp, sizeOfImage, checksum, guid, age);
    }

    public static string FileImageIdentity(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        PeHeaders headers = ParseHeaders(bytes);
        if (headers.DebugRva == 0 || headers.DebugSize < 28 || headers.DebugSize > 0x10000)
            throw new InvalidDataException("The staged image has no usable debug directory.");
        int debugOffset = RvaToFileOffset(bytes, headers, headers.DebugRva);
        int debugCount = checked((int)(headers.DebugSize / 28));
        for (int index = 0; index < debugCount; index++)
        {
            int entry = checked(debugOffset + index * 28);
            if (entry > bytes.Length - 28) break;
            if (U32(bytes, entry + 12) != 2) continue;
            uint dataSize = U32(bytes, entry + 16);
            uint rawOffset = U32(bytes, entry + 24);
            if (dataSize < 24 || rawOffset > bytes.Length - 24) continue;
            byte[] codeView = new byte[24];
            Buffer.BlockCopy(bytes, checked((int)rawOffset), codeView, 0, 24);
            return Identity(headers.TimeDateStamp, headers.SizeOfImage, headers.Checksum, codeView);
        }
        throw new InvalidDataException("The staged image has no RSDS CodeView record.");
    }

    public static string LoadedImageIdentity(uint processId, IntPtr baseAddress)
    {
        const uint PROCESS_QUERY_INFORMATION = 0x0400;
        const uint PROCESS_VM_READ = 0x0010;
        IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the resident product process");
        try
        {
            byte[] initial = ReadRemote(process, baseAddress, 0x1000);
            int pe = checked((int)U32(initial, 0x3c));
            int required = checked(pe + 24 + U16(initial, pe + 20) + U16(initial, pe + 6) * 40);
            byte[] headers = required <= initial.Length ? initial : ReadRemote(process, baseAddress, required);
            PeHeaders parsed = ParseHeaders(headers);
            if (parsed.DebugRva == 0 || parsed.DebugSize < 28 || parsed.DebugSize > 0x10000)
                throw new InvalidDataException("The resident image has no usable debug directory.");
            byte[] debug = ReadRemote(process, new IntPtr(baseAddress.ToInt64() + parsed.DebugRva),
                checked((int)parsed.DebugSize));
            for (int entry = 0; entry <= debug.Length - 28; entry += 28)
            {
                if (U32(debug, entry + 12) != 2) continue;
                uint dataSize = U32(debug, entry + 16);
                uint dataRva = U32(debug, entry + 20);
                if (dataSize < 24 || dataRva == 0) continue;
                byte[] codeView = ReadRemote(process, new IntPtr(baseAddress.ToInt64() + dataRva), 24);
                return Identity(parsed.TimeDateStamp, parsed.SizeOfImage, parsed.Checksum, codeView);
            }
            throw new InvalidDataException("The resident image has no RSDS CodeView record.");
        }
        finally { CloseHandle(process); }
    }
}
'@
}

function Resolve-A4SUnresolvedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Write-A4SJsonAtomicallyReplacing {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Cannot enrich missing trace report '$Path'." }
    $temporary = "$Path.partial-$PID-$([Guid]::NewGuid().ToString('N'))"
    $json = ($Value | ConvertTo-Json -Depth 14) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    $backup = "$Path.backup-$PID-$([Guid]::NewGuid().ToString('N'))"
    $replaced = $false
    try {
        [IO.File]::Replace($temporary, $Path, $backup, $true)
        $replaced = $true
    } finally {
        if ($replaced -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
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

function Assert-A4SResidentContext {
    param(
        [Parameter(Mandatory)][IntPtr]$ExpectedHostWindow,
        [Parameter(Mandatory)][uint32]$ExpectedHostProcessId,
        [Parameter(Mandatory)][int64]$ExpectedHostStartTicks,
        [Parameter(Mandatory)][uint32]$ExpectedExplorerProcessId,
        [Parameter(Mandatory)][int64]$ExpectedExplorerStartTicks,
        [Parameter(Mandatory)][string]$ExpectedLogonId
    )
    $currentHostWindow = [A4SRuntimeTraceNative]::HostWindow()
    if ($currentHostWindow -eq [IntPtr]::Zero -or $currentHostWindow -ne $ExpectedHostWindow) {
        throw 'The validated A4S host window disappeared or was replaced during capture.'
    }
    [uint32]$currentHostProcessId = 0
    [void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($currentHostWindow, [ref]$currentHostProcessId)
    if ($currentHostProcessId -ne $ExpectedHostProcessId) {
        throw "The A4S host window owner changed from PID $ExpectedHostProcessId to PID $currentHostProcessId."
    }
    $currentTaskbar = [A4SRuntimeTraceNative]::FindWindowW('Shell_TrayWnd', $null)
    if ($currentTaskbar -eq [IntPtr]::Zero) { throw 'Explorer taskbar disappeared during capture.' }
    [uint32]$currentExplorerProcessId = 0
    [void][A4SRuntimeTraceNative]::GetWindowThreadProcessId($currentTaskbar, [ref]$currentExplorerProcessId)
    if ($currentExplorerProcessId -ne $ExpectedExplorerProcessId) {
        throw "Explorer changed from PID $ExpectedExplorerProcessId to PID $currentExplorerProcessId during capture."
    }
    $currentHost = [Diagnostics.Process]::GetProcessById([int]$ExpectedHostProcessId)
    $currentExplorer = [Diagnostics.Process]::GetProcessById([int]$ExpectedExplorerProcessId)
    try {
        if ($currentHost.StartTime.ToUniversalTime().Ticks -ne $ExpectedHostStartTicks -or
            $currentExplorer.StartTime.ToUniversalTime().Ticks -ne $ExpectedExplorerStartTicks) {
            throw 'A validated process exited and its PID was reused during capture.'
        }
        if ((Get-A4SProcessLogonId -ProcessId $ExpectedHostProcessId) -ne $ExpectedLogonId -or
            (Get-A4SProcessLogonId -ProcessId $ExpectedExplorerProcessId) -ne $ExpectedLogonId) {
            throw 'The resident host or Explorer logon identity changed during capture.'
        }
    } finally {
        $currentHost.Dispose()
        $currentExplorer.Dispose()
    }
    if ([A4SRuntimeTraceNative]::HostStatus($currentHostWindow, 2500) -ne 3) {
        throw 'A4SMenuHost is no longer READY.'
    }
    return $currentTaskbar
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ProductDirectory) { $ProductDirectory = Join-Path $repoRoot 'build\stage\A4SProduct' }
$resolvedProductDirectory = Resolve-A4SUnresolvedPath $ProductDirectory
$productRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
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
$residentHostStartTicks = $residentHost.StartTime.ToUniversalTime().Ticks
$explorerStartTicks = $explorer.StartTime.ToUniversalTime().Ticks
$observerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($residentHost.SessionId -ne $observerSessionId -or $explorer.SessionId -ne $observerSessionId) {
    throw "Observer, resident host, and Explorer must share the interactive session. observer=$observerSessionId host=$($residentHost.SessionId) explorer=$($explorer.SessionId)."
}
$observerLogonId = Get-A4SProcessLogonId -ProcessId ([uint32][Diagnostics.Process]::GetCurrentProcess().Id)
if ((Get-A4SProcessLogonId -ProcessId $residentHostProcessId) -ne $observerLogonId -or
    (Get-A4SProcessLogonId -ProcessId $explorerProcessId) -ne $observerLogonId) {
    throw 'Observer, resident host, and Explorer do not share one Windows logon identity.'
}
$startAllBackRegistryPath = 'Registry::HKEY_CURRENT_USER\Software\StartIsBack'
$startAllBackDisabledState = $null
if (Test-Path -LiteralPath $startAllBackRegistryPath) {
    $startAllBackDisabledState = Get-ItemPropertyValue -LiteralPath $startAllBackRegistryPath -Name Disabled -ErrorAction SilentlyContinue
    if ($null -eq $startAllBackDisabledState -or [int]$startAllBackDisabledState -ne 1) {
        throw 'StartAllBack is not authoritatively disabled for the qualification trace.'
    }
}
$actualHost = [IO.Path]::GetFullPath($residentHost.MainModule.FileName)
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualHost, $expectedHost)) {
    throw "The resident host is not the exact staged host. Expected '$expectedHost'; found '$actualHost'."
}
$mappedDlls = @($explorer.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' })
$competingStartMenuModules = @($explorer.Modules | Where-Object { $_.ModuleName -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
$mappedDllPaths = @($mappedDlls | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) })
if ($mappedDlls.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals($mappedDllPaths[0], $expectedDll)) {
    throw "Expected exactly one staged A4SMenu.dll mapping in Explorer PID $explorerProcessId; found '$($mappedDllPaths -join '; ')'."
}
if ($competingStartMenuModules.Count -ne 0) {
    throw "A competing StartAllBack/StartIsBack/Open-Shell module remains mapped in Explorer: '$(@($competingStartMenuModules.FileName) -join '; ')'."
}
$initialHostSha256 = (Get-FileHash -LiteralPath $expectedHost -Algorithm SHA256).Hash
$initialDllSha256 = (Get-FileHash -LiteralPath $expectedDll -Algorithm SHA256).Hash
$hostFileIdentity = [A4SRuntimeTraceNative]::FileImageIdentity($expectedHost)
$hostLoadedIdentity = [A4SRuntimeTraceNative]::LoadedImageIdentity(
    $residentHostProcessId, $residentHost.MainModule.BaseAddress)
if (-not [StringComparer]::Ordinal.Equals($hostFileIdentity, $hostLoadedIdentity)) {
    throw "The resident host image is older or different from the staged file at the same path. file='$hostFileIdentity'; memory='$hostLoadedIdentity'. Restart the exact staged host before capture."
}
$dllFileIdentity = [A4SRuntimeTraceNative]::FileImageIdentity($expectedDll)
$dllLoadedIdentity = [A4SRuntimeTraceNative]::LoadedImageIdentity(
    $explorerProcessId, $mappedDlls[0].BaseAddress)
if (-not [StringComparer]::Ordinal.Equals($dllFileIdentity, $dllLoadedIdentity)) {
    throw "Explorer has an older or different A4SMenu.dll image mapped at the staged path. file='$dllFileIdentity'; memory='$dllLoadedIdentity'. Restart Explorer through the approved product lifecycle before capture."
}
$preflightHostSha256 = (Get-FileHash -LiteralPath $expectedHost -Algorithm SHA256).Hash
$preflightDllSha256 = (Get-FileHash -LiteralPath $expectedDll -Algorithm SHA256).Hash
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($initialHostSha256, $preflightHostSha256) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals($initialDllSha256, $preflightDllSha256) -or
    -not [StringComparer]::Ordinal.Equals($hostFileIdentity, [A4SRuntimeTraceNative]::FileImageIdentity($expectedHost)) -or
    -not [StringComparer]::Ordinal.Equals($dllFileIdentity, [A4SRuntimeTraceNative]::FileImageIdentity($expectedDll))) {
    throw 'A staged product binary changed during resident-image preflight.'
}
if (@([A4SRuntimeTraceNative]::VisibleMenuWindows($explorerProcessId)).Count -ne 0) {
    throw 'Close the A4S menu before capture. The tool refuses to guess or alter the initial state.'
}

$observedNominalRefreshRateHz = [A4SRuntimeTraceNative]::NominalRefreshRate($taskbar)
$refreshRateSource = if ($RefreshRateHz -gt 0) { 'operator-supplied-and-checked-against-EnumDisplaySettings' } else { 'EnumDisplaySettings-current-mode-integer' }
if ($RefreshRateHz -eq 0) {
    $RefreshRateHz = $observedNominalRefreshRateHz
    if ($RefreshRateHz -eq 0) { throw 'Could not determine the active display refresh rate; pass -RefreshRateHz explicitly.' }
} elseif ($observedNominalRefreshRateHz -gt 0 -and [Math]::Abs($RefreshRateHz - $observedNominalRefreshRateHz) -gt 1.0) {
    throw "The supplied refresh rate $RefreshRateHz Hz differs materially from the current-mode integer value $observedNominalRefreshRateHz Hz. Recheck the active display before using a one-frame target."
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
$sessionCreateAttempted = $false
$sessionStarted = $false
$captureError = $null
$cleanupError = $null
$stopError = $null
$integrityError = $null
$artifactErrors = [Collections.Generic.List[string]]::new()
$startedUtc = $null
$stoppedUtc = $null
$completedCycles = 0

try {
    for ($warmup = 0; $warmup -lt $WarmupCycles; $warmup++) {
        [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow `
            -ExpectedHostProcessId $residentHostProcessId -ExpectedHostStartTicks $residentHostStartTicks `
            -ExpectedExplorerProcessId $explorerProcessId -ExpectedExplorerStartTicks $explorerStartTicks `
            -ExpectedLogonId $observerLogonId)
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
    $sessionCreateAttempted = $true
    $startResult = Invoke-A4SLogman -Arguments $startArguments
    if ($startResult.exitCode -eq 0) { $sessionStarted = $true }
    try {
        $startResult.output | Set-Content -LiteralPath (Join-Path $resolvedOutputDirectory 'session-start.txt') -Encoding UTF8
    } catch { [void]$artifactErrors.Add("Could not write session-start.txt: $($_.Exception.Message)") }
    if ($startResult.exitCode -ne 0) {
        throw "logman could not start ETW session '$sessionName' (exit $($startResult.exitCode)): $($startResult.output -join ' ')"
    }
    for ($cycle = 0; $cycle -lt $CapturedCycles; $cycle++) {
        [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow `
            -ExpectedHostProcessId $residentHostProcessId -ExpectedHostStartTicks $residentHostStartTicks `
            -ExpectedExplorerProcessId $explorerProcessId -ExpectedExplorerStartTicks $explorerStartTicks `
            -ExpectedLogonId $observerLogonId)
        [void](Invoke-A4SToggleCycle -HostWindow $hostWindow -ExplorerProcessId $explorerProcessId)
        $completedCycles++
    }
    if ($ManualInteractionSeconds -gt 0) {
        Write-Host "Manual trace window: for the next $ManualInteractionSeconds seconds, use the A4S menu normally. Open All Programs, wait for it to populate, return, then type a non-empty search query and let results settle."
        Start-Sleep -Seconds $ManualInteractionSeconds
    }
} catch {
    $captureError = $_
} finally {
    try {
        [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow `
            -ExpectedHostProcessId $residentHostProcessId -ExpectedHostStartTicks $residentHostStartTicks `
            -ExpectedExplorerProcessId $explorerProcessId -ExpectedExplorerStartTicks $explorerStartTicks `
            -ExpectedLogonId $observerLogonId)
        $visible = @([A4SRuntimeTraceNative]::VisibleMenuWindows($explorerProcessId))
        if ($visible.Count -eq 1) {
            [A4SRuntimeTraceNative]::Toggle($hostWindow, 2500)
            [void](Wait-A4SMenuVisibility -Visible $false -ExplorerProcessId $explorerProcessId -TimeoutMilliseconds $TransitionTimeoutMilliseconds)
        } elseif ($visible.Count -gt 1) {
            throw "Cleanup found $($visible.Count) A4S menu windows in validated Explorer PID $explorerProcessId and refused an ambiguous toggle."
        }
    } catch { $cleanupError = $_ }
    if ($sessionCreateAttempted) {
        try {
            $stopResult = Invoke-A4SLogman -Arguments @('stop', $sessionName, '-ets')
            if ($stopResult.exitCode -eq 0) { $stoppedUtc = [DateTimeOffset]::UtcNow }
            try {
                $stopResult.output | Set-Content -LiteralPath (Join-Path $resolvedOutputDirectory 'session-stop.txt') -Encoding UTF8
            } catch { [void]$artifactErrors.Add("Could not write session-stop.txt: $($_.Exception.Message)") }
            if ($sessionStarted -and $stopResult.exitCode -ne 0) {
                throw "logman stop failed with exit code $($stopResult.exitCode): $($stopResult.output -join ' ')"
            }
            if (-not $sessionStarted -and $stopResult.exitCode -ne 0) {
                $queryResult = Invoke-A4SLogman -Arguments @('query', $sessionName, '-ets')
                try {
                    $queryResult.output | Set-Content -LiteralPath (Join-Path $resolvedOutputDirectory 'session-query-after-failed-start.txt') -Encoding UTF8
                } catch { [void]$artifactErrors.Add("Could not write session-query-after-failed-start.txt: $($_.Exception.Message)") }
                if ($queryResult.exitCode -eq 0) {
                    throw "The failed create attempt left ETW session '$sessionName' running, and the unconditional stop request did not remove it."
                }
            }
        } catch { $stopError = $_ }
    }
}

try {
    [void](Assert-A4SResidentContext -ExpectedHostWindow $hostWindow `
        -ExpectedHostProcessId $residentHostProcessId -ExpectedHostStartTicks $residentHostStartTicks `
        -ExpectedExplorerProcessId $explorerProcessId -ExpectedExplorerStartTicks $explorerStartTicks `
        -ExpectedLogonId $observerLogonId)
    $postHostSha256 = (Get-FileHash -LiteralPath $expectedHost -Algorithm SHA256).Hash
    $postDllSha256 = (Get-FileHash -LiteralPath $expectedDll -Algorithm SHA256).Hash
    $postProductRegistration = Get-A4SProductDirectoryRegistration -ProductDirectory $resolvedProductDirectory
    if ($postProductRegistration.kind -ne $productRegistration.kind -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$postProductRegistration.activeSlot, [string]$productRegistration.activeSlot) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($preflightHostSha256, $postHostSha256) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($preflightDllSha256, $postDllSha256)) {
        throw 'A staged product binary changed while the trace was running.'
    }
    if (Test-Path -LiteralPath $startAllBackRegistryPath) {
        $postStartAllBackDisabledState = Get-ItemPropertyValue -LiteralPath $startAllBackRegistryPath -Name Disabled -ErrorAction SilentlyContinue
        if ($null -eq $postStartAllBackDisabledState -or [int]$postStartAllBackDisabledState -ne 1) {
            throw 'StartAllBack became enabled while the trace was running.'
        }
    } elseif ($null -ne $startAllBackDisabledState) {
        throw 'StartAllBack registry state changed while the trace was running.'
    }
    $postMappedDlls = @($explorer.Modules | Where-Object { $_.ModuleName -ieq 'A4SMenu.dll' })
    $postMappedDllPaths = @($postMappedDlls | ForEach-Object { [IO.Path]::GetFullPath($_.FileName) })
    if ($postMappedDlls.Count -ne 1 -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($postMappedDllPaths[0], $expectedDll)) {
        throw "The exact Explorer A4SMenu.dll mapping changed during the trace; found '$($postMappedDllPaths -join '; ')'."
    }
    $postHostLoadedIdentity = [A4SRuntimeTraceNative]::LoadedImageIdentity(
        $residentHostProcessId, $residentHost.MainModule.BaseAddress)
    $postDllLoadedIdentity = [A4SRuntimeTraceNative]::LoadedImageIdentity(
        $explorerProcessId, $postMappedDlls[0].BaseAddress)
    if (-not [StringComparer]::Ordinal.Equals($hostFileIdentity, $postHostLoadedIdentity) -or
        -not [StringComparer]::Ordinal.Equals($dllFileIdentity, $postDllLoadedIdentity)) {
        throw 'A resident product image changed identity while the trace was running.'
    }
    $postCompetingModules = @($explorer.Modules | Where-Object { $_.ModuleName -match '(?i)^(?:Start(?:AllBack|IsBack).*|(?:Classic)?StartMenuDLL)\.dll$' })
    if ($postCompetingModules.Count -ne 0) { throw 'A competing StartAllBack/StartIsBack/Open-Shell module appeared during the trace.' }
} catch { $integrityError = $_ }

if ($stopError) {
    $details = @(
        "ETW session cleanup failed for '$sessionName': $($stopError.Exception.Message)"
        if ($captureError) { "Capture error: $($captureError.Exception.Message)" }
        if ($cleanupError) { "Menu cleanup error: $($cleanupError.Exception.Message)" }
        if ($integrityError) { "Integrity error: $($integrityError.Exception.Message)" }
        $artifactErrors
    ) -join ' '
    throw "$details Capture directory: '$resolvedOutputDirectory'."
}
if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf) -or (Get-Item -LiteralPath $etlPath).Length -eq 0) {
    $reason = @(
        if ($captureError) { $captureError.Exception.Message } else { 'The ETW logger produced no file data.' }
        if ($cleanupError) { "Menu cleanup: $($cleanupError.Exception.Message)" }
        if ($integrityError) { "Integrity: $($integrityError.Exception.Message)" }
        $artifactErrors
    ) -join ' '
    throw "No usable raw ETL was produced. Capture directory: '$resolvedOutputDirectory'. $reason"
}

$coldSampleCount = if ($OperatorAttestsFirstCapturedCycleIsCold) { 1 } else { 0 }
$conversionError = $null
try {
    $conversionArguments = @{
        EtlPath = $etlPath
        ExpectedProcessId = $explorerProcessId
        ColdSampleCount = $coldSampleCount
        ExpectedCycleCount = $(if ($ManualInteractionSeconds -gt 0) { 0 } else { $CapturedCycles })
        WarmOpenTargetMilliseconds = $WarmOpenTargetMilliseconds
        RefreshRateHz = $RefreshRateHz
        OutputPath = $reportPath
    }
    if ($ManualInteractionSeconds -gt 0) {
        $conversionArguments['MinimumWarmSampleCount'] = 1
        $conversionArguments['MinimumCloseSampleCount'] = 1
    }
    if ($EnforceTargets) { $conversionArguments['EnforceTargets'] = $true }
    [void](& (Join-Path $PSScriptRoot 'Convert-A4SRuntimeTrace.ps1') @conversionArguments)
} catch { $conversionError = $_ }

if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    try {
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $currentEtlHash = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$report.source.sha256, $currentEtlHash)) {
            throw 'The raw ETL changed after conversion; refusing to publish capture metadata.'
        }
        if ($report.source.tracerptXmlPath) {
            $currentXmlHash = (Get-FileHash -LiteralPath ([string]$report.source.tracerptXmlPath) -Algorithm SHA256).Hash
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$report.source.tracerptXmlSha256, $currentXmlHash)) {
                throw 'The decoded tracerpt XML changed after conversion; refusing to publish capture metadata.'
            }
        }
        $capture = [pscustomobject][ordered]@{
            sessionName = $sessionName
            providerMode = 'real-time plus sequential ETL file'
            startedUtc = if ($startedUtc) { $startedUtc.ToString('o') } else { $null }
            stoppedUtc = if ($stoppedUtc) { $stoppedUtc.ToString('o') } else { $null }
            requestedCycles = $CapturedCycles
            completedCycles = $completedCycles
            warmupCycles = $WarmupCycles
            manualInteractionSeconds = $ManualInteractionSeconds
            tracePurpose = if ($ManualInteractionSeconds -gt 0) { 'manual Programs/search/interaction phase capture; target enforcement disabled' } else { 'automated open/close target capture' }
            refreshRateHz = $RefreshRateHz
            refreshRateSource = $refreshRateSource
            observedNominalRefreshRateHz = $observedNominalRefreshRateHz
            explorerProcessId = $explorerProcessId
            explorerStartTimeUtc = $explorer.StartTime.ToUniversalTime().ToString('o')
            residentHostProcessId = $residentHostProcessId
            residentHostStartTimeUtc = $residentHost.StartTime.ToUniversalTime().ToString('o')
            observerSessionId = $observerSessionId
            logonId = $observerLogonId
            startAllBackDisabled = if ($null -eq $startAllBackDisabledState) { 'notInstalledOrUnconfigured' } else { [int]$startAllBackDisabledState }
            productDirectory = $resolvedProductDirectory
            productRegistration = $productRegistration
            hostPath = $expectedHost
            hostSha256 = $preflightHostSha256
            hostFileIdentity = $hostFileIdentity
            hostLoadedIdentity = $hostLoadedIdentity
            dllPath = $expectedDll
            dllSha256 = $preflightDllSha256
            dllFileIdentity = $dllFileIdentity
            dllLoadedIdentity = $dllLoadedIdentity
            captureError = if ($captureError) { $captureError.Exception.Message } else { $null }
            cleanupError = if ($cleanupError) { $cleanupError.Exception.Message } else { $null }
            integrityError = if ($integrityError) { $integrityError.Exception.Message } else { $null }
            artifactErrors = @($artifactErrors)
            rawEtlSha256 = $currentEtlHash
        }
        $report | Add-Member -NotePropertyName capture -NotePropertyValue $capture -Force
        Write-A4SJsonAtomicallyReplacing -Path $reportPath -Value $report
    } catch {
        [void]$artifactErrors.Add("Could not enrich the runtime report with capture metadata: $($_.Exception.Message)")
    }
}

$terminalErrors = [Collections.Generic.List[string]]::new()
if ($conversionError) { [void]$terminalErrors.Add("ETL parsing/target evaluation failed: $($conversionError.Exception.Message)") }
if ($captureError) { [void]$terminalErrors.Add("Capture ended early after $completedCycles/$CapturedCycles cycles: $($captureError.Exception.Message)") }
if ($cleanupError) { [void]$terminalErrors.Add("Final menu cleanup failed: $($cleanupError.Exception.Message)") }
if ($integrityError) { [void]$terminalErrors.Add("Resident/staged binary integrity validation failed: $($integrityError.Exception.Message)") }
foreach ($artifactError in $artifactErrors) { [void]$terminalErrors.Add($artifactError) }
if ($terminalErrors.Count) {
    throw "A4S runtime trace did not complete authoritatively. Raw ETL and any derived artifacts are in '$resolvedOutputDirectory'. $($terminalErrors -join ' ')"
}

Write-Output $reportPath
