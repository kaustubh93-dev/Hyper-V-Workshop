#Requires -Modules Az.Accounts, Az.Network, Az.Compute
<#
.SYNOPSIS
    Creates, lists or removes Azure Bastion shareable links (browser RDP without Azure accounts) for the lab hosts.
.DESCRIPTION
    Requires the Bastion Standard SKU (template parameter bastionSku = Standard). Links carry no credentials:
    students sign in with the host account you give them. Remove links after each class.
.EXAMPLE
    ./bastion-links.ps1            # create (or show existing) links for all hosts
.EXAMPLE
    ./bastion-links.ps1 -Remove    # revoke all links
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null }

$bastion = Get-AzBastion -ResourceGroupName $ResourceGroupName | Select-Object -First 1
if (-not $bastion) { throw "No Azure Bastion found in $ResourceGroupName." }
if ($bastion.Sku.Name -eq 'Developer' -or -not $bastion.EnableShareableLink) {
    throw "Bastion '$($bastion.Name)' is $($bastion.Sku.Name) without shareable links. Redeploy with bastionSku=Standard."
}

$vmIds = @(Get-AzVM -ResourceGroupName $ResourceGroupName | Sort-Object Name | ForEach-Object Id)
$common = @{ ResourceGroupName = $ResourceGroupName; Name = $bastion.Name; TargetVmId = $vmIds }

if ($Remove) {
    Remove-AzBastionShareableLink @common -Force | Out-Null
    Write-Host "Removed shareable links for $($vmIds.Count) host(s)." -ForegroundColor Green
    return
}

New-AzBastionShareableLink @common | Out-Null
Get-AzBastionShareableLink @common | ForEach-Object {
    [pscustomobject]@{ Host = ($_.Vm.Id -split '/')[-1]; Link = $_.Bsl }
} | Format-Table -AutoSize -Wrap
Write-Host 'Send each student one link. They open it in a browser and sign in with the host account (e.g. labadmin).' -ForegroundColor Cyan
Write-Host 'Revoke after class: ./bastion-links.ps1 -Remove' -ForegroundColor Yellow
