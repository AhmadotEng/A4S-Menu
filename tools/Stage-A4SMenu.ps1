[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

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

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceDir = Join-Path $repoRoot 'build\bin\Setup64'
$stageRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage'))
$stageDir = [IO.Path]::GetFullPath((Join-Path $stageRoot 'A4SMenu'))
$expected = @('StartMenu.exe', 'StartMenuDLL.dll')

if (-not $stageDir.StartsWith($stageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to stage outside the repository stage root: $stageDir"
}

foreach ($name in $expected) {
    $source = Join-Path $sourceDir $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing build output: $source"
    }
    if ((Get-PeMachine -Path $source) -ne 0x8664) {
        throw "The build output is not x64: $source"
    }
}

if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

foreach ($name in $expected) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $name) -Destination (Join-Path $stageDir $name)
}

$actualFiles = @(Get-ChildItem -LiteralPath $stageDir -File | Select-Object -ExpandProperty Name | Sort-Object)
$actualDirs = @(Get-ChildItem -LiteralPath $stageDir -Directory)
$expectedSorted = @($expected | Sort-Object)
if ($actualDirs.Count -ne 0 -or (Compare-Object $expectedSorted $actualFiles)) {
    throw 'The staged runtime contains an unexpected file or directory.'
}

Get-FileHash -Algorithm SHA256 -LiteralPath ($expected | ForEach-Object { Join-Path $stageDir $_ }) |
    Select-Object Path, Hash

Write-Host "Staged the exact two-file x64 runtime at $stageDir"
