# Optional best-effort startup cleanup. Task Scheduler runs AFTER some Windows networking is initialized.
# It does NOT provide hardware enforced fail-closed isolation at power-on.
param([switch]$Execute)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $Execute) { Write-Host 'Plan only. Use .\Register-SafeStart.ps1 -Execute from an elevated LOCAL console'; exit 0 }
Assert-Administrator; Assert-PhysicalConsole; Assert-Lockdown
$scriptPath = Join-Path $PSScriptRoot 'Close-Gateway.ps1'
$action = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName 'DDGW-SafeStart' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Write-Host 'At-startup cleanup registered. This is best effort; early boot network isolation is NOT guaranteed.' -ForegroundColor Yellow
