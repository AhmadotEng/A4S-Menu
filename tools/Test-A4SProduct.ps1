[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
	throw 'Run this validation from 64-bit PowerShell because it loads the x64 A4SMenu.dll for its ABI probe.'
}

function Find-Dumpbin {
    $vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsInstallPath = & $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsInstallPath) {
        throw 'Visual C++ build tools were not found.'
    }
    $toolsRoot = Join-Path $vsInstallPath 'VC\Tools\MSVC'
    $toolset = Get-ChildItem -LiteralPath $toolsRoot -Directory |
        Sort-Object { [Version]$_.Name } -Descending |
        Select-Object -First 1
    if (-not $toolset) {
        throw "No MSVC toolset was found under $toolsRoot."
    }
    $dumpbinPath = Join-Path $toolset.FullName 'bin\Hostx64\x64\dumpbin.exe'
    if (-not (Test-Path -LiteralPath $dumpbinPath -PathType Leaf)) {
        throw "dumpbin.exe was not found: $dumpbinPath"
    }
    return $dumpbinPath
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "$Path is not a PE image."
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "$Path has an invalid PE signature."
        }
        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-DependentDllNames {
    param(
        [Parameter(Mandatory)][string] $DumpbinPath,
        [Parameter(Mandatory)][string] $BinaryPath
    )

    $output = (& $DumpbinPath /nologo /dependents $BinaryPath) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect dependencies for $BinaryPath."
    }
	return @([Regex]::Matches($output, '(?im)^\s+([a-z0-9_.-]+\.(?:dll|ocx))\s*$') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique)
}

function Assert-SystemDependenciesOnly {
    param(
        [Parameter(Mandatory)][string] $BinaryPath,
        [Parameter(Mandatory)][string[]] $Names
    )

    if ($Names.Count -eq 0) {
        throw "No dependent DLL names were found for $BinaryPath."
    }
	$system32 = Join-Path $env:SystemRoot 'System32'
	foreach ($name in $Names) {
		if ($name -match '^(?i:(?:vcruntime|msvcp|concrt|vcomp|mfc|mfcm|atl).*\.dll)$' -or
			$name -ieq 'ucrtbased.dll') {
			throw "$BinaryPath depends on a Visual C++ redistributable or debug runtime that is not part of the two-file package: $name"
		}
		if ($name -match '^(?i:(?:wininet|winhttp|urlmon)\.dll|hhctrl\.ocx)$') {
			throw "$BinaryPath retained an updater, network-download, or HTML Help dependency outside the A4S product boundary: $name"
		}
		if ($name -match '^(?i:(?:api|ext)-ms-win-.+\.dll)$') {
            continue
        }
        $systemPath = Join-Path $system32 $name
        if (-not (Test-Path -LiteralPath $systemPath -PathType Leaf)) {
            throw "$BinaryPath has a non-system dependency: $name"
        }
    }
}

function Assert-ExactDependencies {
	param(
		[Parameter(Mandatory)][string] $BinaryPath,
		[Parameter(Mandatory)][string[]] $Names,
		[Parameter(Mandatory)][string[]] $ExpectedNames
	)

	$actual = @($Names | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
	$expected = @($ExpectedNames | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
	if ($actual.Count -ne $expected.Count -or (Compare-Object $expected $actual)) {
		throw "$BinaryPath dependency drift. Expected '$($expected -join ', ')'; found '$($actual -join ', ')'."
	}
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stageDir = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage\A4SProduct'))
$hostExePath = Join-Path $stageDir 'A4SMenuHost.exe'
$menuDllPath = Join-Path $stageDir 'A4SMenu.dll'
$expectedNames = @('A4SMenu.dll', 'A4SMenuHost.exe')

if (-not (Test-Path -LiteralPath $stageDir -PathType Container)) {
    throw "Missing staged product directory: $stageDir"
}
$stageDirectoryItem = Get-Item -LiteralPath $stageDir -Force
if (($stageDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The staged product directory is a reparse point: $stageDir"
}
$stageItems = @(Get-ChildItem -LiteralPath $stageDir -Force)
$stageDirectories = @($stageItems | Where-Object { $_.PSIsContainer })
$stageFiles = @($stageItems | Where-Object { -not $_.PSIsContainer })
$actualNames = @($stageFiles | Select-Object -ExpandProperty Name | Sort-Object)
if ($stageDirectories.Count -ne 0 -or $stageFiles.Count -ne 2 -or (Compare-Object $expectedNames $actualNames)) {
    throw 'The staged product must contain exactly A4SMenu.dll and A4SMenuHost.exe as top-level files, with no directories.'
}
foreach ($item in $stageItems) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The staged product contains a reparse point: $($item.FullName)"
    }
}
foreach ($binaryPath in @($hostExePath, $menuDllPath)) {
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        throw "Missing staged product binary: $binaryPath"
    }
    if ((Get-PeMachine -Path $binaryPath) -ne 0x8664) {
        throw "The staged product binary is not x64: $binaryPath"
    }
}

$dumpbinPath = Find-Dumpbin
$hostDependencies = Get-DependentDllNames -DumpbinPath $dumpbinPath -BinaryPath $hostExePath
$dllDependencies = Get-DependentDllNames -DumpbinPath $dumpbinPath -BinaryPath $menuDllPath
Assert-SystemDependenciesOnly -BinaryPath $hostExePath -Names $hostDependencies
Assert-SystemDependenciesOnly -BinaryPath $menuDllPath -Names $dllDependencies
Assert-ExactDependencies -BinaryPath $hostExePath -Names $hostDependencies -ExpectedNames @(
	'ADVAPI32.dll', 'KERNEL32.dll', 'SHELL32.dll', 'USER32.dll'
)
Assert-ExactDependencies -BinaryPath $menuDllPath -Names $dllDependencies -ExpectedNames @(
	'ADVAPI32.dll', 'COMCTL32.dll', 'dwmapi.dll', 'GDI32.dll', 'KERNEL32.dll',
	'MSIMG32.dll', 'NETAPI32.dll', 'OLE32.dll', 'OLEACC.dll', 'OLEAUT32.dll',
	'POWRPROF.dll', 'PROPSYS.dll', 'Secur32.dll', 'SHELL32.dll', 'SHLWAPI.dll',
	'USER32.dll', 'UxTheme.dll', 'WINMM.dll', 'WTSAPI32.dll'
)

$hostImports = (& $dumpbinPath /nologo /imports $hostExePath) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect A4SMenuHost.exe imports.'
}
if ($hostImports -match '(?im)^\s*(?:A4SMenu|StartMenuDLL)\.dll\s*$') {
    throw 'A4SMenuHost.exe has a static menu-DLL dependency; the host must resolve the sibling DLL dynamically.'
}

$dllExports = (& $dumpbinPath /nologo /exports $menuDllPath) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect A4SMenu.dll exports.'
}
$actualExports = @([Regex]::Matches($dllExports, '(?im)^\s+\d+\s+[0-9a-f]+\s+[0-9a-f]+\s+(\S+)(?:\s+.*)?$') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique)
$expectedExports = @('A4SMenu_GetApi', 'A4SMenu_HookInject')
if ($actualExports.Count -ne $expectedExports.Count -or (Compare-Object ($expectedExports | Sort-Object) $actualExports)) {
    throw "A4SMenu.dll exports must be exactly '$($expectedExports -join ', ')'; found '$($actualExports -join ', ')'."
}

$hostInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($hostExePath)
$dllInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($menuDllPath)
if ($hostInfo.OriginalFilename -ne 'A4SMenuHost.exe') {
    throw "Unexpected host OriginalFilename: $($hostInfo.OriginalFilename)"
}
if ($dllInfo.OriginalFilename -ne 'A4SMenu.dll') {
    throw "Unexpected DLL OriginalFilename: $($dllInfo.OriginalFilename)"
}
foreach ($binaryInfo in @($hostInfo, $dllInfo)) {
    if ($binaryInfo.FileVersion -ne '1.0.0.0' -or $binaryInfo.ProductVersion -ne '1.0.0.0') {
        throw "Product version drift in $($binaryInfo.OriginalFilename): file=$($binaryInfo.FileVersion), product=$($binaryInfo.ProductVersion)"
    }
}

if (-not ('A4SBinaryProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class A4SBinaryProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate IntPtr GetApiDelegate(uint requestedAbi);

    [StructLayout(LayoutKind.Sequential)]
    private struct Api
    {
        public uint Size;
        public uint AbiVersion;
        public uint ProductVersion;
        public uint Reserved;
        public IntPtr RequestShutdown;
    }

    public static string Probe(string path)
    {
        const uint LoadLibrarySearchDllLoadDir = 0x00000100;
        const uint LoadLibrarySearchDefaultDirs = 0x00001000;
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, LoadLibrarySearchDllLoadDir | LoadLibrarySearchDefaultDirs);
        if (module == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryExW failed");
        try
        {
            IntPtr address = GetProcAddress(module, "A4SMenu_GetApi");
            if (address == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetProcAddress failed");
            GetApiDelegate getApi = (GetApiDelegate)Marshal.GetDelegateForFunctionPointer(address, typeof(GetApiDelegate));
            if (getApi(0x00030000) != IntPtr.Zero)
                throw new InvalidOperationException("A4SMenu_GetApi accepted the obsolete ABI3 contract.");
            IntPtr apiAddress = getApi(0x00040000);
            if (apiAddress == IntPtr.Zero)
                throw new InvalidOperationException("A4SMenu_GetApi rejected the expected ABI.");
            Api api = (Api)Marshal.PtrToStructure(apiAddress, typeof(Api));
            if (api.Size < (uint)Marshal.SizeOf(typeof(Api)) || api.AbiVersion != 0x00040000 || api.ProductVersion != 0x00010000 || api.RequestShutdown == IntPtr.Zero)
                throw new InvalidOperationException("A4SMenu_GetApi returned an invalid API table.");
            return String.Format("ABI=0x{0:X8}; Product=0x{1:X8}; Size={2}", api.AbiVersion, api.ProductVersion, api.Size);
        }
        finally
        {
            FreeLibrary(module);
        }
    }
}
'@
}

$abiResult = [A4SBinaryProbe]::Probe($menuDllPath)
$versionProcess = Start-Process -FilePath $hostExePath -ArgumentList '--version' -WindowStyle Hidden -PassThru
if (-not $versionProcess.WaitForExit(5000)) {
    try {
        $versionProcess.Kill()
        $versionProcess.WaitForExit()
    }
    catch {
        Write-Warning "Could not terminate the hung version-probe process $($versionProcess.Id): $_"
    }
    throw 'The host --version probe did not exit within five seconds.'
}
if ($versionProcess.ExitCode -ne 0) {
    throw "The host --version probe failed with exit code $($versionProcess.ExitCode)."
}

Write-Host "Validated product ABI: $abiResult"
Write-Host "Validated exact x64 stage contents, exact DLL exports, exact reviewed dependencies, product metadata, and the host --version exit path."
