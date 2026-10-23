# EMERGENCY RESTORE: run locally, elevated. Restores prior Windows Firewall policy and managed NIC states.
param([switch]$Execute)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $Execute) { Write-Host 'Run .\Stop-Lockdown.ps1 -Execute from an ELEVATED local PowerShell console to restore networking.'; exit 0 }
Assert-Administrator; Assert-PhysicalConsole
$cfg = Read-GatewayConfig
Close-Gateway $cfg
$backup = Join-Path $script:StateDir 'firewall-before-lockdown.wfw'
if (-not (Test-Path -LiteralPath $backup)) { throw "Backup not found: $backup. Cannot safely restore firewall settings." }
& netsh.exe advfirewall import $backup | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Firewall import failed. Restore manually before reconnecting adapters.' }
Unregister-ScheduledTask -TaskName 'DDGW-SafeStart' -Confirm:$false -ErrorAction SilentlyContinue
$prev = Get-Content -LiteralPath (Join-Path $script:StateDir 'adapters-before.json') -Raw | ConvertFrom-Json
if ($prev.internet_was_up) { Enable-NetAdapter -Name $prev.internet_adapter -Confirm:$false -ErrorAction Stop }
if ($prev.local_was_up) { Enable-NetAdapter -Name $prev.local_adapter -Confirm:$false -ErrorAction Stop }
Remove-Item -LiteralPath (Join-Path $script:StateDir 'LOCKDOWN_ACTIVE') -Force -ErrorAction SilentlyContinue
Write-GatewayLog 'RESTORE' 'Previous firewall policy imported and NIC administrative states restored'
Write-Host 'RESTORE COMPLETE: imported saved firewall settings and restored previous adapter states.' -ForegroundColor Green
