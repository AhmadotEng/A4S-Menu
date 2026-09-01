# A4S runtime cache and deferred-work architecture

This document describes the second-half cache, preload, Programs, and search
implementation in `A4S_PRODUCT`. It records source contracts and their offline
gates; it does not claim that warm-open, disk-I/O, latency, or pop-in targets
have passed on the qualification machine.

## Opening-path boundary

The product keeps the stable menu model and reusable rendering resources warm
between openings. A root-menu snapshot may be reused only when its complete key
still matches: folder generation, icon-cache epoch, policy generation, refresh
generation, DPI, fixed-profile hash, menu-model hash, and root settings. The
snapshot is cloned for a new window; it is not exposed as mutable shared window
state. A failed rebuild or an epoch change during publication retains the last
complete snapshot instead of replacing it with a partial candidate.

The root open/close path excludes a full default-settings recomputation and a
full cache-file save for the product build. Embedded profile resources are
cached by the exact skin-type/resource-flags/DPI tuple and invalidated through
the normal profile reset. These exclusions reduce work on the path; only live
trace and system I/O evidence can prove the resulting performance requirements.

## Idle preload and metadata admission

The item manager begins shell/filesystem discovery only after a finite,
exit-event-backed quiet period. Shutdown can interrupt that wait. Preload fills
item metadata and decoded icons, prepares the watched folder baseline, and
publishes nonzero folder/path/icon generations for later root and Programs
snapshots.

A warm metadata hit is admitted only when all of the following remain true:

- it is requested on the product UI thread for a nonempty canonical path;
- neither force-validation nor immediate-refresh flags are present;
- the required folder-watch baseline is healthy, armed, and has no pending
  notification;
- the path is covered by the longest matching canonical watched root and the
  root's volume/file identity plus identity/source generations still match;
- the cached entry is stable and contains every requested metadata field; and
- the entry's validated path generation is nonzero and equals the current path
  generation.

Any uncertainty falls back to normal validation. Watch notifications include
file and directory names, attributes, size, last-write time, creation time, and
security. Required known-folder discovery, watcher wait/rearm failure, path or
root identity drift, icon invalidation, and environment-policy changes advance
or invalidate the corresponding generation. Optional preload roots may fail
without publishing false coverage; failure of a root required by the exposed
surface prevents that candidate from becoming the baseline.

## Asynchronous Programs snapshots

The Programs tree enumerates on a dedicated worker. A request captures the
complete configuration plus folder/icon epochs and a nonzero generation. An
already running request with the same configuration gains the current tree as a
subscriber rather than starting duplicate work. Navigation away, destruction,
refresh, or a changed configuration cancels/supersedes the request.

Publication is transactional: only a complete candidate whose configuration
and epochs still match can replace the last good snapshot. A stale worker may
schedule one successor generation, but cannot spin or publish. Completion is
posted with both the tree instance cookie and HWND, preventing a recycled HWND
from accepting an older tree's result. A cold Programs navigation can therefore
wait for the worker without blocking initial root-menu presentation; whether
the resulting interaction meets the visual/timing target remains a live test.

## Lazy search

Search resources are not initialized by manager startup, normal menu opening,
empty pre-search cleanup, or rank updates before search exists. The first
nonempty query performs the one initialization attempt. Success is idempotent;
failure latches a resource-free disabled state for that Explorer lifetime
instead of retrying on every keystroke. Close and ranking paths are safe before
initialization.

## Invalidation and publication rules

The shared pure decision model is in `A4SCacheState.h`. Its nonzero wrapping
epochs and fail-closed predicates are compiled into both the DLL and a native
fault-injection executable. Environment discovery publishes only after every
required power, hardware, policy, root-path, and PIDL-clone stage succeeds.
Metro/App enumeration similarly commits its link and non-app outputs together;
an error cannot leak a successful prefix.

## Offline gates and live evidence

Run the cache/source gates without injecting Explorer:

```powershell
.\tools\Test-A4SCacheStateNative.ps1
.\tools\Test-A4SCacheFirstMetadata.ps1
.\tools\Test-A4SAsyncPrograms.ps1
.\tools\Test-A4SWarmRootCache.ps1
.\tools\Test-A4SLazySearch.ps1
.\tools\Test-A4SPerformanceOptimizations.ps1
```

`Build-A4SProduct.ps1` invokes these gates as part of the aggregate product
validation. They prove the source/publication invariants and executable decision
models, not a live Explorer result. P7-P11 in the
[second-half requirement ledger](A4S-second-half-requirements.md) still need the
[custom runtime trace](../testing/A4S-runtime-trace.md), WPR/WPA file-I/O and
stack evidence, and fixed-state visual captures described by the
[performance/stability plan](../testing/A4S-second-half-performance-and-stability.md).
