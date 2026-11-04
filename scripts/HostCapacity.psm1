function Test-NestedVirtualizationSku {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Sku)

    $families = @('standardDSv5Family', 'standardDASv5Family', 'standardESv5Family', 'standardEASv5Family')
    if ($Sku.Family -notin $families) { return $false }
    $capabilities = @{}
    foreach ($capability in $Sku.Capabilities) {
        $capabilities[$capability.Name] = $capability.Value
    }
    if ($capabilities['CpuArchitectureType'] -ne 'x64' -or
        'V2' -notin ([string]$capabilities['HyperVGenerations'] -split ',')) { return $false }
    $memory = 0.0
    $vcpus = 0
    if (-not [double]::TryParse([string]$capabilities['MemoryGB'], [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$memory)) { return $false }
    $vcpuValue = if ($capabilities.ContainsKey('vCPUsAvailable')) { $capabilities['vCPUsAvailable'] } else { $capabilities['vCPUs'] }
    if (-not [int]::TryParse([string]$vcpuValue, [ref]$vcpus)) { return $false }
    return $memory -ge 32 -and $vcpus -ge 4
}

function Get-HostCapacitySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Sku,
        [Parameter(Mandatory)]
        [object[]]$Usage,
        [Parameter(Mandatory)]
        [string]$Location,
        [Parameter(Mandatory)]
        [string]$Zone,
        [Parameter(Mandatory)]
        [ValidateRange(1, 6)]
        [int]$HostCount
    )

    $vcpuCapability = $Sku.Capabilities | Where-Object Name -ieq 'vCPUs' | Select-Object -First 1
    if (-not $vcpuCapability -or -not [int]::TryParse([string]$vcpuCapability.Value, [ref]$null)) {
        throw "Could not determine vCPU count for SKU '$($Sku.Name)'."
    }
    $vcpus = [int]$vcpuCapability.Value

    $locationInfo = @($Sku.LocationInfo | Where-Object Location -ieq $Location)
    $supportedZones = @($locationInfo | ForEach-Object Zones | ForEach-Object { [string]$_ })
    $zoneSupported = $supportedZones -contains $Zone

    $blocked = @($Sku.Restrictions | Where-Object {
        if ($_.ReasonCode -ne 'NotAvailableForSubscription') { return $false }
        $restrictedLocations = @($_.RestrictionInfo.Locations)
        $restrictedZones = @($_.RestrictionInfo.Zones | ForEach-Object { [string]$_ })
        $locationBlocked = $_.Type -eq 'Location' -and ($restrictedLocations -contains $Location)
        $zoneBlocked = $_.Type -eq 'Zone' -and ($restrictedLocations -contains $Location) -and ($restrictedZones -contains $Zone)
        $locationBlocked -or $zoneBlocked
    })

    $usageRows = @($Usage)
    if ($usageRows.Count -eq 1 -and $usageRows[0].PSObject.Properties['value']) {
        $usageRows = @($usageRows[0].value)
    }
    foreach ($quotaName in @($Sku.Family, 'cores')) {
        if (-not ($usageRows | Where-Object { $_.Name.Value -eq $quotaName })) {
            throw "Quota '$quotaName' was not returned for $Location. Capacity cannot be verified."
        }
    }
    $quotaRows = @($usageRows | Where-Object {
        $_.Name.Value -eq $Sku.Family -or $_.Name.Value -eq 'cores'
    })
    if (-not $quotaRows) {
        throw "Neither the '$($Sku.Family)' nor 'cores' quota was returned for $Location."
    }

    $quotaFreeValues = @($quotaRows | ForEach-Object {
        $limit = [int]$_.Limit
        $current = [int]$_.CurrentValue
        [Math]::Max(0, ($limit - $current))
    })
    $quotaFreeVcpus = [int](($quotaFreeValues | Measure-Object -Minimum).Minimum)
    $maxAdditionalHosts = [int][Math]::Floor($quotaFreeVcpus / $vcpus)
    $isRestricted = $blocked.Count -gt 0
    $canDeploy = $zoneSupported -and -not $isRestricted -and $maxAdditionalHosts -ge $HostCount

    [pscustomobject]@{
        Location                 = $Location
        Zone                     = $Zone
        VmSize                   = [string]$Sku.Name
        VcpusPerHost             = $vcpus
        ZoneSupported            = $zoneSupported
        IsSubscriptionRestricted = $isRestricted
        Family                   = [string]$Sku.Family
        QuotaFreeVcpus           = [int]$quotaFreeVcpus
        MaxAdditionalHosts       = $maxAdditionalHosts
        RequestedHosts           = $HostCount
        CanDeploy                = $canDeploy
    }
}

Export-ModuleMember -Function Get-HostCapacitySummary, Test-NestedVirtualizationSku