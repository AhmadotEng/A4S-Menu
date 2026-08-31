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
foreach ($field in @('folderGeneration', 'policyGeneration', 'refreshGeneration', 'dpi', 'profileHash', 'modelHash', 'rootSettings')) {
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

$restore = Get-CppFunctionBody $container 'bool CMenuContainer::RestoreA4SRootItems( ULONGLONG generation )'
$publish = Get-CppFunctionBody $container 'void CMenuContainer::PublishA4SRootItems( ULONGLONG generation )'
foreach ($body in @($restore, $publish)) {
    Assert-Contract ($body -match 'item\.Clone\(\*it\)') 'a snapshot direction does not deep-clone MenuItem PIDLs'
}
Assert-Contract ($container -match 'if \(it->pItem1\) ILFree\(it->pItem1\);[\s\S]*if \(it->pItem2\) ILFree\(it->pItem2\);') `
    'cached PIDLs are not explicitly released'
Assert-Contract ($publish -match 'GetFolderContentGeneration\(\)!=generation') `
    'a snapshot can publish after watched folder content changed during construction'

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

$toggle = Get-CppFunctionBody $container 'HWND CMenuContainer::ToggleStartMenu( int taskbarId, bool bKeyboard, bool bAllPrograms )'
Assert-Contract ($toggle -match 'const bool bDiscoverA4SEnvironment=!a4sRootCache\.bEnvironmentValid') `
    'one-time policy/path discovery gate is missing'
foreach ($discovery in @(
    'SHRestricted\(REST_NOCOMMONGROUPS\)',
    'FlyoutMenuSettings',
    'GetPwrCapabilities',
    'CoCreateInstance\(CLSID_Shell',
    'ShGetKnownFolderIDList\(FOLDERID_StartMenu',
    'ShGetKnownFolderPath\(FOLDERID_StartMenu'
)) {
    Assert-Contract ($toggle -match $discovery) "expected cold discovery is missing: $discovery"
}
Assert-Contract ($toggle -match 'else\s*\{\s*path1\.Clone\(a4sRootCache\.startMenu\);\s*path2\.Clone\(a4sRootCache\.commonStartMenu\);\s*s_PinFolder=a4sRootCache\.pinFolder;\s*\}') `
    'the warm path does not restore cached Start/CommonStart PIDLs and pin folder'
Assert-Contract ($toggle -match 'else\s*\{\s*s_bHasUpdates=a4sRootCache\.bHasUpdates;\s*for \(int i=0;i<_countof\(g_StdOptions\);i\+\+\)\s*g_StdOptions\[i\]\.options=a4sRootCache\.stdOptions\[i\];\s*\}') `
    'the warm path does not restore cached power/policy standard options'

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

Write-Host 'A4S warm-root cache gates passed.'
