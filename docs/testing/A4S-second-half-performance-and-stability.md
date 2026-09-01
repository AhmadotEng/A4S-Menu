# A4S Menu second-half performance and stability qualification

This document defines the evidence required for the second-half performance
and stability work. The tools deliberately separate observation from system
changes: they never install the product, start or inject the host, restart or
kill Explorer, change display settings, lock the session, sleep the computer,
or sign the user out.

See also the [second-half requirement ledger](../architecture/A4S-second-half-requirements.md),
[runtime-cache architecture](../architecture/A4S-runtime-cache.md),
[custom runtime-trace reference](A4S-runtime-trace.md), and
[failure-recovery plan](A4S-failure-recovery.md). The current exact-build live
result is the [2026-09-01 Plan 2 Step 3 record](A4S-plan2-step3-live-2026-09-01.md).

## Safety boundary

`Get-A4SPerformanceSnapshot.ps1` is read-only. The three tools that can visibly open
the menu refuse to run without `-AllowMenuAutomation`, require an already
resident host in `READY`, and send commands directly to that host. They cannot
start a missing host and therefore cannot inject Explorer accidentally. Their
window observations are restricted to `A4SMenu.CMenuContainer` windows owned
by the taskbar Explorer process, and failure cleanup uses the normal toggle
path to close exactly one menu that the test opened. They refuse an ambiguous
cleanup toggle if more than one matching Explorer-owned menu is visible. A
shared `Local\A4SMenu.QualificationAutomation.v1.<session-id>` mutex also
prevents the performance, trace, and automated-scenario tools in this Windows
session from overlapping their menu cycles. It coordinates only these
cooperating tools; it neither blocks manual input nor serializes another Windows
session. Scenario
cleanup records the exact window it opened and will not close a newly opened
menu after the scenario's own dismissal was already observed.

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
$productDirectory = 'C:\Users\Admin\Downloads\StartAllBack-analysis-handoff\Open-Shell-Menu\build\stage\A4SProduct'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$baselinePath = ".\build\test-results\A4S-pre-injection-$runId.json"

.\tools\Get-A4SPerformanceSnapshot.ps1 `
    -RequireCleanProductState `
    -ProductDirectory $productDirectory `
    -OutputPath $baselinePath
```

The clean-state switch rejects a snapshot if Explorer is more than 120 seconds
old, either selected product binary is missing, or it observes either a mapped
`A4SMenu.dll` or a resident A4S host at capture time. It revalidates the
Explorer/taskbar identity, mappings, host absence, and staged hashes at the end
of capture. After starting the exact staged host and
waiting for `READY`, supply that file to the performance probe. It requires the
same Explorer PID, so the memory delta is a true same-process before/after
comparison rather than a comparison between unrelated Explorer instances. It
remains a process-wide correlation: unrelated Explorer allocations between the
two snapshots are part of the delta.

Snapshot schema 3 records that the explicit clean-state contract was requested,
the observed Explorer age, and the maximum accepted age. The performance probe
rejects an ordinary read-only observation even when it happens to show no host
or mapping; it accepts only an explicit clean baseline whose recorded maximum
is no weaker than 120 seconds.

The snapshot also records:

- exact selected product directory, binary paths, lengths, and SHA-256 hashes;
- taskbar Explorer and resident-host process metrics and I/O counters;
- all monitor bounds, work areas, and monitor scale from
  `GetScaleFactorForMonitor`, with effective DPI derived from that scale (an
  unavailable value is recorded as unavailable, never invented as 96);
- taskbar edge and the Windows 11 alignment registry hint;
- foreground-window geometry, Windows SID, numeric session, token logon ID,
  process start time, and process identity.

The performance run rejects a baseline older than ten minutes and requires its
selected host/DLL paths, lengths, and hashes to match the files and resident
images under test. Baseline memory remains process-wide correlation: the tool
cannot attribute unrelated Explorer allocations to A4S.

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
    -ProductDirectory $productDirectory `
    -BaselinePath $baselinePath `
    -WarmSamples 30 `
    -IdleSeconds 15 `
    -OperatorAttestsFirstOpenIsCold `
    -CapturePopInEvidence `
    -EnforceTargets
```

The probe verifies both file SHA-256 and PE/RSDS build identity against the
actual resident host image and Explorer-mapped DLL, and requires the selected
paths, process start times, numeric session, and token logon identity to remain
stable. It then sends the resident-host control
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

Window ownership checks re-resolve class/title, HWND, owner PID, process start
time, session/logon identity, and host READY state throughout a run. They detect
process/PID replacement and ordinary host-window replacement, but a numeric
HWND is a recyclable kernel value: there is no independent window-creation
generation in the external observer. A same-process destroy-and-recreate event
that reused the same value inside a narrow observation interval is therefore a
residual ambiguity. Correlate the product operation IDs/window markers in the
custom trace when that distinction matters.

The staged product directory is the default, but qualification commands pass it
explicitly so a baseline cannot be reused accidentally against another source.
The installed product root itself does **not** contain the active binaries.
They live in the immutable directory selected by
`HKCU\Software\A4SMenu\ActiveSlot` below `%LocalAppData%\A4SMenu\versions`.
Resolve and validate that directory with the read-only helper, then pass the
same exact value to both baseline and measurement:

```powershell
$productDirectory = .\tools\Resolve-A4SInstalledProductDirectory.ps1
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$baselinePath = ".\build\test-results\A4S-installed-pre-injection-$runId.json"

# With the installed host stopped/unhooked and Explorer freshly restarted:
.\tools\Get-A4SPerformanceSnapshot.ps1 `
    -RequireCleanProductState `
    -ProductDirectory $productDirectory `
    -OutputPath $baselinePath

$menuHost = Join-Path $productDirectory 'A4SMenuHost.exe'
Start-Process -FilePath $menuHost
Start-Sleep -Seconds 2
& $menuHost --status

.\tools\Measure-A4SProductPerformance.ps1 `
    -AllowMenuAutomation `
    -ProductDirectory $productDirectory `
    -BaselinePath $baselinePath `
    -WarmSamples 30 `
    -IdleSeconds 15 `
    -OperatorAttestsFirstOpenIsCold `
    -CapturePopInEvidence `
    -EnforceTargets
```

The resolver rejects a missing/empty registration, paths outside the canonical
`versions` directory, non-direct-child slots, reparse-point directories, and
non-regular host/DLL files. Every qualification tool recognizes an installed
slot, requires it to remain the registry `ActiveSlot`, and records that binding.
The clean baseline and performance run additionally require the same selected
directory, file lengths, hashes, Explorer PID/start time, and logon identity,
preserving the same-process memory comparison for installed runs.

The current external proxy gates are:

- warm-open observer/DWM proxy p95 at or below 50 ms;
- close observer/DWM proxy p95 within one nominal refresh interval reported by
  the menu's display;
- resident host idle CPU at or below 0.05% of total machine capacity;
- no change to Explorer's process-wide read/write I/O counters during every
  warm open.

The frame comparison uses the actual menu monitor's current-mode **nominal**
integer refresh rate. It does not measure variable-refresh scheduling or prove
which composed frame reached the display. Likewise, observer-process `DwmFlush`
is pacing/observation evidence, not a presentation timestamp, and Explorer CPU,
memory, and I/O counters are process-wide rather than A4S-attributed. Treat all
four as screening proxies until the required compositor, stack, and File I/O
traces are attached.

The report includes p50, p95, and maximum timings, every raw sample, exact
binary paths/build identities, host and Explorer IDs/start times/logon identity, same-process memory deltas, and
process-wide I/O-counter deltas. The JSON
evidence is flushed to a new file before an enforced target failure is raised;
existing qualification evidence is never overwritten.

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

## Product runtime trace

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

The product includes the A4S-only `A4SMenu.Runtime` TraceLogging provider,
which is dormant when no trace session listens. It emits correlated operation
events for activation source, open/close paths, pinned and Programs
enumeration, icon load/cache result, backdrop preparation, visibility, first
paint, search initialization, preload, hiding, and repaint rectangles. Capture
30 exact-build cycles with the custom-provider tool after the external run:

```powershell
.\tools\Capture-A4SRuntimeTrace.ps1 `
    -AllowMenuAutomation `
    -ProductDirectory $productDirectory `
    -CapturedCycles 30 `
    -WarmupCycles 1 `
    -RefreshRateHz 239 `
    -EnforceTargets
```

`239` is the qualification machine's current configured rate; recheck it if
the display mode changes. For automated traces the supplied value is only a
cross-check: every warm-up and captured cycle must record a valid nonzero
current-mode integer from `EnumDisplaySettings` for that cycle's actual visible
menu monitor. The recorded count must equal the attempted-cycle count, and the
actual observed rate drives target math. Missing or mixed-rate evidence is
rejected; operator input cannot replace it. The report uses the unrounded
`1000 / refresh-rate` budget (4.184100... ms at 239 Hz), while displaying
rounded values for readability.

The capture validates the staged paths and SHA-256 hashes, the resident and
file PE/RSDS identities, Explorer/host PIDs and start times, numeric session,
token logon identity, disabled StartAllBack state, exact requested cycle count,
and end-of-run identity. It preserves the raw ETL, decoded-XML hash, report,
per-cycle monitor-rate evidence, session logs, and capture metadata in a new
directory. The parser rejects
mixed-process, duplicated, incomplete, and under-sampled traces.

Custom markers authoritatively measure application activation-to-visible,
activation-to-first-paint, close-to-hidden, cache/phase durations, and repaint
area. `windowVisible`, `firstPaint`, and `windowHidden` remain application
markers rather than compositor presentation timestamps. The custom provider
also does not capture kernel file-I/O. Therefore exact presented-frame and
physical-disk claims remain `notMeasured`; a WPR/ETW presentation plus
File I/O/stack capture is still required for those two claims. The external
report's Explorer CPU and I/O values remain process-wide correlation.

The capture session starts only after the host is already `READY`; this safety
boundary means an initial idle preload may have completed before the provider
is enabled. Repeat-open cache-hit evidence remains available, but proof of the
first post-injection preload requires a separately pre-armed ETW/WPR session or
another startup record that begins before the host is launched.

Open/close cycles do not exercise lazy search or the Programs view. Capture
those phase markers separately, without target enforcement:

```powershell
.\tools\Capture-A4SRuntimeTrace.ps1 `
    -AllowMenuAutomation `
    -ProductDirectory $productDirectory `
    -CapturedCycles 0 `
    -WarmupCycles 0 `
    -ManualInteractionSeconds 45 `
    -RefreshRateHz 239
```

During the announced window, open All Programs, wait for it to populate,
return to the normal view, type a non-empty search query, and let results
settle, then close the menu before the window ends. The tool does not toggle a
user-opened menu in manual-only mode. This trace is phase evidence only: its overall target status cannot be
`pass`, and `-EnforceTargets` is deliberately rejected in manual mode.

## Record the stability matrix

The scenario tool records the current environment and can optionally verify an
open/close cycle without changing that environment:

```powershell
.\tools\Test-A4SCurrentScenario.ps1 `
    -ScenarioName dpi-125-centered `
    -ProductDirectory $productDirectory `
    -ExpectedMonitorCount 1 `
    -ExpectedPrimaryScalePercent 125 `
    -ExpectedTaskbarAlignment center `
    -ExpectedTaskbarEdge bottom `
    -AllowDisabledStartAllBackModules `
    -AllowMenuAutomation
```

`-AllowDisabledStartAllBackModules` is an explicit qualification exception for
machines where StartAllBack remains installed. It accepts only
`StartAllBackLoaderX64.dll` and `StartAllBackX64.dll` from
`%ProgramFiles%\StartAllBack` while
`HKCU\Software\StartIsBack\Disabled` is a `REG_DWORD` equal to `1`. Their
paths, lengths, and SHA-256 hashes are recorded and must remain unchanged for
the whole scenario. Without the switch—or for any active, unknown, relocated,
or changing competing module—the scenario still fails.

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

Automation defaults to the staged product directory. Pass `-ProductDirectory`
for an installed slot. An automated scenario will not pass unless the selected
host/DLL paths, SHA-256 hashes, on-disk PE/RSDS identities, resident PE/RSDS
identities, PIDs, start times, numeric session, and token logon ID remain exact
for the whole cycle. Geometry is sampled under per-monitor-v2 thread awareness,
so recorded menu/monitor rectangles are physical pixels at every tested scale.

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
Use a unique `-ScenarioName` and optional `-Notes` for every run. Duplicate
names are rejected. A path-derived mutex serializes writers and same-volume
write-through replacement keeps the aggregate JSON intact. If automation
fails after the environment snapshot, the failed entry and error are persisted
before the script returns failure. The separate shared automation mutex keeps
scenario menu actions from overlapping a performance or trace run.

The required matrix is:

| Area | Required scenarios | Evidence |
| --- | --- | --- |
| DPI | 100%, 125%, 150%, 200% | environment assertions, menu DPI/rect, visual capture |
| Taskbar | centered and left aligned; bottom required, other edges if supported | alignment/edge assertion, open/close |
| Monitors | one monitor, two monitors, mixed DPI, opening from each taskbar | topology snapshot, menu monitor/rect |
| Input | lone Win open/close; Win+R/E/L/X/Tab unaffected; Start click same path | manual physical-key/Start-click checklist plus activation marker/source and visible-window evidence; no synthesized input |
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
.\tools\Test-A4SRuntimeTraceTools.ps1
```

The gates parse every performance/stability/trace script, compile freshly renamed copies
of each embedded native helper, verify `RECT`, `IO_COUNTERS`,
`MONITORINFOEX`, and `DEVMODE` byte sizes, check explicit automation gates and
Explorer-owner filtering, reject a curated list of destructive commands and
native APIs, exercise synthetic trace correlation (including the exact 239 Hz
boundary), and smoke-test only the read-only environment snapshot. The
denylist is defense in depth rather than proof about arbitrary future code; a
human review remains required. The gate does not open the menu or alter
Explorer.

For a parser-only run that must not inspect the current desktop or staged
binaries, use `Test-A4SPerformanceTools.ps1 -SkipObservationSmokeTest` and
`Test-A4SRuntimeTraceTools.ps1 -SkipStagedBinaryIdentitySmokeTest`.

## Current qualification status

An exact-build, real-desktop Step 3 run now exists. Use the
[2026-09-01 live record](A4S-plan2-step3-live-2026-09-01.md), not the earlier
ignored `A4S-*unoptimized*` intermediate evidence, for the current baseline.
The recorded Host/DLL SHA-256 prefixes are `8DD438DB` / `FF66AA07`, and the
canonical cross-trace analysis is
`07-analysis/step3-correlated-etw-v4.json` (SHA-256
`8D404B4CAAD6A4206DAF5703B744780E544B6D14B6E37B44A4FC60D8BE8E0B00`).

That run now supplies:

- a clean same-Explorer resource baseline and +3,842,048-byte private-memory
  delta;
- one operator-attested cold opening and 30 warm external samples;
- 30 complete standalone custom-provider cycles and 30 more under WPR load;
- pinned, icon, backdrop, Programs, and first-input search scopes;
- a 15.359748-second passive-idle CPU trace;
- a sampled pop-in image pair plus numerical pixel comparison; and
- concurrent CPU, File I/O, registry, DWM, DirectComposition, DxgKrnl, DXGI,
  Win32k, and RPC data correlated by raw same-boot QPC.

The warm <=50 ms gate passes. Step 3 deliberately leaves these claims open:

- exact physical first-presented and last-removed frame; the application close
  p95 is within the nominal frame, while the external proxy is not;
- a strict physical warm-disk guarantee; three first-cycle reads were observed
  and physical candidates do not have joined attribution stacks;
- the opening-path registry/COM gate; 900/900 registry events have joined A4S
  stacks and no COM provider was captured;
- proof of the initial idle preload, full search-results/Programs settlement,
  and changed-rectangle-only repainting; and
- all remaining monitor, DPI, fullscreen, Explorer/session, installer,
  rollback, uninstall, and crash-loop scenarios.

Installer and recovery execution are specified separately in the
[current-profile lifecycle](A4S-current-profile-installer-lifecycle.md) and
[failure-recovery plan](A4S-failure-recovery.md). The presence of those tools
does not change any pending status above.
