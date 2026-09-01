# A4S Menu one-file installer

`A4SMenuSetup.exe` is the x64, per-user servicing boundary for A4S Menu. It is
built from `Src/A4SMenu/Setup` and embeds the exact `A4SMenuHost.exe` and
`A4SMenu.dll` produced by the same `A4SProduct|x64` build. It contains no
Open-Shell setup, updater, settings application, skin selector, Classic
Explorer, or taskbar payload.

The one-file distributable is staged at
`build/stage/A4SSetup/A4SMenuSetup.exe`. The directly testable host and DLL
remain available under `build/stage/A4SProduct`; setup code is never loaded into
Explorer.

## Installed layout and identity

The default root is `%LocalAppData%\A4SMenu`; setup does not request elevation.
Runtime versions use immutable slots:

```text
%LocalAppData%\A4SMenu\
  DataCache.db                         preserved across install/update/repair
  versions\
    <version>-<64-hex payload identity>\
      A4SMenuHost.exe                 the only resident process
      A4SMenu.dll                     loaded only into Explorer
      A4SMenuSetup.exe                dormant maintenance/uninstall copy
    <previous version slot>\          retained for one-step rollback
```

The payload identity is a full SHA-256 digest derived from the individual
SHA-256 digests of host, DLL, and setup. Every validation re-reads all three
files, verifies their x64 PE type and matching fixed product versions, and
recomputes this identity from their bytes. A version 1.0 20-hex identity is
accepted only for one-step migration. If a canonical same-version slot is
missing or corrupt, setup first checks the registered active slot, then the
registered previous slot, and then the canonical slot for the exact incoming
three-file payload. This makes update after rollback return to the same reviewed
immutable slot. A candidate outside the direct canonical `versions` root, a
directory or payload-leaf reparse point, a multiply linked payload leaf, or a
candidate with invalid identity or bytes is never reused. If no candidate
matches, repair never overwrites an existing slot: setup deploys a fresh
verified `<identity>.repair-<GUID>` slot.

This hash is an integrity/slot-addressing mechanism, not publisher
authentication. Release artifacts still require Authenticode signing before
public distribution.

The setup copy is not launched at every logon. It remains in the active slot so
Windows Settings repair/uninstall commands keep working if the downloaded
installer is moved or deleted. The active host is the only `Run` entry.
Windows Settings metadata is in the current user's uninstall key; active and
previous slot paths are under `HKCU\Software\A4SMenu`.

## Serialized, recoverable servicing

Every state-changing operation takes the current-user lifecycle mutex and then
the exact setup-payload mutex. A HostSafety mutation takes the separate global
current-user HostSafety mutex after those two locks. A second installer returns
`ERROR_INSTALL_ALREADY_RUNNING`; setup, the lifecycle harness, the host crash
guard, and explicit safety recovery therefore share one reviewed lock order
rather than racing registry or slot changes.

Install, update, and repair use this order:

1. Validate all embedded x64 payloads and the setup image.
2. Plan every root, versions, staging, final-slot path and its required absence
   before filesystem mutation. Capture the exact native type and bytes of every
   owned Run, RunOnce, uninstall, lifecycle, and product-state value. Persist
   and flush that intent, ownership metadata, operation sequence/token, and the
   complete snapshot in the servicing journal.
3. Only after `SnapshotComplete` is durable, create and verify the planned
   staging directory under `versions`, flush each file, compare all three
   payloads byte-for-byte, and rename it to the planned immutable final slot on
   the same volume. Each materialization/ownership phase is persisted in the
   journal. This fallible work occurs while the current host is still running.
4. Queue and flush the exact `!A4SMenuServicingRecovery` RunOnce command that
   invokes the setup copy in the target slot.
5. Request the running host's authenticated logical exit and wait for its
   Explorer callbacks to disarm. Setup does not force-kill it.
6. Durably prepare uninstall metadata and `ActiveSlot`/`PreviousSlot` while the
   old `Run` value remains authoritative.
7. Durably set `ReadyToCommit`, then write and flush the new `Run` command as
   the final externally visible commit marker.
8. For explicit `--repair` only, clear the HostSafety crash-loop state after the
   target registration has committed. `--update`, automatic repair, install,
   and rollback preserve HostSafety. Mark completion, durably delete the
   journal as the transaction completion point, and only then remove and flush
   the now-idempotent recovery RunOnce value.

An in-process failure replays the exact raw snapshot, releases only filesystem
objects still proven to be owned by that journal, and restarts the former host
when it had been present. It never broadly deletes `%LocalAppData%\A4SMenu`,
user settings, or caches. A process or power interruption is resolved by
`--reconcile`: an intent record without a durable complete snapshot owns no
paths and is discarded; an incomplete/pre-commit operation restores the exact
snapshot and releases only identity-bound owned artifacts; a fully matching
committed target is completed. The recovery RunOnce continuation makes this
automatic at the next sign-in once it has been queued.

Fixed product versions are read from setup, host, and DLL. An older installer
cannot replace a newer active slot; an intentional downgrade uses `--rollback`
and a fully validated previous slot. After a successful install or rollback,
setup retains the active slot and one distinct previous slot. A former active
slot that is still mapped by Explorer is retained until a later safe prune.

## Explorer restart boundary

A mapped DLL is never overwritten or hot-unloaded. If Explorer still maps an
old DLL, interactive setup asks before using Windows Restart Manager to restart
Explorer. Silent setup does not restart Explorer unless the caller explicitly
adds `--restart-explorer`. Declining is safe: the new registration is durable,
native Start remains the fallback, and the registered host activates after a
manual Explorer restart or at the next sign-in. The fallback Explorer launch
uses an absolute path resolved from the Windows directory; setup never executes
an `explorer.exe` found through its current directory.

## Uninstall and deferred cleanup

Uninstall uses the same journal and mutex. Before removing registration, it
writes and flushes one native helper at `%TEMP%\A4SMenuCleanup.exe` and queues a
`!A4SMenuCleanup` RunOnce continuation. It then disarms the host, removes
metadata while retaining the old `Run` value, marks the journal ready, and
deletes and flushes `Run` as the final uninstall commit. A crash therefore leaves
either the old exact registration or a durable cleanup path, never an
unregistered orphan with no continuation. Failure to launch the immediate
helper is non-fatal because RunOnce remains queued.

When Explorer still maps the DLL, this logical-uninstall checkpoint can retain
only the empty owned uninstall-key shell; all Windows Settings metadata values
are already gone, so no uninstall entry remains visible. The verified helper
deletes that empty key during physical cleanup after the blocker exits.

The helper waits for the setup process handle and, when an Explorer blocker was
recorded, waits in 100-ms process-handle intervals. Between waits it checks for
installer registration so a reinstall wakes it promptly. Under both product
locks it reconciles an exact servicing continuation, then rechecks registration:
a fully committed reinstall cancels deletion, while malformed or partial
registration fails closed. Cleanup deletes only the three known, hash/version-
valid product files in direct, non-reparse-point version directories. It never
recursively follows reparse points and never deletes unknown content. Known
runtime caches (`DataCache.db`, `DataCache.tmp`, `DataCache.txt`, and
`StartupLog.txt`) survive install/update/repair and are removed only by explicit
uninstall. Unknown root or slot content is preserved; it may leave data-only
directories behind but does not create an endless cleanup retry. The helper
uses Windows POSIX file-disposition semantics for best-effort self-deletion;
otherwise its one deterministic temporary path remains bounded and reusable.

## Command line

The executable uses Windows error codes as process exit codes.

| Command | Behavior |
| --- | --- |
| no operation | Install if no active slot is registered; otherwise redeploy/register while preserving HostSafety. |
| `--install` | Install the embedded version for the current user. |
| `--repair` | Validate and atomically redeploy/register the embedded version; clear HostSafety only after commit. |
| `--update` | Validate and atomically redeploy/register the embedded version while preserving HostSafety. |
| `--uninstall` | Logically disarm, unregister, and schedule safe known-file cleanup. |
| `--rollback` | Restore the fully validated recorded previous slot. |
| `--silent`, `/quiet`, or `/s` | Suppress all prompts. |
| `--restart-explorer` | Explicitly authorize an Explorer restart when required. |
| `--version` | Print version and exit without servicing. |
| `--verify` | Validate embedded payloads and exit without servicing. |
| `--self-test` | Run deterministic payload-identity, snapshot, and recovery-state tests without installation. |

`--reconcile`, `--cleanup`, wait switches, and `--extract-test
<new-directory>` are private servicing/test commands. Reconcile is invoked by
the durable servicing RunOnce entry. Extraction requires a non-existing
directory and does not inspect or change installation registry state.

Examples:

```powershell
& .\A4SMenuSetup.exe --install --silent
& .\A4SMenuSetup.exe --update --silent
& .\A4SMenuSetup.exe --rollback --silent
& .\A4SMenuSetup.exe --uninstall --silent
```

## Non-installing validation

`tools/Test-A4SSetup.ps1` does not install or reconcile the product. It proves:

- the distributable stage contains exactly one regular x64 setup executable;
- setup, host, and DLL have matching product versions;
- embedded resource hashes equal the exact runtime-stage hashes;
- setup imports only its reviewed Windows system dependencies;
- the full payload identity and every recovery-state decision pass the native
  `--self-test` truth table;
- source contracts retain mutex serialization, immutable repair slots,
  active/previous/canonical reuse order, single-link non-reparse payload leaves,
  journal/RunOnce ordering, exact rollback, explicit-repair-only post-commit
  HostSafety reset plus update preservation, uninstall handoff, reparse
  boundaries, and absolute Explorer launch;
- `--version`, `--verify`, self-test, and temporary extraction terminate
  successfully;
- extraction produces exactly setup, host, and DLL byte-for-byte; and
- all probes leave the complete A4S state subtree and its external Run,
  RunOnce, and uninstall values unchanged.

The full `tools/Build-A4SProduct.ps1` gate builds, atomically stages, and runs
both runtime and setup validation. Live standard-user install, Settings UI,
logon startup, upgrade/rollback, restart consent, deliberately interrupted
servicing, locked-DLL cleanup, and uninstall recovery remain release-matrix
tests. Static and isolated tests do not claim those Windows interactions have
run.

The guarded live current-profile procedure is documented in
[A4S-current-profile-installer-lifecycle.md](../testing/A4S-current-profile-installer-lifecycle.md).
Frozen-V1 mutation and V1-to-V2 rollback remain unqualified. They are outside
the current-profile procedure, and this plan does not authorize an alternate
execution environment for them.
