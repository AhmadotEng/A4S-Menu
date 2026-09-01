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

if (-not ('A4STraceFileLeaseNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class A4STraceFileLeaseNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME { public uint LowDateTime, HighDateTime; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks;
        public uint FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    public static string Identity(SafeFileHandle file)
    {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return string.Format(CultureInfo.InvariantCulture, "{0:X8}:{1:X8}{2:X8}",
            information.VolumeSerialNumber, information.FileIndexHigh, information.FileIndexLow);
    }
}
'@
}

function Resolve-A4SOutputPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Assert-A4SReparseFreePath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not $root) { throw "Artifact path is not rooted: '$Path'." }
    if ($fullPath.Substring($root.Length).Contains(':')) {
        throw "Artifact paths may not use alternate data streams: '$fullPath'."
    }

    $current = $fullPath
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Trace conversion refuses a reparse-point path component: '$($item.FullName)'."
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or [StringComparer]::OrdinalIgnoreCase.Equals($parent, $current)) { break }
        $current = $parent
    }
}

function Ensure-A4SSafeParentDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $directory = Split-Path -Parent $Path
    if (-not $directory) { throw "Artifact path has no parent directory: '$Path'." }
    Assert-A4SReparseFreePath -Path $directory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Assert-A4SReparseFreePath -Path $directory
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

function Get-A4SStreamSha256 {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    $position = $Stream.Position
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-', '')
    } finally {
        $Stream.Position = $position
        $sha.Dispose()
    }
}

function New-A4SReadLease {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)

    Assert-A4SReparseFreePath -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name is not a regular file: '$Path'." }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
    try {
        return [pscustomobject]@{
            name = $Name
            path = [IO.Path]::GetFullPath($Path)
            stream = $stream
            identity = [A4STraceFileLeaseNative]::Identity($stream.SafeFileHandle)
            length = $stream.Length
            sha256 = Get-A4SStreamSha256 -Stream $stream
        }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Close-A4SReadLease {
    param($Lease)
    if ($Lease -and $Lease.stream) {
        $Lease.stream.Dispose()
        $Lease.stream = $null
    }
}

function Assert-A4SLeaseStillMatchesPath {
    param([Parameter(Mandatory)]$Lease)

    Assert-A4SReparseFreePath -Path $Lease.path
    $verification = New-A4SReadLease -Name "$($Lease.name) verification" -Path $Lease.path
    try {
        if ($verification.identity -ne $Lease.identity -or
            $verification.length -ne $Lease.length -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals($verification.sha256, $Lease.sha256)) {
            throw "$($Lease.name) changed identity or bytes while trace conversion was running: '$($Lease.path)'."
        }
    } finally { Close-A4SReadLease -Lease $verification }
}

function Assert-A4SNoPhysicalAliases {
    param([Parameter(Mandatory)][object[]]$Leases)

    for ($left = 0; $left -lt $Leases.Count; $left++) {
        for ($right = $left + 1; $right -lt $Leases.Count; $right++) {
            if ([StringComparer]::Ordinal.Equals($Leases[$left].identity, $Leases[$right].identity)) {
                throw "Trace conversion refuses physical aliases: $($Leases[$left].name) and $($Leases[$right].name) identify the same file."
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

function Write-A4SJsonStage {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Get-A4SFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
    try { return Get-A4SStreamSha256 -Stream $stream }
    finally { $stream.Dispose() }
}

$events = @()
$sourceType = ''
$sourcePath = ''
$sourceHash = ''
$rawEtlPreserved = $false
$decodedXml = $null
$decodedXmlHash = $null
$resolvedOutput = $null
$sourceLease = $null
$xmlTargetLease = $null
$jsonTargetLease = $null
$decodedXmlStage = $null
$jsonStage = $null
$conversionMutex = [Threading.Mutex]::new($false, 'Local\A4SMenu.TraceArtifactPublication.v1')
$ownsConversionMutex = $false
try { $ownsConversionMutex = $conversionMutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $ownsConversionMutex = $true }
if (-not $ownsConversionMutex) {
    $conversionMutex.Dispose()
    throw 'Another A4S trace conversion is publishing artifacts in this Windows session. Retry after it completes.'
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Etl') {
        $sourcePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $EtlPath -ErrorAction Stop).ProviderPath)
        if ([IO.Path]::GetExtension($sourcePath) -ine '.etl') { throw "Expected an .etl input; received '$sourcePath'." }
        $sourceType = 'etl'
        $rawEtlPreserved = $true
        if (-not $OutputPath) { $OutputPath = "$([IO.Path]::ChangeExtension($sourcePath, $null)).a4s-runtime.json" }
        $resolvedOutput = Resolve-A4SOutputPath $OutputPath
        if (-not $TracerptXmlPath) { $TracerptXmlPath = [IO.Path]::ChangeExtension($sourcePath, '.tracerpt.xml') }
        $decodedXml = Resolve-A4SOutputPath $TracerptXmlPath
        Assert-A4SDistinctArtifactPaths ([ordered]@{
            rawEtlInput = $sourcePath
            decodedXml = $decodedXml
            jsonReport = $resolvedOutput
        })
        foreach ($path in @($sourcePath, $decodedXml, $resolvedOutput)) { Assert-A4SReparseFreePath -Path $path }
        Ensure-A4SSafeParentDirectory -Path $decodedXml
        Ensure-A4SSafeParentDirectory -Path $resolvedOutput

        $xmlExists = [IO.File]::Exists($decodedXml)
        $jsonExists = [IO.File]::Exists($resolvedOutput)
        foreach ($target in @($decodedXml, $resolvedOutput)) {
            if ((Test-Path -LiteralPath $target) -and -not [IO.File]::Exists($target)) {
                throw "Derived artifact target is not a regular file: '$target'."
            }
        }
        if (-not $Force -and ($xmlExists -or $jsonExists)) {
            throw "A derived XML or JSON artifact already exists. Use -Force only to transactionally replace a complete, recognizable derived pair."
        }
        $sourceLease = New-A4SReadLease -Name 'raw ETL input' -Path $sourcePath
        if ($xmlExists) { $xmlTargetLease = New-A4SReadLease -Name 'decoded XML target' -Path $decodedXml }
        if ($jsonExists) { $jsonTargetLease = New-A4SReadLease -Name 'JSON report target' -Path $resolvedOutput }
        $artifactLeases = @(@($sourceLease, $xmlTargetLease, $jsonTargetLease) | Where-Object { $_ })
        Assert-A4SNoPhysicalAliases -Leases $artifactLeases
        if ($xmlTargetLease) { Assert-A4SExistingDerivedXml -Path $decodedXml }
        if ($jsonTargetLease) { Assert-A4SExistingDerivedReport -Path $resolvedOutput }
        if ($Force -and ($xmlExists -xor $jsonExists)) {
            throw '-Force requires both prior ETL-derived XML and JSON artifacts to exist, or neither; an incomplete pair is refused.'
        }
        $sourceHash = $sourceLease.sha256

        $tracerpt = Join-Path $env:SystemRoot 'System32\tracerpt.exe'
        if (-not (Test-Path -LiteralPath $tracerpt -PathType Leaf)) { throw "Windows tracerpt.exe was not found at '$tracerpt'." }
        $decodedXmlStage = "$decodedXml.partial-$PID-$([Guid]::NewGuid().ToString('N')).xml"
        $decodeOutput = @(& $tracerpt $sourcePath -o $decodedXmlStage -of XML -lr -y 2>&1)
        $decodeExitCode = $LASTEXITCODE
        if ($decodeExitCode -ne 0) {
            throw "tracerpt failed with exit code $decodeExitCode. Raw ETL remains unchanged at '$sourcePath'. Output: $($decodeOutput -join ' ')"
        }
        $decodedXmlHash = Get-A4SFileSha256 -Path $decodedXmlStage
        $events = @(ConvertFrom-A4STracerptXml -Path $decodedXmlStage -ExpectedProcessId $ExpectedProcessId)
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $decodedXmlHash, (Get-A4SFileSha256 -Path $decodedXmlStage))) {
            throw "The staged tracerpt XML changed while it was parsed: '$decodedXmlStage'."
        }
        Assert-A4SLeaseStillMatchesPath -Lease $sourceLease
        if ($events.Count -eq 0) {
            throw "No decodable A4SMenu.Runtime events were found. Raw ETL remains at '$sourcePath'."
        }
    } else {
        $sourcePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $EventJsonPath -ErrorAction Stop).ProviderPath)
        $sourceType = 'syntheticJson'
        if (-not $OutputPath) { $OutputPath = "$sourcePath.a4s-runtime.json" }
        $resolvedOutput = Resolve-A4SOutputPath $OutputPath
        Assert-A4SDistinctArtifactPaths ([ordered]@{
            eventJsonInput = $sourcePath
            jsonReport = $resolvedOutput
        })
        foreach ($path in @($sourcePath, $resolvedOutput)) { Assert-A4SReparseFreePath -Path $path }
        Ensure-A4SSafeParentDirectory -Path $resolvedOutput
        if ((Test-Path -LiteralPath $resolvedOutput) -and -not [IO.File]::Exists($resolvedOutput)) {
            throw "Derived report target is not a regular file: '$resolvedOutput'."
        }
        $jsonExists = [IO.File]::Exists($resolvedOutput)
        if ($jsonExists -and -not $Force) {
            throw "Report already exists at '$resolvedOutput'. Use -Force to replace the derived JSON report."
        }
        $sourceLease = New-A4SReadLease -Name 'synthetic event input' -Path $sourcePath
        if ($jsonExists) { $jsonTargetLease = New-A4SReadLease -Name 'JSON report target' -Path $resolvedOutput }
        $artifactLeases = @(@($sourceLease, $jsonTargetLease) | Where-Object { $_ })
        Assert-A4SNoPhysicalAliases -Leases $artifactLeases
        if ($jsonTargetLease) { Assert-A4SExistingDerivedReport -Path $resolvedOutput }
        $sourceHash = $sourceLease.sha256
        $events = @(Import-A4SEventJson -Path $sourcePath -ExpectedProcessId $ExpectedProcessId)
        Assert-A4SLeaseStillMatchesPath -Lease $sourceLease
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

    if ($EnforceTargets -and $report.targetEvaluation.overallCustomTraceStatus -ne 'pass') {
        throw 'A4S custom runtime trace targets did not pass; no derived artifact replacement was published.'
    }

    $jsonStage = "$resolvedOutput.partial-$PID-$([Guid]::NewGuid().ToString('N')).json"
    Write-A4SJsonStage -Path $jsonStage -Value $report
    $jsonStageHash = Get-A4SFileSha256 -Path $jsonStage

    Assert-A4SLeaseStillMatchesPath -Lease $sourceLease
    if ($xmlTargetLease) { Assert-A4SLeaseStillMatchesPath -Lease $xmlTargetLease }
    if ($jsonTargetLease) { Assert-A4SLeaseStillMatchesPath -Lease $jsonTargetLease }
    Close-A4SReadLease -Lease $xmlTargetLease
    Close-A4SReadLease -Lease $jsonTargetLease
    Assert-A4SReparseFreePath -Path $resolvedOutput

    if ($decodedXml) {
        Assert-A4SReparseFreePath -Path $decodedXml
        $expectedXmlHash = $decodedXmlHash
        $expectedJsonHash = $jsonStageHash
        $xmlValidationPath = $decodedXml
        $jsonValidationPath = $resolvedOutput
        $postPublishValidation = {
            $actualXmlHash = (Get-FileHash -LiteralPath $xmlValidationPath -Algorithm SHA256).Hash
            $actualJsonHash = (Get-FileHash -LiteralPath $jsonValidationPath -Algorithm SHA256).Hash
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($expectedXmlHash, $actualXmlHash) -or
                -not [StringComparer]::OrdinalIgnoreCase.Equals($expectedJsonHash, $actualJsonHash)) {
                throw 'Published XML/JSON bytes do not match the transaction stages.'
            }
        }.GetNewClosure()
        Publish-A4SArtifactPairTransaction -XmlStagedPath $decodedXmlStage `
            -XmlDestinationPath $decodedXml -JsonStagedPath $jsonStage `
            -JsonDestinationPath $resolvedOutput -PostPublishValidation $postPublishValidation
        $decodedXmlStage = $null
        $jsonStage = $null
    } else {
        $expectedJsonHash = $jsonStageHash
        $jsonValidationPath = $resolvedOutput
        $postPublishValidation = {
            $actualJsonHash = (Get-FileHash -LiteralPath $jsonValidationPath -Algorithm SHA256).Hash
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($expectedJsonHash, $actualJsonHash)) {
                throw 'Published JSON bytes do not match the transaction stage.'
            }
        }.GetNewClosure()
        Publish-A4SSingleArtifactTransaction -StagedPath $jsonStage `
            -DestinationPath $resolvedOutput -PostPublishValidation $postPublishValidation
        $jsonStage = $null
    }

    Write-Output $resolvedOutput
} finally {
    try {
        Close-A4SReadLease -Lease $xmlTargetLease
        Close-A4SReadLease -Lease $jsonTargetLease
        Close-A4SReadLease -Lease $sourceLease
        foreach ($stage in @($decodedXmlStage, $jsonStage)) {
            if ($stage -and [IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        }
    } finally {
        if ($ownsConversionMutex) { $conversionMutex.ReleaseMutex() }
        $conversionMutex.Dispose()
    }
}
