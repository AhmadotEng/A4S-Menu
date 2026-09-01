# A4S Plan 2 Step 3 live performance record — 2026-09-01

## Result

Plan 2 Step 3 produced a real-desktop, exact-build performance baseline before
any further optimization work. The warm-open target passes in standalone and
WPR-load measurements. The trace also identifies opening-path registry work
that must be addressed in Step 4. It does **not** establish the exact physical
first/last displayed frame, and it does not contain a COM provider capable of
closing the shell-COM part of P8. Those two limits remain explicit release
gaps rather than inferred passes.

No Windows Sandbox, VM, synthetic input, or simulated Explorer was used. No
product code was changed during the qualifying run.

## Exact qualification boundary

- Evidence root (ignored build output):
  `build/test-results/A4S-step3-20260901T140153Z-src-34b0939-h8DD438DB-dFF66AA07`
- Accepted product source checkpoint: `34b0939`
- Repository HEAD recorded at run creation:
  `2a19eef760f8986eff8772adc901aad16f7a5e37`
- `A4SMenuHost.exe`: 207,872 bytes; SHA-256
  `8DD438DB3FF591CA14388431BD82F08854E87075E6C4E960654DA48FF9B97876`
- `A4SMenu.dll`: 1,356,800 bytes; SHA-256
  `FF66AA070F158D3C1C0732EE195CC88C06BA6034AD691BB969D4B30BEA37ED0A`
- Explorer PID/start UTC: `10408` / `2026-09-01T14:26:34.7373141Z`
- Resident host PID/start UTC: `23844` / `2026-09-01T14:27:01.8004404Z`
- Qualification machine: `DESKTOP-SB7BBDQ`, Windows build `22621`, one
  1920x1080 display at 239 Hz, 100% scale, centered bottom taskbar.
- Clean pre-injection baseline:
  `02-clean-pre-injection/baseline.json`, SHA-256
  `83C63CEEB8558DB205CA768DD46D13726F5DB176A9861673539E37C5214D9F36`.

`Disabled=1` did not keep the installed StartAllBack modules out of Explorer,
so the two exact x64 DLLs were reversibly renamed for the qualifying Explorer
lifetime. Their registrations were restored after an unsuccessful protected
registry-isolation attempt, and no StartAllBack file was deleted or modified.
After all captures stopped, both files were restored under their original
names and their hashes were verified. Explorer then dynamically mapped the
restored loader, so that post-capture process is outside this qualification
boundary. The custody and restoration record is
`06-wpr-presentation-io/capture-context.json`, SHA-256
`CC0400AAD81713B6ABA0165756D4F33483290742BFA2B20D8FC83637B4A8F13A`.

## Measurements

### External real-window proxy

`03-external-timing/performance.json` (SHA-256
`186764867952B3EDF20375311821956C92755BFD2DCE97AC26C0819945520A37`)
contains one operator-attested cold open, 30 warm cycles, and a 15-second idle
interval. `IsWindowVisible` and observer-process `DwmFlush` are deliberately
reported as proxies, not physical presentation timestamps.

| Measurement | Result |
| --- | ---: |
| Cold command to visible observation | 50.9119 ms |
| Cold command through observer `DwmFlush` | 61.6071 ms |
| Warm command to visible, p50 / p95 | 11.123 / 26.273 ms |
| Warm command through observer `DwmFlush`, p50 / p95 / max | 29.540 / 37.938 / 38.618 ms |
| Close to hidden observation, p95 | 14.147 ms |
| Close through observer `DwmFlush`, p50 / p95 / max | 4.084 / 16.780 / 20.637 ms |
| Resident-host idle CPU | 0.000000% |
| Whole-Explorer idle CPU | 0.005206% |
| Explorer private-byte delta from the clean same-process baseline | +3,842,048 bytes |
| Explorer working-set delta | +5,267,456 bytes |
| Explorer handle / thread delta | +48 / -2 |

The warm <=50 ms proxy target passes. The external close proxy does not meet a
4.1841 ms nominal 239 Hz frame. Twenty-nine of 30 warm openings left
Explorer's read/write counters unchanged. Those counters are process-wide
screening evidence and are not a physical-I/O attribution.

### Standalone A4S provider trace

The valid repeated-toggle trace is
`04-runtime-toggle-trace/capture-02/A4SMenu.Runtime.json`, SHA-256
`AA41787CF43DF9EA0AAFFCC38EE1551DDA4DA092454B723A93A0054A8A605A24`.
Its raw ETL is SHA-256
`8C208070E23AFB7C8129B884B418AD5F9EBD23A5EE79EF13A84F30E7C597D74C`.
It contains 30 complete warm cycles and zero diagnostics.

| A4S application marker | p50 | p95 | max |
| --- | ---: | ---: | ---: |
| Activation requested to window visible | 13.644 ms | 15.541 ms | 16.770 ms |
| Activation requested to window hidden | 2.555 ms | 3.508 ms | 5.503 ms |
| Open path | 8.732 ms | 10.194 ms | 10.504 ms |
| Close path | 2.558 ms | 3.508 ms | 5.502 ms |
| Backdrop preparation | 0.015 ms | 0.160 ms | 0.184 ms |
| Pinned enumeration | 0.027 ms | 0.048 ms | 0.065 ms |

All 30 repeated pinned-enumeration operations reported `cacheHit=true`. This
supports reuse after `READY`; it does not reconstruct the earlier preload.

At the application-marker boundary, warm open passes 50 ms and close p95 is
below the nominal 4.1841 ms frame. `windowVisible`, `firstPaint`, and
`windowHidden` are still application events, not proof of a physically
presented or removed frame.

The earlier `04-runtime-toggle-trace/capture-01` is an **invalid conversion
attempt**. `tracerpt` failed because of the original long-path handling, so its
raw ETL (SHA-256
`04F2B9B4F4D22B614F3D2C4BABBFA64D03047D50BFB2F99961677C64C7D6C69C`)
is retained only as failed-attempt evidence. It must not be used for metrics;
all standalone toggle results above come from `capture-02`.

### Programs, icons, and first-input search

The owner physically opened All Programs, returned to the normal view, typed
`steam`, and closed the menu during the manual trace. The report is
`05-runtime-programs-search/capture-01/A4SMenu.Runtime.json`, SHA-256
`210CE96D55BFB02FE12DD589E1727E911DA703DEA42440B51B000B9BEC3643D4`;
its raw ETL is SHA-256
`38FB7BE15A325CD58CF0B538B2BFAC78564262471D52FCE69C7D0B1EC950CF05`.

- Pinned enumeration: 10.365 ms (one operation).
- Icon load: 31 operations; p50 0.133 ms, p95 3.523 ms, max 4.054 ms.
- Programs enumeration: two operations; p50 1.214 ms, p95/max 3.987 ms.
- Search initialization: 0.0936 ms (one operation after input).
- The single manually driven open reached `windowVisible` in 23.826 ms.
- One 3.5231 ms icon load began approximately 8.57 seconds after
  `windowHidden`; Step 4 should treat that as possible uncancelled late work.

This establishes the recorded phase costs. It does not add a marker for the
first search keystroke, first result, or results-settled state, and it does not
prove the complete asynchronous Programs population latency.

### Concurrent WPR/custom correlation

The WPR capture used `CPU.Verbose`, `FileIO.Verbose`, `Registry.Verbose`,
`DesktopComposition.Verbose`, and `GPU.Verbose` in file mode. The system ETL is
`06-wpr-presentation-io/capture-01/A4SMenu.System.etl`, 492,409,545 bytes,
SHA-256
`2C47DEA7AA409626396D01E62C7D3556843CA5AE779E29BD5C8F9BB3063CBCC1`.
The concurrent custom ETL is SHA-256
`6DE4C1C936907DE278C8C3CF347718964A3A601BB15828718DFE25D960F76DDC`.

The canonical cross-trace analysis is
`07-analysis/step3-correlated-etw-v4.json`, SHA-256
`8D404B4CAAD6A4206DAF5703B744780E544B6D14B6E37B44A4FC60D8BE8E0B00`.
It correlates concurrent, same-boot ETLs by raw `TimeStampQPC` and contains 30
complete cycles with zero custom-provider diagnostics.

- Under WPR load, activation-to-visible p50/p95/max was
  16.3295/23.8565/25.3858 ms; close activation-to-hidden p50/p95/max was
  2.2341/3.6494/4.3669 ms.
- The 30 opening intervals contain 900 Explorer registry events: 360 opens,
  240 closes, 150 queries, and 150 value queries. Every one of the 900 events
  has a joined stack containing `A4SMenu.dll`. P8 therefore does not pass.
- The first opening contains three logical reads totaling 32,768 bytes from compressed
  `oleacc.dll`/`gdi32full.dll` data. All three logical reads have joined stacks,
  but none of those stacks contains an A4S frame. Matching target-PID disk and
  hard-fault candidates exist without joined stacks. The remaining 29 opening
  intervals are logically quiet. This does not meet a strict 30/30 quiet rule,
  and it is insufficient to claim that the physical warm path is disk-free.
- The interval contains presentation-provider activity from DWM,
  DirectComposition, DxgKrnl, DXGI, and Win32k, but the analysis intentionally
  does not label any event as the exact physically displayed A4S frame.
- Two target-PID RPC events were inventoried. A COM provider was not captured,
  so an individual shell-COM discovery call cannot be accepted or excluded.

The separate 15.359748-second passive-idle CPU ETL is
`06-wpr-presentation-io/idle-capture-01/A4SMenu.IdleCpu.etl`, SHA-256
`4BED6B617EEE7A24A1AA9B7C98D25C405A033771A81552BC475937B895316ECB`.
There were 31 Explorer CPU samples; 29 had joined stacks and zero of those 29
contained `A4SMenu.dll`. The 12,135 explicit lost-event notifications in that
ETL all identify `DefenderApiLogger`, not an A4S-prefixed session; the reader's
session-level `EventsLost` value is zero. The active system trace's 8,852
explicit notifications have the same unrelated `DefenderApiLogger`
qualification and also report reader `EventsLost=0`. This is scoped support
for effectively zero A4S idle CPU, not a claim that unrelated Explorer work
stopped.

### Pop-in and repaint evidence

The two 463x443 captures have different PNG hashes. The numerical comparison
in `07-analysis/pop-in-pixel-diff.json` (SHA-256
`DA74BF7302BAD6F8BDA3EEEE2D0D52FECDF1CB841A0036EC71C12AE7B2BBE80A`)
finds a maximum channel difference of 6, no pixel with mean-channel difference
above 10, and only four pixels above 3. Changes are confined to the right-side
bounding box and are visually consistent with the live acrylic/backdrop. No
icon or text pop-in is visible in this sampled pair, but the first capture
occurs after observer-process `DwmFlush` and can miss a shorter transient.

The standalone trace recorded 60 paint rectangles; p95 and maximum were the
full 205,109-pixel menu area. The visual pop-in observation is therefore useful,
but the stricter "only changed rectangles" portion of P11 is not yet proven.

## Timestamp and trace interpretation rule

On this machine, `tracerpt.exe` serialized the Dubai offset as `+03:59` even
though Windows reports `+04:00`. Its decoded UTC event timestamps are exactly
60 seconds late. Durations within one decoded trace remain valid. Cross-trace
correlation must use raw, same-boot `TimeStampQPC`; decoded wall-clock UTC must
not be used to join custom and system ETLs. The canonical v4 analysis follows
that rule.

## Offline reproducibility

`tools/Build-A4SStep3Correlator.ps1` builds the offline reader from the locally
installed TraceEvent 3.1.9 assemblies. The reader takes the concurrent custom
ETL, system ETL, a create-new output path, Explorer PID `10408`, the idle ETL,
and expected cycle count `30`. It does not launch, inject, toggle, or otherwise
touch the product.

The final source hashes are:

- correlator source:
  `1CC222D012E309160F58F966C496D9C0960748DA38CCD4045865C29E5FC994A0`;
- build script:
  `63B58F2656A28FC3B7A994B57F320831D353E6B41517118CFC6CCD334FF1C711`;
- built analyzer:
  `D826B4875009EC3E4D8EEAF4830BC020F596B2451830DB6544460D63BF0502CD`.

A second create-new conversion produced a byte-identical v4 report with the
same SHA-256, and the overwrite-refusal check left the canonical report
unchanged.

## Requirement disposition after Step 3

| ID | Exact-build disposition |
| --- | --- |
| P1 | Measured: cold external proxy and 30 warm external/application-marker cycles. |
| P2 | **PASS** on this machine: every reported warm p95 is <=50 ms, including WPR load. |
| P3 | **Open**: application close p95 passes one nominal frame, external proxy fails, and exact compositor removal is not measured. |
| P4 | **PASS within the recorded idle interval**: host 0%; 0/29 joined Explorer samples contain A4S. |
| P5 | **Open**: 29/30 logical intervals are quiet; first-cycle reads and incomplete physical attribution prevent the strict claim. |
| P6 | Measured: +3,842,048 Explorer private bytes in the same process. |
| P7 | Measured for the emitted pinned/icon/backdrop/Programs/search scopes. |
| P8 | **Not passed**: 900/900 registry events are A4S-stack attributed; COM was not captured; filesystem proof is incomplete. |
| P9 | Partial repeat-open cache evidence only; the initial idle preload was not pre-armed/captured. |
| P10 | Partial manual evidence; explicit first-input/result-settled and Programs-visible-settled markers remain absent. |
| P11 | No visible sampled icon/text pop-in; changed-rectangle bounding remains unproven because p95 paint area is the full menu. |

Step 3 is complete as a measurement/instrumentation baseline. It does not make
P3, P5, P8, P9, P10, or the repaint portion of P11 release passes. Step 4 must
use these results rather than replacing them with inferred or simulated data.
