[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$harnessPath = Join-Path $PSScriptRoot 'Test-A4SFailureRecovery.ps1'
$hostPath = Join-Path $repoRoot 'Src\A4SMenu\Host\A4SMenuHost.cpp'
$identityPath = Join-Path $repoRoot 'Src\A4SMenu\Shared\A4SProductIdentity.h'

foreach ($path in @($harnessPath, $hostPath, $identityPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing failure/recovery contract input: $path"
    }
}

$harness = Get-Content -LiteralPath $harnessPath -Raw
$hostSource = Get-Content -LiteralPath $hostPath -Raw
$identity = Get-Content -LiteralPath $identityPath -Raw

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw "A4S failure/recovery contract failed: $Message"
    }
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $harnessPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw ('A4S failure/recovery contract failed: the qualification harness does not parse: ' +
        (($parseErrors | ForEach-Object Message) -join '; '))
}

function Get-FunctionText {
    param([Parameter(Mandatory)][string] $Name)
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $Name
    }, $true)
    Assert-Contract ($null -ne $function) "missing function $Name"
    return $function.Extent.Text
}

Assert-Contract ($harness -match "CmdletBinding\(DefaultParameterSetName\s*=\s*'Offline'\)") `
    'default execution is not the read-only Offline parameter set'
Assert-Contract ($harness -match '''Offline''\s*\{\s*& \(Join-Path \$PSScriptRoot ''Test-A4SFailureRecoveryContracts.ps1''\)') `
    'offline dispatch does anything before the static companion gate'
$offlineDispatch = [Regex]::Match($harness,
    "(?s)'Offline'\s*\{.*?\n\s*\}\s*\n\s*'Isolated'").Value
foreach ($forbidden in @('Initialize-A4SFailureRecoveryNative', 'Start-A4STestHost',
        'New-EvidenceBundle', 'Backup-HostSafety', 'Invoke-ValidatedExplorerCrash',
        'Remove-Item', 'Set-ItemProperty', 'New-Item')) {
    Assert-Contract ($offlineDispatch -notmatch [Regex]::Escape($forbidden)) `
        "offline dispatch contains mutating/runtime primitive $forbidden"
}

Assert-Contract ($harness -match '\$IUnderstandThisWillForceCrashExplorerThreeTimesAndRestartItForCleanup') `
    'live Explorer mutation lacks a conspicuous switch'
Assert-Contract ($harness -match [Regex]::Escape(
    'I ACCEPT FOUR EXPLORER TERMINATIONS: THREE GUARDED CRASHES AND ONE CLEANUP RESTART')) `
    'live Explorer mutation lacks the exact high-friction confirmation phrase'

foreach ($forbidden in @('Stop-Process', 'taskkill', 'Restart-Computer', 'Stop-Computer',
        '--rehook', 'build\stage\A4SProduct')) {
    Assert-Contract ($harness -notmatch [Regex]::Escape($forbidden)) `
        "harness contains forbidden broad or staged primitive $forbidden"
}

$crashFunction = Get-FunctionText 'Invoke-ValidatedExplorerCrash'
Assert-Contract (([Regex]::Matches($harness, '\.Kill\(\)')).Count -eq 1) `
    'Explorer Process.Kill must occur exactly once in the validated crash helper'
Assert-Contract ($crashFunction -match '\.Kill\(\)') 'validated crash helper does not perform the explicitly gated crash'
foreach ($validation in @('Get-TaskbarExplorerIdentity', 'Assert-SameExplorerIdentity',
        'explorer\.exe', 'SessionId', 'WaitForExit')) {
    Assert-Contract ($crashFunction -match $validation) `
        "validated crash helper omits $validation"
}

$isolated = Get-FunctionText 'Invoke-IsolatedDllFailureQualification'
foreach ($case in @("'missing'", "'corrupt'", "'incompatible'")) {
    Assert-Contract ($isolated -match [Regex]::Escape($case)) "isolated matrix omits $case"
}
foreach ($contract in @('New-A4STemporaryRoot', 'Assert-CleanA4SSession',
        'Assert-SameExplorerIdentity', 'Assert-NoA4SMapping',
        'IsLoadableNonProductDll', 'Stop-A4STestHost',
        'Compare-HostSafetySnapshot', 'Remove-A4STemporaryRoot')) {
    Assert-Contract ($isolated -match $contract) "isolated matrix omits $contract"
}
Assert-Contract ($isolated -notmatch 'Invoke-ValidatedExplorerCrash|\.Kill\(\)|Start-Process') `
    'isolated bad-DLL qualification can restart/crash Explorer'

$stopHost = Get-FunctionText 'Stop-A4STestHost'
Assert-Contract ($stopHost -match "--exit") 'test hosts are not stopped through the supported logical exit'
Assert-Contract ($stopHost -match '\$serviceNotActive') 'clean host stop is not verified through --status'
Assert-Contract ($stopHost -notmatch '\.Kill\(|Stop-Process') 'test host cleanup can force-kill a potentially hooked host'

$tempCleanup = Get-FunctionText 'Remove-A4STemporaryRoot'
Assert-Contract ($tempCleanup -match 'Assert-SafeTemporaryRoot') `
    'recursive temporary cleanup is not guarded by an exact temp-root validator'
Assert-Contract (([Regex]::Matches($harness, 'Remove-Item[^\r\n]+-Recurse')).Count -eq 1) `
    'recursive deletion exists outside the validated temporary-root helper'

$atomicWrite = Get-FunctionText 'Write-DurableText'
foreach ($contract in @('Flush\(\$true\)', 'ReplaceFileAtomically', 'MoveFileEx')) {
    Assert-Contract (($atomicWrite -match $contract) -or ($harness -match $contract)) `
        "atomic evidence publication omits $contract"
}

$backup = Get-FunctionText 'Backup-HostSafety'
$restore = Get-FunctionText 'Restore-HostSafety'
foreach ($contract in @('reg\.exe export', 'HostSafetyBackup\.json', 'Get-FileHash',
        'Flush\(\$true\)')) {
    Assert-Contract ($backup -match $contract) "durable HostSafety backup omits $contract"
}
foreach ($contract in @('DeleteSubKeyTree', 'reg\.exe import', 'Get-FileHash',
        'Compare-HostSafetySnapshot')) {
    Assert-Contract ($restore -match $contract) "exact HostSafety recovery omits $contract"
}

$live = Get-FunctionText 'Invoke-LiveFailureRecoveryQualification'
$backupIndex = $live.IndexOf('Backup-HostSafety', [StringComparison]::Ordinal)
$firstCrashIndex = $live.IndexOf('Invoke-ValidatedExplorerCrash', [StringComparison]::Ordinal)
Assert-Contract ($backupIndex -ge 0 -and $firstCrashIndex -gt $backupIndex) `
    'live qualification can crash Explorer before durable HostSafety backup'
foreach ($contract in @(
    'safety-reset-no-dll',
    '\$crashIndex\s*=\s*1;\s*\$crashIndex\s*-le\s*\$crashThreshold',
    'Wait-ReplacementExplorer',
    'Assert-ExactA4SMapping',
    'Invoke-OneMenuAssertion',
    'ExpectedExitCode \$hostStatusSafetyDisabled',
    'Assert-RollingCrashGuard',
    "--reset-safety",
    'safety-reset-recovered-ready',
    'cleanup-restart-complete',
    'Restore-HostSafety'
)) {
    Assert-Contract ($live -match $contract) "live N6/N9 qualification omits $contract"
}
Assert-Contract ($live -match 'preparedBeforeFirstCrash\s*=\s*\$true') `
    'evidence does not attest that durable recovery preceded the crash boundary'
Assert-Contract ($live -match 'oldExplorerPid' -and $live -match 'newExplorerPid' -and
    $live -match 'statusExitCode' -and $live -match 'mappingCount') `
    'live evidence omits exact PID/status/mapping transitions'
Assert-Contract ($live -match 'Do not add surprise Explorer terminations after a failed run') `
    'failed live runs can silently add an unconfirmed cleanup crash'

Assert-Contract ($identity -match 'A4S_HOST_SAFETY_REGISTRY_W\s+L"Software\\\\A4SMenu\\\\HostSafety"') `
    'host and harness no longer agree on the HostSafety registry key'
Assert-Contract ($hostSource -match 'constexpr DWORD kCrashLoopThreshold = 3;') `
    'host crash threshold is no longer exactly three'
Assert-Contract ($hostSource -match 'constexpr ULONGLONG kCrashLoopWindow100ns = UINT64_C\(180\)') `
    'host rolling crash window is no longer 180 seconds'

$tryInject = [Regex]::Match($hostSource,
    '(?s)bool TryInject\(\)\s*\{.*?\n\s*\}\s*\n\s*void BeginConnection').Value
Assert-Contract (-not [string]::IsNullOrWhiteSpace($tryInject)) 'could not isolate host TryInject'
$loadIndex = $tryInject.IndexOf('LoadProductDll()', [StringComparison]::Ordinal)
$targetIndex = $tryInject.IndexOf('FindValidatedExplorer', [StringComparison]::Ordinal)
$hookIndex = $tryInject.IndexOf('SetWindowsHookExW', [StringComparison]::Ordinal)
Assert-Contract ($loadIndex -ge 0 -and $targetIndex -gt $loadIndex -and $hookIndex -gt $targetIndex) `
    'host no longer validates/loads the sibling DLL before selecting or hooking Explorer'
foreach ($abiCheck in @('A4S_DLL_GET_API_EXPORT_A', 'A4S_DLL_HOOK_INJECT_EXPORT_A',
        'api->abiVersion != A4S_MENU_ABI_VERSION',
        'api->productVersion != A4S_MENU_PRODUCT_VERSION')) {
    Assert-Contract ($hostSource -match [Regex]::Escape($abiCheck)) "host DLL validation omits $abiCheck"
}
Assert-Contract ($hostSource -match 'MsgWaitForMultipleObjectsEx' -and
    $hostSource -match 'A4S_TASKBAR_CREATED_MESSAGE_W') `
    'Explorer lifecycle recovery no longer combines process signaling with TaskbarCreated'
foreach ($failSafe in @(
    'g_runtime\.status\s*=\s*A4S_MENU_HOST_STATUS_FAILED',
    'failed \(native Start available\)',
    'disabled after Explorer crash loop \(native Start available\)',
    'exitCode!=ERROR_SUCCESS',
    'ResetSafetyState\(\)'
)) {
    Assert-Contract ($hostSource -match $failSafe) "host fail-safe contract omits $failSafe"
}

# Deterministic offline model for the rolling N9 boundary. A clean event retains
# the prior streak, expiry prunes it, and the third in-window crash disables.
function Advance-GuardModel {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][uint64[]] $Times,
        [Parameter(Mandatory)][bool] $CountAbnormal,
        [Parameter(Mandatory)][uint64] $Now
    )
    [uint64]$window = 180 * 10000000
    $retained = @($Times | Where-Object { $_ -ne 0 -and ($Now -lt $_ -or $Now - $_ -le $window) })
    if ($CountAbnormal) { $retained += $Now }
    if ($retained.Count -gt 3) { $retained = @($retained | Select-Object -Last 3) }
    return [ordered]@{ times = @($retained); disabled = $retained.Count -ge 3 }
}

$one = Advance-GuardModel -Times @() -CountAbnormal $true -Now 100
$two = Advance-GuardModel -Times $one.times -CountAbnormal $true -Now 101
$three = Advance-GuardModel -Times $two.times -CountAbnormal $true -Now 102
Assert-Contract (-not $two.disabled -and $three.disabled) `
    'offline model does not disable at exactly the third in-window crash'
$clean = Advance-GuardModel -Times $two.times -CountAbnormal $false -Now 102
Assert-Contract ($clean.times.Count -eq 2 -and -not $clean.disabled) `
    'offline model erases or counts a clean maintenance exit'
$expired = Advance-GuardModel -Times $two.times -CountAbnormal $true `
    -Now ([uint64](101 + 180 * 10000000 + 1))
Assert-Contract ($expired.times.Count -eq 1 -and -not $expired.disabled) `
    'offline model does not prune expired crash timestamps'

Write-Host 'A4S failure/recovery offline contracts passed: default safety, temp-only N8, event-driven N6, durable recovery, and rolling N9 boundaries.'
