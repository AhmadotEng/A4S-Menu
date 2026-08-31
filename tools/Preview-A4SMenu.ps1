[CmdletBinding()]
param(
    [switch] $CenterBottom
)

$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stageRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\stage'))
$stageDir = [IO.Path]::GetFullPath((Join-Path $stageRoot 'A4SMenu'))
$previewExe = [IO.Path]::GetFullPath((Join-Path $stageDir 'StartMenu.exe'))
$previewDll = [IO.Path]::GetFullPath((Join-Path $stageDir 'StartMenuDLL.dll'))

if (-not $stageDir.StartsWith($stageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to preview outside the repository stage root: $stageDir"
}
foreach ($path in @($previewExe, $previewDll)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing staged runtime file: $path. Run tools\Build-A4SMenu.ps1 first."
    }
}

# Stop only an earlier standalone preview from this exact staged path. Never
# stop the installed Open-Shell process and never touch StartAllBack/Explorer.
$ownedPreviews = Get-CimInstance Win32_Process -Filter "Name='StartMenu.exe'" |
    Where-Object {
        $_.ExecutablePath -eq $previewExe -and
        $_.CommandLine -match '(?i)(?:^|\s)-nohook(?:\s|$)'
    }
foreach ($process in $ownedPreviews) {
    Stop-Process -Id $process.ProcessId -Force
}

$previewArgs = @('-nohook')
if ($CenterBottom) {
    $previewArgs += '-a4scenterbottom'
}

$preview = Start-Process -FilePath $previewExe -ArgumentList $previewArgs -PassThru
$placement = if ($CenterBottom) { 'center-bottom comparison mode' } else { 'bottom-left mode' }
Write-Host "A4S Menu standalone preview started in $placement (PID $($preview.Id)). Explorer remains untouched."
