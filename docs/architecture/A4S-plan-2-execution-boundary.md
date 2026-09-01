# A4S Plan 2 execution boundary and audit

## Authority and purpose

This is the sole retained record of the abandoned Windows Sandbox path. It is
also the execution boundary for Plan 2. Before changing or testing Plan 2,
read this file and the user's authoritative plan attachment:

- path: `C:\Users\Admin\.codex\attachments\67d61361-eb5f-4479-8443-67dc44366a67\pasted-text.txt`
- SHA-256: `138B8B1C22971D24B074933C88ADBBCD8010FBACED9A776AAE48D0AB04F6F788`

The attachment overrides summaries and inferred plans. Windows Sandbox,
`WDAGUtilityAccount`, `.wsb` launchers, `A4SLegacySandbox*` runners, frozen-V1
fixtures made for that runner, and `LegacySandboxEvidence` are out of scope and
have been removed. Do not replace that path with a VM, container, disposable
profile, or another testing environment unless the user explicitly amends the
plan first. A pending test remains pending.

## Exact boundary between Plan 1 and Plan 2

The accepted Plan 1 source checkpoint is:

- `42d61a4844f08f3a86752f41f54dac1b977987e4` — `A4SMenu: complete isolated first-half product`
- parent accepted UI baseline: `edc8bf0fc31f1dc302701716717a5284f13dadff`

The first unmistakable Plan 2 commit is the very next commit:

- `a4ecf47224ad1eec9215bc4ef805296049735b25` — `docs: define second-half release gates`

There is no commit between those two points.

The first-half automated build/static/lifecycle record was produced before the
user's manual staged-host test. It recorded Explorer PID 1660, host PID 15780,
READY state, exact DLL mapping, toggle open/close, logical exit, closed host and
menu, and a mapped but inert DLL. After the user's successful manual invocation
below, there is no durable evidence of another build or validation run before
Plan 2 began. Only final documentation/checkpoint work is durably evidenced.
Do not claim that an unrecorded test occurred.

The exact accepted launcher block must remain byte-for-byte unchanged in the
README and performance document:

```powershell
$menuHost = 'C:\Users\Admin\Downloads\StartAllBack-analysis-handoff\Open-Shell-Menu\build\stage\A4SProduct\A4SMenuHost.exe'

Start-Process -FilePath $menuHost
Start-Sleep -Seconds 2
& $menuHost --status
```

The exact accepted Plan 1 binaries are preserved locally, outside Git, at:

`build\stage\.A4SProduct.backup.cc5ee9cf0c0143a0b105df8f9647b5fc`

| Binary | Bytes | SHA-256 |
| --- | ---: | --- |
| `A4SMenuHost.exe` | 201216 | `C422731706DDB801457C5A4367CB57BC05DCE7A1987334B5775DD2835B27996B` |
| `A4SMenu.dll` | 1532416 | `CC4F0914BD7B0CC1836D4FB8EA5585D766A1365714AD0C81254551A14F0FB80B` |

The backup directory must not be deleted. Source rollback alone does not
reproduce those exact non-deterministic binary bytes.

## Authoritative Plan 2 and current audit

The status terms below are literal: **implemented** is not **live qualified**,
and **pending** means no passing claim exists yet.

### 1. Implement unified native toggling

Required: one DLL dispatcher for the left/right Windows key, Start button, and
external command; toggle only after a lone Windows-key release; preserve key
repeat and Win+R/E/L/X/Tab/D/number behavior; normal focus loss. The owner
explicitly superseded the earlier fallback requirement on 2026-09-01: after
A4S reaches `READY`, native Start must remain disabled for the installed
product. Clean servicing/uninstall may restore the exact registrations before
Explorer replacement.

Status: implemented and source/offline tested, but not live qualified. Principal
commits are `af76b87`, `04b2d6f`, `3d1a1e4`, `9abcd2e`, and source/binary binding
checkpoint `ea8e35c`. Physical left/right Windows-key, Start-click, shortcut,
key-repeat, modifier, focus-loss, and native-suppression rows remain pending.
Rollback to the state before this work: `81924b7`; rollback to all of Plan 1:
`42d61a4`.

### 2. Add lifecycle recovery

Required: event-driven recovery for Explorer restart/crash, taskbar recreation,
lock/unlock, sleep/resume, sign-out, and taskbar monitor/alignment changes;
three failures in a suggested two-minute window; preserve the intentional
native-Start suppression policy; diagnostic reason; manual recovery through
`--status` and `--rehook`.

Status: substantially implemented and partially isolated-tested, not fully live
qualified. Principal commits span `88240cf` through `1fc38dd`, with serialization
fixes `3d1a1e4` and `9abcd2e`. The exact-current isolated missing/corrupt/
incompatible DLL matrix passed at:

`%LocalAppData%\A4SMenuFailureRecovery-20260901-053807-9e49a4c8d0dc4d90aab3f58c49d82d05\evidence.json`

Evidence SHA-256:
`3FB43E844696812804FBDC35155117C9419C8335CFA73380F1A8F9D0A5F9E1F9`.

Manual native-Start observation and destructive/live recovery rows remain
pending. Current implementation differences from the attachment must be
resolved deliberately: the guard uses three failures in 180 seconds rather
than the suggested 120 seconds; recovery uses `--reset-safety`; and `--rehook`
rejects a same-live-Explorer request and does not clear `SAFETY_DISABLED`.

### 3. Instrument performance before optimization

Required: high-resolution/ETW measurements for input-to-DWM-visible frame,
warm/cold open, compositor removal, enumeration, icons/metadata, backdrop,
search, Programs, Explorer memory, idle CPU, and disk/registry/COM activity,
with median and p95.

Status: instrumentation/tooling is implemented; a genuine unoptimized
intermediate baseline exists, but final exact-build coverage is incomplete.
Principal commits are `81924b7`, `2bfa587`, `1e48515`, `37c2df9`, `6f8841b`,
and hardening through `86b48f6`. The preserved ignored
`build\test-results\A4S-*unoptimized*` evidence contains 30 warm samples:
proxy warm p95 41.529 ms, custom ETW visible p95 24.584 ms, custom close p95
3.907 ms, proxy close p95 15.302 ms against a 4.184 ms frame, host idle 0%,
Explorer private-byte delta +3,436,544, pinned p95 12.919 ms, icon p95 0.075
ms, and backdrop p95 0.053 ms. It is not the current binary pair and lacks
exact DWM, physical I/O, registry/COM, Programs, and manual-search coverage.

### 4. Perform evidence-based optimization

Required: retain hidden/stable UI objects, idle-preload pinned items, cache
icons/metadata and Programs, lazy search, remove warm-path filesystem/registry/
shell COM, reuse graphics resources, repaint changed rectangles only, and keep
expensive work off Explorer's UI thread. Targets are warm open <= 50 ms, close
on the next compositor frame, effectively 0% idle CPU, no warm-toggle disk
access, and no visible pop-in.

Status: most code changes are implemented, but final live target validation is
pending. Pre-optimization checkpoint: `a568985`. Principal commits: `4177a4d`,
`50b8d24`, `2f9e102`, `11d6700`, `430b7cc`, `86a7ae0`, `6f10a49`, `7ff3835`,
`f3c3101`, `c1bcfef`, and repaint work `6cd3183`.

### 5. Prune remaining code and resources

Required only after measurements: linker/dependency reports; split fixed
settings from SettingsUI; replace skin and CustomMenu parsing with fixed
records; then remove unused jump-list, drag/drop, touch, Start-button, dialog,
string, bitmap, and stock-skin code while rebuilding and rerunning accepted
tests after every removal.

Status: partial. Pre-step checkpoint: `86b48f6`; partial product-boundary
milestone: `9554cfb`. SettingsUI, CustomMenu, jump-list, drag/drop, and touch
implementations were excluded from the product DLL via fixed stubs. Linker and
dependency reports are missing; SkinManager/parser, StartButton, some headers,
stubs, and bitmaps remain; the pruned build has no accepted post-prune live
qualification.

### 6. Build the one-file installer

Required: `A4SMenuSetup.exe`; default `%LocalAppData%\Programs\A4SMenu\` with
Host + DLL; install/upgrade/repair/uninstall and silent modes; per-user startup
and uninstall registration; matching architecture/version checks; cooperative
unhook; staged atomic activation and rollback; host restart; ask before an
unavoidable Explorer restart; host never installs or repairs files.

Status: substantially implemented and offline-tested, not live lifecycle
qualified. Main commits: `c552851`, `06337dc`, `38dbb46`, `8a604fb`, with the
latest exact-slot rollback fix preserved separately at `4b99c15` (`Reuse the
exact previous installer slot after rollback`). The actual design currently
diverges from the attachment: it installs below
`%LocalAppData%\A4SMenu\versions\<slot>\`, and each slot contains Host, DLL,
and a dormant Setup copy. Standard-user install/update/repair/uninstall, logon,
restart-consent, and real rollback evidence remain pending.

### 7. Full stability and release testing

Required: Explorer lifecycle, multiple/mixed-DPI monitors at 100/125/150/200%,
taskbar positions and alignments, all Windows-key combinations, held/repeated
keys, fullscreen modes, session/power transitions, Fast User Switching,
elevation, full installer lifecycle, old loaded DLL, missing/corrupt/mismatched
DLL, initialization failure, crash loop, native recovery, and coexistence with
the full Open-Shell development tree.

Status: mostly not run. Harnesses exist, but the physical and current-profile
matrix remains pending. The removed alternate-environment attempts do not
count as evidence for any row.

### 8. Final release gate

Required: installed Host + DLL only; achieved performance targets; unchanged
native shortcuts; stable Explorer; no native-Start escape path while A4S is
installed and active; clean uninstall; tested rollback; final README and
technical evidence.

Status: not reached. `ea8e35c` documents and binds source, and `c155ae2` records
a Host/DLL identity, but neither is a qualification/release checkpoint. Every
native, performance, installer, qualification, and final-release ledger row
that lacks recorded evidence remains pending.

## Current staged identities

These later staged files are preserved for deliberate future testing. They are
not declared released:

| Binary | Bytes | SHA-256 |
| --- | ---: | --- |
| `build\stage\A4SProduct\A4SMenuHost.exe` | 207872 | `8115F85209E937DFE88C377284C30275F3562334E040B19DEF072B78B13DED73` |
| `build\stage\A4SProduct\A4SMenu.dll` | 1355776 | `8A9ACE1D4AA30DDCA522FF22814F84D96DAF766E8453C58BC3099B1F66FAA905` |
| `build\stage\A4SSetup\A4SMenuSetup.exe` | 1901056 | `4A8A7109BF77F73F71723BB2ED1192F15FB7E873381BDBE0F0EE315224478704` |

## Rollback rules

- To restore Plan 1 source, use `42d61a4`; use the preserved backup directory
  above for the exact accepted Plan 1 binaries.
- To restore the accepted UI source before the product split, use `edc8bf0`.
- To inspect a step, use its named commits above; do not call a partial
  implementation a release.
- The alternate-environment work was interleaved with valid later changes, so
  resetting to `38dbb46` or blindly reverting the historical commits would
  discard legitimate recovery, optimization, installer, and documentation
  fixes. The correct rollback is the forward cleanup commit that introduced
  this file.
- Do not rewrite history. Historical commits may contain the removed approach;
  they are not approved execution points and were not pushed to `origin/main`.

## Protocol before the next change

1. Read the authoritative attachment and this boundary.
2. State the exact Plan 2 step, intended files, expected test, and rollback
   commit before modifying or launching anything.
3. Do not add a new execution environment or broaden the plan implicitly.
4. Preserve the accepted Plan 1 binary backup and exact launcher block.
5. Record exact binary hashes and evidence for every test; never convert an
   unrun or incomplete row into a passing claim.
6. Make a focused checkpoint before crossing from implementation to live
   mutation, installation, Explorer restart, or session/power testing.
