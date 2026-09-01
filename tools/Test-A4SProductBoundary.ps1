[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Text -notmatch $Pattern) {
        throw "$Label is missing required contract pattern: $Pattern"
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Text -match $Pattern) {
        throw "$Label retained forbidden product-boundary pattern: $Pattern"
    }
}

function Assert-ExactSet {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]] $Actual,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]] $Expected,
        [Parameter(Mandatory)][string] $Label
    )

    $actualSorted = @($Actual | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Unique)
    $expectedSorted = @($Expected | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualSorted)
    if ($difference.Count -ne 0 -or $actualSorted.Count -ne $expectedSorted.Count) {
        $rendered = @($difference | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }) -join ', '
        throw "$Label drifted. Difference: $rendered"
    }
}

function Get-ProjectItems {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ItemName
    )

    [xml] $project = Get-Content -LiteralPath $Path -Raw
    $namespace = [Xml.XmlNamespaceManager]::new($project.NameTable)
    $namespace.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')
    return @($project.SelectNodes("//m:$ItemName",$namespace) | ForEach-Object { [string] $_.Include })
}

function Get-A4SProductActiveText {
    param([Parameter(Mandatory)][string] $Path)

    $active = $true
    $frames = [Collections.Generic.List[object]]::new()
    $output = [Collections.Generic.List[string]]::new()
    foreach ($line in [Regex]::Split((Get-Content -LiteralPath $Path -Raw),'\r?\n')) {
        $directive = [Regex]::Match($line,'^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)$')
        if (-not $directive.Success) {
            if ($active) {
                $output.Add($line)
            }
            continue
        }

        $kind = $directive.Groups[1].Value
        $expression = $directive.Groups[2].Value.Trim()
        if ($kind -in @('if','ifdef','ifndef')) {
            $isA4S = $false
            $condition = $true
            if ($kind -eq 'ifdef' -and $expression -match '^A4S_PRODUCT\b') {
                $isA4S = $true
                $condition = $true
            }
            elseif ($kind -eq 'ifndef' -and $expression -match '^A4S_PRODUCT\b') {
                $isA4S = $true
                $condition = $false
            }
            elseif ($kind -eq 'if' -and $expression -match '^defined\s*(?:\(\s*)?A4S_PRODUCT(?:\s*\))?\s*$') {
                $isA4S = $true
                $condition = $true
            }
            elseif ($kind -eq 'if' -and $expression -match '^!\s*defined\s*(?:\(\s*)?A4S_PRODUCT(?:\s*\))?\s*$') {
                $isA4S = $true
                $condition = $false
            }
            $frames.Add([pscustomobject]@{
                ParentActive = $active
                IsA4S = $isA4S
                Condition = $condition
            })
            $active = $active -and (-not $isA4S -or $condition)
            continue
        }

        if ($kind -eq 'else' -or $kind -eq 'elif') {
            if ($frames.Count -eq 0) {
                throw "Unbalanced preprocessor directive in $Path`: $line"
            }
            $frame = $frames[$frames.Count-1]
            if ($frame.IsA4S) {
                if ($kind -eq 'elif') {
                    throw "A4S_PRODUCT #elif is not supported by the boundary scanner: $Path`: $line"
                }
                $active = $frame.ParentActive -and -not $frame.Condition
            }
            else {
                # Both branches of unrelated compile-time choices belong to
                # the reviewed source closure; only A4S_PRODUCT is resolved.
                $active = $frame.ParentActive
            }
            continue
        }

        if ($frames.Count -eq 0) {
            throw "Unbalanced #endif in $Path`: $line"
        }
        $frame = $frames[$frames.Count-1]
        $frames.RemoveAt($frames.Count-1)
        $active = $frame.ParentActive
    }
    if ($frames.Count -ne 0) {
        throw "Unclosed preprocessor directive in $Path."
    }

    $text = $output -join "`n"
    $text = [Regex]::Replace($text,'(?s)/\*.*?\*/','')
    return [Regex]::Replace($text,'(?m)//[^\r\n]*$','')
}

function Get-NormalizedSourceHash {
    param([Parameter(Mandatory)][string] $Text)

    $withoutComments = [Regex]::Replace($Text,'(?s)/\*.*?\*/','')
    $withoutComments = [Regex]::Replace($withoutComments,'(?m)//[^\r\n]*$','')
    $tokenPattern = 'L?"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9A-Fa-f]+|\d+|::|&&|\|\||<<|>>|<=|>=|==|!=|\+\+|--|->|[{}\[\](),;#=|&?:*<>!+./%-]'
    $normalized = @([Regex]::Matches($withoutComments,$tokenPattern) | ForEach-Object { $_.Value }) -join ' '
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-ExactNormalizedBlock {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $ExpectedHash,
        [Parameter(Mandatory)][string] $Label
    )

    $match = [Regex]::Match($Text,$Pattern)
    if (-not $match.Success) {
        throw "$Label could not be extracted for exact normalization."
    }
    $actualHash = Get-NormalizedSourceHash -Text $match.Value
    if ($actualHash -ne $ExpectedHash) {
        throw "$Label drifted. Expected normalized SHA-256 $ExpectedHash; found $actualHash."
    }
}

function Assert-NoBannedBinaryStrings {
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $unicodeEven = [Text.Encoding]::Unicode.GetString($bytes)
    $unicodeOdd = if ($bytes.Length -gt 1) {
        [Text.Encoding]::Unicode.GetString($bytes,1,$bytes.Length-1)
    }
    else {
        ''
    }
    $banned = @(
        'Settings for Open-Shell Menu',
        'Open-Shell Menu',
        'Classic Shell',
        'Classic style',
        'Classic Skin',
        'Windows Aero',
        'MenuItems1',
        'MenuItems2',
        'OpenShell\Languages',
        '.skin7',
        'CheckWinUpdates',
        'Check for updates',
        'Taskbar texture',
        'Skin options',
        'StartMenu.exe'
    )
    foreach ($term in $banned) {
        if ($ascii.Contains($term) -or $unicodeEven.Contains($term) -or $unicodeOdd.Contains($term)) {
            throw "Product binary retained forbidden string '$term': $Path"
        }
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productRoot = Join-Path $repoRoot 'Src\A4SMenu'
$solutionPath = Join-Path $productRoot 'A4SMenu.Product.sln'
$menuProject = Join-Path $productRoot 'Menu\A4SMenu.vcxproj'
$hostProject = Join-Path $productRoot 'Host\A4SMenuHost.vcxproj'
$runtimeProject = Join-Path $productRoot 'Runtime\A4SMenuRuntime.vcxproj'
$setupProject = Join-Path $productRoot 'Setup\A4SMenuSetup.vcxproj'

$solutionText = Get-Content -LiteralPath $solutionPath -Raw
$solutionProjects = @([Regex]::Matches($solutionText,'(?m)^Project\([^\r\n]+\) = "([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
Assert-ExactSet -Actual $solutionProjects -Expected @(
    'A4SMenu','A4SMenuHost','A4SMenuRuntime','A4SMenuSetup'
) -Label 'A4S product solution projects'

$menuSources = @(
    'A4SDisabledFeatures.cpp',
    '..\..\StartMenu\StartMenuDLL\A4SPerformance.cpp',
    '..\..\StartMenu\StartMenuDLL\A4SMenuProfile.cpp',
    '..\..\StartMenu\StartMenuDLL\Accessibility.cpp',
    '..\..\StartMenu\StartMenuDLL\StartButton.cpp',
    '..\..\StartMenu\StartMenuDLL\StartMenuDLL.cpp',
    'A4SFixedMenu.cpp',
    '..\..\StartMenu\StartMenuDLL\dllmain.cpp',
    '..\..\StartMenu\StartMenuDLL\ItemManager.cpp',
    '..\..\StartMenu\StartMenuDLL\LogManager.cpp',
    '..\..\StartMenu\StartMenuDLL\MenuCommands.cpp',
    '..\..\StartMenu\StartMenuDLL\MenuContainer.cpp',
    '..\..\StartMenu\StartMenuDLL\MenuPaint.cpp',
    '..\..\StartMenu\StartMenuDLL\MetroLinkManager.cpp',
    '..\..\StartMenu\StartMenuDLL\ProgramsTree.cpp',
    '..\..\StartMenu\StartMenuDLL\SearchManager.cpp',
    'A4SFixedSettings.cpp',
    '..\..\StartMenu\StartMenuDLL\SkinManager.cpp',
    '..\..\StartMenu\StartMenuDLL\stdafx.cpp'
)
Assert-ExactSet -Actual (Get-ProjectItems -Path $menuProject -ItemName 'ClCompile') -Expected $menuSources -Label 'A4SMenu compile inputs'
Assert-ExactSet -Actual (Get-ProjectItems -Path $menuProject -ItemName 'ResourceCompile') -Expected @('A4SMenuProduct.rc') -Label 'A4SMenu resources'
Assert-ExactSet -Actual (Get-ProjectItems -Path $menuProject -ItemName 'ProjectReference') -Expected @('..\Runtime\A4SMenuRuntime.vcxproj') -Label 'A4SMenu project references'

Assert-ExactSet -Actual (Get-ProjectItems -Path $hostProject -ItemName 'ClCompile') -Expected @('A4SMenuHost.cpp') -Label 'A4SMenuHost compile inputs'
Assert-ExactSet -Actual (Get-ProjectItems -Path $hostProject -ItemName 'ResourceCompile') -Expected @('A4SMenuHost.rc') -Label 'A4SMenuHost resources'

$runtimeSources = @(
    'A4SSettingsRuntime.cpp',
    '..\..\Lib\Assert.cpp',
    '..\..\Lib\FileHelper.cpp',
    '..\..\Lib\FNVHash.cpp',
    '..\..\Lib\IatHookHelper.cpp',
    '..\..\Lib\Instance.cpp',
    '..\..\Lib\ResourceHelper.cpp',
    '..\..\Lib\Settings.cpp',
    '..\..\Lib\SettingsParser.cpp',
    '..\..\Lib\stdafx.cpp',
    '..\..\Lib\StringSet.cpp',
    '..\..\Lib\StringUtils.cpp',
    '..\..\Lib\TrackResources.cpp',
    '..\..\Lib\Translations.cpp'
)
Assert-ExactSet -Actual (Get-ProjectItems -Path $runtimeProject -ItemName 'ClCompile') -Expected $runtimeSources -Label 'private A4S runtime compile inputs'
Assert-ExactSet -Actual (Get-ProjectItems -Path $runtimeProject -ItemName 'ResourceCompile') -Expected @() -Label 'private A4S runtime resources'
$runtimeProjectText = Get-Content -LiteralPath $runtimeProject -Raw
Assert-Contains -Text $runtimeProjectText -Pattern '<ConfigurationType>StaticLibrary</ConfigurationType>' -Label 'private A4S runtime project'
Assert-Contains -Text $runtimeProjectText -Pattern '<OutDir>\$\(A4SProductBuildRoot\)lib\\\$\(Platform\)\\</OutDir>' -Label 'private A4S runtime project'

Assert-ExactSet -Actual (Get-ProjectItems -Path $setupProject -ItemName 'ClCompile') -Expected @('A4SMenuSetup.cpp') -Label 'A4SMenuSetup compile inputs'
Assert-ExactSet -Actual (Get-ProjectItems -Path $setupProject -ItemName 'ResourceCompile') -Expected @('A4SMenuSetup.rc') -Label 'A4SMenuSetup resources'
Assert-ExactSet -Actual (Get-ProjectItems -Path $setupProject -ItemName 'ProjectReference') -Expected @(
    '..\Host\A4SMenuHost.vcxproj','..\Menu\A4SMenu.vcxproj'
) -Label 'A4SMenuSetup project references'

$menuProjectText = Get-Content -LiteralPath $menuProject -Raw
Assert-NotContains -Text $menuProjectText -Pattern '(?i)CustomMenu\.cpp|SettingsUI\.cpp|StartMenuDLL\.rc' -Label 'A4SMenu project'
Assert-NotContains -Text $menuProjectText -Pattern '(?i)Netapi32\.lib|wintrust\.lib|crypt32\.lib' -Label 'A4SMenu project link inputs'
$linkMatch = [Regex]::Match($menuProjectText,'(?s)<Link>.+?<AdditionalDependencies>([^<]+)</AdditionalDependencies>.+?</Link>')
if (-not $linkMatch.Success) {
    throw 'A4SMenu project has no reviewable linker dependency list.'
}
Assert-ExactSet -Actual @($linkMatch.Groups[1].Value -split ';') -Expected @(
    '$(A4SProductBuildRoot)lib\$(Platform)\A4SMenuRuntime.lib',
    'comctl32.lib','uxtheme.lib','WtsApi32.lib','Secur32.lib','Msimg32.lib',
    'dwmapi.lib','PowrProf.lib','Oleacc.lib','winmm.lib','structuredquery.lib',
    'Propsys.lib','%(AdditionalDependencies)'
) -Label 'A4SMenu linker inputs'

$productResourcePath = Join-Path $productRoot 'Menu\A4SMenuProduct.rc'
$productResourceText = Get-Content -LiteralPath $productResourcePath -Raw
if ((Get-NormalizedSourceHash -Text $productResourceText) -ne '789dfbceb82e82d9e42bf96a63d74814faa27d32fd1f6277eb697bd106ad1580') {
    throw 'A4SMenu product resource graph drifted from the exact reviewed resource boundary.'
}
Assert-Contains -Text $productResourceText -Pattern '(?m)^2\s+SKIN\s+"\.\./\.\./StartMenu/StartMenuDLL/SkinDescription7\.txt"\s*$' -Label 'A4SMenu product resource'
Assert-Contains -Text $productResourceText -Pattern '(?m)^1\s+L10N\s+"\.\./\.\./StartMenu/StartMenuDLL/A4SMenuL10N\.txt"\s*$' -Label 'A4SMenu product resource'
Assert-NotContains -Text $productResourceText -Pattern '(?m)^\s*1\s+SKIN\b|\bDIALOG(?:EX)?\b|\bHTML\b|\bRCDATA\b' -Label 'A4SMenu product resource'
foreach ($resourceName in @('IDI_APPSICON','IDI_APPSICON10','IDI_APPSICON11','IDB_ARROWS','IDB_ARROWS150','IDB_SEARCH_ICONS')) {
    Assert-Contains -Text $productResourceText -Pattern "(?m)^$resourceName\s+" -Label 'A4SMenu product resource'
}
foreach ($term in @('Settings for Open-Shell Menu','Classic style','Classic Skin','Check for updates','Taskbar texture','Skin options')) {
    if ($productResourceText.Contains($term)) {
        throw "A4SMenu product resource retained forbidden UI text '$term'."
    }
}

$fixedMenuPath = Join-Path $productRoot 'Menu\A4SFixedMenu.cpp'
$fixedMenuText = Get-Content -LiteralPath $fixedMenuPath -Raw
Assert-ExactNormalizedBlock -Text $fixedMenuText -Pattern '(?s)\bStdMenuItem\s+g_A4SPowerMenu\[\]\s*=\s*\{.*?\r?\n\s*\};' -ExpectedHash '2dc34ff728e9d014c64f137894d079d65c97bce8aab1a1ffdcbb53a78d9e2749' -Label 'fixed power-menu graph'
Assert-ExactNormalizedBlock -Text $fixedMenuText -Pattern '(?s)\bStdMenuItem\s+g_A4SRootMenu\[\]\s*=\s*\{.*?\r?\n\s*\};' -ExpectedHash '3cb28dc884e0ba5a5d1def79aa408081f5396c25f61976e580f5c646eb07638c' -Label 'fixed root-menu graph'
Assert-NotContains -Text $fixedMenuText -Pattern 'CSettingsParser|GetSettingString\(L"MenuItems' -Label 'fixed menu graph'

$fixedSettingsPath = Join-Path $productRoot 'Menu\A4SFixedSettings.cpp'
$fixedSettingsText = Get-Content -LiteralPath $fixedSettingsPath -Raw
Assert-Contains -Text $fixedSettingsText -Pattern 'A4S_FIXED_FLAGS \(CSetting::FLAG_HIDDEN\|CSetting::FLAG_NOSAVE\|CSetting::FLAG_FORCED_DEFAULT\|CSetting::FLAG_LOCKED_GP\)' -Label 'fixed settings catalog'
Assert-Contains -Text $fixedSettingsText -Pattern 'A4S_BOOL\(CascadeAll,0\)' -Label 'fixed settings catalog'
Assert-Contains -Text $fixedSettingsText -Pattern 'CaptureFixedCatalog\(\);[\s\S]+::InitSettings\(g_A4SSettings' -Label 'fixed settings immutable snapshot order'
Assert-Contains -Text $fixedSettingsText -Pattern 'setting\.defValue=g_A4SSourceDefaults\[index\];[\s\S]+setting\.value=g_A4SSourceDefaults\[index\];[\s\S]+setting\.flags=g_A4SSourceFlags\[index\]\|CSetting::FLAG_DEFAULT;' -Label 'fixed settings immutable restore'
Assert-Contains -Text $fixedSettingsText -Pattern 'void UpdateSettings\( void \)[\s\S]+RestoreFixedCatalog\(\);[\s\S]+SetFixedDefault\(L"MenuDelay"[\s\S]+SetFixedDefault\(L"AllProgramsDelay"[\s\S]+A4SMenuProfile::ApplyLockedSettings\(\);[\s\S]+LockFixedCatalog\(\);' -Label 'fixed settings stale-policy/default reset order'
Assert-NotContains -Text $fixedSettingsText -Pattern 'CheckWinUpdates|MenuItems1|MenuItems2|SkinC1|SkinC2|SkinW7|SkinOptions' -Label 'fixed settings catalog'

# Derive the fixed catalog and prove every typed setting reference in the exact
# product compile graph resolves to a compatible entry after A4S_PRODUCT branch
# selection. This fails closed when a shared source adds a new dependency.
$catalogMatches = @([Regex]::Matches($fixedSettingsText,'(?m)^\s*A4S_(BOOL|INT|HOTKEY|COLOR|STRING|MULTI)\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,'))
$catalog = @{}
foreach ($match in $catalogMatches) {
    $name = $match.Groups[2].Value
    if ($catalog.ContainsKey($name)) {
        throw "Fixed settings catalog contains duplicate entry '$name'."
    }
    $catalog[$name] = $match.Groups[1].Value
}
if ($catalog.Count -ne 190) {
    throw "Fixed settings catalog count drifted. Expected 190 unique entries; found $($catalog.Count)."
}

$menuSourceRoot = Split-Path -Parent $menuProject
$runtimeSourceRoot = Split-Path -Parent $runtimeProject
$compiledSourcePaths = @(
    $menuSources | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $menuSourceRoot $_)) }
    $runtimeSources | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $runtimeSourceRoot $_)) }
)
if ($compiledSourcePaths.Count -ne 33) {
    throw "A4S typed-setting scan expected 33 exact Menu+Runtime compile inputs; found $($compiledSourcePaths.Count)."
}
foreach ($sourcePath in $compiledSourcePaths) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "A4S typed-setting scan is missing compile input: $sourcePath"
    }
}
$activeProductText = @($compiledSourcePaths | ForEach-Object { Get-A4SProductActiveText -Path $_ }) -join "`n"

$accessorTypes = @{
    GetSettingBool = @('BOOL')
    ForceBool = @('BOOL')
    GetSettingInt = @('INT','HOTKEY','COLOR')
    ForceInt = @('INT','HOTKEY','COLOR')
    GetSettingString = @('STRING','MULTI')
    ForceString = @('STRING','MULTI')
}
$literalSettingReferences = @([Regex]::Matches(
    $activeProductText,
    '\b(GetSettingBool|GetSettingInt|GetSettingString|ForceBool|ForceInt|ForceString)\s*\(\s*L"([^"]+)"'
))
foreach ($reference in $literalSettingReferences) {
    $accessor = $reference.Groups[1].Value
    $name = $reference.Groups[2].Value
    if (-not $catalog.ContainsKey($name)) {
        throw "A4S product source references missing fixed setting '$name' through $accessor."
    }
    if ($catalog[$name] -notin $accessorTypes[$accessor]) {
        throw "A4S product source reads '$name' through $accessor, but the fixed catalog type is $($catalog[$name])."
    }
}

$literalGetterNames = @($literalSettingReferences |
    Where-Object { $_.Groups[1].Value.StartsWith('GetSetting',[StringComparison]::Ordinal) } |
    ForEach-Object { $_.Groups[2].Value } |
    Sort-Object -Unique)
if ($literalGetterNames.Count -ne 168) {
    throw "A4S active literal getter closure drifted. Expected 168 unique setting names; found $($literalGetterNames.Count)."
}

# Non-literal calls are deliberately few and reviewed. The exact signature set
# prevents a new variable-driven setting lookup from bypassing the catalog scan.
$nonLiteralCalls = @([Regex]::Matches(
    $activeProductText,
    '(?m)\b(GetSettingBool|GetSettingInt|GetSettingString)\s*\(\s*(?!L")([^\r\n;]*)'
) | ForEach-Object {
    $signature = "$($_.Groups[1].Value)($($_.Groups[2].Value.Trim()))"
    [Regex]::Replace($signature,'\s+','')
})
$actualNonLiteralSignatures = @($nonLiteralCalls | Group-Object | ForEach-Object { "$($_.Count)|$($_.Name)" })
$expectedNonLiteralSignatures = @(
    '1|GetSettingBool(constCSetting&setting))',
    '2|GetSettingBool(constwchar_t*name)const)',
    '1|GetSettingBool(constwchar_t*name))',
    '2|GetSettingBool(constwchar_t*name,bool&bDef)const)',
    '1|GetSettingBool(constwchar_t*name,bool&bDef))',
    '2|GetSettingBool(name))',
    '1|GetSettingBool(name,bDef))',
    '1|GetSettingInt((msg->wParam==MSG_DRAG)?L"MouseClick":L"ShiftClick"))',
    '1|GetSettingInt(bAllPrograms?L"SubMenuAnimation":L"MainMenuAnimation"))',
    '1|GetSettingInt(bAllPrograms?L"SubMenuAnimationSpeed":L"MainMenuAnimationSpeed"))',
    '1|GetSettingInt(categoryHash==m_SearchCategoryHash?L"SearchResultsMax":L"SearchResults"))',
    '2|GetSettingInt(constwchar_t*name)const)',
    '1|GetSettingInt(constwchar_t*name))',
    '2|GetSettingInt(constwchar_t*name,bool&bDef)const)',
    '1|GetSettingInt(constwchar_t*name,bool&bDef))',
    '1|GetSettingInt(m_bSubMenu?L"SubMenuScrollSpeed":L"MainMenuScrollSpeed"))',
    '3|GetSettingInt(name))',
    '1|GetSettingInt(name,bDef))',
    '1|GetSettingString(bPicture?L"UserPictureCommand":L"UserNameCommand"))',
    '1|GetSettingString(command))',
    '1|GetSettingString(constCSetting&setting))',
    '2|GetSettingString(constwchar_t*name)const)',
    '1|GetSettingString(constwchar_t*name))',
    '1|GetSettingString(name))',
    '1|GetSettingString(setting))'
)
Assert-ExactSet -Actual $actualNonLiteralSignatures -Expected $expectedNonLiteralSignatures -Label 'A4S non-literal setting accessors'

$dynamicTypedReferences = @{
    INT = @(
        'MouseClick','ShiftClick','MiddleClick',
        'MainMenuAnimation','SubMenuAnimation',
        'MainMenuAnimationSpeed','SubMenuAnimationSpeed',
        'MainMenuScrollSpeed','SubMenuScrollSpeed',
        'SearchResults','SearchResultsMax'
    )
    STRING = @(
        'MouseClickCommand','ShiftClickCommand','MiddleClickCommand',
        'UserPictureCommand','UserNameCommand',
        'SoundMain','SoundPopup','SoundCommand','SoundDrop','SoundButtonHover'
    )
}
foreach ($expectedType in $dynamicTypedReferences.Keys) {
    foreach ($name in $dynamicTypedReferences[$expectedType]) {
        if (-not $catalog.ContainsKey($name)) {
            throw "A4S dynamic setting path requires missing fixed setting '$name'."
        }
        $compatibleTypes = if ($expectedType -eq 'INT') { @('INT','HOTKEY','COLOR') } else { @('STRING','MULTI') }
        if ($catalog[$name] -notin $compatibleTypes) {
            throw "A4S dynamic setting '$name' has incompatible fixed type $($catalog[$name]); expected $expectedType-compatible."
        }
    }
}

$profilePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\A4SMenuProfile.cpp'
$profileText = Get-Content -LiteralPath $profilePath -Raw
Assert-Contains -Text $profileText -Pattern 'ForceBool\(L"CascadeAll",false\)' -Label 'locked A4S profile'
Assert-Contains -Text $profileText -Pattern 'setting->defValue=value;[\s\S]+setting->value=value;[\s\S]+FLAG_FORCED_DEFAULT[\s\S]+FLAG_LOCKED_GP' -Label 'locked A4S profile'
Assert-Contains -Text $profileText -Pattern '(?s)#ifndef A4S_PRODUCT.+?ForceBool\(L"CheckWinUpdates",false\);.+?#endif' -Label 'upstream preview updater isolation'

$programsTreePath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\ProgramsTree.cpp'
$programsTreeText = Get-Content -LiteralPath $programsTreePath -Raw
Assert-Contains -Text $programsTreeText -Pattern '(?s)if \(wParam==VK_DELETE \|\| wParam==VK_F2\)\s*\{\s*#ifdef A4S_PRODUCT.+?return 0;\s*#else.+?ACTIVATE_RENAME:CMenuContainer::ACTIVATE_DELETE.+?#endif' -Label 'Programs tree fixed interaction boundary'

$menuContainerPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuContainer.cpp'
$menuContainerText = Get-Content -LiteralPath $menuContainerPath -Raw
Assert-Contains -Text $menuContainerText -Pattern '(?s)#ifdef A4S_PRODUCT\s*// Rename and shell deletion.+?if \(wParam==VK_F2 \|\| wParam==VK_DELETE\)\s*return 0;\s*#else.+?ACTIVATE_RENAME.+?ACTIVATE_DELETE.+?#endif' -Label 'root menu fixed interaction boundary'

$menuCommandsPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\MenuCommands.cpp'
$menuCommandsText = Get-Content -LiteralPath $menuCommandsPath -Raw
Assert-Contains -Text $menuCommandsText -Pattern '(?s)void CMenuContainer::ActivateItem.+?#ifdef A4S_PRODUCT.+?if \(type==ACTIVATE_RENAME \|\| type==ACTIVATE_DELETE\)\s*return;\s*#endif' -Label 'mutating activation fail-closed boundary'

$settingsRuntimePath = Join-Path $repoRoot 'Src\Lib\Settings.cpp'
$settingsRuntimeText = Get-Content -LiteralPath $settingsRuntimePath -Raw
$initMatch = [Regex]::Match($settingsRuntimeText,'(?s)void CSettingsManager::Init\(.+?\n\}')
if (-not $initMatch.Success -or $initMatch.Value.IndexOf('LoadSettings(false);') -lt 0 -or $initMatch.Value.IndexOf('UpdateSettings();') -lt 0 -or $initMatch.Value.IndexOf('LoadSettings(false);') -gt $initMatch.Value.IndexOf('UpdateSettings();')) {
    throw 'Settings initialization no longer reapplies the locked product profile after registry loading; stale CascadeAll could escape.'
}

$skinPath = Join-Path $repoRoot 'Src\StartMenu\StartMenuDLL\SkinManager.cpp'
$skinText = Get-Content -LiteralPath $skinPath -Raw
Assert-Contains -Text $skinText -Pattern '(?s)#ifdef A4S_PRODUCT.+?LoadSkin\(g_Instance,NULL,L"",skinType,flags,dpi\).+?#else' -Label 'product skin loader'

$translationsPath = Join-Path $repoRoot 'Src\Lib\Translations.cpp'
$translationsText = Get-Content -LiteralPath $translationsPath -Raw
Assert-Contains -Text $translationsText -Pattern '(?s)#ifdef A4S_PRODUCT.+?FindResource\(hModule,MAKEINTRESOURCE\(1\),L"L10N"\).+?IsLanguageRTL.+?return false;.+?#else' -Label 'product translations'

$resourceHelperPath = Join-Path $repoRoot 'Src\Lib\ResourceHelper.cpp'
$resourceHelperText = Get-Content -LiteralPath $resourceHelperPath -Raw
Assert-Contains -Text $resourceHelperText -Pattern '(?s)#ifdef A4S_PRODUCT.+?LoadTranslationOverrides\(g_Instance\);.+?g_ResStrings\.Init\(g_Instance\);.+?#else' -Label 'product resource loader'
Assert-Contains -Text $resourceHelperText -Pattern '(?s)HINSTANCE LoadTranslationDll.+?#ifdef A4S_PRODUCT.+?return NULL;.+?#else' -Label 'product language loader'

$setupResourcePath = Join-Path $productRoot 'Setup\A4SMenuSetup.rc'
$setupResourceText = Get-Content -LiteralPath $setupResourcePath -Raw
$payloadLines = @([Regex]::Matches($setupResourceText,'(?m)^\s*IDR_A4S_[A-Z_]+\s+RCDATA\s+"[^"]+"\s*$') |
    ForEach-Object { $_.Value.Trim() })
Assert-ExactSet -Actual $payloadLines -Expected @(
    'IDR_A4S_HOST_PAYLOAD RCDATA "../../../build/A4SProduct/bin/x64/A4SMenuHost.exe"',
    'IDR_A4S_MENU_PAYLOAD RCDATA "../../../build/A4SProduct/bin/x64/A4SMenu.dll"'
) -Label 'installer embedded runtime payloads'

$binaryRoot = Join-Path $repoRoot 'build\A4SProduct\bin\x64'
$binaryPaths = @(
    (Join-Path $binaryRoot 'A4SMenu.dll'),
    (Join-Path $binaryRoot 'A4SMenuHost.exe'),
    (Join-Path $binaryRoot 'A4SMenuSetup.exe')
)
$missingBinaries = @($binaryPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missingBinaries.Count -eq 0) {
    foreach ($binaryPath in $binaryPaths) {
        Assert-NoBannedBinaryStrings -Path $binaryPath
    }
}
else {
    Write-Warning "Binary string closure was skipped because product outputs are absent: $($missingBinaries -join ', ')"
}

Write-Host 'Validated exact A4S product projects, compile inputs, normalized menu/resource graphs, exhaustive typed-setting closure, embedded-only resources/translations, stale-registry and mutating-action closure, installer payloads, and binary string closure.'
