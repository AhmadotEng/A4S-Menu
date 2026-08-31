[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = Join-Path $PSScriptRoot 'A4SCacheStateNativeTests.vcxproj'
$testExe = Join-Path $repoRoot 'build\tests\A4SCacheStateNativeTests.exe'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Visual Studio locator is unavailable; native cache-state gates cannot run.'
}
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
    -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) {
    throw 'MSBuild is unavailable; native cache-state gates cannot run.'
}

& $msbuild $project /t:Build /p:Configuration=Release /p:Platform=x64 /nologo /v:minimal
if ($LASTEXITCODE -ne 0) {
    throw "Native cache-state test build failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $testExe -PathType Leaf)) {
    throw "Native cache-state test binary was not produced: $testExe"
}
& $testExe
if ($LASTEXITCODE -ne 0) {
    throw "Native cache-state fault injection failed with exit code $LASTEXITCODE."
}
