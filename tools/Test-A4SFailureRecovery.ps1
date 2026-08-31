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
$serviceNotActive = 1062
$hostStatusReadyExit = 0
$hostStatusFailed = 4
$hostStatusSafetyDisabled = 6
$crashThreshold = 3
$crashWindowSeconds = 180
$script:Evidence = $null
$script:EvidenceFile = $null

function Initialize-A4SFailureRecoveryNative {
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run executable qualification from 64-bit PowerShell so the x64 taskbar Explorer module list is authoritative.'
    }
    if (-not ('A4SFailureRecoveryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class A4SFailureRecoveryNative
{
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

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "$Description is not a regular file: $Path"
    }
    return [IO.Path]::GetFullPath($item.FullName)
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent
    )

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    return $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeTemporaryRoot {
    param([Parameter(Mandatory)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not (Test-PathWithin -Path $fullPath -Parent $tempRoot) -or
        [StringComparer]::OrdinalIgnoreCase.Equals($fullPath.TrimEnd('\'), $tempRoot.TrimEnd('\'))) {
        throw "Refusing a temporary operation outside the OS temporary directory: $fullPath"
    }
    if ([IO.Path]::GetFileName($fullPath) -notlike 'A4SFailureRecovery-*') {
        throw "Refusing a temporary operation without the A4SFailureRecovery prefix: $fullPath"
    }
    return $fullPath
}

function New-A4STemporaryRoot {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('A4SFailureRecovery-' + [Guid]::NewGuid().ToString('N'))
    $path = Assert-SafeTemporaryRoot -Path $path
    [void](New-Item -ItemType Directory -Path $path -ErrorAction Stop)
    return $path
}

function Remove-A4STemporaryRoot {
    param([Parameter(Mandatory)][string] $Path)

    $safePath = Assert-SafeTemporaryRoot -Path $Path
    if (Test-Path -LiteralPath $safePath) {
        Remove-Item -LiteralPath $safePath -Recurse -Force -ErrorAction Stop
    }
}

function Write-DurableText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text
    )

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
    }
    $temporary = Join-Path $directory ('.a4s-atomic-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        [A4SFailureRecoveryNative]::ReplaceFileAtomically($temporary, $Path)
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
        $base = Join-Path $env:LOCALAPPDATA 'A4SMenuQualification\FailureRecovery'
        $bundle = Join-Path $base ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
        $file = Join-Path $bundle 'evidence.json'
    }
    else {
        $file = [IO.Path]::GetFullPath($RequestedPath)
        $bundle = Split-Path -Parent $file
    }
    if (Test-PathWithin -Path $bundle -Parent $repoRoot) {
        throw 'Failure/recovery evidence and HostSafety backups must remain outside the source repository.'
    }
    if ($Mode -eq 'live-explorer-crash-guard' -and
        (Test-PathWithin -Path $bundle -Parent ([IO.Path]::GetTempPath()))) {
        throw 'Live HostSafety recovery data must be durable and cannot be placed under the temporary directory.'
    }
    if (Test-Path -LiteralPath $file) {
        throw "Refusing to overwrite an existing qualification evidence file: $file"
    }
    [void](New-Item -ItemType Directory -Path $bundle -Force -ErrorAction Stop)
    $script:EvidenceFile = $file
    $script:Evidence = [ordered]@{
        schemaVersion = 1
        mode = $Mode
        startedUtc = Get-UtcText
        updatedUtc = Get-UtcText
        sourceCommit = (& git -C $repoRoot rev-parse HEAD 2>$null)
        machine = $env:COMPUTERNAME
        user = [Environment]::UserName
        sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        outcome = 'running'
        checkpoints = [Collections.ArrayList]::new()
        cases = [Collections.ArrayList]::new()
        recovery = [ordered]@{}
        errors = [Collections.ArrayList]::new()
    }
    Save-Evidence
    return [IO.Path]::GetFullPath($bundle)
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
        'MultiString' { @([string[]]$value); break }
        'DWord' { [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$value), 0); break }
        'QWord' { [BitConverter]::ToUInt64([BitConverter]::GetBytes([int64]$value), 0); break }
        default { [string]$value; break }
    }
    return [ordered]@{ name = $Name; kind = $kind.ToString(); value = $encoded }
}

function Get-HostSafetySnapshot {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($hostSafetySubKey, $false)
    if ($null -eq $key) {
        return [ordered]@{ exists = $false; values = @() }
    }
    try {
        $records = @($key.GetValueNames() | Sort-Object | ForEach-Object {
            Get-RegistryValueRecord -Key $key -Name $_
        })
        return [ordered]@{ exists = $true; values = $records }
    }
    finally { $key.Dispose() }
}

function Compare-HostSafetySnapshot {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )
    return (($Expected | ConvertTo-Json -Depth 8 -Compress) -ceq
        ($Actual | ConvertTo-Json -Depth 8 -Compress))
}

function Backup-HostSafety {
    param([Parameter(Mandatory)][string] $Bundle)

    $snapshot = Get-HostSafetySnapshot
    $regFile = Join-Path $Bundle 'HostSafety.reg'
    $regHash = $null
    if ($snapshot.exists) {
        $output = & reg.exe export $hostSafetyRegPath $regFile /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not durably export HostSafety: $($output -join ' ')"
        }
        $stream = [IO.File]::Open($regFile, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        $regHash = (Get-FileHash -LiteralPath $regFile -Algorithm SHA256).Hash
    }
    $postExportSnapshot = Get-HostSafetySnapshot
    if (-not (Compare-HostSafetySnapshot -Expected $snapshot -Actual $postExportSnapshot)) {
        throw 'HostSafety changed while its recovery bundle was being prepared; no Explorer crash is permitted.'
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        createdUtc = Get-UtcText
        registryPath = $hostSafetyRegPath
        snapshot = $snapshot
        regExport = if ($snapshot.exists) { 'HostSafety.reg' } else { $null }
        regExportSha256 = $regHash
    }
    Write-DurableText -Path (Join-Path $Bundle 'HostSafetyBackup.json') `
        -Text ($manifest | ConvertTo-Json -Depth 10)
    return $manifest
}

function Restore-HostSafety {
    param([Parameter(Mandatory)][string] $Bundle)

    $manifestPath = Join-Path ([IO.Path]::GetFullPath($Bundle)) 'HostSafetyBackup.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "HostSafety recovery manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.registryPath -cne $hostSafetyRegPath) {
        throw 'The HostSafety recovery manifest has an unsupported schema or registry target.'
    }

    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($hostSafetySubKey, $false)
    if ($manifest.snapshot.exists) {
        $regFile = Join-Path $Bundle ([string]$manifest.regExport)
        if (-not (Test-Path -LiteralPath $regFile -PathType Leaf)) {
            throw "HostSafety registry export is missing: $regFile"
        }
        $actualHash = (Get-FileHash -LiteralPath $regFile -Algorithm SHA256).Hash
        if ($actualHash -cne [string]$manifest.regExportSha256) {
            throw 'HostSafety.reg changed after the durable backup was recorded.'
        }
        $output = & reg.exe import $regFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not restore HostSafety.reg: $($output -join ' ')"
        }
        $restoredKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            $hostSafetySubKey, $true)
        if ($null -eq $restoredKey) {
            throw 'HostSafety.reg import reported success but the registry key is absent.'
        }
        try { $restoredKey.Flush() } finally { $restoredKey.Dispose() }
    }
    $restored = Get-HostSafetySnapshot
    if (-not (Compare-HostSafetySnapshot -Expected $manifest.snapshot -Actual $restored)) {
        throw 'HostSafety restore did not reproduce the exact pre-test value set.'
    }
    return $restored
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
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "'$Executable $Argument' did not exit within $TimeoutSeconds seconds; it was not force-killed."
        }
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

function Assert-NoResidentA4SHost {
    param([Parameter(Mandatory)][string] $ProbeHost)

    $status = Get-A4SHostStatus -Executable $ProbeHost
    if ($status.exitCode -ne $serviceNotActive) {
        throw "An A4S host mutex/window is already active (status exit $($status.exitCode), '$($status.stdout)')."
    }
    $processes = @(Get-Process -Name 'A4SMenuHost' -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId
    })
    try {
        if ($processes.Count -ne 0) {
            throw "Found $($processes.Count) A4SMenuHost process(es) in the current session despite stopped status."
        }
    }
    finally { $processes | ForEach-Object { $_.Dispose() } }
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
        [string] $Arguments = ''
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
    return [ordered]@{
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

function Assert-RollingCrashGuard {
    param([Parameter(Mandatory)][object] $Snapshot)

    if (-not $Snapshot.exists) {
        throw 'Crash guard did not persist HostSafety after the third Explorer crash.'
    }
    $lookup = @{}
    foreach ($record in $Snapshot.values) { $lookup[[string]$record.name] = $record }
    foreach ($name in @('InjectionDisabled', 'AbnormalExplorerExitCount',
            'AbnormalExplorerExitTimes', 'LastExplorerExitCode')) {
        if (-not $lookup.ContainsKey($name)) { throw "Crash guard omitted HostSafety value '$name'." }
    }
    if ([uint32]$lookup['InjectionDisabled'].value -ne 1 -or
        [uint32]$lookup['AbnormalExplorerExitCount'].value -ne $crashThreshold) {
        throw 'The rolling crash guard did not disable injection at exactly three abnormal exits.'
    }
    $bytes = [Convert]::FromBase64String([string]$lookup['AbnormalExplorerExitTimes'].value)
    if ($bytes.Length -ne 24) { throw 'AbnormalExplorerExitTimes is not the expected three-QWORD record.' }
    $times = @(0, 8, 16 | ForEach-Object { [BitConverter]::ToUInt64($bytes, $_) })
    if (($times | Where-Object { $_ -eq 0 }).Count -ne 0) {
        throw 'The rolling crash record contains an empty timestamp.'
    }
    $windowTicks = [uint64]$crashWindowSeconds * [uint64]10000000
    if ($times[2] -lt $times[0] -or $times[2] - $times[0] -gt $windowTicks) {
        throw 'The three crash timestamps do not fall inside the 180-second rolling guard window.'
    }
    if ([uint32]$lookup['LastExplorerExitCode'].value -eq 0) {
        throw 'The final guarded Explorer termination was recorded as a clean exit.'
    }
    return [ordered]@{ timestamps100ns = $times; span100ns = $times[2] - $times[0] }
}

function Invoke-IsolatedDllFailureQualification {
    param(
        [Parameter(Mandatory)][string] $SourceHost,
        [string] $RequestedEvidencePath
    )

    $sourceHost = Resolve-RegularFile -Path $SourceHost -Description 'A4SMenuHost test input'
    $bundle = New-EvidenceBundle -Mode 'isolated-dll-failures' -RequestedPath $RequestedEvidencePath
    $temporaryRoot = New-A4STemporaryRoot
    $initial = $null
    try {
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

        $caseNames = @('missing', 'corrupt', 'incompatible')
        foreach ($caseName in $caseNames) {
            $caseDirectory = Join-Path $temporaryRoot $caseName
            [void](New-Item -ItemType Directory -Path $caseDirectory -ErrorAction Stop)
            $caseHost = Join-Path $caseDirectory 'A4SMenuHost.exe'
            $caseDll = Join-Path $caseDirectory 'A4SMenu.dll'
            Copy-Item -LiteralPath $sourceHost -Destination $caseHost -ErrorAction Stop

            if ($caseName -eq 'corrupt') {
                [IO.File]::WriteAllBytes($caseDll,
                    [Text.Encoding]::ASCII.GetBytes('A4S deliberate corrupt-DLL qualification input'))
            }
            elseif ($caseName -eq 'incompatible') {
                $systemDll = Resolve-RegularFile -Path (Join-Path $env:SystemRoot 'System32\version.dll') `
                    -Description 'known-loadable non-product DLL'
                Copy-Item -LiteralPath $systemDll -Destination $caseDll -ErrorAction Stop
                if (-not [A4SFailureRecoveryNative]::IsLoadableNonProductDll($caseDll)) {
                    throw 'The incompatible case is not a loadable PE without the A4S exports.'
                }
            }

            $resident = $null
            $stopped = $true
            try {
                Assert-NoResidentA4SHost -ProbeHost $caseHost
                Assert-SameExplorerIdentity -Expected $initial.explorer `
                    -Actual (Get-TaskbarExplorerIdentity) -Label "$caseName pre-start"
                [void](Assert-NoA4SMapping -Explorer $initial.explorer -Label "$caseName pre-start")
                $resident = Start-A4STestHost -Executable $caseHost
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
                [void]$script:Evidence.cases.Add([ordered]@{
                    name = $caseName
                    result = 'pass'
                    hostProcessId = $resident.Id
                    terminalStatusExitCode = $failedStatus.exitCode
                    terminalStatusText = $failedStatus.stdout
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
                    throw "The isolated $caseName test host is not proven stopped; temporary files were retained at '$caseDirectory'."
                }
            }
        }

        $finalExplorer = Get-TaskbarExplorerIdentity
        Assert-SameExplorerIdentity -Expected $initial.explorer -Actual $finalExplorer `
            -Label 'isolated matrix final'
        [void](Assert-NoA4SMapping -Explorer $finalExplorer -Label 'isolated matrix final')
        $finalSafety = Get-HostSafetySnapshot
        if (-not (Compare-HostSafetySnapshot -Expected $initial.hostSafety -Actual $finalSafety)) {
            throw 'The isolated missing/corrupt/incompatible matrix changed HostSafety.'
        }
        $script:Evidence.outcome = 'pass'
        Save-Evidence
        Write-Host "PASS: isolated missing, corrupt, and incompatible DLL failures never injected and Explorer PID $($finalExplorer.pid) remained unchanged."
        Write-Host "Evidence: $script:EvidenceFile"
    }
    catch {
        [void]$script:Evidence.errors.Add($_.Exception.Message)
        $script:Evidence.outcome = 'fail'
        Save-Evidence
        throw
    }
    finally {
        $active = @(Get-Process -Name 'A4SMenuHost' -ErrorAction SilentlyContinue | Where-Object {
            $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId
        })
        try {
            if ($active.Count -eq 0) {
                Remove-A4STemporaryRoot -Path $temporaryRoot
            }
            else {
                Write-Warning "A test host remains active; temporary root retained: $temporaryRoot"
            }
        }
        finally { $active | ForEach-Object { $_.Dispose() } }
    }
}

function Invoke-ValidatedExplorerCrash {
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
        $process.Kill()
        if (-not $process.WaitForExit(15000)) {
            throw "$Label Explorer PID $($current.pid) did not exit after the explicit crash request."
        }
        return [ordered]@{
            label = $Label
            requestedUtc = Get-UtcText
            oldExplorer = $current
            observedExitCode = $process.ExitCode
        }
    }
    finally { $process.Dispose() }
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

    try {
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
            manifest = (Join-Path $bundle 'HostSafetyBackup.json')
            preparedBeforeFirstCrash = $true
            originalHostSafetyExists = [bool]$backup.snapshot.exists
            restored = $false
            instructions = "Run this script with -RecoverHostSafety -RecoveryBundle '$bundle' only after every A4SMenuHost is stopped."
        }
        Save-Evidence

        # Establish an empty crash-guard baseline without loading a valid DLL or
        # installing a hook. This host copy has no sibling A4SMenu.dll.
        $resetDirectory = Join-Path $temporaryRoot 'safety-reset-no-dll'
        [void](New-Item -ItemType Directory -Path $resetDirectory -ErrorAction Stop)
        $resetHost = Join-Path $resetDirectory 'A4SMenuHost.exe'
        Copy-Item -LiteralPath $sourceHost -Destination $resetHost -ErrorAction Stop
        $resetProcess = Start-A4STestHost -Executable $resetHost -Arguments '--reset-safety'
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

        $runtimeDirectory = Join-Path $temporaryRoot 'valid-runtime'
        [void](New-Item -ItemType Directory -Path $runtimeDirectory -ErrorAction Stop)
        $runtimeHost = Join-Path $runtimeDirectory 'A4SMenuHost.exe'
        $runtimeDll = Join-Path $runtimeDirectory 'A4SMenu.dll'
        Copy-Item -LiteralPath $sourceHost -Destination $runtimeHost -ErrorAction Stop
        Copy-Item -LiteralPath $sourceDll -Destination $runtimeDll -ErrorAction Stop
        $script:Evidence.runtime = [ordered]@{
            isolatedDirectory = $runtimeDirectory
            hostPath = $runtimeHost
            hostSha256 = (Get-FileHash -LiteralPath $runtimeHost -Algorithm SHA256).Hash
            dllPath = $runtimeDll
            dllSha256 = (Get-FileHash -LiteralPath $runtimeDll -Algorithm SHA256).Hash
        }
        Save-Evidence

        $resident = Start-A4STestHost -Executable $runtimeHost
        $hostStopped = $false
        [void](Wait-A4SHostStatus -Executable $runtimeHost -ExpectedExitCode $hostStatusReadyExit `
            -TimeoutSeconds $ReconnectTimeoutSeconds -ResidentProcess $resident)
        $ready = Get-A4SCheckpoint -Label 'initial-ready' -HostExecutable $runtimeHost `
            -KnownHostProcessId $resident.Id
        Assert-ExactA4SMapping -Checkpoint $ready -ExpectedDll $runtimeDll
        Add-EvidenceCheckpoint $ready

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

            $termination = Invoke-ValidatedExplorerCrash -ExpectedExplorer $before.explorer `
                -Label "guarded crash $crashIndex of $crashThreshold"
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
                $after.rollingGuard = Assert-RollingCrashGuard -Snapshot $after.hostSafety
            }
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
        $cleanupTermination = Invoke-ValidatedExplorerCrash `
            -ExpectedExplorer $cleanupBefore.explorer -Label 'post-recovery cleanup restart'
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

        # Do not add surprise Explorer terminations after a failed run. A retained
        # mapping is inert after a verified --exit and its exact temporary path is
        # preserved in evidence for a user-controlled restart boundary.
        if (-not $cleanupRestartComplete -and $hostStopped) {
            try {
                $current = Get-TaskbarExplorerIdentity
                $retained = @(Get-A4SModuleRecords -ExplorerProcessId $current.pid)
                if ($retained.Count -ne 0) {
                    [void]$script:Evidence.errors.Add(
                        "A logically inert mapping remains pinned; restart Explorer manually before deleting '$temporaryRoot'.")
                }
            }
            catch {
                [void]$script:Evidence.errors.Add("Could not inspect retained mappings: $($_.Exception.Message)")
            }
        }

        if ($backupPrepared -and $hostStopped) {
            try {
                [void](Restore-HostSafety -Bundle $bundle)
                $script:Evidence.recovery.restored = $true
                $script:Evidence.recovery.restoredUtc = Get-UtcText
            }
            catch {
                [void]$script:Evidence.errors.Add("HostSafety restore failed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        elseif ($backupPrepared) {
            [void]$script:Evidence.errors.Add(
                'HostSafety was not restored while a test host may still be active; use the durable recovery command in evidence.')
        }

        if ($cleanupRestartComplete -and $hostStopped) {
            try { Remove-A4STemporaryRoot -Path $temporaryRoot }
            catch {
                [void]$script:Evidence.errors.Add("Temporary runtime cleanup failed: $($_.Exception.Message)")
                if ($null -eq $operationError) { $operationError = $_ }
            }
        }
        else {
            $script:Evidence.recovery.retainedTemporaryRoot = $temporaryRoot
        }

        $script:Evidence.outcome = if ($null -eq $operationError) { 'pass' } else { 'fail' }
        Save-Evidence
    }

    if ($operationError) { throw $operationError }
    Write-Host 'PASS: two reconnects, exact single mappings, one-menu behavior, the three-crash guard, no-injection fail-safe, reset recovery, and cleanup restart were verified.'
    Write-Host "Evidence: $script:EvidenceFile"
}

switch ($PSCmdlet.ParameterSetName) {
    'Offline' {
        & (Join-Path $PSScriptRoot 'Test-A4SFailureRecoveryContracts.ps1')
        Write-Host 'Offline mode made no runtime, registry, Explorer, staging, or evidence changes.'
        Write-Host 'Use -RunIsolatedDllFailures with -HostPath for temp-only N8 execution.'
        Write-Host 'The live N6/N9 path additionally requires the conspicuous crash switch and exact confirmation text.'
    }
    'Isolated' {
        Initialize-A4SFailureRecoveryNative
        Invoke-IsolatedDllFailureQualification -SourceHost $HostPath `
            -RequestedEvidencePath $EvidencePath
    }
    'Live' {
        Initialize-A4SFailureRecoveryNative
        if (-not $IUnderstandThisWillForceCrashExplorerThreeTimesAndRestartItForCleanup -or
            $ConfirmationText -cne 'I ACCEPT FOUR EXPLORER TERMINATIONS: THREE GUARDED CRASHES AND ONE CLEANUP RESTART') {
            throw 'The exact destructive Explorer confirmation was not supplied.'
        }
        Invoke-LiveFailureRecoveryQualification -SourceHost $HostPath -SourceDll $DllPath `
            -RequestedEvidencePath $EvidencePath
    }
    'Recover' {
        $active = @(Get-Process -Name 'A4SMenuHost' -ErrorAction SilentlyContinue | Where-Object {
            $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId
        })
        try {
            if ($active.Count -ne 0) {
                throw 'Refusing HostSafety recovery while an A4SMenuHost is active in this session. Stop it through --exit first.'
            }
        }
        finally { $active | ForEach-Object { $_.Dispose() } }
        [void](Restore-HostSafety -Bundle $RecoveryBundle)
        Write-Host "HostSafety restored exactly from: $RecoveryBundle"
    }
    default { throw "Unsupported parameter set: $($PSCmdlet.ParameterSetName)" }
}
