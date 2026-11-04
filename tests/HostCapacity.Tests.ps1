Import-Module (Join-Path $PSScriptRoot '..\scripts\HostCapacity.psm1') -Force

Describe 'Subscription-aware VM size selection' {
    It 'does not restrict the ARM VM size to a fixed list' {
        $template = Get-Content (Join-Path $PSScriptRoot '..\template\template.json') -Raw | ConvertFrom-Json

        ($template.parameters.vmSize.PSObject.Properties.Name -contains 'allowedValues') | Should Be $false
    }

    It 'uses a dynamic compatibility filter rather than a fixed SKU shortlist' {
        $ui = Get-Content (Join-Path $PSScriptRoot '..\template\createUiDefinition.json') -Raw | ConvertFrom-Json
        $selector = $ui.parameters.steps[0].elements | Where-Object name -eq 'vmSize'

        $selector.type | Should Be 'Microsoft.Compute.SizeSelector'
        $selector.constraints.allowedSizes | Should Match 'steps'
        $selector.constraints.allowedSizes | Should Match 'compatibleSizes'
        $selector.constraints.zone | Should Be "[steps('hosts').zone]"
        $selector.count | Should Be "[int(steps('hosts').hostCount)]"
        $ui.parameters.outputs.vmSize | Should Be "[steps('hosts').vmSize]"
    }

    It 'allows a SKU outside the old shortlist through the preflight parameter binder' {
        $command = Get-Command (Join-Path $PSScriptRoot '..\scripts\check-host-capacity.ps1')
        $validateSets = @($command.Parameters['VmSize'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })

        $validateSets.Count | Should Be 0
        $command.Parameters.ContainsKey('ListSizes') | Should Be $true
    }
}

Describe 'Test-NestedVirtualizationSku' {
    $compatibleSku = [pscustomobject]@{
        Name = 'Standard_D16as_v5'
        Family = 'standardDASv5Family'
        Capabilities = @(
            [pscustomobject]@{ Name = 'CpuArchitectureType'; Value = 'x64' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = '64' }
            [pscustomobject]@{ Name = 'vCPUs'; Value = '16' }
        )
    }

    It 'accepts a documented nested-virtualization family' {
        Test-NestedVirtualizationSku -Sku $compatibleSku | Should Be $true
    }

    It 'rejects a burstable family even when it supports Gen2' {
        $sku = $compatibleSku | Select-Object *
        $sku.Family = 'standardBSFamily'
        Test-NestedVirtualizationSku -Sku $sku | Should Be $false
    }

    It 'rejects ARM64 instead of assuming Gen2 means nested support' {
        $sku = $compatibleSku | Select-Object *
        $sku.Capabilities = @($compatibleSku.Capabilities | Where-Object Name -ne 'CpuArchitectureType') + @([pscustomobject]@{ Name = 'CpuArchitectureType'; Value = 'Arm64' })
        Test-NestedVirtualizationSku -Sku $sku | Should Be $false
    }

    It 'rejects unknown capability data' {
        $sku = $compatibleSku | Select-Object *
        $sku.Capabilities = @()
        Test-NestedVirtualizationSku -Sku $sku | Should Be $false
    }

    It 'rejects a compatible family with less than 32 GB of memory' {
        $sku = $compatibleSku | Select-Object *
        $sku.Capabilities = @($compatibleSku.Capabilities | Where-Object Name -ne 'MemoryGB') + @([pscustomobject]@{ Name = 'MemoryGB'; Value = '16' })
        Test-NestedVirtualizationSku -Sku $sku | Should Be $false
    }

    It 'rejects a constrained size with fewer than four available vCPUs' {
        $sku = $compatibleSku | Select-Object *
        $sku.Capabilities = @($compatibleSku.Capabilities) + @([pscustomobject]@{ Name = 'vCPUsAvailable'; Value = '2' })
        Test-NestedVirtualizationSku -Sku $sku | Should Be $false
    }
}

Describe 'Get-HostCapacitySummary' {
    $baseSku = [pscustomobject]@{
        Name         = 'Standard_E8as_v5'
        Family       = 'standardEASv5Family'
        Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '8' })
        LocationInfo = @([pscustomobject]@{ Location = 'eastus2'; Zones = @('1', '2', '3') })
        Restrictions = @()
    }
    $usage = @(
        [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores' }; CurrentValue = 32; Limit = 100 }
        [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardEASv5Family' }; CurrentValue = 24; Limit = 64 }
    )

    It 'calculates additional hosts from the tighter family or core quota' {
        $summary = Get-HostCapacitySummary -Sku $baseSku -Usage $usage -Location 'eastus2' -Zone '2' -HostCount 4

        $summary.MaxAdditionalHosts | Should Be 5
        $summary.CanDeploy | Should Be $true
    }

    It 'rejects a SKU restricted for the requested zone' {
        $sku = $baseSku | Select-Object *
        $sku.Restrictions = @([pscustomobject]@{
            ReasonCode      = 'NotAvailableForSubscription'
            Type            = 'Zone'
            RestrictionInfo = [pscustomobject]@{ Locations = @('eastus2'); Zones = @('1', '3') }
        })

        $summary = Get-HostCapacitySummary -Sku $sku -Usage $usage -Location 'eastus2' -Zone '1' -HostCount 1

        $summary.CanDeploy | Should Be $false
        $summary.IsSubscriptionRestricted | Should Be $true
    }

    It 'allows a requested zone when a SKU restriction only names other zones' {
        $sku = $baseSku | Select-Object *
        $sku.Restrictions = @([pscustomobject]@{
            ReasonCode      = 'NotAvailableForSubscription'
            Type            = 'Zone'
            RestrictionInfo = [pscustomobject]@{ Locations = @('eastus2'); Zones = @('1', '3') }
        })

        $summary = Get-HostCapacitySummary -Sku $sku -Usage $usage -Location 'eastus2' -Zone '2' -HostCount 6

        $summary.ZoneSupported | Should Be $true
        $summary.IsSubscriptionRestricted | Should Be $false
        $summary.MaxAdditionalHosts | Should Be 5
        $summary.CanDeploy | Should Be $false
    }

    It 'reports the count that quota supports when requested hosts exceed it' {
        $limitedUsage = @(
            [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores' }; CurrentValue = 96; Limit = 100 }
            [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardEASv5Family' }; CurrentValue = 60; Limit = 64 }
        )

        $summary = Get-HostCapacitySummary -Sku $baseSku -Usage $limitedUsage -Location 'eastus2' -Zone '2' -HostCount 1

        $summary.MaxAdditionalHosts | Should Be 0
        $summary.CanDeploy | Should Be $false
    }

    It 'reads Azure CLI quota envelopes and camel-case zone restrictions' {
        $cliSku = [pscustomobject]@{
            name         = 'Standard_E8as_v5'
            family       = 'standardEASv5Family'
            capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '8' })
            locationInfo = @([pscustomobject]@{ location = 'eastus2'; zones = @('1', '2', '3') })
            restrictions = @([pscustomobject]@{
                reasonCode      = 'NotAvailableForSubscription'
                type            = 'Zone'
                restrictionInfo = [pscustomobject]@{ locations = @('eastus2'); zones = @('1', '2', '3') }
            })
        }
        $cliUsage = [pscustomobject]@{
            value = @(
                [pscustomobject]@{ name = [pscustomobject]@{ value = 'cores' }; currentValue = '48'; limit = '100' }
                [pscustomobject]@{ name = [pscustomobject]@{ value = 'standardEASv5Family' }; currentValue = '24'; limit = '100' }
            )
        }

        $summary = Get-HostCapacitySummary -Sku $cliSku -Usage $cliUsage -Location 'eastus2' -Zone '2' -HostCount 1

        $summary.IsSubscriptionRestricted | Should Be $true
        $summary.MaxAdditionalHosts | Should Be 6
        $summary.CanDeploy | Should Be $false
    }

    It 'does not declare capacity when the selected family quota is missing' {
        $regionalQuotaOnly = @($usage | Where-Object { $_.Name.Value -eq 'cores' })

        { Get-HostCapacitySummary -Sku $baseSku -Usage $regionalQuotaOnly -Location eastus2 -Zone 2 -HostCount 1 } | Should Throw
    }
}