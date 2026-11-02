Import-Module (Join-Path $PSScriptRoot '..\scripts\HostCapacity.psm1') -Force

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
}