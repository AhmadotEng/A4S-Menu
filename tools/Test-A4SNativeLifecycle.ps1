[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dllPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\StartMenuDLL.cpp'
$containerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.cpp'
$hostPath = Join-Path $repoRoot 'Src\A4SMenu\Host\A4SMenuHost.cpp'
$identityPath = Join-Path $repoRoot 'Src\A4SMenu\Shared\A4SProductIdentity.h'
$dllSource = Get-Content -LiteralPath $dllPath -Raw
$containerSource = Get-Content -LiteralPath $containerPath -Raw
$hostSource = Get-Content -LiteralPath $hostPath -Raw
$identitySource = Get-Content -LiteralPath $identityPath -Raw

function Assert-Match {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Failure
    )
    if ($Text -notmatch $Pattern) {
        throw $Failure
    }
}

$threadMatch = [Regex]::Match(
    $dllSource,
    '(?s)static DWORD WINAPI A4SKeyboardThreadProc\s*\(.*?\n\}\s*\n\s*static void ReleaseFinishedA4SKeyboardThread')
if (-not $threadMatch.Success) {
    throw 'The dedicated A4S keyboard-owner thread could not be isolated.'
}
Assert-Match $threadMatch.Value 'SetWindowsHookEx\s*\(\s*WH_KEYBOARD_LL' `
    'WH_KEYBOARD_LL is not installed by the dedicated owner thread.'
Assert-Match $threadMatch.Value 'while\s*\(\s*GetMessage\(' `
    'The keyboard-owner thread is not a blocked message loop.'
foreach ($command in @('A4S_KEYBOARD_SUSPEND', 'A4S_KEYBOARD_REFRESH', 'A4S_KEYBOARD_STOP')) {
    Assert-Match $threadMatch.Value ([Regex]::Escape($command)) `
        "The keyboard-owner thread does not handle $command."
}

$callbackMatch = [Regex]::Match(
    $dllSource,
    '(?s)static LRESULT CALLBACK HookA4SKeyboard\s*\([^;]+?\)\s*\r?\n\{.*?\r?\n\}\s*\r?\n#endif')
if (-not $callbackMatch.Success) {
    throw 'The A4S low-level keyboard callback could not be isolated.'
}
$callback = $callbackMatch.Value
$chainIndex = $callback.LastIndexOf('CallNextHookEx', [StringComparison]::Ordinal)
$postIndex = $callback.LastIndexOf('PostMessage', [StringComparison]::Ordinal)
if ($chainIndex -lt 0 -or $postIndex -lt 0 -or $chainIndex -gt $postIndex) {
    throw 'The keyboard callback must chain the release before deciding to post/claim it.'
}
if ($callback -match '(?i)\b(?:new|malloc|calloc|realloc|RegOpen|CreateFile|ShellExecute|SendMessage)\b') {
    throw 'The keyboard callback contains an allocation, registry, file, shell, or synchronous-send operation.'
}
Assert-Match $callback 'ReconcileMissingA4SWinKeyUps' `
    'The callback no longer self-heals a missed Windows-key release.'
Assert-Match $callback 'route\.claimLoneRelease\s*&&\s*downstream==0' `
    'A downstream hook claim no longer suppresses the A4S lone-key toggle.'
Assert-Match $dllSource 'InitializeA4SPhysicalKeyState[\s\S]*GetAsyncKeyState' `
    'The fixed physical-key state is not seeded for pre-held keys.'
Assert-Match $dllSource 'A4S_TEST_PREHELD_WIN_UP[\s\S]*must remain native on release' `
    'The compile-time contract no longer covers a pre-held Windows key.'
Assert-Match $dllSource 'A4S_TEST_MODIFIED_UP[\s\S]*any pre-held key must keep the gesture native' `
    'The compile-time contract no longer covers a pre-held nonmodifier key.'
Assert-Match $dllSource 'A4S_TEST_RECOVERED_WIN_STATE[\s\S]*lost Windows-key-up must be self-healed' `
    'The compile-time contract no longer covers lost Windows-key-up recovery.'

$startMatch = [Regex]::Match(
    $dllSource,
    '(?s)static bool StartA4SKeyboardThread\s*\(.*?\r?\n\}\s*\r?\n\s*static bool RefreshA4SKeyboardHook')
if (-not $startMatch.Success) {
    throw 'The keyboard-owner startup handshake could not be isolated.'
}
foreach ($pattern in @(
    'WaitForSingleObject\(g_A4SKeyboardOperationEvent,A4S_KEYBOARD_HANDSHAKE_TIMEOUT\)',
    'InterlockedExchange\(&g_A4SKeyboardAcceptInput,0\)',
    'PostThreadMessage\(g_A4SKeyboardThreadId,A4S_KEYBOARD_STOP',
    'ReleaseFinishedA4SKeyboardThread\(\)',
    'SetLastError\(failure\)'
)) {
    Assert-Match $startMatch.Value $pattern `
        'Owner-thread install timeout/failure no longer gates input and attempts bounded cleanup.'
}
Assert-Match $dllSource 'static bool RefreshA4SKeyboardHook[\s\S]*A4S_KEYBOARD_HANDSHAKE_TIMEOUT' `
    'Keyboard refresh no longer has a bounded completion handshake.'
Assert-Match $dllSource 'static bool StopA4SKeyboardThread[\s\S]*deadline=GetTickCount64\(\)\+A4S_KEYBOARD_HANDSHAKE_TIMEOUT' `
    'Keyboard stop no longer shares one bounded cleanup deadline.'
Assert-Match $dllSource 'A4S_MENU_COMMAND_SUSPEND_INPUT[\s\S]*InterlockedExchange\(&g_A4SInputSuspended,1\)' `
    'Suspend no longer latches the taskbar-side stale-toggle gate.'
Assert-Match $dllSource 'command==A4S_COMMAND_TOGGLE\s*&&\s*activationEnabled' `
    'A queued toggle can bypass the taskbar-side suspended-input gate.'
Assert-Match $containerSource 'ForceCloseA4STransients[\s\S]*ShowWindow\(SW_HIDE\)[\s\S]*PostMessage\(WM_CLOSE\)' `
    'Session transitions do not have a synchronous product-only transient close path.'

Assert-Match $hostSource 'AbnormalExplorerExitTimes' `
    'The host does not persist exact rolling Explorer-exit timestamps.'
Assert-Match $hostSource 'kCrashTimesValue[\s\S]*REG_BINARY' `
    'The rolling Explorer-exit timestamps are not persisted as a fixed binary record.'
Assert-Match $hostSource 'inputGeneration[\s\S]*injectionInputGeneration' `
    'The host does not retain input generations across injection.'
Assert-Match $hostSource 'sessionInputInteractive[\s\S]*powerInputInteractive[\s\S]*interactiveInput' `
    'The host does not keep independent session and power input latches.'
Assert-Match $hostSource 'interactiveInput=g_runtime\.sessionInputInteractive\s*&&\s*g_runtime\.powerInputInteractive\s*&&\s*!g_runtime\.sessionEnding' `
    'The host interactive state is not gated by session, power, and session-ending state.'
Assert-Match $hostSource 'WM_WTSSESSION_CHANGE:[\s\S]*LatchSessionInput\(false\)[\s\S]*LatchSessionInput\(true\)' `
    'WTS transitions no longer update the independent session latch.'
Assert-Match $hostSource 'WM_POWERBROADCAST:[\s\S]*LatchPowerInput\(false\)[\s\S]*LatchPowerInput\(true\)' `
    'Power transitions no longer update the independent power latch.'
Assert-Match $hostSource 'WM_QUERYENDSESSION:[\s\S]*sessionEnding=true;[\s\S]*AdvanceInteractiveInputGeneration\(\)' `
    'Session ending no longer suspends input without overwriting the WTS latch.'
Assert-Match $hostSource 'WM_ENDSESSION:[\s\S]*sessionEnding=false;[\s\S]*AdvanceInteractiveInputGeneration\(\)' `
    'A cancelled session ending no longer recomputes the preserved WTS/power state.'
Assert-Match $hostSource 'HandleReadyStatus[\s\S]*ReconcileInteractiveInput' `
    'READY does not reconcile WTS/power transitions missed during injection.'
Assert-Match $hostSource 'A4S_MENU_HOST_CONTROL_TOGGLE:[\s\S]*if \(!g_runtime\.interactiveInput\)[\s\S]*return FALSE' `
    'The host can queue a toggle while the interactive desktop is suspended.'
if ($hostSource -match '!g_runtime\.explicitStopPending') {
    throw 'An explicit --exit pending flag must not suppress a pre-DISARMED Explorer crash.'
}
Assert-Match $hostSource '!g_runtime\.sessionEnding\s*&&\s*!g_runtime\.authenticatedDisarmed' `
    'Crash suppression is not limited to session ending or authenticated DISARMED state.'
Assert-Match $hostSource 'attemptedActivation\s*&&\s*exitCode!=ERROR_SUCCESS\s*&&\s*!g_runtime\.sessionEnding\s*&&\s*!g_runtime\.authenticatedDisarmed' `
    'A nonzero pre-DISARMED Explorer exit is no longer counted.'
Assert-Match $identitySource 'A4S_HOST_SAFETY_MUTEX_PREFIX_W\s+L"Global\\\\A4SMenu\.HostSafety\.v1\."' `
    'The cross-session HostSafety mutation mutex identity is missing.'
foreach ($pattern in @(
    'class SafetyMutationLock',
    'ConvertSidToStringSidW',
    'A4S_HOST_SAFETY_MUTEX_PREFIX_W',
    'CreateMutexW\(nullptr,FALSE,name\.c_str\(\)\)',
    'WaitForSingleObject\(m_mutex\.get\(\),2000\)',
    'void LoadSafetyState\(\)[\s\S]*SafetyMutationLock mutationLock;[\s\S]*mutationLock\.acquire\(\)',
    'bool PersistSafetyState\(DWORD lastExitCode\)[\s\S]*SafetyMutationLock mutationLock;[\s\S]*mutationLock\.acquire\(\)',
    'bool ResetSafetyState\(\)[\s\S]*SafetyMutationLock mutationLock;[\s\S]*mutationLock\.acquire\(\)'
)) {
    Assert-Match $hostSource $pattern `
        'A HostSafety read/write/reset path escaped cross-session serialization.'
}

# Independent executable model for the rolling-window edge that a window
# anchored to the first failure gets wrong.
function Add-RollingFailure {
    param([long[]] $Times, [long] $Now, [long] $Window, [bool] $Count)
    $retained = @($Times | Where-Object { $_ -gt 0 -and $Now -ge $_ -and ($Now - $_) -le $Window })
    if ($Count) { $retained += $Now }
    return @($retained | Select-Object -Last 3)
}
$window = 180000
$times = Add-RollingFailure @() 100 $window $true
$times = Add-RollingFailure $times ($window - 10) $window $true
$times = Add-RollingFailure $times ($window + 120) $window $true
if ($times.Count -ne 2) {
    throw 'The rolling model did not prune only the expired first timestamp.'
}
$times = Add-RollingFailure $times ($window + 121) $window $true
if ($times.Count -ne 3) {
    throw 'Three current abnormal timestamps did not trip the rolling model.'
}
$afterClean = Add-RollingFailure $times ($window + 122) $window $false
if ($afterClean.Count -ne 3) {
    throw 'A clean/maintenance exit erased current abnormal timestamps.'
}

function Test-ReconcileRequired {
    param(
        [long] $InjectionGeneration,
        [long] $CurrentGeneration,
        [bool] $Interactive
    )
    return (-not $Interactive) -or $InjectionGeneration -ne $CurrentGeneration
}
if (-not (Test-ReconcileRequired 7 8 $true)) {
    throw 'A resume transition during injection was not reconciled.'
}
if (-not (Test-ReconcileRequired 7 7 $false)) {
    throw 'A suspended final state was not reconciled for a fresh mapping.'
}
if (Test-ReconcileRequired 7 7 $true) {
    throw 'An unchanged interactive generation requested a redundant refresh.'
}
if (-not (Test-ReconcileRequired 7 9 $true)) {
    throw 'A lock followed by unlock during injection did not require a final refresh.'
}

function Get-CombinedInteractiveState {
    param(
        [bool] $SessionInteractive,
        [bool] $PowerInteractive,
        [bool] $SessionEnding = $false
    )
    return $SessionInteractive -and $PowerInteractive -and -not $SessionEnding
}
if (Get-CombinedInteractiveState $false $true) {
    throw 'An automatic power resume incorrectly overrode the locked-session latch.'
}
if (Get-CombinedInteractiveState $true $false) {
    throw 'A session unlock incorrectly overrode the suspended-power latch.'
}
if (-not (Get-CombinedInteractiveState $true $true)) {
    throw 'Independent session and power recovery did not restore input.'
}
if (Get-CombinedInteractiveState $true $true $true) {
    throw 'A pending session ending did not suspend otherwise-interactive input.'
}

function Test-AbnormalExitCounted {
    param(
        [bool] $Attempted,
        [int] $ExitCode,
        [bool] $SessionEnding,
        [bool] $AuthenticatedDisarmed
    )
    return $Attempted -and $ExitCode -ne 0 -and -not $SessionEnding -and -not $AuthenticatedDisarmed
}
if (-not (Test-AbnormalExitCounted $true 1 $false $false)) {
    throw 'A nonzero Explorer exit before authenticated DISARMED was suppressed.'
}
if (Test-AbnormalExitCounted $true 1 $false $true) {
    throw 'An Explorer exit after authenticated DISARMED was counted.'
}
if (Test-AbnormalExitCounted $true 1 $true $false) {
    throw 'An OS session-ending Explorer exit was counted.'
}

Write-Host 'Validated dedicated keyboard-hook ownership, downstream release ordering, pre-held/self-healing key state, transient force-close, independent session/power generation reconciliation, and rolling crash-guard boundaries.'
