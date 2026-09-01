[CmdletBinding(DefaultParameterSetName = 'Etl')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Etl')]
    [string]$EtlPath,
    [Parameter(Mandatory, ParameterSetName = 'SyntheticJson')]
    [string]$EventJsonPath,
    [uint32]$ExpectedProcessId = 0,
    [ValidateRange(0, 1000)]
    [int]$ColdSampleCount = 0,
    [ValidateRange(0, 1000)]
    [int]$ExpectedCycleCount = 0,
    [ValidateRange(1, 1000)]
    [int]$MinimumWarmSampleCount = 20,
    [ValidateRange(1, 1000)]
    [int]$MinimumCloseSampleCount = 20,
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

function Assert-A4SDistinctArtifactPaths {
    param([Parameter(Mandatory)][Collections.IDictionary]$Paths)

    $names = @($Paths.Keys)
    for ($left = 0; $left -lt $names.Count; $left++) {
        for ($right = $left + 1; $right -lt $names.Count; $right++) {
            $leftName = [string]$names[$left]
            $rightName = [string]$names[$right]
            if ([StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetFullPath([string]$Paths[$leftName]),
                [IO.Path]::GetFullPath([string]$Paths[$rightName]))) {
                throw "Trace conversion requires distinct $leftName and $rightName paths. -Force never authorizes replacing the raw input or aliasing two derived artifacts."
            }
        }
    }
}

function Assert-A4SExistingDerivedReport {
    param([Parameter(Mandatory)][string]$Path)

    try { $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "-Force refused to replace '$Path' because it is not a readable A4S derived JSON report." }
    if (-not $existing.PSObject.Properties['schemaVersion'] -or
        -not $existing.PSObject.Properties['provider'] -or
        -not $existing.provider -or
        -not $existing.provider.PSObject.Properties['name'] -or
        -not $existing.provider.PSObject.Properties['guid'] -or
        [int]$existing.schemaVersion -ne 2 -or
        [string]$existing.provider.name -ne 'A4SMenu.Runtime' -or
        [string]$existing.provider.guid -ne '74a9f986-c7ab-429a-9571-df0fb7f4a33c') {
        throw "-Force refused to replace '$Path' because it is not an A4SMenu.Runtime schema-2 derived report."
    }
}

function Assert-A4SExistingDerivedXml {
    param([Parameter(Mandatory)][string]$Path)

    try { $existingEvents = @(ConvertFrom-A4STracerptXml -Path $Path -ExpectedProcessId 0) }
    catch { throw "-Force refused to replace '$Path' because it is not readable A4S tracerpt XML." }
    if ($existingEvents.Count -eq 0) {
        throw "-Force refused to replace '$Path' because it contains no A4SMenu.Runtime events."
    }
}

function Write-A4SJsonCreateNew {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = "$Path.partial-$PID-$([Guid]::NewGuid().ToString('N'))"
    $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    [IO.File]::Move($temporary, $Path)
}

$events = @()
$sourceType = ''
$sourcePath = ''
$sourceHash = ''
$rawEtlPreserved = $false
$decodedXml = $null
$decodedXmlHash = $null

if ($PSCmdlet.ParameterSetName -eq 'Etl') {
    $sourcePath = (Resolve-Path -LiteralPath $EtlPath -ErrorAction Stop).ProviderPath
    if ([IO.Path]::GetExtension($sourcePath) -ine '.etl') { throw "Expected an .etl input; received '$sourcePath'." }
    $sourceType = 'etl'
    if (-not $OutputPath) { $OutputPath = "$([IO.Path]::ChangeExtension($sourcePath, $null)).a4s-runtime.json" }
    $resolvedOutput = Resolve-A4SOutputPath $OutputPath
    if (-not $TracerptXmlPath) { $TracerptXmlPath = [IO.Path]::ChangeExtension($sourcePath, '.tracerpt.xml') }
    $decodedXml = Resolve-A4SOutputPath $TracerptXmlPath
    Assert-A4SDistinctArtifactPaths ([ordered]@{
        rawEtlInput = $sourcePath
        decodedXml = $decodedXml
        jsonReport = $resolvedOutput
    })
    if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
        throw "Report already exists at '$resolvedOutput'. Use -Force to replace the derived JSON report."
    }
    if ((Test-Path -LiteralPath $resolvedOutput -PathType Leaf) -and $Force) {
        Assert-A4SExistingDerivedReport -Path $resolvedOutput
    }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $rawEtlPreserved = $true
    if ((Test-Path -LiteralPath $decodedXml) -and -not $Force) {
        throw "Decoded tracerpt XML already exists at '$decodedXml'. Use -Force to replace only that derived file; the ETL is never changed."
    }
    if ((Test-Path -LiteralPath $decodedXml -PathType Leaf) -and $Force) {
        Assert-A4SExistingDerivedXml -Path $decodedXml
    }
    $xmlDirectory = Split-Path -Parent $decodedXml
    if (-not (Test-Path -LiteralPath $xmlDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $xmlDirectory -Force | Out-Null
    }
    $tracerpt = Join-Path $env:SystemRoot 'System32\tracerpt.exe'
    if (-not (Test-Path -LiteralPath $tracerpt -PathType Leaf)) { throw "Windows tracerpt.exe was not found at '$tracerpt'." }
    $decodedXmlTemporary = "$decodedXml.partial-$PID-$([Guid]::NewGuid().ToString('N')).xml"
    $decodeOutput = @(& $tracerpt $sourcePath -o $decodedXmlTemporary -of XML -lr -y 2>&1)
    $decodeExitCode = $LASTEXITCODE
    if ($decodeExitCode -ne 0) {
        throw "tracerpt failed with exit code $decodeExitCode. Raw ETL remains at '$sourcePath'; partial derived output, if any, remains at '$decodedXmlTemporary'. Output: $($decodeOutput -join ' ')"
    }
    $decodedXmlHash = (Get-FileHash -LiteralPath $decodedXmlTemporary -Algorithm SHA256).Hash
    $events = @(ConvertFrom-A4STracerptXml -Path $decodedXmlTemporary -ExpectedProcessId $ExpectedProcessId)
    $postParseXmlHash = (Get-FileHash -LiteralPath $decodedXmlTemporary -Algorithm SHA256).Hash
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($decodedXmlHash, $postParseXmlHash)) {
        throw "The decoded tracerpt XML changed while it was parsed; refusing non-immutable evidence from '$decodedXmlTemporary'."
    }
    $postDecodeSourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($sourceHash, $postDecodeSourceHash)) {
        throw "The raw ETL changed while it was decoded; refusing non-immutable evidence from '$sourcePath'."
    }
    if ($events.Count -eq 0) {
        throw "No decodable A4SMenu.Runtime events were found. Raw ETL remains at '$sourcePath'; inspect '$decodedXmlTemporary' and verify the selected DLL contains provider 74a9f986-c7ab-429a-9571-df0fb7f4a33c."
    }
    if (Test-Path -LiteralPath $decodedXml -PathType Leaf) {
        $xmlBackup = "$decodedXml.backup-$PID-$([Guid]::NewGuid().ToString('N'))"
        $xmlReplaced = $false
        try {
            [IO.File]::Replace($decodedXmlTemporary, $decodedXml, $xmlBackup, $true)
            $xmlReplaced = $true
        } finally {
            if ($xmlReplaced -and [IO.File]::Exists($xmlBackup)) { [IO.File]::Delete($xmlBackup) }
        }
    } else {
        [IO.File]::Move($decodedXmlTemporary, $decodedXml)
    }
    $publishedXmlHash = (Get-FileHash -LiteralPath $decodedXml -Algorithm SHA256).Hash
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($decodedXmlHash, $publishedXmlHash)) {
        throw "The atomically published tracerpt XML does not match the parsed bytes at '$decodedXml'."
    }
} else {
    $sourcePath = (Resolve-Path -LiteralPath $EventJsonPath -ErrorAction Stop).ProviderPath
    $sourceType = 'syntheticJson'
    if (-not $OutputPath) { $OutputPath = "$sourcePath.a4s-runtime.json" }
    $resolvedOutput = Resolve-A4SOutputPath $OutputPath
    Assert-A4SDistinctArtifactPaths ([ordered]@{
        eventJsonInput = $sourcePath
        jsonReport = $resolvedOutput
    })
    if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
        throw "Report already exists at '$resolvedOutput'. Use -Force to replace the derived JSON report."
    }
    if ((Test-Path -LiteralPath $resolvedOutput -PathType Leaf) -and $Force) {
        Assert-A4SExistingDerivedReport -Path $resolvedOutput
    }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $events = @(Import-A4SEventJson -Path $sourcePath -ExpectedProcessId $ExpectedProcessId)
    $postImportSourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($sourceHash, $postImportSourceHash)) {
        throw "The synthetic event source changed while it was parsed; refusing non-immutable evidence from '$sourcePath'."
    }
    if ($events.Count -eq 0) { throw "No A4S runtime events were found in '$sourcePath'." }
}

$report = ConvertTo-A4SRuntimeReport -Events $events -ColdSampleCount $ColdSampleCount `
    -ExpectedCycleCount $ExpectedCycleCount -MinimumWarmSampleCount $MinimumWarmSampleCount `
    -MinimumCloseSampleCount $MinimumCloseSampleCount `
    -WarmOpenTargetMilliseconds $WarmOpenTargetMilliseconds -RefreshRateHz $RefreshRateHz `
    -SourceType $sourceType -SourcePath $sourcePath
$report.source | Add-Member -NotePropertyName sha256 -NotePropertyValue $sourceHash
$report.source | Add-Member -NotePropertyName rawEtlPreserved -NotePropertyValue $rawEtlPreserved
if ($decodedXml) { $report.source | Add-Member -NotePropertyName tracerptXmlPath -NotePropertyValue $decodedXml }
if ($decodedXml) { $report.source | Add-Member -NotePropertyName tracerptXmlSha256 -NotePropertyValue $decodedXmlHash }

if ((Test-Path -LiteralPath $resolvedOutput) -and $Force) {
    # Force applies only to derived files in an explicit conversion. Preserve
    # the old report until the replacement bytes are durable.
    $temporaryOutput = "$resolvedOutput.partial-$PID-$([Guid]::NewGuid().ToString('N'))"
    Write-A4SJsonCreateNew -Path $temporaryOutput -Value $report
    $outputBackup = "$resolvedOutput.backup-$PID-$([Guid]::NewGuid().ToString('N'))"
    $outputReplaced = $false
    try {
        [IO.File]::Replace($temporaryOutput, $resolvedOutput, $outputBackup, $true)
        $outputReplaced = $true
    } finally {
        if ($outputReplaced -and [IO.File]::Exists($outputBackup)) { [IO.File]::Delete($outputBackup) }
    }
} else {
    Write-A4SJsonCreateNew -Path $resolvedOutput -Value $report
}
Write-Output $resolvedOutput

if ($EnforceTargets -and $report.targetEvaluation.overallCustomTraceStatus -ne 'pass') {
    throw "A4S custom runtime trace targets did not pass. Review '$resolvedOutput'."
}
