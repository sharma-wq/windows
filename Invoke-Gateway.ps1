# Two-NIC store-and-forward Windows proof of concept. No real changes without -Execute.
param([switch]$Execute)
. (Join-Path $PSScriptRoot 'Common.ps1')
$cfg = Read-GatewayConfig
$sourceUrl = "https://$($cfg.source_hostname)$($cfg.source_file_path)"
if (-not $Execute) {
    Write-Host 'DRY RUN ONLY (no firewall or adapter changes)' -ForegroundColor Cyan
    Write-Host '1 IDLE: both gateway interfaces DOWN, no phase rules.'
    Write-Host "2 FETCH: allow curl.exe $($cfg.source_ip):443 over $($cfg.internet_adapter), HTTPS $sourceUrl"
    Write-Host "3 HOLD: both interfaces DOWN, verify local SHA-256, stage in $($cfg.staging_directory)"
    Write-Host "4 DELIVER: allow Windows OpenSSH SFTP/SSH $($cfg.receiver_ip):22 over $($cfg.local_adapter)"
    Write-Host '5 Verify receiver sha256sum matches; close both NICs; optionally delete after confirmation.'
    Write-Host 'To run LIVE inside an isolated VM that was placed in lockdown, use .\Invoke-Gateway.ps1 -Execute'
    exit 0
}
Assert-Administrator; Assert-PhysicalConsole; Assert-Lockdown
if ($cfg.source_ip -eq '203.0.113.20' -or $cfg.source_hostname.EndsWith('.test')) { throw 'Replace test/example HTTPS source IP and hostname before live execution.' }
if (-not (Test-Path -LiteralPath $cfg.ssh_private_key) -or -not (Test-Path -LiteralPath $cfg.ssh_known_hosts)) { throw 'Private SSH key and independently verified known_hosts file are required.' }
if (-not (Test-Path -LiteralPath $cfg.staging_directory -PathType Container)) { throw 'Staging drive/folder is not mounted or missing.' }
$curl = Join-Path $env:windir 'System32\curl.exe'
$sftp = Join-Path $env:windir 'System32\OpenSSH\sftp.exe'
$ssh = Join-Path $env:windir 'System32\OpenSSH\ssh.exe'
foreach ($exe in @($curl,$sftp,$ssh)) { if (-not (Test-Path -LiteralPath $exe)) { throw "Required executable missing: $exe" } }
# Restrict remote filename to safe characters. Never accept arbitrary remote shell input.
$filename = Split-Path -Leaf ([string]$cfg.source_file_path)
if ($filename -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$' -or $filename -eq '.' -or $filename -eq '..') { throw 'Unsupported remote filename.' }
$staged = Join-Path $cfg.staging_directory $filename
$partial = $staged + '.partial'
$manifest = $staged + '.sha256.json'
$remotePath = ([string]$cfg.receiver_directory).TrimEnd('/') + '/' + $filename
$batchFile = Join-Path $script:StateDir 'sftp-batch.txt'
$locked = Join-Path $script:StateDir 'RUN_ACTIVE'
if (Test-Path -LiteralPath $locked) { throw 'Another run is active, or previous run needs manual fault review. Refusing concurrent transfer.' }
New-Item -ItemType File -Path $locked -ErrorAction Stop | Out-Null
$phase = 'INIT'
try {
    Close-Gateway $cfg
    Assert-AdapterIsolation $cfg 'none'
    Assert-NoDefaultRoute
    Assert-OnlyGatewayAllowRules
    Write-GatewayLog 'START' "$filename"
    $phase = 'FETCH'
    Start-GatewayPhase $cfg 'fetch'
    Write-Host "FETCH: HTTPS $sourceUrl -> $partial"
    $resolve = '{0}:443:{1}' -f $cfg.source_hostname,$cfg.source_ip
    & $curl '--fail' '--show-error' '--silent' '--proto' '=https' '--tlsv1.2' '--resolve' $resolve '--connect-timeout' ([string]$cfg.connect_timeout_seconds) '--max-time' ([string]$cfg.max_transfer_seconds) '--output' $partial $sourceUrl
    if ($LASTEXITCODE -ne 0) { throw "HTTPS curl failed, exit code $LASTEXITCODE" }
    Close-Gateway $cfg
    Assert-AdapterIsolation $cfg 'none'
    if (-not (Test-Path -LiteralPath $partial)) { throw 'Downloaded file not found.' }
    $sha = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    Move-Item -LiteralPath $partial -Destination $staged -Force
    $record = [ordered]@{ filename=$filename; sha256=$sha; length=(Get-Item -LiteralPath $staged).Length; source=$sourceUrl; utc=(Get-Date).ToUniversalTime().ToString('o') }
    $record | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
    Write-GatewayLog 'HOLD' "$filename sha256=$sha"
    if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'Staging SHA256 mismatch.' }
    $phase = 'DELIVER'
    Start-GatewayPhase $cfg 'deliver'
    # Path is escaped for SFTP batch parser; a simple staging path without embedded quotes is required.
    if ($staged.Contains('"') -or $remotePath.Contains('"')) { throw 'Invalid SFTP file path.' }
    $sftpLocalPath = $staged.Replace('\','/')
    ('put "{0}" "{1}"' -f $sftpLocalPath,$remotePath) | Set-Content -LiteralPath $batchFile -Encoding Ascii
    $identity = "$($cfg.receiver_username)@$($cfg.receiver_ip)"
    Write-Host "DELIVER: SFTP $staged -> $identity`:$remotePath"
    & $sftp -b $batchFile -i $cfg.ssh_private_key -P 22 -o 'BatchMode=yes' -o 'StrictHostKeyChecking=yes' -o "UserKnownHostsFile=$($cfg.ssh_known_hosts)" -o 'IdentitiesOnly=yes' $identity
    if ($LASTEXITCODE -ne 0) { throw "SFTP failed, exit code $LASTEXITCODE" }
    # Separate authenticated SSH checksum acknowledgment on the isolated LAN only.
    $remoteCommand = "sha256sum -- '$remotePath'"
    $remoteHashOutput = & $ssh -i $cfg.ssh_private_key -p 22 -o 'BatchMode=yes' -o 'StrictHostKeyChecking=yes' -o "UserKnownHostsFile=$($cfg.ssh_known_hosts)" -o 'IdentitiesOnly=yes' $identity $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw 'Receiver hash acknowledgment failed.' }
    $remoteHash = ((@($remoteHashOutput) -join ' ').Trim() -split '\s+')[0].ToLowerInvariant()
    if ($remoteHash -ne $sha) { throw "HASH MISMATCH local=$sha remote=$remoteHash" }
    Close-Gateway $cfg
    Assert-AdapterIsolation $cfg 'none'
    Write-GatewayLog 'FINISH' "$filename sha256=$sha bytes=$($record.length)"
    Write-Host "SUCCESS: receiver verified SHA256 $sha" -ForegroundColor Green
    if ($cfg.delete_after_confirmation) { Remove-Item -LiteralPath $staged -Force; Remove-Item -LiteralPath $manifest -Force }
} catch {
    Write-GatewayLog 'FAULT' "phase=$phase detail=$_"
    Write-Error "FAULT in $phase`: $_"
    throw
} finally {
    Close-Gateway $cfg
    Remove-Item -LiteralPath $batchFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $locked -Force -ErrorAction SilentlyContinue
    # The firewall remains default DENY at idle. Restore ordinary rules only with Stop-Lockdown.ps1.
}
