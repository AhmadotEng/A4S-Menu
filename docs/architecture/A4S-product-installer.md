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
missing or corrupt, repair never overwrites it: setup deploys a fresh verified
`<identity>.repair-<GUID>` slot.

This hash is an integrity/slot-addressing mechanism, not publisher
authentication. Release artifacts still require Authenticode signing before
public distribution.

The setup copy is not launched at every logon. It remains in the active slot so
Windows Settings repair/uninstall commands keep working if the downloaded
installer is moved or deleted. The active host is the only `Run` entry.
Windows Settings metadata is in the current user's uninstall key; active and
previous slot paths are under `HKCU\Software\A4SMenu`.

## Serialized, recoverable servicing

Every state-changing operation first takes a named, per-user mutex. A second
installer returns `ERROR_INSTALL_ALREADY_RUNNING`; it cannot race registry or
slot changes made by the first.

Install, update, and repair use this order:

1. Validate all embedded x64 payloads and the setup image.
2. Build and verify a new staging directory under `versions`, flush each file,
   compare all three byte-for-byte, and rename the directory to its immutable
   final name on the same volume. This fallible work occurs while the current
   host is still running.
3. Capture the exact native type and bytes of every owned Run, RunOnce,
   uninstall, and product-state value in a durable servicing journal. Queue a
   `!A4SMenuServicingRecovery` RunOnce command that invokes the setup copy in
   the target slot.
4. Request the running host's authenticated logical exit and wait for its
   Explorer callbacks to disarm. Setup does not force-kill it.
5. Durably prepare uninstall metadata and `ActiveSlot`/`PreviousSlot` while the
   old `Run` value remains authoritative.
6. Durably set `ReadyToCommit`, then write and flush the new `Run` command as
   the final externally visible commit marker.
7. For an explicit repair, clear the HostSafety crash-loop latch only after the
   target registration has committed. Durably remove the journal, then remove
   the recovery RunOnce value.

An in-process failure replays the exact raw snapshot and restarts the former
host when it had been present. It never deletes `%LocalAppData%\A4SMenu`, user
settings, or caches. A process or power interruption is resolved by
`--reconcile`: an incomplete/pre-commit operation restores the snapshot; a
fully matching committed target is completed. The durable RunOnce continuation
makes this reconciliation automatic at the next sign-in after registry changes
have begun. A journal created before any registration change is harmless even
if its RunOnce continuation had not yet been queued.

Fixed product versions are read from setup, host, and DLL. An older installer
cannot replace a newer active slot; an intentional downgrade uses `--rollback`
and a fully validated previous slot. After a successful install or rollback,
setup retains the active slot and one previous slot. A former active slot that
is still mapped by Explorer is retained until a later safe prune.

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
deletes/flushed `Run` as the final uninstall commit. A crash therefore leaves
either the old exact registration or a durable cleanup path—never an
unregistered orphan with no continuation. Failure to launch the immediate
helper is non-fatal because RunOnce remains queued.

The helper waits on process handles without polling and deletes only the three
known product files in direct, non-reparse-point version directories. It never
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
| no operation | Install if no active slot is registered; otherwise repair/update. |
| `--install` | Install the embedded version for the current user. |
| `--repair` or `--update` | Validate and atomically redeploy/register the embedded version; reset HostSafety only after commit. |
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
  journal/RunOnce ordering, exact rollback, post-commit HostSafety reset,
  uninstall handoff, reparse boundaries, and absolute Explorer launch;
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
