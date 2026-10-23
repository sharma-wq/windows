# DANGEROUS: only use on a dedicated Windows test VM with a local console.
param([switch]$Execute, [string]$Acknowledge = '')
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $Execute -or $Acknowledge -cne 'LOCKDOWN') {
    Write-Host 'PLAN ONLY: To apply on an ISOLATED WINDOWS VM at its local console, use:' -ForegroundColor Yellow
    Write-Host '.\Start-Lockdown.ps1 -Execute -Acknowledge LOCKDOWN'
    Write-Host 'This backs up firewall policy, disables existing local allow rules, blocks all traffic by default, and disables two network adapters.'
    exit 0
}
Assert-Administrator; Assert-PhysicalConsole
$cfg = Read-GatewayConfig
[void](Get-AdapterChecked $cfg.internet_adapter); [void](Get-AdapterChecked $cfg.local_adapter)
if (Test-Path (Join-Path $script:StateDir 'LOCKDOWN_ACTIVE')) { throw 'Already in lockdown: use Stop-Lockdown.ps1 before reinitializing.' }
if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
# Preserve the prior policy and NIC admin states for restoration.
$backup = Join-Path $script:StateDir 'firewall-before-lockdown.wfw'
$nicState = [ordered]@{
    internet_was_up=(Test-IsAdministrativelyUp (Get-AdapterChecked $cfg.internet_adapter))
    local_was_up=(Test-IsAdministrativelyUp (Get-AdapterChecked $cfg.local_adapter))
    internet_adapter=$cfg.internet_adapter
    local_adapter=$cfg.local_adapter
}
$nicState | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:StateDir 'adapters-before.json') -Encoding UTF8
& netsh.exe advfirewall export $backup | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $backup)) { throw 'Firewall backup failed. Refusing lockdown.' }
Write-Warning 'LOCKDOWN WILL INTERRUPT ALL NORMAL NETWORKING. KEEP THIS LOCAL CONSOLE OPEN.'
$answer = Read-Host 'Type YES to continue on this dedicated test machine'
if ($answer -cne 'YES') { Write-Host 'Cancelled'; exit 0 }
try {
    Disable-NetAdapter -Name $cfg.internet_adapter -Confirm:$false -ErrorAction Stop
    Disable-NetAdapter -Name $cfg.local_adapter -Confirm:$false -ErrorAction Stop
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Block -ErrorAction Stop
    # Default Block does NOT suppress other existing Allow rules. Temporarily disable local Allow rules.
    @(Get-NetFirewallRule -PolicyStore PersistentStore -Enabled True -Action Allow -ErrorAction Stop) |
        Set-NetFirewallRule -Enabled False -ErrorAction Stop
    Remove-PhaseRules
    Assert-NoDefaultRoute
    Assert-AdapterIsolation $cfg 'none'
    Assert-OnlyGatewayAllowRules
    Set-Content -LiteralPath (Join-Path $script:StateDir 'LOCKDOWN_ACTIVE') -Value 'Lockdown enabled; restore with Stop-Lockdown.ps1' -Encoding Ascii
    Write-GatewayLog 'LOCKDOWN' 'Firewall backup saved; all locally configured allow rules disabled'
    Write-Host 'LOCKDOWN ACTIVE. Both managed adapters DOWN. Other effective allow rules: none.' -ForegroundColor Green
} catch {
    Write-Error "Lockdown failed, attempting policy restoration: $_"
    & netsh.exe advfirewall import $backup | Out-Host
    if ($nicState.internet_was_up) { Enable-NetAdapter -Name $cfg.internet_adapter -Confirm:$false -ErrorAction SilentlyContinue }
    if ($nicState.local_was_up) { Enable-NetAdapter -Name $cfg.local_adapter -Confirm:$false -ErrorAction SilentlyContinue }
    throw 'Lockdown unsuccessful. Confirm policy and adapters manually at local console.'
}
