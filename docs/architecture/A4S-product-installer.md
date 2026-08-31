# A4S Menu one-file installer

`A4SMenuSetup.exe` is the x64, per-user servicing boundary for A4S Menu. It is
built from `Src/A4SMenu/Setup` and embeds the exact `A4SMenuHost.exe` and
`A4SMenu.dll` produced by the same `A4SProduct|x64` build. It contains no
Open-Shell setup, updater, settings, skin, Classic Explorer, or taskbar payload.

The exact one-file distributable is staged separately at
`build/stage/A4SSetup/A4SMenuSetup.exe`. The development/runtime stage remains
the exact two files under `build/stage/A4SProduct`; this keeps setup code out of
Explorer and preserves the direct host/DLL lifecycle test.

## Installed layout

The default root is `%LocalAppData%\A4SMenu`; no elevation is requested. Runtime
versions are immutable slots:

```text
%LocalAppData%\A4SMenu\
  DataCache.db                         preserved across install/update/repair
  versions\
    <version>-<payload identity>\
      A4SMenuHost.exe                 the only resident process
      A4SMenu.dll                     loaded only into Explorer
      A4SMenuSetup.exe                dormant maintenance/uninstall copy
    <previous version slot>\          retained for one-step rollback
```

The setup copy is never launched at logon and is not a resident runtime
component. It is retained because the Windows Settings uninstall and repair
commands require a stable executable after the downloaded installer is moved
or deleted.

The active host is registered only in
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Windows Settings metadata
is under the current user's uninstall key. Product state records the active and
previous immutable slots under `HKCU\Software\A4SMenu`.

## Servicing transaction

Install, update, and repair use this order:

1. Validate the embedded x64 PE payloads and the setup image.
2. Request the running host's authenticated logical exit and wait for its
   Explorer callbacks to disarm. A timeout aborts servicing; setup never
   force-kills the host.
3. Write a new, uniquely named staging directory under `versions`, flush every
   file, and compare all three files byte-for-byte with their sources.
4. Rename the complete directory to its immutable final name on the same
   volume. The rename is the filesystem commit point.
5. Change startup and uninstall registration, then write `ActiveSlot` last as
   the registration commit marker. An in-process failure restores the recorded
   previous registration.
6. Retain the former active slot as `PreviousSlot`. `--rollback` validates all
   three files, swaps active/previous registration, and uses the same Explorer
   restart boundary.

Fixed product versions are read from setup, host, and DLL. The three files in a
slot must match. An older installer cannot replace a newer active slot; an
intentional downgrade uses `--rollback` and the recorded previous slot.

A mapped DLL is never overwritten or hot-unloaded. If Explorer still maps it,
interactive setup asks before using Windows Restart Manager to restart
Explorer. Silent setup never restarts Explorer unless the caller explicitly
adds `--restart-explorer`. Declining is safe: the host remains stopped, native
Start remains available, and the registered version starts at the next sign-in
or after a manual Explorer restart.

## Uninstall and deferred cleanup

Uninstall first requests the same bounded logical disarm, then removes only the
A4S current-user startup, uninstall, and product-state registrations. It never
recursively follows reparse points and never deletes unknown files.

Because Explorer may still map the old DLL, setup writes at most one native
helper, `%TEMP%\A4SMenuCleanup.exe`. The helper waits on process handles without
polling, deletes only known files in product-owned version directories, and is
also registered in current-user `RunOnce` for recovery after sign-out. It uses
Windows 10 POSIX file-disposition semantics for best-effort self-deletion; if
that is unavailable, the one deterministic temporary path remains bounded and
is reused or replaced by a later uninstall. No command processor or shell
deletion string is used.

Known product caches (`DataCache.db`, `DataCache.tmp`, `DataCache.txt`, and
`StartupLog.txt`) survive install/update/repair and are removed only by explicit
uninstall. Unknown root content prevents removal of the now data-only root but
is not recursively deleted.

## Command line

The executable uses Windows error codes as process exit codes.

| Command | Behavior |
| --- | --- |
| no operation | Install if no active slot is registered; otherwise repair/update. |
| `--install` | Install the embedded version for the current user. |
| `--repair` or `--update` | Validate and atomically redeploy/register the embedded version. |
| `--uninstall` | Logically disarm, unregister, and schedule safe known-file cleanup. |
| `--rollback` | Restore the validated recorded previous slot. |
| `--silent`, `/quiet`, or `/s` | Suppress all prompts. |
| `--restart-explorer` | Explicitly authorize an Explorer restart when required. |
| `--version` | Print version and exit without servicing. |
| `--verify` | Validate embedded payloads and exit without servicing. |

`--extract-test <new-directory>` and the cleanup/wait switches are internal
test/servicing commands. Extraction requires a non-existing directory and does
not inspect or change installation registry state.

Examples:

```powershell
& .\A4SMenuSetup.exe --install --silent
& .\A4SMenuSetup.exe --update --silent
& .\A4SMenuSetup.exe --rollback --silent
& .\A4SMenuSetup.exe --uninstall --silent
```

## Non-installing validation

`tools/Test-A4SSetup.ps1` does not install the product. It proves:

- the distributable stage contains exactly one regular x64 setup executable;
- setup, host, and DLL have matching product versions;
- embedded resource hashes equal the exact runtime-stage hashes;
- setup imports only its reviewed Windows system dependencies;
- `--version`, `--verify`, and temporary extraction terminate successfully;
- extraction produces exactly setup, host, and DLL, byte-for-byte; and
- those probes leave all A4S installation registry locations unchanged.

The full `tools/Build-A4SProduct.ps1` gate builds, atomically stages, and runs
both runtime and setup validation. Live standard-user install, Settings UI,
logon startup, upgrade/rollback, restart-consent, interrupted servicing, and
uninstall cleanup remain release-matrix tests; the static extraction gate does
not claim those Windows interactions have run.
