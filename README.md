# Hyper-V Workshop Lab on Azure

On-demand Hyper-V training lab: Windows Server 2025 Azure VMs with nested virtualization. Each host is pre-built with an MSLab domain controller and Windows Server 2025 guest VMs so students start straight on nodes, networking and clustering.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fkaustubh93-dev%2FHyper-V-Workshop%2Fmain%2Ftemplate%2Ftemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fkaustubh93-dev%2FHyper-V-Workshop%2Fmain%2Ftemplate%2FcreateUiDefinition.json)

Tip: **Ctrl+click** (Cmd+click on macOS) the button to open the portal in a new tab.

Select your subscription, resource group and region first, then choose a host count, zone and VM size in the portal's live size selector. Only documented nested-virtualization families **Dsv5, Dasv5, Esv5 and Easv5** with x64/Gen2 support, at least 4 vCPUs and 32 GB RAM are offered. Individual sizes are discovered dynamically, not limited to the old shortlist. Unknown families are excluded until verified. Supply the host administrator password (min 12 chars). The template does the full build on its own:

For all advanced parameters, use the [plain ARM deployment form](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fkaustubh93-dev%2FHyper-V-Workshop%2Fmain%2Ftemplate%2Ftemplate.json). Its VM size is free text and bypasses the portal filter: run the preflight below before deploying directly with ARM. Leave **Host Setup Script** and **Mslab Setup Script** empty to download the scripts from this repo.

1. Deploys the hosts, network, Bastion and auto-shutdown (~15-20 min until the portal shows **Succeeded**).
2. Installs Hyper-V and the `InternalNAT` network on each host (run command `setup-hyperv`).
3. Queues the MSLab build on each host (run command `setup-mslab`): DC plus the configured number of nodes. This keeps running **~1.5 h after the portal shows Succeeded** (see [Check progress](#check-progress)).
4. Connect through Bastion. Standard supports shareable links; Developer is the no-public-IP default and requires users to have Azure access.

Deploy before ~19:00 IST so the 21:00 auto-shutdown doesn't interrupt the MSLab build.

> [!IMPORTANT]
> **Browser shareable links require Bastion Standard.** Standard needs a public IP; on some subscriptions, first register this feature and re-register the provider from Azure Cloud Shell or Az PowerShell. **Bastion Developer is the default** and avoids the public-IP prerequisite, but is portal-only and requires users to sign in to Azure.

```powershell
Register-AzProviderFeature -ProviderNamespace Microsoft.Network -FeatureName AllowBringYourOwnPublicIpAddress
Register-AzResourceProvider -ProviderNamespace Microsoft.Network
```

If the feature isn't registered or permitted, keep **Bastion Sku** = `Developer`.

### Key parameters

| Parameter | Default | Notes |
|---|---|---|
| Host Count | 2 | 1-6 Hyper-V hosts `HYD-HOST-1..N` |
| Vm Size | `Standard_D8as_v5` recommendation | Portal discovers compatible sizes within documented nested-Hyper-V families; preflight rejects unverified families and undersized hosts |
| Zone | `2` | Select a zone offered in your subscription and region; restrictions can change |
| Bastion Sku | `Developer` | No public IP prerequisite; choose `Standard` for shareable links after its feature precheck passes |
| Deploy MS Lab | `true` | `false` deploys bare Hyper-V hosts |
| Mslab Node Count / Memory GB | 3 / 5 | Nodes per host |
| Auto Shutdown Time / Time Zone | 21:00 / India Standard Time | |

## What gets deployed

| Resource | Details |
|---|---|
| Hyper-V hosts | `HYD-HOST-1..N` (default 2, maximum 6), `Standard_D8as_v5` (8 vCPU / 32 GB), Windows Server 2025 Datacenter Gen2, Trusted Launch |
| Data disk | 1 TB Premium SSD per host, formatted as `V:` (VMs in `V:\VMs`, MSLab in `V:\MSLab`, ISO in `V:\ISO\Server2025`) |
| Network | VNet `172.16.0.0/16`, NSG allowing RDP only from Azure Bastion, no public IPs on the hosts |
| Azure Bastion | **Developer** (default, portal-only, no public IP prerequisite) or **Standard** (shareable links, public IP, additional cost and subscription prerequisites) |
| Auto-shutdown | Daily at 21:00 India Standard Time |
| Host setup | Run Command executes [scripts/setup-host.ps1](scripts/setup-host.ps1): installs Hyper-V, reboots, creates `InternalNAT` internal switch + NAT (`192.168.0.0/24`, gateway `.1`) and a DHCP scope (`.100-.199`) |
| MSLab | Run Command executes [scripts/mslab-host.ps1](scripts/mslab-host.ps1) on each host: MSLab v26.07.1, Server 2025 eval ISO, parent disks, `MSLab-DC` (`corp.contoso.com`) and `MSLab-Node1..3` (5 GB, 2 vCPU, 4x100 GB disks, `Storage1`/`Storage2` networks) |

## Capacity preflight

Before ARM or Terraform deployment, check the selected SKU, zone restrictions, and how many additional hosts current family/core quota supports:

```powershell
.\scripts\check-host-capacity.ps1 -Location eastus2 -Zone 2 -VmSize Standard_D8as_v5 -HostCount 6 -BastionSku Developer
```

To discover nested-Hyper-V-compatible VM sizes for another subscription and region instead of choosing from a fixed size list:

```powershell
.\scripts\check-host-capacity.ps1 -SubscriptionId '<subscription-id>' -Location eastus2 -Zone 2 -HostCount 2 -ListSizes
```

This lists only verified Dsv5, Dasv5, Esv5 and Easv5 family members with x64/Gen2 support, at least 4 vCPUs and 32 GB RAM, and shows their zone restrictions and quota-supported additional hosts. A single `-VmSize` check rejects unsupported or unverified sizes. Azure does not expose a universal nested-virtualization capability flag; `HyperVGenerations=V2` alone is not proof of nesting support. Missing quota is reported as unverified. Rerun with `-VmSize` to check Bastion prerequisites too. Quota eligibility is not a capacity reservation, and adding SKU choices cannot bypass regional/family quota limits.

Family support references: [Dsv5](https://learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dsv5-series), [Dasv5](https://learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dasv5-series), [Esv5](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv5-series), [Easv5](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/easv5-series). Increase host RAM when increasing node count or node memory beyond the defaults. If the portal compatibility query fails, returns no candidates, or is paginated, the selector deliberately offers no deployable size; use CLI preflight instead.

The check also verifies public-IP feature/provider prerequisites when `-BastionSku Standard` is selected. Quota and SKU restrictions are checkable; **live compute capacity is not reserved by this preflight and can change before Azure allocates VMs**. If the selected SKU is restricted, try another supported size or zone.

## MSLab: domain controller and guest VMs

The template uses [MSLab](https://github.com/microsoft/MSLab) to build a ready-to-use lab on **each** host:

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

The storage VLANs have no DHCP server, so after the build each node's storage NICs are renamed to `Storage1`/`Storage2` and given static IPs (`NodeN` gets `10.10.1.N` and `10.10.2.N`, /24). Students can go straight to SET switches, clustering and S2D.

**Credentials:** `CORP\LabAdmin` / `LS1setup!` (domain and local Administrator).

To add more guests, edit `V:\MSLab\LabConfig.ps1` on a host and run `V:\MSLab\Deploy.ps1` again; existing VMs are kept.

## Check progress

Portal > `HYD-HOST-1` (and `-2`) > **Operations > Run command > RunPowerShellScript**:

```powershell
Get-Content C:\HyperVSetup\status.txt          # Hyper-V + InternalNAT: expect COMPLETE
Get-Content C:\MSLabSetup\status.txt -Tail 5   # MSLab: expect COMPLETE VMs: MSLab-DC, MSLab-Node1..3
Get-VM | Format-Table Name, State
```

More detail: `C:\MSLabSetup\mslab-host.log` and `V:\MSLab\*.log`. If the host restarts mid-build, the MSLab task resumes automatically at boot.

## Share the lab with students

With **Bastion Standard**, students need only a browser, not an Azure account, VPN or RDP client. With **Bastion Developer**, users need an Azure account with access to the subscription and connect through the portal.

1. Portal > resource group > **vnet-hyperv-training-bastion** > **Shareable links** > **+ Add**.
2. Select `HYD-HOST-1` and/or `HYD-HOST-2`, optionally set an **Expiration**, then **Apply**.
3. Copy each link and send it to the students for that host, together with the host account (`labadmin` and the password chosen at deploy).
4. Students open the link, sign in, then open **Hyper-V Manager** and connect to `MSLab-DC` or a node with `CORP\LabAdmin` / `LS1setup!`. Manage nodes from the DC (Server Manager, Failover Cluster Manager, PowerShell remoting). Guest computer names drop the `MSLab-` prefix, e.g. `Enter-PSSession Node1`.
5. After class, select the links on the same page and **Delete** them.

Links carry no credentials and the hosts have no public IP or open port. Each host allows **2 concurrent RDP sessions**, and two people signing in with the same account take over each other's session, so plan one account per student per host.

Users with Azure access can also use portal > VM > **Connect > Bastion**.

## Troubleshooting

**Bastion says "target machine is unreachable".** Defender for Cloud JIT on some subscriptions removes the NSG rule that lets Bastion reach RDP. Portal > `HYD-HOST-nsg` > **Inbound security rules** > **+ Add**: source IP `172.16.1.0/26` (Bastion Standard) or `168.63.129.16` (Bastion Developer), destination port `3389`, TCP, Allow, priority `310`.

**VM won't start: "requested VM size is currently not available".** Azure capacity can change after preflight. Run `scripts/start-lab.ps1` to try the configured diskless nested-virtualization sizes; if all fail, check another eligible zone or retry later. Lab VMs shut down cleanly with the host and auto-start with it (DC first), so they boot after a resize.

**Nested networking.** Guests on `InternalNAT` get DHCP addresses in `192.168.0.100-199` (gateway `192.168.0.1`). Host setup logs are in `C:\HyperVSetup`.

## Cost and cleanup

Compute cost depends on host size/count and Bastion SKU. Deallocating hosts ends compute charges, but managed disks continue to bill. Standard Bastion has hourly charges; Developer is free.

- **Pause:** portal > each VM > **Stop** (deallocate). **Start** them again before class.
- **Remove everything:** portal > resource group > **Delete resource group**, then type its name to confirm. This deletes the hosts, disks, Bastion, public IP, network and schedules.
