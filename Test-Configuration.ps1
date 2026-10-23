# Safe: read-only preflight. Run this first in ordinary PowerShell.
. (Join-Path $PSScriptRoot 'Common.ps1')
Write-Host 'DATA DIODE WINDOWS: NON-DESTRUCTIVE PREFLIGHT' -ForegroundColor Cyan
try { $cfg = Read-GatewayConfig; Write-Host 'Configuration JSON: valid' -ForegroundColor Green } catch { Write-Warning $_; exit 2 }
Write-Host "Fetch: HTTPS $($cfg.source_hostname) -> $($cfg.source_ip):443 via $($cfg.internet_adapter)"
Write-Host "Deliver: SFTP $($cfg.receiver_username)@$($cfg.receiver_ip):22 via $($cfg.local_adapter)"
Write-Host "Staging: $($cfg.staging_directory)"
if ($cfg.source_ip -eq '203.0.113.20') { Write-Warning 'SOURCE IP IS A DOCUMENTATION ADDRESS; replace it.' }
if ($cfg.source_hostname.EndsWith('.test')) { Write-Warning 'SOURCE HOST IS A PLACEHOLDER; replace it.' }
Write-Host 'Adapters (read-only):'
Get-NetAdapter | Format-Table Name,Status,AdminStatus,LinkSpeed -AutoSize
Write-Host 'IP addresses and routes (read-only):'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -in @($cfg.internet_adapter,$cfg.local_adapter) } | Format-Table InterfaceAlias,IPAddress,PrefixLength
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Format-Table InterfaceAlias,NextHop
Write-Host 'Firewall profiles (read-only):'
Get-NetFirewallProfile | Format-Table Name,Enabled,DefaultInboundAction,DefaultOutboundAction
Write-Host 'Installed transfer executables:'
foreach ($file in @((Join-Path $env:windir 'System32\curl.exe'),(Join-Path $env:windir 'System32\OpenSSH\sftp.exe'),(Join-Path $env:windir 'System32\OpenSSH\ssh.exe'))) {
    Write-Host "$file  Exists=$(Test-Path -LiteralPath $file)"
}
Write-Host 'No changes were made.' -ForegroundColor Green
