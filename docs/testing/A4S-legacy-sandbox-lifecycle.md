# A4S legacy installer lifecycle in Windows Sandbox

`Invoke-A4SLegacySandboxLifecycle.ps1` qualifies the frozen `1.0.0.0`
installer against one reviewed `1.1.0.0` installer without installing V1 in the
real user profile. The repository (including the frozen fixture and reviewed V2
setup) and a fresh per-run control directory are mapped read-only. A separate
per-run results directory is the only writable host mapping. The request,
Sandbox configuration, and host result therefore are not writable from the
guest.

The complementary real-profile harness deliberately verifies V1 read-only and
mutates only V2; see
[A4S-current-profile-installer-lifecycle.md](A4S-current-profile-installer-lifecycle.md).
Neither document claims its live matrix has run merely because the harness is
present.

The Sandbox configuration disables networking, vGPU, microphone and camera
input, printers, clipboard sharing, and enables Protected Client. The runner
will not launch without the explicit `-AllowSandboxLaunch` switch. It also
refuses an existing Sandbox session, mapped/reparse fixture paths, a V2 setup
outside the repository, or a writable evidence path that overlaps the
read-only repository mapping. The guest additionally requires the real process
token to be the local `WDAGUtilityAccount` SID ending in RID 504; environment
variables alone cannot authorize destructive guest operations. The host binds
the launcher to the canonical x64 `%SystemRoot%\System32\WindowsSandbox.exe`
instead of trusting PATH resolution.

Run the offline parser and safety contracts first:

```powershell
.\tools\Test-A4SLegacySandboxLifecycleContracts.ps1
```

After the final V2 build has been reviewed, calculate and independently record
the setup, embedded host, and embedded DLL hashes. Then launch the disposable
matrix with those exact values:

```powershell
.\tools\Invoke-A4SLegacySandboxLifecycle.ps1 `
    -V2SetupPath .\build\A4SProduct\bin\x64\A4SMenuSetup.exe `
    -ExpectedV2SetupSha256 <reviewed-setup-sha256> `
    -ExpectedV2HostSha256 <reviewed-host-sha256> `
    -ExpectedV2MenuSha256 <reviewed-menu-sha256> `
    -AllowSandboxLaunch
```

The guest executes this fixed sequence:

1. frozen V1 install;
2. V1-to-V2 update;
3. rollback to V1;
4. update to the same reviewed V2 again;
5. same-version V2 repair; and
6. V2 uninstall.

Each step requires exit code zero and captures exact setup/host/DLL hashes,
fixed product versions, registration, slots and file inventory, the taskbar
Explorer PID and mapped A4S modules, process state, user-state fingerprints,
and `DataCache.db`. No operation receives `--restart-explorer`.

Config/Menu/legacy sentinels are seeded before the V1 install and must survive
that install. Because the V1 install necessarily starts its host, the cache
preservation baseline is written only after the V1 DLL is mapped, the host has
accepted `--exit`, and its preload interval has settled. The V2 update,
rollback, second update, repair, and pending-uninstall checkpoint must preserve
those exact cache bytes.

The V1 DLL is intentionally observed mapped in the same Explorer process. A
no-restart uninstall therefore ends as a *logical uninstall with verified
physical cleanup pending Explorer exit*. The evidence requires the Run and
active registration to be gone, the exact V2 cleanup helper and identity-bound
RunOnce continuation to remain, the host to be stopped, and the seeded user
state/cache to remain exact while cleanup is blocked. Closing Windows Sandbox
then discards the entire guest. This run does not claim that post-Explorer-exit
physical cleanup was observed.

The guest publishes `progress.json`, then atomically publishes `evidence.json`
and `completion.json`. The host reads each final JSON file once under a
non-writable file handle, hashes and parses the same bytes, and validates the
request/session nonce and evidence hash. These checks reject stale, partial,
cross-run, or post-publication file replacement; they are correlation and
integrity checks between the reviewed host and guest scripts, not a security
boundary against another process already running as the same host user. The
host captures the real profile's A4S state before and after and fails if that
state or the host Explorer PID changed. Windows Sandbox is left open after
completion for inspection; close it manually.
