[CmdletBinding()]
param(
    [switch] $AllowExplorerInjection,
    [ValidateRange(5, 120)]
    [int] $ReadyTimeoutSeconds = 30,
    [ValidateRange(2, 30)]
    [int] $MenuTimeoutSeconds = 8,
    [ValidateRange(2, 30)]
    [int] $StopTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this x64 lifecycle test from 64-bit PowerShell so Explorer modules can be verified.'
}

if (-not $AllowExplorerInjection) {
    throw @'
This is an Explorer-mutating lifecycle test. It injects the staged A4SMenu.dll
into the live taskbar Explorer. Re-run explicitly with -AllowExplorerInjection.
The script never restarts Explorer and never uses same-process --rehook.
'@
}

if (-not ('A4SProductLifecycleNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class A4SProductLifecycleNative
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

    public static uint GetTaskbarProcessId()
    {
        IntPtr taskbar = FindWindowW("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero)
            throw new InvalidOperationException("Shell_TrayWnd was not found.");
        uint processId;
        if (GetWindowThreadProcessId(taskbar, out processId) == 0 || processId == 0)
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(), "Could not resolve the taskbar Explorer process.");
        return processId;
    }

    public static IntPtr[] GetVisibleTopLevelWindows(string expectedClassName)
    {
        List<IntPtr> matches = new List<IntPtr>();
        bool enumerated = EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window))
                return true;
            StringBuilder className = new StringBuilder(256);
            if (GetClassNameW(window, className, className.Capacity) > 0 &&
                String.Equals(className.ToString(), expectedClassName, StringComparison.Ordinal))
                matches.Add(window);
            return true;
        }, IntPtr.Zero);
        if (!enumerated)
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(), "Could not enumerate top-level windows.");
        return matches.ToArray();
    }
}
'@
}

function Invoke-A4SHostCommand {
    param(
        [Parameter(Mandatory)][string] $HostExecutable,
        [Parameter(Mandatory)][string] $Argument,
        [ValidateRange(100, 30000)][int] $TimeoutMilliseconds = 5000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $HostExecutable
    $startInfo.Arguments = $Argument
    $startInfo.WorkingDirectory = Split-Path -Parent $HostExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $commandProcess = [Diagnostics.Process]::Start($startInfo)
    if (-not $commandProcess) {
        throw "Could not start $HostExecutable $Argument."
    }
    try {
        if (-not $commandProcess.WaitForExit($TimeoutMilliseconds)) {
            throw "A4SMenuHost $Argument did not exit within $TimeoutMilliseconds ms."
        }
        return $commandProcess.ExitCode
    }
    finally {
        $commandProcess.Dispose()
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
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    return [bool](& $Condition)
}

function Get-A4SProcessPath {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)

    $Process.Refresh()
    if ($Process.HasExited) {
        throw "Process $($Process.Id) exited before its executable path was verified."
    }
    return [IO.Path]::GetFullPath($Process.MainModule.FileName)
}

function Get-A4SModulePaths {
    param([Parameter(Mandatory)][uint32] $ProcessId)

    $targetProcess = [Diagnostics.Process]::GetProcessById([int]$ProcessId)
    try {
        return @($targetProcess.Modules | ForEach-Object {
            [IO.Path]::GetFullPath($_.FileName)
        })
    }
    finally {
        $targetProcess.Dispose()
    }
}

function Test-A4SPathEqual {
    param(
        [Parameter(Mandatory)][string] $First,
        [Parameter(Mandatory)][string] $Second
    )

    return [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath($First),
        [IO.Path]::GetFullPath($Second))
}

function Get-VisibleA4SMenuWindows {
    return @([A4SProductLifecycleNative]::GetVisibleTopLevelWindows(
        'A4SMenu.CMenuContainer'))
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stageDirectory = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage\A4SProduct'))
$hostExecutable = [IO.Path]::GetFullPath((Join-Path $stageDirectory 'A4SMenuHost.exe'))
$menuDll = [IO.Path]::GetFullPath((Join-Path $stageDirectory 'A4SMenu.dll'))
$serviceNotActive = 1062
$productHostProcess = $null
$hostStartedByTest = $false
$stopVerified = $false

Write-Host 'Running the non-injecting static product gate first...'
& (Join-Path $PSScriptRoot 'Test-A4SProduct.ps1')

foreach ($requiredPath in @($hostExecutable, $menuDll)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing staged product binary: $requiredPath"
    }
}

$initialStatus = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--status'
if ($initialStatus -ne $serviceNotActive) {
    throw "An A4SMenuHost is already active or not responding in this session (status $initialStatus). Stop it safely before this test."
}

$taskbarProcessId = [A4SProductLifecycleNative]::GetTaskbarProcessId()
$initialExplorerModules = @(Get-A4SModulePaths -ProcessId $taskbarProcessId)
$existingMenuModules = @($initialExplorerModules | Where-Object {
    [IO.Path]::GetFileName($_) -ieq 'A4SMenu.dll'
})
if ($existingMenuModules.Count -ne 0) {
    throw @"
A4SMenu.dll is already mapped in taskbar Explorer PID ${taskbarProcessId}:
$($existingMenuModules -join "`n")
The mapping may be a correctly disarmed pin. Restart Explorer manually before
repeating this lifecycle test. This script will not restart Explorer or use
same-process --rehook.
"@
}

if ((Get-VisibleA4SMenuWindows).Count -ne 0) {
    throw 'An A4S product menu window is already visible before the host starts.'
}

try {
    Write-Host "Starting staged host: $hostExecutable"
    $hostStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $hostStartInfo.FileName = $hostExecutable
    $hostStartInfo.WorkingDirectory = $stageDirectory
    $hostStartInfo.UseShellExecute = $false
    $hostStartInfo.CreateNoWindow = $true
    $productHostProcess = [Diagnostics.Process]::Start($hostStartInfo)
    if (-not $productHostProcess) {
        throw 'Could not start the staged A4SMenuHost.exe.'
    }
    $hostStartedByTest = $true

    $ready = Wait-A4SCondition -TimeoutSeconds $ReadyTimeoutSeconds -Condition {
        if ($productHostProcess.HasExited) {
            return $false
        }
        $status = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--status'
        return $status -eq 0
    } -PollMilliseconds 150
    if (-not $ready) {
        $lastStatus = if ($productHostProcess.HasExited) {
            "host exited with code $($productHostProcess.ExitCode)"
        }
        else {
            "status code $(Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--status')"
        }
        throw "A4SMenuHost did not reach READY within $ReadyTimeoutSeconds seconds ($lastStatus)."
    }

    $actualHostPath = Get-A4SProcessPath -Process $productHostProcess
    if (-not (Test-A4SPathEqual -First $actualHostPath -Second $hostExecutable)) {
        throw "The resident host path is not the staged host. Expected '$hostExecutable'; found '$actualHostPath'."
    }

    $readyTaskbarProcessId = [A4SProductLifecycleNative]::GetTaskbarProcessId()
    if ($readyTaskbarProcessId -ne $taskbarProcessId) {
        throw "Explorer changed during initialization (PID $taskbarProcessId -> $readyTaskbarProcessId)."
    }
    $readyModules = @(Get-A4SModulePaths -ProcessId $taskbarProcessId)
    $exactMappings = @($readyModules | Where-Object {
        Test-A4SPathEqual -First $_ -Second $menuDll
    })
    if ($exactMappings.Count -ne 1) {
        $namedMappings = @($readyModules | Where-Object {
            [IO.Path]::GetFileName($_) -ieq 'A4SMenu.dll'
        })
        throw "Expected exactly one '$menuDll' mapping in Explorer PID $taskbarProcessId; named mappings: '$($namedMappings -join '; ')'."
    }
    Write-Host "READY: staged host PID $($productHostProcess.Id), taskbar Explorer PID $taskbarProcessId, exact DLL mapping verified."

    $toggleOpenCode = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--toggle'
    if ($toggleOpenCode -ne 0) {
        throw "Opening --toggle failed with exit code $toggleOpenCode."
    }
    if (-not (Wait-A4SCondition -TimeoutSeconds $MenuTimeoutSeconds -Condition {
        (Get-VisibleA4SMenuWindows).Count -ne 0
    })) {
        throw "No visible A4SMenu.CMenuContainer window appeared within $MenuTimeoutSeconds seconds."
    }
    Write-Host 'Toggle-open verified by visible A4SMenu.CMenuContainer.'

    $toggleCloseCode = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--toggle'
    if ($toggleCloseCode -ne 0) {
        throw "Closing --toggle failed with exit code $toggleCloseCode."
    }
    if (-not (Wait-A4SCondition -TimeoutSeconds $MenuTimeoutSeconds -Condition {
        (Get-VisibleA4SMenuWindows).Count -eq 0
    })) {
        throw "The visible A4S menu did not close within $MenuTimeoutSeconds seconds."
    }
    Write-Host 'Toggle-close verified.'

    $exitCode = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--exit'
    if ($exitCode -ne 0) {
        throw "A4SMenuHost --exit failed with exit code $exitCode."
    }
    if (-not $productHostProcess.WaitForExit($StopTimeoutSeconds * 1000)) {
        throw "The resident host did not exit within $StopTimeoutSeconds seconds after logical disarm."
    }
    if (-not (Wait-A4SCondition -TimeoutSeconds $MenuTimeoutSeconds -Condition {
        (Get-VisibleA4SMenuWindows).Count -eq 0
    })) {
        throw 'An A4S menu window remained visible after host shutdown.'
    }
    $stoppedStatus = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--status'
    if ($stoppedStatus -ne $serviceNotActive) {
        throw "Expected a stopped host after --exit; --status returned $stoppedStatus."
    }

    $finalTaskbarProcessId = [A4SProductLifecycleNative]::GetTaskbarProcessId()
    if ($finalTaskbarProcessId -ne $taskbarProcessId) {
        throw "Explorer changed during shutdown (PID $taskbarProcessId -> $finalTaskbarProcessId), so the pinned-map assertion is inconclusive."
    }
    $finalModules = @(Get-A4SModulePaths -ProcessId $taskbarProcessId)
    $pinnedMappings = @($finalModules | Where-Object {
        Test-A4SPathEqual -First $_ -Second $menuDll
    })
    if ($pinnedMappings.Count -ne 1) {
        throw "The expected pinned '$menuDll' mapping was not retained after logical disarm."
    }

    $stopVerified = $true
    Write-Host 'PASS: host and menu closed; the exact DLL remains pinned and logically inert in Explorer as designed.'
    Write-Host 'Restart Explorer manually before another lifecycle run. This script did not restart Explorer and never used --rehook.'
}
finally {
    if ($hostStartedByTest -and $productHostProcess) {
        $productHostProcess.Refresh()
        if (-not $productHostProcess.HasExited) {
            Write-Warning 'The test did not reach its verified stop. Requesting the supported logical --exit path once; the process will not be killed.'
            try {
                $cleanupExitCode = Invoke-A4SHostCommand -HostExecutable $hostExecutable -Argument '--exit'
                if ($cleanupExitCode -eq 0) {
                    [void]$productHostProcess.WaitForExit($StopTimeoutSeconds * 1000)
                }
            }
            catch {
                Write-Warning "The cleanup --exit request failed: $_"
            }
            $productHostProcess.Refresh()
            if (-not $productHostProcess.HasExited) {
                Write-Warning 'A4SMenuHost is still running. Do not force-kill it; inspect its state or restart Explorer manually when safe.'
            }
        }
        $productHostProcess.Dispose()
    }
    if (-not $stopVerified) {
        Write-Warning 'Lifecycle validation did not complete. No Explorer restart or same-process --rehook was attempted.'
    }
}
