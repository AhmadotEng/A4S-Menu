[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build\tools\A4SStep3Correlator')
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'A4SStep3Correlator\Program.cs'
$buildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
$private = Join-Path $buildTools 'Common7\IDE\PrivateAssemblies'
$csc = Join-Path $buildTools 'MSBuild\Current\Bin\Roslyn\csc.exe'
$framework = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319'
$newtonsoft = Join-Path $buildTools 'Common7\IDE\CommonExtensions\Microsoft\NuGet\Newtonsoft.Json.dll'

$references = @(
    (Join-Path $framework 'mscorlib.dll'),
    (Join-Path $framework 'System.dll'),
    (Join-Path $framework 'System.Core.dll'),
    (Join-Path $framework 'System.Xml.dll'),
    (Join-Path $framework 'System.Runtime.Serialization.dll'),
    (Join-Path $framework 'netstandard.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.FastSerialization.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.Tracing.EventSource.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.Tracing.TraceEvent.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.Utilities.dll'),
    $newtonsoft
)

$runtimeFiles = @(
    (Join-Path $private 'Dia2Lib.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.FastSerialization.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.Tracing.EventSource.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.Tracing.TraceEvent.dll'),
    (Join-Path $private 'Microsoft.Diagnostics.Utilities.dll'),
    (Join-Path $private 'TraceReloggerLib.dll'),
    $newtonsoft,
    (Join-Path $buildTools 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\RemoteAgent\System.Reflection.Metadata.dll'),
    (Join-Path $buildTools 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\RemoteAgent\System.Collections.Immutable.dll'),
    (Join-Path $buildTools 'Common7\IDE\CommonExtensions\Microsoft\VBCSharp\LanguageServices\InteractiveHost\Desktop\Microsoft.Win32.Registry.dll'),
    (Join-Path $buildTools 'Common7\IDE\CommonExtensions\Microsoft\NuGet\System.Memory.dll'),
    (Join-Path $buildTools 'Common7\IDE\CommonExtensions\Microsoft\NuGet\System.Runtime.CompilerServices.Unsafe.dll')
)

foreach ($path in @($source, $csc) + $references + $runtimeFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing A4S Step 3 correlator build dependency: $path"
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$executable = Join-Path $OutputDirectory 'A4SStep3Correlator.exe'
$arguments = @(
    '/nologo',
    '/langversion:latest',
    '/nostdlib+',
    '/target:exe',
    '/platform:x64',
    '/optimize+',
    '/deterministic+',
    "/out:$executable"
) + @($references | ForEach-Object { "/reference:$_" }) + $source

& $csc @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "A4S Step 3 correlator compilation failed with exit code $LASTEXITCODE."
}

foreach ($path in $runtimeFiles) {
    Copy-Item -LiteralPath $path -Destination (Join-Path $OutputDirectory ([IO.Path]::GetFileName($path))) -Force
}

Write-Output $executable
