#Requires -Modules Az.Network
<#
.SYNOPSIS
    Re-adds the Bastion RDP allow rules that Defender JIT / subscription policy strips from the NSG.
.EXAMPLE
    .\scripts\fix-bastion-nsg.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    [string]$NsgName = 'HYD-HOST-nsg',
    [string]$BastionSubnetPrefix = '172.16.1.0/26'
)

$ErrorActionPreference = 'Stop'
# Developer SKU connects from the Azure platform IP; Standard SKU from AzureBastionSubnet
$rules = @(
    @{ Name = 'Allow-RDP-From-Bastion-Developer'; Priority = 300; Source = '168.63.129.16' }
    @{ Name = 'Allow-RDP-From-Bastion-Subnet'; Priority = 310; Source = $BastionSubnetPrefix }
)

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NsgName
$missing = @($rules | Where-Object { $_.Name -notin $nsg.SecurityRules.Name })
if (-not $missing) {
    Write-Host "Bastion RDP rules already present on $NsgName." -ForegroundColor Green
    return
}

foreach ($rule in $missing) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name $rule.Name -Priority $rule.Priority -Direction Inbound -Access Allow `
        -Protocol Tcp -SourceAddressPrefix $rule.Source -SourcePortRange '*' `
        -DestinationAddressPrefix '*' -DestinationPortRange 3389 | Out-Null
}
$nsg | Set-AzNetworkSecurityGroup | Out-Null
Write-Host "Re-added $($missing.Name -join ', ') to $NsgName. Retry the Bastion connection." -ForegroundColor Green
