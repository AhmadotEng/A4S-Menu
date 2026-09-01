<#
.SYNOPSIS
Captures the Windows Sandbox guest lifecycle process before invoking it.

.DESCRIPTION
Windows Sandbox does not surface LogonCommand exit status to the host. This
small wrapper publishes correlation-bound stage records, captures the guest
PowerShell stdout and stderr, and publishes a hash-bound exit record through
the dedicated writable evidence mapping. It never installs or launches A4S
product binaries itself.
#>
[CmdletBinding()]
param(
    [string] $GuestScriptPath,
    [string] $RequestPath,
    [string] $EvidenceRoot,
    [string] $SessionId,
    [string] $Nonce,
    [string] $RequestSha256,
    [string] $BootstrapScriptSha256,
    [string] $GuestScriptSha256,
    [switch] $ContractSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Write-Utf8NoBomNewFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text
    )
    $full = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($directory)) {
        throw "Output directory is unavailable: $directory"
    }
    $temporary = Join-Path $directory `
        (([IO.Path]::GetFileName($full)) + ".$PID.$([Guid]::NewGuid().ToString('N')).new")
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $full)
    }
    catch {
        try { [IO.File]::Delete($temporary) } catch {}
        throw
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-FailClosedScriptCommand {
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][Collections.IDictionary] $NamedArguments
    )
    $invocation = '& ' + (ConvertTo-PowerShellSingleQuotedLiteral $ScriptPath)
    foreach ($entry in $NamedArguments.GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9]*$') {
            throw "Unsafe PowerShell parameter name: $name"
        }
        $invocation += ' -' + $name + ' ' +
            (ConvertTo-PowerShellSingleQuotedLiteral ([string]$entry.Value))
    }
    return @"
`$ErrorActionPreference = 'Stop'
try {
    $invocation
    if (-not `$?) {
        throw 'The invoked guest script reported a non-terminating error.'
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine((`$_ | Out-String))
    exit 1
}
"@
}

function ConvertTo-EncodedPowerShellCommand {
    param([Parameter(Mandatory)][string] $Command)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Publish-BootstrapStage {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 999)][int] $Ordinal,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string] $Stage,
        [hashtable] $Details
    )
    $record = [ordered]@{
        SchemaVersion = 1
        SessionId = $SessionId
        Nonce = $Nonce
        RequestSha256 = $RequestSha256
        BootstrapScriptSha256 = $BootstrapScriptSha256
        GuestScriptSha256 = $GuestScriptSha256
        Ordinal = $Ordinal
        Stage = $Stage
        ProcessId = $PID
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        Details = $Details
    }
    $name = 'stage-{0:D3}-{1}.json' -f $Ordinal, $Stage
    Write-Utf8NoBomNewFile -Path (Join-Path $EvidenceRoot $name) `
        -Text ($record | ConvertTo-Json -Depth 20)
    $script:lastStage = $Stage
}

function Assert-ContractModel {
    $contractRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('A4SSandboxBootstrapContract-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($contractRoot) | Out-Null
    try {
        $path = Join-Path $contractRoot 'utf8.json'
        Write-Utf8NoBomNewFile -Path $path -Text '{"contract":true}'
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 2 -or
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
                $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
            [IO.File]::ReadAllText($path) -cne '{"contract":true}') {
            throw 'Bootstrap UTF-8 publication contract failed.'
        }

        $successScript = Join-Path $contractRoot 'success.ps1'
        $terminatingScript = Join-Path $contractRoot 'terminating.ps1'
        $nonTerminatingScript = Join-Path $contractRoot 'nonterminating.ps1'
        [IO.File]::WriteAllText($successScript, "Write-Output 'success'",
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($terminatingScript,
            "throw 'synthetic terminating failure'", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($nonTerminatingScript,
            "Write-Error 'synthetic non-terminating failure'",
            [Text.UTF8Encoding]::new($false))
        $windowsPowerShell = Join-Path $env:SystemRoot `
            'System32\WindowsPowerShell\v1.0\powershell.exe'
        $exitCodes = [Collections.Generic.List[int]]::new()
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            foreach ($contractScript in @($successScript, $terminatingScript,
                    $nonTerminatingScript)) {
                $command = New-FailClosedScriptCommand -ScriptPath $contractScript `
                    -NamedArguments ([ordered]@{})
                $encoded = ConvertTo-EncodedPowerShellCommand $command
                $contractOutput = @(& $windowsPowerShell -NoLogo -NoProfile `
                    -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
                $exitCodes.Add([int]$LASTEXITCODE)
            }
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($exitCodes.Count -ne 3 -or $exitCodes[0] -ne 0 -or
            $exitCodes[1] -eq 0 -or $exitCodes[2] -eq 0) {
            throw "Fail-closed guest invocation contract failed (exit codes: $($exitCodes -join ','))."
        }
        Write-Host 'A4S legacy Sandbox bootstrap PS5 fail-closed child exit contract passed.'
    }
    finally {
        if ([IO.Directory]::Exists($contractRoot)) {
            [IO.Directory]::Delete($contractRoot, $true)
        }
    }
    Write-Host "A4S legacy Sandbox bootstrap contract passed under Windows PowerShell $($PSVersionTable.PSVersion)."
}

if ($ContractSelfTest) {
    Assert-ContractModel
    return
}

$fixedGuestScript = 'C:\A4S\Repo\tools\Invoke-A4SLegacySandboxGuest.ps1'
$fixedRequest = 'C:\A4S\Control\request.json'
$fixedEvidence = 'C:\A4S\Evidence'
$script:lastStage = 'bootstrap-parameter-binding'
$localRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('A4SSandboxBootstrap-' + [Guid]::NewGuid().ToString('N'))
$stdoutPath = Join-Path $localRoot 'guest.stdout.txt'
$stderrPath = Join-Path $localRoot 'guest.stderr.txt'
$consoleParts = [Collections.Generic.List[string]]::new()
$exitCode = 1

try {
    if ([IO.Path]::GetFullPath($GuestScriptPath) -cne $fixedGuestScript -or
        [IO.Path]::GetFullPath($RequestPath) -cne $fixedRequest -or
        [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\') -cne $fixedEvidence) {
        throw 'Bootstrap paths do not match the fixed Sandbox mapping contract.'
    }
    Publish-BootstrapStage -Ordinal 1 -Stage 'bootstrap-entry'

    if ($SessionId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $Nonce -notmatch '^[0-9A-F]{64}$' -or
        $RequestSha256 -notmatch '^[0-9A-F]{64}$' -or
        $BootstrapScriptSha256 -notmatch '^[0-9A-F]{64}$' -or
        $GuestScriptSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'Bootstrap correlation parameters are malformed.'
    }
    $actualBootstrapSha256 = Get-FileSha256 $MyInvocation.MyCommand.Path
    $actualGuestSha256 = Get-FileSha256 $fixedGuestScript
    if ($actualBootstrapSha256 -cne $BootstrapScriptSha256 -or
        $actualGuestSha256 -cne $GuestScriptSha256) {
        throw 'Bootstrap or guest script does not match the host-reviewed SHA-256.'
    }
    Publish-BootstrapStage -Ordinal 2 -Stage 'scripts-authenticated' -Details @{
        ActualBootstrapScriptSha256 = $actualBootstrapSha256
        ActualGuestScriptSha256 = $actualGuestSha256
    }

    [IO.Directory]::CreateDirectory($localRoot) | Out-Null
    Publish-BootstrapStage -Ordinal 3 -Stage 'guest-process-starting'
    $windowsPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([IO.Path]::GetFullPath($windowsPowerShell) -cne
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -or
        -not [IO.File]::Exists($windowsPowerShell)) {
        throw 'Canonical 64-bit Windows PowerShell is unavailable in Sandbox.'
    }
    $guestCommand = New-FailClosedScriptCommand -ScriptPath $fixedGuestScript `
        -NamedArguments ([ordered]@{
            RequestPath = $fixedRequest
            ExpectedSessionId = $SessionId
            ExpectedNonce = $Nonce
            ExpectedRequestSha256 = $RequestSha256
            ExpectedGuestScriptSha256 = $GuestScriptSha256
        })
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', (ConvertTo-EncodedPowerShellCommand $guestCommand)
    )
    $guestProcess = Start-Process -FilePath $windowsPowerShell `
        -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    # Wait only for the direct guest PowerShell. Start-Process -Wait can wait
    # for detached descendants such as the intentionally pending cleanup helper.
    $guestProcess.WaitForExit()
    $exitCode = [int]$guestProcess.ExitCode
    if ($exitCode -eq 0 -and [IO.File]::Exists($stderrPath) -and
        (Get-Item -LiteralPath $stderrPath -Force).Length -ne 0) {
        $exitCode = 1
        $consoleParts.Add(
            'Guest PowerShell returned zero but emitted stderr; bootstrap failed closed.')
    }
    Publish-BootstrapStage -Ordinal 90 -Stage 'guest-process-exited' `
        -Details @{ ExitCode = $exitCode }
}
catch {
    $exitCode = 1
    $consoleParts.Add("Bootstrap failure: $($_.Exception.Message)")
    $consoleParts.Add("Bootstrap stack: $($_.ScriptStackTrace)")
    try {
        Publish-BootstrapStage -Ordinal 98 -Stage 'bootstrap-failed' `
            -Details @{ Message = $_.Exception.Message }
    }
    catch {}
}
finally {
    try {
        if ([IO.File]::Exists($stdoutPath)) {
            $consoleParts.Add("--- guest stdout ---`r`n$([IO.File]::ReadAllText($stdoutPath))")
        }
        if ([IO.File]::Exists($stderrPath)) {
            $consoleParts.Add("--- guest stderr ---`r`n$([IO.File]::ReadAllText($stderrPath))")
        }
        $consoleText = ($consoleParts -join "`r`n")
        if ([string]::IsNullOrWhiteSpace($consoleText)) {
            $consoleText = "Guest process exited with code $exitCode and produced no console output."
        }
        if ($consoleText.Length -gt 60000) {
            $consoleText = '[earlier guest console output omitted by bootstrap] ' +
                $consoleText.Substring($consoleText.Length - 60000)
        }
        $consolePath = Join-Path $fixedEvidence 'guest-console.log'
        Write-Utf8NoBomNewFile -Path $consolePath -Text $consoleText
        $consoleItem = Get-Item -LiteralPath $consolePath -Force
        $exitRecord = [ordered]@{
            SchemaVersion = 1
            SessionId = $SessionId
            Nonce = $Nonce
            RequestSha256 = $RequestSha256
            BootstrapScriptSha256 = $BootstrapScriptSha256
            GuestScriptSha256 = $GuestScriptSha256
            ExitCode = $exitCode
            LastStage = $script:lastStage
            ConsoleFile = 'guest-console.log'
            ConsoleLength = [long]$consoleItem.Length
            ConsoleSha256 = Get-FileSha256 $consolePath
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-Utf8NoBomNewFile -Path (Join-Path $fixedEvidence 'guest-exit.json') `
            -Text ($exitRecord | ConvertTo-Json -Depth 20)
    }
    catch {
        # This is intentionally a direct best-effort fallback. If even it fails,
        # the host's bounded no-bootstrap/no-exit deadline reports the mapping fault.
        try {
            $publicationFailure = $_.Exception.ToString()
            if ($publicationFailure.Length -gt 60000) {
                $publicationFailure = '[earlier publication failure detail omitted] ' +
                    $publicationFailure.Substring($publicationFailure.Length - 60000)
            }
            [IO.File]::WriteAllText((Join-Path $fixedEvidence 'bootstrap-publication-failure.txt'),
                $publicationFailure, [Text.UTF8Encoding]::new($false))
        }
        catch {}
    }
    if ([IO.Directory]::Exists($localRoot)) {
        try { [IO.Directory]::Delete($localRoot, $true) } catch {}
    }
}

exit $exitCode
