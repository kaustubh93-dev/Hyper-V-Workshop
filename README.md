# Hyper-V Workshop Lab on Azure

On-demand Hyper-V training lab: Windows Server 2025 Azure VMs with nested virtualization. Each host can be pre-built with an MSLab domain controller and Windows Server 2025 guest VMs so students start straight on nodes, networking and clustering.

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

## MSLab: domain controller and guest VMs

`-WithMSLab` (or `deploy-mslab.ps1`) uses [MSLab](https://github.com/microsoft/MSLab) to build a ready-to-use lab on **each** host:

1. Downloads MSLab v26.07.1 and the Windows Server 2025 evaluation ISO.
2. Converts the ISO into parent (differencing) disks: `Win2025_G2.vhdx` (Desktop Experience) and `Win2025Core_G2.vhdx` (Server Core).
3. Builds and promotes the domain controller `MSLab-DC` for `corp.contoso.com` (DNS, DHCP, NAT to the internet).
4. Creates the guest VMs `MSLab-Node1..3` from the Core parent disk and joins them to the domain.

### Lab layout (per host)

| VM | OS | vCPU / RAM | Disks | Network |
|---|---|---|---|---|
| `MSLab-DC` | Server 2025 Datacenter (GUI) | 2 / 2 GB | OS | `Internet` 192.168.0.2 (InternalNAT), `Management1` 10.0.0.1 |
| `MSLab-Node1..3` | Server 2025 Core | 2 / 5 GB | OS + 4 x 100 GB (for S2D) | `Management1/2` DHCP 10.0.0.x, `Storage1` 10.10.1.N (VLAN 1), `Storage2` 10.10.2.N (VLAN 2) |

| Switch | Type | Purpose |
|---|---|---|
| `InternalNAT` | Internal | Host NAT to the internet (192.168.0.0/24); only the DC is attached |
| `MSLab-LabSwitch` | Private | Lab network: management 10.0.0.0/24 plus Storage1/Storage2 VLANs |

The storage VLANs have no DHCP server, so after Deploy the script renames each node's storage NICs to `Storage1`/`Storage2` and assigns static IPs (`NodeN` gets `10.10.1.N` and `10.10.2.N`, /24). Without this they would sit on APIPA (169.254.x.x) addresses. Students can go straight to SET switches, clustering and S2D.

**Credentials:** `CORP\LabAdmin` / `LS1setup!` (domain and local Administrator).

### Run and monitor

Hydration runs as a background task on each host (~1.5 h). Start it after deploy, or rerun it to resume if interrupted:

```powershell
./scripts/deploy-mslab.ps1 -ResourceGroupName rg-hyperv-training-eus2           # start / resume
./scripts/deploy-mslab.ps1 -ResourceGroupName rg-hyperv-training-eus2 -Status   # expect COMPLETE VMs: MSLab-DC, MSLab-Node1..3
```

Logs: `C:\MSLabSetup\status.txt`, `C:\MSLabSetup\mslab-host.log`, `V:\MSLab\*.log`. Start before ~19:00 IST so the 21:00 auto-shutdown doesn't interrupt hydration. Change node count or memory with `-NodeCount` (0-6) and `-NodeMemoryGB` (2-16).

### Student access

1. Azure portal > `HYD-HOST-1` (or `-2`) > **Connect > Bastion**, sign in as `labadmin`.
2. Open **Hyper-V Manager** and connect to `MSLab-DC` (or a node) with `CORP\LabAdmin` / `LS1setup!`.
3. Manage nodes from the DC (Server Manager, Failover Cluster Manager, PowerShell remoting). Guest computer names drop the `MSLab-` prefix, e.g. `Enter-PSSession Node1`.

To add more guests, edit `V:\MSLab\LabConfig.ps1` on the host and run `V:\MSLab\Deploy.ps1` again; existing VMs are kept.

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
./scripts/start-lab.ps1                                   # start hosts + MSLab VMs (use this instead of the portal Start button)
./scripts/teardown.ps1 -ResourceGroupName <rg> -StopOnly  # deallocate hosts only
./scripts/teardown.ps1 -ResourceGroupName <rg>            # delete everything
```

`start-lab.ps1` handles Azure capacity shortages: if `Standard_E4s_v5` isn't available in the zone, it resizes the stopped host to the next nested-virtualization size (`E4s_v4`, `D8s_v5`, `D8s_v4`, `E8s_v5`) and retries. Lab VMs are set to shut down (not save state) with the host and auto-start with it, DC first, so they boot cleanly even on a different CPU after a resize.
