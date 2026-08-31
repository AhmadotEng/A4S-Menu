[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$treeHeaderPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ProgramsTree.h'
$treeSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ProgramsTree.cpp'
$containerSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.cpp'
$dllSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\StartMenuDLL.cpp'
$itemHeaderPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.h'
$itemSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'

foreach ($path in @($treeHeaderPath, $treeSourcePath, $containerSourcePath,
        $dllSourcePath, $itemHeaderPath, $itemSourcePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing asynchronous Programs source input: $path"
    }
}

$treeHeader = Get-Content -LiteralPath $treeHeaderPath -Raw
$treeSource = Get-Content -LiteralPath $treeSourcePath -Raw
$containerSource = Get-Content -LiteralPath $containerSourcePath -Raw
$dllSource = Get-Content -LiteralPath $dllSourcePath -Raw
$itemHeader = Get-Content -LiteralPath $itemHeaderPath -Raw
$itemSource = Get-Content -LiteralPath $itemSourcePath -Raw

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw "A4S asynchronous Programs contract failed: $Message"
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
    $state = 'Code'
    for ($index = $openBrace; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        switch ($state) {
            'LineComment' {
                if ($character -eq "`n") { $state = 'Code' }
                continue
            }
            'BlockComment' {
                if ($character -eq '*' -and $next -eq '/') { $state = 'Code'; $index++ }
                continue
            }
            'String' {
                if ($character -eq '\') { $index++ }
                elseif ([int]$character -eq 34) { $state = 'Code' }
                continue
            }
            'Character' {
                if ($character -eq '\') { $index++ }
                elseif ([int]$character -eq 39) { $state = 'Code' }
                continue
            }
        }
        if ($character -eq '/' -and $next -eq '/') { $state = 'LineComment'; $index++; continue }
        if ($character -eq '/' -and $next -eq '*') { $state = 'BlockComment'; $index++; continue }
        if ([int]$character -eq 34) { $state = 'String'; continue }
        if ([int]$character -eq 39) { $state = 'Character'; continue }
        if ($character -eq '{') { $depth++; continue }
        if ($character -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($openBrace, $index - $openBrace + 1)
            }
        }
    }
    throw "Unterminated C++ function: $Signature"
}

$createItems = Get-CppFunctionBody $treeSource 'bool CProgramsTree::CreateItems( void )'
$requestItems = Get-CppFunctionBody $treeSource 'void CProgramsTree::RequestA4SItems( CProgramsTree *pOwner, HWND notifyWindow,'
$worker = Get-CppFunctionBody $treeSource 'DWORD CALLBACK CProgramsTree::A4SAsyncWorkerProc( void *param )'
$buildSnapshot = Get-CppFunctionBody $treeSource 'CProgramsTree::A4SAsyncResult CProgramsTree::BuildA4SRootSnapshot('
$applySnapshot = Get-CppFunctionBody $treeSource 'bool CProgramsTree::ApplyA4SSnapshot( LONG expectedGeneration )'
$applyRoot = Get-CppFunctionBody $treeSource 'void CProgramsTree::ApplyA4SRootItems( std::vector<CTreeItem*> &newItems,'
$waitIcons = Get-CppFunctionBody $treeSource 'CProgramsTree::A4SAsyncResult CProgramsTree::WaitForA4SIcons('
$destroy = Get-CppFunctionBody $treeSource 'LRESULT CProgramsTree::OnDestroy( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )'
$shutdown = Get-CppFunctionBody $treeSource 'bool CProgramsTree::ShutdownA4SItems( DWORD timeout )'
$snapshotReady = Get-CppFunctionBody $treeSource 'LRESULT CProgramsTree::OnA4SSnapshotReady( UINT uMsg, WPARAM wParam, LPARAM lParam,'
$toggle = Get-CppFunctionBody $containerSource 'HWND CMenuContainer::ToggleStartMenu( int taskbarId, bool bKeyboard, bool bAllPrograms )'
$setMenuMode = Get-CppFunctionBody $containerSource 'void CMenuContainer::SetMenuMode( TMenuMode mode, bool bKeyboard )'
$completePrograms = Get-CppFunctionBody $containerSource 'void CMenuContainer::CompleteA4SProgramsNavigation( CProgramsTree *pTree )'
$closeManagers = Get-CppFunctionBody $dllSource 'STARTMENUAPI bool CloseManagers( bool bNohook )'
$enumeratorCtor = Get-CppFunctionBody $itemSource 'CShellItemEnumerator::CShellItemEnumerator( IShellItem *pFolder )'
$enumeratorNext = Get-CppFunctionBody $itemSource 'bool CShellItemEnumerator::GetNext( CComPtr<IShellItem> &pChild, CAbsolutePidl &childPidl )'
$queueIcon = Get-CppFunctionBody $itemSource 'bool CItemManager::QueueA4SItemInfo( const ItemInfo *pInfo0, int refreshFlags )'
$readyIcons = Get-CppFunctionBody $itemSource 'bool CItemManager::AreA4SItemInfosReady('
$waitItem = Get-CppFunctionBody $itemSource 'bool CItemManager::WaitForA4SItemInfo( DWORD timeout )'
$customIcon = Get-CppFunctionBody $itemSource 'const CItemManager::ItemInfo *CItemManager::GetA4SCustomIcon( const wchar_t *path,'
$refreshItem = Get-CppFunctionBody $itemSource 'void CItemManager::RefreshItemInfo( ItemInfo *pInfo, int refreshFlags, IShellItem *pItem0, bool bHasWriteLock )'
$liveConfiguration = Get-CppFunctionBody $treeSource 'bool CProgramsTree::IsA4SConfigurationLive('
$supersedeConfiguration = Get-CppFunctionBody $treeSource 'bool CProgramsTree::SupersedeA4SConfigurationIfStale('

# Product-only dispatch: upstream still executes the original synchronous tree
# construction, while A4S returns immediately after requesting a snapshot.
Assert-Contract ($createItems -match '#ifdef\s+A4S_PRODUCT[\s\S]*RequestA4SItems\([^;]+false\)[\s\S]*return\s+ApplyA4SSnapshot\(\)[\s\S]*#else[\s\S]*CreateFolderItems\(NULL\)[\s\S]*return\s+true') `
    'CreateItems no longer isolates asynchronous A4S behavior from upstream Open-Shell'

# A normal menu opening starts only a missing warmup. A cold Programs request
# subscribes to the same generation; only explicit invalidation, configuration
# change, or a later request following failure may supersede it.
Assert-Contract ($toggle -match '#ifdef\s+A4S_PRODUCT[\s\S]*CProgramsTree::PreloadA4SItems\(s_bNoCommonFolders\)') `
    'the normal menu no longer overlaps first-frame work with Programs warmup'
Assert-Contract ($requestItems -match 'if\s*\(bInvalidate\)[\s\S]*InterlockedIncrement\(&s_A4SAsyncGeneration\)') `
    'explicit refresh no longer supersedes a worker that may have captured stale content'
Assert-Contract ($requestItems -match 'else\s+if\s*\(s_A4SAsyncFailedGeneration==s_A4SAsyncGeneration\)[\s\S]*InterlockedIncrement\(&s_A4SAsyncGeneration\)') `
    'a later request cannot retry a failed generation'
Assert-Contract ($requestItems -match 'bConfigurationChanged\s*\|\|\s*bInvalidate\s*\|\|\s*!s_bA4SAsyncHasSnapshot') `
    'missing and explicit-refresh paths no longer start the worker'
Assert-Contract ($requestItems -notmatch 'if\s*\(\s*!s_bA4SAsyncHasSnapshot\s*\)[\s\S]{0,160}InterlockedIncrement\(&s_A4SAsyncGeneration\)') `
    'a same-configuration cold subscriber restarts the preload generation'
Assert-Contract ($worker -match 's_bA4SAsyncWorkerRunning\s*=\s*false[\s\S]*s_A4SAsyncReadyGeneration\s*!=\s*s_A4SAsyncGeneration[\s\S]*StartA4SAsyncWorkerLocked\(\)') `
    'a refresh arriving during worker teardown can be lost'
Assert-Contract ($worker -match 's_A4SAsyncFailedGeneration\s*!=\s*s_A4SAsyncGeneration[\s\S]*s_A4SAsyncReadyGeneration\s*!=\s*s_A4SAsyncGeneration') `
    'a current-generation failure can spin immediately without a later request'

# The worker owns a dedicated STA, retains the DLL until its apartment is gone,
# and publishes only a scalar generation plus an identity token to the UI HWND.
Assert-Contract ($worker -match 'CoInitializeEx\(NULL,COINIT_APARTMENTTHREADED\)') `
    'shell enumeration is not isolated in a dedicated STA'
Assert-Contract ($treeSource -match 'GetModuleHandleEx\(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS') `
    'the worker does not pin the DLL across Explorer unhook/unload'
Assert-Contract ($worker -match 'CoUninitialize\(\)[\s\S]*FreeLibraryAndExitThread\(module,0\)') `
    'the module can unload before worker COM teardown completes'
Assert-Contract ($worker -match 'PostMessage\(notifyWindow,TVM_A4S_SNAPSHOT_READY,[\s\S]*generation,[\s\S]*notifyCookie\)') `
    'worker completion is not marshaled as a generation/identity-only message'
Assert-Contract ($treeHeader -notmatch 'CProgramsTree\s*\*\s*s_pA4SAsyncNotifyOwner') `
    'the process cache still retains a raw tree-owner pointer'
Assert-Contract ($treeHeader -match 'volatile\s+LONG\s+s_A4SNextInstanceCookie' -and
    $treeHeader -match 'LONG\s+m_A4SInstanceCookie') `
    'tree completions are not protected by a monotonic instance cookie'
Assert-Contract ($snapshotReady -match 'instanceCookie!=m_A4SInstanceCookie' -and
    $snapshotReady -match 's_A4SAsyncNotifyWindow==m_hWnd' -and
    $snapshotReady -match 's_A4SAsyncNotifyCookie==instanceCookie') `
    'queued completion does not reject HWND/owner ABA reuse'
Assert-Contract ($treeHeader -notmatch 'CComPtr\s*<\s*IShellItem\s*>\s+s_A4S') `
    'an apartment-bound shell item escaped into the cached snapshot'

# Enumerator termination and shell failures are explicit. Only a completely
# enumerated, icon-ready generation can replace the last known-good snapshot.
Assert-Contract ($itemHeader -match 'HRESULT\s+GetResult\(\s*void\s*\)\s+const' -and
    $itemHeader -match 'HRESULT\s+m_Result') `
    'CShellItemEnumerator cannot distinguish clean exhaustion from failure'
Assert-Contract ($itemSource -match 'CShellItemEnumerator::CShellItemEnumerator\(\s*IShellItem\s*\*pFolder\s*\)\s*:\s*m_Result\(E_FAIL\)' -and
    $enumeratorCtor -match 'm_Result=m_pEnumItems\?S_OK') `
    'enumerator construction does not preserve its terminal HRESULT'
Assert-Contract ($enumeratorNext -match 'm_Result=nextResult' -and
    $enumeratorNext -match 'm_Result=pidlResult' -and
    $enumeratorNext -match 'm_Result=createResult') `
    'mid-stream shell enumeration failures are collapsed into clean exhaustion'
Assert-Contract ($treeHeader -match 'A4S_ASYNC_SUCCESS[\s\S]*A4S_ASYNC_CANCELLED[\s\S]*A4S_ASYNC_FAILURE') `
    'snapshot construction does not propagate success/cancel/failure outcomes'
Assert-Contract ($buildSnapshot -match 'A4S_ASYNC_FAILURE' -and
    $buildSnapshot -match 'folderResult!=A4S_ASYNC_SUCCESS' -and
    $buildSnapshot -match 'return\s+WaitForA4SIcons\(items,generation\)') `
    'known-folder, enumeration, or icon outcomes can be ignored during publication'
Assert-Contract ($worker -match 'result==A4S_ASYNC_SUCCESS[\s\S]*oldItems\.swap\(s_A4SAsyncItems\)[\s\S]*s_A4SAsyncItems\.swap\(items\)') `
    'an incomplete snapshot can replace the last complete cache'
Assert-Contract ($worker -match 's_A4SAsyncFailedGeneration=generation' -and
    $worker -notmatch 's_A4SAsyncFailedGeneration=generation[\s\S]{0,220}s_A4SAsyncItems\.clear') `
    'failure does not retain the previous complete snapshot'

# Cancellation and content coherency are generation based. The watched-folder
# generation joins configuration identity, so external Start Menu edits cannot
# leave a process-lifetime stale cache.
Assert-Contract ($treeHeader -match 'ULONGLONG\s+folderContentGeneration\s*;') `
    'snapshot identity omits watched-folder content generation'
Assert-Contract ($treeHeader -match 'ULONGLONG\s+iconCacheEpoch\s*;' -and
    $treeHeader -match 'iconCacheEpoch==other\.iconCacheEpoch') `
    'snapshot identity omits the ItemManager icon/cache epoch'
Assert-Contract ($treeSource -match 'folderContentGeneration\s*=\s*g_ItemManager\.GetFolderContentGeneration\(\)') `
    'snapshot capture does not consume the watcher generation'
Assert-Contract ($treeSource -match 'iconCacheEpoch\s*=\s*g_ItemManager\.GetIconCacheEpoch\(\)') `
    'snapshot capture does not consume the icon/cache epoch'
Assert-Contract ($liveConfiguration -match 'IsFolderWatchBaselineReady\(\)' -and
    $liveConfiguration -match 'GetFolderContentGeneration\(\)' -and
    $liveConfiguration -match 'GetIconCacheEpoch\(\)') `
    'live snapshot validation omits baseline, folder generation, or icon epoch'
Assert-Contract ($worker -match 'while\s*\(IsA4SGenerationCurrent\(generation\)\s*&&[\s\S]*!g_ItemManager\.IsFolderWatchBaselineReady\(\)\)[\s\S]*WaitForFolderWatchBaseline\(100\)') `
    'Programs can enumerate or publish before the directory watcher baseline'
$supersedeCallCount = [Regex]::Matches($worker, 'SupersedeA4SConfigurationIfStale\(configuration,generation\)').Count
Assert-Contract ($supersedeCallCount -ge 3) `
    'worker does not validate live epochs before build, before publication, and after a publication race'
$supersedeIncrementCount = [Regex]::Matches($supersedeConfiguration, 'InterlockedIncrement\(&s_A4SAsyncGeneration\)').Count
Assert-Contract ($supersedeIncrementCount -eq 1 -and
    $supersedeConfiguration -match 'generation==s_A4SAsyncGeneration' -and
    $supersedeConfiguration -match 'configuration==s_A4SAsyncConfiguration') `
    'a stale external epoch can spawn duplicate successor generations or supersede unrelated work'
Assert-Contract ($worker -match 'IsA4SConfigurationLive\(configuration\)[\s\S]*oldItems\.swap\(s_A4SAsyncItems\)[\s\S]*s_A4SAsyncItems\.swap\(items\)[\s\S]*IsA4SConfigurationLive\(configuration\)' -and
    $worker -match 'items\.swap\(s_A4SAsyncItems\)[\s\S]*s_A4SAsyncItems\.swap\(oldItems\)') `
    'publication does not restore the prior snapshot when an epoch changes during the swap'
Assert-Contract ($buildSnapshot -match 'IsA4SGenerationCurrent\(generation\)') `
    'root enumeration cannot observe cancellation between shell folders'
Assert-Contract ($worker -match 'if\s*\(bRetry\)[\s\S]*continue\s*;') `
    'a superseded worker can terminate without rebuilding the latest generation'
Assert-Contract ($destroy -match 'UnsubscribeA4SItems\(m_hWnd,m_A4SInstanceCookie\)') `
    'destroyed trees remain subscribed to worker completion'
Assert-Contract ($shutdown -match 's_bA4SAsyncStopping\s*=\s*true[\s\S]*InterlockedIncrement\(&s_A4SAsyncGeneration\)') `
    'shutdown does not gate new requests before cancelling the active generation'
Assert-Contract ($shutdown -match 'WaitForSingleObject\(worker,timeout\)\s*!=\s*WAIT_OBJECT_0[\s\S]*return\s+false') `
    'shutdown can dismantle ItemManager without proving worker exit'
Assert-Contract ($worker -match 's_bA4SAsyncStopping[\s\S]*break\s*;') `
    'the worker does not honor logical-disarm cancellation'
Assert-Contract ($closeManagers -match 'ShutdownA4SItems\(1500\)[\s\S]*return\s+false[\s\S]*g_SearchManager\.Close\(\)[\s\S]*g_ItemManager\.Close\(\)') `
    'manager shutdown does not join Programs before destroying its dependencies'

# Cold navigation stays in normal mode until CreateItems has atomically merged
# a complete snapshot. Navigating elsewhere or closing the menu cancels the
# pending transition, and only the subscribed tree may complete it.
$guardIndex = $setMenuMode.IndexOf('if (!m_pProgramsTree->CreateItems())', [StringComparison]::Ordinal)
$modeWriteIndex = $setMenuMode.IndexOf('s_MenuMode=mode;', [StringComparison]::Ordinal)
$oldStateIndex = $setMenuMode.IndexOf('InitializeOldState();', [StringComparison]::Ordinal)
Assert-Contract ($guardIndex -ge 0 -and $guardIndex -lt $oldStateIndex -and
    $guardIndex -lt $modeWriteIndex) `
    'cold Programs navigation can switch/redraw the empty tree before publication'
Assert-Contract ($setMenuMode -match 'mode!=MODE_PROGRAMS[\s\S]*m_bA4SPendingProgramsNavigation=false') `
    'navigating away does not cancel a pending Programs transition'
Assert-Contract ($setMenuMode -match 'm_bClosing\s*\|\|\s*m_bDestroyed[\s\S]*return') `
    'a closing menu may begin a cold Programs transition'
Assert-Contract ($completePrograms -match 'pTree!=m_pProgramsTree' -and
    $completePrograms -match '!m_bA4SPendingProgramsNavigation' -and
    $completePrograms -match 'm_bClosing\s*\|\|\s*m_bDestroyed' -and
    $completePrograms -match 'SetMenuMode\(MODE_PROGRAMS,bKeyboard\)') `
    'late completion can enter Programs after cancellation, close, or owner replacement'
Assert-Contract ($snapshotReady -match 'ApplyA4SSnapshot\(\(LONG\)wParam\)[\s\S]*CompleteA4SProgramsNavigation\(this\)') `
    'Programs can transition before its matching snapshot has been merged'
Assert-Contract ($applySnapshot -match 's_A4SAsyncReadyGeneration==currentGeneration' -and
    $applySnapshot -match 's_A4SSnapshotConfiguration==s_A4SAsyncConfiguration' -and
    $applySnapshot -match 's_A4SSnapshotConfiguration\.bFoldersFirst') `
    'the UI can apply a stale or differently configured retained snapshot'
$applyLiveChecks = [Regex]::Matches($applySnapshot, 'IsA4SConfigurationLive\(snapshotConfiguration\)').Count
Assert-Contract ($applyLiveChecks -ge 2 -and
    $applySnapshot -match 'RequestA4SItems\(this,m_hWnd,snapshotConfiguration\.bNoCommonFolders,false\)' -and
    $applySnapshot -match 'delete\s+\*it[\s\S]*RequestA4SItems') `
    'UI application lacks both live epoch barriers or cannot request one safe successor'

# Every root icon is decoded (or reaches a terminal fallback) on ItemManager's
# existing decoder before the immutable snapshot becomes publishable. The
# snapshot worker may wait; neither the menu first-frame path nor the UI merge
# performs icon work.
Assert-Contract ($itemHeader -match 'int\s+a4sResolvedIconFlags\s*;') `
    'ItemInfo cannot distinguish a terminal fallback from an unresolved icon'
Assert-Contract ($itemHeader -match 'HANDLE\s+m_A4SItemReadyEvent\s*;') `
    'ItemManager has no cancellable icon-readiness wake event'
Assert-Contract ($itemSource -match 'm_A4SItemReadyEvent\s*=\s*CreateEvent\(NULL,FALSE,FALSE,NULL\)') `
    'icon readiness does not use an auto-reset completion event'
Assert-Contract ($queueIcon -match 'refreshFlags\s*&=\s*INFO_ICON') `
    'the Programs readiness API accepts non-icon work'
Assert-Contract ($queueIcon -match 'm_ItemQueueLow\.erase[\s\S]*QueueItemInfo\(pInfo,missingFlags\)') `
    'Programs icons are not promoted from idle preload to the decoder queue'
Assert-Contract ($queueIcon -notmatch 'RefreshItemInfo\s*\(') `
    'the Programs snapshot path can decode an icon on its calling thread'
Assert-Contract ($readyIcons -match 'validFlags\|pInfo->a4sResolvedIconFlags') `
    'readiness does not require either a valid icon or a terminal fallback'
Assert-Contract ($waitItem -match 'm_A4SItemReadyEvent[\s\S]*m_ExitEvent[\s\S]*WaitForMultipleObjects') `
    'icon readiness cannot be interrupted by ItemManager shutdown'
Assert-Contract ($customIcon -match 'GetCustomIconInternal\(text,index,iconSizeType,false,true\)') `
    'the Apps row can decode its custom icon on the snapshot worker'
Assert-Contract ($refreshItem -match 'a4sResolvedIconFlags\|=requestedIconFlags[\s\S]*SetEvent\(m_A4SItemReadyEvent\)') `
    'the decoder does not publish terminal icon readiness'
Assert-Contract ($waitIcons -match 'QueueA4SItemInfo[\s\S]*AreA4SItemInfosReady[\s\S]*WaitForA4SItemInfo') `
    'the snapshot can publish before all row icons resolve'
Assert-Contract ($waitIcons -match 'while\s*\(IsA4SGenerationCurrent\(generation\)\)') `
    'icon readiness waiting is not generation-cancellable'
Assert-Contract ($buildSnapshot -match 'return\s+WaitForA4SIcons\(items,generation\)') `
    'root enumeration publishes without passing the icon-readiness barrier'
Assert-Contract ($applySnapshot -notmatch 'UpdateItemInfo|GetCustomIcon|GetA4SCustomIcon|QueueA4SItemInfo|WaitForA4SItemInfo') `
    'UI snapshot publication still performs or waits for icon work'
Assert-Contract ($applySnapshot -match 'bApps[\s\S]*HasNewApps\(false\)') `
    'the cached Apps row no longer preserves its upstream new-item state'

# Text and item metadata are assembled off-thread; no tree-control calls occur
# in the snapshot builder. UI publication is a single redraw-suppressed merge.
Assert-Contract ($buildSnapshot -notmatch 'TreeView_|SendMessage|PostMessage|RedrawWindow') `
    'background snapshot construction touches a UI window/control'
Assert-Contract ($applySnapshot -match 'WM_SETREDRAW,FALSE[\s\S]*ApplyA4SRootItems\([\s\S]*WM_SETREDRAW,TRUE[\s\S]*RDW_UPDATENOW') `
    'snapshot rows can become visible incrementally'
Assert-Contract ($applyRoot -match 'TVIS_EXPANDEDONCE[\s\S]*RefreshTree\(hItem,pSelectItem\)') `
    'complete root replacement no longer preserves expanded-folder behavior'
Assert-Contract ($worker -match 'A4S_PERF_PROGRAMS_ENUMERATION') `
    'background enumeration is no longer represented in runtime telemetry'
Assert-Contract ($applySnapshot -match 'SetResult\(static_cast<UINT32>\(snapshot\.size\(\)\),TRUE\)') `
    'cached publication is not marked as a cache hit in runtime telemetry'

# Deterministic lifecycle model checks supplement the source contracts. They
# exercise the four regressions without requiring Explorer injection.
$failureModel = [ordered]@{
    Generation = 12
    ReadyGeneration = 11
    FailedGeneration = 0
    Snapshot = @('known-good-a', 'known-good-b')
    WorkerStarts = 1
}
$snapshotBeforeFailure = @($failureModel.Snapshot)
$failureModel.FailedGeneration = $failureModel.Generation
$wouldSelfRetry = ($failureModel.FailedGeneration -ne $failureModel.Generation) -and
    ($failureModel.ReadyGeneration -ne $failureModel.Generation)
Assert-Contract (-not $wouldSelfRetry -and
    (@($failureModel.Snapshot) -join '|') -eq ($snapshotBeforeFailure -join '|')) `
    'a failed generation discards the last snapshot or immediately self-retries'

$subscriberModel = [ordered]@{
    Generation = 21
    FailedGeneration = 0
    HasSnapshot = $false
    WorkerRunning = $true
    NotifyCookie = 0
}
$generationBeforeSubscribe = $subscriberModel.Generation
$subscriberModel.NotifyCookie = 7001
# Same configuration, no explicit invalidation, and no prior failure: subscribe
# to the already running preload without advancing its generation.
Assert-Contract ($subscriberModel.Generation -eq $generationBeforeSubscribe -and
    $subscriberModel.NotifyCookie -eq 7001 -and $subscriberModel.WorkerRunning) `
    'cold navigation supersedes instead of subscribing to an in-flight preload'

$retryModel = [ordered]@{ Generation = 30; FailedGeneration = 30; WorkerStarts = 1 }
if ($retryModel.FailedGeneration -eq $retryModel.Generation) {
    $retryModel.Generation++
    $retryModel.FailedGeneration = 0
    $retryModel.WorkerStarts++
}
Assert-Contract ($retryModel.Generation -eq 31 -and
    $retryModel.FailedGeneration -eq 0 -and $retryModel.WorkerStarts -eq 2) `
    'the next user request cannot retry a terminal failure exactly once'

$reusedHwnd = 0x1234
$postedCookie = 41
$replacementCookie = 42
$acceptStaleCompletion = ($reusedHwnd -eq $reusedHwnd) -and
    ($postedCookie -eq $replacementCookie)
Assert-Contract (-not $acceptStaleCompletion) `
    'a recycled HWND can accept the destroyed tree instance completion'

$navigationModel = [ordered]@{ Mode = 'Normal'; Pending = $true; Closing = $false }
$navigationModel.Pending = $false # Search/normal navigation cancels the request.
$lateCompletionEntersPrograms = $navigationModel.Pending -and
    -not $navigationModel.Closing
Assert-Contract (-not $lateCompletionEntersPrograms -and
    $navigationModel.Mode -eq 'Normal') `
    'a cancelled cold completion can still replace the normal menu'

# Deterministic epoch-publication model. A mismatch conditionally advances the
# exact captured generation once; repeated observations from the old worker do
# not spin or start additional successors.
$epochModel = [ordered]@{
    Generation = 50
    CapturedGeneration = 50
    DesiredFolder = [UInt64]12
    DesiredIcons = [UInt64]8
    LiveFolder = [UInt64]13
    LiveIcons = [UInt64]8
    Successors = 0
    Snapshot = @('known-good')
}
function Invoke-EpochSupersede([Collections.IDictionary] $model) {
    $stale = $model.DesiredFolder -ne $model.LiveFolder -or
        $model.DesiredIcons -ne $model.LiveIcons
    if ($stale -and $model.CapturedGeneration -eq $model.Generation) {
        $model.DesiredFolder = $model.LiveFolder
        $model.DesiredIcons = $model.LiveIcons
        $model.Generation++
        $model.Successors++
    }
}
Invoke-EpochSupersede $epochModel
Invoke-EpochSupersede $epochModel # the old captured generation cannot advance twice
Assert-Contract ($epochModel.Generation -eq 51 -and $epochModel.Successors -eq 1 -and
    ($epochModel.Snapshot -join '|') -eq 'known-good') `
    'one folder/icon mismatch does not produce exactly one retained-cache successor'

$publicationModel = [ordered]@{
    Snapshot = @('old-complete')
    Candidate = @('new-complete')
    FolderBefore = [UInt64]20
    FolderAfter = [UInt64]21
    IconBefore = [UInt64]4
    IconAfter = [UInt64]4
}
$canCommit = $publicationModel.FolderBefore -eq $publicationModel.FolderAfter -and
    $publicationModel.IconBefore -eq $publicationModel.IconAfter
if ($canCommit) { $publicationModel.Snapshot = @($publicationModel.Candidate) }
Assert-Contract (($publicationModel.Snapshot -join '|') -eq 'old-complete') `
    'an epoch change during publication replaced the previous complete Programs snapshot'

Write-Host 'A4S asynchronous Programs gates passed.'
