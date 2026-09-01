# A4S deferred refinements

This file records accepted future refinements without interrupting the numbered
Plan 2 execution order. An entry here is not permission to implement it early.

## Exact popup centering for a centered taskbar

Status: deferred. No source change has been made.

At 1920x1080 and the current DPI, Windows reported the centered Start button at
`x=740..785`. A4S opened at `x=739..1202`, producing popup center `x=970.5`
against physical screen center `x=960`: approximately 11 physical pixels to
the right. This occurs because the popup is aligned to the Start button's left
edge rather than centered in the active monitor's work area.

When this refinement reaches the appropriate geometry/qualification work:

- for a centered taskbar, calculate the popup origin from the active monitor's
  work-area center and the final popup width;
- for a left-aligned taskbar, retain Start-button anchoring;
- clamp the result to the active monitor work area;
- recompute after DPI, resolution, monitor, work-area, or taskbar-alignment
  changes; and
- validate at 100%, 125%, 150%, and 200% scaling and on secondary monitors.

Do not implement this as a hardcoded `-11 px` offset.

## Evidence-based performance refinements after Step 3

Status: deferred because the accepted build already meets its warm-opening and
idle-CPU targets. No source change has been made.

The [2026-09-01 Step 3 live record](../testing/A4S-plan2-step3-live-2026-09-01.md)
identified only these concrete optimization candidates:

- eliminate or cache the 30 A4S-attributed registry operations recorded during
  every opening;
- cancel the one icon-loading task observed 8.57 seconds after the menu had
  closed; and
- reduce full-menu repainting so unchanged regions are not repainted.

These are not current release blockers. Implement one at a time only if a later
measurement or reproduced defect justifies its regression risk, then compare a
separately built candidate against the preserved Step 3 baseline.
