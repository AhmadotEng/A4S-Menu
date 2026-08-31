[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Run setup validation from 64-bit PowerShell.'
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "$Path is not a PE image." }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "$Path has an invalid PE signature." }
        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Find-Dumpbin {
    $vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsInstallPath = & $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsInstallPath) { throw 'Visual C++ build tools were not found.' }
    $toolsRoot = Join-Path $vsInstallPath 'VC\Tools\MSVC'
    $toolset = Get-ChildItem -LiteralPath $toolsRoot -Directory |
        Sort-Object { [Version]$_.Name } -Descending |
        Select-Object -First 1
    if (-not $toolset) { throw "No MSVC toolset was found under $toolsRoot." }
    $dumpbinPath = Join-Path $toolset.FullName 'bin\Hostx64\x64\dumpbin.exe'
    if (-not (Test-Path -LiteralPath $dumpbinPath -PathType Leaf)) {
        throw "dumpbin.exe was not found: $dumpbinPath"
    }
    return $dumpbinPath
}

function Get-DependentDllNames {
    param(
        [Parameter(Mandatory)][string] $DumpbinPath,
        [Parameter(Mandatory)][string] $BinaryPath
    )

    $output = (& $DumpbinPath /nologo /dependents $BinaryPath) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect dependencies for $BinaryPath." }
    return @([Regex]::Matches($output, '(?im)^\s+([a-z0-9_.-]+\.(?:dll|ocx))\s*$') |
        ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } |
        Sort-Object -Unique)
}

function Get-RegistryFingerprint {
    $locations = @(
        @{ Path = 'HKCU:\Software\A4SMenu'; Names = $null; Recurse = $true },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Names = @('A4SMenu'); Recurse = $false },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Names = @('!A4SMenuCleanup', '!A4SMenuServicingRecovery'); Recurse = $false },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\A4SMenu'; Names = $null; Recurse = $false }
    )
    $records = [Collections.Generic.List[string]]::new()

    function Add-KeyFingerprint {
        param(
            [Parameter(Mandatory)][string] $Path,
            [AllowNull()][string[]] $Names,
            [Parameter(Mandatory)][bool] $Recurse
        )

        if (-not (Test-Path -LiteralPath $Path)) {
            $records.Add("$Path|<absent>")
            return
        }
        $key = Get-Item -LiteralPath $Path
        $records.Add("$Path|<key>")
        $actualNames = @($key.GetValueNames())
        $selectedNames = if ($null -eq $Names) { @($actualNames | Sort-Object) } else { @($Names | Sort-Object) }
        foreach ($name in $selectedNames) {
            if ($actualNames -inotcontains $name) {
                $records.Add("$Path|$name|<absent>")
                continue
            }
            $kind = $key.GetValueKind($name).ToString()
            $value = $key.GetValue($name, $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $encoded = if ($value -is [byte[]]) {
                [BitConverter]::ToString($value).Replace('-', '')
            }
            elseif ($value -is [string[]]) {
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($value -join "`0")))
            }
            elseif ($null -eq $value) { '<null>' }
            else { [string]$value }
            $records.Add("$Path|$name|$kind|$encoded")
        }
        if ($Recurse) {
            foreach ($child in @(Get-ChildItem -LiteralPath $Path | Sort-Object PSChildName)) {
                Add-KeyFingerprint -Path $child.PSPath -Names $null -Recurse $true
            }
        }
    }

    foreach ($location in $locations) {
        Add-KeyFingerprint -Path $location.Path -Names $location.Names -Recurse $location.Recurse
    }
    return ($records -join "`n")
}

function Get-SourceSection {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $StartMarker,
        [Parameter(Mandatory)][string] $EndMarker
    )

    $start = $Source.IndexOf($StartMarker, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing setup source marker: $StartMarker" }
    $end = $Source.IndexOf($EndMarker, $start + $StartMarker.Length, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw "Missing setup source marker after '$StartMarker': $EndMarker" }
    return $Source.Substring($start, $end - $start)
}

function Assert-SourceOrder {
    param(
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string[]] $Markers
    )

    $offset = 0
    foreach ($marker in $Markers) {
        $index = $Source.IndexOf($marker, $offset, [StringComparison]::Ordinal)
        if ($index -lt 0) {
            throw "$Description is missing or misorders '$marker'."
        }
        $offset = $index + $marker.Length
    }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Invoke-SetupProbe {
    param(
        [Parameter(Mandatory)][string] $SetupPath,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $process = Start-Process -FilePath $SetupPath -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(15000)) {
        try { $process.Kill(); $process.WaitForExit() } catch {}
        throw "A4SMenuSetup $($Arguments -join ' ') did not exit within 15 seconds."
    }
    if ($process.ExitCode -ne 0) {
        throw "A4SMenuSetup $($Arguments -join ' ') failed with exit code $($process.ExitCode)."
    }
}

if (-not ('A4SSetupResourceProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class A4SSetupResourceProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resourceData);
    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);

    public static byte[] Read(string path, int identifier)
    {
        const uint AsImageResource = 0x20;
        const uint AsDatafileExclusive = 0x40;
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, AsImageResource | AsDatafileExclusive);
        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryExW failed");
        try
        {
            IntPtr resource = FindResourceW(module, new IntPtr(identifier), new IntPtr(10));
            if (resource == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "FindResourceW failed");
            uint size = SizeofResource(module, resource);
            IntPtr loaded = LoadResource(module, resource);
            IntPtr data = loaded == IntPtr.Zero ? IntPtr.Zero : LockResource(loaded);
            if (size == 0 || data == IntPtr.Zero) throw new InvalidOperationException("Embedded resource is empty.");
            byte[] bytes = new byte[size];
            Marshal.Copy(data, bytes, 0, checked((int)size));
            return bytes;
        }
        finally { FreeLibrary(module); }
    }
}
'@
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeStage = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage\A4SProduct'))
$setupStage = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage\A4SSetup'))
$setupPath = Join-Path $setupStage 'A4SMenuSetup.exe'
$hostPath = Join-Path $runtimeStage 'A4SMenuHost.exe'
$menuPath = Join-Path $runtimeStage 'A4SMenu.dll'
$setupSourcePath = Join-Path $repoRoot 'Src\A4SMenu\Setup\A4SMenuSetup.cpp'
$setupSource = [IO.File]::ReadAllText($setupSourcePath)

foreach ($requiredMarker in @(
    'kSetupMutexPrefix',
    'AcquireSetupMutex()',
    'kServicingKey',
    'kRecoveryRunOnceValue',
    'QueueJournalRecovery(recoveryCommand)',
    'Operation::Reconcile',
    'Hex(HashBytes(identity))',
    'SlotNameMatchesPayload(actualName, expectedName)',
    'NewGuidName(L".repair-")',
    'DeleteJournalDurably()',
    'ClearSafetyStateChecked()',
    'GetWindowsDirectoryW',
    'execute.lpFile = explorerPath.c_str()',
    'Unknown user-created root/slot content is deliberately preserved.')) {
    if ($setupSource.IndexOf($requiredMarker, [StringComparison]::Ordinal) -lt 0) {
        throw "Setup safety contract is missing '$requiredMarker'."
    }
}
if ($setupSource.IndexOf('RestoreRegistrationBestEffort', [StringComparison]::Ordinal) -ge 0 -or
    $setupSource.IndexOf('execute.lpFile = L"explorer.exe"', [StringComparison]::Ordinal) -ge 0) {
    throw 'Setup contains a retired destructive-recovery or relative Explorer-launch path.'
}

$installSource = Get-SourceSection -Source $setupSource -StartMarker 'int InstallOrRepair(' -EndMarker 'int Rollback('
Assert-SourceOrder -Description 'Install/repair transaction' -Source $installSource -Markers @(
    'DeploySlot(payloads, oldState.activeSlot)',
    'BeginJournal(',
    'QueueJournalRecovery(recoveryCommand)',
    'StopHost()',
    'PrepareSlotRegistration(newSlot, previous)',
    'MarkJournalReady()',
    'CommitSlotStartup(newSlot)',
    'CompleteJournal(journal)')
if ($installSource.IndexOf('resetSafety = options.operation == Operation::Repair',
        [StringComparison]::Ordinal) -lt 0) {
    throw 'Explicit repair no longer requests a post-commit HostSafety reset.'
}

$uninstallSource = Get-SourceSection -Source $setupSource -StartMarker 'int Uninstall(' -EndMarker 'int Cleanup('
Assert-SourceOrder -Description 'Uninstall transaction' -Source $uninstallSource -Markers @(
    'BeginJournal(',
    'PrepareCleanup(payloads)',
    'StopHost()',
    'PrepareUnregisterProduct()',
    'MarkJournalReady()',
    'CommitUnregisteredStartup()',
    'CompleteJournal(journal)',
    'StartPreparedCleanup(')

$failureSource = Get-SourceSection -Source $setupSource -StartMarker '[[noreturn]] void RestoreFailedOperation(' -EndMarker 'int InstallOrRepair('
Assert-SourceOrder -Description 'Failed-operation rollback' -Source $failureSource -Markers @(
    'RollBackJournal(journal)',
    'ValidateSlotBasic(oldState.activeSlot)',
    'StartHost(oldState.activeSlot)')
if ($failureSource.IndexOf('DeleteTreeChecked(kStateKey)', [StringComparison]::Ordinal) -ge 0 -or
    $failureSource.IndexOf('Unregister', [StringComparison]::Ordinal) -ge 0) {
    throw 'Failed-operation recovery can delete the product state instead of restoring its exact snapshot.'
}

$completeSource = Get-SourceSection -Source $setupSource -StartMarker 'void CompleteJournal(' -EndMarker 'void ReconcilePendingJournal('
Assert-SourceOrder -Description 'Post-commit completion' -Source $completeSource -Markers @(
    'ClearSafetyStateChecked()',
    'DeleteJournalDurably()',
    'DeleteValueChecked(kRunOnceKey, kRecoveryRunOnceValue)')

$prepareSource = Get-SourceSection -Source $setupSource -StartMarker 'void PrepareSlotRegistration(' -EndMarker 'void CommitSlotStartup('
if ($prepareSource.IndexOf('kRecoveryRunOnceValue', [StringComparison]::Ordinal) -ge 0) {
    throw 'Install preparation removes its own durable recovery command before the commit marker.'
}

$setupItems = @(Get-ChildItem -LiteralPath $setupStage -Force)
if ($setupItems.Count -ne 1 -or $setupItems[0].PSIsContainer -or $setupItems[0].Name -cne 'A4SMenuSetup.exe') {
    throw 'The distributable stage must contain exactly one file named A4SMenuSetup.exe.'
}
if (($setupItems[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    (Get-PeMachine -Path $setupPath) -ne 0x8664) {
    throw 'The staged setup must be a regular x64 PE file.'
}

$setupInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setupPath)
$hostInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($hostPath)
$menuInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($menuPath)
if ($setupInfo.OriginalFilename -cne 'A4SMenuSetup.exe' -or
    $setupInfo.ProductVersion -ne $hostInfo.ProductVersion -or
    $setupInfo.ProductVersion -ne $menuInfo.ProductVersion) {
    throw 'Setup, host, and DLL product metadata do not identify the same A4S release.'
}

$dumpbin = Find-Dumpbin
$actualDependencies = @(Get-DependentDllNames -DumpbinPath $dumpbin -BinaryPath $setupPath)
$expectedDependencies = @('ADVAPI32.DLL', 'BCRYPT.DLL', 'KERNEL32.DLL', 'OLE32.DLL',
    'RSTRTMGR.DLL', 'SHELL32.DLL', 'USER32.DLL', 'VERSION.DLL') | Sort-Object
if ($actualDependencies.Count -ne $expectedDependencies.Count -or
    (Compare-Object $expectedDependencies $actualDependencies)) {
    throw "A4SMenuSetup dependency drift. Expected '$($expectedDependencies -join ', ')'; found '$($actualDependencies -join ', ')'."
}

$embeddedHost = [A4SSetupResourceProbe]::Read($setupPath, 201)
$embeddedMenu = [A4SSetupResourceProbe]::Read($setupPath, 202)
$hostHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $hostPath).Hash
$menuHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $menuPath).Hash
$embeddedHostHash = Get-BytesSha256 -Bytes $embeddedHost
$embeddedMenuHash = Get-BytesSha256 -Bytes $embeddedMenu
if ($embeddedHostHash -ne $hostHash -or $embeddedMenuHash -ne $menuHash) {
    throw 'The one-file installer does not embed the exact staged host and DLL.'
}

$registryBefore = Get-RegistryFingerprint
Invoke-SetupProbe -SetupPath $setupPath -Arguments @('--version')
Invoke-SetupProbe -SetupPath $setupPath -Arguments @('--verify', '--silent')
Invoke-SetupProbe -SetupPath $setupPath -Arguments @('--self-test', '--silent')
$testRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\test'))
if (-not (Test-Path -LiteralPath $testRoot)) { New-Item -ItemType Directory -Path $testRoot | Out-Null }
if ((Get-Item -LiteralPath $testRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Refusing to extract through a reparse point: $testRoot"
}
$layout = [IO.Path]::GetFullPath((Join-Path $testRoot ('.A4SSetupLayout.' + [Guid]::NewGuid().ToString('N'))))
if (-not $layout.StartsWith($testRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The temporary layout escaped the verified build test root.'
}
try {
    Invoke-SetupProbe -SetupPath $setupPath -Arguments @('--extract-test', $layout, '--silent')
    $layoutItems = @(Get-ChildItem -LiteralPath $layout -Force)
    $expectedLayout = @('A4SMenu.dll', 'A4SMenuHost.exe', 'A4SMenuSetup.exe')
    $actualLayout = @($layoutItems | Select-Object -ExpandProperty Name | Sort-Object)
    if ($layoutItems.Count -ne 3 -or ($layoutItems | Where-Object { $_.PSIsContainer -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }) -or
        (Compare-Object $expectedLayout $actualLayout)) {
        throw 'The side-effect-free extraction did not produce the exact three-file installed layout.'
    }
    foreach ($pair in @(
        @((Join-Path $layout 'A4SMenuHost.exe'), $hostPath),
        @((Join-Path $layout 'A4SMenu.dll'), $menuPath),
        @((Join-Path $layout 'A4SMenuSetup.exe'), $setupPath))) {
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $pair[0]).Hash -ne
            (Get-FileHash -Algorithm SHA256 -LiteralPath $pair[1]).Hash) {
            throw "Extracted payload mismatch: $($pair[0])"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $layout) {
        $layoutItem = Get-Item -LiteralPath $layout -Force
        if (($layoutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to clean a reparse-point test layout: $layout"
        }
        Remove-Item -LiteralPath $layout -Recurse -Force
    }
}
$registryAfter = Get-RegistryFingerprint
if ($registryAfter -cne $registryBefore) {
    throw 'Setup verification/extraction changed A4S Menu installation registry state.'
}

Write-Host "Validated one-file installer $($setupInfo.ProductVersion): exact embedded payloads, servicing safety contracts, deterministic recovery self-tests, system dependencies, metadata, no-op probes, and registry-neutral extraction."
