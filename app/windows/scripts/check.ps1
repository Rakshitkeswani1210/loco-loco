# Proves the app works on this PC. Starts three demo servers in your user folder, runs Loco Loco's
# screenshot script against only their ports, and saves what it drew. Stops only the servers it started.
#   scripts/check.ps1 -Exe "dist\x64\Loco Loco\Loco Loco.exe"
#   scripts/check.ps1 -Exe ... -Out shots -Scan path\to\loco-scan.exe
# Needs PowerShell 7, and python and node on PATH.
#Requires -Version 7
param(
    [Parameter(Mandatory)][string]$Exe,
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot) 'shots'),
    [string]$Scan,
    [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$data = Join-Path ([IO.Path]::GetTempPath()) "loco-check-$PID"
# Inside the user folder, where Loco Loco looks for your own servers.
$demo = Join-Path ([Environment]::GetFolderPath('UserProfile')) "loco-check-$PID"

function Listening([int]$port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

# The usual port when it's free, otherwise any free one, so a real server is never touched.
function Port([int]$want) {
    if (-not (Listening $want)) { return $want }
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    $p
}

function Folder([string]$name, [hashtable]$files) {
    $dir = Join-Path $demo $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($f in $files.Keys) { Set-Content -Path (Join-Path $dir $f) -Value $files[$f] -Encoding utf8NoBOM }
    $dir
}

function Run([string]$file, [string[]]$arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new($file)
    foreach ($a in $arguments) { $psi.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        $p.Kill($true)
        throw "$([IO.Path]::GetFileName($file)) $($arguments[0]) took longer than $TimeoutSeconds s"
    }
    $p.ExitCode
}

$servers = @(
    @{ Name = 'storefront-web'; Port = (Port 5173); Program = 'node'; Args = { param($p) @('server.js', "$p") }
       Files = @{
           'package.json' = '{ "name": "storefront-web", "private": true }'
           'server.js' = "const port = +process.argv[2];`nrequire('http').createServer((q, s) => s.end('storefront-web\n')).listen(port, '127.0.0.1', () => console.log('listening on ' + port));"
       } },
    @{ Name = 'ops-validation-api'; Port = (Port 8000); Program = 'python'; Args = { param($p) @('-m', 'http.server', "$p", '--bind', '127.0.0.1') }
       Files = @{ 'pyproject.toml' = "[project]`nname = `"ops-validation-api`"`nversion = `"0.1.0`"" } },
    @{ Name = 'design-docs'; Port = (Port 4321); Program = 'python'; Args = { param($p) @('-m', 'http.server', "$p", '--bind', '127.0.0.1') }
       Files = @{ 'index.html' = '<h1>design-docs</h1>' } }
)
$ports = $servers | ForEach-Object { $_.Port }

$code = 1
try {
    foreach ($s in $servers) {
        $dir = Folder $s.Name $s.Files
        # Each in its own hidden console, as if started in a terminal, so Stop can send it Ctrl+C.
        Start-Process -FilePath $s.Program -ArgumentList (& $s.Args $s.Port) -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
    }
    $end = (Get-Date).AddSeconds(30)
    while (@($ports | Where-Object { -not (Listening $_) }).Count -gt 0) {
        if ((Get-Date) -gt $end) { throw "Demo servers didn't start on $($ports -join ', ')" }
        Start-Sleep -Milliseconds 300
    }
    Write-Host "Demo servers on $($ports -join ', ')"

    if ($Scan) {
        $listed = & $Scan | Out-String
        Write-Host $listed
        foreach ($s in $servers) {
            if ($listed -notmatch [regex]::Escape($s.Name)) { throw "loco-scan didn't list $($s.Name)" }
        }
    }

    $code = Run $Exe @('--screenshot', $Out, '--only', ($ports -join ','), '--data', $data)
    foreach ($f in 'log.txt', 'error.txt') {
        $path = Join-Path $Out $f
        if (Test-Path $path) { Write-Host "---- $f"; Get-Content $path | Write-Host }
    }
    $icons = Run $Exe @('--icons', (Join-Path $Out 'icons'))
    if ($icons -ne 0) { Write-Host "--icons exited with $icons"; if ($code -eq 0) { $code = $icons } }
    Get-ChildItem $Out -Recurse -File | ForEach-Object { Write-Host $_.FullName.Substring($Out.Length + 1) }
}
finally {
    # Only the ports this script started, including servers Loco Loco restarted on them.
    foreach ($p in $ports) {
        Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $demo, $data -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Loco Loco --screenshot exited with $code"
exit $code
