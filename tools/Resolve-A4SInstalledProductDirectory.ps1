[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'A4SBinaryIdentity.psm1') -Force
$activeSlot = Get-A4SInstalledActiveSlot

# Emit only the canonical slot path so callers can safely capture it once and
# pass the same exact value to baseline, performance, trace, and scenario tools.
Write-Output $activeSlot
