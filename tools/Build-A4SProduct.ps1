[CmdletBinding()]
param(
    [switch] $SkipStage,
    [switch] $SkipValidation
)

$ErrorActionPreference = 'Stop'

if ($SkipStage -and -not $SkipValidation) {
    throw 'SkipStage requires SkipValidation; validation must never inspect a stale staged product.'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$solutionPath = Join-Path $repoRoot 'Src\A4SMenu\A4SMenu.Product.sln'
$packagesPath = Join-Path $repoRoot 'Src\packages'
$vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
    throw "Visual Studio locator was not found: $vswherePath"
}

$vsInstallPath = & $vswherePath -latest -products * -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.ATL -property installationPath
if (-not $vsInstallPath) {
	throw 'Visual Studio Build Tools with MSBuild, the x64 C++ toolchain, and ATL were not found.'
}

$msbuildPath = Join-Path $vsInstallPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
	throw "MSBuild was not found in the selected C++ toolchain: $msbuildPath"
}

& $msbuildPath $solutionPath /m /restore /t:Build /p:RestorePackagesConfig=true "/p:RestorePackagesPath=$packagesPath" /p:Configuration=A4SProduct /p:Platform=x64 /nologo /v:minimal
if ($LASTEXITCODE -ne 0) {
    throw "A4S product build failed with exit code $LASTEXITCODE."
}

if (-not $SkipStage) {
    & (Join-Path $PSScriptRoot 'Stage-A4SProduct.ps1')
}

if (-not $SkipValidation) {
    & (Join-Path $PSScriptRoot 'Test-A4SProductBoundary.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SNativeLifecycle.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SLifecycleTools.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SCacheStateNative.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SCacheFirstMetadata.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SAsyncPrograms.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SWarmRootCache.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SLazySearch.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SPerformanceOptimizations.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SRuntimeTraceTools.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SPerformanceTools.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SFailureRecoveryContracts.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SInstallerLifecycleContracts.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SProduct.ps1')
    & (Join-Path $PSScriptRoot 'Test-A4SSetup.ps1')
}
