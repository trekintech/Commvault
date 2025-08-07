#requires -Version 7.0
#requires -Modules `
    Az.Accounts, `
    Az.Compute, `
    Az.Storage, `
    Az.Sql, `
    Az.SqlVirtualMachine, `
    Az.ResourceGraph, `
    Az.Monitor, `
    Az.Resources, `
    Az.RecoveryServices, `
    Az.CostManagement, `
    Az.CosmosDB, `
    Az.MySql, `
    Az.MariaDb, `
    Az.PostgreSql, `
    Az.Table

<#
.SYNOPSIS
Collects sizing and usage info across Azure workloads:
  • VMs & Managed Disks
  • SQL Databases & Managed Instances
  • MySQL, MariaDB, PostgreSQL
  • Cosmos DB
  • Table Storage
  • Blob & File Storage
  • Recovery Services Vaults/Policies/Items/Cost
  • (Optional) Key Vault counts
  • Oracle Database@Azure
Exports detailed CSVs and a summary CSV breaking down by Subscription, ResourceGroup, Region.
#>

param (
  [Parameter(ParameterSetName='AllSubscriptions', Mandatory=$false)] [switch]$AllSubscriptions,
  [Parameter(ParameterSetName='CurrentSubscription', Mandatory=$true)]  [switch]$CurrentSubscription,
  [Parameter(ParameterSetName='Subscriptions', Mandatory=$true)]       [string]$Subscriptions = '',
  [Parameter(ParameterSetName='SubscriptionIds', Mandatory=$true)]     [string]$SubscriptionIds = '',
  [Parameter(ParameterSetName='ManagementGroups', Mandatory=$true)]    [string]$ManagementGroups,
  [switch]$GetContainerDetails,
  [switch]$GetKeyVaultAmounts,
  [switch]$SkipAzureBackup,
  [switch]$SkipAzureFiles,
  [switch]$SkipAzureSQLandMI,
  [switch]$SkipAzureStorageAccounts,
  [switch]$SkipAzureVMandManagedDisks,
  [switch]$SkipAzureCosmosDB,
  [switch]$Anonymize,
  [string]$AnonymizeFields,
  [string]$NotAnonymizeFields
)

# -- preserve culture --
$OriginalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
[Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'

# -- timestamp & logs --
$date         = Get-Date
$fileDate     = $date.ToString('yyyy-MM-dd_HHmm')
$logFile      = "output_azure_$fileDate.log"
if (Test-Path $logFile) { Remove-Item $logFile }
Start-Transcript -Path $logFile

# -- import modules --
Import-Module `
  Az.Accounts,Az.Compute,Az.Storage,Az.Sql,Az.SqlVirtualMachine,`
  Az.ResourceGraph,Az.Monitor,Az.Resources,Az.RecoveryServices,`
  Az.CostManagement,Az.CosmosDB,Az.MySql,Az.MariaDb,Az.PostgreSql,Az.Table -ErrorAction Stop

# -- determine subscriptions --
$ctx   = Get-AzContext
switch ($PSCmdlet.ParameterSetName) {
  'AllSubscriptions'   { $subs = Get-AzSubscription -TenantId $ctx.Tenant.Id }
  'CurrentSubscription'{ $subs = Get-AzSubscription -TenantId $ctx.Tenant.Id -SubscriptionName $ctx.Subscription.Name }
  'Subscriptions'      { $subs = $Subscriptions.Split(',') | ForEach-Object { Get-AzSubscription -SubscriptionName $_ -TenantId $ctx.Tenant.Id } }
  'SubscriptionIds'    { $subs = $SubscriptionIds.Split(',') | ForEach-Object { Get-AzSubscription -SubscriptionId $_ -TenantId $ctx.Tenant.Id } }
  'ManagementGroups'   {
    $subs = @()
    foreach ($mg in $ManagementGroups.Split(',')) {
      $ids = Search-AzGraph -Query "ResourceContainers | where type=='microsoft.resources/subscriptions' and managementGroupIds has '$mg'" 
      $subs += ($ids | Select-Object -ExpandProperty name | ForEach-Object { Get-AzSubscription -SubscriptionId $_ -TenantId $ctx.Tenant.Id })
    }
  }
}

# -- prepare collections --
$vmList       = @()
$attachedList = @(); $unattachedList = @()
$sqlList      = @(); $miList = @()
$mysqlList    = @(); $mariaList = @(); $pgList = @()
$cosmosList   = @()
$tableList    = @()
$blobList     = @(); $fileList = @()
$vaultList    = @(); $vaultPolicyList = @(); $vaultItemList = @(); $backupCostList = @()
$kvList       = @()
$oracleList   = @()

# -- process each subscription --
foreach ($sub in $subs) {
  Set-AzContext -Subscription $sub.Id -Tenant $ctx.Tenant.Id | Out-Null
  $tenant = (Get-AzTenant -TenantId $sub.TenantId).Name

  #
  # VMs & Managed Disks
  #
  if (-not $SkipAzureVMandManagedDisks) {
    $vms = Get-AzVM -ErrorAction Continue
    foreach ($vm in $vms) {
      $disks      = $vm.StorageProfile.OSDisk, $vm.StorageProfile.DataDisks
      $countDisk  = $disks.Count
      $sizeGiB    = ($disks | Measure-Object -Property DiskSizeGB -Sum).Sum
      $obj = [PSCustomObject]@{
        Subscription    = $sub.Name
        Tenant          = $tenant
        ResourceGroup   = $vm.ResourceGroupName
        Region          = $vm.Location
        Name            = $vm.Name
        VMSize          = $vm.HardwareProfile.VmSize
        Status          = $vm.ProvisioningState
        DiskCount       = $countDisk
        DiskSizeGiB     = $sizeGiB
        DiskSizeTiB     = [math]::Round($sizeGiB/1024,4)
        HasMSSQL        = 'No'
      }
      # tags
      foreach ($k in $vm.Tags.Keys) {
        $obj | Add-Member -NotePropertyName "Tag_$k" -NotePropertyValue $vm.Tags[$k] -Force
      }
      $vmList += $obj
    }
    # mark SQL VMs
    Get-AzSqlVM -ErrorAction Continue | ForEach-Object {
      $match = $vmList | Where-Object { $_.Name -eq $_.Name -and $_.Subscription -eq $sub.Name }
      if ($match) { $match.HasMSSQL = 'Yes'}
    }
  }

  #
  # Azure SQL & Managed Instances
  #
  if (-not $SkipAzureSQLandMI) {
    # standalone DBs + pools
    foreach ($srv in Get-AzSqlServer -ErrorAction Continue) {
      $dbs = Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction Continue
      foreach ($db in $dbs) {
        if ($db.SkuName -eq 'System') { continue }
        $isPool = $db.SkuName -eq 'ElasticPool'
        if ($isPool) { continue }  # elastic pools handled separately if desired
        $obj = [PSCustomObject]@{
          Subscription  = $sub.Name
          Tenant        = $tenant
          ResourceGroup = $srv.ResourceGroupName
          Region        = $srv.Location
          ResourceType  = 'AzureSQL'
          Name          = $db.DatabaseName
          Tier          = $db.SkuName
          MaxSizeGiB    = [math]::Round($db.MaxSizeBytes/1GB,2)
          MaxSizeTiB    = [math]::Round($db.MaxSizeBytes/1TB,4)
        }
        $sqlList += $obj
      }
    }
    # managed instances
    foreach ($mi in Get-AzSqlInstance -ErrorAction Continue) {
      $obj = [PSCustomObject]@{
        Subscription  = $sub.Name
        Tenant        = $tenant
        ResourceGroup = $mi.ResourceGroupName
        Region        = $mi.Location
        ResourceType  = 'SQLMI'
        Name          = $mi.ManagedInstanceName
        Tier          = $mi.Sku.Name
        MaxSizeGiB    = $mi.StorageSizeInGB
        MaxSizeTiB    = [math]::Round($mi.StorageSizeInGB/1024,4)
      }
      $miList += $obj
    }
  }

  #
  # MySQL, MariaDB, PostgreSQL
  #
  foreach ($srv in Get-AzMySqlServer -ErrorAction Continue) {
    $obj = [PSCustomObject]@{
      Subscription  = $sub.Name
      Tenant        = $tenant
      ResourceGroup = $srv.ResourceGroupName
      Region        = $srv.Location
      ResourceType  = 'MySQL'
      Name          = $srv.Name
      Tier          = $srv.Sku.Name
      StorageGiB    = [math]::Round($srv.StorageProfile.StorageMB/1024,2)
    }
    $mysqlList += $obj
  }
  foreach ($srv in Get-AzMariaDbServer -ErrorAction Continue) {
    $obj = [PSCustomObject]@{
      Subscription  = $sub.Name
      Tenant        = $tenant
      ResourceGroup = $srv.ResourceGroupName
      Region        = $srv.Location
      ResourceType  = 'MariaDB'
      Name          = $srv.Name
      Tier          = $srv.Sku.Name
      StorageGiB    = [math]::Round($srv.StorageProfile.StorageMB/1024,2)
    }
    $mariaList += $obj
  }
  foreach ($srv in Get-AzPostgreSqlServer -ErrorAction Continue) {
    $obj = [PSCustomObject]@{
      Subscription  = $sub.Name
      Tenant        = $tenant
      ResourceGroup = $srv.ResourceGroupName
      Region        = $srv.Location
      ResourceType  = 'PostgreSQL'
      Name          = $srv.Name
      Tier          = $srv.Sku.Name
      StorageGiB    = [math]::Round($srv.StorageProfile.StorageMB/1024,2)
    }
    $pgList += $obj
  }

  #
  # Table Storage
  #
  try {
    $sas = Get-AzStorageAccount -ErrorAction Continue | Where-Object Kind -in 'StorageV2','Table'
    foreach ($sa in $sas) {
      $ctx   = $sa.Context
      $tabs  = Get-AzTable –Context $ctx -ErrorAction Continue
      foreach ($t in $tabs) {
        $obj = [PSCustomObject]@{
          Subscription  = $sub.Name
          Tenant        = $tenant
          ResourceGroup = $sa.ResourceGroupName
          Region        = $sa.PrimaryLocation
          ResourceType  = 'TableStorage'
          Account       = $sa.StorageAccountName
          TableName     = $t.Name
        }
        $tableList += $obj
      }
    }
  } catch { Write-Host "TableStorage error: $_" -ForegroundColor Yellow }

  #
  # Cosmos DB
  #
  if (-not $SkipAzureCosmosDB) {
    foreach ($acc in Get-AzCosmosDBAccount -ErrorAction Continue) {
      $obj = [PSCustomObject]@{
        Subscription  = $sub.Name
        Tenant        = $tenant
        ResourceGroup = $acc.ResourceGroupName
        Region        = $acc.Location
        ResourceType  = 'CosmosDB'
        Name          = $acc.Name
        Kind          = $acc.Kind
        OfferType     = $acc.NameDatabaseAccountOfferType
      }
      $cosmosList += $obj
    }
  }

  #
  # Blob & File Storage (metrics)
  #
  if (-not $SkipAzureStorageAccounts) {
    $sas = Get-AzStorageAccount -ErrorAction Continue
    foreach ($sa in $sas) {
      $resId = $sa.Id
      # Blob
      $mb = (Get-AzMetric -ResourceId "$resId/blobServices/default" -MetricName BlobCapacity -Aggregation Maximum -ErrorAction SilentlyContinue).Data.Maximum[-1]
      $objB = [PSCustomObject]@{
        Subscription  = $sub.Name; Tenant=$tenant; ResourceGroup=$sa.ResourceGroupName; Region=$sa.PrimaryLocation;
        ResourceType='BlobStorage'; Account=$sa.StorageAccountName; UsedGiB=[math]::Round($mb/1GB,2)
      }
      $blobList += $objB
      # File
      $mf = (Get-AzMetric -ResourceId "$resId/fileServices/default" -MetricName FileCapacity -Aggregation Maximum -ErrorAction SilentlyContinue).Data.Maximum[-1]
      $objF = [PSCustomObject]@{
        Subscription  = $sub.Name; Tenant=$tenant; ResourceGroup=$sa.ResourceGroupName; Region=$sa.PrimaryLocation;
        ResourceType='FileStorage'; Account=$sa.StorageAccountName; UsedGiB=[math]::Round($mf/1GB,2)
      }
      $fileList += $objF
    }
  }

  #
  # Recovery Services Vaults & Backup
  #
  if (-not $SkipAzureBackup) {
    foreach ($vault in Get-AzRecoveryServicesVault -ErrorAction Continue) {
      $vp = Get-AzRecoveryServicesBackupProtectionPolicy -Vault $vault -ErrorAction Continue
      $vi = $vp | ForEach-Object { Get-AzRecoveryServicesBackupItem -Policy $_ -ErrorAction SilentlyContinue }
      $cost = (Invoke-AzCostManagementQuery -Type Usage -Scope "subscriptions/$($sub.SubscriptionId)" `
                 -DatasetGranularity Monthly -Timeframe MonthToDate `
                 -DatasetFilter (New-AzCostManagementQueryFilterObject -Dimensions (New-AzCostManagementQueryComparisonExpressionObject -Name 'ServiceName' -Value 'Backup')) `
                 -DatasetAggregation @{ totalCostUSD = @{ name='CostUSD'; function='Sum' } } `
                 -ErrorAction SilentlyContinue).Rows | ForEach-Object {
                   [PSCustomObject]@{
                     Subscription=$sub.Name; Tenant=$tenant; Month=$_[-1]; CostUSD=[math]::Round($_[0],2)
                   }
                 }

      $vaultList      += [PSCustomObject]@{ Subscription=$sub.Name; Tenant=$tenant; ResourceGroup=$vault.ResourceGroupName; Region=$vault.Location; Name=$vault.Name }
      $vaultPolicyList+= $vp
      $vaultItemList  += $vi
      $backupCostList += $cost
    }
  }

  #
  # Key Vault counts
  #
  if ($GetKeyVaultAmounts) {
    foreach ($kv in Get-AzKeyVault -ErrorAction Continue) {
      $certs = (Get-AzKeyVaultCertificate -VaultName $kv.VaultName -ErrorAction SilentlyContinue).Count
      $secrs = (Get-AzKeyVaultSecret -VaultName $kv.VaultName -ErrorAction SilentlyContinue).Count
      $keys  = (Get-AzKeyVaultKey -VaultName $kv.VaultName -ErrorAction SilentlyContinue).Count
      $kvList += [PSCustomObject]@{
        Subscription=$sub.Name; Tenant=$tenant; ResourceGroup=$kv.ResourceGroupName; Region=$kv.Location; Name=$kv.VaultName;
        CertCount=$certs; SecretCount=$secrs; KeyCount=$keys
      }
    }
  }

  #
  # Oracle Database@Azure via Resource Graph
  #
  try {
    $ords = Search-AzGraph -Query "Resources | where type=='Microsoft.Oracle/servers'"
    foreach ($o in $ords) {
      $oracleList += [PSCustomObject]@{
        Subscription  = $sub.Name; Tenant=$tenant; ResourceGroup=$o.resourceGroup; Region=$o.location;
        ResourceType='Oracle@Azure'; Name=$o.name; SKU=$o.sku.name
      }
    }
  } catch { Write-Host "Oracle@Azure error: $_" -ForegroundColor Yellow }

} # end foreach subscription

# -- Export CSVs --
$outputDir = "."
$lists = @{
  azure_vms               = $vmList
  azure_sql               = $sqlList
  azure_sqlmi             = $miList
  azure_mysql             = $mysqlList
  azure_mariadb           = $mariaList
  azure_postgresql        = $pgList
  azure_cosmosdb          = $cosmosList
  azure_tablestorage      = $tableList
  azure_blobstorage       = $blobList
  azure_filestorage       = $fileList
  azure_backup_vaults     = $vaultList
  azure_backup_policies   = $vaultPolicyList
  azure_backup_items      = $vaultItemList
  azure_backup_costs      = $backupCostList
  azure_keyvaults         = $kvList
  azure_oracle            = $oracleList
}

foreach ($name in $lists.Keys) {
  $data = $lists[$name]
  if ($data -and $data.Count -gt 0) {
    $path = Join-Path $outputDir "${name}_$fileDate.csv"
    $data | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Exported $path"
  }
}

#
# Create a combined summary that breaks down by Subscription / ResourceGroup / Region / ResourceType
#
$summary = @()
foreach ($name in $lists.Keys) {
  $data = $lists[$name]
  if ($data -and $data.Count -gt 0) {
    $grouped = $data |
      Group-Object Subscription,ResourceGroup,Region |
      ForEach-Object {
        [PSCustomObject]@{
          Subscription   = $_.Name.Subscription
          ResourceGroup  = $_.Name.ResourceGroup
          Region         = $_.Name.Region
          ResourceType   = $name
          Count          = $_.Count
        }
      }
    $summary += $grouped
  }
}
$summaryPath = Join-Path $outputDir "azure_sizing_summary_$fileDate.csv"
$summary | Export-Csv -Path $summaryPath -NoTypeInformation
Write-Host "Exported summary to $summaryPath"

Stop-Transcript
# -- restore culture --
[Threading.Thread]::CurrentThread.CurrentCulture = $OriginalCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = $OriginalCulture
