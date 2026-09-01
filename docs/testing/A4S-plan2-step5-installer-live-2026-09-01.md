# A4S Plan 2 combined Step 5 installer record — 2026-09-01

## Scope and status

This record covers the combined installer cleanup, build, and real
current-profile lifecycle step. The content/static phase and most of the live
servicing matrix completed. The tested setup is **not release-qualified**:
physical uninstall exposed two cleanup defects described below. The accepted
Host and DLL identities remain unchanged.

No Windows Sandbox, VM, simulated Explorer, or synthetic input result qualifies
this step.

## Frozen inputs

- Source/documentation checkpoint:
  `2097486928b0ddd3eb4e7324c8d6ab4789b4b5cd`.
- `A4SMenuHost.exe`: 207,872 bytes, version `1.1.0.0`, SHA-256
  `8DD438DB3FF591CA14388431BD82F08854E87075E6C4E960654DA48FF9B97876`.
- `A4SMenu.dll`: 1,356,800 bytes, version `1.1.0.0`, SHA-256
  `FF66AA070F158D3C1C0732EE195CC88C06BA6034AD691BB969D4B30BEA37ED0A`.
- `A4SMenuSetup.exe`: 1,902,080 bytes, version `1.1.0.0`, SHA-256
  `11A8B530F34E3CA4010A069AF06C44C4687C124D3FBA80BB67F9B3CFBC1B7E76`.
- The setup image is not Authenticode-signed. Signing remains a distribution
  gate and is not represented as completed by this development qualification.

## Installer-content audit

The setup PE contains exactly:

| Resource | Bytes | Purpose |
| --- | ---: | --- |
| `VERSION` | 1,492 | File/product identity |
| `MANIFEST/1` | 1,440 | Windows execution/compatibility manifest |
| `RCDATA/201` | 207,872 | Exact `A4SMenuHost.exe` payload |
| `RCDATA/202` | 1,356,800 | Exact `A4SMenu.dll` payload |

The two embedded runtime payloads total 1,564,672 bytes. The remaining 337,408
bytes comprise the installer PE, manifest/version data, and servicing engine.
No PDB, debug runtime, documentation, language pack, external skin, settings
application, updater, or upstream Open-Shell installer payload is embedded.

Direct imports are limited to `ADVAPI32`, `bcrypt`, `KERNEL32`, `ole32`,
`RstrtMgr`, `SHELL32`, `USER32`, and `VERSION`. They implement registry/state
ownership, hashing/tokens, files/processes/synchronization, LocalAppData memory
release, consented Explorer restart, argument/path/launch handling, UI/window
messaging, and payload-version compatibility. No dependency is currently
unjustified.

The maintenance self-copy is intentionally retained. It keeps repair and
uninstall available after the originally downloaded setup is moved or deleted.
The private verification/extraction/self-test commands reuse required servicing
code and are retained for diagnosability. No evidence-backed content removal is
warranted.

## Non-installing results

- `tools/Test-A4SProduct.ps1`: **PASS**.
- `tools/Test-A4SProductBoundary.ps1`: **PASS**.
- `tools/Test-A4SSetup.ps1`: **PASS**.
- `tools/Test-A4SInstallerLifecycleContracts.ps1`: **PASS as an offline safety
  contract only**, not as live installer evidence.
- Fresh extraction produced exactly `A4SMenuHost.exe`, `A4SMenu.dll`, and
  `A4SMenuSetup.exe`; all three hashes match the frozen inputs above.
- The extraction left A4S startup, RunOnce, uninstall, and installer-owned
  registration unchanged.

## Current-profile pre-mutation state

- Development host PID `23844` runs from `build\stage\A4SProduct`.
- Explorer PID `10408` maps that exact development `A4SMenu.dll`.
- No installer-owned `Run`, `RunOnce`, uninstall key, versions tree, servicing
  journal, setup process, cleanup process, or cleanup helper exists.
- Existing user data consists of legacy `HKCU\Software\A4SMenu`
  `InstallPath`/`Enabled` values and `%LocalAppData%\A4SMenu\DataCache.db`.
  These must be preserved byte-for-byte by the guarded lifecycle procedure.

The read-only checkpoint tool
`tools/Capture-A4SInstallerCheckpoint.ps1` records the registry projection,
install-root inventory, A4S processes, and Explorer module mapping before and
after each separate live operation. Its first checkpoint confirmed one
development host, one development DLL mapped by Explorer, and only the existing
cache file below the per-user install root.

## Compatible previous-version fixture

Update and rollback require a lower version that uses the same durable
sequence/token servicing protocol as the final package. A test-only `1.0.1.0`
fixture was therefore built from the exact frozen source checkpoint in an
isolated detached worktree. The only source differences are the four product
version fields; runtime, UI, installer, and lifecycle code are unchanged.

| Binary | Bytes | SHA-256 |
| --- | ---: | --- |
| `A4SMenuHost.exe` | 207,872 | `43DCE47CE1305C9B9340D2C5576D9DAA93BD6FA84ED8100F981EE141C6430717` |
| `A4SMenu.dll` | 1,356,800 | `8ECA3D7700488322D8375AD0020EA21099DA0496212A41E4A1167CAAF6F05E52` |
| `A4SMenuSetup.exe` | 1,902,080 | `82BE449D9B9BF747D0453227D08323607A4CE3FED31262D45A3336034CC3DEEA` |

This fixture is lifecycle evidence only and is not a release artifact. The
historical `1.0.0.0` package remains excluded because it predates the current
cooperative servicing protocol.

## Live prerequisites and pending matrix

Before installation, the development host must disarm cleanly and the owner
must explicitly approve one Explorer restart so the pinned development DLL is
absent from the new Explorer. The clean boundary must then verify zero A4S host,
setup, cleanup, and Explorer-mapped A4S modules.

The real matrix is deliberately ordered so setup never attempts an unsupported
downgrade:

1. capture a recovery bundle, exit the development host, and cross one
   owner-approved Explorer restart to reach an unmapped clean boundary;
2. clean-install the reviewed protocol-compatible `1.0.1.0` fixture;
3. update to the frozen final `1.1.0.0` package without an implicit restart;
4. physically sign out/in, then verify final startup, exact mapping, status,
   and menu behavior;
5. run same-version final repair;
6. rollback registration to `1.0.1.0`, cross an owner-approved Explorer
   boundary, and physically verify the restored version;
7. update again to `1.1.0.0`, cross an owner-approved Explorer boundary, and
   physically verify the final version;
8. uninstall without an implicit Explorer restart and capture the coherent
   pending-cleanup state;
9. cross an owner-approved Explorer restart and verify physical cleanup and
   native Start behavior;
10. clean-install the frozen final package from that physically clean state,
    restore only the original user-owned registry projection/cache bytes around
    the new installer-owned registration, and verify the delivered state.

The existing monolithic lifecycle harness remains unchanged. It is not used for
this run because it expects the historical fixture and does not pause between
real desktop/session transitions. Setup mutations are invoked separately, with
a fresh read-only checkpoint and owner-visible validation between operations.

## Live results

The development host exited cleanly. The first Explorer-restart guard detected
two same-session `explorer.exe` processes and correctly made no change. The
taskbar owner was then identified through `Shell_TrayWnd`; with explicit owner
approval only that shell process was restarted. Shell PID changed from `10408`
to `23024`, and the new clean checkpoint recorded zero A4S processes, zero
Explorer-mapped A4S modules, no installer registration, and only the preserved
cache file.

The compatible `1.0.1.0` fixture then installed successfully on the real
current profile:

- lifecycle sequence `1`, operation token
  `CE264EE350E9201F66B12B4270B092DE38A456C9EC3D198619F287541708BC0C`;
- active Host/DLL/setup hashes exactly matched the reviewed fixture;
- one ready host and one matching Explorer DLL mapping;
- exact startup and uninstall registration, with no cleanup or recovery
  `RunOnce` residue;
- the owner physically opened the menu and confirmed normal behavior.

The frozen final setup then completed `--update --silent` with exit code `0`
and without changing Explorer PID:

- lifecycle sequence `2`, operation token
  `55EC0C92C325ACE8E59AC91EF9587E05C3D7960F1BF51359C6C63000CB01D850`;
- active slot version `1.1.0.0` with all three exact frozen hashes;
- previous slot retained all three exact `1.0.1.0` fixture hashes;
- startup/uninstall registration remained complete and transient servicing
  state was absent;
- the host was stopped while Explorer retained the exact previous-version DLL,
  which is the designed pre-session-reload state.

One evidence limitation is explicit: the owner opened the fixture menu after
the installed checkpoint, but no second immediate checkpoint was captured
before update. The later comparison shows only runtime-maintained
`Menu\LastAppsTime`, `Menu\LastProgramsTime`, and `DataCache.db` changed; all
configuration values remained stable. Because that activity window spans both
the real menu use and setup invocation, it is not claimed as installer-only
preservation evidence. Every remaining mutation must take a fresh immediate
pre-checkpoint.

After a physical sign-out/sign-in, the registered final host started without
manual assistance. The read-only checkpoint recorded host PID `24384`, status
`ready`, exact final Host SHA-256
`8DD438DB3FF591CA14388431BD82F08854E87075E6C4E960654DA48FF9B97876`,
and exactly one Explorer mapping of final DLL SHA-256
`FF66AA070F158D3C1C0732EE195CC88C06BA6034AD691BB969D4B30BEA37ED0A`.
Sequence `2` and its operation token were unchanged, startup/uninstall
registration remained present, and cleanup/recovery `RunOnce` values were
absent. The owner confirmed that the menu opened normally after sign-in.

Same-version `1.1.0.0 --repair --silent` then completed with exit code `0`
without changing Explorer PID. It advanced lifecycle sequence to `3` with
operation token
`598DF28B2C66986AEA321F9F18976639F5F1FE3A48142C526F465A9222B7D42A`.
The active and previous slots, all installed paths/hashes, startup/uninstall
registration, user-owned registry projection, and cache bytes were identical
to the immediate pre-repair checkpoint. No transient servicing state remained.
As designed while the DLL is mapped, the host is stopped pending the rollback
test and a later owner-approved Explorer boundary.

Rollback then completed with exit code `0` and without changing Explorer PID.
It advanced lifecycle sequence to `4` with operation token
`1AB644EFA8E754B95DCBB0B3E63C928996B763927D139A491AE73CD61CF403BF`,
registered the exact three `1.0.1.0` fixture payloads as active, and retained
the exact three final `1.1.0.0` payloads as previous. The immediate pre/post
comparison proved unchanged user registry projection, cache bytes, and
installed file paths/hashes; startup/uninstall registration remained present
and no transient servicing state remained. Explorer still maps the final DLL
and the host remains stopped until a separately approved shell restart.

With explicit owner approval, the first rollback-restart command contained an
operator-script spacing error. It attempted PID `0`, Windows denied that
operation, and a read-only probe confirmed shell PID `21732` and unchanged
product state. The corrected guarded command then restarted only the
`Shell_TrayWnd` owner (`21732` to `17940`). The unmapped checkpoint recorded
zero A4S modules/processes. Launching the exact registered rollback host reached
`ready` at PID `10796`, and Explorer mapped exactly one DLL with reviewed
`1.0.1.0` SHA-256
`8ECA3D7700488322D8375AD0020EA21099DA0496212A41E4A1167CAAF6F05E52`.
The owner confirmed normal visible rollback-menu interaction.

The owner then confirmed the rollback menu opened normally. A second update to
the frozen final package completed with exit code `0` and unchanged Explorer
PID. It advanced lifecycle sequence to `5` with operation token
`0C88A2ED391432CA79A7253A79BA0CF91580169022093D08CA1BD8F3AEDB337B`.
The exact final payloads are active, the exact fixture payloads remain previous,
and an immediate pre/post comparison proved unchanged user registry projection,
cache bytes, and installed paths/hashes. No transient servicing state remains.
Explorer still maps the fixture DLL and the host is stopped pending a separately
approved final shell restart.

With explicit owner approval, the final activation restart replaced taskbar
Explorer PID `17940` with `23136`; the clean boundary contained no A4S mapping
or process. The exact registered final host then reached `ready` at PID `12600`,
and Explorer mapped exactly one DLL with final SHA-256
`FF66AA070F158D3C1C0732EE195CC88C06BA6034AD691BB969D4B30BEA37ED0A`.
The owner confirmed normal visible menu interaction before uninstall.

## Uninstall result and discovered defects

Final `1.1.0.0 --uninstall --silent` completed its logical transaction without
restarting Explorer. It advanced lifecycle sequence to `6` with operation token
`A46EE016E6EACA0B3DE7B0ACBF94A4C4534E9A903D3FA0242C588C6039CA9F18`.
The immediate checkpoint proved a coherent pending-cleanup state: startup and
installed registration were removed, the exact empty uninstall placeholder and
exact identity-bearing `!A4SMenuCleanup` value remained, the exact cleanup
helper was running, and Explorer still mapped the final DLL. No unrelated user
state was changed.

After the approved Explorer boundary, the runtime was inactive but physical
cleanup did not converge. The settled state contained:

- no A4S process or Explorer DLL mapping;
- no startup, cleanup, or recovery `RunOnce` value;
- the exact sequence-6 lifecycle identity;
- both immutable version slots, `DataCache.db`, the empty uninstall key, and
  `%TEMP%\A4SMenuCleanup.exe` still present.

Windows had consumed the `!A4SMenuCleanup` wake-up before the helper acquired
its product locks. The setup then incorrectly required that value to remain
present in both `CleanupContinuationMatches` and
`RemoveCanonicalCleanupStateForHelper`, so the exact helper rejected its own
valid continuation. `RunOnce` is therefore a wake-up mechanism, not durable
cleanup ownership. The exact lifecycle operation identity and the product's
installed/recovery-state gates must remain the cleanup authority; a present
mismatched retry value must still fail closed. Replacement-Explorer inspection
also needs a bounded retry so a temporarily absent taskbar or incomplete module
snapshot cannot consume the only cleanup opportunity.

The failed state was preserved locally before recovery. The verified backup at
`C:\Users\Admin\A4SBackup-20260901T195726818Z` contains all seven installed
files, the exact helper, and exports of both A4S registry trees. It is outside
this repository and is not a pushed artifact.

For recovery only, the exact sequence-6 retry value was restored and the exact
reviewed helper (SHA-256
`11A8B530F34E3CA4010A069AF06C44C4687C124D3FBA80BB67F9B3CFBC1B7E76`) was
invoked directly. It removed the install tree and product registry state but
returned Windows error `82` while attempting native self-deletion. The exact,
unlocked helper was then moved into the verified backup instead of being
destroyed. A final read-only check proved zero installed files, registrations,
continuations, A4S processes, and Explorer mappings. The desktop `A4S Menu`
development shortcut remains intentionally because it targets the repository's
preview script and is not installer-owned.

This recovery is not counted as a passing uninstall. The tested setup hash
`11A8B530F34E3CA4010A069AF06C44C4687C124D3FBA80BB67F9B3CFBC1B7E76` is
disqualified for release. Its source remains unchanged at this checkpoint;
the incomplete cleanup experiment was deliberately excluded from the commit.

## Qualification status

Passed on the real profile:

- compatible clean install and visible menu interaction;
- final update and physical sign-in startup;
- same-version repair with exact state preservation;
- rollback, approved Explorer boundary, and visible prior-version menu;
- update back to final and approved activation boundary;
- logical uninstall transaction and exact pending-cleanup capture.

Still required before Step 5 can close:

1. implement and test consumed-`RunOnce` continuation handling;
2. bound replacement-Explorer inspection without weakening module safety;
3. make helper self-removal reliable or provide a verified per-user fallback;
4. rebuild while preserving the accepted Host/DLL hashes and record the new
   setup hash;
5. repeat only the affected real path: install, uninstall without restart,
   approved Explorer restart, and complete physical cleanup;
6. install the corrected one-file package again as the delivered state.
