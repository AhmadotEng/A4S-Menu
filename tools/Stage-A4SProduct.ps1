[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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

function Assert-PathWithin {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $fullPath.StartsWith($fullParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the verified parent '$fullParent': $fullPath"
    }
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string] $Path,
        [switch] $Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to stage through a reparse point: $Path"
    }
    if ($Recurse -and $item.PSIsContainer) {
        $nestedReparsePoint = Get-ChildItem -LiteralPath $Path -Force -Recurse |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First 1
        if ($nestedReparsePoint) {
            throw "Refusing to operate on a tree containing a reparse point: $($nestedReparsePoint.FullName)"
        }
    }
}

function Assert-ExactProductTree {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $ExpectedNames
    )

    Assert-NoReparsePoint -Path $Path -Recurse
    $items = @(Get-ChildItem -LiteralPath $Path -Force)
    $actualFiles = @($items | Where-Object { -not $_.PSIsContainer } | Select-Object -ExpandProperty Name | Sort-Object)
    $actualDirectories = @($items | Where-Object { $_.PSIsContainer })
    $expectedSorted = @($ExpectedNames | Sort-Object)
    if ($actualDirectories.Count -ne 0 -or $actualFiles.Count -ne $expectedSorted.Count -or (Compare-Object $expectedSorted $actualFiles)) {
        throw "The product tree '$Path' does not contain exactly the expected files."
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceDir = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\A4SProduct\bin\x64'))
$stageRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage'))
$stageDir = [IO.Path]::GetFullPath((Join-Path $stageRoot 'A4SProduct'))
$setupStageDir = [IO.Path]::GetFullPath((Join-Path $stageRoot 'A4SSetup'))
$expectedNames = @('A4SMenuHost.exe', 'A4SMenu.dll')
$setupExpectedNames = @('A4SMenuSetup.exe')

Assert-PathWithin -Path $sourceDir -Parent $repoRoot
Assert-PathWithin -Path $stageRoot -Parent $repoRoot
Assert-PathWithin -Path $stageDir -Parent $stageRoot
Assert-PathWithin -Path $setupStageDir -Parent $stageRoot

# Reject links in every existing boundary and in both trees. This ensures that
# copying and the later recursive cleanup cannot cross a verified directory.
Assert-NoReparsePoint -Path $repoRoot
Assert-NoReparsePoint -Path (Join-Path $repoRoot 'build')
Assert-NoReparsePoint -Path $sourceDir -Recurse
Assert-NoReparsePoint -Path $stageRoot
Assert-NoReparsePoint -Path $stageDir -Recurse
Assert-NoReparsePoint -Path $setupStageDir -Recurse

foreach ($name in $expectedNames) {
    $sourcePath = Join-Path $sourceDir $name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Missing product build output: $sourcePath"
    }
    Assert-NoReparsePoint -Path $sourcePath
    if ((Get-PeMachine -Path $sourcePath) -ne 0x8664) {
        throw "The product build output is not x64: $sourcePath"
    }
}

$setupSourcePath = Join-Path $sourceDir 'A4SMenuSetup.exe'
if (-not (Test-Path -LiteralPath $setupSourcePath -PathType Leaf)) {
    throw "Missing one-file installer build output: $setupSourcePath"
}
Assert-NoReparsePoint -Path $setupSourcePath
if ((Get-PeMachine -Path $setupSourcePath) -ne 0x8664) {
    throw "The one-file installer is not x64: $setupSourcePath"
}

if (-not (Test-Path -LiteralPath $stageRoot)) {
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
}
Assert-NoReparsePoint -Path $stageRoot

$swapId = [Guid]::NewGuid().ToString('N')
$tempDir = [IO.Path]::GetFullPath((Join-Path $stageRoot ".A4SProduct.staging.$swapId"))
$backupDir = [IO.Path]::GetFullPath((Join-Path $stageRoot ".A4SProduct.backup.$swapId"))
Assert-PathWithin -Path $tempDir -Parent $stageRoot
Assert-PathWithin -Path $backupDir -Parent $stageRoot

$oldStageMoved = $false
$newStageInstalled = $false
$swapCommitted = $false
try {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    Assert-NoReparsePoint -Path $tempDir

    foreach ($name in $expectedNames) {
        Copy-Item -LiteralPath (Join-Path $sourceDir $name) -Destination (Join-Path $tempDir $name)
    }
    Assert-ExactProductTree -Path $tempDir -ExpectedNames $expectedNames
    foreach ($name in $expectedNames) {
        $sourcePath = Join-Path $sourceDir $name
        $temporaryPath = Join-Path $tempDir $name
        if ((Get-PeMachine -Path $temporaryPath) -ne 0x8664) {
            throw "The temporary staged output is not x64: $name"
        }
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
        $temporaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryPath).Hash
        if ($sourceHash -ne $temporaryHash) {
            throw "The temporary staged copy failed SHA-256 verification: $name"
        }
    }

    if (Test-Path -LiteralPath $stageDir) {
        # A rename within one volume is the rollback point for the swap.
        Move-Item -LiteralPath $stageDir -Destination $backupDir
        $oldStageMoved = $true
    }
    Move-Item -LiteralPath $tempDir -Destination $stageDir
    $newStageInstalled = $true

    Assert-ExactProductTree -Path $stageDir -ExpectedNames $expectedNames
    $swapCommitted = $true
}
catch {
    $failure = $_
    if ($newStageInstalled -and (Test-Path -LiteralPath $stageDir)) {
        Assert-PathWithin -Path $stageDir -Parent $stageRoot
        Assert-NoReparsePoint -Path $stageDir -Recurse
        Remove-Item -LiteralPath $stageDir -Recurse -Force
        $newStageInstalled = $false
    }
    if ($oldStageMoved -and (Test-Path -LiteralPath $backupDir) -and -not (Test-Path -LiteralPath $stageDir)) {
        Move-Item -LiteralPath $backupDir -Destination $stageDir
        $oldStageMoved = $false
    }
    if (Test-Path -LiteralPath $tempDir) {
        Assert-PathWithin -Path $tempDir -Parent $stageRoot
        Assert-NoReparsePoint -Path $tempDir -Recurse
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
    throw $failure
}

# Cleanup happens only after the replacement has been fully validated. A
# cleanup failure must not roll back a committed product to a partly deleted
# backup; retain it as a recoverable artifact and warn instead.
if ($swapCommitted -and $oldStageMoved -and (Test-Path -LiteralPath $backupDir)) {
    try {
        Assert-PathWithin -Path $backupDir -Parent $stageRoot
        Assert-NoReparsePoint -Path $backupDir -Recurse
        Remove-Item -LiteralPath $backupDir -Recurse -Force
        $oldStageMoved = $false
    }
    catch {
        Write-Warning "The new product is committed, but the previous-stage backup could not be removed: $backupDir. $_"
    }
}

$hashes = Get-FileHash -Algorithm SHA256 -LiteralPath ($expectedNames | ForEach-Object { Join-Path $stageDir $_ })
$hashes | Select-Object Path, Hash
Write-Host "Atomically staged the exact two-file x64 product at $stageDir"

# The distributable is a separate exact one-file stage. Keeping it apart from
# the two-file development/runtime layout prevents an installer from being
# mistaken for an Explorer-loaded product component.
$setupSwapId = [Guid]::NewGuid().ToString('N')
$setupTempDir = [IO.Path]::GetFullPath((Join-Path $stageRoot ".A4SSetup.staging.$setupSwapId"))
$setupBackupDir = [IO.Path]::GetFullPath((Join-Path $stageRoot ".A4SSetup.backup.$setupSwapId"))
Assert-PathWithin -Path $setupTempDir -Parent $stageRoot
Assert-PathWithin -Path $setupBackupDir -Parent $stageRoot

$oldSetupMoved = $false
$newSetupInstalled = $false
$setupSwapCommitted = $false
try {
    New-Item -ItemType Directory -Path $setupTempDir | Out-Null
    Assert-NoReparsePoint -Path $setupTempDir
    Copy-Item -LiteralPath $setupSourcePath -Destination (Join-Path $setupTempDir 'A4SMenuSetup.exe')
    Assert-ExactProductTree -Path $setupTempDir -ExpectedNames $setupExpectedNames
    $temporarySetupPath = Join-Path $setupTempDir 'A4SMenuSetup.exe'
    if ((Get-PeMachine -Path $temporarySetupPath) -ne 0x8664) {
        throw 'The temporary staged installer is not x64.'
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $temporarySetupPath).Hash -ne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $setupSourcePath).Hash) {
        throw 'The temporary installer copy failed SHA-256 verification.'
    }

    if (Test-Path -LiteralPath $setupStageDir) {
        Move-Item -LiteralPath $setupStageDir -Destination $setupBackupDir
        $oldSetupMoved = $true
    }
    Move-Item -LiteralPath $setupTempDir -Destination $setupStageDir
    $newSetupInstalled = $true
    Assert-ExactProductTree -Path $setupStageDir -ExpectedNames $setupExpectedNames
    $setupSwapCommitted = $true
}
catch {
    $failure = $_
    if ($newSetupInstalled -and (Test-Path -LiteralPath $setupStageDir)) {
        Assert-PathWithin -Path $setupStageDir -Parent $stageRoot
        Assert-NoReparsePoint -Path $setupStageDir -Recurse
        Remove-Item -LiteralPath $setupStageDir -Recurse -Force
    }
    if ($oldSetupMoved -and (Test-Path -LiteralPath $setupBackupDir) -and
        -not (Test-Path -LiteralPath $setupStageDir)) {
        Move-Item -LiteralPath $setupBackupDir -Destination $setupStageDir
        $oldSetupMoved = $false
    }
    if (Test-Path -LiteralPath $setupTempDir) {
        Assert-PathWithin -Path $setupTempDir -Parent $stageRoot
        Assert-NoReparsePoint -Path $setupTempDir -Recurse
        Remove-Item -LiteralPath $setupTempDir -Recurse -Force
    }
    throw $failure
}

if ($setupSwapCommitted -and $oldSetupMoved -and (Test-Path -LiteralPath $setupBackupDir)) {
    try {
        Assert-PathWithin -Path $setupBackupDir -Parent $stageRoot
        Assert-NoReparsePoint -Path $setupBackupDir -Recurse
        Remove-Item -LiteralPath $setupBackupDir -Recurse -Force
    }
    catch {
        Write-Warning "The installer is committed, but its previous-stage backup remains at $setupBackupDir. $_"
    }
}

Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $setupStageDir 'A4SMenuSetup.exe') |
    Select-Object Path, Hash
Write-Host "Atomically staged the exact one-file x64 installer at $setupStageDir"
