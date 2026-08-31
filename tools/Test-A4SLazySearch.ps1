[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$searchHeaderPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\SearchManager.h'
$searchSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\SearchManager.cpp'
$menuSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.cpp'
$dllSourcePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\StartMenuDLL.cpp'

foreach ($path in @($searchHeaderPath, $searchSourcePath, $menuSourcePath, $dllSourcePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing lazy-search source input: $path"
    }
}

$searchHeader = Get-Content -LiteralPath $searchHeaderPath -Raw
$searchSource = Get-Content -LiteralPath $searchSourcePath -Raw
$menuSource = Get-Content -LiteralPath $menuSourcePath -Raw
$dllSource = Get-Content -LiteralPath $dllSourcePath -Raw

function Get-CppFunctionBody {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Signature
    )

    $signatureIndex = $Source.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($signatureIndex -lt 0) {
        throw "Could not locate C++ function: $Signature"
    }
    $openIndex = $Source.IndexOf('{', $signatureIndex)
    if ($openIndex -lt 0) {
        throw "Could not locate opening brace for: $Signature"
    }

    $depth = 0
    for ($index = $openIndex; $index -lt $Source.Length; $index++) {
        switch ($Source[$index]) {
            '{' { $depth++ }
            '}' {
                $depth--
                if ($depth -eq 0) {
                    return $Source.Substring($openIndex, $index - $openIndex + 1)
                }
            }
        }
    }
    throw "Could not locate closing brace for: $Signature"
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Failure
    )
    if ($Source -notmatch $Pattern) { throw $Failure }
}

$initBody = Get-CppFunctionBody -Source $searchSource -Signature 'bool CSearchManager::Init( void )'
$beginBody = Get-CppFunctionBody -Source $searchSource -Signature 'bool CSearchManager::BeginSearch( const CString &searchText )'
$closeBody = Get-CppFunctionBody -Source $searchSource -Signature 'bool CSearchManager::Close( void )'
$closeMenuBody = Get-CppFunctionBody -Source $searchSource -Signature 'void CSearchManager::CloseMenu( void )'
$rankBody = Get-CppFunctionBody -Source $searchSource -Signature 'void CSearchManager::AddItemRank( unsigned int hash )'
$resultsBody = Get-CppFunctionBody -Source $searchSource -Signature 'void CSearchManager::GetSearchResults( SearchResults &results )'
$managersBody = Get-CppFunctionBody -Source $dllSource -Signature 'STARTMENUAPI bool InitManagers( bool bNohook )'
$updateBody = Get-CppFunctionBody -Source $menuSource -Signature 'void CMenuContainer::UpdateSearchResults( bool bForceShowAll )'

Assert-Contains $searchHeader '#ifdef\s+A4S_PRODUCT\s+bool\s+m_bInitializationFailed;\s+#endif' `
    'Search failure is not latched for the A4S product.'
Assert-Contains $initBody 'if\s*\(m_bInitializationFailed\)\s*return false;' `
    'Init does not preserve the terminal A4S search-failure latch.'
Assert-Contains $initBody 'if\s*\(m_bInitialized\)\s*return true;' `
    'Init is not idempotent.'
Assert-Contains $initBody 'm_bInitializationFailed\s*=\s*true;' `
    'Init failure does not disable later search attempts.'
Assert-Contains $managersBody '#ifndef\s+A4S_PRODUCT[\s\S]*g_SearchManager\.Init\(\)[\s\S]*#endif' `
    'A4S product activation still eagerly initializes search.'

$lazyFailureIndex = $beginBody.IndexOf('if (m_bInitializationFailed)', [StringComparison]::Ordinal)
$lazyEmptyIndex = $beginBody.IndexOf('if (searchText.IsEmpty())', [StringComparison]::Ordinal)
$lazyInitIndex = $beginBody.IndexOf('if (!Init())', [StringComparison]::Ordinal)
if ($lazyFailureIndex -lt 0 -or $lazyEmptyIndex -lt 0 -or $lazyInitIndex -lt 0 -or
    $lazyFailureIndex -gt $lazyEmptyIndex -or $lazyEmptyIndex -gt $lazyInitIndex) {
    throw 'BeginSearch does not gate initialization in failure, empty-query, nonempty-query order.'
}
Assert-Contains $closeBody 'if\s*\(!m_bInitialized\)\s*return true;' `
    'Close is unsafe before lazy initialization.'
Assert-Contains $closeMenuBody 'if\s*\(!m_bInitialized[\s\S]*m_bInitializationFailed[\s\S]*\)\s*return;' `
    'CloseMenu is unsafe before lazy initialization.'
Assert-Contains $rankBody 'if\s*\(!m_bInitialized[\s\S]*m_bInitializationFailed[\s\S]*\)\s*return;' `
    'AddItemRank can touch or initialize pre-search ranking state.'
Assert-Contains $resultsBody 'if\s*\(!m_bInitialized[\s\S]*m_bInitializationFailed[\s\S]*\)[\s\S]*results\.bResults\s*=\s*false;[\s\S]*results\.bSearching\s*=\s*false;[\s\S]*return;' `
    'GetSearchResults does not return a deterministic empty pre-search result.'
Assert-Contains $updateBody 'const bool searchStarted\s*=\s*g_SearchManager\.BeginSearch\(s_SearchResults\.currentString\);' `
    'The UI does not observe lazy search initialization failure.'
Assert-Contains $updateBody 's_SearchResults\.bSearching\s*=\s*searchStarted;' `
    'The UI can remain stuck in Searching after initialization failure.'

$eventCalls = [Regex]::Matches($searchSource, '\bCreateEvent\s*\(').Count
$threadCalls = [Regex]::Matches($searchSource, '\bCreateThread\s*\(').Count
if ($eventCalls -ne 2 -or [Regex]::Matches($initBody, '\bCreateEvent\s*\(').Count -ne 2) {
    throw 'Search event creation escaped the lazy Init boundary.'
}
if ($threadCalls -ne 1 -or [Regex]::Matches($initBody, '\bCreateThread\s*\(').Count -ne 1 -or
    $initBody -notmatch 'for\s*\([^\)]*_countof\(m_SearchThreads\)') {
    throw 'Search worker creation escaped the lazy eight-worker Init boundary.'
}

# Deterministic lifecycle model. This does not execute or inject the product;
# it exercises the resource and failure invariants enforced by the source gate.
function New-LazySearchState {
    return @{
        Initialized = $false
        Disabled = $false
        InitAttempts = 0
        Events = 0
        Workers = 0
        RanksLoaded = $false
        RankWrites = 0
    }
}

function Invoke-SearchInit {
    param([hashtable] $State, [bool] $Fail)
    if ($State.Disabled) { return $false }
    if ($State.Initialized) { return $true }
    $State.InitAttempts++
    if ($Fail) {
        $State.Disabled = $true
        return $false
    }
    $State.Events = 2
    $State.Workers = 8
    $State.RanksLoaded = $true
    $State.Initialized = $true
    return $true
}

function Invoke-BeginSearch {
    param([hashtable] $State, [string] $Text, [bool] $Fail = $false)
    if ($State.Disabled) { return $false }
    if (-not $State.Initialized) {
        if ([string]::IsNullOrEmpty($Text)) { return $true }
        return Invoke-SearchInit -State $State -Fail $Fail
    }
    return $true
}

function Invoke-AddRank {
    param([hashtable] $State)
    if ($State.Initialized) { $State.RankWrites++ }
}

function Invoke-SearchClose {
    param([hashtable] $State)
    if (-not $State.Initialized) { return }
    $State.Events = 0
    $State.Workers = 0
    $State.Initialized = $false
}

$cold = New-LazySearchState
Invoke-AddRank $cold
if ($cold.InitAttempts -ne 0 -or $cold.Events -ne 0 -or $cold.Workers -ne 0 -or $cold.RankWrites -ne 0) {
    throw 'Model: product activation/menu open/pre-search rank unexpectedly initialized search.'
}
if (-not (Invoke-BeginSearch -State $cold -Text '')) {
    throw 'Model: empty pre-search cleanup should be a successful no-op.'
}
if ($cold.InitAttempts -ne 0 -or $cold.Events -ne 0 -or $cold.Workers -ne 0) {
    throw 'Model: empty input allocated lazy search resources.'
}
if (-not (Invoke-BeginSearch -State $cold -Text 'STEAM')) {
    throw 'Model: first nonempty query did not initialize search.'
}
if ($cold.InitAttempts -ne 1 -or $cold.Events -ne 2 -or $cold.Workers -ne 8 -or -not $cold.RanksLoaded) {
    throw 'Model: first nonempty query did not create the exact search resource set.'
}
if (-not (Invoke-BeginSearch -State $cold -Text 'STEAMVR') -or $cold.InitAttempts -ne 1) {
    throw 'Model: initialized search was not idempotent.'
}
Invoke-AddRank $cold
if ($cold.RankWrites -ne 1) { throw 'Model: initialized ranking did not remain available.' }
Invoke-SearchClose $cold
if ($cold.Events -ne 0 -or $cold.Workers -ne 0 -or $cold.Initialized) {
    throw 'Model: Close did not release initialized search resources.'
}

$failed = New-LazySearchState
if (Invoke-BeginSearch -State $failed -Text 'FAIL' -Fail $true) {
    throw 'Model: forced initialization failure was reported as success.'
}
if (-not $failed.Disabled -or $failed.InitAttempts -ne 1 -or $failed.Events -ne 0 -or $failed.Workers -ne 0) {
    throw 'Model: failed initialization did not become a resource-free terminal no-op.'
}
if (Invoke-BeginSearch -State $failed -Text 'RETRY' -or $failed.InitAttempts -ne 1) {
    throw 'Model: disabled search retried initialization.'
}
Invoke-AddRank $failed
Invoke-SearchClose $failed
if ($failed.RankWrites -ne 0 -or $failed.Events -ne 0 -or $failed.Workers -ne 0) {
    throw 'Model: disabled search was not safe for rank/close calls.'
}

Write-Host 'A4S lazy-search static and lifecycle model gates passed.'
