[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$headerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.h'
$containerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.cpp'
$commandsPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuCommands.cpp'
$dllPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\StartMenuDLL.cpp'
$itemManagerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'

foreach ($path in @($headerPath, $containerPath, $commandsPath, $dllPath, $itemManagerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing A4S warm-root source input: $path"
    }
}

$header = Get-Content -LiteralPath $headerPath -Raw
$container = Get-Content -LiteralPath $containerPath -Raw
$commands = Get-Content -LiteralPath $commandsPath -Raw
$dll = Get-Content -LiteralPath $dllPath -Raw
$itemManager = Get-Content -LiteralPath $itemManagerPath -Raw

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        throw "A4S warm-root cache contract failed: $Message"
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
	$inLineComment = $false
	$inBlockComment = $false
	$inString = $false
	$inChar = $false
	$escaped = $false
    for ($index = $openBrace; $index -lt $Text.Length; $index++) {
		$character = $Text[$index]
		$nextCharacter = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

		if ($inLineComment) {
			if ($character -eq "`r" -or $character -eq "`n") { $inLineComment = $false }
			continue
		}
		if ($inBlockComment) {
			if ($character -eq '*' -and $nextCharacter -eq '/') {
				$inBlockComment = $false
				$index++
			}
			continue
		}
		if ($inString -or $inChar) {
			if ($escaped) { $escaped = $false; continue }
			if ($character -eq '\') { $escaped = $true; continue }
			if (($inString -and $character -eq '"') -or ($inChar -and $character -eq "'")) {
				$inString = $false
				$inChar = $false
			}
			continue
		}

		if ($character -eq '/' -and $nextCharacter -eq '/') { $inLineComment = $true; $index++; continue }
		if ($character -eq '/' -and $nextCharacter -eq '*') { $inBlockComment = $true; $index++; continue }
		if ($character -eq '"') { $inString = $true; continue }
		if ($character -eq "'") { $inChar = $true; continue }

        if ($character -eq '{') { $depth++ }
        elseif ($character -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($openBrace, $index - $openBrace + 1)
            }
        }
    }
    throw "Could not locate the closing brace for $Signature"
}

Assert-Contract ($header -match '#ifdef\s+A4S_PRODUCT[\s\S]*InvalidateA4SRootCache\(\s*bool\s+bEnvironment=false\s*\)[\s\S]*ClearA4SRootCache\(\s*void\s*\)[\s\S]*#endif') `
    'the public invalidation/lifetime API is not product-only'
Assert-Contract ($container -match '#ifdef\s+A4S_PRODUCT\s+struct\s+CMenuContainer::A4SRootCache') `
    'the root snapshot implementation is not product-only'

$keyBlock = [Regex]::Match($container, '(?s)struct Key\s*\{.*?bool operator==.*?\n\s*\}').Value
foreach ($field in @('folderGeneration', 'iconCacheEpoch', 'policyGeneration', 'refreshGeneration', 'dpi', 'profileHash', 'modelHash', 'rootSettings')) {
    Assert-Contract ($keyBlock -match [Regex]::Escape($field)) "cache key omits $field"
}

$candidate = Get-CppFunctionBody $container 'bool CMenuContainer::IsA4SRootCacheCandidate( void ) const'
foreach ($pattern in @(
    '!m_bSubMenu',
    '!m_pParent',
    '\(m_Options&CONTAINER_PROGRAMS\)!=0',
    'CONTAINER_ALLPROGRAMS',
    'CONTAINER_SEARCH',
    'CONTAINER_JUMPLIST',
    'CONTAINER_APPS',
    'CONTAINER_A4S_CONTEXT'
)) {
    Assert-Contract ($candidate -match $pattern) "normal-root scope is missing $pattern"
}
Assert-Contract ($candidate -match 'g_ItemManager\.IsFolderWatchBaselineReady\(\)') `
    'root snapshots can be used before the watched-directory baseline is armed'

$restore = Get-CppFunctionBody $container 'bool CMenuContainer::RestoreA4SRootItems( ULONGLONG folderGeneration,'
$publish = Get-CppFunctionBody $container 'void CMenuContainer::PublishA4SRootItems( ULONGLONG folderGeneration,'
$invalidate = Get-CppFunctionBody $container 'void CMenuContainer::InvalidateA4SRootCache( bool bEnvironment )'
$clearEnvironment = Get-CppFunctionBody $container 'void ClearEnvironment( void )'
foreach ($body in @($restore, $publish)) {
    Assert-Contract ($body -match 'item\.Clone\(\*it\)') 'a snapshot direction does not deep-clone MenuItem PIDLs'
    Assert-Contract ($body -match 'GetFolderContentGeneration\(\)!=folderGeneration' -and
        $body -match 'GetIconCacheEpoch\(\)!=iconCacheEpoch') `
        'a root snapshot direction omits its immediate folder/icon epoch recheck'
}
Assert-Contract ($container -match 'if \(it->pItem1\) ILFree\(it->pItem1\);[\s\S]*if \(it->pItem2\) ILFree\(it->pItem2\);') `
    'cached PIDLs are not explicitly released'
Assert-Contract ($restore -notmatch 'ClearSnapshot\(' -and $invalidate -notmatch 'ClearSnapshot\(') `
    'a cache miss or invalidation destroys the previous known-good snapshot'
Assert-Contract ($restore -match 'std::vector<MenuItem>\s+restoredItems' -and
    $restore -match 'm_Items\.swap\(restoredItems\)') `
    'restore mutates the live menu before the complete PIDL clone is validated'
$newItemsIndex = $publish.IndexOf('std::vector<MenuItem> newItems', [StringComparison]::Ordinal)
$oldItemsIndex = $publish.IndexOf('std::vector<MenuItem> oldItems', [StringComparison]::Ordinal)
$swapSnapshotIndex = $publish.IndexOf('cache.items.swap(newItems)', [StringComparison]::Ordinal)
Assert-Contract ($publish -match '!bComplete' -and $newItemsIndex -ge 0 -and
    $oldItemsIndex -gt $newItemsIndex -and $swapSnapshotIndex -gt $oldItemsIndex -and
    $publish -notmatch 'cache\.ClearSnapshot\(' -and
    $publish -match 'newItems\.swap\(cache\.items\)[\s\S]*cache\.items\.swap\(oldItems\)') `
    'publication can clear the prior snapshot before a complete replacement is ready'
Assert-Contract ($clearEnvironment -notmatch 'startMenu\.Clear|commonStartMenu\.Clear|pinFolder\.Empty') `
    'environment invalidation erases the previous complete rollback values'

$dependentFields = @(
    'm_ScrollCount', 'm_OriginalScrollCount', 'm_OriginalCount', 'm_SearchIndex',
    'm_SearchProvidersCount', 'm_SearchItemCount', 'm_ProgramButtonIndex',
    'm_ProgramTreeIndex', 'm_FolderHash[0]', 'm_FolderHash[1]', 's_ShutdownCommand'
)
foreach ($field in $dependentFields) {
    $escaped = [Regex]::Escape($field)
    Assert-Contract ($restore -match $escaped) "restore omits $field"
    Assert-Contract ($publish -match $escaped) "publish omits $field"
}

$initItems = Get-CppFunctionBody $container 'void CMenuContainer::InitItems( void )'
$restoreIndex = $initItems.IndexOf('RestoreA4SRootItems', [StringComparison]::Ordinal)
$shellIndex = $initItems.IndexOf('SHCreateItemFromIDList', [StringComparison]::Ordinal)
Assert-Contract ($restoreIndex -ge 0 -and $shellIndex -gt $restoreIndex) `
    'the warm restore does not return before shell discovery/enumeration'
Assert-Contract ($initItems -match 'pinnedScope\.SetResult\([^;]+,TRUE\);\s*return;') `
    'cache hits are not recorded and returned immediately'
Assert-Contract ($initItems -match 'm_pDropFolder\[0\]=m_pDropFolder\[1\]=NULL') `
    'warm roots can retain apartment-bound drag/drop shell objects'
Assert-Contract ($initItems -match 'bool\s+bA4SRootBuildComplete=false' -and
    $initItems -match 'bA4SRootBuildComplete=true' -and
    $initItems -match 'FAILED\(AddFirstFolder\([^;]+\)\)[\s\S]*bA4SRootBuildComplete=false' -and
    $initItems -match 'FAILED\(AddSecondFolder\([^;]+\)\)[\s\S]*bA4SRootBuildComplete=false' -and
    $initItems -match 'PublishA4SRootItems\(a4sRootGeneration,a4sRootIconEpoch,[\s\S]*bA4SRootBuildComplete\)') `
    'root construction does not fail closed across both required enumerations'
Assert-Contract ($initItems -match 'SHCreateItemFromIDList\(m_Path1\[0\][\s\S]*else[\s\S]*bA4SRootBuildComplete=false') `
    'a required root SHCreateItemFromIDList failure remains cache-eligible'

$firstFolder = Get-CppFunctionBody $container 'HRESULT CMenuContainer::AddFirstFolder( IShellItem *pFolder,'
$secondFolder = Get-CppFunctionBody $container 'HRESULT CMenuContainer::AddSecondFolder( IShellItem *pFolder,'
foreach ($folderBody in @($firstFolder, $secondFolder)) {
    Assert-Contract ($folderBody -match 'HRESULT\s+result=S_FALSE' -and
        $folderBody -match 'enumerator\.GetResult\(\)' -and
        $folderBody -match 'FAILED\(terminal\)' -and
        $folderBody -match 'return\s+result') `
        'folder enumeration does not distinguish clean S_FALSE exhaustion from failure'
    Assert-Contract ($folderBody -match 'FAILED\(hr\)\s*\|\|\s*!ignore' -and
        $folderBody -match 'FAILED\(hrFlags\)' -and
        $folderBody -match 'SUCCEEDED\(result\)\)\s*result=') `
        'folder enumeration does not propagate a required shell failure'
}

$toggle = Get-CppFunctionBody $container 'HWND CMenuContainer::ToggleStartMenu( int taskbarId, bool bKeyboard, bool bAllPrograms )'
$resolveEnvironment = Get-CppFunctionBody $container 'static bool ResolveA4SRootEnvironment( bool bAllPrograms,'
Assert-Contract ($toggle -match 'const bool bDiscoverA4SEnvironment=!a4sRootCache\.bEnvironmentValid') `
    'one-time policy/path discovery gate is missing'
foreach ($discovery in @(
    'SHRestricted\(REST_NOCOMMONGROUPS\)',
    'FlyoutMenuSettings',
    'GetPwrCapabilities',
    'CoCreateInstance\(CLSID_Shell'
)) {
    Assert-Contract ($toggle -match $discovery) "expected cold discovery is missing: $discovery"
}
foreach ($discovery in @(
    'ShGetKnownFolderIDList\(FOLDERID_StartMenu',
    'ShGetKnownFolderPath\(FOLDERID_StartMenu',
    'ShGetKnownFolderIDList\(FOLDERID_CommonStartMenu',
    'SHCreateDirectory\(NULL,path\)',
    'SHParseDisplayName\(path,NULL,&resolvedStart'
)) {
    Assert-Contract ($resolveEnvironment -match $discovery) "transactional path discovery is missing: $discovery"
}
Assert-Contract ($resolveEnvironment -match 'FAILED\(hr\)\s*\|\|' -and
    $resolveEnvironment -match 'createResult!=ERROR_SUCCESS' -and
    $resolveEnvironment -match 'FAILED\(hr\)\s*\|\|\s*!resolvedStart') `
    'known-folder, directory creation, or parse failure can be reported as a complete environment'
Assert-Contract ($toggle -match 'else\s*\{\s*path1\.Clone\(a4sRootCache\.startMenu\);\s*path2\.Clone\(a4sRootCache\.commonStartMenu\);\s*s_PinFolder=a4sRootCache\.pinFolder;\s*\}') `
    'the warm path does not restore cached Start/CommonStart PIDLs and pin folder'
Assert-Contract ($toggle -match 'else\s*\{\s*s_bHasUpdates=a4sRootCache\.bHasUpdates;\s*for \(int i=0;i<_countof\(g_StdOptions\);i\+\+\)\s*g_StdOptions\[i\]\.options=a4sRootCache\.stdOptions\[i\];\s*\}') `
    'the warm path does not restore cached power/policy standard options'
$environmentCommitCount = [Regex]::Matches($toggle, 'a4sRootCache\.bEnvironmentValid=true').Count
Assert-Contract ($environmentCommitCount -eq 1 -and
    $toggle -match 'cachedStart\s*&&\s*\(!path2\s*\|\|\s*cachedCommon\)[\s\S]*a4sRootCache\.stdOptions\[i\]=g_StdOptions\[i\]\.options[\s\S]*a4sRootCache\.bEnvironmentValid=true') `
    'environment state is published partially or through more than one commit point'

$prepareIndex = $toggle.LastIndexOf('PrepareA4SRootConfiguration', [StringComparison]::Ordinal)
$initIndex = $toggle.LastIndexOf('pStartMenu->InitItems()', [StringComparison]::Ordinal)
Assert-Contract ($prepareIndex -ge 0 -and $initIndex -gt $prepareIndex) `
    'the complete DPI/profile/model/policy configuration is not prepared before InitItems'

$refresh = Get-CppFunctionBody $container 'LRESULT CMenuContainer::OnRefresh( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )'
$invalidateIndex = $refresh.LastIndexOf('InvalidateA4SRootCache(false)', [StringComparison]::Ordinal)
$refreshInitIndex = $refresh.LastIndexOf('InitItems()', [StringComparison]::Ordinal)
Assert-Contract ($invalidateIndex -ge 0 -and $refreshInitIndex -gt $invalidateIndex) `
    'an explicit root refresh can restore the old snapshot'

foreach ($operation in @('CreatePinLink', 'RemoveA4SPinnedLink')) {
    Assert-Contract ($commands -match ("(?s)SUCCEEDED\(" + $operation + ".*?InvalidateA4SRootCache\(false\).*?PostRefreshMessage\(\)")) `
        "$operation does not invalidate before posting its explicit refresh"
}

$closeManagers = Get-CppFunctionBody $dll 'STARTMENUAPI bool CloseManagers( bool bNohook )'
$clearIndex = $closeManagers.IndexOf('ClearA4SRootCache()', [StringComparison]::Ordinal)
$managerCloseIndex = $closeManagers.IndexOf('g_ItemManager.Close()', [StringComparison]::Ordinal)
Assert-Contract ($clearIndex -ge 0 -and $managerCloseIndex -gt $clearIndex) `
    'the root snapshot is not freed before ItemManager closes'
$ownerSettingChange = Get-CppFunctionBody $dll 'LRESULT OnSettingChange( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )'
Assert-Contract ($ownerSettingChange -match 'wParam!=SPI_SETACTIVEWINDOWTRACKING') `
    'the menu''s own active-window-tracking broadcasts can discard every warm snapshot'
Assert-Contract ($ownerSettingChange -match 'InvalidateA4SRootCache\(wParam!=SPI_SETWORKAREA\)') `
    'work-area changes do not preserve the cached environment while other settings rediscover it'

$ownerColorChange = Get-CppFunctionBody $dll 'LRESULT OnColorChange( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )'
$ownerDisplayChange = Get-CppFunctionBody $dll 'LRESULT OnDisplayChange( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )'
Assert-Contract ($ownerColorChange -match 'InvalidateA4SRootCache\(false\)') `
    'color changes unnecessarily discard policy and known-folder state'
Assert-Contract ($ownerDisplayChange -match 'InvalidateA4SRootCache\(false\)') `
    'display changes unnecessarily discard policy and known-folder state'
foreach ($eventPattern in @(
    'A4S_MENU_COMMAND_SUSPEND_INPUT[\s\S]*InvalidateA4SRootCache\(true\)',
    'A4S_MENU_COMMAND_REFRESH_INPUT[\s\S]*InvalidateA4SRootCache\(true\)'
)) {
    Assert-Contract ($dll -match $eventPattern) "environment invalidation hook is missing: $eventPattern"
}

Assert-Contract ($itemManager -match 'ULONGLONG CItemManager::GetFolderContentGeneration\( void \) const') `
    'the watched folder-generation dependency is missing'

# Deterministic key model: every required dimension must reject a stale cache,
# while an identical warm key must hit.
$base = [ordered]@{
    folderGeneration = [UInt64]9
    iconCacheEpoch = [UInt64]5
    policyGeneration = 3
    refreshGeneration = 4
    dpi = 144
    profileHash = [UInt32]10
    modelHash = [UInt32]11
    rootSettings = [UInt32]12
}
function Compare-Key([Collections.IDictionary] $left, [Collections.IDictionary] $right) {
    foreach ($name in $base.Keys) {
        if ($left[$name] -ne $right[$name]) { return $false }
    }
    return $true
}
$same = [ordered]@{}
foreach ($name in $base.Keys) { $same[$name] = $base[$name] }
Assert-Contract (Compare-Key $base $same) 'an identical warm key missed'
foreach ($name in $base.Keys) {
	$changed = [ordered]@{}
	foreach ($copyName in $base.Keys) { $changed[$copyName] = $base[$copyName] }
    $changed[$name] = [UInt64]$changed[$name] + 1
    Assert-Contract (-not (Compare-Key $base $changed)) "a changed $name did not invalidate"
}

# Executable publication model: failed discovery/enumeration/clone attempts
# preserve the last complete snapshot. Only a complete candidate with matching
# folder and icon epochs replaces it.
function Invoke-RootPublicationModel {
    param(
        [Parameter(Mandatory)][string[]] $Previous,
        [Parameter(Mandatory)][string[]] $Candidate,
        [bool] $EnvironmentComplete = $true,
        [bool] $FirstFolderComplete = $true,
        [bool] $SecondFolderComplete = $true,
        [bool] $CloneComplete = $true,
        [UInt64] $CapturedFolder = 7,
        [UInt64] $LiveFolder = 7,
        [UInt64] $CapturedIcons = 4,
        [UInt64] $LiveIcons = 4
    )
    $complete = $EnvironmentComplete -and $FirstFolderComplete -and
        $SecondFolderComplete -and $CloneComplete -and
        $CapturedFolder -eq $LiveFolder -and $CapturedIcons -eq $LiveIcons
    if ($complete) { return @($Candidate) }
    return @($Previous)
}

$knownGood = @('pinned-a', 'pinned-b')
$replacement = @('new-a', 'new-b', 'new-c')
$failureCases = @(
    @{ EnvironmentComplete = $false },       # known-folder / parse discovery
    @{ FirstFolderComplete = $false },       # first enumerator or SHCreate
    @{ SecondFolderComplete = $false },      # merge enumerator or SHCreate
    @{ CloneComplete = $false },             # PIDL clone allocation
    @{ CapturedFolder = [UInt64]7; LiveFolder = [UInt64]8 },
    @{ CapturedIcons = [UInt64]4; LiveIcons = [UInt64]5 }
)
foreach ($case in $failureCases) {
    $observed = Invoke-RootPublicationModel -Previous $knownGood -Candidate $replacement @case
    Assert-Contract (($observed -join '|') -eq ($knownGood -join '|')) `
        "failed rebuild replaced the last good snapshot: $($case | ConvertTo-Json -Compress)"
}
$published = Invoke-RootPublicationModel -Previous $knownGood -Candidate $replacement
Assert-Contract (($published -join '|') -eq ($replacement -join '|')) `
    'a complete matching rebuild did not atomically replace the old snapshot'

$environmentStages = [ordered]@{
    Policy = $true
    Power = $true
    StartFolder = $true
    CommonFolder = $true
    PinPath = $true
}
foreach ($failedStage in $environmentStages.Keys) {
    $candidate = [ordered]@{}
    foreach ($stage in $environmentStages.Keys) { $candidate[$stage] = $environmentStages[$stage] }
    $candidate[$failedStage] = $false
    $eligible = -not ($candidate.Values -contains $false)
    Assert-Contract (-not $eligible) "partial environment became eligible after $failedStage failure"
}

Write-Host 'A4S warm-root cache gates passed.'
