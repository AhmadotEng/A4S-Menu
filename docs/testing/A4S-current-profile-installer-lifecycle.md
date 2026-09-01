# A4S current-profile installer lifecycle qualification

`Test-A4SInstallerLifecycle.ps1` is the guarded live test for the real current
user profile. It mutates the per-user A4S installation, startup, uninstall, and
cache locations. It is not an offline test, it does not run automatically from
the product build, and this document does not claim that it has been executed.

Frozen-V1 install/update/rollback is intentionally excluded here. V1 predates
the lifecycle sequence/token ownership protocol, so it is only verified
read-only in the current profile. Its mutation matrix belongs in the disposable
[Windows Sandbox procedure](A4S-legacy-sandbox-lifecycle.md).

## Safe starting state

Run the companion contracts first:

```powershell
.\tools\Test-A4SInstallerLifecycleContracts.ps1
```

That gate parses and fault-injects the harness/source contract without running
setup or touching installed A4S state. The live harness then requires 64-bit
PowerShell and refuses to start unless all of the following are true:

- the V1 and V2 setup paths are local, fixed, regular, non-reparse files with
  the exact supplied SHA-256 values and expected `1.0.0.0`/`1.1.0.0` versions;
- the V1 embedded host/DLL hashes equal the frozen reviewed identities;
- the install root has no installer-owned registration, versions tree, setup or
  cleanup process, journal, RunOnce continuation, or cleanup helper;
- the taskbar Explorer is the current interactive x64 Explorer and has no A4S
  module mapped; and
- fixture, evidence, install, and helper paths neither overlap nor alias one
  another.

Existing user-owned `HKCU\Software\A4SMenu` data and `DataCache.db` are allowed.
Before the first setup execution the harness captures a durable recovery
manifest containing their native registry types/bytes and cache bytes/absence.

## Exact current-profile sequence

After read-only `--verify` probes for both frozen V1 and reviewed V2, the live
matrix performs:

1. silent V2 install;
2. silent same-version V2 `--repair`;
3. silent V2 uninstall;
4. silent final V2 install; and
5. authenticated logical host exit, leaving V2 installed but quiescent.

The harness never supplies `--restart-explorer`. If a previously mapped DLL
prevents immediate final activation, it records the stopped/native-fallback
state; a later manual Explorer restart and host launch, or the next sign-in,
activates the registered slot.

Every step receives a harness-owned operation sequence/token and must commit
that exact identity. Checkpoints bind setup/host/DLL hashes, slot inventory,
Run/RunOnce/uninstall registration, Explorer modules, process state, cache,
user-state partitions, and HostSafety. Install and uninstall must preserve the
captured user state while cleanup is pending. Explicit `--repair` may clear only
HostSafety; install, update-like registration, uninstall, and final install may
not. After the final host is quiescent, the harness merges the original
user-owned registry projection and original cache bytes back around the exact
installer-owned registration, then verifies stability again.

The uninstall checkpoint may be either quiescent or pending because Explorer
can still map the exact known DLL. Pending cleanup is accepted only when one
identity-bound helper/RunOnce continuation and one explained mapped slot account
for it. If the uninstall key still exists in this pending state, it must be an
exact empty root placeholder: every Windows Settings value and every subkey must
already be gone. A quiescent checkpoint requires the key itself to be absent.
The immediate final install must cancel that stale helper promptly and must not
let it delete the newly registered product.

## Live command

Use only the final reviewed setup hash and the frozen V1 hash shown by the
harness. Paths here are placeholders, not release evidence:

```powershell
.\tools\Test-A4SInstallerLifecycle.ps1 `
    -V1SetupPath <frozen-v1-setup-path> `
    -V2SetupPath .\build\A4SProduct\bin\x64\A4SMenuSetup.exe `
    -ExpectedV1SetupSha256 DF282F8DC18B382B7AC28599294E2A371EF97D01F85AE6F66E9DF6A02ACBC7C2 `
    -ExpectedV2SetupSha256 <reviewed-v2-setup-sha256> `
    -AllowInstallMutation
```

Evidence is written to a fresh child of
`build\evidence\installer-lifecycle` unless `-EvidenceDirectory` selects a
reviewed non-overlapping location. A reported PASS applies only to the exact
recorded inputs and final state.

## Failure behavior

The harness records every setup launch and checkpoint before making the next
decision. On failure it mutates only an aggregate it previously registered as
owned and still proves unchanged. It can wait for known pending cleanup,
restore the originally clean user projection, or uninstall a still-exact owned
V2 state. A superseding or ambiguous state is preserved and reported rather
than overwritten. Keep the evidence/recovery directory until the original
registry and cache state and the final product state have both been verified.

This procedure supplies installer evidence for I2-I10 and part of Q8 in the
[second-half ledger](../architecture/A4S-second-half-requirements.md). It does
not prove legacy V1 mutation, Settings UI appearance, a fresh logon, an Explorer
restart, or post-Explorer-exit physical cleanup unless those are separately
observed and recorded.
