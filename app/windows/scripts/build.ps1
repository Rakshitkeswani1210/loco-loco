# Builds Loco Loco for Windows and zips it, self-contained, so the PC needs nothing installed.
#   scripts/build.ps1              x64 and Arm64 zips in app/windows/dist
#   scripts/build.ps1 -Arch x64    one of them
#   scripts/build.ps1 -Run         build for this PC and start it
param(
    [ValidateSet('x64', 'arm64')][string[]]$Arch = @('x64', 'arm64'),
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dist = Join-Path $root 'dist'
$version = (Select-Xml -Path (Join-Path $root 'Directory.Build.props') -XPath '//Version').Node.InnerText
if ($Run) { $Arch = @(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }) }

foreach ($a in $Arch) {
    # The zip holds one "Loco Loco" folder, so unzipping never scatters files.
    $folder = Join-Path $dist "$a\Loco Loco"
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    dotnet publish (Join-Path $root 'src\LocoLoco') -c Release -r "win-$a" -o $folder
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    # Without it WinUI can't find its own themes, and the app fails on launch.
    if (-not (Test-Path (Join-Path $folder 'resources.pri'))) { throw "The $a build has no resources.pri" }
    $zip = Join-Path $dist "LocoLoco-$version-windows-$a.zip"
    Compress-Archive -Path $folder -DestinationPath $zip -Force
    Write-Host "Built $zip"
}

if ($Run) { Start-Process (Join-Path $dist "$($Arch[0])\Loco Loco\Loco Loco.exe") }
