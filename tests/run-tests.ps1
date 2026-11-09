[CmdletBinding()]
param(
    [switch]$DockerIntegration,
    [switch]$ComposeIntegration,
    [switch]$FullN8nIntegration,
    [switch]$PublicTunnelIntegration
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    if ($DockerIntegration) { $env:RUN_DOCKER_TESTS = '1' }
    if ($ComposeIntegration) { $env:RUN_COMPOSE_TESTS = '1' }
    if ($FullN8nIntegration) { $env:RUN_N8N_TESTS = '1' }
    if ($PublicTunnelIntegration) { $env:RUN_TUNNEL_TESTS = '1' }
    python tests/run_tests.py
    if ($LASTEXITCODE -ne 0) { throw "Тести завершилися з кодом $LASTEXITCODE" }
} finally {
    Remove-Item Env:\RUN_DOCKER_TESTS -ErrorAction SilentlyContinue
    Remove-Item Env:\RUN_COMPOSE_TESTS -ErrorAction SilentlyContinue
    Remove-Item Env:\RUN_N8N_TESTS -ErrorAction SilentlyContinue
    Remove-Item Env:\RUN_TUNNEL_TESTS -ErrorAction SilentlyContinue
    Pop-Location
}
