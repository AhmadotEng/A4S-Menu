# A4S native input and recovery contract

This document describes the ABI4 native-input and recovery implementation.
It does not claim the interactive Windows qualification rows are complete;
those rows still require a fresh Explorer and the release test matrix.

## One toggle path

The native taskbar Start button, a lone left or right Windows-key gesture, and
the host `--toggle` command all queue `A4S_MENU_COMMAND_TOGGLE` to the validated
taskbar thread. That thread is the only place that calls `ToggleStartMenu`.
An input event is suppressed only after its toggle command has been queued.
If initialization is incomplete, the taskbar is invalid, or queuing fails, the
event passes through and Windows' native Start path remains available.

The DLL installs a `WH_KEYBOARD_LL` decision hook only as the final part of the
product activation transaction. Windows-key down is observed but passed
through. Any other key-down while either Windows key is held marks the gesture
as a chord. The corresponding Windows-key release is passed through for a
chord and claimed only for an unmatched lone gesture. Therefore Win+R, Win+E,
Win+L, Win+X, Win+Tab, modified gestures, and future chords do not use the A4S
toggle path. The callback is allocation-free and performs no registry, file,
COM, or shell discovery work.

## Focus and session behavior

The inherited popup activation handler closes all A4S menu windows when the
foreground activates a non-menu window. A4S remains in the normal z-order band;
it is not permanently topmost.

The host dynamically registers current-session WTS notifications. Lock,
logoff, remote disconnect, and suspend queue `SUSPEND_INPUT`, which closes
transient menu UI and clears partial Windows-key state. Unlock, logon, remote
connect, and resume queue `REFRESH_INPUT`, which closes stale UI and replaces
the low-level keyboard hook. If refresh cannot safely remove or recreate that
hook, the DLL logically disarms all activation callbacks and reports the inert
state to the host. Explorer process exit remains the authoritative reconnect
boundary; no polling timer is added.

## Crash-loop fail-safe

The host records abnormal Explorer exit codes only when an authenticated A4S
initialization or ready activation was in flight. Three abnormal exits inside a
rolling 180-second window persistently set
`HKCU\Software\A4SMenu\HostSafety\InjectionDisabled`. The resident host then
enters `SAFETY_DISABLED`, performs no further injection, and leaves the
replacement Explorer's native Start behavior untouched. A clean Explorer exit
clears the rolling count. Installer repair or an explicit
`A4SMenuHost.exe --reset-safety` clears the latch and begins a fresh validated
connection. The reset is fail-closed: a registry deletion failure does not
clear the in-memory latch.

The key classifier and crash-window transition logic have compile-time tests.
The non-injecting product gate additionally proves that ABI3 is rejected and
ABI4 is accepted. Live verification must still cover lone-key open/close,
every named Windows shortcut, focus dismissal, lock/unlock, suspend/resume,
Explorer crash recovery, and the controlled crash-loop trip/reset sequence.
