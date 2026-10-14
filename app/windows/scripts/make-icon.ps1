# Redraws src/LocoLoco/Assets/LocoLoco.ico from the octopus code the tray icon uses.
#   scripts/make-icon.ps1                  the .ico only
#   scripts/make-icon.ps1 -Preview out     also app and tray preview sheets in out
param([string]$Preview)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$arguments = @(Join-Path $root 'src\LocoLoco\Assets\LocoLoco.ico')
if ($Preview) { $arguments += $Preview }
dotnet run --project (Join-Path $root 'src\make-icon') -- @arguments
exit $LASTEXITCODE
