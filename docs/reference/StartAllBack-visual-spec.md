# StartAllBack popup Start menu — visual source of truth

Status: **reference set complete for Phase 4**

Captured on: 2026-08-30
Target: only the popup Start menu, including its program-row popup. The taskbar, Start button, File Explorer UI and its own context menus, and every other Windows shell surface are out of scope.

Labeled review sheet: `StartAllBack-capture-sheet.png`.

This document separates measured facts from implementation choices. The live configuration does not expose a user-account flyout or a cascading Programs flyout; those states are correctly recorded as not applicable rather than manufactured by changing the user's setup.

## User-directed A4S material override (2026-08-30)

- The captured StartAllBack measurements remain the geometry and interaction reference, but the A4S product must use one continuous, wallpaper-reactive acrylic material for every background surface inside the popup.
- Main, Programs, footer, right pane, search-results canvas, search-field interior, scrollbar gutter, and shutdown flyout must not introduce solid black or fixed-color blocks.
- The search field retains its measured bounds, radius, border, glyphs, hint/query text, caret, and selection behavior, but deliberately drops the captured fixed `#191919` fill.
- Separators, borders, text, icons, the scrollbar thumb/arrows, and temporary hover/selection overlays remain visible foreground treatments.

## User-directed A4S interaction corrections (2026-08-31)

- The popup uses normal foreground-window z-order, not persistent `WS_EX_TOPMOST`: opening it or clicking inside raises it, while activating another application may place that application above it.
- Hovering **All Programs** or **Back** paints the normal hover highlight only. Switching between those views requires an explicit mouse click or keyboard activation; no hover timer may toggle the view.
- Scroll input, thumb dragging, and scrollbar-button use must immediately show the bright 6 px thumb and arrows, then decay to the quiet 2 px idle line after interaction.
- Delayed shell-description tooltips are disabled throughout the A4S popup, including program rows, right-pane links, the shutdown control, and its flyout.
- Per the current user preference, the A4S power flyout shows Sleep before Restart. Its 117x128 px size and captured overlapping position are retained. The flyout uses the same acrylic policy and opacity as the main menu; the overlapped root pixels are temporarily excluded so the flyout samples the desktop/application once rather than double-tinting the main material.

## User-directed pinned-program and context-menu contract (2026-08-31)

- A pinned program is a large root-row variant: **40 DIP** high with a **32×32 DIP** icon. At 96 DPI the first row begins at local `y=7`, its icon occupies `x=12..43`, `y=11..42`, and its text ink begins at approximately `x=50`.
- The larger geometry applies only to root pinned programs. All Programs retains its 22 DIP rows and small icons; search results and the right pane retain their independent metrics.
- The product continues to read pins from the current user Start Menu root so it shares the user's existing StartAllBack pins. Pinning copies a source `.lnk` rather than creating a nested link; unpinning may delete only a validated direct-child `.lnk` from that root.
- Right-clicking an unpinned program shows exactly three source-owned commands, with no injected shell-extension entries or separators:
  1. Run as administrator
  2. Pin to start menu
  3. Open file location
- A pinned program uses the same order, changing only command 2 to **Unpin from start menu**.
- Program folders, blank space, search results, right-pane links, and other popup surfaces do not expose Open-Shell's generic context menu.
- The footer power control ends at x=397 DIP, three pixels left of the earlier prototype; its chevron, split hit boundary, connected highlight edge, and flyout anchor move left with that edge.
- Categorized search rows use their actual 31-DIP pitch and stop completely above the fixed See more results strip at y=362. The native edit remains the input, selection, clipboard, accessibility, and horizontal-scroll model but contributes no visible pixels. Query, hint, selection, and the blinking caret are rendered together on the parent's 32-bit buffer using the menu's ClearType-natural Segoe UI Variable Text font through `DTT_COMPOSITED`, producing grayscale coverage without child-surface erase artifacts.

## Capture matrix

| Required behavior/state | Authoritative evidence | Status |
|---|---|---|
| Normal/main menu | `states/StartAllBack-normal.png` | Captured; empty left pane is intentional |
| Left item hover/selection | `states/StartAllBack-all-programs-hover.png`, `states/StartAllBack-all-programs-selection.png`, `states/StartAllBack-all-programs-hover-user.png` | Captured |
| Right-pane hover | `states/StartAllBack-right-pane-hover.png` | Captured |
| All Programs | `states/StartAllBack-all-programs.png`, `states/StartAllBack-all-programs-user-full.png` | Captured |
| Program-folder submenu | `states/StartAllBack-inline-submenus.png` | Captured as inline expansion, which is the configured behavior |
| Search results | `states/StartAllBack-search-steam.png` | Captured |
| Shutdown hover and flyout | `states/StartAllBack-shutdown-hover-tooltip.png`, `states/StartAllBack-shutdown-menu.png` | Captured |
| Scrollbar idle/active | `states/StartAllBack-all-programs.png`, `states/StartAllBack-scrollbar-active.png` | Captured |
| Dynamic backdrop tint | `states/StartAllBack-all-programs-blue-backdrop.png` plus neutral captures | Captured |
| User-account menu | Registry/configuration and the `Admin` link in every full capture | Not applicable: current setup exposes a direct link, not a flyout |
| Shadow | `states/StartAllBack-all-programs-shadow.png` plus exterior margins in supplied captures | Vertical extent measured; use native DWM shadow and validate live |

`StartAllBack-current-menu.png` is an additional All Programs crop. `OpenShell-pass2-context.jpg` is a rejected Open-Shell comparison and is never target evidence.

## Live system and scaling

- Display: `\\.\DISPLAY1`, ViewSonic VX2719-PC-MHD.
- Mode: 1920×1080, 32-bit, 239 Hz; work area 1920×1040 with a 40 px taskbar.
- Effective DPI: `GetDpiForSystem=96`, `DeviceCaps=96×96`; Windows scaling is 100%.
- `Win8DpiScaling=0`; text scaling is 100% with no `TextScaleFactor` override.
- Theme: custom theme based on Aero `NormalColor` / `NormalSize`; apps and system use dark mode.
- DWM composition and transparency are enabled; high contrast is off.
- Accent prevalence is off. Primary accent is `#0078D4`; darker accent is `#0067C0`; legacy highlight is `#0078D7`.
- DWM colorization value: `0xC40078D4` (alpha byte 196). This is environmental context, not the menu compositor's alpha.
- StartAllBack `StartMenuAlpha=128` (50.2% setting value). Use this as the authoritative opacity input.

## Typography and system metrics

- Windows' generic menu metric is Segoe UI Regular, nominal 9 pt / 12 logical px at 96 DPI (`lfHeight=-12`), but it is not the popup renderer's source of truth.
- Captured StartAllBack popup text matches Segoe UI Variable Text, weight 400, `lfHeight=-13`, with natural glyph geometry composited to grayscale coverage. Use this captured raster treatment for the A4S popup.
- Menu/caption/status/message system font cell: 16 px.
- Icon-title font: Segoe UI Variable Text, 9.75 pt, 18 px.
- Menu-height metric: 20 px; caption height: 23 px.
- Small icon metric: 16×16; normal icon metric: 32×32.
- System scrollbar metric: 17×17; border: 1 px; frame border: 4 px.
- Menu show delay: 0 ms.
- Visible menu text has white cores (`#FFFFFF`) with grayscale antialiasing. Search hint is approximately `#999999`, subject to antialiasing.

## Outer panel and chrome

- Core popup bitmap: exactly **463×443 px** at 100% scale, `(0,0)` through `(462,442)` inclusive.
- Verified core offsets inside supplied screenshots:
  - All Programs full: `(5,3)` through `(467,445)`.
  - Normal: `(1,4)` through `(463,446)`.
  - Search: `(0,6)` through `(462,448)`.
  - Blue backdrop: `(2,4)` through `(464,446)`.
- Corner radius: **8 ±1 px**.
- Outer hairline: 1 px, usually `#3D3D3D`–`#3F3F3F`.
- The dedicated 463×459 shadow capture places the same panel at `y=8..450`, exposing 8 px above and below. Other supplied crops expose up to 7 px horizontally. A flattened crop cannot isolate a unique shadow-alpha curve; use the native DWM shadow rather than a guessed bitmap and verify its live footprint against the reference margins.

## Shared horizontal layout

- Left application surface ends at `x=260`.
- Scrollbar gutter: `x=261..275`, 15 px total:
  - left bevel `x=261`
  - trough `x=262..274`
  - right bevel `x=275`
- Right-pane transition at `x=276`; full right-pane fill starts at `x=277`.
- Nominal left item/selection rectangle: `x=8..260`, 253 px.
- Left app icon slot: **20×20 px**, `x=10..29`. Source art can contain transparent margins.
- Left text ink begins at `x=33` or `x=34`, leaving a 3–4 px visual icon/text gap.
- Right conceptual icon slot: **16×16 px**, `x=292..307`, 16 px inset from the pane start.
- Right text begins at `x=317` or `x=318`.
- Requested right glyph sources: Segoe Fluent Icons `E7EE` Admin, `F000` Documents, `E896` Downloads, `F8A6` Control Panel, `E713` Settings, and `E7EF` Run. This PC and Command Prompt retain the captured procedural designs with thinner 8× coverage rendering.
- Right separator: `y=176`, strong run approximately `x=290..447`, core near `#363636` with a soft left ramp.

## Shared vertical layout

- Left list begins at `y=7`.
- Left rows are exactly **22 px**: row `n` spans `y=(7+22n)..(28+22n)`.
- Sixteen visible rows end at `y=358`; last row is `y=337..358`.
- All Programs/Back boundary: transition `y=360`; bright 1 px line at `y=361`.
- All Programs or Back band: approximately `y=362..389`, 28 px.
- Back chevron ink: `x=20..25`, `y=371..380`; Back text ink: `x=50..75`, `y=372..381`.
- Footer bevel: `y=389..391`, with a bright divider at `y=391`.
- Footer surface: `y=392..441`; outer border at `y=442`.
- Right rows use a **40 px rhythm**:
  - Admin `y=15..54`
  - Documents `y=55..94`
  - Downloads `y=95..134`
  - This PC `y=135..174`
  - separator/padding `y=175..177`
  - Control Panel `y=178..217`
  - Settings `y=218..257`
  - Command Prompt `y=258..297`
  - Run `y=298..337`

## Normal/main state

- The normal capture has the same 463×443 frame and right rail.
- The captured StartAllBack left program area is intentionally empty: `Start_TrackProgs=0`, `StartMenuFavorites=0`, and the capture-time favorites payload contains no pinned entries. The current A4S product may display explicit current-user pins in this area; it must never synthesize MFU/recent defaults.
- `Start_MinMFU=9` reserves the empty program area.
- The bottom-left band says **All Programs** with a right-pointing chevron; selecting it switches the same pane to the All Programs list.
- Do not populate the empty area with Open-Shell recent programs or pinned defaults.

## All Programs and inline folder expansion

- `AllProgramsFlyout=0` selects the Windows 7-style in-place All Programs pane, not an XP-style cascading flyout.
- `Start_AutoCascade=0` means folders do not open merely by pausing on them.
- `states/StartAllBack-inline-submenus.png` is the authoritative submenu state. Accessibility and Apps expand inside the same 253 px list, shifting/scrolling the contents rather than creating a second popup.
- Accessibility children shown by the reference: Live captions, Magnifier, Narrator, On-Screen Keyboard, Voice access, and Windows Speech Recognition.
- Nested items are indented but retain the 22 px row rhythm and 20 px icon art.

## Scrollbar behavior — required clean line

- The gutter is visually quiet (`#202020`–`#232323`) with no bulky painted track.
- Idle thumb in the clean All Programs crop: **2 px** at `x=268..269`; solid `y=24..153`, antialiased endpoints `y=23` and `y=154`.
- Active/used thumb in `StartAllBack-scrollbar-active.png`:
  - **6 px wide**, `x=265..270`.
  - Visible `y=168..299` in panel-local coordinates, 132 px tall in that scroll position.
  - Approximately 3 px rounded caps.
  - Interior mode `#CECECE`; edge shades primarily `#C8C8C8` and `#CCCCCC`.
- Small arrow glyphs remain clean and unobtrusive at `x=264..271`, top `y=13..18`, bottom `y=350..355` in the active capture.
- Required behavior: preserve the faint 2 px idle line, expand/brighten to the 6 px rounded line during hover/scroll/drag, then return to idle 600 ms after discrete input ends. Never render a conventional wide scrollbar track or square thumb.

## Footer and search box

- Search outer bounds: `x=13..269`, `y=404..429`, exactly **257×26 px**.
- Border: about `#4B4F50`–`#4E5053`, 1 px, 3–4 px radius.
- Captured StartAllBack fill mode: `#191919`, materially more opaque/fixed than the glass body. The current A4S product intentionally overrides that captured material with the continuous wallpaper-reactive acrylic policy defined above.
- Empty-state magnifier: `x=18..32`, `y=409..423`, 15×15 visible pixels in a 16 px cell.
- The bright vertical at `x=44`, `y=408..424` is the focused empty-edit **caret**, not a decorative divider. It must blink and follow focus.
- Search hint begins at `x≈51/52`.
- Power glyph: `x=290..305`, `y=409..424`, 16×16.
- Shutdown text ink: `x=311..371`, `y=412..421`.
- Shutdown chevron: `x=387..392`, `y=412..421`.

## Search-results state

- Core panel remains 463×443; normal columns are replaced by one full-width results surface above the footer.
- Query in the reference: `steam`.
- Category title: **Programs**.
- Selected Steam result rounded rectangle is approximately `x=20..452`, local `y=44..70`, **433×27 px**.
- Result list: Steam, Steam Support Center, SteamTools, Uninstall SteamTools.
- **See more results** is anchored immediately above the footer divider.
- Search box retains `x=13..269`, `y=404..429`; the clear-X glyph replaces the magnifier.
- Query caret is exactly local `x=79`, `y=408..424`, 1×17 px in the captured blink phase.

## Hover, selection, and reveal

- Selection hit targets retain their full nominal item rectangles, but every visible A4S hover/selection fill is inset exactly 1 physical pixel on all four sides, with 1–2 px rounded antialiasing.
- Measured core is approximately `#414244` over `#27282A`, broadly consistent with a 12% white overlay; that percentage is an inference, not a source alpha.
- Pointer hover additionally supports a Fluent blue radial reveal. In the captured sample it is centered around `(184,176)` with a faint ~108 px footprint and a measured peak near `#34638D`.
- Reveal position follows the pointer and must never be baked into a bitmap.
- Right-pane hover is a separate, wider rounded highlight. The supplied Command Prompt sample spans approximately panel-local `x=286..454`, `y=257..293`, with main modes `#404040`/`#414141`; the 16 px white glyph and text remain unchanged.

## Shutdown hover and flyout

- Hovering either half of the power control paints one connected rounded highlight across **Shut down** and its chevron. Delayed system-description tooltips are disabled.
- Opening the power flyout does not latch the root **Shut down** highlight; the connected root highlight is present only while the pointer or an active press remains over the footer control.
- Clicking the chevron opens a **117×128 px** flyout, captured at screenshot coordinates `(399,306)..(515,433)`.
- Item order is authoritative:
  1. Switch user
  2. Sign out
  3. separator
  4. Lock
  5. Sleep
  6. Restart
- Hibernate is absent because it is disabled on this system.
- Flyout uses the same dark, subtly backdrop-reactive material, small rounded chrome, white Segoe UI text, 24–25 px row rhythm, and neutral hover treatment.
- The first-row **Switch user** hover fill is trimmed by 2 DIP at the flyout's top edge, and the last-row **Restart** fill is trimmed by 2 DIP at its bottom edge; row hit targets and text positions do not move.
- The fixed right-pane **Command Prompt** entry launches through Open-Shell's existing elevated-command path on a normal click and therefore requests standard UAC consent when required.

## User-account behavior

- `HideUserFrame=1` hides the account picture.
- `Start_ShowUser=1` exposes **Admin** as a direct right-pane link to the personal folder; it has no chevron and no account flyout.
- Therefore a separate user-menu state is **not applicable** to the current setup. Do not invent one in Open-Shell.
- Session actions that do exist (Switch user and Sign out) are represented in the shutdown flyout.

## Program context flyout

- Right-clicking a pinned program or an All Programs leaf opens a source-owned compact flyout, not the native Windows `HMENU` surface.
- The command order is fixed: **Run as administrator**, **Pin/Unpin from start menu**, **Open file location**.
- At 96 DPI the popup is exactly **216x80 px**: 4 px top padding, three 24 px rows, and 4 px bottom padding.
- Row hit rectangles are `[4,4,212,28)`, `[4,28,212,52)`, and `[4,52,212,76)`; the visible hover fill retains the shared one-physical-pixel inset.
- The UAC shield is 16x16 px at popup-local `x=11`; text begins at popup-local `x=35` and uses the same composited Segoe UI Variable Text rendering as the shutdown flyout.
- The popup uses the shutdown flyout's WCA acrylic, small DWM corners, border, and native shadow. Where it overlaps the root menu, the overlap is temporarily excluded from the root so the popup samples the desktop/application once instead of inheriting the root tint.
- It follows normal menu focus behavior: it appears above the active Start menu, dismisses on Escape or an outside click, and does not remain globally topmost after another application is activated.
- While it is open, left- or right-clicking another eligible pinned or All Programs leaf consumes that complete click, closes the old popup, and opens a replacement at the newly clicked program. Clicking any ineligible surface performs an ordinary dismissal.

## Backdrop material, color, and opacity

- Neutral clean-body modes are `#272727` and `#282828`; footer modes are `#212121`–`#222222`.
- The blue-background StartAllBack capture moves body sample `(100,100)` from neutral `#282828` to `#172954`, while its search sample `(250,417)` stays `#191919`. This is a reference fact; A4S applies its documented continuous-material override to the search surface too.
- This proves a **live adaptive blurred-backdrop tint**, not a flat dark fill or static transparent bitmap.
- StartAllBack's captured search fill is more opaque/fixed than the surrounding material; this behavior is not carried into the current A4S override.
- Flattened 24-bit screenshots cannot uniquely separate blur kernel, tint, and compositor alpha. Use `StartMenuAlpha=128`, native Windows backdrop composition, and live A/B validation rather than fitting a guessed static alpha.

## Current StartAllBack configuration

- Installed version: StartAllBack 3.6.8 (`StartAllBackCfg.exe` 3.6.8.4690; DLL 3.6.8).
- Enhanced classic Start menu enabled: `Disabled=0`.
- Final capture-time registry audit: `FrameStyle=0`, `StartMenuAlpha=128`.
- `HideUserFrame=1`, `Start_ShowUser=1`, `Start_RightPaneIcons=2`.
- `Start_MinMFU=9`, `Start_LargeAllAppsIcons=0`.
- `AllProgramsFlyout=0`, `Start_AutoCascade=0`, `StartMetroAppsFolder=1`.
- `Start_NotifyNewApps=0`, `Start_TrackProgs=0`.
- Current right pane: Admin, Documents, Downloads, This PC, Control Panel, Settings, Command Prompt, Run.
- Default power action: Shut down.

## Phase 4 implementation contract

1. Build a source-level, environment-specific fork of the Open-Shell Start Menu application. This is **not a skin project**.
2. Make the main Start Menu renderer/DLL authoritative for geometry, material, painting, interaction states, icons, search, inline folders, scrollbar behavior, and the shutdown flyout.
3. Retain only the minimal executable/loader and DLL boundary required to hook the existing Start button and show this popup. Remove or compile out unrelated Open-Shell feature surfaces, skin selection, menu customization, settings pages, update plumbing, and unused shell components.
4. Keep environment constants in a small, explicit renderer profile inside the customizable DLL so future visual changes do not require restoring the general Open-Shell skin/settings system.
5. Do not change the taskbar, Start button appearance, File Explorer or its context menus, or any other shell behavior outside this popup.
6. Match the 463×443 silhouette, 8 px corners, column split, row rhythms, icon cells, type baselines, footer/search layout, inline folder expansion, two-state clean scrollbar, highlights, shutdown flyout, and backdrop-reactive material.
7. Use live composition for backdrop and native DWM shadow; do not paint flattened screenshot colors as fixed fills.
8. Keep the normal left pane empty and omit Open-Shell feature clutter that is absent from the reference.
9. Validate every captured state with matched crops and pixel/difference inspection at 96 DPI.
10. Never use the rejected Open-Shell pass as target evidence.
