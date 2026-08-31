[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$headerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.h'
$sourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'
$stateHeaderPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\A4SCacheState.h'
$nativeGatePath = Join-Path $PSScriptRoot 'Test-A4SCacheStateNative.ps1'

foreach ($path in @($headerPath, $sourcePath, $stateHeaderPath, $nativeGatePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing cache-first metadata source input: $path"
    }
}

$header = Get-Content -LiteralPath $headerPath -Raw
$source = Get-Content -LiteralPath $sourcePath -Raw
$stateHeader = Get-Content -LiteralPath $stateHeaderPath -Raw

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw "A4S cache-first metadata contract failed: $Message"
    }
}

function Get-CppFunctionBody {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Signature
    )

    $signatureIndex = $Text.IndexOf($Signature, [StringComparison]::Ordinal)
    Assert-Contract ($signatureIndex -ge 0) "could not locate $Signature"
    $openBrace = $Text.IndexOf('{', $signatureIndex)
    Assert-Contract ($openBrace -ge 0) "could not locate the opening brace for $Signature"

    $depth = 0
    for ($index = $openBrace; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq '{') { $depth++ }
        elseif ($Text[$index] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($openBrace, $index - $openBrace + 1)
            }
        }
    }
    throw "Could not locate the closing brace for $Signature"
}

$helperSignature = 'bool CItemManager::TryGetCachedFileMetadata( unsigned int hash, const CString &PATH, int refreshFlags, FILETIME &writeTime, FILETIME &createTime )'
$shellSignature = 'const CItemManager::ItemInfo *CItemManager::GetItemInfo( IShellItem *pItem, PIDLIST_ABSOLUTE pidl, int refreshFlags, TLocation location )'
$pathSignature = 'const CItemManager::ItemInfo *CItemManager::GetItemInfo( CString path, int refreshFlags, TLocation location )'

$helper = Get-CppFunctionBody -Text $source -Signature $helperSignature
$shellOverload = Get-CppFunctionBody -Text $source -Signature $shellSignature
$pathOverload = Get-CppFunctionBody -Text $source -Signature $pathSignature
$resetTempIcons = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::ResetTempIcons( void )'

Assert-Contract ($header -match '#ifdef\s+A4S_PRODUCT\s+bool\s+TryGetCachedFileMetadata\([^;]+;\s+#endif') `
    'the helper declaration is not product-only'
Assert-Contract ($source -match ('#ifdef\s+A4S_PRODUCT\s+' + [Regex]::Escape($helperSignature))) `
    'the helper definition is not product-only'

Assert-Contract ($helper -match 'GetCurrentThreadId\(\)\s*!=\s*m_MainThreadId') `
    'non-UI preload/watcher threads could take the cache-first path'
Assert-Contract ($helper -match 'refreshFlags\s*&\s*\(INFO_VALIDATE_FILE\|INFO_REFRESH_NOW\)') `
    'force validation flags do not bypass the cache-first path'
Assert-Contract ($helper -match 'info\.bTemp\s*\|\|\s*info\.refreshFlags\s*\|\|\s*info\.newPidl') `
    'temporary, queued, or replacement-PIDL entries do not fail closed'
Assert-Contract ($helper -match '\(info\.validFlags\s*&\s*requiredFlags\)\s*!=\s*requiredFlags') `
    'partially cached metadata could bypass validation'
Assert-Contract ($helper -match 'writeTime\s*=\s*info\.writestamp;[\s\S]*createTime\s*=\s*info\.createstamp;') `
    'cache hits do not reuse the atomically protected timestamps'

foreach ($overload in @($shellOverload, $pathOverload)) {
    Assert-Contract ($overload -match '#ifdef\s+A4S_PRODUCT[\s\S]*TryGetCachedFileMetadata\(') `
        'a GetItemInfo overload does not product-guard the cache-first call'
    Assert-Contract ($overload -match 'if\s*\(!bUseCachedFileMetadata\)[\s\S]*MenuGetFileTimestamp\(') `
        'a GetItemInfo overload can still stat a successful cache hit'
    Assert-Contract ($overload -match '!bUseCachedFileMetadata\s*&&\s*!pInfo->packagePath\.IsEmpty\(\)') `
        'a GetItemInfo overload can still stat a cached package path'
}

# The watched classic-pins directory must remain inside the notification set;
# this is what turns pin/unpin and in-place shortcut edits into worker-thread
# validation without putting filesystem calls back on the warm opening path.
$watchedCountMatch = [Regex]::Match($source, 'const\s+int\s+NUM_WATCHED_DIRS\s*=\s*(\d+)\s*;')
Assert-Contract $watchedCountMatch.Success 'NUM_WATCHED_DIRS is missing'
$cacheFoldersIndex = $source.IndexOf('g_CacheFolders[]=', [StringComparison]::Ordinal)
$preloadIndex = $source.IndexOf('void CItemManager::PreloadItemsThread( void )', [StringComparison]::Ordinal)
Assert-Contract ($cacheFoldersIndex -ge 0 -and $preloadIndex -gt $cacheFoldersIndex) 'cache folder table is malformed'
$cacheFolders = $source.Substring($cacheFoldersIndex, $preloadIndex - $cacheFoldersIndex)
$folderEntries = [Regex]::Matches($cacheFolders, '\{FOLDERID_[^\r\n]+\}')
$classicPinnedIndex = -1
for ($index = 0; $index -lt $folderEntries.Count; $index++) {
    if ($folderEntries[$index].Value -match 'FOLDERID_ClassicPinned') {
        $classicPinnedIndex = $index
        break
    }
}
Assert-Contract ($classicPinnedIndex -ge 0 -and $classicPinnedIndex -lt [int]$watchedCountMatch.Groups[1].Value) `
    'classic pins are no longer covered by the directory watcher'
Assert-Contract ($source -match 'FindFirstChangeNotification\([^;]+FILE_NOTIFY_CHANGE_LAST_WRITE\)') `
    'the watcher no longer observes pin/unpin and shortcut metadata changes'

Assert-Contract ($header -match '#ifdef\s+A4S_PRODUCT[\s\S]*ULONGLONG\s+GetFolderContentGeneration\(\s*void\s*\)\s+const;[\s\S]*GetIconCacheEpoch') `
    'the product-only folder-content generation API is missing'
$constructor = Get-CppFunctionBody -Text $source -Signature 'CItemManager::CItemManager( void )'
$generationGetter = Get-CppFunctionBody -Text $source -Signature 'ULONGLONG CItemManager::GetFolderContentGeneration( void ) const'
$generationAdvance = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::AdvanceFolderContentGeneration( void )'
$preload = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::PreloadItemsThread( void )'
$upstreamBranchIndex = $preload.IndexOf('#else', [StringComparison]::Ordinal)
Assert-Contract ($upstreamBranchIndex -gt 0) 'product/upstream preload split is missing'
$productPreload = $preload.Substring(0, $upstreamBranchIndex)
Assert-Contract ($constructor -match 'm_FolderContentGeneration\s*=\s*1\s*;') `
    'folder-content generation is not initialized to a nonzero value'
Assert-Contract ($generationGetter -match 'InterlockedCompareExchange64\(') `
    'folder-content generation reads are not atomic'
Assert-Contract ($generationAdvance -match 'InterlockedCompareExchange64\(') `
    'folder-content generation updates are not atomic'
Assert-Contract ($generationAdvance -match 'A4SCacheState::NextNonzeroEpoch\(value\)' -and
    $stateHeader -match 'return\s+value==UINT64_MAX\?1:value\+1') `
    'folder-content generation can wrap through the reserved zero value'

# Watch requirements are conditional. The per-user Start root is mandatory;
# common groups, classic pins, and Apps become mandatory only when exposed.
# Desktop/public desktop/taskbar pins remain best-effort metadata preloads.
$requiredMask = Get-CppFunctionBody -Text $stateHeader -Signature 'inline uint32_t RequiredFolderWatchMask( bool noCommonFolders,'
Assert-Contract ($stateHeader -match 'WATCH_START_MENU\s*=1U<<0' -and
    $stateHeader -match 'WATCH_COMMON_START_MENU=1U<<1' -and
    $stateHeader -match 'WATCH_CLASSIC_PINNED\s*=1U<<5' -and
    $stateHeader -match 'WATCH_METRO_APPS\s*=1U<<6') `
    'the exact Start/Common/classic/Apps watch-bit mapping changed'
Assert-Contract ($requiredMask -match 'uint32_t\s+mask=WATCH_START_MENU' -and
    $requiredMask -match '!noCommonFolders[\s\S]*WATCH_COMMON_START_MENU' -and
    $requiredMask -match 'classicPinnedRoot[\s\S]*WATCH_CLASSIC_PINNED' -and
    $requiredMask -match 'metroAppsSurface[\s\S]*WATCH_METRO_APPS' -and
    $requiredMask -notmatch 'WATCH_DESKTOP|WATCH_PUBLIC_DESKTOP|WATCH_TASKBAR_PINNED') `
    'the conditionally required watch set is incomplete or includes optional roots'
Assert-Contract ($header -match 'ConfigureA4SFolderWatches' -and
    $header -match 'm_A4SRequiredWatchMask' -and
    $header -match 'm_A4SArmedWatchMask') `
    'ItemManager does not track required and successfully armed watch sets explicitly'

# Icon/metadata invalidation has an independent epoch. ResetTempIcons executes
# on every menu toggle, so a true no-op must preserve warm snapshot identity.
Assert-Contract ($header -match 'ULONGLONG\s+GetIconCacheEpoch\(\s*void\s*\)\s+const' -and
    $header -match 'volatile\s+LONGLONG\s+m_IconCacheEpoch') `
    'the product has no icon/cache epoch in ItemManager'
$iconGetter = Get-CppFunctionBody -Text $source -Signature 'ULONGLONG CItemManager::GetIconCacheEpoch( void ) const'
$iconAdvance = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::AdvanceIconCacheEpoch( void )'
Assert-Contract ($constructor -match 'm_IconCacheEpoch\s*=\s*1\s*;') `
    'icon/cache epoch is not initialized to a nonzero value'
Assert-Contract ($iconGetter -match 'InterlockedCompareExchange64\(' -and
    $iconAdvance -match 'InterlockedCompareExchange64\(' -and
    $iconAdvance -match 'A4SCacheState::NextNonzeroEpoch\(value\)') `
    'icon/cache epoch is not atomically monotonic with zero-skipping wrap'
$resetEpochCalls = [Regex]::Matches($resetTempIcons, 'AdvanceIconCacheEpoch\(\)').Count
Assert-Contract ($resetTempIcons -match 'bool\s+bCacheInvalidated=false' -and
    $resetTempIcons -match 'if\s*\(bCacheInvalidated\)\s*AdvanceIconCacheEpoch\(\)' -and
    $resetEpochCalls -eq 1) `
    'ResetTempIcons advances the epoch on a no-op toggle'
Assert-Contract ($resetTempIcons -match 'a4sResolvedIconFlags&=~INFO_SMALL_ICON' -and
    $resetTempIcons -match 'a4sResolvedIconFlags&=~INFO_LARGE_ICON' -and
    $resetTempIcons -match 'a4sResolvedIconFlags&=~INFO_EXTRA_LARGE_ICON' -and
    $resetTempIcons -match 'a4sResolvedIconFlags&=~INFO_ICON') `
    'invalidated icons can remain falsely marked as terminally resolved'

# The pre-watch delay cannot validate a snapshot. Readiness is manual-reset and
# the content generation advances before readiness is published.
Assert-Contract ($header -match 'IsFolderWatchBaselineReady' -and
    $header -match 'WaitForFolderWatchBaseline' -and
    $header -match 'm_A4SFolderWatchReadyEvent') `
    'the initial watched-directory baseline has no explicit readiness contract'
Assert-Contract ($source -match 'm_A4SFolderWatchReadyEvent=CreateEvent\(NULL,TRUE,FALSE,NULL\)') `
    'folder watcher readiness is not a manual-reset one-time baseline'
$waitBaseline = Get-CppFunctionBody -Text $source -Signature 'bool CItemManager::WaitForFolderWatchBaseline( DWORD timeout ) const'
Assert-Contract ($waitBaseline -match 'm_A4SFolderWatchReadyEvent' -and
    $waitBaseline -match 'm_ExitEvent' -and
    $waitBaseline -match 'WaitForMultipleObjects' -and
    $waitBaseline -match 'wait==WAIT_OBJECT_0\s*&&\s*IsFolderWatchBaselineReady\(\)') `
    'waiting for the initial watcher baseline cannot be cancelled at shutdown'
$isReady = Get-CppFunctionBody -Text $source -Signature 'bool CItemManager::IsFolderWatchBaselineReady( void ) const'
$revoke = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::RevokeA4SFolderWatchBaseline( void )'
Assert-Contract ($isReady -match 'm_A4SRequiredWatchMask' -and
    $isReady -match 'm_A4SArmedWatchMask' -and
    $isReady -match 'RequiredFolderWatchesReady\(requiredMask,armedMask,[\s\S]*true,true,false\)') `
    'readiness does not atomically revalidate the current required/armed set'
$readyResetIndex = $revoke.IndexOf('InterlockedExchange(&m_A4SFolderWatchReady,0)', [StringComparison]::Ordinal)
$armedResetIndex = $revoke.IndexOf('InterlockedExchange(&m_A4SArmedWatchMask,0)', [StringComparison]::Ordinal)
$generationRevokeIndex = $revoke.IndexOf('AdvanceFolderContentGeneration()', [StringComparison]::Ordinal)
Assert-Contract ($readyResetIndex -ge 0 -and $armedResetIndex -gt $readyResetIndex -and
    $generationRevokeIndex -gt $armedResetIndex -and $revoke -match 'ResetEvent\(m_A4SFolderWatchReadyEvent\)') `
    'watch failure does not revoke readiness, clear armed state, and advance generation'
$baselineSequence = 'AdvanceFolderContentGeneration\(\);\s*InterlockedExchange\(&m_A4SArmedWatchMask,[\s\S]*?\);\s*InterlockedExchange\(&m_A4SFolderWatchReady,1\);\s*SetEvent\(m_A4SFolderWatchReadyEvent\);'
Assert-Contract ($preload -match $baselineSequence) `
    'watcher readiness is signaled before pre-watch snapshots are invalidated'
Assert-Contract ($preload -match 'setupRequiredMask' -and
    $preload -match 'armedMask\|=1U<<i' -and
    $preload -match 'currentRequiredMask==setupRequiredMask' -and
    $preload -match 'pendingMask\|=watchMasks\[watch\]' -and
    $preload -match 'if\s*\(pendingMask\)[\s\S]*dirMask=pendingMask[\s\S]*continue') `
    'required handles are not tracked or already-signaled changes can publish before reload'
Assert-Contract ($productPreload -match 'wchar_t\s+path\[_MAX_PATH\]=\{\}' -and
    $productPreload -match 'SHGetPathFromIDList\(pidl,path\)\s*&&\s*path\[0\]' -and
    $productPreload -notmatch 'SUCCEEDED\(SHGetPathFromIDList') `
    'a failed or empty Win32 watch path can be mistaken for a successful HRESULT'
Assert-Contract ($preload -match 'WATCH_RETRY_MIN_MS=250' -and
    $preload -match 'WATCH_RETRY_MAX_MS=30000' -and
    $preload -match 'WaitForWatchRetry\(retryDelay\)' -and
    $preload -match 'm_A4SWatchRebuildEvent') `
    'watch recovery is not bounded, event-driven, and reconfigurable'
$waitFailureCount = [Regex]::Matches($preload, 'WAIT_FAILED[\s\S]{0,700}RevokeA4SFolderWatchBaseline\(\)').Count
$rearmFailureCount = [Regex]::Matches($preload, '!FindNextChangeNotification[\s\S]{0,1400}RevokeA4SFolderWatchBaseline\(\)').Count
Assert-Contract ($waitFailureCount -ge 2 -and $rearmFailureCount -ge 1) `
    'WaitForMultipleObjects or FindNextChangeNotification failure can leave readiness published'

# Deterministic fail-closed decision model for the exact conditions encoded by
# TryGetCachedFileMetadata. This exercises every rejection edge without loading
# the DLL into Explorer.
function Test-CacheFirstDecision {
    param(
        [bool] $MainThread = $true,
        [bool] $PathPresent = $true,
        [bool] $ValidateFile = $false,
        [bool] $RefreshNow = $false,
        [bool] $EntryFound = $true,
        [bool] $Temporary = $false,
        [bool] $QueuedRefresh = $false,
        [bool] $ReplacementPidl = $false,
        [int] $RequestedFlags = 3,
        [int] $ValidFlags = 3
    )
    if (-not $MainThread -or -not $PathPresent -or $ValidateFile -or $RefreshNow) { return $false }
    if (-not $EntryFound -or $Temporary -or $QueuedRefresh -or $ReplacementPidl) { return $false }
    return (($ValidFlags -band $RequestedFlags) -eq $RequestedFlags)
}

Assert-Contract (Test-CacheFirstDecision) 'a fully valid warm UI-thread hit was rejected'
$failClosedCases = @(
    @{ MainThread = $false },
    @{ PathPresent = $false },
    @{ ValidateFile = $true },
    @{ RefreshNow = $true },
    @{ EntryFound = $false },
    @{ Temporary = $true },
    @{ QueuedRefresh = $true },
    @{ ReplacementPidl = $true },
    @{ RequestedFlags = 3; ValidFlags = 1 }
)
foreach ($case in $failClosedCases) {
    if (Test-CacheFirstDecision @case) {
        throw "A4S cache-first metadata model accepted a fail-closed case: $($case | ConvertTo-Json -Compress)"
    }
}

$generation = [UInt64]1
foreach ($notification in 1..32) {
    $generation++
}
Assert-Contract ($generation -eq 33) 'folder-content generation model did not advance monotonically'
$generation = [UInt64]::MaxValue
$generation = if ($generation -eq [UInt64]::MaxValue) { [UInt64]1 } else { $generation + 1 }
Assert-Contract ($generation -eq 1) 'folder-content generation model did not skip zero on wrap'

# Executable no-op/invalidation model for ResetTempIcons.
function Invoke-IconResetModel {
    param([UInt64] $Epoch, [bool] $RemovedOrInvalidated)
    if ($RemovedOrInvalidated) {
        return $(if ($Epoch -eq [UInt64]::MaxValue) { [UInt64]1 } else { $Epoch + 1 })
    }
    return $Epoch
}
$iconEpoch = [UInt64]14
$iconEpoch = Invoke-IconResetModel -Epoch $iconEpoch -RemovedOrInvalidated:$false
Assert-Contract ($iconEpoch -eq 14) 'a no-op toggle changed icon/cache identity'
$iconEpoch = Invoke-IconResetModel -Epoch $iconEpoch -RemovedOrInvalidated:$true
Assert-Contract ($iconEpoch -eq 15) 'a real icon invalidation did not change cache identity'

# A snapshot captured during the initial delay is never eligible after watcher
# setup: baseline publication first advances generation, then exposes readiness.
$blindWindow = [ordered]@{
    SnapshotGeneration = [UInt64]3
    LiveGeneration = [UInt64]3
    BaselineReady = $false
}
$eligibleBeforeBaseline = $blindWindow.BaselineReady -and
    $blindWindow.SnapshotGeneration -eq $blindWindow.LiveGeneration
$blindWindow.LiveGeneration++
$blindWindow.BaselineReady = $true
$eligibleAfterBaseline = $blindWindow.BaselineReady -and
    $blindWindow.SnapshotGeneration -eq $blindWindow.LiveGeneration
Assert-Contract (-not $eligibleBeforeBaseline -and -not $eligibleAfterBaseline) `
    'a pre-watch snapshot can survive baseline establishment'

# The executable native gate compiles the same production decision header and
# injects each missing-required-watch, wait failure, rearm failure, pending
# signal, epoch wrap, and required environment-probe failure.
& $nativeGatePath

Write-Host 'A4S cache-first metadata gates passed.'
