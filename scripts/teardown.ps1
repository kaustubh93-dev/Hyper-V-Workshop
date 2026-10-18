#Requires -Modules Az.Accounts, Az.Resources, Az.Compute
<#
.SYNOPSIS
    Stops or removes the Hyper-V training lab.
.DESCRIPTION
    Default deletes the whole resource group and everything in it (hosts, disks, Bastion, public IP,
    VNet, NSG, shutdown schedules) and verifies nothing is left, which stops all charges.
    -StopOnly deallocates the hosts; managed disks keep billing.
.EXAMPLE
    ./teardown.ps1            # delete everything (asks you to type the resource group name)
.EXAMPLE
    ./teardown.ps1 -StopOnly  # deallocate hosts only; bring back with start-lab.ps1
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

$resources = @(Get-AzResource -ResourceGroupName $ResourceGroupName | Sort-Object ResourceType, Name)
Write-Host "`n$($resources.Count) resource(s) in ${ResourceGroupName}:" -ForegroundColor Cyan
$resources | Format-Table Name, ResourceType -AutoSize | Out-String -Width 200 | Write-Host

$locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName)
if ($locks) {
    throw "Resource locks block deletion: $($locks.Name -join ', '). Remove them with Remove-AzResourceLock, then re-run."
}

if (-not $Force) {
    $answer = Read-Host "Type '$ResourceGroupName' to permanently delete it and ALL resources listed above"
    if ($answer -cne $ResourceGroupName) {
        Write-Host 'Confirmation did not match; aborting.'
        return
    }
}

Write-Host "Deleting $ResourceGroupName (usually 5-15 minutes)..."
$started = Get-Date
Remove-AzResourceGroup -Name $ResourceGroupName -Force | Out-Null

if (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) {
    throw "$ResourceGroupName still exists. Check the Azure portal for resources that failed to delete."
}
Write-Host ("Deleted {0} and all {1} resource(s) in {2:N0} min. Nothing is left billing." -f $ResourceGroupName, $resources.Count, ((Get-Date) - $started).TotalMinutes) -ForegroundColor Green
