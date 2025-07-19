# Check and install required modules if missing
$requiredModules = @("Az.Accounts", "Az.Sql", "Az.Compute", "Az.Resources")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Output "Module $module not found. Installing..."
        Install-Module -Name $module -Force -Scope CurrentUser
    }
    Import-Module $module -ErrorAction Stop
}

# Connect to Azure if not already connected
if (-not (Get-AzContext)) {
    Connect-AzAccount
}

# Define conversion constants
$oneTBBytes = 1099511627776  # 1 TB in bytes
$oneTBGB    = 1024           # 1 TB in GB

# Define required permissions as prerequisites
$requiredPermissions = @(
    "Microsoft.Sql/servers/read",
    "Microsoft.Sql/servers/databases/read",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/disks/read",
    "Microsoft.Resources/subscriptions/read"
)

function Test-Permission {
    param(
        [string]$RequiredPermission,
        [array]$PermissionEntries
    )
    foreach ($entry in $PermissionEntries) {
        foreach ($allowed in $entry.actions) {
            # Replace escaped wildcard characters so that permissions with
            # wildcards like "Microsoft.Sql/servers/*" are matched correctly.
            $regex = [regex]::Escape($allowed) -replace '\\*', '.*'
            if ($RequiredPermission -match "^$regex$") {
                $excluded = $false
                foreach ($denied in $entry.notActions) {
                    $nregex = [regex]::Escape($denied) -replace '\\*', '.*'
                    if ($RequiredPermission -match "^$nregex$") {
                        $excluded = $true
                        break
                    }
                }
                if (-not $excluded) {
                    return $true
                }
            }
        }
    }
    return $false
}

# Get all subscriptions
$subscriptions = Get-AzSubscription
$results = @()
$detailedResults = @()

foreach ($sub in $subscriptions) {
    Write-Output "Processing subscription: $($sub.Name) ($($sub.Id))"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Check for required permissions in the current subscription
    try {
        $permResponse = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$($sub.Id)/providers/Microsoft.Authorization/permissions?api-version=2015-07-01" -ErrorAction Stop
        $permContent = $permResponse.Content | ConvertFrom-Json
    }
    catch {
        Write-Output "Unable to retrieve permissions for subscription: $($sub.Name) ($($sub.Id)). Skipping."
        continue
    }

    $missingPermissions = @()
    foreach ($perm in $requiredPermissions) {
        if (-not (Test-Permission -RequiredPermission $perm -PermissionEntries $permContent.value)) {
            $missingPermissions += $perm
        }
    }
    if ($missingPermissions.Count -gt 0) {
        Write-Output "Subscription $($sub.Name) ($($sub.Id)) is missing the following required permissions: $($missingPermissions -join ', ')"
        Write-Output "Skipping this subscription."
        continue
    }

    # ----- Azure SQL Databases -----
    $sqlInstanceCount = 0
    $totalSQLSizeBytes = 0
    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if ($sqlServers) {
        foreach ($server in $sqlServers) {
            $databases = Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
            if ($databases) {
                foreach ($db in $databases) {
                    $sqlInstanceCount++
                    $dbSizeTB = 0
                    if ($db.MaxSizeBytes) {
                        $parsedValue = 0
                        if ([long]::TryParse($db.MaxSizeBytes.ToString(), [ref]$parsedValue)) {
                            $totalSQLSizeBytes += $parsedValue
                            $dbSizeTB = [math]::Round($parsedValue / $oneTBBytes, 2)
                        }
                    }
                    $detailedResults += [pscustomobject]@{
                        SubscriptionName  = $sub.Name
                        SubscriptionId    = $sub.Id
                        ResourceGroupName = $server.ResourceGroupName
                        ResourceType      = 'SQLDatabase'
                        ResourceName      = $db.DatabaseName
                        SizeTB            = $dbSizeTB
                    }
                }
            }
        }
    }
    $totalSQLSizeTB = [math]::Round($totalSQLSizeBytes / $oneTBBytes, 2)

    # ----- Azure VMs and Attached Disks -----
    $vmCount = 0
    $totalDiskSizeGB = 0
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    if ($vms) {
        foreach ($vm in $vms) {
            $vmCount++
            $vmDiskSizeGB = 0
            if ($vm.StorageProfile.OsDisk.DiskSizeGB) {
                $vmDiskSizeGB += $vm.StorageProfile.OsDisk.DiskSizeGB
            }
            if ($vm.StorageProfile.DataDisks) {
                foreach ($disk in $vm.StorageProfile.DataDisks) {
                    if ($disk.DiskSizeGB) {
                        $vmDiskSizeGB += $disk.DiskSizeGB
                    }
                }
            }
            $totalDiskSizeGB += $vmDiskSizeGB
            $detailedResults += [pscustomobject]@{
                SubscriptionName  = $sub.Name
                SubscriptionId    = $sub.Id
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType      = 'VirtualMachine'
                ResourceName      = $vm.Name
                SizeGB            = $vmDiskSizeGB
            }
        }
    }
    $totalDiskSizeTB = [math]::Round($totalDiskSizeGB / $oneTBGB, 2)

    # Collect results for the subscription
    $results += [pscustomobject]@{
        SubscriptionName = $sub.Name
        SubscriptionId   = $sub.Id
        SQLInstanceCount = $sqlInstanceCount
        TotalSQLSizeTB   = $totalSQLSizeTB
        VMCount          = $vmCount
        TotalDiskSizeTB  = $totalDiskSizeTB
    }
}

# Display the results on screen
$results | Format-Table -AutoSize
Write-Output "Total subscriptions processed: $($results.Count)"

# Write the results to CSV
$csvPath = Join-Path -Path (Get-Location) -ChildPath "AzureResourceSizes.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Force
Write-Output "Results have been written to CSV file: $csvPath"

# Write detailed object information to CSV for further analysis
$detailsPath = Join-Path -Path (Get-Location) -ChildPath "AzureResourceDetails.csv"
$detailedResults | Export-Csv -Path $detailsPath -NoTypeInformation -Force
Write-Output "Detailed results have been written to CSV file: $detailsPath"
