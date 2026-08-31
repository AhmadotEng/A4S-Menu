# A4S custom runtime trace

`Capture-A4SRuntimeTrace.ps1` records the manifest-free `A4SMenu.Runtime`
TraceLogging provider that is built into the A4S product DLL.

Use this reference with the
[performance/stability qualification procedure](A4S-second-half-performance-and-stability.md)
and [second-half requirement ledger](../architecture/A4S-second-half-requirements.md).

- Provider: `A4SMenu.Runtime`
- GUID: `74a9f986-c7ab-429a-9571-df0fb7f4a33c`
- Windows dependencies: 64-bit PowerShell, `logman.exe`, and `tracerpt.exe`
- Network dependencies: none

The capture tool does **not** start the host, inject a DLL, rehook or restart
Explorer. It refuses to run unless all of these preconditions are already true:

1. `-AllowMenuAutomation` was explicitly supplied.
2. the resident `A4SMenuHost.exe` owns the expected product control window and
   reports `READY` through `A4SMenu.Host.Control.v1`;
3. the resident host executable path is exactly the selected product path;
4. taskbar Explorer, the host, and the observer share the same numeric session
   and token logon identity;
5. StartAllBack is either unconfigured/not installed or its `Disabled` value
   is exactly `1` (the value is checked again after capture);
6. Explorer has exactly one `A4SMenu.dll` mapping and its path is exactly the
   selected DLL path;
7. the RSDS build GUID/age plus PE timestamp and image size read from each
   resident process image exactly match the corresponding selected file (a path
   match alone is deliberately insufficient because Windows can retain an old
   mapped image after that path is replaced);
8. the selected host and DLL hashes remain stable across preflight and capture;
   and
9. no A4S menu window is visible before the run.

Each measured opening must create exactly one visible
`A4SMenu.CMenuContainer` owned by that validated Explorer process. Toggle
requests use the product's existing host control message. The tool never runs a
second host executable as a command client. Recovery cleanup revalidates the
same host window, host process start time, taskbar Explorer process start time,
and `READY` state, and examines only menu windows owned by that validated
Explorer PID. It never toggles because a same-class window exists in some other
process.

The strong resident-image check requires the product's normal RSDS CodeView
record. If a future product build intentionally strips that identity, the trace
tool fails closed; add an equally strong immutable build identifier before
relaxing this precondition.

## Static/self-test (safe with no injected product)

This is the first command to run after changing the scripts:

```powershell
& .\tools\Test-A4SRuntimeTraceTools.ps1
```

It performs no live ETW capture and never starts the product. It checks the
PowerShell syntax and safety gate, compiles the embedded Win32 interop helper,
validates the PE/RSDS identity of staged binaries when they are present, feeds
synthetic events through the JSON and tracerpt-XML parsers, verifies strict
cycle/phase correlation and percentile results, and proves that truncated,
mixed-process, ambiguous, or incomplete input cannot pass.
Use `-SkipStagedBinaryIdentitySmokeTest` for a strictly parser/synthetic run
that must not inspect staged binaries.

## Live capture

Build and start the exact staged host through the normal product lifecycle
procedure first. Confirm that it is `READY`, close the menu, and then run:

```powershell
& .\tools\Capture-A4SRuntimeTrace.ps1 `
    -AllowMenuAutomation `
    -ProductDirectory .\build\stage\A4SProduct `
    -CapturedCycles 20
```

For an installed build, do not pass `%LocalAppData%\A4SMenu` itself. Resolve
the immutable registered slot and use it as the exact product directory:

```powershell
$productDirectory = .\tools\Resolve-A4SInstalledProductDirectory.ps1
& .\tools\Capture-A4SRuntimeTrace.ps1 `
    -AllowMenuAutomation `
    -ProductDirectory $productDirectory `
    -CapturedCycles 20
```

An installed-slot run fails if the selected directory is not or ceases to be
the registry `ActiveSlot`.

The default single warm-up cycle happens before ETW starts, so every captured
sample is classified as warm. To record an operator-qualified cold first
sample, do not warm up and provide the explicit attestation:

```powershell
& .\tools\Capture-A4SRuntimeTrace.ps1 `
    -AllowMenuAutomation `
    -WarmupCycles 0 `
    -OperatorAttestsFirstCapturedCycleIsCold `
    -CapturedCycles 21
```

The tool creates a unique ETW session name and a new output directory. It uses
the provider in real-time mode while simultaneously writing a sequential ETL
file. Once session creation is attempted, an unconditional stop is issued from
a `finally` block, including failed or partial starts. A successful start whose
stop fails is a terminal error; after a failed start, the tool also queries a
failed stop to detect a residual named session. If Windows denies ETW session
creation, run the same command from an elevated 64-bit PowerShell; do not weaken
the product preflight.

Artifacts in the unique directory include:

- `A4SMenu.Runtime.etl`: immutable raw evidence (never deleted or overwritten);
- `A4SMenu.Runtime.tracerpt.xml`: Windows-decoded provider events;
- `A4SMenu.Runtime.json`: correlated events, operations, cycles, statistics,
  diagnostics, selected binary hashes/registration, and target evaluation;
- `session-start.txt` and `session-stop.txt`: `logman` results.

The JSON records activation source, open begin/end, visible, first paint, close
begin/end, hidden, and all phase scopes emitted by the DLL. It reports p50,
p95, maximum, and mean durations. A trace is incomplete when a begin has no
end, an end has no begin, a duplicate begin occurs, or an opening cycle lacks
one of its required markers. It also fails completeness for a missing whole
cycle, duplicate cycle marker, mixed/zero process identity, zero phase
operation, or phase that changes threads. The live capture always supplies the
requested cycle count to the converter, so total ETW loss of one cycle cannot
silently reduce the denominator.

The custom-trace target evaluation covers:

- warm `activationRequested` to `windowVisible` p95 at or below 50 ms by
  default;
- the closing `activationRequested` to `windowHidden` p95 within one nominal
  display frame (the report also retains the narrower `closePath` duration);
- exactly the requested number of captured cycles;
- at least 20 complete warm samples and 20 complete close samples by default;
- zero incomplete-operation/cycle diagnostics.

Use `-EnforceTargets` when a non-passing custom trace should make the command
fail after preserving its ETL and writing the report.

Programs enumeration and first-input search initialization require a separate
manual phase trace; they are not exercised by repeated open/close cycles:

```powershell
& .\tools\Capture-A4SRuntimeTrace.ps1 `
    -AllowMenuAutomation `
    -ProductDirectory $productDirectory `
    -CapturedCycles 0 `
    -WarmupCycles 0 `
    -ManualInteractionSeconds 45
```

Automated cycles and a manual interaction window are mutually exclusive, and
manual phase traces deliberately cannot use `-EnforceTargets`.

## Offline conversion

An existing ETL can be decoded again without running or touching the product:

```powershell
& .\tools\Convert-A4SRuntimeTrace.ps1 `
    -EtlPath .\build\test-results\A4S-runtime-trace-...\A4SMenu.Runtime.etl `
    -ExpectedProcessId 1234 `
    -ExpectedCycleCount 20 `
    -RefreshRateHz 239
```

`-Force` permits atomically replacing only derived XML/JSON files. The raw ETL
is never modified. `-EventJsonPath` exists for deterministic synthetic/offline tests.
Offline `-EnforceTargets` cannot pass without an explicit
`-ExpectedCycleCount`; this prevents a truncated ETL from validating itself.
The 20-sample minimums can be raised, but lowering them weakens the evidence and
must be recorded with the result.

## Interpretation limits and follow-up evidence

`firstPaint` is an application paint marker. `windowVisible` records the menu's
visibility path. Neither proves when the compositor presented the pixels on a
physical display. The capture tool calls `DwmFlush` only to pace test cycles;
it does not reinterpret that call as a presented-frame timestamp. Use Windows
Performance Recorder/Analyzer with DWM/GPU presentation providers when the
one-frame claim needs physical presentation evidence.

The custom provider also does not observe physical file I/O. It can time icon,
pinned-item, Programs, search, backdrop, and preload scopes, but a zero-disk-I/O
claim requires a WPR/WPA follow-up with File I/O activity enabled and filtering
to the measured Explorer PID and interval. Preserve that ETL beside this custom
trace and state the WPR profile and Windows build in the test record.

Because this guarded tool creates its ETW session only after the host reports
`READY`, the initial idle preload may already be over. A startup-preload claim
needs a separately pre-armed ETW/WPR session before launching the host; a later
repeat-open trace can prove cache use but cannot reconstruct a missed preload.

Synthetic self-test success validates correlation and the expected tracerpt
XML shape; it is not a substitute for decoding at least one real ETL on the
target Windows build.
