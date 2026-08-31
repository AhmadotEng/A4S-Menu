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
- The installed runtime must contain only `A4SMenuHost.exe` and `A4SMenu.dll`.
  `A4SMenuSetup.exe` is the distributable installer, not a resident component.
- StartAllBack is disabled for qualification. Its still-mapped loader/runtime
  modules are recorded separately from the A4S result.
- A failed or crash-loop-disabled A4S initialization must leave Windows' native
  Start path available.

## Native input and lifecycle

| ID | Requirement | Required evidence | Status |
| --- | --- | --- | --- |
| N1 | A lone left or right Windows-key press toggles A4S Menu. | Automated input trace plus visible-window assertion on a fresh Explorer. | Pending |
| N2 | A second lone Windows-key press closes the open menu. | Open/close timing and visible-window assertion. | Pending |
| N3 | Clicking the primary taskbar Start button uses the same toggle path. | Centered and left-aligned taskbar interaction tests. | Pending |
| N4 | Win+R, Win+E, Win+L, Win+X, Win+Tab, and other modified Windows-key chords remain native and do not flash A4S Menu. | Shortcut matrix; disruptive lock test run separately. | Pending |
| N5 | Clicking or activating another application dismisses the menu normally; the menu is not permanently topmost. | Focus-transition window assertion and visual check. | Pending |
| N6 | Explorer restart/crash reconnects without polling or duplicate hooks. | Explorer PID transition, host status, exact DLL mapping, and one-menu assertion. | Pending |
| N7 | Lock/unlock and sleep/resume preserve or restore a usable connection. | Session/power transition test record. | Pending |
| N8 | Initialization failure passes native Start through. | Missing/corrupt/incompatible DLL tests and native-Start observation. | Pending |
| N9 | Repeated Explorer failures trip a bounded crash-loop guard, disable injection, and keep native Start available. | Deterministic guard-state test plus controlled live failure test. | Pending |
| N10 | Normal logical exit disarms callbacks before the host exits. | Lifecycle regression gate and inert-mapping assertion. | Pending |

## Performance and rendering

| ID | Requirement | Required evidence | Status |
| --- | --- | --- | --- |
| P1 | Measure cold and warm toggle-to-first-visible latency. | Timestamped samples and summary statistics. | Pending |
| P2 | Warm opening is at most 50 ms on the qualification machine. | Repeated warm sample report. | Pending |
| P3 | Closing completes within one display frame. | Close sample report with detected display refresh interval. | Pending |
| P4 | Idle host and injected runtime consume effectively 0% CPU. | Timed process CPU delta while idle. | Pending |
| P5 | A warm toggle performs no filesystem reads/writes attributable to A4S. | I/O-counter and/or ETW evidence with documented scope. | Pending |
| P6 | Record Explorer private-memory delta caused by A4S. | Before/after process-memory samples on a fresh Explorer. | Pending |
| P7 | Measure pinned enumeration, icon loading, backdrop preparation, Programs enumeration, and search initialization. | Internal phase markers exported to the measurement tool or trace. | Pending |
| P8 | The opening path avoids filesystem, registry, and shell-COM discovery calls. | Trace plus reviewed opening-path call graph. | Pending |
| P9 | Pinned metadata/icons are preloaded after Explorer is idle and reusable resources are cached. | Instrumented cache warm-up and repeat-open trace. | Pending |
| P10 | Programs enumeration does not block first-frame presentation; search initializes only on first input. | Phase trace and cold interactive checks. | Pending |
| P11 | Opening shows no visible icon/text pop-in and repainting is bounded to required regions. | Frame capture/visual check and paint counters. | Pending |

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
| Q3 | Centered and left-aligned Windows 11 taskbars | Start-button and keyboard toggle checks for both alignments. | Pending |
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
