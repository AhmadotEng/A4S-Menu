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

$createItems = Get-CppFunctionBody $treeSource 'void CProgramsTree::CreateItems( void )'
$requestItems = Get-CppFunctionBody $treeSource 'void CProgramsTree::RequestA4SItems( CProgramsTree *pOwner, HWND notifyWindow,'
$worker = Get-CppFunctionBody $treeSource 'DWORD CALLBACK CProgramsTree::A4SAsyncWorkerProc( void *param )'
$buildSnapshot = Get-CppFunctionBody $treeSource 'bool CProgramsTree::BuildA4SRootSnapshot( const A4SAsyncConfiguration &configuration,'
$applySnapshot = Get-CppFunctionBody $treeSource 'bool CProgramsTree::ApplyA4SSnapshot( LONG expectedGeneration )'
$applyRoot = Get-CppFunctionBody $treeSource 'void CProgramsTree::ApplyA4SRootItems( std::vector<CTreeItem*> &newItems,'
$waitIcons = Get-CppFunctionBody $treeSource 'bool CProgramsTree::WaitForA4SIcons( std::vector<CTreeItem> &items, LONG generation )'
$destroy = Get-CppFunctionBody $treeSource 'LRESULT CProgramsTree::OnDestroy( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )'
$shutdown = Get-CppFunctionBody $treeSource 'bool CProgramsTree::ShutdownA4SItems( DWORD timeout )'
$toggle = Get-CppFunctionBody $containerSource 'HWND CMenuContainer::ToggleStartMenu( int taskbarId, bool bKeyboard, bool bAllPrograms )'
$closeManagers = Get-CppFunctionBody $dllSource 'STARTMENUAPI bool CloseManagers( bool bNohook )'
$queueIcon = Get-CppFunctionBody $itemSource 'bool CItemManager::QueueA4SItemInfo( const ItemInfo *pInfo0, int refreshFlags )'
$readyIcons = Get-CppFunctionBody $itemSource 'bool CItemManager::AreA4SItemInfosReady('
$waitItem = Get-CppFunctionBody $itemSource 'bool CItemManager::WaitForA4SItemInfo( DWORD timeout )'
$customIcon = Get-CppFunctionBody $itemSource 'const CItemManager::ItemInfo *CItemManager::GetA4SCustomIcon( const wchar_t *path,'
$refreshItem = Get-CppFunctionBody $itemSource 'void CItemManager::RefreshItemInfo( ItemInfo *pInfo, int refreshFlags, IShellItem *pItem0, bool bHasWriteLock )'

# Product-only dispatch: upstream still executes the original synchronous tree
# construction, while A4S returns immediately after requesting a snapshot.
Assert-Contract ($createItems -match '#ifdef\s+A4S_PRODUCT[\s\S]*RequestA4SItems\([\s\S]*ApplyA4SSnapshot\(\)[\s\S]*return\s*;[\s\S]*#else[\s\S]*CreateFolderItems\(NULL\)') `
    'CreateItems no longer isolates asynchronous A4S behavior from upstream Open-Shell'

# A normal menu opening starts only a missing warmup. Entering Programs may
# refresh an existing immutable snapshot without discarding it first.
Assert-Contract ($toggle -match '#ifdef\s+A4S_PRODUCT[\s\S]*CProgramsTree::PreloadA4SItems\(s_bNoCommonFolders\)') `
    'the normal menu no longer overlaps first-frame work with Programs warmup'
Assert-Contract ($requestItems -match 'if\s*\(bRefresh\)[\s\S]*InterlockedIncrement\(&s_A4SAsyncGeneration\)') `
    'explicit refresh no longer supersedes a worker that may have captured stale content'
Assert-Contract ($requestItems -match '!s_bA4SAsyncHasSnapshot\s*\|\|\s*bRefresh') `
    'missing and explicit-refresh paths no longer start the worker'
Assert-Contract ($worker -match 's_bA4SAsyncWorkerRunning\s*=\s*false[\s\S]*s_A4SAsyncReadyGeneration\s*!=\s*s_A4SAsyncGeneration[\s\S]*StartA4SAsyncWorkerLocked\(\)') `
    'a refresh arriving during worker teardown can be lost'

# The worker owns a dedicated STA, retains the DLL until its apartment is gone,
# and publishes only a scalar generation plus an identity token to the UI HWND.
Assert-Contract ($worker -match 'CoInitializeEx\(NULL,COINIT_APARTMENTTHREADED\)') `
    'shell enumeration is not isolated in a dedicated STA'
Assert-Contract ($treeSource -match 'GetModuleHandleEx\(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS') `
    'the worker does not pin the DLL across Explorer unhook/unload'
Assert-Contract ($worker -match 'CoUninitialize\(\)[\s\S]*FreeLibraryAndExitThread\(module,0\)') `
    'the module can unload before worker COM teardown completes'
Assert-Contract ($worker -match 'PostMessage\(notifyWindow,TVM_A4S_SNAPSHOT_READY,[\s\S]*generation,[\s\S]*pNotifyOwner\)') `
    'worker completion is not marshaled as a generation/identity-only message'
Assert-Contract ($treeHeader -notmatch 'CComPtr\s*<\s*IShellItem\s*>\s+s_A4S') `
    'an apartment-bound shell item escaped into the cached snapshot'

# Cancellation and content coherency are generation based. The watched-folder
# generation joins configuration identity, so external Start Menu edits cannot
# leave a process-lifetime stale cache.
Assert-Contract ($treeHeader -match 'ULONGLONG\s+folderContentGeneration\s*;') `
    'snapshot identity omits watched-folder content generation'
Assert-Contract ($treeSource -match 'folderContentGeneration\s*=\s*g_ItemManager\.GetFolderContentGeneration\(\)') `
    'snapshot capture does not consume the watcher generation'
Assert-Contract ($buildSnapshot -match 'IsA4SGenerationCurrent\(generation\)') `
    'root enumeration cannot observe cancellation between shell folders'
Assert-Contract ($worker -match 'if\s*\(bRetry\)[\s\S]*continue\s*;') `
    'a superseded worker can terminate without rebuilding the latest generation'
Assert-Contract ($destroy -match 'UnsubscribeA4SItems\(this\)') `
    'destroyed trees remain subscribed to worker completion'
Assert-Contract ($shutdown -match 's_bA4SAsyncStopping\s*=\s*true[\s\S]*InterlockedIncrement\(&s_A4SAsyncGeneration\)') `
    'shutdown does not gate new requests before cancelling the active generation'
Assert-Contract ($shutdown -match 'WaitForSingleObject\(worker,timeout\)\s*!=\s*WAIT_OBJECT_0[\s\S]*return\s+false') `
    'shutdown can dismantle ItemManager without proving worker exit'
Assert-Contract ($worker -match 's_bA4SAsyncStopping[\s\S]*break\s*;') `
    'the worker does not honor logical-disarm cancellation'
Assert-Contract ($closeManagers -match 'ShutdownA4SItems\(1500\)[\s\S]*return\s+false[\s\S]*g_SearchManager\.Close\(\)[\s\S]*g_ItemManager\.Close\(\)') `
    'manager shutdown does not join Programs before destroying its dependencies'

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

Write-Host 'A4S asynchronous Programs gates passed.'
