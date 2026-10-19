#Requires -Modules Az.Accounts, Az.Resources, Az.Compute
<#
.SYNOPSIS
    Deploys the on-demand Hyper-V training lab (nested-virtualization hosts) to Azure.
.EXAMPLE
    ./deploy.ps1 -WhatIf
.EXAMPLE
    ./deploy.ps1 -WithMSLab    # full rebuild: hosts + MSLab DC and nodes
.EXAMPLE
    ./deploy.ps1 -BastionSku Developer    # subscriptions that block public IPs (portal-only Bastion)
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-hyperv-training-eus2',
    [string]$Location = 'eastus2',
    [securestring]$AdminPassword,
    [string]$VmSize,
    [ValidateSet('Standard', 'Developer')]
    [string]$BastionSku = 'Standard',
    [switch]$WithMSLab,
    [ValidateRange(0, 6)]
    [int]$NodeCount = 3,
    [ValidateRange(2, 16)]
    [int]$NodeMemoryGB = 5,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$templateFile = Join-Path $repoRoot 'template\template.json'
$parameterFile = Join-Path $repoRoot 'template\parameters.json'
$setupScriptFile = Join-Path $PSScriptRoot 'setup-host.ps1'

function Assert-VmCapacity {
    param([string]$Location, [string]$VmSize, [int]$HostCount)

    $sku = Get-AzComputeResourceSku -Location $Location |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize } |
        Select-Object -First 1
    if (-not $sku) { throw "$VmSize is not offered in $Location." }
    $blocked = $sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' -and $_.Type -eq 'Location' }
    if ($blocked) { throw "$VmSize is restricted for this subscription in $Location." }

    $vcpus = [int]($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value
    $required = $vcpus * $HostCount
    $usage = Get-AzVMUsage -Location $Location
    foreach ($quotaName in @($sku.Family, 'cores')) {
        $quota = $usage | Where-Object { $_.Name.Value -eq $quotaName }
        if (-not $quota) { continue }
        $free = $quota.Limit - $quota.CurrentValue
        if ($free -lt $required) {
            throw "Quota '$quotaName' in ${Location}: need $required vCPU, only $free free. Request an increase first."
        }
        Write-Host "Quota '$quotaName': $free vCPU free, $required needed." -ForegroundColor Green
    }
}

foreach ($file in $templateFile, $parameterFile, $setupScriptFile) {
    if (-not (Test-Path $file)) { throw "Missing file: $file" }
}

$context = Get-AzContext
if (-not $context) { Connect-AzAccount | Out-Null }
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null }
Write-Host "Subscription: $((Get-AzContext).Subscription.Name)" -ForegroundColor Cyan

$fileParams = (Get-Content $parameterFile -Raw | ConvertFrom-Json).parameters
if (-not $VmSize) { $VmSize = $fileParams.vmSize.value }
Assert-VmCapacity -Location $Location -VmSize $VmSize -HostCount $fileParams.hostCount.value

if (-not $AdminPassword) {
    $AdminPassword = Read-Host -AsSecureString -Prompt "Admin password for $($fileParams.adminUsername.value) (min 12 chars)"
}

if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{ purpose = 'hyperv-training' } | Out-Null
    Write-Host "Created resource group $ResourceGroupName in $Location."
}

$deployment = @{
    Name                  = "hyperv-lab-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    ResourceGroupName     = $ResourceGroupName
    TemplateFile          = $templateFile
    TemplateParameterFile = $parameterFile
    location              = $Location
    adminPassword         = $AdminPassword
    hostSetupScript       = Get-Content $setupScriptFile -Raw
    bastionSku            = $BastionSku
    vmSize                = $VmSize
    deployMSLab           = [bool]$WithMSLab
    mslabNodeCount        = $NodeCount
    mslabNodeMemoryGB     = $NodeMemoryGB
    mslabSetupScript      = Get-Content (Join-Path $PSScriptRoot 'mslab-host.ps1') -Raw
}

if ($WhatIf) {
    New-AzResourceGroupDeployment @deployment -WhatIf
    return
}

Write-Host 'Deploying (Hyper-V install + reboot adds ~10-15 minutes)...' -ForegroundColor Cyan
$result = New-AzResourceGroupDeployment @deployment
if ($result.ProvisioningState -ne 'Succeeded') {
    throw "Deployment $($deployment.Name) finished with state $($result.ProvisioningState)."
}

Write-Host "`nHosts ready (allow ~5 min after deploy for the post-reboot task):" -ForegroundColor Green
$hosts = @($result.Outputs['hosts'].Value)
foreach ($labHost in $hosts) {
    Write-Host ("  {0}  private IP {1}" -f $labHost.name, $labHost.privateIp)
}
# Defender JIT can strip the Bastion RDP rule right after the NSG is created
& (Join-Path $PSScriptRoot 'fix-bastion-nsg.ps1') -ResourceGroupName $ResourceGroupName -NsgName "$($fileParams.namePrefix.value)-nsg"

if ($WithMSLab) {
    Write-Host "`nMSLab is building in the background on each host (~1.5 h). Check: ./deploy-mslab.ps1 -ResourceGroupName $ResourceGroupName -Status" -ForegroundColor Cyan
}

Write-Host "`nConnect: Azure portal > VM > Connect > Bastion."
if ($BastionSku -eq 'Standard') {
    Write-Host "Students without Azure accounts: ./bastion-links.ps1 -ResourceGroupName $ResourceGroupName  (browser RDP links; revoke with -Remove)" -ForegroundColor Cyan
}
Write-Host "`nVerify on each host: Get-Content C:\HyperVSetup\status.txt  (expect COMPLETE)"
Write-Host "Cost: ~`$0.87/hour for both hosts while running; 1 TB Premium disks bill even when stopped. Run teardown.ps1 when done." -ForegroundColor Yellow
