[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$solution = Join-Path $repoRoot 'Src\OpenShell.sln'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio locator was not found: $vswhere"
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if (-not $vsPath) {
    throw 'Visual Studio Build Tools with MSBuild were not found.'
}

$msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
$env:CS_VERSION = '4.4.1000'
$env:CS_VERSION_ORIG = '4.4.1000'

& $msbuild $solution /m /t:StartMenu /p:Configuration=Setup /p:Platform=x64 /nologo /v:minimal
if ($LASTEXITCODE -ne 0) {
    throw "A4S Menu build failed with exit code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot 'Stage-A4SMenu.ps1')
