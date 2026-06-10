
<#
================================================================================
Cloud Rewind Azure Resource Quoting Script
================================================================================
Purpose
-------
Inventory Azure resources across all subscriptions in a tenant and classify them
into billable vs non-billable and data vs configuration.

This version only excludes the specific unused resource types requested:
    - Unattached disks
    - Unattached Public IP addresses
    - Unattached Network Interfaces
    - Unattached NSGs
    - Unattached Application Gateways
    - Unattached Load Balancers
    - Unused VNETs

Classification
--------------
Data Resources
    - Virtual Machines
    - Managed Data Disks

Configuration Resources
    - Everything else

Notes
-----
- SQL master database is excluded
- VMSS is counted only when orchestration mode is Uniform
- VMSS child VM resources are treated as non-billable
- Tenant-wide and per-subscription totals are summarized at the end
================================================================================
#>

Connect-AzAccount

$subscriptions = Get-AzSubscription

$billableResources = @(
    "Microsoft.Web/sites",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Network/azureFirewalls",
    "Microsoft.KeyVault/vaults",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Compute/disks",
    "Microsoft.Network/natGateways",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Sql/servers",
    "Microsoft.Sql/servers/databases",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Compute/virtualMachineScaleSets"
)

$nonBillableResources = @(
    "Microsoft.Web/serverfarms",
    "Microsoft.Compute/availabilitySets",
    "Microsoft.Network/networkInterfaces",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/privateEndpoints",
    "Microsoft.Network/routeTables",
    "Microsoft.Network/virtualNetworkPeerings",
    "Microsoft.Compute/images",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines"
)

function Get-ResourceClass {
    param([string]$ResourceType)

    if ($ResourceType -eq "Microsoft.Compute/virtualMachines" -or $ResourceType -eq "Microsoft.Compute/disks") {
        return "Data"
    }

    return "Config"
}

function Test-ResourceAssociated {
    param([object]$Resource)

    switch ($Resource.ResourceType) {

        "Microsoft.Compute/disks" {
            $disk = Get-AzDisk -ResourceGroupName $Resource.ResourceGroupName -DiskName $Resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $disk) { return $false }
            return ($null -ne $disk.ManagedBy -and $disk.ManagedBy -ne "")
        }

        "Microsoft.Network/publicIPAddresses" {
            $props = $Resource.Properties
            return ($null -ne $props.ipConfiguration -and $props.ipConfiguration -ne "")
        }

        "Microsoft.Network/networkInterfaces" {
            $nic = Get-AzNetworkInterface -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $nic) { return $false }
            return ($null -ne $nic.VirtualMachine -and $nic.VirtualMachine -ne "")
        }

        "Microsoft.Network/networkSecurityGroups" {
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $nsg) { return $false }
            $hasSubnetAssoc = ($nsg.Subnets -ne $null -and $nsg.Subnets.Count -gt 0)
            $hasNicAssoc = ($nsg.NetworkInterfaces -ne $null -and $nsg.NetworkInterfaces.Count -gt 0)
            return ($hasSubnetAssoc -or $hasNicAssoc)
        }

        "Microsoft.Network/applicationGateways" {
            $agw = Get-AzApplicationGateway -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $agw) { return $false }
            $hasListeners = ($agw.HttpListeners -ne $null -and $agw.HttpListeners.Count -gt 0)
            $hasBackendPools = ($agw.BackendAddressPools -ne $null -and $agw.BackendAddressPools.Count -gt 0)
            return ($hasListeners -or $hasBackendPools)
        }

        "Microsoft.Network/loadBalancers" {
            $lb = Get-AzLoadBalancer -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $lb) { return $false }
            $hasFrontend = ($lb.FrontendIpConfigurations -ne $null -and $lb.FrontendIpConfigurations.Count -gt 0)
            $hasBackend = ($lb.BackendAddressPools -ne $null -and $lb.BackendAddressPools.Count -gt 0)
            return ($hasFrontend -or $hasBackend)
        }

        "Microsoft.Network/virtualNetworks" {
            $vnet = Get-AzVirtualNetwork -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $vnet) { return $false }
            $hasSubnets = ($vnet.Subnets -ne $null -and $vnet.Subnets.Count -gt 0)
            $hasPeerings = ($vnet.VirtualNetworkPeerings -ne $null -and $vnet.VirtualNetworkPeerings.Count -gt 0)
            return ($hasSubnets -or $hasPeerings)
        }

        default {
            return $true
        }
    }
}

$subscriptionReports = @()

foreach ($sub in $subscriptions) {
    Write-Host "Processing Subscription:" $sub.Name
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $billableData = 0
    $billableConfig = 0
    $nonBillableData = 0
    $nonBillableConfig = 0

    $resources = Get-AzResource

    foreach ($resource in $resources) {
        $type = $resource.ResourceType

        # Exclude SQL master DB
        if ($type -eq "Microsoft.Sql/servers/databases" -and $resource.Name -match "/master$") {
            continue
        }

        # Exclude only the requested unused / unattached resources
        if ($type -in @(
            "Microsoft.Compute/disks",
            "Microsoft.Network/publicIPAddresses",
            "Microsoft.Network/networkInterfaces",
            "Microsoft.Network/networkSecurityGroups",
            "Microsoft.Network/applicationGateways",
            "Microsoft.Network/loadBalancers",
            "Microsoft.Network/virtualNetworks"
        )) {
            if (-not (Test-ResourceAssociated -Resource $resource)) {
                continue
            }
        }

        # VMSS = Uniform only
        if ($type -eq "Microsoft.Compute/virtualMachineScaleSets") {
            $vmss = Get-AzVmss -ResourceGroupName $resource.ResourceGroupName -VMScaleSetName $resource.Name -ErrorAction SilentlyContinue
            if ($null -ne $vmss -and $vmss.OrchestrationMode -ne "Uniform") {
                continue
            }
        }

        # Managed Disk = Data disks only
        if ($type -eq "Microsoft.Compute/disks") {
            $disk = Get-AzDisk -ResourceGroupName $resource.ResourceGroupName -DiskName $resource.Name -ErrorAction SilentlyContinue
            if ($null -eq $disk) { continue }
            if ($disk.OsType) { continue }
        }

        $resourceClass = Get-ResourceClass -ResourceType $type

        if ($billableResources -contains $type) {
            if ($resourceClass -eq "Data") { $billableData++ } else { $billableConfig++ }
        }
        elseif ($nonBillableResources -contains $type) {
            if ($resourceClass -eq "Data") { $nonBillableData++ } else { $nonBillableConfig++ }
        }
    }

    $subscriptionReports += [pscustomobject]@{
        SubscriptionName  = $sub.Name
        SubscriptionId    = $sub.Id
        BillableData      = $billableData
        BillableConfig    = $billableConfig
        NonBillableData   = $nonBillableData
        NonBillableConfig = $nonBillableConfig
        TotalBillable     = ($billableData + $billableConfig)
        TotalNonBillable  = ($nonBillableData + $nonBillableConfig)
        TotalCount        = ($billableData + $billableConfig + $nonBillableData + $nonBillableConfig)
    }
}

Write-Host ""
Write-Host "========== Billable vs Non-Billable by Subscription =========="
$subscriptionReports |
    Sort-Object SubscriptionName |
    Select-Object SubscriptionName, BillableData, BillableConfig, NonBillableData, NonBillableConfig, TotalBillable, TotalNonBillable, TotalCount |
    Format-Table -AutoSize

Write-Host ""
Write-Host "========== Tenant Totals =========="
$tenantBillableData = ($subscriptionReports | Measure-Object BillableData -Sum).Sum
$tenantBillableConfig = ($subscriptionReports | Measure-Object BillableConfig -Sum).Sum
$tenantNonBillableData = ($subscriptionReports | Measure-Object NonBillableData -Sum).Sum
$tenantNonBillableConfig = ($subscriptionReports | Measure-Object NonBillableConfig -Sum).Sum

Write-Host "Billable Data       : $tenantBillableData"
Write-Host "Billable Config     : $tenantBillableConfig"
Write-Host "Non-Billable Data   : $tenantNonBillableData"
Write-Host "Non-Billable Config : $tenantNonBillableConfig"
Write-Host "Grand Total         : $($tenantBillableData + $tenantBillableConfig + $tenantNonBillableData + $tenantNonBillableConfig)"
