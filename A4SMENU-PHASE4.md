# A4S Menu Phase 4 — source-fork contract

Phase 4 is a source-level fork of the Open-Shell Start Menu application. It is
not a `.skin7` project and it does not expose Open-Shell's general-purpose skin
or settings surfaces.

## Runtime boundary

The supported x64 runtime contains only:

- `StartMenu.exe`: a small resident launcher, single-instance controller, and
  Explorer hook bootstrap.
- `StartMenuDLL.dll`: the injected Start-menu host, fixed environment model,
  layout, input, search, commands, and all rendering.

`Lib` remains a static build dependency. `StartMenuHelper`, stock skin DLLs,
Classic Explorer, Classic IE, the updater, and Setup are outside the product.

## Scope guard

The fork owns only the popup Start menu. It must not replace or repaint the
taskbar, the Start button, File Explorer, shell context menus, or other Windows
shell UI. The native Start button is retained and only its activation is routed
to the popup menu.

## Configuration authority

`Src/StartMenu/StartMenuDLL/A4SMenuProfile.*` is the single customization
authority compiled into `StartMenuDLL.dll`. It owns:

- the fixed Win7-style two-column menu mode;
- the exact right-column model and shutdown flyout filter;
- the inline All Programs and search behavior needed by the captures;
- DPI-scaled geometry, typography, colors, adaptive material, glyph policy,
  selection, and scrollbar metrics;
- feature locks which prevent old registry values from re-enabling unrelated
  Open-Shell functionality.

The current reference constants are source values, not skin guesses:

- popup: 463x443 at 96 DPI, split at x=276;
- search: `[13,404,270,430)`;
- inline Programs tree: `[7,7,276,362)`;
- Programs/Back band: `[8,362,261,390)`;
- footer divider: y=391, footer material starts at y=392;
- WCA acrylic: state 4, flags `0x13`, tint `#202020`, alpha 128;
- native DWM 8-DIP main corners, border, and shadow, with no Win32 window
  region that could disable DWM rounding.

The legacy `MenuSkin` structure is temporarily retained as an internal render
record because the upstream layout and painter use it at hundreds of sites.
No external skin is selected or loaded by the environment build. The fixed
profile is injected before the render record is finalized. The parser and
settings editor can then be reduced without changing the visible contract.

`StartMenuDLL.dll` is the replaceable/customizable component. `StartMenu.exe`
is deliberately kept visually inert and stable; it only launches and injects
the matching DLL. Fixed English labels are embedded as `1/L10N` in the DLL, so
there is no localization INI or language DLL in the runtime directory.

Use `tools/Build-A4SMenu.ps1` to build the x64 Setup configuration and create
`build/stage/A4SMenu`. The staging script validates the PE architecture and
refuses any runtime payload other than the two supported binaries.

Use `tools/Preview-A4SMenu.ps1` for the standalone `-nohook` preview. It never
injects Explorer and does not disable or replace StartAllBack, so it is the
required visual-QA path before activation.

## Phase 4 implementation sequence

1. Remove all stock-skin project dependencies from `StartMenu.exe`.
2. Route every menu open through the compiled environment profile.
3. Lock the runtime model and suppress the settings/import/update surfaces.
4. Move the accepted search and power primitives out of skin-controlled
   options and into the environment profile.
5. Implement fixed geometry, source-owned monochrome glyphs, adaptive acrylic,
   and the clean idle/active scrollbar from the reference captures.
6. Build x64 and validate through `-nohook`; activate only after every captured
   state passes while StartAllBack remains available as the rollback path.

The rejected `Src/Skins/StartAllBack11` directory and settings XML are
intentionally excluded from this source repository. They are not build or
runtime inputs. The accepted StartAllBack reference captures and measurements
are stored in `docs/reference`.
