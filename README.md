<a href="#"><img src=/Src/Setup/OpenShell.ico width="80" align="left"/></a>

# A4S Menu

A source-level Open-Shell fork that reproduces only the popup Start menu for
the captured Windows environment. It is not a skin and does not replace the
taskbar, Start-button appearance, File Explorer, external shell context menus,
or other Windows shell surfaces.

Current source profile: `A4SMenu/phase4-source-profile/23`.

## Implemented behavior

- Fixed 463&times;443-DIP two-column layout with DPI-scaled geometry, native DWM
  chrome, and continuous wallpaper-reactive acrylic.
- Current-user pinned programs with 40-DIP rows and 32&times;32-DIP icons, plus the
  22-DIP inline All Programs tree.
- Clean two-state scrollbar with a quiet 2-pixel idle thumb, bright 6-pixel
  active thumb and arrows, and a 600-ms return to idle.
- Source-rendered search hint, query, selection, horizontal scrolling, and
  caret while retaining the native edit control as the input model.
- Fixed right-column links, including a Command Prompt action that uses the
  existing elevated-command path.
- Source-owned power flyout with connected footer highlighting, no delayed
  shell-description tooltips, and the configured Sleep-before-Restart order.
- Compact source-owned program context flyout containing only Run as
  administrator, Pin/Unpin from start menu, and Open file location.
- Context flyouts open at the clicked program and can be replaced immediately
  by left- or right-clicking another eligible pinned or All Programs entry.

## Product and package boundary

The current x64 product has two deliberately separate stages:

- `build\stage\A4SProduct` contains exactly `A4SMenuHost.exe` and
  `A4SMenu.dll` for direct development and qualification.
- `build\stage\A4SSetup` contains exactly `A4SMenuSetup.exe`, the one-file
  per-user installer with the matching host and DLL embedded as resources.

An installed immutable version slot contains `A4SMenuHost.exe`, `A4SMenu.dll`,
and a dormant `A4SMenuSetup.exe` maintenance copy. Only the host is a resident
process; the DLL runs in Explorer, and setup runs only for servicing. The full
Open-Shell repository remains the development environment and is not installed.
The general settings/skin application, Classic Explorer, Classic IE, updater,
taskbar styling, File Explorer integration, help bundle, language DLLs, and
preview tools are outside the product package.

The historical two-file milestone is recorded in
[docs/architecture/A4S-product-first-half.md](docs/architecture/A4S-product-first-half.md).
The current installer, native-input/recovery, cache, and evidence boundaries are
documented in:

- [docs/architecture/A4S-product-installer.md](docs/architecture/A4S-product-installer.md)
- [docs/architecture/A4S-native-input-recovery.md](docs/architecture/A4S-native-input-recovery.md)
- [docs/architecture/A4S-runtime-cache.md](docs/architecture/A4S-runtime-cache.md)
- [docs/architecture/A4S-second-half-requirements.md](docs/architecture/A4S-second-half-requirements.md)

## Product build

Build the isolated `A4SProduct|x64` solution, atomically stage the direct
two-file runtime and one-file setup package, and run the non-injecting gates:

```powershell
.\tools\Build-A4SProduct.ps1
```

The direct runtime is written to `build\stage\A4SProduct`; the distributable is
written to `build\stage\A4SSetup`. The build runs the product-boundary,
native-lifecycle, cache, performance-tool, recovery, installer-lifecycle,
runtime, and setup contract gates. Staging and static validation reject extra
files, non-x64 binaries, dependency or export drift, an ABI other than ABI4,
mismatched product metadata, and a resident `--version` command. These gates do
not by themselves qualify live Explorer, installer, session, or performance
behavior.

To rerun only the static gate against an existing stage:

```powershell
.\tools\Test-A4SProduct.ps1
```

This static test loads the DLL only in its probe process. It does not inject
Explorer.

### Development-only comparison preview

The retained upstream `StartMenu.exe`/`StartMenuDLL.dll` `-nohook` path is used
only for visual development and comparison. It is not the A4S product package:

```powershell
.\tools\Preview-A4SProduct.ps1 -CenterBottom
```

That wrapper builds the upstream development target and launches its standalone
preview without injecting Explorer. Its legacy output under
`build\stage\A4SMenu` must not be distributed as the product.

### Direct-runtime live lifecycle gate

After the static and visual gates pass, run the Explorer-mutating lifecycle
test only from a fresh Explorer process with no prior A4S mapping:

```powershell
.\tools\Test-A4SProductLifecycle.ps1 -AllowExplorerInjection
```

The explicit opt-in test runs the static gate first, launches the exact staged
host, confirms the exact staged DLL is mapped in the taskbar Explorer, toggles
the product menu open and closed, and requests logical `--exit`. It verifies
that the host and menu close while the deliberately pinned DLL remains mapped
but inert until Explorer exits.

The lifecycle gate refuses to start when a host or prior A4S DLL mapping is
already present. It never uses same-process `--rehook`, never force-kills the
host, and never restarts Explorer. Restart Explorer manually before repeating
the lifecycle test.

### Manual interactive test session

After restarting Explorer so no prior A4S DLL is mapped, start the exact staged
product and confirm that it reaches `READY` with:

```powershell
$menuHost = 'C:\Users\Admin\Downloads\StartAllBack-analysis-handoff\Open-Shell-Menu\build\stage\A4SProduct\A4SMenuHost.exe'

Start-Process -FilePath $menuHost
Start-Sleep -Seconds 2
& $menuHost --status
```

Keep the host running while testing the Start button and menu interactions. The
explicit toggle command is:

```powershell
& $menuHost --toggle
```

Finish the session through the supported logical disarm path:

```powershell
& $menuHost --exit
```

After `--exit`, restart Explorer before another test session. Do not force-kill
the host and do not use same-process `--rehook`.

## Validation status

The accepted UI baseline still consists of **14 StartAllBack reference images**
covering **10 required-state entries**: nine captured states and one user-menu
state that is not applicable to this configuration. The first-half build and
fresh-Explorer lifecycle results remain historical evidence for their exact
binaries; they do not qualify the current second-half build.

The second-half source and qualification harnesses are implemented. The build
gate covers product/package boundaries, ABI4 native lifecycle, cache
publication, lazy search, asynchronous Programs enumeration, trace conversion,
performance-tool safety, installer transactions, legacy-Sandbox contracts, and
failure-recovery contracts. Live performance, current-profile installation,
legacy upgrade/rollback, Windows input/session transitions, DPI/monitor rows,
and controlled Explorer-failure tests remain pending until their exact reviewed
build and evidence are recorded. See:

- [docs/testing/A4S-second-half-performance-and-stability.md](docs/testing/A4S-second-half-performance-and-stability.md)
- [docs/testing/A4S-current-profile-installer-lifecycle.md](docs/testing/A4S-current-profile-installer-lifecycle.md)
- [docs/testing/A4S-legacy-sandbox-lifecycle.md](docs/testing/A4S-legacy-sandbox-lifecycle.md)
- [docs/testing/A4S-failure-recovery.md](docs/testing/A4S-failure-recovery.md)

The measured visual and interaction contract is in
[docs/reference/StartAllBack-visual-spec.md](docs/reference/StartAllBack-visual-spec.md).
The exact toolchain, binary hashes, dependency allowlists, and results for the
historical first-half build are recorded in
[docs/architecture/A4S-product-build-record.md](docs/architecture/A4S-product-build-record.md).

[A4SMENU-PHASE4.md](A4SMENU-PHASE4.md) remains the accepted UI/profile
implementation history. Current second-half architecture and release status are
defined by the linked architecture documents and requirement ledger, not by the
historical first-half record.

## Upstream

A4S Menu is derived from
[Open-Shell/Open-Shell-Menu](https://github.com/Open-Shell/Open-Shell-Menu),
originally Classic Shell by Ivo Beltchev. Upstream Open-Shell downloads do not
contain this environment-specific A4S fork.
