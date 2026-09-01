# A4S failure and crash-loop recovery qualification

`Test-A4SFailureRecovery.ps1` separates safe offline contracts, isolated DLL
load failures, a deliberately destructive Explorer crash-loop test, and an
authenticated HostSafety recovery path. The isolated and live modes are never
implied by an offline PASS. This document defines how to run them later; it does
not claim that either executable mode has run.

## Immutable release binding

Both executable modes require a tracked, committed release-record JSON file
inside this repository. The file must contain exactly these eight fields:

```text
schemaVersion
product
sourceCommit
hostSha256
dllSha256
hostFileVersion
dllFileVersion
hostReportedVersion
```

`schemaVersion` is integer `1`, `product` is exactly `A4SMenu`, hashes are full
SHA-256 strings, and `sourceCommit` identifies the exact source used for the
binaries. The record's own Git commit must descend from that source commit, and
the working file must be byte-identical to its committed blob. The harness then
binds the supplied PE files and host `--version` result to the record. Create
this record only after the final source is committed and exact binaries are
built; no provisional record is release evidence.

## Offline contracts

Run without parameters:

```powershell
.\tools\Test-A4SFailureRecovery.ps1
```

This invokes `Test-A4SFailureRecoveryContracts.ps1`. It parses the harness,
checks the host/setup lock and crash-state contracts, and exercises transaction
primitives only in a cryptographically random HKCU test subtree and a validated
OS-temporary root. It does not alter product HostSafety, start a host, map the
DLL, restart Explorer, or create live evidence.

## Isolated sibling-DLL failures

After the final release record is committed and a fresh taskbar Explorer has no
A4S mapping, the non-crashing executable matrix is:

```powershell
.\tools\Test-A4SFailureRecovery.ps1 `
    -RunIsolatedDllFailures `
    -HostPath <reviewed-A4SMenuHost.exe> `
    -ReleaseRecordPath <tracked-release-record.json>
```

It creates private missing, corrupt, and known-loadable non-product sibling DLL
cases; the last deliberately has no A4S exports. Each host must fail without
injecting Explorer, every tracked host
must stop, the same Explorer identity must remain clean, and Registry64
HostSafety must be restored transactionally. Evidence defaults to a durable
fresh directory below `%LocalAppData%`, outside the repository and `%TEMP%`.
The test records that native Start behavior still needs a human observation; it
never turns absence of an A4S mapping into a mechanical native-Start PASS.

## Deliberately destructive live crash-loop mode

This mode forcibly terminates the validated taskbar Explorer three times and
performs one final cleanup restart. Announce the disruption, close unrelated
work, review the exact release record and command, and use a fresh Explorer with
no prior A4S mapping. It requires both the conspicuous switch and the exact
confirmation text:

```powershell
.\tools\Test-A4SFailureRecovery.ps1 `
    -IUnderstandThisWillForceCrashExplorerThreeTimesAndRestartItForCleanup `
    -ConfirmationText 'I ACCEPT FOUR EXPLORER TERMINATIONS: THREE GUARDED CRASHES AND ONE CLEANUP RESTART' `
    -HostPath <reviewed-A4SMenuHost.exe> `
    -DllPath <reviewed-A4SMenu.dll> `
    -ReleaseRecordPath <tracked-release-record.json>
```

The harness durably backs up the exact Registry64 HostSafety aggregate before
the first crash and binds every later mutation to that known state. It verifies
READY/one-menu behavior and the exact DLL mapping, then records ordered crash
boundaries 1, 2, and 3. The first two replacement Explorers must reconnect; the
third must leave the replacement Explorer uninjected with `SAFETY_DISABLED`.
The five-value HostSafety schema and its timestamp boundaries are checked at
each stage. An explicit reset must restore a usable connection, after which the
host is logically disarmed and the fourth Explorer termination establishes a
clean replacement for recovery cleanup.

Native Start availability after failure and crash-loop disablement remains a
manual observation even when all mechanical assertions pass. Preserve that
observation beside the JSON evidence rather than changing the harness result.

## Recovery and retained bundles

Evidence and `HostSafetyBackup.json` are persisted before any authorized
Explorer termination. If interruption prevents automatic restoration, the
evidence contains the exact retained root, manifest hash, freshly observed
current HostSafety aggregate hash, and recovery command. Do not delete the
bundle or guess at registry values. First prove that every same-user A4S host in
every Windows session is stopped and that the taskbar Explorer has no A4S DLL
mapping or A4S menu window. Then use the recorded values with:

```powershell
.\tools\Test-A4SFailureRecovery.ps1 `
    -RecoverHostSafety `
    -RecoveryBundle <retained-bundle> `
    -ExpectedManifestSha256 <recorded-manifest-sha256> `
    -ExpectedCurrentHostSafetySha256 <freshly-recorded-current-state-sha256>
```

Recovery authenticates the bundle, refuses an intervening aggregate, and keeps
an immediate pre-restore rollback bundle. Delete neither bundle until exact
restoration and clean-state inspection are complete.

The host-side schema and lock order are documented in
[A4S-native-input-recovery.md](../architecture/A4S-native-input-recovery.md).
N6, N8, and N9 in the
[second-half requirement ledger](../architecture/A4S-second-half-requirements.md)
remain pending until the exact isolated/live evidence and required manual
native-Start observations are recorded.
