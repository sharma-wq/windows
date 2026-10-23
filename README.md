# Windows Native Data Diode Gateway — controlled proof of concept

This is the **Windows PowerShell port** of the Raspberry Pi store-and-forward gateway concept. It is **not** an executable hardware data diode. Windows Defender Firewall and PowerShell switch between two NICs while one program fetches approved HTTPS data and OpenSSH delivers that file to an isolated SFTP receiver. Hash verification and phase logging are provided.

**Status:** Static structure and JSON syntax checked during packaging. Live Windows firewall/NIC/SFTP behavior **has not been run or certified** in the author's environment. Test inside a dedicated snapshot-capable Windows 10/11 Pro or Enterprise VM with TWO virtual Ethernet adapters and local console first.

## Safety and limitations

- **Do NOT run `Start-Lockdown.ps1 -Execute` on the laptop you use for Internet access, remote access, office networking, or production work.** It intentionally disables all local ALLOW firewall rules and both configured NICs. It can disconnect the machine. You must use a spare Windows computer or a dedicated VM with a console and a snapshot.
- `Test-Configuration.ps1`, `Test-Simulated-Cycle.ps1`, and `Invoke-Gateway.ps1` without `-Execute` are non-destructive.
- Windows Defender Firewall `-Program` matches an executable **path**, not an isolated Linux UID. A different process running the same allowed program binary may reuse that permission. OpenSSH SFTP also involves `ssh.exe`; both executable paths are permitted in the delivery phase. Consequently this is a **prototype application allowlist**, not the same per-service identity assurance as the Linux SRS.
- Existing enabled ALLOW rules can defeat a default-outbound-block policy. `Start-Lockdown.ps1` backs up the firewall and disables locally configurable enabled ALLOW rules and refuses to continue if any effective ALLOW rules remain (for example GPO rules). Test with a VM snapshot. There can be Windows platform exceptions beyond ordinary firewall rules; verify with packet captures and system tests.
- Phase switching uses Windows administrative NIC disable/enable, not physical one-way media or a tamper-resistant mechanism. There may be race windows, startup windows, administrator bypasses, Windows Filtering Platform exceptions, and fail-open behavior on kernel compromise. The optional startup scheduled task runs *after* some networking begins; it is not early-boot isolation.
- No router port forwarding is required. Approved transfers initiate outbound TCP connections only.
- No antivirus or content sanitization is implemented. SHA-256 checks integrity relative to the fetched copy, not whether files are safe. TLS uses Windows trusted certificates; SFTP requires a **preverified** `known_hosts` file.
- Do not disable the network adapter currently used by RDP or SSH. The scripts reject detected RDP/SSH sessions but this is not a complete remote-session detector.
- Manually configure two STATIC IPv4 NIC addresses in the VM, without default gateways. The source-specific `/32` route is created temporarily for the HTTPS source IP through `internet_next_hop`. `Get-NetRoute` must show no IPv4/IPv6 default route.
- The **source and receiver are example addresses**, not functional servers. You must provision a trusted HTTPS server and SFTP receiver first.

## Files

| File | Purpose |
|---|---|
| `config.example.json` | Network interfaces, destination IP/hostnames, SSH key, staging disk |
| `Common.ps1` | Validation, NIC protection, firewall rules, cleanup, logging |
| `Test-Configuration.ps1` | SAFE: inspect configuration, NICs, routing, firewall state |
| `Test-Simulated-Cycle.ps1` | SAFE: copy test data between folders and compare SHA-256 |
| `Start-Lockdown.ps1` | DANGEROUS: opt-in backup/default-deny/disable existing ALLOW rules/NICs |
| `Invoke-Gateway.ps1` | Dry-run by default; `-Execute` performs live HTTPS -> staging -> SFTP |
| `Close-Gateway.ps1` | Emergency: disable both gateway interfaces and clear temporary rules |
| `Stop-Lockdown.ps1` | Emergency restoration of prior firewall rules and NIC state |
| `Register-SafeStart.ps1` | Optional best-effort at-startup cleanup (not early boot fail-closed) |

## A. SAFE quick start on Windows + VS Code

1. Extract ZIP somewhere like `C:\Projects\Data_Diode_Windows_Native`.
2. Open the folder in VS Code. In Terminal select **PowerShell**, not CMD.
3. Copy the example config:

```powershell
Copy-Item .\config.example.json .\config.json
```

4. Run the file-only demonstration (safe to run on your normal laptop):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Simulated-Cycle.ps1
```

5. Inspect your network settings, no changes made:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Configuration.ps1
```

6. See the live operation PLAN without running it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Gateway.ps1
```

Expected result: the demo reports a matching SHA-256 hash and the dry run describes FETCH/HOLD/DELIVER/FINISH. This is a mock, not real firewall proof.

## B. LIVE Windows VM proof (requires two interfaces and a separate receiver)

**Only on a throwaway Windows VM at its local graphical console, with a snapshot.** PowerShell must be **Run as Administrator**.

1. Change `config.json` so interface aliases match `Get-NetAdapter`; replace source IP+hostname, receiver IP+user, the key, `known_hosts` and staging drive. Do not use sample 203.0.113.20 or `.test` host.
2. In Windows IP settings manually set gateway WAN NIC e.g. `192.168.1.20/24` **without a default gateway**, and local NIC e.g. `192.168.50.1/24` **without a default gateway**. Use separate virtual switches/segments. `internet_next_hop` is the WAN router, e.g. `192.168.1.1`. If DHCP re-inserts routes, adjust the VM network configuration first. Disable all other NICs including Wi-Fi and virtual VPN adapters.
3. Prepare a trusted HTTPS endpoint with a valid certificate matching `source_hostname`. The `curl.exe --resolve` flag pins that hostname to source_ip, so no DNS request is required.
4. Prepare a Linux SFTP server reachable over the local segment, `receiver_username` with write rights to `receiver_directory` and read rights for `sha256sum`. Provision SSH key authentication and put the **verified** server host key in `ssh_known_hosts`. Never automatically accept an unknown host key.
5. Ensure `staging_directory` exists on a test disk (e.g., `D:\DiodeStore`). For final hardware use a properly attached 4 TB disk with access control.
6. Review `Test-Configuration.ps1`; verify `Get-NetRoute` has no default route.
7. Snapshot VM. Open LOCAL Administrator PowerShell and invoke **lockdown**:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Lockdown.ps1 -Execute -Acknowledge LOCKDOWN
```

You must also type `YES` on the local console. The tool saves prior firewall rules at `state\firewall-before-lockdown.wfw`, disables existing enabled local ALLOW rules, and leaves both adapters disabled. If other effective ALLOW rules remain, it refuses live transfer and attempts restoration. Domain policy can defeat this scheme.

8. Run the live transfer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Gateway.ps1 -Execute
```

Flow: both NIC DOWN -> FETCH: WAN enabled, firewall only `curl.exe`, source IP TCP443, temporary /32 route -> download to `.partial` -> both NIC DOWN -> hash/manifest -> DELIVER: LAN enabled, only SFTP/SSH binaries to server IP TCP22 -> server `sha256sum` confirmation -> both NIC DOWN -> optional confirmed deletion. A successful run **does not restore general Internet**; lockdown remains active until you explicitly restore.

9. Inspect status and logs:

```powershell
Get-NetAdapter | Format-Table Name,Status,AdminStatus
Get-NetFirewallRule -Name 'DDGW-PHASE-*' -ErrorAction SilentlyContinue
Get-NetFirewallProfile | Format-Table Name,DefaultOutboundAction
Get-Content .\state\events.jsonl -Tail 20
```

### Emergency shutdown versus restore

Stop just the transfer network paths (leave default-deny in place):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Close-Gateway.ps1
```

Restore firewall and NIC state from backup (RE-ENABLES previous firewall permissions and interfaces):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Lockdown.ps1 -Execute
```

If the PowerShell restore tool fails, from an elevated LOCAL console use the last resort (replace paths if different):

```powershell
netsh advfirewall import "C:\Projects\Data_Diode_Windows_Native\state\firewall-before-lockdown.wfw"
Enable-NetAdapter -Name "Ethernet" -Confirm:$false
Enable-NetAdapter -Name "Ethernet 2" -Confirm:$false
```

The `netsh import` replaces the current local firewall policy with the snapshot. Review `Get-NetFirewallProfile` afterward. Use VM rollback if restoration is incomplete.

## Acceptance checks and unfinished areas

- Approved HTTPS `curl.exe` download works, certificate validated and hash saved.
- Wrong IP, port 80, or another program cannot reach either network during the specified phase.
- `Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Action Allow` must show only current DDGW phase rules; both phase allowlists must never coexist.
- Both NICs down after each phase, and on exceptions; no default IPv4 or IPv6 route; forwarding/bridging disabled.
- Server SFTP receives actual bytes with pretrusted host key; remote SHA-256 equals local staged hash. Server verification does not necessarily prove permanent disk persistence; add server-side durable acknowledgement if needed.
- Test adapter fault injection, forced process termination, early-boot, Windows update, unexpected virtual adapters, and reboot separately. Not certified by current code.
- Large transfers need separate transfer deadlines; current configuration defaults to `3600` seconds for curl, not the SRS 120-second limit. Record approval to change this.
- The scripts cannot guarantee that a Windows administrator, malware with elevated privileges, or a compromised kernel will not bypass the software enforcement. Hardware enforcement requires separate hardware.

## Microsoft reference docs

- Windows Defender Firewall `New-NetFirewallRule`: https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule
- `Set-NetFirewallProfile`: https://learn.microsoft.com/powershell/module/netsecurity/set-netfirewallprofile
- `Disable-NetAdapter`: https://learn.microsoft.com/powershell/module/netadapter/disable-netadapter
- `New-NetRoute`: https://learn.microsoft.com/powershell/module/nettcpip/new-netroute
