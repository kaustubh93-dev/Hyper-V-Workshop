# Hyper-V Workshop Lab on Azure

On-demand Hyper-V training lab: Windows Server 2025 Azure VMs with nested virtualization, ready to host nested Windows Server 2025 guests.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fkaustubh93-dev%2FHyper-V-Workshop%2Fmain%2Ftemplate%2Ftemplate.json)

The portal prompts for a resource group, region, and admin password (min 12 chars). Everything else has defaults.

### Or deploy with PowerShell

Requires the `Az.Accounts`, `Az.Resources`, and `Az.Compute` modules.

```powershell
Connect-AzAccount
./scripts/deploy.ps1 -SubscriptionId <sub-id> -ResourceGroupName rg-hyperv-training -Location eastus2
# Preview only
./scripts/deploy.ps1 -WhatIf
# Also download the Server 2025 evaluation ISO to V:\ISO on each host
./scripts/deploy.ps1 -Server2025IsoUrl 'https://go.microsoft.com/fwlink/?linkid=<from-eval-center>'
```

`deploy.ps1` checks vCPU quota for the chosen VM size before deploying. Edit [template/parameters.json](template/parameters.json) to change host count, VM size, shutdown time, etc.

## What gets deployed

| Resource | Details |
|---|---|
| Hyper-V hosts | `HYD-HOST-1..N` (default 2), `Standard_E4s_v5`, Windows Server 2025 Datacenter Gen2, Trusted Launch |
| Data disk | 1 TB Premium SSD per host, formatted as `V:` (VMs in `V:\VMs`, ISOs in `V:\ISO`) |
| Network | VNet `172.16.0.0/16`, NSG allowing RDP only from Azure Bastion, no public IPs |
| Azure Bastion | Developer SKU (free, one session at a time) |
| Auto-shutdown | Daily at 21:00 India Standard Time |
| Host setup | Run Command executes [scripts/setup-host.ps1](scripts/setup-host.ps1): installs Hyper-V, reboots, creates `NestedNAT` internal switch + NAT (`192.168.100.0/24`, gateway `.1`) |

## After deployment

Allow ~10-15 minutes for Hyper-V install and reboot. Connect via **Azure portal > VM > Connect > Bastion**, then verify:

```powershell
Get-Content C:\HyperVSetup\status.txt   # expect COMPLETE
```

Logs are in `C:\HyperVSetup`. Give nested guests a static IP in `192.168.100.0/24` with gateway `192.168.100.1`.

## Cost and cleanup

Roughly $0.87/hour for two hosts while running. The 1 TB Premium disks bill even when the VMs are stopped.

```powershell
./scripts/teardown.ps1 -ResourceGroupName <rg>            # delete everything
./scripts/teardown.ps1 -ResourceGroupName <rg> -StopOnly  # deallocate hosts only
```
