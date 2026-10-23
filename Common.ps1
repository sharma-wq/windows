# Data Diode Windows proof of concept. Windows PowerShell 5.1, Windows 10/11 Pro/Enterprise.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RulePrefix = 'DDGW-'
$script:Root = $PSScriptRoot
$script:StateDir = Join-Path $script:Root 'state'

function Read-GatewayConfig {
    $path = Join-Path $script:Root 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Copy config.example.json to config.json, then edit real settings.' }
    $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($key in @('internet_adapter','local_adapter','source_hostname','source_ip','source_file_path','internet_next_hop','receiver_ip','receiver_username','receiver_directory','ssh_private_key','ssh_known_hosts','staging_directory')) {
        if (-not $cfg.$key) { throw "Missing config setting: $key" }
    }
    if ($cfg.internet_adapter -eq $cfg.local_adapter) { throw 'The two adapter aliases must differ.' }
    foreach ($address in @($cfg.source_ip,$cfg.internet_next_hop,$cfg.receiver_ip)) {
        $parsed = $null
        if ((-not [System.Net.IPAddress]::TryParse([string]$address,[ref]$parsed)) -or ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork)) {
            throw "Expected an IPv4 address, got: $address"
        }
    }
    if ($cfg.source_file_path -notmatch '^/[A-Za-z0-9_./-]+$' -or $cfg.source_file_path.Contains('..')) { throw 'Use a simple HTTPS file path without traversal.' }
    if ($cfg.source_hostname -notmatch '^[A-Za-z0-9.-]+$') { throw 'Invalid source hostname.' }
    if ($cfg.receiver_username -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid receiver username.' }
    if ($cfg.receiver_directory -notmatch '^/[A-Za-z0-9_./-]+$' -or $cfg.receiver_directory.Contains('..')) { throw 'Invalid server destination path.' }
    return $cfg
}
function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open Windows PowerShell as Administrator on the LOCAL console.' }
}
function Assert-PhysicalConsole {
    if ($env:SESSIONNAME -match '^RDP-') { throw 'Do not change network adapters through Remote Desktop. Use the local console.' }
    if ($env:SSH_CONNECTION) { throw 'Do not change network adapters through SSH.' }
}
function Assert-Lockdown {
    if (-not (Test-Path (Join-Path $script:StateDir 'LOCKDOWN_ACTIVE'))) { throw 'Run Start-Lockdown.ps1 locally before executing real transfers.' }
}
function Get-AdapterChecked([string]$name) {
    $a = Get-NetAdapter -Name $name -ErrorAction Stop
    if ($null -eq $a) { throw "Adapter missing: $name" }
    return $a
}
function Test-IsAdministrativelyUp($adapter) {
    if ($null -ne $adapter.PSObject.Properties['AdminStatus']) { return ([string]$adapter.AdminStatus -eq 'Up') }
    return ([string]$adapter.Status -ne 'Disabled')
}
function Assert-AdapterIsolation($cfg,[string]$allowed) {
    $wan = Get-AdapterChecked $cfg.internet_adapter
    $lan = Get-AdapterChecked $cfg.local_adapter
    $wanUp = Test-IsAdministrativelyUp $wan
    $lanUp = Test-IsAdministrativelyUp $lan
    if ($wanUp -and $lanUp) { throw 'ISOLATION FAULT: both controlled adapters administratively UP.' }
    if ($allowed -eq 'none' -and ($wanUp -or $lanUp)) { throw 'ISOLATION FAULT: expected both interfaces DOWN.' }
    if ($allowed -eq 'fetch' -and (-not $wanUp -or $lanUp)) { throw 'FETCH STATE FAULT.' }
    if ($allowed -eq 'deliver' -and ($wanUp -or -not $lanUp)) { throw 'DELIVER STATE FAULT.' }
    $other = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
        $_.Name -ne $cfg.internet_adapter -and $_.Name -ne $cfg.local_adapter -and (Test-IsAdministrativelyUp $_)
    })
    if ($other.Count -gt 0) { throw "Other network adapters enabled: $($other.Name -join ', '). Disable Wi-Fi/VPN/extra adapters on the dedicated test VM." }
}
function Remove-PhaseRules {
    @(Get-NetFirewallRule -Name 'DDGW-PHASE-*' -ErrorAction SilentlyContinue) | Remove-NetFirewallRule -ErrorAction Stop
}
function Remove-GatewayRoute($cfg) {
    $prefix = [string]$cfg.source_ip + '/32'
    @(Get-NetRoute -DestinationPrefix $prefix -InterfaceAlias $cfg.internet_adapter -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $cfg.internet_next_hop }) |
        Remove-NetRoute -Confirm:$false -ErrorAction Stop
}
function Close-Gateway($cfg) {
    # Turning interfaces DOWN first prevents packet forwarding during firewall rule changes.
    try { Disable-NetAdapter -Name $cfg.internet_adapter -Confirm:$false -ErrorAction Stop } catch { Write-Warning "WAN disable: $_" }
    try { Disable-NetAdapter -Name $cfg.local_adapter -Confirm:$false -ErrorAction Stop } catch { Write-Warning "LAN disable: $_" }
    try { Remove-PhaseRules } catch { Write-Warning "Firewall cleanup: $_" }
    try { Remove-GatewayRoute $cfg } catch { Write-Warning "Route cleanup: $_" }
}
function Assert-NoDefaultRoute {
    $v4 = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $v6 = @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
    if ($v4.Count -gt 0 -or $v6.Count -gt 0) { throw 'Default route exists. Use static NIC addresses WITHOUT default gateways in the isolated VM.' }
}
function Assert-OnlyGatewayAllowRules {
    $others = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Action Allow -ErrorAction Stop | Where-Object { $_.Name -notlike 'DDGW-PHASE-*' })
    if ($others.Count -gt 0) { throw "Found $($others.Count) other effective Windows Firewall ALLOW rules. GPO/OS policy can bypass the intended allowlist." }
}
function Add-PhaseRule([string]$name,[string]$program,[string]$iface,[string]$ip,[int]$port) {
    if (-not (Test-Path -LiteralPath $program)) { throw "Required Windows executable missing: $program" }
    New-NetFirewallRule -Name "DDGW-PHASE-$name" -DisplayName "DDGW phase $name" -Direction Outbound -Action Allow -Enabled True -Profile Any -Protocol TCP -RemoteAddress $ip -RemotePort $port -InterfaceAlias $iface -Program $program -ErrorAction Stop | Out-Null
}
function Start-GatewayPhase($cfg,[ValidateSet('fetch','deliver')][string]$phase) {
    Close-Gateway $cfg
    Assert-AdapterIsolation $cfg 'none'
    Assert-NoDefaultRoute
    Assert-OnlyGatewayAllowRules
    if ($phase -eq 'fetch') {
        Add-PhaseRule 'FETCH-CURL' (Join-Path $env:windir 'System32\curl.exe') $cfg.internet_adapter $cfg.source_ip 443
        Enable-NetAdapter -Name $cfg.internet_adapter -Confirm:$false -ErrorAction Stop
        New-NetRoute -DestinationPrefix "$($cfg.source_ip)/32" -InterfaceAlias $cfg.internet_adapter -NextHop $cfg.internet_next_hop -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    } else {
        # Some OpenSSH builds establish SFTP sessions through a child ssh.exe process.
        $base = Join-Path $env:windir 'System32\OpenSSH'
        Add-PhaseRule 'SEND-SFTP' (Join-Path $base 'sftp.exe') $cfg.local_adapter $cfg.receiver_ip 22
        Add-PhaseRule 'SEND-SSH' (Join-Path $base 'ssh.exe') $cfg.local_adapter $cfg.receiver_ip 22
        Enable-NetAdapter -Name $cfg.local_adapter -Confirm:$false -ErrorAction Stop
    }
    Assert-AdapterIsolation $cfg $phase
    Assert-OnlyGatewayAllowRules
}
function Write-GatewayLog([string]$event,[string]$detail) {
    if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    $record = [ordered]@{ utc=(Get-Date).ToUniversalTime().ToString('o'); event=$event; detail=$detail }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $script:StateDir 'events.jsonl') -Encoding UTF8
}
