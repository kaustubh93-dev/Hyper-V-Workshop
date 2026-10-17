#Requires -Modules Az.Accounts, Az.Compute
<#
.SYNOPSIS
    Starts the lab hosts, falling back to other nested-virtualization sizes when Azure lacks capacity, then starts the MSLab VMs.
.EXAMPLE
    ./start-lab.ps1
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    # Preferred first; all are no-temp-disk sizes because Azure can't resize between temp-disk and diskless sizes
    [string[]]$Sizes = @('Standard_E4s_v5', 'Standard_E4s_v4', 'Standard_D8s_v5', 'Standard_D8s_v4', 'Standard_E8s_v5')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null }

$guestScript = @'
foreach ($vm in Get-VM -Name 'MSLab-*' | Sort-Object { $_.Name -ne 'MSLab-DC' }, Name) {
    if ($vm.State -eq 'Running') { continue }
    try { Start-VM -VM $vm -ErrorAction Stop }
    catch {
        # Saved state from a different host CPU can't be restored; cold-boot instead
        Remove-VMSavedState -VM $vm
        Start-VM -VM $vm
    }
}
Get-VM -Name 'MSLab-*' | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.State)" }
'@

function Start-HostWithFallback([string]$Name) {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status
    if (($vm.Statuses | Where-Object Code -like 'PowerState/*').Code -eq 'PowerState/running') {
        Write-Host "${Name}: already running" -ForegroundColor Green
        return
    }
    foreach ($size in $Sizes) {
        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
            if ($vm.HardwareProfile.VmSize -ne $size) {
                $vm.HardwareProfile.VmSize = $size
                Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm | Out-Null
            }
            Start-AzVM -ResourceGroupName $ResourceGroupName -Name $Name | Out-Null
            Write-Host "${Name}: running on $size" -ForegroundColor Green
            return
        }
        catch { Write-Warning "${Name}: $size unavailable - $(($_.Exception.Message -split "`n")[0])" }
    }
    throw "${Name}: none of $($Sizes -join ', ') had capacity. Retry later."
}

$hostNames = @(Get-AzVM -ResourceGroupName $ResourceGroupName | Sort-Object Name | ForEach-Object Name)
foreach ($name in $hostNames) { Start-HostWithFallback $name }

foreach ($name in $hostNames) {
    Write-Host "== ${name}: starting MSLab VMs ==" -ForegroundColor Cyan
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $name `
        -CommandId RunPowerShellScript -ScriptString $guestScript
    $result.Value | ForEach-Object { $_.Message } | Where-Object { $_ }
}

& (Join-Path $PSScriptRoot 'fix-bastion-nsg.ps1') -ResourceGroupName $ResourceGroupName
