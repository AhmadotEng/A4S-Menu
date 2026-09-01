<#
.SYNOPSIS
Captures read-only evidence for one A4S Menu installer lifecycle checkpoint.

.DESCRIPTION
This tool does not launch setup, stop the host, restart Explorer, or write to
the A4S Menu install/registry locations. It records current-user product
registration, A4S processes, Explorer-loaded A4S modules, and the complete
per-user install-root inventory in a timestamped JSON file.

.EXAMPLE
.\tools\Capture-A4SInstallerCheckpoint.ps1 -Label clean-boundary
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
    [string] $Label,

    [string] $EvidenceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Run installer checkpoint capture from 64-bit PowerShell.'
}

if (-not $PSBoundParameters.ContainsKey('EvidenceDirectory')) {
    $EvidenceDirectory = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\build\evidence\installer-step5-live'))
}

$installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu'))
$cleanupHelperPath = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'A4SMenuCleanup.exe'))
$stateSubKey = 'Software\A4SMenu'
$lifecycleSubKey = 'Software\A4SMenuLifecycle'
$runSubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$runOnceSubKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
$uninstallSubKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu'

function Convert-RegistryData {
    param(
        [Parameter(Mandatory)] $Data,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind] $Kind
    )

    if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
        return [Convert]::ToBase64String([byte[]]$Data)
    }
    if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) {
        return @([string[]]$Data)
    }
    return $Data
}

function Get-RegistryTreeRecord {
    param([Parameter(Mandatory)][string] $SubKey)

    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    if ($null -eq $root) {
        return [ordered]@{ SubKey = $SubKey; Present = $false; Nodes = @() }
    }

    $nodes = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[object]]::new()
    $pending.Push([pscustomobject]@{ Key = $root; RelativePath = '' })
    try {
        while ($pending.Count) {
            $current = $pending.Pop()
            $key = $current.Key
            $relative = [string]$current.RelativePath
            try {
                $values = [Collections.Generic.List[object]]::new()
                foreach ($name in @($key.GetValueNames() | Sort-Object)) {
                    $kind = $key.GetValueKind($name)
                    $raw = $key.GetValue($name, $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $values.Add([ordered]@{
                        Name = [string]$name
                        Kind = $kind.ToString()
                        Data = Convert-RegistryData -Data $raw -Kind $kind
                    })
                }
                $nodes.Add([ordered]@{ RelativePath = $relative; Values = @($values) })

                foreach ($childName in @($key.GetSubKeyNames() | Sort-Object -Descending)) {
                    $child = $key.OpenSubKey($childName, $false)
                    if ($null -eq $child) { continue }
                    $childRelative = if ($relative) { "$relative\$childName" } else { $childName }
                    $pending.Push([pscustomobject]@{ Key = $child; RelativePath = $childRelative })
                }
            }
            finally {
                if (-not [object]::ReferenceEquals($key, $root)) { $key.Dispose() }
            }
        }
    }
    finally { $root.Dispose() }

    return [ordered]@{ SubKey = $SubKey; Present = $true; Nodes = @($nodes) }
}

function Get-RegistryValueRecord {
    param(
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)][string] $Name
    )

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    if ($null -eq $key) {
        return [ordered]@{ SubKey = $SubKey; Name = $Name; Present = $false }
    }
    try {
        if ($key.GetValueNames() -notcontains $Name) {
            return [ordered]@{ SubKey = $SubKey; Name = $Name; Present = $false }
        }
        $kind = $key.GetValueKind($Name)
        $raw = $key.GetValue($Name, $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [ordered]@{
            SubKey = $SubKey
            Name = $Name
            Present = $true
            Kind = $kind.ToString()
            Data = Convert-RegistryData -Data $raw -Kind $kind
        }
    }
    finally { $key.Dispose() }
}

function Get-FileRecord {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RelativePath
    )

    $item = Get-Item -LiteralPath $Path -Force
    $version = $null
    try { $version = $item.VersionInfo.ProductVersion } catch {}
    return [ordered]@{
        RelativePath = $RelativePath
        Bytes = [int64]$item.Length
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash
        ProductVersion = $version
        LastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Get-StandaloneFileRecord {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ Path = $Path; Present = $false }
    }

    $item = Get-Item -LiteralPath $Path -Force
    $isDirectory = [bool]$item.PSIsContainer
    $isReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    $record = [ordered]@{
        Path = $item.FullName
        Present = $true
        IsDirectory = $isDirectory
        IsReparsePoint = $isReparsePoint
    }
    if (-not $isDirectory -and -not $isReparsePoint) {
        $file = Get-FileRecord -Path $item.FullName -RelativePath $item.FullName
        $record.Bytes = $file.Bytes
        $record.Sha256 = $file.Sha256
        $record.ProductVersion = $file.ProductVersion
        $record.LastWriteUtc = $file.LastWriteUtc
    }
    return $record
}

function Get-InstallInventory {
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [ordered]@{
            Root = $Root
            Present = $false
            Directories = @()
            Files = @()
            ReparsePoints = @()
        }
    }

    $directories = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $reparsePoints = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object FullName)) {
            $relative = $item.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $reparsePoints.Add($relative)
                continue
            }
            if ($item.PSIsContainer) {
                $directories.Add($relative)
                $pending.Push($item.FullName)
                continue
            }
            $files.Add((Get-FileRecord -Path $item.FullName -RelativePath $relative))
        }
    }
    return [ordered]@{
        Root = $Root
        Present = $true
        Directories = @($directories | Sort-Object)
        Files = @($files | Sort-Object RelativePath)
        ReparsePoints = @($reparsePoints | Sort-Object)
    }
}

function Get-TaskbarExplorerProcessId {
    if (-not ('A4SCheckpointNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class A4SCheckpointNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}
'@
    }

    $taskbar = [A4SCheckpointNativeMethods]::FindWindow('Shell_TrayWnd', $null)
    if ($taskbar -eq [IntPtr]::Zero) { return [uint32]0 }
    [uint32]$processId = 0
    [void][A4SCheckpointNativeMethods]::GetWindowThreadProcessId($taskbar, [ref]$processId)
    return $processId
}

function Get-ProcessRecords {
    $names = @('A4SMenuHost.exe', 'A4SMenuSetup.exe', 'A4SMenuCleanup.exe')
    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in $names })) {
        $records.Add([ordered]@{
            Name = [string]$process.Name
            ProcessId = [uint32]$process.ProcessId
            ParentProcessId = [uint32]$process.ParentProcessId
            ExecutablePath = [string]$process.ExecutablePath
            CommandLine = [string]$process.CommandLine
        })
    }
    return @($records | Sort-Object Name, ProcessId)
}

function Get-ExplorerRecord {
    param([Parameter(Mandatory)][uint32] $TaskbarProcessId)

    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $records = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId })) {
        $modules = [Collections.Generic.List[object]]::new()
        $moduleError = $null
        try {
            foreach ($module in @($process.Modules | Where-Object {
                        $_.ModuleName -ieq 'A4SMenu.dll'
                    })) {
                $modules.Add((Get-FileRecord -Path $module.FileName -RelativePath $module.FileName))
            }
        }
        catch { $moduleError = $_.Exception.Message }
        $records.Add([ordered]@{
            ProcessId = [uint32]$process.Id
            IsTaskbarOwner = [uint32]$process.Id -eq $TaskbarProcessId
            StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            A4SModules = @($modules)
            ModuleInspectionError = $moduleError
        })
    }
    return @($records | Sort-Object ProcessId)
}

function Get-ObjectSha256 {
    param([Parameter(Mandatory)] $Value)
    $json = $Value | ConvertTo-Json -Depth 64 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') }
    finally { $sha.Dispose() }
}

$evidenceRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($evidenceRoot.StartsWith($installRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase) -or
    $evidenceRoot.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidenceDirectory must remain outside the A4S Menu install root.'
}
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null

$state = Get-RegistryTreeRecord -SubKey $stateSubKey
$lifecycle = Get-RegistryTreeRecord -SubKey $lifecycleSubKey
$registration = [ordered]@{
    Run = Get-RegistryValueRecord -SubKey $runSubKey -Name 'A4SMenu'
    CleanupRunOnce = Get-RegistryValueRecord -SubKey $runOnceSubKey -Name '!A4SMenuCleanup'
    RecoveryRunOnce = Get-RegistryValueRecord -SubKey $runOnceSubKey -Name '!A4SMenuServicingRecovery'
    Uninstall = Get-RegistryTreeRecord -SubKey $uninstallSubKey
}
$inventory = Get-InstallInventory -Root $installRoot
$cleanupHelper = Get-StandaloneFileRecord -Path $cleanupHelperPath
$taskbarExplorerProcessId = Get-TaskbarExplorerProcessId
$snapshot = [ordered]@{
    SchemaVersion = 2
    Label = $Label
    CapturedUtc = [DateTime]::UtcNow.ToString('o')
    Machine = [ordered]@{
        OsVersion = [Environment]::OSVersion.Version.ToString()
        Is64BitProcess = [Environment]::Is64BitProcess
        SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        TaskbarExplorerProcessId = $taskbarExplorerProcessId
    }
    Registry = [ordered]@{
        State = $state
        Lifecycle = $lifecycle
        Registration = $registration
    }
    InstallInventory = $inventory
    CleanupHelper = $cleanupHelper
    Processes = @(Get-ProcessRecords)
    Explorers = @(Get-ExplorerRecord -TaskbarProcessId $taskbarExplorerProcessId)
}
$snapshot.Fingerprints = [ordered]@{
    StateSha256 = Get-ObjectSha256 $state
    LifecycleSha256 = Get-ObjectSha256 $lifecycle
    RegistrationSha256 = Get-ObjectSha256 $registration
    InstallInventorySha256 = Get-ObjectSha256 $inventory
    CleanupHelperSha256 = Get-ObjectSha256 $cleanupHelper
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $evidenceRoot "$stamp-$Label.json"
$json = $snapshot | ConvertTo-Json -Depth 64
[IO.File]::WriteAllText($path, $json + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))

Write-Host "A4S installer checkpoint: $path"
Write-Host "  A4S processes: $(@($snapshot.Processes).Count)"
$explorerModuleCount = 0
foreach ($explorer in @($snapshot.Explorers)) {
    $explorerModuleCount += @($explorer.A4SModules).Count
}
Write-Host "  Explorer A4S modules: $explorerModuleCount"
Write-Host "  Taskbar Explorer PID: $($snapshot.Machine.TaskbarExplorerProcessId)"
Write-Host "  Install files: $(@($snapshot.InstallInventory.Files).Count)"
Write-Host "  Cleanup helper present: $($snapshot.CleanupHelper.Present)"
Write-Output $path
