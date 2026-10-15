# Hyper-V Workshop Lab on Azure

On-demand Hyper-V training lab: Windows Server 2025 Azure VMs with nested virtualization, ready to host nested Windows Server 2025 guests.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fkaustubh93-dev%2FHyper-V-Workshop%2Fmain%2Ftemplate%2Ftemplate.json)

The portal prompts for a resource group, region, and admin password (min 12 chars). Everything else has defaults.

### Or deploy with PowerShell

Requires the `Az.Accounts`, `Az.Resources`, and `Az.Compute` modules.

```powershell
Connect-AzAccount
# Full rebuild: hosts + MSLab (DC + 3 Server 2025 nodes per host)
./scripts/deploy.ps1 -WithMSLab
# Hosts only
./scripts/deploy.ps1 -SubscriptionId <sub-id> -ResourceGroupName rg-hyperv-training-eus2 -Location eastus2
# Preview only
./scripts/deploy.ps1 -WhatIf
```

`deploy.ps1` checks vCPU quota for the chosen VM size before deploying. Edit [template/parameters.json](template/parameters.json) to change host count, VM size, shutdown time, etc.

## What gets deployed

| Resource | Details |
|---|---|
| Hyper-V hosts | `HYD-HOST-1..N` (default 2), `Standard_E4s_v5`, Windows Server 2025 Datacenter Gen2, Trusted Launch |
| Data disk | 1 TB Premium SSD per host, formatted as `V:` (VMs in `V:\VMs`, MSLab in `V:\MSLab`, ISO in `V:\ISO\Server2025`) |
| Network | VNet `172.16.0.0/16`, NSG allowing RDP only from Azure Bastion, no public IPs |
| Azure Bastion | Developer SKU (free, one session at a time) |
| Auto-shutdown | Daily at 21:00 India Standard Time |
| Host setup | Run Command executes [scripts/setup-host.ps1](scripts/setup-host.ps1): installs Hyper-V, reboots, creates `InternalNAT` internal switch + NAT (`192.168.0.0/24`, gateway `.1`) and a DHCP scope (`.100-.199`) |
| MSLab (`-WithMSLab`) | [scripts/mslab-host.ps1](scripts/mslab-host.ps1) on each host: MSLab v26.07.1, Server 2025 eval ISO, parent disks, `MSLab-DC` (`corp.contoso.com`) and `MSLab-Node1..3` (5 GB, 2 vCPU, 4x100 GB disks, `Storage1`/`Storage2` networks) |

## MSLab

Hydration runs in a background task on each host (~1.5 h). Start it after deploy, or rerun it if interrupted:

```powershell
./scripts/deploy-mslab.ps1 -ResourceGroupName rg-hyperv-training-eus2           # start / resume
./scripts/deploy-mslab.ps1 -ResourceGroupName rg-hyperv-training-eus2 -Status   # expect COMPLETE VMs: MSLab-DC, MSLab-Node1..3
```

Logs: `C:\MSLabSetup\status.txt`, `C:\MSLabSetup\mslab-host.log`, `V:\MSLab\*.log`. Lab credentials: `CORP\LabAdmin` / `LS1setup!`. The DC routes to the internet through `InternalNAT` (static `192.168.0.2`).

Start before ~19:00 IST so the 21:00 auto-shutdown doesn't interrupt hydration.

## After deployment

Allow ~10-15 minutes for Hyper-V install and reboot. Connect via **Azure portal > VM > Connect > Bastion**, then verify:

```powershell
Get-Content C:\HyperVSetup\status.txt   # expect COMPLETE
```

Logs are in `C:\HyperVSetup`. Nested guests on `InternalNAT` get DHCP addresses in `192.168.0.100-199` (gateway `192.168.0.1`).

### Bastion says "target machine is unreachable"

Defender for Cloud JIT on some subscriptions removes the NSG rule that lets Bastion Developer (`168.63.129.16`) reach RDP. Re-add it:

```powershell
./scripts/fix-bastion-nsg.ps1 -ResourceGroupName rg-hyperv-training-eus2
```

## Cost and cleanup

Roughly $0.87/hour for two hosts while running. The 1 TB Premium disks bill even when the VMs are stopped.

```powershell
./scripts/teardown.ps1 -ResourceGroupName <rg>            # delete everything
./scripts/teardown.ps1 -ResourceGroupName <rg> -StopOnly  # deallocate hosts only
```
