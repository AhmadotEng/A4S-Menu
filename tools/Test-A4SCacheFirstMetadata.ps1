[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$headerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.h'
$sourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ItemManager.cpp'

foreach ($path in @($headerPath, $sourcePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing cache-first metadata source input: $path"
    }
}

$header = Get-Content -LiteralPath $headerPath -Raw
$source = Get-Content -LiteralPath $sourcePath -Raw

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

Assert-Contract ($header -match '#ifdef\s+A4S_PRODUCT\s+ULONGLONG\s+GetFolderContentGeneration\(\s*void\s*\)\s+const;\s+#endif') `
    'the product-only folder-content generation API is missing'
$constructor = Get-CppFunctionBody -Text $source -Signature 'CItemManager::CItemManager( void )'
$generationGetter = Get-CppFunctionBody -Text $source -Signature 'ULONGLONG CItemManager::GetFolderContentGeneration( void ) const'
$generationAdvance = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::AdvanceFolderContentGeneration( void )'
$preload = Get-CppFunctionBody -Text $source -Signature 'void CItemManager::PreloadItemsThread( void )'
Assert-Contract ($constructor -match 'm_FolderContentGeneration\s*=\s*1\s*;') `
    'folder-content generation is not initialized to a nonzero value'
Assert-Contract ($generationGetter -match 'InterlockedCompareExchange64\(') `
    'folder-content generation reads are not atomic'
Assert-Contract ($generationAdvance -match 'InterlockedCompareExchange64\(') `
    'folder-content generation updates are not atomic'
Assert-Contract ($generationAdvance -match 'value\s*==\s*~0ULL\s*\?\s*1\s*:\s*value\s*\+\s*1') `
    'folder-content generation can wrap through the reserved zero value'
Assert-Contract ($source -match 'A4S_MENU_CONTENT_DIR_MASK\s*=\s*\(1U<<0\)\|\(1U<<1\)\|\(1U<<5\)\|\(1U<<6\)') `
    'the content generation mask no longer covers both Start roots, classic pins, and packaged app links'
Assert-Contract ($preload -match 'dirMask\s*&\s*A4S_MENU_CONTENT_DIR_MASK[\s\S]*AdvanceFolderContentGeneration\(\)') `
    'watched menu-content notifications do not advance the generation'

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

Write-Host 'A4S cache-first metadata gates passed.'
