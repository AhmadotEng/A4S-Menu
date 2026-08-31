Set-StrictMode -Version 2.0

$script:A4SProviderGuid = '74a9f986-c7ab-429a-9571-df0fb7f4a33c'
$script:A4SEventNames = @{
    1 = 'activationRequested'
    2 = 'openPath'
    3 = 'pinnedEnumeration'
    4 = 'iconLoad'
    5 = 'backdropPrepare'
    6 = 'windowVisible'
    7 = 'firstPaint'
    8 = 'programsEnumeration'
    9 = 'searchInitialization'
    10 = 'closePath'
    11 = 'windowHidden'
    12 = 'preload'
}
$script:A4SStageNames = @{
    0 = 'instant'
    1 = 'begin'
    2 = 'end'
}
$script:A4SActivationNames = @{
    0 = 'unknown'
    1 = 'host'
    2 = 'windowsKey'
    3 = 'startButton'
}

function ConvertTo-A4SUInt64 {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [uint64]0 }
    $text = ([string]$Value).Trim()
    if ($text.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
        return [Convert]::ToUInt64($text.Substring(2), 16)
    }
    return [Convert]::ToUInt64($text, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-A4SBoolean {
    param($Value)
    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $false }
    $text = ([string]$Value).Trim()
    return $text -eq '1' -or $text.Equals('true', [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-A4STimestamp {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new(([DateTime]$Value).ToUniversalTime()) }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-A4SPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $Default
    }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) { return $property.Value }
    return $Default
}

function New-A4SCanonicalEvent {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][int]$Sequence
    )
    $eventId = [int](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'Event'))
    $stageId = [int](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'Stage'))
    $activationId = [int](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'ActivationSource'))
    if (-not $script:A4SEventNames.ContainsKey($eventId)) { throw "Unknown A4S runtime Event value '$eventId'." }
    if (-not $script:A4SStageNames.ContainsKey($stageId)) { throw "Unknown A4S runtime Stage value '$stageId'." }
    if (-not $script:A4SActivationNames.ContainsKey($activationId)) { $activationId = 0 }

    $timestampValue = Get-A4SPropertyValue $InputObject 'TimestampUtc'
    if ($null -eq $timestampValue) { $timestampValue = Get-A4SPropertyValue $InputObject 'Timestamp' }
    if ($null -eq $timestampValue) { throw 'A runtime event has no TimestampUtc value.' }

    [pscustomobject][ordered]@{
        sequence = $Sequence
        timestampUtc = (ConvertTo-A4STimestamp $timestampValue)
        eventId = $eventId
        eventName = $script:A4SEventNames[$eventId]
        stageId = $stageId
        stageName = $script:A4SStageNames[$stageId]
        operation = [uint64](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'Operation'))
        value = [uint32](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'Value'))
        cacheHit = ConvertTo-A4SBoolean (Get-A4SPropertyValue $InputObject 'CacheHit')
        activationSourceId = $activationId
        activationSource = $script:A4SActivationNames[$activationId]
        window = [uint64](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'Window'))
        processId = [uint32](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'ProcessId'))
        threadId = [uint32](ConvertTo-A4SUInt64 (Get-A4SPropertyValue $InputObject 'ThreadId'))
    }
}

function Get-A4SXmlAttribute {
    param($Node, [string[]]$Names)
    if ($null -eq $Node -or $null -eq $Node.Attributes) { return $null }
    foreach ($name in $Names) {
        foreach ($attribute in $Node.Attributes) {
            if ($attribute.LocalName -ieq $name) { return $attribute.Value }
        }
    }
    return $null
}

function ConvertFrom-A4STracerptXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [uint32]$ExpectedProcessId = 0
    )
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    [xml]$document = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop
    $eventNodes = @($document.SelectNodes("//*[local-name()='Event']"))
    $result = [Collections.Generic.List[object]]::new()
    $sequence = 0
    foreach ($node in $eventNodes) {
        $system = $node.SelectSingleNode("./*[local-name()='System']")
        if ($null -eq $system) { continue }
        $provider = $system.SelectSingleNode("./*[local-name()='Provider']")
        $providerGuid = Get-A4SXmlAttribute $provider @('Guid', 'ProviderGuid')
        $providerName = Get-A4SXmlAttribute $provider @('Name', 'EventSourceName')
        $normalizedGuid = if ($providerGuid) { $providerGuid.Trim('{}').ToLowerInvariant() } else { '' }
        if ($normalizedGuid -ne $script:A4SProviderGuid -and $providerName -ne 'A4SMenu.Runtime') { continue }

        $timeNode = $system.SelectSingleNode("./*[local-name()='TimeCreated']")
        $timestamp = Get-A4SXmlAttribute $timeNode @('SystemTime')
        if (-not $timestamp) { continue }

        $payload = @{}
        foreach ($data in @($node.SelectNodes("./*[local-name()='EventData']//*[local-name()='Data']"))) {
            $name = Get-A4SXmlAttribute $data @('Name')
            if ($name) { $payload[$name] = $data.InnerText }
        }
        foreach ($leaf in @($node.SelectNodes("./*[local-name()='UserData']//*[not(*)]"))) {
            $name = Get-A4SXmlAttribute $leaf @('Name')
            if (-not $name) { $name = $leaf.LocalName }
            if ($name -and -not $payload.ContainsKey($name)) { $payload[$name] = $leaf.InnerText }
        }
        if (-not $payload.ContainsKey('Event') -or -not $payload.ContainsKey('Stage') -or
            -not $payload.ContainsKey('Operation')) { continue }

        $execution = $system.SelectSingleNode("./*[local-name()='Execution']")
        if (-not $payload.ContainsKey('ProcessId')) {
            $payload['ProcessId'] = Get-A4SXmlAttribute $execution @('ProcessID', 'ProcessId')
        }
        if (-not $payload.ContainsKey('ThreadId')) {
            $payload['ThreadId'] = Get-A4SXmlAttribute $execution @('ThreadID', 'ThreadId')
        }
        $payload['TimestampUtc'] = $timestamp
        $sequence++
        $canonical = New-A4SCanonicalEvent -InputObject $payload -Sequence $sequence
        if ($ExpectedProcessId -eq 0 -or $canonical.processId -eq $ExpectedProcessId) {
            [void]$result.Add($canonical)
        }
    }
    return @($result)
}

function Import-A4SEventJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [uint32]$ExpectedProcessId = 0
    )
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $root = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop | ConvertFrom-Json
    $sourceEvents = if ($root.PSObject.Properties['events']) { @($root.events) } else { @($root) }
    $result = [Collections.Generic.List[object]]::new()
    $sequence = 0
    foreach ($item in $sourceEvents) {
        $sequence++
        $canonical = New-A4SCanonicalEvent -InputObject $item -Sequence $sequence
        if ($ExpectedProcessId -eq 0 -or $canonical.processId -eq $ExpectedProcessId) {
            [void]$result.Add($canonical)
        }
    }
    return @($result)
}

function Get-A4SDurationMilliseconds {
    param($Start, $End)
    if ($null -eq $Start -or $null -eq $End) { return $null }
    return [Math]::Round((([DateTimeOffset]$End) - ([DateTimeOffset]$Start)).TotalMilliseconds, 3)
}

function Get-A4SStatistics {
    param([object[]]$Values)
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -eq 0) {
        return [pscustomobject][ordered]@{ count = 0; p50Milliseconds = $null; p95Milliseconds = $null; maxMilliseconds = $null; meanMilliseconds = $null }
    }
    $p50Index = [Math]::Max(0, [Math]::Ceiling(0.50 * $numbers.Count) - 1)
    $p95Index = [Math]::Max(0, [Math]::Ceiling(0.95 * $numbers.Count) - 1)
    return [pscustomobject][ordered]@{
        count = $numbers.Count
        p50Milliseconds = [Math]::Round($numbers[$p50Index], 3)
        p95Milliseconds = [Math]::Round($numbers[$p95Index], 3)
        maxMilliseconds = [Math]::Round($numbers[-1], 3)
        meanMilliseconds = [Math]::Round((($numbers | Measure-Object -Average).Average), 3)
    }
}

function ConvertTo-A4SRuntimeReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Events,
        [ValidateRange(0, 1000)][int]$ColdSampleCount = 0,
        [ValidateRange(1, 250)][double]$WarmOpenTargetMilliseconds = 50,
        [ValidateRange(20, 1000)][double]$RefreshRateHz = 60,
        [string]$SourceType = 'events',
        [string]$SourcePath = ''
    )
    $canonicalEvents = [Collections.Generic.List[object]]::new()
    $sequence = 0
    foreach ($event in @($Events)) {
        $sequence++
        if ($event.PSObject.Properties['eventId'] -and $event.PSObject.Properties['timestampUtc']) {
            $event.timestampUtc = ConvertTo-A4STimestamp $event.timestampUtc
            if (-not $event.PSObject.Properties['sequence']) { $event | Add-Member -NotePropertyName sequence -NotePropertyValue $sequence }
            [void]$canonicalEvents.Add($event)
        } else {
            [void]$canonicalEvents.Add((New-A4SCanonicalEvent -InputObject $event -Sequence $sequence))
        }
    }
    $orderedEvents = @($canonicalEvents | Sort-Object timestampUtc, sequence)
    $diagnostics = [Collections.Generic.List[object]]::new()
    $begins = @{}
    $phases = [Collections.Generic.List[object]]::new()

    foreach ($event in $orderedEvents) {
        if ($event.stageId -eq 1) {
            $key = "$($event.eventId):$($event.operation)"
            if ($begins.ContainsKey($key)) {
                [void]$diagnostics.Add([pscustomobject][ordered]@{ kind = 'duplicateBegin'; eventName = $event.eventName; operation = $event.operation; timestampUtc = $event.timestampUtc })
            } else { $begins[$key] = $event }
        } elseif ($event.stageId -eq 2) {
            $key = "$($event.eventId):$($event.operation)"
            if (-not $begins.ContainsKey($key)) {
                [void]$diagnostics.Add([pscustomobject][ordered]@{ kind = 'endWithoutBegin'; eventName = $event.eventName; operation = $event.operation; timestampUtc = $event.timestampUtc })
            } else {
                $begin = $begins[$key]
                [void]$begins.Remove($key)
                [void]$phases.Add([pscustomobject][ordered]@{
                    eventId = $event.eventId
                    eventName = $event.eventName
                    operation = $event.operation
                    startUtc = $begin.timestampUtc
                    endUtc = $event.timestampUtc
                    durationMilliseconds = Get-A4SDurationMilliseconds $begin.timestampUtc $event.timestampUtc
                    value = $event.value
                    cacheHit = $event.cacheHit
                    threadId = $begin.threadId
                })
            }
        }
    }
    foreach ($key in @($begins.Keys)) {
        $begin = $begins[$key]
        [void]$diagnostics.Add([pscustomobject][ordered]@{ kind = 'beginWithoutEnd'; eventName = $begin.eventName; operation = $begin.operation; timestampUtc = $begin.timestampUtc })
    }

    $openBegins = @($orderedEvents | Where-Object { $_.eventId -eq 2 -and $_.stageId -eq 1 })
    if ($ColdSampleCount -gt $openBegins.Count) {
        throw "ColdSampleCount $ColdSampleCount exceeds the $($openBegins.Count) observed opening cycles."
    }
    $activationEvents = @($orderedEvents | Where-Object { $_.eventId -eq 1 -and $_.stageId -eq 0 })
    $cycles = [Collections.Generic.List[object]]::new()
    $previousOpenStart = [DateTimeOffset]::MinValue
    for ($index = 0; $index -lt $openBegins.Count; $index++) {
        $open = $openBegins[$index]
        $nextOpenStart = if ($index + 1 -lt $openBegins.Count) { $openBegins[$index + 1].timestampUtc } else { [DateTimeOffset]::MaxValue }
        $visible = @($orderedEvents | Where-Object { $_.eventId -eq 6 -and $_.stageId -eq 0 -and $_.operation -eq $open.operation -and $_.timestampUtc -ge $open.timestampUtc } | Select-Object -First 1)
        $paint = @($orderedEvents | Where-Object { $_.eventId -eq 7 -and $_.stageId -eq 0 -and $_.operation -eq $open.operation -and $_.timestampUtc -ge $open.timestampUtc } | Select-Object -First 1)
        $hidden = @($orderedEvents | Where-Object { $_.eventId -eq 11 -and $_.stageId -eq 0 -and $_.operation -eq $open.operation -and $_.timestampUtc -ge $open.timestampUtc -and $_.timestampUtc -lt $nextOpenStart } | Select-Object -First 1)
        $openPhase = @($phases | Where-Object { $_.eventId -eq 2 -and $_.operation -eq $open.operation } | Select-Object -First 1)
        $boundary = if ($hidden.Count) { $hidden[0].timestampUtc } else { $nextOpenStart }
        $closePhase = @($phases | Where-Object { $_.eventId -eq 10 -and $_.startUtc -ge $open.timestampUtc -and $_.startUtc -le $boundary } | Sort-Object startUtc | Select-Object -First 1)
        $activation = @($activationEvents | Where-Object { $_.timestampUtc -ge $previousOpenStart -and $_.timestampUtc -le $open.timestampUtc } | Sort-Object timestampUtc | Select-Object -Last 1)
        $closeActivation = @()
        if ($closePhase.Count) {
            $closeActivation = @($activationEvents | Where-Object {
                $_.timestampUtc -ge $open.timestampUtc -and $_.timestampUtc -le $closePhase[0].startUtc
            } | Sort-Object timestampUtc | Select-Object -Last 1)
        }
        $sourceId = if ($open.activationSourceId -ne 0) { $open.activationSourceId } elseif ($activation.Count) { $activation[0].activationSourceId } else { 0 }
        $sourceName = if ($script:A4SActivationNames.ContainsKey([int]$sourceId)) { $script:A4SActivationNames[[int]$sourceId] } else { 'unknown' }
        $cyclePhases = @($phases | Where-Object {
            $_.eventId -notin @(2, 10) -and $_.startUtc -ge $open.timestampUtc -and $_.startUtc -le $boundary
        } | Sort-Object startUtc)
        $missing = [Collections.Generic.List[string]]::new()
        if (-not $activation.Count) { [void]$missing.Add('activationRequested') }
        if (-not $openPhase.Count) { [void]$missing.Add('openPathEnd') }
        if (-not $visible.Count) { [void]$missing.Add('windowVisible') }
        if (-not $paint.Count) { [void]$missing.Add('firstPaint') }
        if (-not $closeActivation.Count) { [void]$missing.Add('closeActivationRequested') }
        if (-not $closePhase.Count) { [void]$missing.Add('closePath') }
        if (-not $hidden.Count) { [void]$missing.Add('windowHidden') }
        if ($missing.Count) {
            [void]$diagnostics.Add([pscustomobject][ordered]@{ kind = 'incompleteCycle'; cycle = $index + 1; operation = $open.operation; missing = @($missing) })
        }

        $activationTimestamp = if ($activation.Count) { $activation[0].timestampUtc } else { $null }
        $visibleTimestamp = if ($visible.Count) { $visible[0].timestampUtc } else { $null }
        $paintTimestamp = if ($paint.Count) { $paint[0].timestampUtc } else { $null }
        $hiddenTimestamp = if ($hidden.Count) { $hidden[0].timestampUtc } else { $null }
        $closeStart = if ($closePhase.Count) { $closePhase[0].startUtc } else { $null }
        $closeActivationTimestamp = if ($closeActivation.Count) { $closeActivation[0].timestampUtc } else { $null }
        $closeSourceId = if ($closeActivation.Count) { $closeActivation[0].activationSourceId } else { 0 }
        $closeSourceName = if ($script:A4SActivationNames.ContainsKey([int]$closeSourceId)) { $script:A4SActivationNames[[int]$closeSourceId] } else { 'unknown' }
        [void]$cycles.Add([pscustomobject][ordered]@{
            sample = $index + 1
            classification = if ($index -lt $ColdSampleCount) { 'cold' } else { 'warm' }
            operation = $open.operation
            activationSourceId = [int]$sourceId
            activationSource = $sourceName
            activationUtc = $activationTimestamp
            openBeginUtc = $open.timestampUtc
            windowVisibleUtc = $visibleTimestamp
            firstPaintUtc = $paintTimestamp
            closeActivationUtc = $closeActivationTimestamp
            closeActivationSourceId = [int]$closeSourceId
            closeActivationSource = $closeSourceName
            closeBeginUtc = $closeStart
            windowHiddenUtc = $hiddenTimestamp
            activationToVisibleMilliseconds = Get-A4SDurationMilliseconds $activationTimestamp $visibleTimestamp
            activationToFirstPaintMilliseconds = Get-A4SDurationMilliseconds $activationTimestamp $paintTimestamp
            openBeginToVisibleMilliseconds = Get-A4SDurationMilliseconds $open.timestampUtc $visibleTimestamp
            openBeginToFirstPaintMilliseconds = Get-A4SDurationMilliseconds $open.timestampUtc $paintTimestamp
            openPathMilliseconds = if ($openPhase.Count) { $openPhase[0].durationMilliseconds } else { $null }
            closeActivationToHiddenMilliseconds = Get-A4SDurationMilliseconds $closeActivationTimestamp $hiddenTimestamp
            closeBeginToHiddenMilliseconds = Get-A4SDurationMilliseconds $closeStart $hiddenTimestamp
            closePathMilliseconds = if ($closePhase.Count) { $closePhase[0].durationMilliseconds } else { $null }
            complete = $missing.Count -eq 0
            missing = @($missing)
            phases = $cyclePhases
        })
        $previousOpenStart = $open.timestampUtc
    }

    $warmCycles = @($cycles | Where-Object { $_.classification -eq 'warm' })
    $allPhaseStats = [ordered]@{}
    foreach ($group in @($phases | Where-Object { $_.eventId -notin @(2, 10) } | Group-Object eventName | Sort-Object Name)) {
        $allPhaseStats[$group.Name] = Get-A4SStatistics @($group.Group.durationMilliseconds)
    }
    $warmOpen = Get-A4SStatistics @($warmCycles.activationToVisibleMilliseconds)
    $warmPaint = Get-A4SStatistics @($warmCycles.activationToFirstPaintMilliseconds)
    $close = Get-A4SStatistics @($cycles.closeActivationToHiddenMilliseconds)
    $frameBudget = [Math]::Round(1000.0 / $RefreshRateHz, 3)
    $warmStatus = if ($warmOpen.count -eq 0) { 'notMeasured' } elseif ($warmOpen.p95Milliseconds -le $WarmOpenTargetMilliseconds) { 'pass' } else { 'fail' }
    $closeStatus = if ($close.count -eq 0) { 'notMeasured' } elseif ($close.p95Milliseconds -le $frameBudget) { 'pass' } else { 'fail' }
    $completeStatus = if ($diagnostics.Count -eq 0 -and $cycles.Count -gt 0) { 'pass' } else { 'fail' }
    $measuredStatuses = @($warmStatus, $closeStatus, $completeStatus | Where-Object { $_ -ne 'notMeasured' })
    $overallStatus = if ($measuredStatuses.Count -eq 0) { 'notMeasured' } elseif ($measuredStatuses -contains 'fail') { 'fail' } else { 'pass' }

    $serializedEvents = @($orderedEvents | ForEach-Object {
        [pscustomobject][ordered]@{
            sequence = $_.sequence
            timestampUtc = $_.timestampUtc.ToString('o')
            eventId = $_.eventId
            eventName = $_.eventName
            stageId = $_.stageId
            stageName = $_.stageName
            operation = $_.operation
            value = $_.value
            cacheHit = $_.cacheHit
            activationSourceId = $_.activationSourceId
            activationSource = $_.activationSource
            window = ('0x{0:x}' -f $_.window)
            processId = $_.processId
            threadId = $_.threadId
        }
    })

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        generatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        provider = [pscustomobject][ordered]@{ name = 'A4SMenu.Runtime'; guid = $script:A4SProviderGuid }
        source = [pscustomobject][ordered]@{ type = $SourceType; path = $SourcePath }
        samplePolicy = [pscustomobject][ordered]@{ coldSampleCount = $ColdSampleCount; warmSampleCount = $warmCycles.Count }
        counts = [pscustomobject][ordered]@{ events = $orderedEvents.Count; operations = $phases.Count; cycles = $cycles.Count; diagnostics = $diagnostics.Count }
        statistics = [pscustomobject][ordered]@{
            warmActivationToVisible = $warmOpen
            warmActivationToFirstPaint = $warmPaint
            allCloseActivationToHidden = $close
            allCloseBeginToHidden = Get-A4SStatistics @($cycles.closeBeginToHiddenMilliseconds)
            allOpenPath = Get-A4SStatistics @($cycles.openPathMilliseconds)
            allClosePath = Get-A4SStatistics @($cycles.closePathMilliseconds)
            phases = [pscustomobject]$allPhaseStats
        }
        targetEvaluation = [pscustomobject][ordered]@{
            overallCustomTraceStatus = $overallStatus
            warmOpen = [pscustomobject][ordered]@{ metric = 'activationRequested to windowVisible'; p95Milliseconds = $warmOpen.p95Milliseconds; targetMilliseconds = $WarmOpenTargetMilliseconds; status = $warmStatus }
            close = [pscustomobject][ordered]@{ metric = 'close activationRequested to windowHidden'; p95Milliseconds = $close.p95Milliseconds; refreshRateHz = $RefreshRateHz; frameBudgetMilliseconds = $frameBudget; status = $closeStatus }
            completeness = [pscustomobject][ordered]@{ requiredDiagnostics = 0; actualDiagnostics = $diagnostics.Count; status = $completeStatus }
            presentedFrame = [pscustomobject][ordered]@{ status = 'notMeasured'; reason = 'windowVisible and firstPaint are application markers, not compositor presentation timestamps' }
            physicalWarmDiskIo = [pscustomobject][ordered]@{ status = 'notMeasured'; reason = 'the custom provider does not capture physical file I/O' }
        }
        diagnostics = @($diagnostics)
        cycles = @($cycles)
        operations = @($phases | Sort-Object startUtc)
        events = $serializedEvents
    }
}

Export-ModuleMember -Function ConvertFrom-A4STracerptXml, Import-A4SEventJson, ConvertTo-A4SRuntimeReport
