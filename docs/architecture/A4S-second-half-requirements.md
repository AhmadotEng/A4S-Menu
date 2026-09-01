# A4S Menu second-half requirement and evidence ledger

This ledger turns the second-half plan into release gates. A requirement is
complete only when its implementation and the listed evidence both exist.
Passing a source inspection is not a substitute for a Windows interaction
test, and an interactive observation is not a substitute for an automated
failure-path check where one is practical.

## Provenance and safety boundary

- Exact first-half rollback commit:
  `42d61a4844f08f3a86752f41f54dac1b977987e4`.
- The full Open-Shell tree remains the development environment.
- Each installed immutable slot contains `A4SMenuHost.exe`, `A4SMenu.dll`, and a
  dormant `A4SMenuSetup.exe` maintenance/uninstall copy. The resident runtime is
  only the host process plus the DLL mapped in Explorer; setup is never a
  resident component.
- StartAllBack is disabled for qualification. Its still-mapped loader/runtime
  modules are recorded separately from the A4S result.
- The owner superseded the earlier native-fallback requirement on 2026-09-01.
  While the installed A4S product owns Start activation, native Start must not
  appear. Failure and crash-loop recovery must preserve that policy and expose
  diagnostics/manual repair instead of silently falling through to native
  Start.

Implementation and test procedures are documented in the
[native input/recovery contract](A4S-native-input-recovery.md),
[runtime-cache architecture](A4S-runtime-cache.md),
[one-file installer contract](A4S-product-installer.md),
[performance/stability plan](../testing/A4S-second-half-performance-and-stability.md),
[current-profile installer plan](../testing/A4S-current-profile-installer-lifecycle.md),
[failure-recovery plan](../testing/A4S-failure-recovery.md). These links show
that the implementation and harnesses exist; the rows below remain pending
until their required evidence is actually recorded.

## Native input and lifecycle

| ID | Requirement | Required evidence | Status |
| --- | --- | --- | --- |
| N1 | A lone left or right Windows-key press toggles A4S Menu. | Manual physical-key action on a fresh Explorer, activation-source trace, and visible-window assertion; do not synthesize Windows-key input. | [PASS for the available left key; right key absent](../testing/A4S-plan2-step1-live-2026-09-01.md) |
| N2 | A second lone Windows-key press closes the open menu. | Manual physical-key action, activation-source trace, and visible-window assertion. | [PASS](../testing/A4S-plan2-step1-live-2026-09-01.md) |
| N3 | Clicking the primary taskbar Start button uses the same toggle path. | Manual physical Start-button clicks plus activation-source trace for centered and left-aligned taskbars. | [PASS](../testing/A4S-plan2-step1-live-2026-09-01.md) |
| N4 | Win+R, Win+E, Win+L, Win+X, Win+Tab, and other modified Windows-key chords remain native and do not flash A4S Menu. | Shortcut matrix; disruptive lock test run separately. | [PASS](../testing/A4S-plan2-step1-live-2026-09-01.md) |
| N5 | Clicking or activating another application dismisses the menu normally; the menu is not permanently topmost. | Focus-transition window assertion and visual check. | [PASS](../testing/A4S-plan2-step1-live-2026-09-01.md) |
| N6 | Explorer restart/crash reconnects without polling or duplicate hooks. | Explorer PID transition, host status, exact DLL mapping, and one-menu assertion. | Pending |
| N7 | Lock/unlock and sleep/resume preserve or restore a usable connection. | Session/power transition test record. | Pending |
| N8 | Initialization failure preserves the installed product's native-Start suppression policy and exposes a diagnostic/manual-repair path. | Missing/corrupt/incompatible DLL tests plus Start-route and diagnostic observation. | Pending |
| N9 | Repeated Explorer failures trip a bounded crash-loop guard without silently restoring native Start, and expose a diagnostic/manual-repair path. | Deterministic guard-state test plus controlled live failure and Start-route tests. | Pending |
| N10 | Normal logical exit disarms callbacks before the host exits. | Lifecycle regression gate and inert-mapping assertion. | Pending |

## Performance and rendering

| ID | Requirement | Required evidence | Status |
| --- | --- | --- | --- |
| P1 | Measure cold and warm toggle-to-first-visible latency. | Timestamped samples and summary statistics. | [MEASURED on the exact build](../testing/A4S-plan2-step3-live-2026-09-01.md): cold external visible proxy 50.9119 ms; 30 warm external p50/p95 11.123/26.273 ms; standalone A4S marker p50/p95 13.644/15.541 ms. Physical presentation is not implied. |
| P2 | Warm opening is at most 50 ms on the qualification machine. | Repeated warm sample report. | [**PASS** on the recorded 239 Hz qualification machine](../testing/A4S-plan2-step3-live-2026-09-01.md): warm p95 is 15.541 ms standalone, 23.8565 ms under concurrent WPR load, and 37.938 ms through the external observer's `DwmFlush` proxy. |
| P3 | Closing completes within one display frame. | Custom close markers plus compositor-presentation trace at the actual menu monitor's nominal refresh mode. | [OPEN](../testing/A4S-plan2-step3-live-2026-09-01.md): app-marker p95 is 3.508 ms standalone and 3.6494 ms under WPR load versus 4.1841 ms nominal, but the external proxy p95 is 16.780 ms and no exact physical removal frame was identified. |
| P4 | Idle host and injected runtime consume effectively 0% CPU. | Timed host delta plus ETW/WPA attribution of Explorer CPU to the injected A4S code. | [**PASS within the recorded exact-build interval**](../testing/A4S-plan2-step3-live-2026-09-01.md): host 0.000000%; in 15.359748 seconds of passive ETW idle, 0/29 joined Explorer CPU-sample stacks contain `A4SMenu.dll`. |
| P5 | A warm toggle performs no filesystem reads/writes attributable to A4S. | WPR/ETW File I/O activity and stacks filtered to the exact Explorer PID and measured intervals. | [OPEN; strict 30/30 quiet rule not met](../testing/A4S-plan2-step3-live-2026-09-01.md): three first-cycle logical reads (32,768 bytes) have joined stacks without an A4S frame; 29 later intervals are logically quiet, but disk/hard-fault candidates lack joined stacks and physical quiet is not proven. |
| P6 | Record Explorer private-memory delta caused by A4S. | Before/after process-memory samples on a fresh Explorer. | [MEASURED](../testing/A4S-plan2-step3-live-2026-09-01.md): same-Explorer private-byte delta +3,842,048 bytes; working set +5,267,456 bytes; handles +48; threads -2. This remains process-wide correlation. |
| P7 | Measure pinned enumeration, icon loading, backdrop preparation, Programs enumeration, and search initialization. | Internal phase markers exported to the measurement tool or trace. | [MEASURED for the emitted scopes](../testing/A4S-plan2-step3-live-2026-09-01.md): warm pinned p95 0.0475 ms, backdrop p95 0.1595 ms; manual icon p95 3.523 ms, Programs p95 3.987 ms, search initialization 0.0936 ms. |
| P8 | The opening path avoids filesystem, registry, and shell-COM discovery calls. | Reviewed opening-path call graph plus system trace/stacks for the exact measured intervals. | [**NOT PASSED**](../testing/A4S-plan2-step3-live-2026-09-01.md): all 900/900 opening-interval registry events have joined stacks containing `A4SMenu.dll`; the three file reads do not have A4S frames, but strict quiet is unmet; no COM provider was captured. |
| P9 | Pinned metadata/icons are preloaded after Explorer is idle and reusable resources are cached. | Instrumented cache warm-up and repeat-open trace. | [PARTIAL](../testing/A4S-plan2-step3-live-2026-09-01.md): 30/30 repeat-open pinned operations are cache hits and very small, but capture began after `READY` and did not observe the initial idle preload. |
| P10 | Programs enumeration does not block first-frame presentation; search initializes only on first input. | Phase trace and cold interactive checks. | [PARTIAL](../testing/A4S-plan2-step3-live-2026-09-01.md): the physical manual trace recorded Programs after the visible menu and one search initialization after input, but has no first-keystroke/results-settled or Programs-visible-settled marker. |
| P11 | Opening shows no visible icon/text pop-in and repainting is bounded to required regions. | Frame capture/visual check and paint counters. | [PARTIAL](../testing/A4S-plan2-step3-live-2026-09-01.md): no icon/text pop-in is visible in the sampled pair and the maximum channel delta is 6, but the first sample can miss a transient and p95/max paint area is the full menu. |

## Installer and servicing

| ID | Requirement | Required evidence | Status |
| --- | --- | --- | --- |
| I1 | One `A4SMenuSetup.exe` embeds the exact host and DLL payload. | Resource/payload hash verification and clean-machine extraction test. | Pending |
| I2 | Default install is per-user under `%LocalAppData%\A4SMenu` and needs no elevation. | Standard-user install test and installed-file inventory. | Pending |
| I3 | Setup supports interactive install, repair/update, and uninstall. | End-to-end lifecycle test. | Pending |
| I4 | Setup supports documented silent command-line modes with deterministic exit codes. | Automated silent lifecycle matrix. | Pending |
| I5 | Current-user startup launches the installed host. | Startup registration inspection and fresh-logon test. | Pending |
| I6 | Windows Settings contains a correct uninstall entry. | HKCU uninstall-record assertion and Settings visual check. | Pending |
| I7 | Update/uninstall requests logical disarm before replacing or removing runtime files. | Host-state trace and locked-file/failure-path test. | Pending |
| I8 | Updates are atomic and retain one recoverable previous version. | Injected copy/validation failure tests and rollback hash check. | Pending |
| I9 | Setup does not force-restart Explorer; an interactive restart is requested only when actually needed. | Process-PID assertion and prompt-path test. | Pending |
| I10 | Uninstall removes product startup/registration/current files while preserving a recoverable failed-operation state. | Post-uninstall inventory and interrupted-uninstall test. | Pending |

## Windows qualification matrix

| ID | Scenario | Required evidence | Status |
| --- | --- | --- | --- |
| Q1 | 100%, 125%, 150%, and 200% DPI/scaling | Fixed-state captures and geometry assertions at each scale. | Pending |
| Q2 | Multiple monitors, including non-primary taskbar invocation | Monitor-specific placement and dismissal captures. | Pending |
| Q3 | Centered and left-aligned Windows 11 taskbars | Start-button and keyboard toggle checks for both alignments. | [PASS on the current display/DPI](../testing/A4S-plan2-step1-live-2026-09-01.md) |
| Q4 | Fullscreen application foreground behavior | Open/dismiss/no-steal-focus checks. | Pending |
| Q5 | Normal, Programs, search, context popup, power popup, and pinned-item states | Same-size captures compared with accepted references. | Pending |
| Q6 | Pin, unpin, run as administrator, and open-file-location commands | Functional checks for pinned and Programs entries. | Pending |
| Q7 | Sign-out/logon and clean startup | Installed-build reconnect and single-host assertion. | Pending |
| Q8 | Install, same-version repair, upgrade, rollback, uninstall, and load failure | Versioned end-to-end matrix with hashes and exit codes. | Pending |

## Completion rule

The second half is releasable only when every row is either **PASS** with a
linked result or explicitly **DEFERRED** by the user. A missing physical setup
(for example, no second monitor) is reported as untested, not silently treated
as a pass. Release records must identify the exact source commit, compiler and
SDK versions, staged hashes, setup hash, Windows build, display topology,
scaling values, refresh rate, and Explorer PID boundaries used by the tests.
