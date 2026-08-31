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
start a missing host and therefore cannot inject Explorer accidentally. Their
window observations are restricted to `A4SMenu.CMenuContainer` windows owned
by the taskbar Explorer process, and failure cleanup uses the normal toggle
path to close a menu that the test opened.

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

The clean-state switch rejects a snapshot if it observes either a mapped
`A4SMenu.dll` or a resident A4S host at capture time. After starting the exact staged host and
waiting for `READY`, supply that file to the performance probe. It requires the
same Explorer PID, so the memory delta is a true same-process before/after
comparison rather than a comparison between unrelated Explorer instances. It
remains a process-wide correlation: unrelated Explorer allocations between the
two snapshots are part of the delta.

The snapshot also records:

- exact staged binary paths and SHA-256 hashes;
- taskbar Explorer and resident-host process metrics and I/O counters;
- all monitor bounds, work areas, and monitor scale from
  `GetScaleFactorForMonitor`, with effective DPI derived from that scale (an
  unavailable value is recorded as unavailable, never invented as 96);
- taskbar edge and the Windows 11 alignment registry hint;
- foreground-window geometry and session/process identity.

## Start the staged host for manual qualification

Keep the staged product path stable between builds so the same manual entry
point can be reused throughout qualification. After taking the clean baseline,
start the host and confirm its injected state with:

```powershell
$menuHost = 'C:\Users\Admin\Downloads\StartAllBack-analysis-handoff\Open-Shell-Menu\build\stage\A4SProduct\A4SMenuHost.exe'

Start-Process -FilePath $menuHost
Start-Sleep -Seconds 2
& $menuHost --status
```

The expected healthy result is `READY`. Do not move or rename the staged
`A4SProduct` directory during a qualification sequence because the exact host
and DLL paths and hashes are part of the evidence checks.

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

The probe verifies that the resident host and DLL are the exact files in the
selected product directory, and that the observer, host, and taskbar
Explorer share one interactive session. It then sends the resident-host control
message directly. It does not include the startup cost of a transient
`A4SMenuHost.exe --toggle` process. Each open sample measures command dispatch
until an Explorer-owned `A4SMenu.CMenuContainer` is observed visible, then
calls `DwmFlush` from the observer process. Close records the corresponding
hidden-window observation and observer-process `DwmFlush` boundary.

These are external proxies, not first/last-presented-frame markers.
`IsWindowVisible` can change before composition, and `DwmFlush` in PowerShell
does not prove which frame contained another process's window update. The 1 ms
poll also inherits scheduler granularity and can create conservative timing
failures. Product-side QPC/ETW markers and a presentation trace are required
for authoritative frame claims.

The staged product directory is the default. To qualify an installed payload,
pass its directory explicitly, for example
`-ProductDirectory (Join-Path $env:LOCALAPPDATA 'A4SMenu')`. The report records
the exact host and DLL SHA-256 hashes.

The current external proxy gates are:

- warm-open observer/DWM proxy p95 at or below 50 ms;
- close observer/DWM proxy p95 within one nominal refresh interval reported by
  the menu's display;
- resident host idle CPU at or below 0.05% of total machine capacity;
- no change to Explorer's process-wide read/write I/O counters during every
  warm open.

The report includes p50, p95, and maximum timings, every raw sample, exact
binary paths, host and Explorer IDs, same-process memory deltas, and
process-wide I/O-counter deltas. The JSON
evidence is written before an enforced target failure is raised.

The I/O-counter gate is not a physical-disk proof. Unrelated Explorer work can
increment it (false positive), while cache hits, paging, and memory-mapped I/O
can escape it (false negative). Use WPR/ETW file-I/O events and stacks for the
actual "no warm disk access" acceptance claim.

`-OperatorAttestsFirstOpenIsCold` labels the first sample as an operator
attestation; the tool cannot prove that no menu was opened earlier in that DLL
lifetime. A defensible cold run therefore needs the clean snapshot, a fresh
host, and the operator to run the probe before any other opening. Warm results
exclude that first sample and still contain exactly `-WarmSamples` samples. If
the switch is omitted, the tool performs one unmeasured open/close warm-up
before collecting exactly `-WarmSamples` warm samples.

Pop-in evidence consists of a PNG sampled after the first observer-process
`DwmFlush` and another after the settle delay. Equal PNG hashes show pixel
equality for those two sampled captures only; the first capture can miss
shorter-lived pop-in. Different hashes are inconclusive because acrylic,
wallpaper, the cursor, and other desktop animation can also alter pixels;
compare the two images visually.

## Measurement boundaries

External observation can measure host-toggle/window-visibility proxies, host
idle CPU, same-Explorer memory growth, and process-wide Explorer I/O counters.
It cannot prove exact presented-frame latency, physical disk quiet, or
accurately attribute these internal phases:

- pinned-item enumeration;
- decoded-icon loading versus cache hits;
- acrylic/backdrop preparation;
- asynchronous All Programs enumeration;
- first-typing search initialization;
- a lone Windows-key event to first paint;
- repaint rectangles or the exact first fully populated frame.

The product now includes the A4S-only `A4SMenu.Runtime` TraceLogging provider,
which is dormant when no trace session listens. It emits correlated operation
events for activation source, open/close paths, pinned and Programs
enumeration, icon load/cache result, backdrop preparation, visibility, first
paint, search initialization, preload, and hiding. The external PowerShell
report does not start or parse that provider. An explicit WPR/ETW capture and
analysis pass is still required; file-I/O and presentation stacks can then
distinguish A4S activity from unrelated Explorer background work without a
test-only export or shared-memory ABI in the installed DLL.

Until those markers exist, the report labels Explorer CPU and I/O as
process-wide correlation, not A4S attribution. It must not be used to claim
that internal enumeration, icon, acrylic, search, exact frame, or physical-disk
targets passed.

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
focus another application. A pass requires both menu disappearance and a new
foreground window owned by a non-Explorer process. If a test fails, it attempts
to close a still-visible menu through the normal toggle path.

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

Launching a command from a terminal normally makes that terminal foreground.
For a fullscreen/windowed foreground assertion, add (for example)
`-ForegroundObservationDelaySeconds 5` and reactivate the target application
during the countdown. The snapshot occurs only after that delay.

Fullscreen classification is intentionally named a geometry heuristic in the
evidence. It requires a non-shell, non-minimized foreground window whose bounds
cover one monitor within two pixels; it does not distinguish exclusive
fullscreen from a borderless window. Pair it with application-specific or
present-mode evidence. Taskbar alignment is likewise the Windows 11 registry
hint, not a pixel-level observation of the Start button.

`-ExpectedHostPresence resident` checks only for the host window. Recovery
qualification must also use `-AllowMenuAutomation`, which requires `READY`, an
A4S DLL mapping in the taskbar Explorer process, shared session identity, and a
successful foreground open/close cycle.

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

It parses every performance/stability script, compiles a freshly renamed copy
of each embedded native helper, verifies `RECT`, `IO_COUNTERS`,
`MONITORINFOEX`, and `DEVMODE` byte sizes, checks explicit automation gates and
Explorer-owner filtering, rejects a curated list of destructive commands and
native APIs, and smoke-tests only the read-only environment snapshot. The
denylist is defense in depth rather than proof about arbitrary future code; a
human review remains required. The gate does not open the menu or alter
Explorer.

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
