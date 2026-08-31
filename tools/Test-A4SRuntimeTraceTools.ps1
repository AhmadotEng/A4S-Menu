[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-A4S {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "A4S runtime trace self-test failed: $Message" }
}

$ownedFiles = @(
    'A4SRuntimeTrace.Core.psm1',
    'Convert-A4SRuntimeTrace.ps1',
    'Capture-A4SRuntimeTrace.ps1',
    'Test-A4SRuntimeTraceTools.ps1'
)
foreach ($name in $ownedFiles) {
    $path = Join-Path $PSScriptRoot $name
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Assert-A4S ($parseErrors.Count -eq 0) "$name has PowerShell parse errors: $($parseErrors -join '; ')"
}

$capturePath = Join-Path $PSScriptRoot 'Capture-A4SRuntimeTrace.ps1'
$captureText = Get-Content -LiteralPath $capturePath -Raw
Assert-A4S ($captureText -match '\[switch\]\$AllowMenuAutomation') 'capture tool has no explicit AllowMenuAutomation switch'
Assert-A4S ($captureText -match 'if \(-not \$AllowMenuAutomation\)') 'capture gate is not enforced before preflight'
Assert-A4S ($captureText -notmatch '(?i)Start-Process|Stop-Process|Restart-Computer|Stop-Computer|--rehook|--reset-safety|Invoke-WebRequest|Invoke-RestMethod') 'capture tool contains a forbidden process, injection, restart, or network primitive'
Assert-A4S ($captureText -notmatch 'VisibleMenuWindows\(0\)') 'capture cleanup can inspect or toggle based on a menu from an unvalidated process'
Assert-A4S ($captureText -match 'LoadedImageIdentity' -and $captureText -match 'FileImageIdentity') 'capture preflight does not compare resident and staged PE build identities'
Assert-A4S ($captureText -match 'ExpectedCycleCount\s*=\s*\$CapturedCycles') 'capture does not bind report completeness to the requested cycle count'
Assert-A4S ($captureText -match '\$sessionCreateAttempted\s*=\s*\$true[\s\S]+Invoke-A4SLogman -Arguments \$startArguments') 'ETW create attempts are not armed for unconditional cleanup before logman runs'
Assert-A4S ($captureText -match 'Invoke-A4SLogman -Arguments @\(''stop'', \$sessionName, ''-ets''\)') 'ETW session teardown is missing'

$captureTokens = $null
$captureParseErrors = $null
$captureAst = [Management.Automation.Language.Parser]::ParseFile(
    $capturePath, [ref]$captureTokens, [ref]$captureParseErrors)
$interopSources = @($captureAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'public static class A4SRuntimeTraceNative'
}, $true))
Assert-A4S ($interopSources.Count -eq 1) 'could not uniquely locate the embedded native interop source'
if (-not ('A4SRuntimeTraceNative' -as [type])) {
    Add-Type -TypeDefinition $interopSources[0].Value
}
Assert-A4S ($null -ne ('A4SRuntimeTraceNative' -as [type])) 'embedded native interop source did not compile'

$stagedProduct = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build\stage\A4SProduct'))
foreach ($stagedName in @('A4SMenuHost.exe', 'A4SMenu.dll')) {
    $stagedPath = Join-Path $stagedProduct $stagedName
    if (Test-Path -LiteralPath $stagedPath -PathType Leaf) {
        $identity = [A4SRuntimeTraceNative]::FileImageIdentity($stagedPath)
        Assert-A4S ($identity -match '^timestamp=[0-9a-f]{8};size=[0-9a-f]{8};checksum=[0-9a-f]{8};rsds=[0-9a-f]{32};age=[1-9][0-9]*$') "$stagedName has no strong parseable PE/RSDS identity"
    }
}

$gateWorked = $false
try { & $capturePath } catch {
    if ($_.Exception.Message -match 'never starts the host, injects Explorer, or\s+restarts Explorer') { $gateWorked = $true }
}
Assert-A4S $gateWorked 'capture script did not fail closed without -AllowMenuAutomation'

Import-Module (Join-Path $PSScriptRoot 'A4SRuntimeTrace.Core.psm1') -Force
$baseTime = [DateTimeOffset]::Parse('2026-08-31T12:00:00.0000000Z')
$synthetic = [Collections.Generic.List[object]]::new()
function Add-SyntheticEvent {
    param(
        [double]$Milliseconds,
        [int]$Event,
        [int]$Stage,
        [uint64]$Operation,
        [int]$ActivationSource = 0,
        [uint32]$Value = 0,
        [bool]$CacheHit = $false
    )
    [void]$synthetic.Add([pscustomobject][ordered]@{
        TimestampUtc = $baseTime.AddMilliseconds($Milliseconds).ToString('o')
        Event = $Event
        Stage = $Stage
        Operation = $Operation
        Value = $Value
        CacheHit = $CacheHit
        ActivationSource = $ActivationSource
        Window = '0x100'
        ProcessId = 4242
        ThreadId = 17
    })
}

# First observed cycle is explicitly classified cold; the next two are warm.
Add-SyntheticEvent 0 1 0 0 1
Add-SyntheticEvent 1 2 1 100 1
Add-SyntheticEvent 2 3 1 101
Add-SyntheticEvent 6 3 2 101 0 12 $true
Add-SyntheticEvent 60 7 0 100
Add-SyntheticEvent 80 6 0 100
Add-SyntheticEvent 80.2 2 2 100
Add-SyntheticEvent 99 1 0 100 1
Add-SyntheticEvent 100 10 1 102
Add-SyntheticEvent 108 11 0 100
Add-SyntheticEvent 108.1 10 2 102

Add-SyntheticEvent 200 1 0 0 1
Add-SyntheticEvent 201 2 1 200 1
Add-SyntheticEvent 202 5 1 201
Add-SyntheticEvent 204 5 2 201
Add-SyntheticEvent 217 7 0 200
Add-SyntheticEvent 221 6 0 200
Add-SyntheticEvent 221.2 2 2 200
Add-SyntheticEvent 249 1 0 200 1
Add-SyntheticEvent 250 10 1 202
Add-SyntheticEvent 255 11 0 200
Add-SyntheticEvent 255.1 10 2 202

Add-SyntheticEvent 300 1 0 0 1
Add-SyntheticEvent 301 2 1 300 1
Add-SyntheticEvent 318 7 0 300
Add-SyntheticEvent 331 6 0 300
Add-SyntheticEvent 331.1 2 2 300
Add-SyntheticEvent 349 1 0 300 1
Add-SyntheticEvent 350 10 1 301
Add-SyntheticEvent 354 11 0 300
Add-SyntheticEvent 354.1 10 2 301

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ("A4SRuntimeTraceSelfTest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $jsonPath = Join-Path $tempRoot 'events.json'
    $outputPath = Join-Path $tempRoot 'report.json'
    @($synthetic) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    [void](& (Join-Path $PSScriptRoot 'Convert-A4SRuntimeTrace.ps1') -EventJsonPath $jsonPath `
        -ExpectedProcessId 4242 -ColdSampleCount 1 -ExpectedCycleCount 3 `
        -MinimumWarmSampleCount 2 -MinimumCloseSampleCount 3 -RefreshRateHz 60 -OutputPath $outputPath)
    $report = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-A4S ($report.schemaVersion -eq 2) 'runtime report schema was not advanced for strict completeness fields'
    Assert-A4S ($report.counts.cycles -eq 3) 'synthetic JSON did not correlate three cycles'
    Assert-A4S ($report.counts.diagnostics -eq 0) 'complete synthetic JSON produced diagnostics'
    Assert-A4S ($report.samplePolicy.coldSampleCount -eq 1 -and $report.samplePolicy.warmSampleCount -eq 2) 'cold/warm sample policy is wrong'
    Assert-A4S ([Math]::Abs([double]$report.statistics.warmActivationToVisible.p95Milliseconds - 31.0) -lt 0.001) 'warm p95 was not nearest-rank 31 ms'
    Assert-A4S ($report.targetEvaluation.overallCustomTraceStatus -eq 'pass') 'passing synthetic trace failed targets'
    Assert-A4S ($report.cycles[1].activationSource -eq 'host') 'activation source was not decoded'
    Assert-A4S ($report.statistics.phases.backdropPrepare.count -eq 1) 'nested phase duration was not reported'

    $xmlPath = Join-Path $tempRoot 'tracerpt.xml'
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $writer = [Xml.XmlWriter]::Create($xmlPath, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('Events', 'http://schemas.microsoft.com/win/2004/08/events/event')
        foreach ($event in $synthetic) {
            $writer.WriteStartElement('Event')
            $writer.WriteStartElement('System')
            $writer.WriteStartElement('Provider')
            $writer.WriteAttributeString('Name', 'A4SMenu.Runtime')
            $writer.WriteAttributeString('Guid', '{74a9f986-c7ab-429a-9571-df0fb7f4a33c}')
            $writer.WriteEndElement()
            $writer.WriteStartElement('TimeCreated')
            $writer.WriteAttributeString('SystemTime', [string]$event.TimestampUtc)
            $writer.WriteEndElement()
            $writer.WriteStartElement('Execution')
            $writer.WriteAttributeString('ProcessID', '4242')
            $writer.WriteAttributeString('ThreadID', '17')
            $writer.WriteEndElement()
            $writer.WriteEndElement()
            $writer.WriteStartElement('EventData')
            foreach ($field in @('Event', 'Stage', 'Operation', 'Value', 'CacheHit', 'ActivationSource', 'Window', 'ProcessId', 'ThreadId')) {
                $writer.WriteStartElement('Data')
                $writer.WriteAttributeString('Name', $field)
                # The ETW System/Execution identity is authoritative. A payload
                # field with the same name must not override it.
                $writer.WriteString($(if ($field -eq 'ProcessId') { '9999' } else { [string]$event.$field }))
                $writer.WriteEndElement()
            }
            $writer.WriteEndElement()
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    } finally { $writer.Dispose() }

    $xmlEvents = @(ConvertFrom-A4STracerptXml -Path $xmlPath -ExpectedProcessId 4242)
    Assert-A4S ($xmlEvents.Count -eq $synthetic.Count) 'tracerpt XML parser lost synthetic events'
    $xmlReport = ConvertTo-A4SRuntimeReport -Events $xmlEvents -ColdSampleCount 1 `
        -ExpectedCycleCount 3 -MinimumWarmSampleCount 2 -MinimumCloseSampleCount 3 -RefreshRateHz 60
    Assert-A4S ($xmlReport.counts.cycles -eq 3 -and $xmlReport.counts.diagnostics -eq 0) 'tracerpt XML correlation disagrees with JSON correlation'

    [xml]$wrongProviderDocument = Get-Content -LiteralPath $xmlPath -Raw
    $wrongProviderFirstEvent = $wrongProviderDocument.SelectSingleNode("//*[local-name()='Event']")
    $wrongProviderNode = $wrongProviderFirstEvent.SelectSingleNode("./*[local-name()='System']/*[local-name()='Provider']")
    $wrongProviderNode.SetAttribute('Guid', '{11111111-2222-3333-4444-555555555555}')
    $wrongProviderPath = Join-Path $tempRoot 'wrong-provider.xml'
    $wrongProviderDocument.Save($wrongProviderPath)
    $wrongProviderEvents = @(ConvertFrom-A4STracerptXml -Path $wrongProviderPath -ExpectedProcessId 4242)
    Assert-A4S ($wrongProviderEvents.Count -eq $synthetic.Count - 1) 'provider-name fallback accepted an event carrying the wrong provider GUID'

    $missingWholeCycleReport = ConvertTo-A4SRuntimeReport -Events $xmlEvents -ColdSampleCount 1 `
        -ExpectedCycleCount 4 -MinimumWarmSampleCount 2 -MinimumCloseSampleCount 3 -RefreshRateHz 60
    Assert-A4S (@($missingWholeCycleReport.diagnostics | Where-Object { $_.kind -eq 'cycleCountMismatch' }).Count -eq 1) 'a wholly missing cycle was not diagnosed'
    Assert-A4S ($missingWholeCycleReport.targetEvaluation.overallCustomTraceStatus -eq 'fail') 'a wholly missing cycle could still pass targets'

    $noWarmReport = ConvertTo-A4SRuntimeReport -Events $xmlEvents -ColdSampleCount 3 `
        -ExpectedCycleCount 3 -MinimumWarmSampleCount 1 -MinimumCloseSampleCount 3 -RefreshRateHz 60
    Assert-A4S ($noWarmReport.targetEvaluation.warmOpen.status -eq 'notMeasured') 'a trace with no warm sample fabricated a warm metric'
    Assert-A4S ($noWarmReport.targetEvaluation.overallCustomTraceStatus -ne 'pass') 'a trace with no warm sample could pass targets'

    $missingOpenActivationEvents = @($xmlEvents | Where-Object {
        -not ($_.eventId -eq 1 -and $_.operation -eq 0 -and $_.timestampUtc -eq $baseTime.AddMilliseconds(200))
    })
    $missingOpenActivationReport = ConvertTo-A4SRuntimeReport -Events $missingOpenActivationEvents `
        -ColdSampleCount 1 -ExpectedCycleCount 3 -MinimumWarmSampleCount 1 `
        -MinimumCloseSampleCount 2 -RefreshRateHz 60
    Assert-A4S (@($missingOpenActivationReport.diagnostics | Where-Object {
        $_.kind -eq 'incompleteCycle' -and $_.cycle -eq 2 -and $_.missing -contains 'activationRequested'
    }).Count -eq 1) 'a prior close activation was incorrectly reused as the next open activation'

    $mixedProcessEvents = @($xmlEvents) + [pscustomobject][ordered]@{
        sequence = 999; timestampUtc = $baseTime.AddMilliseconds(390); eventId = 1
        eventName = 'activationRequested'; stageId = 0; stageName = 'instant'; operation = 0
        value = 0; cacheHit = $false; activationSourceId = 1; activationSource = 'host'
        window = 0; processId = 8484; threadId = 17
    }
    $mixedProcessReport = ConvertTo-A4SRuntimeReport -Events $mixedProcessEvents -ColdSampleCount 1 `
        -ExpectedCycleCount 3 -MinimumWarmSampleCount 2 -MinimumCloseSampleCount 3 -RefreshRateHz 60
    Assert-A4S (@($mixedProcessReport.diagnostics | Where-Object { $_.kind -eq 'nonUniqueProcess' }).Count -eq 1) 'events from multiple processes were not diagnosed'

    $duplicateVisibleEvents = @($xmlEvents) + [pscustomobject][ordered]@{
        TimestampUtc = $baseTime.AddMilliseconds(221.1).ToString('o'); Event = 6
        Stage = 0; Operation = 200; Value = 0; CacheHit = $false; ActivationSource = 0
        Window = '0x100'; ProcessId = 4242; ThreadId = 17
    }
    $duplicateVisibleReport = ConvertTo-A4SRuntimeReport -Events $duplicateVisibleEvents `
        -ColdSampleCount 1 -ExpectedCycleCount 3 -MinimumWarmSampleCount 2 `
        -MinimumCloseSampleCount 3 -RefreshRateHz 60
    Assert-A4S (@($duplicateVisibleReport.diagnostics | Where-Object {
        $_.kind -eq 'duplicateCycleMarker' -and $_.cycle -eq 2 -and $_.marker -eq 'windowVisible'
    }).Count -eq 1) 'a duplicate visibility marker was not diagnosed'
    Assert-A4S ($duplicateVisibleReport.targetEvaluation.overallCustomTraceStatus -eq 'fail') 'duplicate cycle markers could still pass targets'

    $incomplete = @($xmlEvents) + [pscustomobject][ordered]@{
        TimestampUtc = $baseTime.AddMilliseconds(400).ToString('o')
        Event = 12; Stage = 1; Operation = 999; Value = 0; CacheHit = $false
        ActivationSource = 0; Window = '0x0'; ProcessId = 4242; ThreadId = 17
    }
    $badReport = ConvertTo-A4SRuntimeReport -Events $incomplete -ColdSampleCount 1 `
        -ExpectedCycleCount 3 -MinimumWarmSampleCount 2 -MinimumCloseSampleCount 3 -RefreshRateHz 60
    Assert-A4S (@($badReport.diagnostics | Where-Object { $_.kind -eq 'beginWithoutEnd' -and $_.operation -eq 999 }).Count -eq 1) 'unmatched phase begin was not diagnosed'
    Assert-A4S ($badReport.targetEvaluation.completeness.status -eq 'fail') 'incomplete trace did not fail completeness target'

    $missingExpectedOutput = Join-Path $tempRoot 'missing-expected.json'
    $enforcementRejected = $false
    try {
        [void](& (Join-Path $PSScriptRoot 'Convert-A4SRuntimeTrace.ps1') -EventJsonPath $jsonPath `
            -ExpectedProcessId 4242 -ColdSampleCount 1 -MinimumWarmSampleCount 2 `
            -MinimumCloseSampleCount 3 -RefreshRateHz 60 -OutputPath $missingExpectedOutput -EnforceTargets)
    } catch {
        if ($_.Exception.Message -match 'did not pass') { $enforcementRejected = $true }
    }
    Assert-A4S $enforcementRejected 'target enforcement passed without an expected cycle count'
} finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        $resolvedTempRoot.Length -gt $tempBase.Length) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'PASS: A4S runtime trace scripts parse cleanly, fail closed without automation consent, validate staged PE/RSDS identities when present, decode synthetic tracerpt XML, reject truncated/mixed/ambiguous traces, enforce sample sufficiency, and diagnose incomplete operations without starting or injecting the product.'
