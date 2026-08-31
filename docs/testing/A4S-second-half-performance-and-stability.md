# A4S Menu second-half performance and stability qualification

This document defines the evidence required for the second-half performance
and stability work. The tools deliberately separate observation from system
changes: they never install the product, start or inject the host, restart or
kill Explorer, change display settings, lock the session, sleep the computer,
or sign the user out.

## Safety boundary

`Get-A4SPerformanceSnapshot.ps1` is read-only. The two tools that visibly open
the menu refuse to run without `-AllowMenuAutomation`, require an already
resident host in `READY`, and send commands directly to that host. They cannot
start a missing host and therefore cannot inject Explorer accidentally.

Environment transitions remain manual:

- restart or crash Explorer outside the scripts;
- change taskbar alignment, monitor topology, or DPI in Windows Settings;
- enter and leave fullscreen applications;
- lock/unlock, sleep/resume, and sign out/in yourself;
- install, repair, update, and uninstall only through the installer test plan.

After each transition, record the resulting state with the scenario tool.

## Capture a clean resource baseline

Immediately after a fresh Explorer start, before launching A4SMenuHost, run:

```powershell
.\tools\Get-A4SPerformanceSnapshot.ps1 `
    -RequireCleanProductState `
    -OutputPath .\build\test-results\A4S-pre-injection.json
```

The clean-state switch proves that the snapshot has neither a mapped
`A4SMenu.dll` nor a resident A4S host. After starting the exact staged host and
waiting for `READY`, supply that file to the performance probe. It requires the
same Explorer PID, so the memory delta is a true same-process before/after
comparison rather than a comparison between unrelated Explorer instances.

The snapshot also records:

- exact staged binary paths and SHA-256 hashes;
- taskbar Explorer and resident-host process metrics and I/O counters;
- all monitor bounds, work areas, DPI, and scaling;
- taskbar edge and the Windows 11 alignment registry hint;
- foreground-window geometry and session/process identity.

## Measure the current build

Close the menu and run the performance probe only after the host reports
`READY`:

```powershell
.\tools\Measure-A4SProductPerformance.ps1 `
    -AllowMenuAutomation `
    -BaselinePath .\build\test-results\A4S-pre-injection.json `
    -WarmSamples 30 `
    -IdleSeconds 15 `
    -CapturePopInEvidence `
    -EnforceTargets
```

The probe sends the resident-host control message directly. It does not include
the startup cost of a transient `A4SMenuHost.exe --toggle` process. Each open
sample measures command dispatch to the first visible
`A4SMenu.CMenuContainer`, then calls `DwmFlush` and records the presentation
boundary. Close uses the corresponding hidden-window boundary and `DwmFlush`.

The current external gates are:

- warm-open p95 at or below 50 ms;
- close p95 within one refresh interval reported by the menu's display;
- resident host idle CPU at or below 0.05% of total machine capacity;
- no observed Explorer read/write operations or bytes during every warm open.

The report includes p50, p95, and maximum timings, every raw sample, host and
Explorer IDs, same-process memory deltas, and process-wide I/O deltas. The JSON
evidence is written before an enforced target failure is raised.

`-OperatorAttestsFirstOpenIsCold` labels the first sample as an operator
attestation; the tool cannot prove that no menu was opened earlier in that DLL
lifetime. A defensible cold run therefore needs the clean snapshot, a fresh
host, and the operator to run the probe before any other opening. Warm results
exclude that first sample.

Pop-in evidence consists of a PNG taken just after the first presented window
and another after the settle delay. Equal PNG hashes prove pixel stability for
that sample. Different hashes are inconclusive because acrylic, wallpaper,
the cursor, and other desktop animation can also alter pixels; compare the two
images visually.

## Measurement boundaries

External observation can prove host-toggle latency, display-frame close,
host idle CPU, same-Explorer memory growth, and process-wide Explorer I/O. It
cannot accurately attribute these internal phases:

- pinned-item enumeration;
- decoded-icon loading versus cache hits;
- acrylic/backdrop preparation;
- asynchronous All Programs enumeration;
- first-typing search initialization;
- a lone Windows-key event to first paint;
- repaint rectangles or the exact first fully populated frame.

Those require product markers. The recommended implementation is an A4S-only
ETW/TraceLogging provider that is dormant when no trace session listens and
emits QPC-correlated events for activation request/source, open-path begin,
pinned enumeration begin/end and count, icon load begin/end and cache hit,
acrylic prepare begin/end, window visible, first paint complete, Programs
enumeration begin/end, search initialization begin/end, close requested, and
window hidden. WPR file-I/O stacks can then distinguish A4S activity from
unrelated Explorer background work. This avoids adding a test-only export or
shared-memory ABI to the installed DLL.

Until those markers exist, the report labels Explorer CPU and I/O as
process-wide correlation, not A4S attribution. It must not be used to claim
that internal enumeration, icon, acrylic, or search targets passed.

## Record the stability matrix

The scenario tool records the current environment and can optionally verify an
open/close cycle without changing that environment:

```powershell
.\tools\Test-A4SCurrentScenario.ps1 `
    -ScenarioName dpi-125-centered `
    -ExpectedMonitorCount 1 `
    -ExpectedPrimaryScalePercent 125 `
    -ExpectedTaskbarAlignment center `
    -ExpectedTaskbarEdge bottom `
    -AllowMenuAutomation
```

To test normal Start-menu focus dismissal, add
`-ObserveManualFocusDismissal`. The tool opens the menu and asks the tester to
focus another application; it only observes that the menu disappears. If a
test fails, it closes a still-visible menu through the normal toggle path and
preserves the evidence.

Fullscreen and recovery runs can assert the state that the tester prepared
without causing the transition. For example, record a pre-lock entry and then
compare the post-unlock Explorer and session identities:

```powershell
.\tools\Test-A4SCurrentScenario.ps1 `
    -ScenarioName before-lock `
    -ExpectedHostPresence resident

# Lock and unlock Windows yourself, then:
.\tools\Test-A4SCurrentScenario.ps1 `
    -ScenarioName after-unlock `
    -CompareWithScenario before-lock `
    -ExpectedExplorerRelationship same `
    -ExpectedSessionRelationship same `
    -ExpectedHostPresence resident `
    -AllowMenuAutomation
```

Use `-ExpectedForegroundMode fullscreen` for a prepared fullscreen state,
`-ExpectedMenuMonitor` for a specific display device such as
`\\.\DISPLAY2`, and `-ExpectedMenuScalePercent` to prove the menu's actual
window DPI after opening. These are assertions only; the tool does not switch
applications, displays, taskbars, or sessions.

Entries append to `build/test-results/A4S-stability-matrix.json` by default.
Use a unique `-ScenarioName` and optional `-Notes` for every run.

The required matrix is:

| Area | Required scenarios | Evidence |
| --- | --- | --- |
| DPI | 100%, 125%, 150%, 200% | environment assertions, menu DPI/rect, visual capture |
| Taskbar | centered and left aligned; bottom required, other edges if supported | alignment/edge assertion, open/close |
| Monitors | one monitor, two monitors, mixed DPI, opening from each taskbar | topology snapshot, menu monitor/rect |
| Input | lone Win open/close; Win+R/E/L/X/Tab unaffected; Start click same path | input harness plus marker/source evidence |
| Focus | click another app; Alt+Tab; outside click; foreground loss | manual-focus observation and visual check |
| Fullscreen | borderless and exclusive fullscreen | pre/post scenario record and application-specific result |
| Explorer | normal restart, forced crash recovery, initialization failure | new PID record, host recovery/status, native Start fail-safe |
| Session | lock/unlock, sleep/resume, sign-out/sign-in | post-transition scenario record and recovery/status |
| Package | install, upgrade, repair, uninstall, interrupted update | installer logs, file/registry/startup state, rollback result |
| Failure guard | missing/corrupt DLL and repeated Explorer failure | native Start result, automatic disable record, recovery action |

The scenario tool does not pretend that recording one current configuration
proves the whole matrix. Each row needs its own authoritative run and, where
not automatable safely, a screenshot or installer/session log.

## Static tooling gate

Run the non-injecting tool gate after edits:

```powershell
.\tools\Test-A4SPerformanceTools.ps1
```

It parses every performance/stability script, compiles each embedded native
helper, verifies explicit menu-automation gates, rejects a list of destructive
system commands, and smoke-tests only the read-only environment snapshot. It
does not open the menu or alter Explorer.

## Current qualification status

The harness is implemented, but no second-half live performance run or full
matrix run is implied by its existence. The following evidence still requires
an explicit live test after the native-input, optimization, and installer work
stabilizes:

- clean same-Explorer before/after memory capture;
- operator-attested cold opening and repeated warm-opening samples;
- first-paint/pop-in image comparison;
- ETW-attributed internal phase and warm-I/O timings;
- all monitor, DPI, alignment, fullscreen, Explorer, and session scenarios;
- installation, update, repair, rollback, uninstall, and crash-loop guard.
