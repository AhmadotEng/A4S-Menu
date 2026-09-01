# Plan 2 Step 1 live interaction record — 2026-09-01

## Scope and result

Plan 2 Step 1, unified native toggling, is complete for the current
qualification machine and keyboard. This record covers interaction behavior;
the measured `<= 50 ms` warm-open target remains Plan 2 Step 3 work.

The owner changed the product policy before this test: while A4S is installed,
running, and `READY`, A4S owns Start activation and Windows' native Start menu
must not appear. The accepted implementation contains no low-level keyboard
hook, does not synthesize input, and does not suppress physical key-up events.

Tested source checkpoint: `34b0939` (`Update product boundary for native Start
route`). Native-Start ownership was introduced by `a85af78`; the rollback point
immediately before that ownership change is `f1dca8c`.

## Exact staged binaries

| Binary | Bytes | SHA-256 |
| --- | ---: | --- |
| `build\stage\A4SProduct\A4SMenuHost.exe` | 207872 | `8DD438DB3FF591CA14388431BD82F08854E87075E6C4E960654DA48FF9B97876` |
| `build\stage\A4SProduct\A4SMenu.dll` | 1356800 | `FF66AA070F158D3C1C0732EE195CC88C06BA6034AD691BB969D4B30BEA37ED0A` |
| `build\stage\A4SSetup\A4SMenuSetup.exe` | 1902080 | `11A8B530F34E3CA4010A069AF06C44C4687C124D3FBA80BB67F9B3CFBC1B7E76` |

The live check used Explorer PID `23736` and the single resident host PID
`22656`. `A4SMenuHost.exe --status` returned `0`, the exact staged DLL was
mapped in Explorer, and both `VK_LWIN` and `VK_RWIN` reported released before
physical testing.

## Owner-operated interaction matrix

The owner performed the physical actions and confirmed the listed result in
the live desktop session.

| Interaction | Result |
| --- | --- |
| Tap left Windows key once | PASS — A4S opened; native Start did not appear |
| Tap left Windows key a second time | PASS — A4S closed |
| Hold left Windows key for one second, then release | PASS — one opening on release, without repeat flicker or a stuck modifier |
| Right Windows key | NOT APPLICABLE — the physical keyboard has no right Windows key |
| Click centered Start button twice | PASS — same open/close toggle behavior |
| Click left-aligned Start button twice | PASS — same open/close toggle behavior and correct left placement |
| Left Windows key with left-aligned taskbar | PASS — open/close toggle behavior |
| `Win+R` | PASS — Run opened; neither Start menu appeared |
| `Win+E` | PASS — File Explorer opened |
| `Win+I` | PASS — Settings opened |
| `Win+X` | PASS — Quick Link menu opened |
| `Win+Tab` | PASS — Task View opened |
| `Win+D` | PASS — desktop show/restore behavior remained native |
| `Win+1` | PASS — taskbar application activation remained native |
| `Win+S` | PASS — Windows Search opened |
| `Win+Shift+S` | PASS — screenshot overlay opened |
| `Ctrl+Esc` twice | PASS — A4S opened and closed |
| `Win+L` | PASS — Windows locked; the host remained healthy after unlock |
| Activate another application while A4S is open | PASS — A4S dismissed and focus moved normally |

After the shortcut and lock sequence, the host still returned healthy status,
exactly one resident host existed, and both Windows-key states were released.
The centered and left-aligned taskbar interaction checks both passed. The
right-key row is explicitly not claimed because that physical key is absent.

## Supporting nonphysical checks

Before the physical test, the acknowledged native-Start takeover transaction
reached `READY_WITH_NATIVE_START_TAKEOVER`. Posting the shell's
`WM_SYSCOMMAND/SC_TASKLIST` route to the validated Explorer `Progman` thread
opened A4S in the observed check and a second post closed it. The native
`StartMenuExperienceHost` had zero visible, uncloaked windows before, during,
and after that cycle. The lifecycle/static validation and full A4S product
build suite passed for this staged pair.

## Explicitly deferred

- Warm input-to-first-visible-frame latency, including the `<= 50 ms` target,
  is Plan 2 Step 3 and was not inferred from visual response.
- Exact mathematical screen-centering of the popup is recorded in
  [A4S deferred refinements](../architecture/A4S-deferred-refinements.md).
- Broader DPI, monitor, fullscreen, and lifecycle qualification remains in its
  later numbered Plan 2 steps. It is not part of this Step 1 completion claim.

## Non-product window observation

The dark rectangle seen after `Win+D`/alignment/focus testing was independently
identified as a minimized Visual Studio Code/Electron GPU surface: Code.exe
PID `18436`, top-level class `Chrome_WidgetWin_1`, not an Explorer-owned
`A4SMenu.*` window. A4S creates no separate full-screen backdrop window. The
VS Code window was safely minimized; no A4S source change was made for it.
