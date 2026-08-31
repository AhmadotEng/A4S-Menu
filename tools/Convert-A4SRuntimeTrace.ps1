[CmdletBinding(DefaultParameterSetName = 'Etl')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Etl')]
    [string]$EtlPath,
    [Parameter(Mandatory, ParameterSetName = 'SyntheticJson')]
    [string]$EventJsonPath,
    [uint32]$ExpectedProcessId = 0,
    [ValidateRange(0, 1000)]
    [int]$ColdSampleCount = 0,
    [ValidateRange(1, 250)]
    [double]$WarmOpenTargetMilliseconds = 50,
    [ValidateRange(20, 1000)]
    [double]$RefreshRateHz = 60,
    [string]$OutputPath,
    [string]$TracerptXmlPath,
    [switch]$EnforceTargets,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'A4SRuntimeTrace.Core.psm1') -Force

function Resolve-A4SOutputPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

$events = @()
$sourceType = ''
$sourcePath = ''
$sourceHash = ''
$rawEtlPreserved = $false
$decodedXml = $null

if ($PSCmdlet.ParameterSetName -eq 'Etl') {
    $sourcePath = (Resolve-Path -LiteralPath $EtlPath -ErrorAction Stop).ProviderPath
    if ([IO.Path]::GetExtension($sourcePath) -ine '.etl') { throw "Expected an .etl input; received '$sourcePath'." }
    $sourceType = 'etl'
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $rawEtlPreserved = $true
    if (-not $TracerptXmlPath) { $TracerptXmlPath = [IO.Path]::ChangeExtension($sourcePath, '.tracerpt.xml') }
    $decodedXml = Resolve-A4SOutputPath $TracerptXmlPath
    if ((Test-Path -LiteralPath $decodedXml) -and -not $Force) {
        throw "Decoded tracerpt XML already exists at '$decodedXml'. Use -Force to replace only that derived file; the ETL is never changed."
    }
    $xmlDirectory = Split-Path -Parent $decodedXml
    if (-not (Test-Path -LiteralPath $xmlDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $xmlDirectory -Force | Out-Null
    }
    $tracerpt = Join-Path $env:SystemRoot 'System32\tracerpt.exe'
    if (-not (Test-Path -LiteralPath $tracerpt -PathType Leaf)) { throw "Windows tracerpt.exe was not found at '$tracerpt'." }
    $decodeOutput = @(& $tracerpt $sourcePath -o $decodedXml -of XML -lr -y 2>&1)
    $decodeExitCode = $LASTEXITCODE
    if ($decodeExitCode -ne 0) {
        throw "tracerpt failed with exit code $decodeExitCode. Raw ETL remains at '$sourcePath'. Output: $($decodeOutput -join ' ')"
    }
    $events = @(ConvertFrom-A4STracerptXml -Path $decodedXml -ExpectedProcessId $ExpectedProcessId)
    if ($events.Count -eq 0) {
        throw "No decodable A4SMenu.Runtime events were found. Raw ETL remains at '$sourcePath'; inspect '$decodedXml' and verify the staged DLL contains provider 74a9f986-c7ab-429a-9571-df0fb7f4a33c."
    }
} else {
    $sourcePath = (Resolve-Path -LiteralPath $EventJsonPath -ErrorAction Stop).ProviderPath
    $sourceType = 'syntheticJson'
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $events = @(Import-A4SEventJson -Path $sourcePath -ExpectedProcessId $ExpectedProcessId)
    if ($events.Count -eq 0) { throw "No A4S runtime events were found in '$sourcePath'." }
}

if (-not $OutputPath) {
    $base = if ($sourceType -eq 'etl') { [IO.Path]::ChangeExtension($sourcePath, $null) } else { $sourcePath }
    $OutputPath = "$base.a4s-runtime.json"
}
$resolvedOutput = Resolve-A4SOutputPath $OutputPath
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "Report already exists at '$resolvedOutput'. Use -Force to replace the derived JSON report."
}
$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$report = ConvertTo-A4SRuntimeReport -Events $events -ColdSampleCount $ColdSampleCount `
    -WarmOpenTargetMilliseconds $WarmOpenTargetMilliseconds -RefreshRateHz $RefreshRateHz `
    -SourceType $sourceType -SourcePath $sourcePath
$report.source | Add-Member -NotePropertyName sha256 -NotePropertyValue $sourceHash
$report.source | Add-Member -NotePropertyName rawEtlPreserved -NotePropertyValue $rawEtlPreserved
if ($decodedXml) { $report.source | Add-Member -NotePropertyName tracerptXmlPath -NotePropertyValue $decodedXml }

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
Write-Output $resolvedOutput

if ($EnforceTargets -and $report.targetEvaluation.overallCustomTraceStatus -ne 'pass') {
    throw "A4S custom runtime trace targets did not pass. Review '$resolvedOutput'."
}
