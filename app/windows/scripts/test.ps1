# Runs the tests. On Windows that includes IntegrationTests, which start and stop their own Python and Node servers.
# Extra arguments go to dotnet test, for example: scripts/test.ps1 --filter Naming
$ErrorActionPreference = 'Stop'
dotnet test (Join-Path (Split-Path $PSScriptRoot) 'tests\LocoCore.Tests') @args
exit $LASTEXITCODE
