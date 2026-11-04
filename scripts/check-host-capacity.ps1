[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location = 'eastus2',
    [ValidateSet('1', '2', '3', '4')]
    [string]$Zone = '2',
    [ValidatePattern('^Standard_[A-Za-z0-9_-]+$')]
    [string]$VmSize = 'Standard_D8as_v5',
    [switch]$ListSizes,
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

$skuQuery = if ($ListSizes) { '[*]' } else { "[?name=='$VmSize'] | [0]" }
$skuJson = az vm list-skus --location $Location --resource-type virtualMachines --all --query $skuQuery --output json
if ($LASTEXITCODE -ne 0) { throw "Could not query VM SKU availability for $Location." }
$sku = $skuJson | ConvertFrom-Json
if (-not $sku) { throw "$VmSize is not offered in $Location." }
if ($ListSizes -and $sku.PSObject.Properties['value']) { $sku = @($sku.value) }
if (-not $ListSizes -and -not (Test-NestedVirtualizationSku -Sku $sku)) {
    throw "$VmSize is not verified for this nested-Hyper-V lab. Select a documented Dsv5, Dasv5, Esv5 or Easv5 size with x64/Gen2 support, at least 4 vCPUs and 32 GB RAM."
}

$usageJson = az vm list-usage --location $Location --output json
if ($LASTEXITCODE -ne 0) { throw "Could not query vCPU quota for $Location." }
$usageResponse = $usageJson | ConvertFrom-Json
if ($usageResponse.PSObject.Properties['value']) {
    $usage = @($usageResponse.value)
}
else {
    $usage = @($usageResponse)
}

if ($ListSizes) {
    Write-Host 'Nested-Hyper-V sizes from documented compatible families, with at least 4 vCPUs and 32 GB RAM. Live capacity is not reserved.' -ForegroundColor Cyan
    $rows = foreach ($candidate in $sku) {
        if (-not (Test-NestedVirtualizationSku -Sku $candidate)) { continue }
        try {
            $summary = Get-HostCapacitySummary -Sku $candidate -Usage $usage -Location $Location -Zone $Zone -HostCount $HostCount -ErrorAction Stop
            $memory = $candidate.capabilities | Where-Object name -eq 'MemoryGB' | Select-Object -First 1 -ExpandProperty value
            [pscustomobject]@{
                VmSize             = $summary.VmSize
                Vcpus              = $summary.VcpusPerHost
                MemoryGB           = $memory
                ZoneSupported      = $summary.ZoneSupported
                Restricted         = $summary.IsSubscriptionRestricted
                MaxAdditionalHosts = $summary.MaxAdditionalHosts
                CanDeploy          = $summary.CanDeploy
                UnverifiedReason   = ''
            }
        }
        catch {
            [pscustomobject]@{
                VmSize             = $candidate.name
                Vcpus              = $null
                MemoryGB           = $null
                ZoneSupported      = $null
                Restricted         = $null
                MaxAdditionalHosts = $null
                CanDeploy          = $false
                UnverifiedReason   = $_.Exception.Message
            }
        }
    }
    $rows | Sort-Object -Property @{ Expression = 'CanDeploy'; Descending = $true }, VmSize | Format-Table -AutoSize
    Write-Warning 'Only verified Dsv5, Dasv5, Esv5 and Easv5 families are listed; unknown families are excluded. Rerun with -VmSize to also check Bastion prerequisites. Quota eligibility does not guarantee allocation.'
    return
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