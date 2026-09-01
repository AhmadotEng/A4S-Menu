# A4S Plan 2 Step 2 rolled-back experiment findings

Date: 2026-09-01

## Status

The uncommitted Step 2 lifecycle/recovery experiment was rolled back in full.
The source baseline is commit `2a19eef760f8986eff8772adc901aad16f7a5e37`.
No C++, PowerShell harness, product-version, manifest, README, or existing
architecture/testing-document change from the experiment is retained. Its
isolated `build/scratch/step2-abi5` binaries are also removed.

This file is the only retained artifact from that experiment. It records ideas
for later review; it does not claim that any idea was implemented, qualified,
or accepted.

## Why the experiment was rejected

Offline source-contract checks and synthetic state transitions can find some
ownership and ordering errors, but they cannot establish real behavior for
Explorer, the taskbar, the Windows key, focus changes, lock/unlock,
sleep/resume, sign-out/sign-in, or taskbar recreation on this computer. They
must not be reported as substitutes for the owner's physical observations.

The experiment incorrectly expanded Step 2 into repeated speculative
hardening based on static audits. That departed from the agreed workflow of
testing one real interaction at a time. The same restriction applies to
Windows Sandbox or a VM: neither is an accepted qualification environment for
this product.

## Useful findings to reconsider during real testing

These are review notes, not requirements proven by the rolled-back code:

1. Native-Start suppression should be claimed only after an authenticated
   suppression-core acknowledgement. Missing, corrupt, incompatible, or
   pre-core DLL states must remain `unverified`.
2. Core readiness and full-menu readiness should remain distinct so a failed
   UI initialization cannot silently expose native Start.
3. A requested host stop should remain pending until the DLL authenticates a
   completed disarm or the owning Explorer process exits. A timeout alone is
   not proof of cleanup.
4. Every installed bootstrap or route `HHOOK` needs explicit ownership.
   `UnhookWindowsHookEx` failure must retain the handle for bounded cleanup;
   code must never forget it and install an uncontrolled duplicate.
5. A still-valid taskbar HWND is not necessarily the current taskbar. Recovery
   checks should compare stored identity with the authoritative current
   `Shell_TrayWnd`, its Start child, process ID, and thread ID.
6. A same-process taskbar thread change should not migrate full menu managers,
   owner windows, or UI state across threads. If later required by a real
   reproduced failure, consider a suppression-only quarantine and require an
   Explorer restart for full UI recovery.
7. Repeated `TaskbarCreated` events can race an in-flight recovery. Any future
   design should track the exact target being handled and must not consume a
   third or later taskbar identity without scheduling its recovery.
8. Manager, Progman, taskbar, and Start-button routes can change at different
   moments. A future suppression claim should be based on one final validated
   snapshot and must become `unverified` if that snapshot cannot be proven.
9. Failure to retire an obsolete hook is cleanup debt after a replacement has
   been validated; it should be retained and logged without losing ownership.
   Whether recovery can safely continue must be decided from real behavior.
10. Transient route or hook-install failures need a bounded recovery policy.
    Retry status must not claim `suppressed` before the current taskbar route
    has actually been proven.
11. Crash-loop recovery needs a physical checkpoint before any recovery
    command: lone Win and a Start-button click must open neither native Start
    nor the full A4S menu. A script cannot supply this observation.
12. Automatic launch after sign-out/sign-in belongs to the installer/startup
    step. A standalone development host cannot prove that installed-product
    behavior.

## Deferred visible issue

An orphaned black A4S backdrop window was observed after taskbar-alignment or
focus changes. It remains a documented future reproduction target. It was not
fixed as part of this experiment and should not be mixed into lifecycle work
without first reproducing it on the real desktop.

## Evidence limitations

The discarded scratch candidate compiled, and several offline source/binary
contract checks passed at intermediate points. A final static check then failed
because its expected source pattern no longer matched a refactor. None of
those results is live Explorer evidence, and none is carried forward as a Step
2 pass.

No isolated DLL-failure run, destructive Explorer crash-loop run, staging
replacement, or live-product replacement was performed during this
experiment.

## Required workflow if Step 2 is resumed

1. Start from the committed baseline above.
2. Reproduce one real interaction on the owner's current Windows session.
3. Record the exact visible result before proposing code.
4. Make one minimal, reviewable change for that reproduced issue.
5. Build separately; do not replace the accepted staged/live pair without
   explicit permission.
6. Let the owner perform the physical test and record pass/fail before moving
   to the next interaction.
7. Use static checks only as supporting diagnostics, never as the acceptance
   result.
8. Do not use Windows Sandbox or a VM for product qualification.
