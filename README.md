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

## Runtime boundary

The first-half staged x64 product contains exactly:

- `A4SMenuHost.exe` - the small per-session Explorer injector and reconnect
  watchdog.
- `A4SMenu.dll` - the popup menu UI, fixed environment model, search, commands,
  and interactions.

The full Open-Shell repository remains the development environment; it is not
the installed payload. The general settings/skin application, Classic
Explorer, Classic IE, updater, installer, taskbar styling, File Explorer
integration, help files, language DLLs, and preview tools are not staged.

The one-file installer is intentionally deferred to the second half. The
current first-half product boundary and Explorer lifecycle are documented in
[docs/architecture/A4S-product-first-half.md](docs/architecture/A4S-product-first-half.md).

## Product build

Build the isolated `A4SProduct|x64` solution, atomically stage the exact
two-file payload, and run the non-injecting static gate:

```powershell
.\tools\Build-A4SProduct.ps1
```

The staged product is written to `build\stage\A4SProduct`. The staging and
static gates reject extra files, non-x64 binaries, dependency drift, export or
ABI drift, mismatched product metadata, and a resident `--version` command.

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

### Explicit live lifecycle gate

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

## Validation

The first-half validation set combines accepted visual references, isolated
builds, an automated static product gate, and an explicit live lifecycle gate:

- **14 accepted StartAllBack reference images** covering **10 required-state
  entries**: nine captured states and one user-menu state that is not
  applicable to this configuration.
- Clean x64 product and retained upstream development builds: **PASS**.
- Exact two-file staging and `tools\Test-A4SProduct.ps1`: **PASS**.
- Fresh-Explorer `tools\Test-A4SProductLifecycle.ps1`: **PASS** against the
  exact staged ABI3 binaries; READY, open, close, logical disarm, host exit,
  and the expected inert DLL pin were verified.
- Manual standalone visual and interaction review at 96 DPI through
  `tools\Preview-A4SProduct.ps1 -CenterBottom`.

The measured visual and interaction contract is in
[docs/reference/StartAllBack-visual-spec.md](docs/reference/StartAllBack-visual-spec.md).
The exact toolchain, binary hashes, dependency allowlists, and current gate
results are recorded in
[docs/architecture/A4S-product-build-record.md](docs/architecture/A4S-product-build-record.md).

[A4SMENU-PHASE4.md](A4SMENU-PHASE4.md) remains the accepted UI/profile
implementation history. The first-half architecture document is authoritative
for the new product package and host lifecycle.

## Upstream

A4S Menu is derived from
[Open-Shell/Open-Shell-Menu](https://github.com/Open-Shell/Open-Shell-Menu),
originally Classic Shell by Ivo Beltchev. Upstream Open-Shell downloads do not
contain this environment-specific A4S fork.
