# Emergency phase cleanup. Leaves strict lockdown in effect (does not restore ordinary Windows networking).
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Administrator
$cfg = Read-GatewayConfig
Close-Gateway $cfg
Assert-AdapterIsolation $cfg 'none'
Write-GatewayLog 'CLOSED' 'Both interfaces down; phase-specific allow rules removed'
Write-Host 'CLOSED: both gateway interfaces DOWN, phase permissions removed.' -ForegroundColor Green
