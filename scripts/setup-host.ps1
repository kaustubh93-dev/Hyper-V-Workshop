#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepares an Azure VM as a Hyper-V host for nested Windows Server 2025 guests.
.DESCRIPTION
    Runs via Azure managed Run Command as SYSTEM. Formats the data disk as V:, installs Hyper-V,
    then (after one reboot) creates a NAT switch for guests and optionally downloads the
    Server 2025 evaluation ISO. Safe to re-run. Logs to C:\HyperVSetup.
#>
[CmdletBinding()]
param(
    [string]$NatPrefix = '192.168.100.0/24',
    [string]$IsoUrl = ''
)

$ErrorActionPreference = 'Stop'
$root = 'C:\HyperVSetup'
$taskName = 'HyperVPostReboot'

$postRebootScript = @'
$ErrorActionPreference = 'Stop'
$root = 'C:\HyperVSetup'
$switchName = 'NestedNAT'
Start-Transcript -Path (Join-Path $root 'post-reboot.log') -Append | Out-Null
try {
    $cfg = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json

    # Hyper-V WMI provider lags behind vmms right after the first boot
    $deadline = (Get-Date).AddMinutes(15)
    while ($true) {
        try { Get-VMHost -ErrorAction Stop | Out-Null; break }
        catch {
            if ((Get-Date) -gt $deadline) { throw "Hyper-V management not ready: $_" }
            Start-Sleep -Seconds 15
        }
    }

    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    }

    $network, $prefixLength = $cfg.NatPrefix.Split('/')
    $octets = $network.Split('.')
    $gateway = '{0}.{1}.{2}.{3}' -f $octets[0], $octets[1], $octets[2], ([int]$octets[3] + 1)
    if (-not (Get-NetIPAddress -IPAddress $gateway -ErrorAction SilentlyContinue)) {
        $ifIndex = (Get-NetAdapter -Name "vEthernet ($switchName)").ifIndex
        New-NetIPAddress -IPAddress $gateway -PrefixLength ([byte]$prefixLength) -InterfaceIndex $ifIndex | Out-Null
    }
    if (-not (Get-NetNat -Name $switchName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $switchName -InternalIPInterfaceAddressPrefix $cfg.NatPrefix | Out-Null
    }

    Set-VMHost -VirtualHardDiskPath 'V:\VMs' -VirtualMachinePath 'V:\VMs'

    if ($cfg.IsoUrl) {
        $iso = 'V:\ISO\WindowsServer2025-Eval.iso'
        if (-not (Test-Path $iso)) {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $cfg.IsoUrl -OutFile "$iso.partial" -UseBasicParsing
            Move-Item -Path "$iso.partial" -Destination $iso -Force
        }
    }

    Unregister-ScheduledTask -TaskName 'HyperVPostReboot' -Confirm:$false -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $root 'status.txt') -Value "COMPLETE $(Get-Date -Format o) gateway=$gateway"
}
catch {
    Set-Content -Path (Join-Path $root 'status.txt') -Value "FAILED $(Get-Date -Format o): $_"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
'@

New-Item -ItemType Directory -Path $root -Force | Out-Null
Start-Transcript -Path (Join-Path $root 'setup.log') -Append | Out-Null
try {
    if ($NatPrefix -notmatch '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-9])$') {
        throw "Invalid NatPrefix '$NatPrefix'. Expected an IPv4 CIDR between /16 and /29."
    }
    if ($IsoUrl -and -not $IsoUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'IsoUrl must be an https:// URL.'
    }

    if (-not (Get-Volume -DriveLetter V -ErrorAction SilentlyContinue)) {
        $rawDisk = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Number | Select-Object -First 1
        if (-not $rawDisk) { throw 'No RAW data disk found to initialize as V:.' }
        $rawDisk |
            Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter V -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'HyperV' -AllocationUnitSize 65536 -Confirm:$false |
            Out-Null
    }
    'V:\VMs', 'V:\ISO' | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }

    @{ NatPrefix = $NatPrefix; IsoUrl = $IsoUrl } | ConvertTo-Json | Set-Content -Path (Join-Path $root 'config.json') -Encoding UTF8
    $postScriptPath = Join-Path $root 'post-reboot.ps1'
    Set-Content -Path $postScriptPath -Value $postRebootScript -Encoding UTF8

    $feature = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    if ($feature.RestartNeeded -eq 'Yes') {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$postScriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Set-Content -Path (Join-Path $root 'status.txt') -Value "REBOOTING $(Get-Date -Format o)"
        # Delay lets Run Command report success before the host restarts
        & shutdown.exe /r /t 60 /d p:2:4 /c 'Hyper-V installed; restarting to finish setup.'
        Write-Output 'Hyper-V installed. Host restarts in 60 seconds; post-reboot setup runs as a scheduled task.'
    }
    else {
        & $postScriptPath
        Write-Output 'Hyper-V already installed. Post-reboot setup completed inline.'
    }
}
finally {
    Stop-Transcript | Out-Null
}
