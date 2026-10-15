#Requires -Modules Az.Accounts, Az.Compute
<#
.SYNOPSIS
    Starts (or checks) MSLab hydration on the lab Hyper-V hosts through Azure Run Command.
.EXAMPLE
    ./deploy-mslab.ps1            # refresh host networking + start MSLab on all hosts
.EXAMPLE
    ./deploy-mslab.ps1 -Status    # show progress
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    [string[]]$VMName,
    [ValidateRange(0, 6)]
    [int]$NodeCount = 3,
    [ValidateRange(2, 16)]
    [int]$NodeMemoryGB = 5,
    [string]$IsoUrl,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null }
if (-not $VMName) { $VMName = @(Get-AzVM -ResourceGroupName $ResourceGroupName | Sort-Object Name | ForEach-Object Name) }
if (-not $VMName) { throw "No VMs found in $ResourceGroupName. Run deploy.ps1 first." }

function Invoke-OnHost([string]$Vm, [string]$ScriptPath, [hashtable]$Parameter = @{}) {
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $Vm `
        -CommandId RunPowerShellScript -ScriptPath $ScriptPath -Parameter $Parameter
    $result.Value | ForEach-Object { $_.Message } | Where-Object { $_ }
}

if ($Status) {
    $check = Join-Path $env:TEMP 'mslab-status.ps1'
    Set-Content -Path $check -Value @'
if (Test-Path C:\MSLabSetup\status.txt) { Get-Content C:\MSLabSetup\status.txt -Tail 5 } else { 'NOT STARTED' }
Get-VM | Format-Table Name, State, @{n='MemGB';e={[math]::Round($_.MemoryAssigned/1GB,1)}} -AutoSize | Out-String
'@
    foreach ($vm in $VMName) {
        Write-Host "== $vm ==" -ForegroundColor Cyan
        Invoke-OnHost -Vm $vm -ScriptPath $check
    }
    return
}

$mslabParams = @{ NodeCount = "$NodeCount"; NodeMemoryGB = "$NodeMemoryGB" }
if ($IsoUrl) { $mslabParams.IsoUrl = $IsoUrl }

foreach ($vm in $VMName) {
    Write-Host "== ${vm}: ensuring host NAT switch + DHCP ==" -ForegroundColor Cyan
    Invoke-OnHost -Vm $vm -ScriptPath (Join-Path $PSScriptRoot 'setup-host.ps1')
    Write-Host "== ${vm}: starting MSLab ==" -ForegroundColor Cyan
    Invoke-OnHost -Vm $vm -ScriptPath (Join-Path $PSScriptRoot 'mslab-host.ps1') -Parameter $mslabParams
}

Write-Host "`nHydration runs in the background (~1-2 h). Check with: ./deploy-mslab.ps1 -Status" -ForegroundColor Green
Write-Host 'Keep hosts running until COMPLETE; the 21:00 IST auto-shutdown will interrupt it.' -ForegroundColor Yellow
