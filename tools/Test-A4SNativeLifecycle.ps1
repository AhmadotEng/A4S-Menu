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

if ($dllSource -match '\b(?:WH_KEYBOARD_LL|KBDLLHOOKSTRUCT|HookA4SKeyboard)\b') {
    throw 'A4S must not intercept or suppress physical keyboard events.'
}

$installMatch = [Regex]::Match($dllSource,
    '(?s)static bool InstallA4SNativeHotkeyHook\s*\(.*?\n\}\s*\n\s*static bool RefreshA4SNativeHotkeyHook')
if (-not $installMatch.Success) { throw 'The shell-manager hook transaction could not be isolated.' }
foreach ($pattern in @(
    'FindWindow\(L"ApplicationManager_ImmersiveShellWindow",NULL\)',
    'if\s*\(!shellWindow\)[\s\S]*FindWindow\(L"ApplicationManager_DesktopShellWindow",NULL\)',
    'GetWindowThreadProcessId\(shellWindow,&shellProcessId\)',
    'shellProcessId!=GetCurrentProcessId\(\)',
    'SetWindowsHookEx\(WH_GETMESSAGE,HookA4SNativeHotkey'
)) {
    Assert-Match $installMatch.Value $pattern `
        'The native shell-hotkey hook is not bound to an available validated Explorer shell-manager thread.'
}

$registrationHook = [Regex]::Match($dllSource,
    '(?s)static BOOL WINAPI ShellRegisterHotKeyHook\s*\(.*?\n\}')
if (-not $registrationHook.Success) { throw 'The TwinUI native-Start registration guard could not be isolated.' }
foreach ($pattern in @(
    'state>=A4S_NATIVE_TAKEOVER_PENDING',
    'hWnd==NULL\s*&&\s*hWndTarget==NULL',
    'id==A4S_NATIVE_WINDOWS_HOTKEY_ID\s*&&\s*fsModifiers==MOD_WIN\s*&&\s*vk==0',
    'id==A4S_NATIVE_CTRL_ESCAPE_HOTKEY_ID\s*&&\s*fsModifiers==MOD_CONTROL\s*&&\s*vk==VK_ESCAPE',
    'return g_ShellRegisterHotKey\(hWnd, id, fsModifiers, vk, hWndTarget\)'
)) {
    Assert-Match $registrationHook.Value $pattern `
        'The IAT guard no longer blocks only the two exact native-Start registrations while takeover is active.'
}

$takeoverInstall = [Regex]::Match($dllSource,
    '(?s)static DWORD InstallA4SNativeStartTakeover\s*\(.*?\n\}')
if (-not $takeoverInstall.Success) { throw 'The native-Start takeover installation could not be isolated.' }
foreach ($pattern in @(
    'GetProcAddress\([\s\S]*MAKEINTRESOURCEA\(2671\)\)',
    'GetModuleHandle\(L"twinui.dll"\)',
    'SetIatHook\(twinui,"user32.dll",[\s\S]*MAKEINTRESOURCEA\(2671\),ShellRegisterHotKeyHook\)',
    'RegisterWindowMessage\([\s\S]*A4SMenu\.NativeStartControl\.v1',
    'InvokeA4SNativeControl\(A4S_NATIVE_CONTROL_TAKEOVER'
)) {
    Assert-Match $takeoverInstall.Value $pattern `
        'The acknowledged TwinUI takeover transaction is incomplete.'
}

$controlCallback = [Regex]::Match($dllSource,
    '(?s)static bool HandleA4SNativeControlMessage\s*\(.*?\n\}')
if (-not $controlCallback.Success) { throw 'The manager-thread takeover callback could not be isolated.' }
foreach ($pattern in @(
    'generation==InterlockedCompareExchange\(&g_A4SNativeControlGeneration,0,0\)',
    'UnregisterHotKey\(NULL,A4S_NATIVE_WINDOWS_HOTKEY_ID\)',
    'UnregisterHotKey\(NULL,A4S_NATIVE_CTRL_ESCAPE_HOTKEY_ID\)',
    'ProbeA4SNativeCombinationFree\([\s\S]*A4S_PROBE_WINDOWS_HOTKEY_ID,MOD_WIN,0\)',
    'ProbeA4SNativeCombinationFree\([\s\S]*A4S_PROBE_CTRL_ESCAPE_HOTKEY_ID,[\s\S]*MOD_CONTROL,VK_ESCAPE\)',
    'g_ShellRegisterHotKey\(NULL,[\s\S]*A4S_NATIVE_WINDOWS_HOTKEY_ID,MOD_WIN,0,NULL\)',
    'g_ShellRegisterHotKey\(NULL,[\s\S]*A4S_NATIVE_CTRL_ESCAPE_HOTKEY_ID,[\s\S]*MOD_CONTROL,VK_ESCAPE,NULL\)',
    'SetEvent\(g_A4SNativeControlEvent\)'
)) {
    Assert-Match $controlCallback.Value $pattern `
        'The native registration takeover/restore callback lost its acknowledged exact-ID transaction.'
}

$activationInstall = [Regex]::Match($dllSource,
    '(?s)static bool InstallA4SActivationHooks\s*\(.*?\nfailed:.*?\n\}')
if (-not $activationInstall.Success) { throw 'The activation hook transaction could not be isolated.' }
foreach ($pattern in @(
    'if \(!IsWindow\(g_ProgWin\)\)[\s\S]*goto failed',
    'g_ProgHook=SetWindowsHookEx\(WH_GETMESSAGE,HookProgManThread',
    'InstallA4SNativeHotkeyHook\(\)',
    'InstallA4SNativeStartTakeover\(\)'
)) {
    Assert-Match $activationInstall.Value $pattern `
        'The taskbar, shell-manager, Progman, and registration takeover are not one activation transaction.'
}

$systemStartHandler = [Regex]::Match($dllSource,
    '(?s)static bool HandleA4SSystemStartMessage\s*\(\s*MSG \*message\s*\)\s*\r?\n\{.*?\r?\n\}')
if (-not $systemStartHandler.Success) { throw 'The shared SC_TASKLIST handler could not be isolated.' }
foreach ($pattern in @(
    'message->message!=WM_SYSCOMMAND',
    '\(message->wParam&0xFFF0\)!=SC_TASKLIST',
    'QueueA4SToggle\(g_TaskBar,A4S_KEYBOARD_TOGGLE\)',
    'message->message=WM_NULL'
)) {
    Assert-Match $systemStartHandler.Value $pattern `
        'SC_TASKLIST is no longer unconditionally routed to A4S while the product owns Start.'
}

$callbackMatch = [Regex]::Match(
    $dllSource,
    '(?s)static LRESULT CALLBACK HookA4SNativeHotkey\s*\([^;]+?\)\s*\r?\n\{.*?\r?\n\}\s*\r?\n#endif')
if (-not $callbackMatch.Success) {
    throw 'The A4S native shell-hotkey callback could not be isolated.'
}
$callback = $callbackMatch.Value
if ($callback -match '(?i)\b(?:new|malloc|calloc|realloc|RegOpen|CreateFile|ShellExecute|SendMessage|SendInput|keybd_event)\b') {
    throw 'The shell-hotkey callback contains allocation, I/O, shell, synchronous-send, or input-injection work.'
}
if ($callback -match '\breturn\s+1\s*;') {
    throw 'The shell-hotkey hook must never suppress a physical keyboard event.'
}
Assert-Match $callback 'code==HC_ACTION\s*&&\s*wParam==PM_REMOVE' `
    'The manager callback can consume a peeked message.'
Assert-Match $callback 'HandleA4SNativeControlMessage\(message\)' `
    'The shell-manager callback no longer executes the acknowledged takeover command.'
Assert-Match $callback 'HandleA4SSystemStartMessage\(message\)' `
    'The shell-manager queue no longer routes SC_TASKLIST through A4S.'
Assert-Match $callback 'IsA4SNativeStartHotkey\(message->message,message->wParam,message->lParam\)' `
    'Already-queued native Start hotkeys are not consumed during takeover.'
Assert-Match $callback 'CallNextHookEx\(g_A4SNativeHotkeyHook,code,wParam,lParam\)' `
    'The shell-hotkey hook no longer chains every message.'
Assert-Match $dllSource 'static_assert\(IsA4SNativeStartHotkey[\s\S]*shell lone-Windows-key hotkey must toggle A4S' `
    'The compile-time contract no longer accepts the shell lone-Windows-key message.'
Assert-Match $dllSource 'id==A4S_PROBE_WINDOWS_HOTKEY_ID[\s\S]*id==A4S_PROBE_CTRL_ESCAPE_HOTKEY_ID' `
    'A retained free-combination probe can strand the Start gesture outside A4S routing.'
Assert-Match $dllSource 'Ctrl\+Esc must use the A4S Start path' `
    'Ctrl+Esc can still expose native Start.'
Assert-Match $dllSource 'Win\+R must remain native' `
    'The compile-time contract no longer rejects Win+R.'
Assert-Match $dllSource 'g_ProgWin=GetShellWindow\(\)' `
    'The A4S product no longer resolves Explorer''s actual Progman shell window.'
Assert-Match $dllSource 'RestoreA4SNativeStart\(\)[\s\S]*ClearIatHook\(g_ShellRegisterHotKeyHook\)' `
    'Clean disarm can clear the IAT guard before restoring native registration ownership.'
Assert-Match $dllSource 'A4S_ACTIVATION_CLEAR_RESTORE_FAILED[\s\S]*Keep the IAT guard and every activation hook intact' `
    'A failed registration restoration can tear down the remaining A4S Start route.'
Assert-Match $dllSource 'clearResult==A4S_ACTIVATION_CLEAR_RESTORE_FAILED[\s\S]*A4S_INIT_READY' `
    'Initialization rollback can leave native Start disabled with A4S inert.'
Assert-Match $dllSource 'static bool RefreshA4SNativeHotkeyHook[\s\S]*RemoveA4SNativeHotkeyHook\(\)[\s\S]*InstallA4SNativeHotkeyHook\(\)' `
    'Shell-hotkey recovery no longer replaces the targeted message hook.'
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
    'bool ResetSafetyState\(\)[\s\S]*SafetyMutationLock mutationLock;[\s\S]*mutationLock\.acquire\(\)',
    'bool RecordExplorerExitForCrashGuard\([\s\S]*SafetyMutationLock mutationLock;[\s\S]*mutationLock\.acquire\(\)[\s\S]*ReadSafetyStateLocked\(state\)[\s\S]*AdvanceCrashGuard\(state,countAbnormalExit,now\)[\s\S]*PersistSafetyStateLocked\(state,exitCode\)[\s\S]*ApplySafetyStateToRuntime\(state\)'
)) {
    Assert-Match $hostSource $pattern `
        'A HostSafety load/reset path or crash read-modify-write transaction escaped cross-session serialization.'
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

Write-Host 'Validated acknowledged native-Start takeover, SC_TASKLIST routing without physical-key suppression, exact Win-shortcut preservation, transient force-close, independent session/power generation reconciliation, and rolling crash-guard boundaries.'
