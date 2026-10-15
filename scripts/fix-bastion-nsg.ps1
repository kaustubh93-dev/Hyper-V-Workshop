#Requires -Modules Az.Network
<#
.SYNOPSIS
    Re-adds the Bastion Developer RDP allow rule that Defender JIT / subscription policy strips from the NSG.
.EXAMPLE
    .\scripts\fix-bastion-nsg.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    [string]$NsgName = 'HYD-HOST-nsg'
)

$ErrorActionPreference = 'Stop'
$ruleName = 'Allow-RDP-From-Bastion-Developer'

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NsgName
if ($nsg.SecurityRules | Where-Object Name -eq $ruleName) {
    Write-Host "$ruleName already present on $NsgName." -ForegroundColor Green
    return
}

$nsg | Add-AzNetworkSecurityRuleConfig -Name $ruleName -Priority 300 -Direction Inbound -Access Allow `
    -Protocol Tcp -SourceAddressPrefix '168.63.129.16' -SourcePortRange '*' `
    -DestinationAddressPrefix '*' -DestinationPortRange 3389 | Set-AzNetworkSecurityGroup | Out-Null
Write-Host "Re-added $ruleName to $NsgName. Retry the Bastion connection." -ForegroundColor Green
