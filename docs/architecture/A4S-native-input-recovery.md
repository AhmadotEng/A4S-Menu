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

The DLL creates a dedicated blocked message-loop thread and installs
`WH_KEYBOARD_LL` on that thread only as the final part of the product activation
transaction. Install, suspend, refresh, and stop requests use explicit events
and a two-second bounded handshake; the Explorer taskbar thread never owns or
pumps the low-level hook. A timeout immediately gates the callback, fails or
disarms activation, and leaves native Start as the fallback. The pinned DLL is
not hot-unloaded if a timed-out owner thread cannot be proven stopped.

Windows-key down is observed but passed through. Any other key-down while
either Windows key is held marks the gesture as a chord. The corresponding
Windows-key release is passed through for a chord and considered for A4S only
for an unmatched lone gesture. For that lone release, A4S first calls the next
hook; it queues and claims the release only if downstream returned zero and the
taskbar post succeeded. Downstream hooks therefore always see a matching
Windows-key release and cannot be left with a stuck Windows-key-down state.
Therefore Win+R, Win+E, Win+L, Win+X, Win+Tab, modified gestures, and future
chords do not use the A4S toggle path.

The owner thread seeds and maintains a fixed 256-key bitmap without allocation.
A Windows key already held when the hook starts is ineligible for a lone-key
toggle. Before each event, asynchronous state reconciles a tracked Windows key
whose release was lost; a later key or Windows-key-down therefore self-heals
instead of inheriting a stale chord. The callback only reads/updates this fixed
state, chains, and posts at most one message. It performs no registry, file,
COM, shell discovery, allocation, or synchronous taskbar call.

## Focus and session behavior

The inherited popup activation handler closes all A4S menu windows when the
foreground activates a non-menu window. A4S remains in the normal z-order band;
it is not permanently topmost.

The host dynamically registers current-session WTS notifications. It keeps
independent session and power latches, combines them with logical AND plus a
session-ending gate, and advances a monotonic generation for every transition in every host phase,
including `STARTING` and `INJECTING`. Consequently, an automatic power resume
cannot override a session that is still locked, and an unlock cannot override
a power state that is still suspended. A cancelled shutdown releases only the
session-ending gate, so it cannot overwrite a WTS lock received in the interim.
Each injection records its starting
generation. `READY` reconciles a transition missed during synchronous DLL
initialization before it releases a queued toggle. A suspended final state is
always sent to a fresh mapping; a suspend followed by resume during the attempt
sends a refresh only when both independent latches are interactive.

Lock, logoff, remote disconnect, and suspend queue `SUSPEND_INPUT`. The product
UI thread synchronously hides root, search, submenu, context, and power popups,
cancels context results, and queues their non-reentrant close path without
activating the taskbar or restoring another foreground window;
the keyboard owner then cancels partial state and stops accepting input. A
taskbar-side suspended latch rejects a toggle already queued by a racing
keyboard or Start-button callback, and the host rejects explicit toggles while
the interactive desktop is suspended.
Unlock, logon, remote connect, and resume recompute the combined state and queue
`REFRESH_INPUT` only after both latches are interactive. Refresh repeats the
transient cancellation and replaces the low-level hook on its owner thread.
If any bounded handshake fails, the DLL logically disarms all activation
callbacks and reports the inert state to the host. Explorer process exit
remains the authoritative reconnect boundary; no polling timer is added.

## Crash-loop fail-safe

Every production read-modify-write or reset of
`HKCU\Software\A4SMenu\HostSafety` is serialized by
`Global\A4SMenu.HostSafety.v1.<current-user-SID>`. The host holds that mutex
while loading, advancing, persisting, or resetting the guard. Setup acquires it
after its current-user lifecycle and payload-specific setup mutexes; the
failure-recovery harness uses the same `Lifecycle -> Setup -> HostSafety ->
current-desktop host` order. A lock/open/read/write failure is fail-closed and
cannot silently authorize injection.

The persisted product schema is flat, contains no subkeys, and after an
abnormal exit contains exactly these five values:

| Value | Registry type | Meaning |
| --- | --- | --- |
| `InjectionDisabled` | `REG_DWORD` | Nonzero after the rolling threshold trips. |
| `AbnormalExplorerExitCount` | `REG_DWORD` | Current retained timestamp count, at most three. |
| `AbnormalExplorerExitTimes` | `REG_BINARY` | Exactly three little-endian QWORD timestamp slots (24 bytes). |
| `AbnormalExplorerWindowStart` | `REG_QWORD` | First nonzero retained crash timestamp. |
| `LastExplorerExitCode` | `REG_DWORD` | Exit code from the most recently classified abnormal boundary. |

The host records abnormal Explorer exit times only when an authenticated A4S
initialization or ready activation was in flight. It persists the three exact
timestamps as `AbnormalExplorerExitTimes` (`REG_BINARY`), prunes every timestamp
older than 180 seconds, and appends the new abnormal exit. This is a true rolling
window rather than a count anchored to the first failure. The older count/window
values are accepted once and migrated conservatively; timestamps temporarily in
the future after a backward wall-clock correction are retained rather than
weakening the guard. Three abnormal exits
inside the rolling 180-second window persistently set
`HKCU\Software\A4SMenu\HostSafety\InjectionDisabled`. The resident host then
enters `SAFETY_DISABLED`, performs no further injection, and leaves the
replacement Explorer's native Start behavior untouched. Clean exits do not add
a timestamp and do not erase still-current abnormal timestamps.

A nonzero Explorer exit during `--exit` teardown still counts until the host
receives an authenticated `DISARMED` status; `exitPending` alone is not a
maintenance exemption because a crash during teardown may identify a faulty
DLL. Only a latched OS session ending (`WM_QUERYENDSESSION` or WTS logoff), or
the authenticated state after callbacks are inert, suppresses the abnormal
classification. The installer restarts Explorer only after disarm/host exit, so
that intended restart is no longer observed by this guard. Only explicit
installer `--repair` or an explicit `A4SMenuHost.exe --reset-safety` clears the
latch and begins a fresh validated connection. Installer `--update`, automatic
repair, install, and rollback preserve the latch. Reset is fail-closed: a mutex,
registry-open, or registry-deletion failure does not clear the in-memory latch.

The key classifier, pre-held modifier rule, and rolling crash-window transitions
have compile-time tests. Direct A4S product builds compile the dedicated owner
thread and host generation reconciliation with warning-as-error. The
non-injecting product gate additionally proves that ABI3 is rejected and ABI4
is accepted. Live verification must still cover lone-key open/close,
every named Windows shortcut, focus dismissal, lock/unlock, suspend/resume,
Explorer crash recovery, and the controlled crash-loop trip/reset sequence.

Run the source-only lifecycle gate without injection or registry writes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/Test-A4SNativeLifecycle.ps1
```

The offline, isolated-DLL, and deliberately destructive Explorer qualification
procedures are separated in
[the failure-recovery test plan](../testing/A4S-failure-recovery.md). Their
existence is not evidence that the isolated or live modes have run.
