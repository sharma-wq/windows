# Safe: operates only on temporary files; does NOT invoke Windows Firewall or network adapter cmdlets.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('ddgw-windows-demo-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$stage = Join-Path $root 'stage'
$received = Join-Path $root 'received'
foreach ($p in @($source,$stage,$received)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
$states = @()
try {
    $payload = Join-Path $source 'payload.bin'
    [System.IO.File]::WriteAllBytes($payload,[Text.Encoding]::UTF8.GetBytes('Data Diode Windows test payload - no live network operations'))
    $states += 'IDLE eth0=DOWN eth1=DOWN rules=none'
    $states += 'FETCH eth0=UP eth1=DOWN rule=curl to TCP443 (simulation)'
    Copy-Item -LiteralPath $payload -Destination (Join-Path $stage 'payload.bin')
    $states += 'HOLD eth0=DOWN eth1=DOWN rules=none'
    $stageFile = Join-Path $stage 'payload.bin'
    $digest = (Get-FileHash -LiteralPath $stageFile -Algorithm SHA256).Hash
    $states += 'DELIVER eth0=DOWN eth1=UP rule=sftp/ssh to TCP22 (simulation)'
    Copy-Item -LiteralPath $stageFile -Destination (Join-Path $received 'payload.bin')
    $actual = (Get-FileHash -LiteralPath (Join-Path $received 'payload.bin') -Algorithm SHA256).Hash
    if ($actual -ne $digest) { throw 'SHA mismatch (simulated transfer)' }
    $states += 'FINISH eth0=DOWN eth1=DOWN rules=none'
    $states | ForEach-Object { Write-Host $_ }
    Write-Host "PASS - simulated Windows fetch/HOLD/deliver/integrity ($digest)" -ForegroundColor Green
    Write-Host 'This does not test the real Windows Firewall or physical adapters.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
