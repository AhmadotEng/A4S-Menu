[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$headerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.h'
$sourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'
$stateHeaderPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\A4SCacheState.h'
$menuSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.cpp'
$metroHeaderPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MetroLinkManager.h'
$metroSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MetroLinkManager.cpp'
$nativeGatePath = Join-Path $PSScriptRoot 'Test-A4SCacheStateNative.ps1'

foreach ($path in @($headerPath, $sourcePath, $stateHeaderPath, $menuSourcePath,
        $metroHeaderPath, $metroSourcePath, $nativeGatePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing cache-first metadata source input: $path"
    }
}

$header = Get-Content -LiteralPath $headerPath -Raw
$source = Get-Content -LiteralPath $sourcePath -Raw
$stateHeader = Get-Content -LiteralPath $stateHeaderPath -Raw
$menuSource = Get-Content -LiteralPath $menuSourcePath -Raw
$metroHeader = Get-Content -LiteralPath $metroHeaderPath -Raw
$metroSource = Get-Content -LiteralPath $metroSourcePath -Raw

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

Assert-Contract ($stateHeader -match 'struct\s+CachedMetadataAdmissionState' -and
    $stateHeader -match 'bool\s+watchBaselineReady' -and
    $stateHeader -match 'bool\s+pathCoveredByWatchIdentity' -and
    $stateHeader -match 'uint64_t\s+validatedPathGeneration' -and
    $stateHeader -match 'uint64_t\s+currentPathGeneration' -and
    $stateHeader -match 'inline\s+bool\s+CanUseCachedFileMetadata') `
    'the shared metadata-admission predicate lacks a reviewed readiness or identity input'
Assert-Contract ($helper -match 'admission\.mainThread\s*=\s*GetCurrentThreadId\(\)==m_MainThreadId' -and
    $helper -match 'admission\.forceValidation\s*=' -and
    $helper -match 'INFO_VALIDATE_FILE\|INFO_REFRESH_NOW' -and
    $helper -match 'admission\.watchBaselineReady\s*=\s*IsFolderWatchBaselineReady\(\)' -and
    $helper -match 'admission\.entryStable\s*=\s*!info\.bTemp\s*&&\s*!info\.refreshFlags\s*&&\s*!info\.newPidl' -and
    $helper -match 'admission\.pathCoveredByWatchIdentity\s*=' -and
    $helper -match 'admission\.requestedFlagsComplete\s*=' -and
    $helper -match 'admission\.validatedPathGeneration\s*=\s*info\.a4sPathIdentityGeneration' -and
    $helper -match 'CanUseCachedFileMetadata\(admission\)') `
    'TryGetCachedFileMetadata does not feed every fail-closed condition to the shared predicate'
Assert-Contract ($helper -match 'const\s+ULONGLONG\s+pathGeneration\s*=\s*GetA4SPathIdentityGeneration\(\)' -and
    $helper -match 'return\s+IsFolderWatchBaselineReady\(\)\s*&&\s*GetA4SPathIdentityGeneration\(\)==pathGeneration') `
    'watch readiness and path identity are not rechecked after the protected timestamp copy'
Assert-Contract ($helper -match 'writeTime\s*=\s*info\.writestamp;[\s\S]*createTime\s*=\s*info\.createstamp;') `
    'cache hits do not reuse the atomically protected timestamps'
Assert-Contract ($header -match 'a4sPathIdentityGeneration\s*=\s*0' -and
    $header -match 'ULONGLONG\s+a4sPathIdentityGeneration') `
    'new and persisted ItemInfo records are not ineligible until real validation stamps them'

foreach ($overload in @($shellOverload, $pathOverload)) {
    Assert-Contract ($overload -match '#ifdef\s+A4S_PRODUCT[\s\S]*TryGetCachedFileMetadata\(') `
        'a GetItemInfo overload does not product-guard the cache-first call'
    Assert-Contract ($overload -match 'if\s*\(!bUseCachedFileMetadata\)[\s\S]*MenuGetFileTimestamp\(') `
        'a GetItemInfo overload can still stat a successful cache hit'
    Assert-Contract ($overload -match '!bUseCachedFileMetadata\s*&&\s*!pInfo->packagePath\.IsEmpty\(\)') `
        'a GetItemInfo overload can still stat a cached package path'
    Assert-Contract ($overload -match 'bA4SFileMetadataValidated\s*=\s*true' -and
        $overload -match 'pInfo->a4sPathIdentityGeneration\s*=' -and
        $overload -match 'GetA4SPathIdentityGeneration\(\)==a4sValidationGeneration') `
        'real timestamp validation is not bound to the current path-identity generation'
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
$requiredNotifyMask = 0x00000001 -bor 0x00000002 -bor 0x00000004 -bor
    0x00000008 -bor 0x00000010 -bor 0x00000040 -bor 0x00000100
Assert-Contract ($stateHeader -match 'constexpr\s+uint32_t\s+RequiredDirectoryNotifyFilter' -and
    $stateHeader -match 'FILE_NOTIFY_CHANGE_ATTRIBUTES' -and
    $stateHeader -match 'FILE_NOTIFY_CHANGE_SIZE' -and
    $stateHeader -match 'FILE_NOTIFY_CHANGE_CREATION' -and
    $stateHeader -match 'FILE_NOTIFY_CHANGE_SECURITY' -and
    $source -match 'FindFirstChangeNotification\(path,TRUE,[\s\S]{0,160}RequiredDirectoryNotifyFilter\(\)') `
    'the production watcher does not use the full shared metadata-change filter'
Assert-Contract ($source -match 'static_assert\(A4SCacheState::RequiredDirectoryNotifyFilter\(\)==[\s\S]{0,300}FILE_NOTIFY_CHANGE_SECURITY') `
    'the pure notify-filter contract is not tied to the exact Win32 production constants'
Assert-Contract ($requiredNotifyMask -eq 0x0000015F) `
    'the test-side expected Win32 directory notification mask drifted'

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

# Required roots become eligible only after their complete initial/reload
# enumeration succeeds. Optional roots remain explicit best-effort preloads.
$loadFolder = Get-CppFunctionBody -Text $source -Signature 'HRESULT CItemManager::LoadFolderItems( IShellItem *pFolder, int refreshFlags, int levels, TLocation location )'
$loadMetro = Get-CppFunctionBody -Text $source -Signature 'HRESULT CItemManager::LoadMetroItems( int refreshFlags )'
$metroLinks = Get-CppFunctionBody -Text $metroSource -Signature 'HRESULT GetMetroLinks( std::vector<MetroLink> &links, bool bLog, std::vector<CString> *pNonApps10 )'
Assert-Contract ($header -match 'HRESULT\s+LoadFolderItems\(' -and
    $header -match 'HRESULT\s+LoadMetroItems\(' -and
    $metroHeader -match 'HRESULT\s+GetMetroLinks\(') `
    'folder or Apps enumeration still hides success/failure behind a void API'
Assert-Contract ($loadFolder -match '!enumerator\.IsValid\(\)[\s\S]{0,160}enumerator\.GetResult\(\)' -and
    $loadFolder -match 'HRESULT_FROM_WIN32\(ERROR_CANCELLED\)' -and
    $loadFolder -match 'if\s*\(!pItemInfo\)[\s\S]{0,80}return\s+E_FAIL' -and
    $loadFolder -match 'FAILED\(attributesResult\)' -and
    $loadFolder -match 'FAILED\(recursiveResult\)' -and
    $loadFolder -match 'const\s+HRESULT\s+terminal=enumerator\.GetResult\(\)' -and
    $loadFolder -match 'terminal==S_FALSE\?S_OK') `
    'folder construction, recursion, cancellation, or terminal enumeration failure is not propagated'
Assert-Contract ($source -match 'FAILED\(hr\)\s*\|\|\s*!pFolder0' -and
    $source -match 'nextResult!=S_OK\s*\|\|\s*!child' -and
    $source -match 'nextResult!=S_OK\s*\|\|\s*!pChild0' -and
    $source -match 'FAILED\(pidlResult\)\s*\|\|\s*!pidl0') `
    'COM success-with-null folder, child, or PIDL can be mistaken for a complete enumeration'
Assert-Contract ($loadMetro -match 'const\s+HRESULT\s+linksResult=GetMetroLinks' -and
    $loadMetro -match 'FAILED\(linksResult\)' -and
    $loadMetro -match 'HRESULT_FROM_WIN32\(ERROR_CANCELLED\)' -and
    $loadMetro -match 'if\s*\(!pItemInfo\)[\s\S]{0,80}return\s+E_FAIL') `
    'Apps preload does not propagate discovery, cancellation, or item-construction failure'
Assert-Contract ($metroLinks -match 'ShGetKnownFolderItem' -and
    $metroLinks -match 'FAILED\(result\)\s*\|\|\s*!pApps' -and
    $metroLinks -match 'BindToHandler\(NULL,BHID_EnumItems' -and
    $metroLinks -match 'if\s*\(result==S_FALSE\)\s*break' -and
    $metroLinks -match 'if\s*\(result!=S_OK\s*\|\|\s*!pChild\)') `
    'Apps known-folder, enumerator construction, or terminal failure can be mistaken for success'
Assert-Contract ($stateHeader -match 'inline\s+bool\s+RequiredFolderLoadsComplete' -and
    $productPreload -match 'requestedRequiredLoadMask=dirMask&setupRequiredMask' -and
    $productPreload -match 'completedRequiredLoadMask\|=1U<<i' -and
    $productPreload -match '!bRequiredLoadsComplete' -and
    $productPreload -match 'if\s*\(bLoadedAny\s*&&\s*bRequiredLoadsComplete\)[\s\S]{0,400}SaveCacheFile\(\)') `
    'required initial/reload success is not part of baseline publication'
Assert-Contract ($productPreload -match 'Desktop is optional for A4S readiness' -and
    $requiredMask -notmatch 'WATCH_DESKTOP|WATCH_PUBLIC_DESKTOP|WATCH_TASKBAR_PINNED') `
    'optional preload failure semantics are no longer explicit'

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
    $isReady -match 'm_A4SPublishedWatchIdentityHash' -and
    $isReady -match 'm_A4SPublishedWatchConfigurationGeneration' -and
    $isReady -match 'RequiredFolderWatchesReady\(requiredMask,armedMask,[\s\S]*true,true,false\)') `
    'readiness does not atomically revalidate handles, canonical identity, and source generation'
$readyResetIndex = $revoke.IndexOf('InterlockedExchange(&m_A4SFolderWatchReady,0)', [StringComparison]::Ordinal)
$armedResetIndex = $revoke.IndexOf('InterlockedExchange(&m_A4SArmedWatchMask,0)', [StringComparison]::Ordinal)
$generationRevokeIndex = $revoke.IndexOf('AdvanceFolderContentGeneration()', [StringComparison]::Ordinal)
$pathGenerationRevokeIndex = $revoke.IndexOf('AdvanceA4SPathIdentityGeneration()', [StringComparison]::Ordinal)
Assert-Contract ($readyResetIndex -ge 0 -and $armedResetIndex -gt $readyResetIndex -and
    $generationRevokeIndex -gt $armedResetIndex -and
    $pathGenerationRevokeIndex -gt $generationRevokeIndex -and
    $revoke -match 'ResetEvent\(m_A4SFolderWatchReadyEvent\)') `
    'watch failure does not revoke readiness and advance both content and path generations'
$baselineSequence = 'AdvanceFolderContentGeneration\(\);\s*InterlockedExchange64\(&m_A4SPublishedWatchIdentityHash,[\s\S]*?\);\s*InterlockedExchange64\(&m_A4SPublishedWatchConfigurationGeneration,[\s\S]*?\);\s*InterlockedExchange\(&m_A4SArmedWatchMask,[\s\S]*?\);\s*InterlockedExchange\(&m_A4SFolderWatchReady,1\);\s*SetEvent\(m_A4SFolderWatchReadyEvent\);'
Assert-Contract ($preload -match $baselineSequence) `
    'watcher readiness is signaled before generation and canonical identity publication'
Assert-Contract ($preload -match 'setupRequiredMask' -and
    $preload -match 'armedMask\|=watchBit' -and
    $preload -match 'currentRequiredMask==setupRequiredMask' -and
    $preload -match 'pendingMask\|=watchMasks\[watch\]' -and
    $preload -match 'pendingMask&currentRequiredMask' -and
    $preload -match 'dirMask=pendingMask') `
    'required handles are not tracked or pending required/optional changes are not separated'

# Required watch handles are bound to canonical final directory identities and
# a same-mask source generation, never merely to a bitmask.
$resolveFolder = Get-CppFunctionBody -Text $source -Signature 'static HRESULT ResolveA4SCacheFolder( int index, CAbsolutePidl &pidl,'
$queryIdentity = Get-CppFunctionBody -Text $source -Signature 'static HRESULT QueryA4SDirectoryIdentity( const wchar_t *path,'
$forceReconfigure = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::ForceA4SFolderWatchReconfigure( void )'
Assert-Contract ($resolveFolder -match '!SHGetPathFromIDList\(pidl,path\)\s*\|\|\s*!path\[0\]' -and
    $resolveFolder -notmatch 'SUCCEEDED\(SHGetPathFromIDList') `
    'a failed or empty Win32 watch path can be mistaken for a successful HRESULT'
Assert-Contract ($queryIdentity -match 'CreateFile\(path,FILE_READ_ATTRIBUTES' -and
    $queryIdentity -match 'GetFileInformationByHandle\(' -and
    $queryIdentity -match 'GetFinalPathNameByHandle\(' -and
    $queryIdentity -match 'FILE_NAME_NORMALIZED\|VOLUME_NAME_NT') `
    'watch identity is not derived from the canonical final directory and stable file identity'
Assert-Contract ($productPreload -match 'QueryA4SDirectoryIdentity\([\s\S]{0,500}FindFirstChangeNotification\([\s\S]{0,500}QueryA4SDirectoryIdentity\(' -and
    $productPreload -match 'beforeIdentity==afterIdentity' -and
    $productPreload -match 'ComputeA4SRequiredWatchIdentity' -and
    $productPreload -match 'WatchConfigurationMatches\(published,observed\)') `
    'reparse/path uncertainty is not checked around handle creation, publication, and steady state'
Assert-Contract ($header -match 'm_A4SWatchConfigurationGeneration' -and
    $header -match 'm_A4SPublishedWatchConfigurationGeneration' -and
    $header -match 'm_A4SPublishedWatchIdentityHash' -and
    $stateHeader -match 'struct\s+WatchConfigurationIdentity' -and
    $stateHeader -match 'sourceGeneration!=0') `
    'same-mask path-source changes are not part of watch configuration identity'
Assert-Contract ($forceReconfigure -match 'm_A4SWatchConfigurationGeneration' -and
    $forceReconfigure -match 'RevokeA4SFolderWatchBaseline\(\)' -and
    $forceReconfigure -match 'SetEvent\(m_A4SWatchRebuildEvent\)') `
    'forced same-mask reconfiguration does not revoke and rebuild the baseline'
Assert-Contract ($menuSource -match 'if\s*\(bEnvironment\)\s*g_ItemManager\.ForceA4SFolderWatchReconfigure\(\)') `
    'environment/WM_SETTINGCHANGE invalidation does not force same-mask path re-resolution'
Assert-Contract ($preload -match 'WATCH_RETRY_MIN_MS=250' -and
    $preload -match 'WATCH_RETRY_MAX_MS=30000' -and
    $preload -match 'WATCH_IDENTITY_RECHECK_MS=30000' -and
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
        [bool] $WatchBaselineReady = $true,
        [bool] $PathCoveredByWatchIdentity = $true,
        [bool] $EntryStable = $true,
        [int] $RequestedFlags = 3,
        [int] $ValidFlags = 3,
        [UInt64] $ValidatedPathGeneration = 7,
        [UInt64] $CurrentPathGeneration = 7
    )
    if (-not $MainThread -or -not $PathPresent -or $ValidateFile -or $RefreshNow -or
        -not $WatchBaselineReady -or -not $PathCoveredByWatchIdentity -or
        -not $EntryStable) { return $false }
    return (($ValidFlags -band $RequestedFlags) -eq $RequestedFlags) -and
        $ValidatedPathGeneration -ne 0 -and
        $ValidatedPathGeneration -eq $CurrentPathGeneration
}

Assert-Contract (Test-CacheFirstDecision) 'a fully valid warm UI-thread hit was rejected'
$failClosedCases = @(
    @{ MainThread = $false },
    @{ PathPresent = $false },
    @{ ValidateFile = $true },
    @{ RefreshNow = $true },
    @{ WatchBaselineReady = $false },
    @{ PathCoveredByWatchIdentity = $false },
    @{ EntryStable = $false },
    @{ RequestedFlags = 3; ValidFlags = 1 },
    @{ ValidatedPathGeneration = [UInt64]0 },
    @{ ValidatedPathGeneration = [UInt64]6; CurrentPathGeneration = [UInt64]7 }
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
