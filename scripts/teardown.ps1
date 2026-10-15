#Requires -Modules Az.Accounts, Az.Resources, Az.Compute
<#
.SYNOPSIS
    Stops or removes the Hyper-V training lab.
.DESCRIPTION
    Default deletes the whole resource group (stops all charges).
    -StopOnly deallocates the hosts; managed disks keep billing.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    [switch]$StopOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null }

if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Host "Resource group $ResourceGroupName not found; nothing to do."
    return
}

if ($StopOnly) {
    $vms = Get-AzVM -ResourceGroupName $ResourceGroupName
    foreach ($vm in $vms) {
        Write-Host "Deallocating $($vm.Name)..."
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $vm.Name -Force | Out-Null
    }
    Write-Host 'Hosts deallocated. Managed disks still incur charges.' -ForegroundColor Yellow
    return
}

if (-not $Force) {
    $answer = Read-Host "Type '$ResourceGroupName' to permanently delete it and all lab VMs/disks"
    if ($answer -cne $ResourceGroupName) {
        Write-Host 'Confirmation did not match; aborting.'
        return
    }
}

Write-Host "Deleting $ResourceGroupName (this takes several minutes)..."
Remove-AzResourceGroup -Name $ResourceGroupName -Force | Out-Null
Write-Host 'Lab removed.' -ForegroundColor Green
