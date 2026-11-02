[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location = 'eastus2',
    [ValidateSet('1', '2', '3', '4')]
    [string]$Zone = '2',
    [ValidateSet(
        'Standard_D8s_v5', 'Standard_D8s_v4', 'Standard_D16s_v5',
        'Standard_E8s_v5', 'Standard_E8s_v4', 'Standard_E4s_v5', 'Standard_E4s_v4',
        'Standard_D8as_v5', 'Standard_E8as_v5', 'Standard_E4as_v5', 'Standard_D16as_v5'
    )]
    [string]$VmSize = 'Standard_D8as_v5',
    [ValidateRange(1, 6)]
    [int]$HostCount = 2,
    [ValidateSet('Developer', 'Standard')]
    [string]$BastionSku = 'Developer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HostCapacity.psm1') -Force

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it from https://aka.ms/installazurecliwindows.'
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the requested Azure subscription.' }
}
az account show --only-show-errors --output none
if ($LASTEXITCODE -ne 0) { throw 'Run az login before checking host capacity.' }

$skuQuery = "[?name=='$VmSize'] | [0]"
$skuJson = az vm list-skus --location $Location --resource-type virtualMachines --query $skuQuery --output json
if ($LASTEXITCODE -ne 0) { throw "Could not query VM SKU availability for $Location." }
$sku = $skuJson | ConvertFrom-Json
if (-not $sku) { throw "$VmSize is not offered in $Location." }

$usageQuery = "[?name.value=='$($sku.family)' || name.value=='cores']"
$usageJson = az vm list-usage --location $Location --query $usageQuery --output json
if ($LASTEXITCODE -ne 0) { throw "Could not query vCPU quota for $Location." }
$usageResponse = $usageJson | ConvertFrom-Json
if ($usageResponse.PSObject.Properties['value']) {
    $usage = @($usageResponse.value)
}
else {
    $usage = @($usageResponse)
}
$summary = Get-HostCapacitySummary -Sku $sku -Usage $usage -Location $Location -Zone $Zone -HostCount $HostCount

Write-Host 'VM capacity preflight (quota and SKU restrictions only; live allocation is not reserved):' -ForegroundColor Cyan
$summary | Format-List Location, Zone, VmSize, VcpusPerHost, ZoneSupported, IsSubscriptionRestricted, QuotaFreeVcpus, MaxAdditionalHosts, RequestedHosts, CanDeploy

$bastionReady = $true
if ($BastionSku -eq 'Standard') {
    $featureState = az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state --output tsv 2>$null
    $featureRegistered = $LASTEXITCODE -eq 0 -and $featureState -eq 'Registered'
    $providerState = az provider show --namespace Microsoft.Network --query registrationState --output tsv 2>$null
    $providerRegistered = $LASTEXITCODE -eq 0 -and $providerState -eq 'Registered'
    $bastionReady = $featureRegistered -and $providerRegistered
    Write-Host "Standard Bastion public-IP prerequisite: $(if ($bastionReady) { 'Registered' } else { 'MISSING' })"
    if (-not $bastionReady) {
        Write-Warning 'Use -BastionSku Developer, or register Microsoft.Network/AllowBringYourOwnPublicIpAddress and re-register Microsoft.Network before deploying Standard Bastion.'
    }
}
else {
    Write-Host 'Bastion Developer selected; no Bastion public-IP feature is required.'
}

if (-not $summary.CanDeploy -or -not $bastionReady) {
    throw 'Preflight failed. Adjust host count, SKU, zone, or Bastion prerequisites before deploying.'
}

Write-Host "Preflight passed for $HostCount host(s). Azure capacity can still change before deployment." -ForegroundColor Green