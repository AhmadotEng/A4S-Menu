[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$solution = Join-Path $repoRoot 'Src\OpenShell.sln'
$packagesPath = Join-Path $repoRoot 'Src\packages'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio locator was not found: $vswhere"
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.ATL -property installationPath
if (-not $vsPath) {
	throw 'Visual Studio Build Tools with MSBuild, the x64 C++ toolchain, and ATL were not found.'
}

$msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) {
	throw "MSBuild was not found in the selected C++ toolchain: $msbuild"
}

& $msbuild $solution /m /restore /t:StartMenu /p:RestorePackagesConfig=true "/p:RestorePackagesPath=$packagesPath" /p:Configuration=Setup /p:Platform=x64 /p:CS_VERSION=4.4.1000 /p:CS_VERSION_ORIG=4.4.1000 /nologo /v:minimal
if ($LASTEXITCODE -ne 0) {
    throw "A4S Menu build failed with exit code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot 'Stage-A4SMenu.ps1')
