[CmdletBinding()]
param(
    [switch] $CenterBottom,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

# The production DLL intentionally exports only its tiny C ABI. For visual QA,
# compile the same menu/UI sources through the retained upstream development
# launcher and its -nohook path. Product ABI and static package checks are
# handled by Test-A4SProduct.ps1. The separate, explicit
# Test-A4SProductLifecycle.ps1 gate performs live Explorer validation; this
# preview script never injects Explorer.
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-A4SMenu.ps1')
}

$previewParameters = @{}
if ($CenterBottom) {
    $previewParameters.CenterBottom = $true
}
& (Join-Path $PSScriptRoot 'Preview-A4SMenu.ps1') @previewParameters
