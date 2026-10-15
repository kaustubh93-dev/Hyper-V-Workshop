#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Hydrates and deploys an MSLab environment (DC, Server 2025 parent disks, nodes) on a lab Hyper-V host.
.DESCRIPTION
    Without -Run (e.g. via Azure Run Command) it stages itself to C:\MSLabSetup and starts a SYSTEM
    scheduled task, then returns. The task downloads MSLab and the Server 2025 evaluation ISO, writes
    LabConfig.ps1 and runs 1_Prereq, 2_CreateParentDisks and Deploy unattended.
    Progress: C:\MSLabSetup\status.txt and C:\MSLabSetup\mslab-host.log.
    Requires setup-host.ps1 to have created the 'InternalNAT' switch (192.168.0.0/24), which MSLab reuses on Azure.
#>
[CmdletBinding()]
param(
    [string]$IsoUrl = 'https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso',
    [ValidateRange(0, 6)]
    [int]$NodeCount = 3,
    [ValidateRange(2, 16)]
    [int]$NodeMemoryGB = 5,
    [ValidateLength(8, 64)]
    [string]$AdminPassword = 'LS1setup!',
    [switch]$Run
)

$ErrorActionPreference = 'Stop'
$stage = 'C:\MSLabSetup'
$labRoot = 'V:\MSLab'
$isoDir = 'V:\ISO\Server2025'
$taskName = 'MSLabSetup'
$statusFile = Join-Path $stage 'status.txt'

function Set-Status([string]$Message) {
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $statusFile -Value $line
    Write-Output $line
}

function Get-RemoteFile([string]$Uri, [string]$Destination) {
    & curl.exe --fail --location --retry 3 --silent --show-error --output "$Destination.partial" $Uri
    if ($LASTEXITCODE -ne 0) { throw "Download failed ($LASTEXITCODE): $Uri" }
    Move-Item -Path "$Destination.partial" -Destination $Destination -Force
}

function Invoke-MSLabStep([string]$Script) {
    Set-Status "RUNNING $Script"
    $proc = Start-Process -FilePath powershell.exe -WorkingDirectory $labRoot -Wait -PassThru -NoNewWindow `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$labRoot\$Script`""
    Set-Status "FINISHED $Script exit=$($proc.ExitCode)"
}

# Storage VLANs have no DHCP, so nodes would otherwise sit on APIPA addresses
function Set-NodeStorageIp {
    $cred = New-Object PSCredential('CORP\LabAdmin', (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    $subnets = [ordered]@{ Storage1 = '10.10.1'; Storage2 = '10.10.2' }
    foreach ($vm in Get-VM -Name 'MSLab-Node*' | Sort-Object Name) {
        $nodeNumber = [int]($vm.Name -replace '\D')
        $deadline = (Get-Date).AddMinutes(20)
        while ($true) {
            try { Invoke-Command -VMName $vm.Name -Credential $cred -ScriptBlock { $true } -ErrorAction Stop | Out-Null; break }
            catch {
                if ((Get-Date) -gt $deadline) { throw "$($vm.Name) not reachable via PowerShell Direct: $_" }
                Start-Sleep -Seconds 30
            }
        }
        foreach ($net in $subnets.Keys) {
            $mac = (Get-VMNetworkAdapter -VM $vm -Name $net).MacAddress -replace '(..)(?!$)', '$1-'
            Invoke-Command -VMName $vm.Name -Credential $cred -ArgumentList $mac, $net, "$($subnets[$net]).$nodeNumber" -ScriptBlock {
                param($Mac, $Name, $Ip)
                $nic = Get-NetAdapter | Where-Object MacAddress -eq $Mac
                if ($nic.Name -ne $Name) { Rename-NetAdapter -Name $nic.Name -NewName $Name }
                if (-not (Get-NetIPAddress -InterfaceAlias $Name -IPAddress $Ip -ErrorAction SilentlyContinue)) {
                    New-NetIPAddress -InterfaceAlias $Name -IPAddress $Ip -PrefixLength 24 | Out-Null
                }
            }
        }
        Set-Status "STORAGE IPs set on $($vm.Name): 10.10.1.$nodeNumber, 10.10.2.$nodeNumber"
    }
}

function New-LabConfigContent {
    $pw = $AdminPassword.Replace("'", "''")
    @"
`$LabConfig = @{
    DomainAdminName          = 'LabAdmin'
    AdminPassword            = '$pw'
    Prefix                   = 'MSLab-'
    SwitchName               = 'LabSwitch'
    DCEdition                = '4'
    Internet                 = `$true
    UseHostDnsAsForwarder    = `$true
    ServerISOFolder          = '$isoDir'
    TelemetryLevel           = 'None'
    AutoClosePSWindows       = `$true
    AutoCleanUp              = `$true
    AutoStartAfterDeploy     = `$true
    AdditionalNetworksConfig = @()
    VMs                      = @()
}

`$LabConfig.AdditionalNetworksConfig += @{ NetName = 'Storage1'; NetAddress = '10.10.1.'; NetVLAN = '1'; Subnet = '255.255.255.0' }
`$LabConfig.AdditionalNetworksConfig += @{ NetName = 'Storage2'; NetAddress = '10.10.2.'; NetVLAN = '2'; Subnet = '255.255.255.0' }

for (`$i = 1; `$i -le $NodeCount; `$i++) {
    `$LabConfig.VMs += @{
        VMName             = "Node`$i"
        Configuration      = 'S2D'
        ParentVHD          = 'Win2025Core_G2.vhdx'
        HDDNumber          = 4
        HDDSize            = 100GB
        MemoryStartupBytes = ${NodeMemoryGB}GB
        VMProcessorCount   = 2
        AdditionalNetworks = `$true
    }
}
"@
}

if (-not $Run) {
    if (-not $PSCommandPath) { throw 'Run this script from a file so it can stage itself.' }
    if (-not (Get-VMSwitch -Name 'InternalNAT' -ErrorAction SilentlyContinue)) {
        throw "Switch 'InternalNAT' not found. Re-run setup-host.ps1 first."
    }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination "$stage\mslab-host.ps1" -Force
    @{ IsoUrl = $IsoUrl; NodeCount = $NodeCount; NodeMemoryGB = $NodeMemoryGB; AdminPassword = $AdminPassword } |
        ConvertTo-Json | Set-Content -Path "$stage\params.json" -Encoding UTF8

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$stage\mslab-host.ps1`" -Run"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Set-Status 'QUEUED MSLab setup task started'
    return
}

$params = Get-Content "$stage\params.json" -Raw | ConvertFrom-Json
$IsoUrl = $params.IsoUrl
$NodeCount = [int]$params.NodeCount
$NodeMemoryGB = [int]$params.NodeMemoryGB
$AdminPassword = $params.AdminPassword

Start-Transcript -Path (Join-Path $stage 'mslab-host.log') -Append | Out-Null
try {
    # AutoCleanUp in 2_CreateParentDisks renames 3_Deploy.ps1 to Deploy.ps1
    if (-not (Test-Path "$labRoot\3_Deploy.ps1") -and -not (Test-Path "$labRoot\Deploy.ps1")) {
        Set-Status 'DOWNLOADING MSLab'
        New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
        $zip = Join-Path $stage 'mslab.zip'
        Get-RemoteFile -Uri 'https://github.com/microsoft/MSLab/releases/download/v26.07.1/mslab_v26.07.1.zip' -Destination $zip
        Expand-Archive -Path $zip -DestinationPath $labRoot -Force
        Get-ChildItem -Path $labRoot -Recurse -File | Unblock-File
    }

    New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
    if (-not (Get-ChildItem -Path $isoDir -Filter *.iso)) {
        Set-Status 'DOWNLOADING Windows Server 2025 evaluation ISO'
        Get-RemoteFile -Uri $IsoUrl -Destination (Join-Path $isoDir 'WindowsServer2025-Eval.iso')
    }

    Set-Content -Path "$labRoot\LabConfig.ps1" -Value (New-LabConfigContent) -Encoding UTF8

    # MSLab's Get-PackageProvider/Install-Module would prompt for NuGet and an untrusted repo, hanging this non-interactive task
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    if (-not (Test-Path "$labRoot\ParentDisks\Win2025Core_G2.vhdx")) {
        Invoke-MSLabStep '1_Prereq.ps1'
        Invoke-MSLabStep '2_CreateParentDisks.ps1'
    }
    if (-not (Test-Path "$labRoot\ParentDisks\Win2025Core_G2.vhdx")) {
        throw "Parent disk not created. Check transcripts in $labRoot."
    }

    $deployScript = if (Test-Path "$labRoot\3_Deploy.ps1") { '3_Deploy.ps1' } else { 'Deploy.ps1' }
    Invoke-MSLabStep $deployScript
    if (-not (Get-VM -Name 'MSLab-DC' -ErrorAction SilentlyContinue)) {
        throw "MSLab-DC VM not found after Deploy. Check transcripts in $labRoot."
    }
    Set-NodeStorageIp

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Set-Status "COMPLETE VMs: $((Get-VM -Name 'MSLab-*').Name -join ', ')"
}
catch {
    Set-Status "FAILED $_"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
