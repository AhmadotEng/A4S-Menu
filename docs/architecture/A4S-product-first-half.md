# A4S Menu product architecture - first half

> Historical milestone: this document is frozen to the completed first-half
> ABI3/two-file runtime and explains what was intentionally deferred at that
> time. It is not the current package, ABI, installer, cache, or qualification
> contract. Follow the current documents linked from the repository README for
> second-half behavior.

This document is the first-half product contract. It describes the two-binary
build split and the safe Explorer lifecycle that are completed before native
Windows-key routing, performance optimization, and installer work.

## Frozen baseline and rollback

- Source baseline: commit `edc8bf0fc31f1dc302701716717a5284f13dadff`.
- Implementation branch: `a4s-product-first-half`.
- Accepted profile: `A4SMenu/phase4-source-profile/23`.
- The ignored local rollback archive is
  `build/baseline/profile23-edc8bf0/`. It contains the accepted
  `StartMenu.exe`, `StartMenuDLL.dll`, hashes, and capture-profile record.
- The upstream solution and the `-nohook` preview remain development tools.
  The product build does not replace their outputs.

## First-half product boundary

The staged product contains exactly two x64 files:

- `A4SMenuHost.exe` - the per-session Explorer injection and reconnect host.
- `A4SMenu.dll` - the popup menu UI, fixed profile, item/program model, search,
  shell commands, interactions, and rendering.

No standalone Open-Shell settings program, skin chooser, updater, installer,
Classic Explorer/IE component, taskbar styler, help bundle, language DLL, or
development preview tool is staged. The full Open-Shell repository remains the
development and debugging environment; source retention does not make a file
part of the installed product.

The DLL is not a clean-room menu implementation. The accepted fixed profile
still needs selected inherited runtime pieces, including settings descriptors,
embedded English localization, skin evaluation, custom-menu parsing, shell
item metadata, icon loading, Programs-tree enumeration, and search. The first
half removes or excludes product-facing configuration and unused interaction
surfaces where safe, but does not delete upstream source merely to reduce the
repository. Deeper removal is allowed only after the accepted interaction
states continue to pass.

## Build isolation

`Src/A4SMenu/A4SMenu.Product.sln` has one supported configuration:
`A4SProduct|x64`. It defines `A4S_PRODUCT=1`, writes isolated intermediates and
outputs under `build/A4SProduct`, and does not alter the upstream
`OpenShell.sln` outputs.

`A4SMenuHost.exe` resolves its canonical absolute sibling `A4SMenu.dll` at
runtime. It has no import-library dependency on the menu DLL. The DLL exposes
only the versioned C entry points declared in
`Src/A4SMenu/Shared/A4SProductApi.h`.

## Runtime identity and trust boundary

The product build has A4S-only identities for its registry and policy paths,
local data, window classes, registered messages, clipboard formats, mutexes,
and status notifications. It can therefore coexist with source and installed
Open-Shell builds without intentionally sharing their configuration.

Each injection attempt has a random nonzero cookie. The host publishes that
cookie as `A4SMenu.Host.AttemptCookie.v1` on its hidden control window before
installing the bootstrap hook, then posts `A4SMenu.Dll.Bootstrap.v1` with the
host HWND and cookie to the validated taskbar. Explorer captures that identity
before initialization and never substitutes a newer host's cookie while the
attempt is in flight. `A4SMenu.Dll.Status.v2` reports `READY`, `FAILED`, or
`DISARMED` with the captured cookie and producing Explorer PID. The host accepts
only the cookie and PID for its current validated attempt and only a legal state
transition. This rejects stale attempts and accidental registered-message
traffic.

This is a stale-message defense, not a security boundary against another
process running as the same user at the same integrity level. Such processes
can inspect the host window and remain inside the first-half trust boundary.

## Host and DLL lifecycle

1. The host enforces one instance per interactive session and desktop.
2. It locates `Shell_TrayWnd` and validates that its owner is the same-session,
   native x64 `%WINDIR%\explorer.exe`.
3. It loads only the absolute sibling DLL in the host process, negotiates ABI
   `0x00030000`, publishes the attempt cookie, and installs a `WH_GETMESSAGE`
   bootstrap hook on the validated taskbar thread.
4. Product `DllMain` records the module handle only. COM, settings,
   localization, logging, manager creation, and hook installation run later
   from the Explorer-side bootstrap callback, outside loader lock.
5. The Explorer mapping pins itself before creating managers, workers, or
   activation hooks. Initialization is a one-way transaction for that Explorer
   process.
6. Native Start input is intercepted only after required initialization and
   activation hooks commit. The DLL then reports `READY` with the current
   cookie, and the host removes its bootstrap hook.
7. The host's message pump waits directly on the validated Explorer process
   handle with no idle polling. Process exit is the authoritative reconnect
   boundary; `TaskbarCreated` is only an early replacement hint. A replayed
   broadcast or same-process taskbar recreation cannot create a second
   activation set.

Initialization failure reports `FAILED` and leaves that mapping inert. It is
not retried in the same Explorer process.

## Shutdown means logical disarm, not unload

`A4SMenuHost.exe --exit` asks the Explorer mapping to disarm first. The DLL
enters `DISARMING`, closes the visible menu, removes or neutralizes activation
callbacks, tears down safely closable runtime state, and reports `DISARMED`.
Callbacks are gated on the `READY` state, so a callback whose OS hook could not
be physically removed only passes through and cannot reopen the menu. After
the acknowledgement, the host exits.

The Explorer copy of `A4SMenu.dll` deliberately remains pinned and mapped until
that Explorer process exits. Unloading code while inherited workers, COM
objects, window procedures, or an OS hook might still reference it is unsafe.
Consequently:

- a stopped host plus a mapped DLL is the expected post-test state;
- `DISARMED` and `FAILED` mappings never reinitialize;
- `--rehook` is intentionally unsupported while the same Explorer is alive;
- a fresh activation after disarm requires a real Explorer process restart and
  a new host launch;
- no first-half tool automatically restarts or kills Explorer.

The native Start path remains the fail-safe before `READY`, after a failed
initialization, and after logical disarm. The first half does not yet make the
full native-keyboard-routing guarantee planned for the second half.

## Host command surface

- no argument: start the resident host and begin a fresh connection;
- `--toggle`: ask the ready host to open or close the menu (or launch the host
  with one pending toggle when no host exists);
- `--status`: return success only for `READY`;
- `--exit`: logically disarm the DLL and then stop the host;
- `--version`: report the product version without becoming resident;
- `--rehook`: reserved for a new Explorer boundary and rejected for the same
  live Explorer process.

## Verification gates

Build and run the non-injecting static gate:

```powershell
.\tools\Build-A4SProduct.ps1
.\tools\Test-A4SProduct.ps1
```

The static gate verifies exact two-file staging, x64 PE format, exact DLL
exports, exact reviewed dependency allowlists, A4S version metadata, ABI
negotiation in a non-injecting test process, and the non-resident `--version`
path. It loads the
DLL only in the test process and does not inject Explorer.

For visual QA, `tools/Preview-A4SProduct.ps1 -CenterBottom` uses the retained
upstream `-nohook` development launcher. It does not inject Explorer.

After static and visual gates pass, the explicit lifecycle test is:

```powershell
.\tools\Test-A4SProductLifecycle.ps1 -AllowExplorerInjection
```

That test refuses to begin if a host is already running or if an A4S menu DLL
is already mapped in the fresh taskbar Explorer. It runs the static gate first,
starts the exact staged host, waits for `READY`, verifies the exact staged DLL
path in the taskbar Explorer, toggles the menu open and closed by its product window
class, requests `--exit`, and verifies the host and menu close. It then confirms
that the DLL remains mapped as the expected inert pin. The script never invokes
`--rehook`, never restarts Explorer, and never kills the host as a shortcut to
cleanup.

Restart Explorer manually before repeating the lifecycle test. This is an
intentional first-half limitation, not a test leak.

## Deferred to the second half

The following remain outside this phase:

- lone-Windows-key routing and proof that Win+R, Win+E, Win+L, Win+X, Win+Tab,
  and other Windows shortcuts remain native;
- complete focus-dismissal, lock/unlock, sleep/resume, fullscreen, taskbar
  alignment, multiple-monitor, mixed-DPI, and crash-recovery qualification;
- measured warm/cold opening, icon and metadata caching, asynchronous Programs
  enumeration, lazy search initialization, repaint reduction, memory, CPU, and
  disk-I/O optimization;
- crash-loop detection and automatic injection disablement;
- the one-file installer, per-user startup registration, repair, atomic update,
  rollback, uninstall, and silent command-line modes.

These are intentionally deferred so first-half lifecycle and product-boundary
failures can be diagnosed without mixing them with installer or performance
work.
