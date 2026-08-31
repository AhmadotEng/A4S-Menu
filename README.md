<a href="#"><img src=/Src/Setup/OpenShell.ico width="80" align="left"/></a>

# A4S Menu

A source-level Open-Shell fork that reproduces only the popup Start menu for
the captured Windows environment. It is not a skin and does not replace the
taskbar, Start-button appearance, File Explorer, external shell context menus,
or other Windows shell surfaces.

Current source profile: `A4SMenu/phase4-source-profile/23`.

## Implemented behavior

- Fixed 463×443-DIP two-column layout with DPI-scaled geometry, native DWM
  chrome, and continuous wallpaper-reactive acrylic.
- Current-user pinned programs with 40-DIP rows and 32×32-DIP icons, plus the
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

The staged x64 runtime contains exactly:

- `StartMenu.exe`
- `StartMenuDLL.dll`

The general Open-Shell settings/skin experience, Classic Explorer, Classic IE,
updater, and installer are outside this environment-specific runtime. See
[A4SMENU-PHASE4.md](A4SMENU-PHASE4.md) for the complete source-fork contract.

## Build and preview

Build the x64 runtime and stage the exact two-file payload:

```powershell
.\tools\Build-A4SMenu.ps1
```

Open the standalone comparison preview without injecting Explorer or disabling
StartAllBack:

```powershell
.\tools\Preview-A4SMenu.ps1 -CenterBottom
```

The staged runtime is written to `build\stage\A4SMenu`.

## Validation

No automated test suite is currently checked into this fork. Validation uses:

- **14 accepted StartAllBack reference images** covering **10 required-state
  entries**: nine captured states and one user-menu state that is not
  applicable to this configuration.
- A clean x64 build through `tools\Build-A4SMenu.ps1`.
- Staging checks that reject non-x64 binaries and any payload other than the
  two supported runtime files.
- Manual standalone visual and interaction review at 96 DPI through
  `tools\Preview-A4SMenu.ps1 -CenterBottom`.

The measured visual and interaction contract is in
[docs/reference/StartAllBack-visual-spec.md](docs/reference/StartAllBack-visual-spec.md).

## Upstream

A4S Menu is derived from
[Open-Shell/Open-Shell-Menu](https://github.com/Open-Shell/Open-Shell-Menu),
originally Classic Shell by Ivo Beltchev. Upstream Open-Shell downloads do not
contain this environment-specific A4S fork.
