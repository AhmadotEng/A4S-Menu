[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL'

function Assert-A4S {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw "A4S performance optimization contract failed: $Message"
    }
}

function Read-A4SSource {
    param([Parameter(Mandatory)][string] $Name)

    $path = Join-Path $sourceRoot $Name
    Assert-A4S (Test-Path -LiteralPath $path -PathType Leaf) "required source file is missing: $path"
    return Get-Content -LiteralPath $path -Raw
}

function Get-A4SCppFunction {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $QualifiedName
    )

    # All functions covered by this gate have one-line signatures. Isolate the
    # exact definition, then balance braces while ignoring comments and quoted
    # literals so a nearby function can never accidentally satisfy a contract.
    $namePattern = [Regex]::Escape($QualifiedName)
    $definitionPattern = "(?m)^[\t ]*[^\r\n;{}]*$namePattern\s*\([^\r\n;{}]*\)[\t ]*(?:const[\t ]*)?\r?\n?[\t ]*\{"
    $definitions = [Regex]::Matches($Text, $definitionPattern)
    Assert-A4S ($definitions.Count -eq 1) "could not uniquely isolate $QualifiedName (found $($definitions.Count) definitions)"

    $definition = $definitions[0]
    $openBrace = $definition.Index + $definition.Value.LastIndexOf('{')
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
                if ($character -eq '*' -and $next -eq '/') {
                    $state = 'Code'
                    $index++
                }
                continue
            }
            'String' {
                if ($character -eq '\') {
                    $index++
                } elseif ([int]$character -eq 34) {
                    $state = 'Code'
                }
                continue
            }
            'Character' {
                if ($character -eq '\') {
                    $index++
                } elseif ([int]$character -eq 39) {
                    $state = 'Code'
                }
                continue
            }
        }

        if ($character -eq '/' -and $next -eq '/') {
            $state = 'LineComment'
            $index++
            continue
        }
        if ($character -eq '/' -and $next -eq '*') {
            $state = 'BlockComment'
            $index++
            continue
        }
        if ([int]$character -eq 34) {
            $state = 'String'
            continue
        }
        if ([int]$character -eq 39) {
            $state = 'Character'
            continue
        }
        if ($character -eq '{') {
            $depth++
            continue
        }
        if ($character -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($definition.Index, $index - $definition.Index + 1)
            }
        }
    }

    throw "A4S performance optimization contract failed: unterminated definition for $QualifiedName"
}

function Resolve-A4SPreprocessorCondition {
    param([Parameter(Mandatory)][string] $Directive)

    $normalized = ($Directive -replace '/\*.*?\*/', '' -replace '//.*$', '').Trim()
    if ($normalized -match '^#\s*ifdef\s+A4S_PRODUCT\s*$') {
        return [pscustomobject]@{ Known = $true; Value = $true }
    }
    if ($normalized -match '^#\s*ifndef\s+A4S_PRODUCT\s*$') {
        return [pscustomobject]@{ Known = $true; Value = $false }
    }
    if ($normalized -match '^#\s*if\s+defined\s*\(\s*A4S_PRODUCT\s*\)\s*$') {
        return [pscustomobject]@{ Known = $true; Value = $true }
    }
    if ($normalized -match '^#\s*if\s+!\s*defined\s*\(\s*A4S_PRODUCT\s*\)\s*$') {
        return [pscustomobject]@{ Known = $true; Value = $false }
    }
    return [pscustomobject]@{ Known = $false; Value = $false }
}

function Get-A4SOccurrenceStates {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern
    )

    $frames = [Collections.Generic.List[object]]::new()
    $states = [Collections.Generic.List[object]]::new()
    $lines = [Regex]::Split($Text, '\r?\n')

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        $trimmed = $line.Trim()
        if ($trimmed -match '^#\s*(?:if|ifdef|ifndef)\b') {
            $frames.Add((Resolve-A4SPreprocessorCondition $trimmed))
            continue
        }
        if ($trimmed -match '^#\s*else\b') {
            Assert-A4S ($frames.Count -gt 0) "unmatched #else while analyzing source line $($lineIndex + 1)"
            $frame = $frames[$frames.Count - 1]
            if ($frame.Known) { $frame.Value = -not $frame.Value }
            continue
        }
        if ($trimmed -match '^#\s*elif\s+(.+)$') {
            Assert-A4S ($frames.Count -gt 0) "unmatched #elif while analyzing source line $($lineIndex + 1)"
            $frames[$frames.Count - 1] = Resolve-A4SPreprocessorCondition ("#if " + $Matches[1])
            continue
        }
        if ($trimmed -match '^#\s*endif\b') {
            Assert-A4S ($frames.Count -gt 0) "unmatched #endif while analyzing source line $($lineIndex + 1)"
            $frames.RemoveAt($frames.Count - 1)
            continue
        }

        if ($line -notmatch $Pattern) { continue }
        $excluded = $false
        $productGuarded = $false
        foreach ($frame in $frames) {
            if (-not $frame.Known) { continue }
            if ($frame.Value) { $productGuarded = $true } else { $excluded = $true }
        }
        $states.Add([pscustomobject]@{
            Line = $lineIndex + 1
            Text = $line.Trim()
            Excluded = $excluded
            ProductGuarded = $productGuarded -and -not $excluded
        })
    }

    Assert-A4S ($frames.Count -eq 0) 'unterminated preprocessor conditional while analyzing a function'
    return @($states)
}

function Assert-A4SProductExcludesOccurrences {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Description
    )

    foreach ($occurrence in @(Get-A4SOccurrenceStates -Text $Text -Pattern $Pattern)) {
        Assert-A4S $occurrence.Excluded "$Description remains compiled into A4S_PRODUCT at function-relative line $($occurrence.Line): $($occurrence.Text)"
    }
}

$skinSource = Read-A4SSource 'SkinManager.cpp'
$containerSource = Read-A4SSource 'MenuContainer.cpp'
$itemSource = Read-A4SSource 'ItemManager.cpp'
$searchSource = Read-A4SSource 'SearchManager.cpp'
$dllSource = Read-A4SSource 'StartMenuDLL.cpp'
$profileSource = Read-A4SSource 'A4SMenuProfile.cpp'

# Embedded profile resources remain warm for one exact skin type/resource-flags/
# DPI tuple. Reset() is the single invalidation path and must clear Hash.
$loadSkin = Get-A4SCppFunction -Text $skinSource -QualifiedName 'MenuSkin::LoadMenuSkin'
$resetSkin = Get-A4SCppFunction -Text $skinSource -QualifiedName 'MenuSkin::Reset'
Assert-A4S ($loadSkin -match '(?s)if\s*\(\s*A4SMenuProfile::IsEnabled\s*\(\s*\)\s*\).*?profileKey\s*\[\s*\]\s*=\s*\{.*?skinType.*?flags.*?dpi.*?\}') 'the product skin cache key does not include skin type, resource flags, and DPI'
Assert-A4S ($loadSkin -match 'profileHash\s*=\s*CalcFNVHash\s*\(\s*profileKey\s*,\s*sizeof\s*\(\s*profileKey\s*\)\s*\)') 'the product skin cache key is not hashed as one tuple'
Assert-A4S ($loadSkin -match '(?s)Hash\s*==\s*profileHash.*?Dpi\s*==\s*dpi.*?return\s+true\s*;') 'the product skin cache does not reuse the matching type/flags/DPI profile'
Assert-A4S ($loadSkin -match 'Hash\s*=\s*loaded\s*\?\s*profileHash\s*:\s*0\s*;') 'failed skin loads can publish a valid cache key'
Assert-A4S ($resetSkin -match '\bHash\s*=\s*0\s*;') 'MenuSkin::Reset no longer invalidates the cached product profile'

# The root toggle and close paths must not repeat full settings derivation or
# persist the entire item cache. These calls may remain for upstream builds.
$toggleMenu = Get-A4SCppFunction -Text $containerSource -QualifiedName 'CMenuContainer::ToggleStartMenu'
$destroyMenu = Get-A4SCppFunction -Text $containerSource -QualifiedName 'CMenuContainer::OnDestroy'
Assert-A4SProductExcludesOccurrences -Text $toggleMenu -Pattern '\bUpdateDefaultSettings\s*\(' -Description 'full default-settings recomputation on each root toggle'
Assert-A4SProductExcludesOccurrences -Text $destroyMenu -Pattern '\bSaveCacheFile\s*\(' -Description 'full cache persistence on each root close'

# Preloading starts only after a finite, exit-event-backed quiet period. The
# wait must precede shell/filesystem discovery and must have an early-exit path.
$preload = Get-A4SCppFunction -Text $itemSource -QualifiedName 'CItemManager::PreloadItemsThread'
$waitStates = @(Get-A4SOccurrenceStates -Text $preload -Pattern 'WaitForSingleObject\s*\(\s*m_ExitEvent\s*,')
$productWait = @($waitStates | Where-Object ProductGuarded | Select-Object -First 1)
Assert-A4S ($productWait.Count -eq 1) 'preload has no A4S_PRODUCT-only wait on m_ExitEvent'
$waitMatch = [Regex]::Match($preload, 'WaitForSingleObject\s*\(\s*m_ExitEvent\s*,\s*([^\)]+)\)')
Assert-A4S $waitMatch.Success 'the preload quiet-period wait could not be isolated'
$timeout = $waitMatch.Groups[1].Value.Trim()
Assert-A4S ($timeout -notmatch '^(?:0(?:[uUlL]*)?|NULL|INFINITE)$') 'the preload quiet period is zero or infinite'
if ($timeout -match '^\d+$') {
    Assert-A4S ([uint64]$timeout -gt 0) 'the preload quiet period is not positive'
}
$firstDiscovery = [Regex]::Match($preload, '\b(?:ShGetKnownFolderIDList|SHParseDisplayName|SHCreateItemFromIDList|FindFirstChangeNotification|LoadFolderItems|LoadMetroItems)\s*\(')
Assert-A4S $firstDiscovery.Success 'preload shell/filesystem discovery could not be located'
Assert-A4S ($waitMatch.Index -lt $firstDiscovery.Index) 'preload begins shell/filesystem discovery before its quiet period'
$quietTailLength = [Math]::Min(900, $firstDiscovery.Index - $waitMatch.Index)
$quietTail = $preload.Substring($waitMatch.Index, $quietTailLength)
Assert-A4S ($quietTail -match '\b(?:WAIT_OBJECT_0|WAIT_TIMEOUT)\b') 'the preload quiet wait result is not checked'
Assert-A4S ($quietTail -match '\breturn\s*;') 'the preload quiet wait cannot exit promptly when shutdown is requested'

# Drag/drop is not a product feature. Keep upstream implementation available,
# but prove that no helper creation, root-window registration, teardown, option,
# or preferred-effect clipboard plumbing survives the product preprocessing.
$constructor = Get-A4SCppFunction -Text $containerSource -QualifiedName 'CMenuContainer::CMenuContainer'
$createMenu = Get-A4SCppFunction -Text $containerSource -QualifiedName 'CMenuContainer::OnCreate'
Assert-A4SProductExcludesOccurrences -Text $constructor -Pattern '\bCLSID_DragDropHelper\b|\bm_pDragSourceHelper\b' -Description 'menu drag/drop helper construction'
Assert-A4SProductExcludesOccurrences -Text $createMenu -Pattern '\bRegisterDragDrop\s*\(|\bCDropTargetProxy\b' -Description 'menu drop-target registration'
Assert-A4SProductExcludesOccurrences -Text $destroyMenu -Pattern '\bRevokeDragDrop\s*\(|\bm_pDropTargetHelper\b|\bm_pDropTargetProxy\b|\bm_pDragObject\b' -Description 'menu drag/drop teardown'
Assert-A4SProductExcludesOccurrences -Text $toggleMenu -Pattern '\bCONTAINER_(?:DRAG|DROP)\b' -Description 'root drag/drop container options'
Assert-A4SProductExcludesOccurrences -Text $toggleMenu -Pattern '\bCFSTR_(?:PREFERREDDROPEFFECT|DROPDESCRIPTION)\b' -Description 'drag/drop clipboard-format registration'
Assert-A4SProductExcludesOccurrences -Text $toggleMenu -Pattern 's_bNoDragDrop\s*=\s*!\s*GetSettingBool' -Description 'per-toggle drag/drop setting lookup'
$noDragStates = @(Get-A4SOccurrenceStates -Text $toggleMenu -Pattern 's_bNoDragDrop\s*=\s*true\s*;')
Assert-A4S (@($noDragStates | Where-Object ProductGuarded).Count -eq 1) 'A4S_PRODUCT does not publish drag/drop as unavailable on each root-menu construction'
Assert-A4S ($profileSource -match 'ForceBool\s*\(\s*L"EnableDragDrop"\s*,\s*false\s*\)') 'the source-owned product profile no longer forces drag/drop off'

# Prefer the dedicated executable-model gate when the lazy-search change owns
# one. The fallback remains fail-closed so this aggregate contract is useful in
# an intermediate checkout where the implementation is present before its gate.
$lazySearchGate = Join-Path $PSScriptRoot 'Test-A4SLazySearch.ps1'
if (Test-Path -LiteralPath $lazySearchGate -PathType Leaf) {
    & $lazySearchGate
} else {
    $initManagers = Get-A4SCppFunction -Text $dllSource -QualifiedName 'InitManagers'
    Assert-A4SProductExcludesOccurrences -Text $initManagers -Pattern '\bg_SearchManager\.Init\s*\(' -Description 'eager product search initialization'

    $searchInit = Get-A4SCppFunction -Text $searchSource -QualifiedName 'CSearchManager::Init'
    $beginSearch = Get-A4SCppFunction -Text $searchSource -QualifiedName 'CSearchManager::BeginSearch'
    Assert-A4S ($searchInit -match '(?s)m_bInitializationFailed.*?return\s+false') 'failed product search initialization is not terminal'
    Assert-A4S ($searchInit -match '(?s)m_bInitialized.*?return\s+true') 'product search initialization is not idempotent'
    Assert-A4S ($beginSearch -match '(?s)searchText\.IsEmpty\s*\(\s*\).*?return\s+true\s*;.*?if\s*\(\s*!\s*Init\s*\(\s*\)\s*\)') 'search initializes before the first non-empty query'

    foreach ($functionName in @('CSearchManager::CloseMenu', 'CSearchManager::AddItemRank', 'CSearchManager::GetSearchResults')) {
        $function = Get-A4SCppFunction -Text $searchSource -QualifiedName $functionName
        Assert-A4S ($function -match 'if\s*\(\s*!\s*m_bInitialized\s*\)') "$functionName is unsafe before lazy initialization"
    }
}

Write-Host 'Validated product skin caching/invalidation, toggle and close hot-path exclusions, interruptible delayed preload, drag/drop omission, and lazy search initialization.'
