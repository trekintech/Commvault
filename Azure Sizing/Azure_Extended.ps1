#requires -Version 7.0
#requires -Modules Az.Accounts,Az.Compute,Az.Storage,Az.Sql,Az.SqlVirtualMachine,Az.ResourceGraph,Az.Monitor,Az.Resources,Az.RecoveryServices,Az.CosmosDB,Az.MySql,Az.MariaDb,Az.PostgreSql

<#
.SYNOPSIS
Collects Azure workload inventory and capacity for backup sizing with regional breakdowns.

.DESCRIPTION
Get-AzureSizingInfo.ps1 discovers and sizes:
- Azure VMs (count) and Managed Disks (capacity)
- Azure SQL Databases and SQL Managed Instances
- Azure Storage Accounts (total used), Blob Containers (optional detail), File Shares, Table Storage
- Azure Data Lake Storage Gen2
- Azure Cosmos DB (by account)
- Azure Database for MySQL/MariaDB/PostgreSQL
- Optional: Oracle Database@Azure
- Optional: Azure Backup (vaults, policies, protected items)

Outputs
1) Per-workload totals (count + GiB + TiB)
2) Per-region/per-workload breakdowns
3) Raw detail CSVs for each service
4) A lightweight HTML report for easy sharing

This script is vendor-neutral and suitable to support Commvault sizing workflows.

.EXAMPLE
./Get-AzureSizingInfo.ps1 -CurrentSubscription -OutputPath .\out

.EXAMPLE
./Get-AzureSizingInfo.ps1 -AllSubscriptions -GetContainerDetails -AutoInstallModules

.NOTES
Avoids heavy blob enumeration by default. Uses Azure Metrics and Resource Graph where possible.
#>

param (
  [CmdletBinding(DefaultParameterSetName = 'AllSubscriptions')]

  [Parameter(ParameterSetName='AllSubscriptions')]
  [switch]$AllSubscriptions,

  [Parameter(ParameterSetName='CurrentSubscription', Mandatory=$true)]
  [switch]$CurrentSubscription,

  [Parameter(ParameterSetName='Subscriptions', Mandatory=$true)]
  [string[]]$Subscriptions,

  [Parameter(ParameterSetName='ManagementGroups', Mandatory=$true)]
  [string[]]$ManagementGroups,

  [switch]$SkipAzureVMandManagedDisks,
  [switch]$SkipAzureSQLandManagedInstances,
  [switch]$SkipAzureStorageAccounts,
  [switch]$SkipAzureBackup,
  [switch]$SkipAzureCosmosDB,
  [switch]$SkipAzureDataLake,
  [switch]$SkipAzureDatabaseServices,
  [switch]$SkipOracleDatabase,

  [switch]$GetContainerDetails,
  [string]$OutputPath = ".",

  [switch]$AutoInstallModules
)

$ScriptVersion = "3.0.0"
Write-Host "`n[INFO] Azure Sizing Script v$ScriptVersion" -ForegroundColor Green

#----------------------------
# Helpers
#----------------------------
function Test-RequiredModules {
  $required = @('Az.Accounts','Az.Compute','Az.Storage','Az.Sql','Az.SqlVirtualMachine','Az.ResourceGraph','Az.Monitor','Az.Resources')
  $optional = @('Az.RecoveryServices','Az.CosmosDB','Az.MySql','Az.MariaDb','Az.PostgreSql','Az.Oracle')
  $missingRequired = @()
  foreach ($m in $required) { if (-not (Get-Module -ListAvailable -Name $m)) { $missingRequired += $m } }
  if ($missingRequired.Count -gt 0) {
    if ($AutoInstallModules) {
      Write-Host "[INFO] Installing required modules: $($missingRequired -join ', ')" -ForegroundColor Yellow
      $missingRequired | ForEach-Object { Install-Module -Name $_ -Scope CurrentUser -Force -AllowClobber }
    } else {
      Write-Host "[ERROR] Missing required modules: $($missingRequired -join ', ')" -ForegroundColor Red
      Write-Host "Re-run with -AutoInstallModules or install them manually: Install-Module -Name $($missingRequired -join ', ')" -ForegroundColor Yellow
      exit 1
    }
  }
  $optionalMissing = @()
  foreach ($m in $optional) { if (-not (Get-Module -ListAvailable -Name $m)) { $optionalMissing += $m } }
  if ($optionalMissing.Count -gt 0) {
    Write-Host "[INFO] Optional modules not found (some features may be skipped): $($optionalMissing -join ', ')" -ForegroundColor Yellow
  }
}
function Convert-Bytes {
  param([double]$Bytes)
  $GiB = [math]::Round($Bytes / 1GB, 2)      # 1024-based GiB
  $TiB = [math]::Round($Bytes / 1TB, 3)
  [pscustomobject]@{ Bytes=$Bytes; GiB=$GiB; TiB=$TiB }
}
function To-BytesFromGB {
  param([double]$GB)
  # Treat numeric "GB" properties from Azure as GiB-aligned sizes for disks/quotas
  return [double]$GB * 1GB
}
function Normalize-Location {
  param([string]$Loc)
  if (-not $Loc -or $Loc.Trim() -eq '') { return 'Unknown' }
  $l = $Loc.Trim()
  # Azure often returns lowercase region codes; keep as-is to avoid mislabeling
  return $l
}
function Add-Aggregate {
  param(
    [hashtable]$Map,
    [string]$App,
    [string]$Region,
    [double]$SizeBytes
  )
  $key = "$App|$Region"
  if (-not $Map.ContainsKey($key)) {
    $Map[$key] = [pscustomobject]@{ App=$App; Region=$Region; Count=0; Bytes=0.0 }
  }
  $Map[$key].Count++
  $Map[$key].Bytes += $SizeBytes
}
function Get-ResourcesViaGraph {
  param([string]$ResourceType,[string]$SubscriptionId)
  $q = "Resources | where type =~ '$ResourceType' and subscriptionId == '$SubscriptionId'"
  try { Search-AzGraph -Query $q -ErrorAction SilentlyContinue } catch { @() }
}
function Get-MetricBytes {
  param([string]$ResourceId,[string]$MetricName,[int]$Days=1)
  try {
    $end = Get-Date
    $start = $end.AddDays(-[math]::Max(1,$Days))
    $m = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -StartTime $start -EndTime $end -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
    $val = $m.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1
    if ($val) { return [double]$val.Average } else { return 0.0 }
  } catch { return 0.0 }
}

#----------------------------
# Init
#----------------------------
Test-RequiredModules
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$AllVMs = @()
$AllManagedDisks = @()
$AllSQLDatabases = @()
$AllSQLManagedInstances = @()
$AllStorageAccounts = @()
$AllBlobContainers = @()
$AllFileShares = @()
$AllCosmosDBAccounts = @()
$AllDataLakeGen2 = @()
$AllMariaDBServers = @()
$AllMySQLServers = @()
$AllPostgreSQLServers = @()
$AllTableStorage = @()
$AllOracleDBs = @()
$AllBackupVaults = @()
$AllBackupPolicies = @()
$AllBackupItems = @()

$Aggregates = @{}        # key: "App|Region" -> {App,Region,Count,Bytes}
$TotalsByApp = @{}       # key: "App" -> {App,Count,Bytes}

function Bump-AppTotals {
  param([string]$App,[int]$Count,[double]$Bytes)
  if (-not $TotalsByApp.ContainsKey($App)) {
    $TotalsByApp[$App] = [pscustomobject]@{ App=$App; Count=0; Bytes=0.0 }
  }
  $TotalsByApp[$App].Count += $Count
  $TotalsByApp[$App].Bytes += $Bytes
}

#----------------------------
# Target subscriptions
#----------------------------
Write-Host "[INFO] Checking Azure connection..." -ForegroundColor Green
$ctx = Get-AzContext
if (-not $ctx) { Write-Host "Not connected. Run Connect-AzAccount." -ForegroundColor Red; exit 1 }
Write-Host "[INFO] Connected as: $($ctx.Account.Id)" -ForegroundColor Green

function Get-TargetSubscriptions {
  $target = @()
  if ($CurrentSubscription) {
    $c = Get-AzContext
    $target += Get-AzSubscription -SubscriptionId $c.Subscription.Id
  } elseif ($Subscriptions) {
    foreach ($s in $Subscriptions) {
      $sub = (Get-AzSubscription -SubscriptionName $s -ErrorAction SilentlyContinue)
      if (-not $sub) { $sub = Get-AzSubscription -SubscriptionId $s -ErrorAction SilentlyContinue }
      if ($sub) { $target += $sub }
    }
  } elseif ($ManagementGroups) {
    foreach ($mg in $ManagementGroups) {
      $mgSubs = Get-AzManagementGroupSubscription -GroupName $mg
      foreach ($m in $mgSubs) { $target += Get-AzSubscription -SubscriptionId $m.Name }
    }
  } else {
    $target = Get-AzSubscription
  }
  $target
}

$targetSubscriptions = Get-TargetSubscriptions
Write-Host "[INFO] Subscriptions to process: $($targetSubscriptions.Count)" -ForegroundColor Green

#----------------------------
# Collectors
#----------------------------
function Collect-VMs-And-Disks {
  param($SubId)
  Write-Host "  [VM/Disks] $SubId" -ForegroundColor Cyan
  $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
  foreach ($vm in $vms) {
    $loc = Normalize-Location $vm.Location
    $AllVMs += [pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=$vm.ResourceGroupName; Name=$vm.Name; Location=$loc; VmSize=$vm.HardwareProfile.VmSize
    }
    Add-Aggregate -Map $Aggregates -App 'Azure VM' -Region $loc -SizeBytes 0
  }
  $disks = Get-AzDisk -ErrorAction SilentlyContinue
  foreach ($d in $disks) {
    $loc = Normalize-Location $d.Location
    $sizeBytes = To-BytesFromGB $d.DiskSizeGB
    $AllManagedDisks += [pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=$d.ResourceGroupName; Name=$d.Name; Location=$loc; Sku=$d.Sku.Name; DiskSizeGB=$d.DiskSizeGB
    }
    Add-Aggregate -Map $Aggregates -App 'Managed Disk' -Region $loc -SizeBytes $sizeBytes
  }
}

function Collect-SQL {
  param($SubId)
  Write-Host "  [SQL] $SubId" -ForegroundColor Cyan
  $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
  foreach ($s in $servers) {
    $dbs = Get-AzSqlDatabase -ServerName $s.ServerName -ResourceGroupName $s.ResourceGroupName -ErrorAction SilentlyContinue
    foreach ($db in $dbs) {
      if ($db.DatabaseName -eq 'master') { continue }
      $loc = Normalize-Location $db.Location
      $sizeBytes = [double]($db.MaxSizeBytes)
      $AllSQLDatabases += [pscustomobject]@{
        SubscriptionId=$SubId; ResourceGroup=$db.ResourceGroupName; ServerName=$s.ServerName; DatabaseName=$db.DatabaseName; Location=$loc; MaxSizeBytes=$db.MaxSizeBytes
      }
      Add-Aggregate -Map $Aggregates -App 'Azure SQL DB' -Region $loc -SizeBytes $sizeBytes
    }
  }
  $mis = Get-AzSqlInstance -ErrorAction SilentlyContinue
  foreach ($mi in $mis) {
    $loc = Normalize-Location $mi.Location
    $sizeBytes = To-BytesFromGB ($mi.StorageSizeInGB)
    $AllSQLManagedInstances += [pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=$mi.ResourceGroupName; Name=$mi.ManagedInstanceName; Location=$loc; StorageSizeInGB=$mi.StorageSizeInGB
    }
    Add-Aggregate -Map $Aggregates -App 'SQL Managed Instance' -Region $loc -SizeBytes $sizeBytes
  }
}

function Collect-Storage {
  param($SubId)
  Write-Host "  [Storage] $SubId" -ForegroundColor Cyan
  $sas = Get-AzStorageAccount -ErrorAction SilentlyContinue
  foreach ($sa in $sas) {
    $loc = Normalize-Location $sa.Location
    $acctBytes = Get-MetricBytes -ResourceId $sa.Id -MetricName 'UsedCapacity' -Days 2
    $AllStorageAccounts += [pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=$sa.ResourceGroupName; StorageAccountName=$sa.StorageAccountName; Location=$loc; Kind=$sa.Kind; Sku=$sa.Sku.Name; UsedBytes=$acctBytes
    }
    Add-Aggregate -Map $Aggregates -App 'Storage Account' -Region $loc -SizeBytes $acctBytes

    if ($sa.EnableHierarchicalNamespace) {
      $AllDataLakeGen2 += [pscustomobject]@{
        SubscriptionId=$SubId; ResourceGroup=$sa.ResourceGroupName; StorageAccountName=$sa.StorageAccountName; Location=$loc; UsedBytes=$acctBytes
      }
      Add-Aggregate -Map $Aggregates -App 'ADLS Gen2' -Region $loc -SizeBytes $acctBytes
    }

    try {
      $ctx = $sa.Context
      # File shares
      $shares = Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue
      foreach ($sh in $shares) {
        $usageBytes = 0.0
        try {
          $stats = Get-AzStorageShareStats -Share $sh -Context $ctx -ErrorAction SilentlyContinue
          if ($stats -and $stats.Usage) { $usageBytes = [double]$stats.Usage }
        } catch {}
        $AllFileShares += [pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=$sa.ResourceGroupName; StorageAccountName=$sa.StorageAccountName; ShareName=$sh.Name; Location=$loc; UsedBytes=$usageBytes
        }
        Add-Aggregate -Map $Aggregates -App 'Azure Files' -Region $loc -SizeBytes $usageBytes
      }

      # Tables (service-level metric approximation)
      $tableSvcId = "$($sa.Id)/tableServices/default"
      $tableBytes = Get-MetricBytes -ResourceId $tableSvcId -MetricName 'TableCapacity' -Days 2
      if ($tableBytes -gt 0) {
        $AllTableStorage += [pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=$sa.ResourceGroupName; StorageAccountName=$sa.StorageAccountName; Location=$loc; UsedBytes=$tableBytes
        }
        Add-Aggregate -Map $Aggregates -App 'Table Storage' -Region $loc -SizeBytes $tableBytes
      }

      # Blobs per-container (heavy) only when requested
      if ($GetContainerDetails) {
        $containers = Get-AzStorageContainer -Context $ctx -ErrorAction SilentlyContinue
        foreach ($c in $containers) {
          # Best-effort estimate by enumerating names/lengths; can be slow on large accounts
          $sumBytes = 0.0
          try {
            $blobs = Get-AzStorageBlob -Container $c.Name -Context $ctx -ErrorAction SilentlyContinue
            if ($blobs) { $sumBytes = ($blobs | Measure-Object -Property Length -Sum).Sum }
          } catch {}
          $AllBlobContainers += [pscustomobject]@{
            SubscriptionId=$SubId; ResourceGroup=$sa.ResourceGroupName; StorageAccountName=$sa.StorageAccountName; ContainerName=$c.Name; Location=$loc; UsedBytes=$sumBytes
          }
          Add-Aggregate -Map $Aggregates -App 'Blob Container' -Region $loc -SizeBytes $sumBytes
        }
      }
    } catch {
      Write-Host "    [WARN] Could not access storage context for $($sa.StorageAccountName)" -ForegroundColor Yellow
    }
  }
}

function Collect-Cosmos {
  param($SubId)
  Write-Host "  [Cosmos DB] $SubId" -ForegroundColor Cyan
  # Discover via Resource Graph, size via metrics (DataUsage + IndexUsage)
  $cosmos = Get-ResourcesViaGraph -ResourceType "microsoft.documentdb/databaseaccounts" -SubscriptionId $SubId
  foreach ($c in $cosmos) {
    $loc = Normalize-Location $c.location
    $rid = "/subscriptions/$SubId/resourceGroups/$($c.resourceGroup)/providers/Microsoft.DocumentDB/databaseAccounts/$($c.name)"
    $data = Get-MetricBytes -ResourceId $rid -MetricName 'DataUsage' -Days 2
    $index = Get-MetricBytes -ResourceId $rid -MetricName 'IndexUsage' -Days 2
    $used = $data + $index
    $AllCosmosDBAccounts += [pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=$c.resourceGroup; AccountName=$c.name; Location=$loc; UsedBytes=$used
    }
    Add-Aggregate -Map $Aggregates -App 'Cosmos DB' -Region $loc -SizeBytes $used
  }
}

function Collect-PaaS-DBs {
  param($SubId)
  Write-Host "  [MySQL/MariaDB/PostgreSQL] $SubId" -ForegroundColor Cyan
  $rgs = Get-AzResourceGroup -ErrorAction SilentlyContinue
  foreach ($rg in $rgs) {
    try {
      $maria = Get-AzMariaDbServer -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($s in $maria) {
        $loc = Normalize-Location $s.Location
        $bytes = [double]$s.StorageProfile.StorageMB * 1MB
        $AllMariaDBServers += [pscustomobject]@{ SubscriptionId=$SubId; ResourceGroup=$s.ResourceGroupName; ServerName=$s.Name; Location=$loc; UsedBytes=$bytes }
        Add-Aggregate -Map $Aggregates -App 'MariaDB' -Region $loc -SizeBytes $bytes
      }
    } catch {}
    try {
      $mysql = Get-AzMySqlServer -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($s in $mysql) {
        $loc = Normalize-Location $s.Location
        $bytes = [double]$s.StorageProfile.StorageMB * 1MB
        $AllMySQLServers += [pscustomobject]@{ SubscriptionId=$SubId; ResourceGroup=$s.ResourceGroupName; ServerName=$s.Name; Location=$loc; UsedBytes=$bytes }
        Add-Aggregate -Map $Aggregates -App 'MySQL' -Region $loc -SizeBytes $bytes
      }
    } catch {}
    try {
      $pg = Get-AzPostgreSqlServer -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($s in $pg) {
        $loc = Normalize-Location $s.Location
        $bytes = [double]$s.StorageProfile.StorageMB * 1MB
        $AllPostgreSQLServers += [pscustomobject]@{ SubscriptionId=$SubId; ResourceGroup=$s.ResourceGroupName; ServerName=$s.Name; Location=$loc; UsedBytes=$bytes }
        Add-Aggregate -Map $Aggregates -App 'PostgreSQL' -Region $loc -SizeBytes $bytes
      }
    } catch {}
  }
}

function Collect-Oracle {
  param($SubId)
  if ($SkipOracleDatabase) { return }
  if (-not (Get-Module -ListAvailable -Name Az.Oracle)) {
    Write-Host "  [Oracle] Az.Oracle not installed; skipping." -ForegroundColor Yellow
    return
  }
  Write-Host "  [Oracle] $SubId" -ForegroundColor Cyan
  Import-Module Az.Oracle -ErrorAction SilentlyContinue
  $rgs = Get-AzResourceGroup -ErrorAction SilentlyContinue
  foreach ($rg in $rgs) {
    try {
      $adbs = Get-AzOracleAutonomousDatabase -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($db in $adbs) {
        $loc = Normalize-Location $db.Location
        $bytes = ([double]$db.DataStorageSizeInTBs) * 1TB
        $AllOracleDBs += [pscustomobject]@{ SubscriptionId=$SubId; ResourceGroup=$rg.ResourceGroupName; Name=$db.Name; Location=$loc; UsedBytes=$bytes }
        Add-Aggregate -Map $Aggregates -App 'Oracle@Azure' -Region $loc -SizeBytes $bytes
      }
    } catch {}
  }
}

function Collect-Backup {
  param($SubId)
  if ($SkipAzureBackup) { return }
  Write-Host "  [Azure Backup] $SubId" -ForegroundColor Cyan
  $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
  foreach ($v in $vaults) {
    $loc = Normalize-Location $v.Location
    $AllBackupVaults += [pscustomobject]@{ SubscriptionId=$SubId; ResourceGroup=$v.ResourceGroupName; VaultName=$v.Name; Location=$loc }
    try {
      Set-AzRecoveryServicesVaultContext -Vault $v -ErrorAction SilentlyContinue
      $pol = Get-AzRecoveryServicesBackupProtectionPolicy -ErrorAction SilentlyContinue
      foreach ($p in $pol) {
        $AllBackupPolicies += [pscustomobject]@{ SubscriptionId=$SubId; VaultName=$v.Name; PolicyName=$p.Name; WorkloadType=$p.WorkloadType; BackupManagementType=$p.BackupManagementType }
      }
      $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -ErrorAction SilentlyContinue
      foreach ($c in $containers) {
        $items = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -ErrorAction SilentlyContinue
        foreach ($i in $items) {
          $AllBackupItems += [pscustomobject]@{
            SubscriptionId=$SubId; VaultName=$v.Name; ItemName=$i.Name; ProtectionState=$i.ProtectionState; LastBackupTime=$i.LastBackupTime
          }
        }
      }
    } catch {}
  }
}

#----------------------------
# Execute per subscription
#----------------------------
foreach ($sub in $targetSubscriptions) {
  Write-Host "`n[INFO] Processing: $($sub.Name) ($($sub.Id))" -ForegroundColor Yellow
  Set-AzContext -SubscriptionId $sub.Id | Out-Null

  if (-not $SkipAzureVMandManagedDisks) { Collect-VMs-And-Disks -SubId $sub.Id }
  if (-not $SkipAzureSQLandManagedInstances) { Collect-SQL -SubId $sub.Id }
  if (-not $SkipAzureStorageAccounts) { Collect-Storage -SubId $sub.Id }
  if (-not $SkipAzureCosmosDB) { Collect-Cosmos -SubId $sub.Id }
  if (-not $SkipAzureDatabaseServices) { Collect-PaaS-DBs -SubId $sub.Id }
  if (-not $SkipOracleDatabase) { Collect-Oracle -SubId $sub.Id }
  if (-not $SkipAzureBackup) { Collect-Backup -SubId $sub.Id }
}

#----------------------------
# Build summaries
#----------------------------
# Roll Aggregates into TotalsByApp
foreach ($kv in $Aggregates.GetEnumerator()) {
  $rec = $kv.Value
  Bump-AppTotals -App $rec.App -Count $rec.Count -Bytes $rec.Bytes
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory | Out-Null }

# Per-app totals CSV
$byApp = $TotalsByApp.Values | Sort-Object App | ForEach-Object {
  $conv = Convert-Bytes $_.Bytes
  [pscustomobject]@{
    App       = $_.App
    Count     = $_.Count
    Size_GiB  = $conv.GiB
    Size_TiB  = $conv.TiB
  }
}
$byAppFile = Join-Path $OutputPath "azure_sizing_by_app_$timestamp.csv"
$byApp | Export-Csv -Path $byAppFile -NoTypeInformation

# Per-region per-app CSV
$byRegionApp = $Aggregates.Values | Sort-Object Region,App | ForEach-Object {
  $conv = Convert-Bytes $_.Bytes
  [pscustomobject]@{
    Region    = $_.Region
    App       = $_.App
    Count     = $_.Count
    Size_GiB  = $conv.GiB
    Size_TiB  = $conv.TiB
  }
}
$byRegionFile = Join-Path $OutputPath "azure_sizing_by_region_$timestamp.csv"
$byRegionApp | Export-Csv -Path $byRegionFile -NoTypeInformation

# Also export raw detail CSVs (for traceability)
if ($AllVMs.Count)                { $AllVMs                | Export-Csv (Join-Path $OutputPath "azure_vms_$timestamp.csv") -NoTypeInformation }
if ($AllManagedDisks.Count)       { $AllManagedDisks       | Export-Csv (Join-Path $OutputPath "azure_managed_disks_$timestamp.csv") -NoTypeInformation }
if ($AllSQLDatabases.Count)       { $AllSQLDatabases       | Export-Csv (Join-Path $OutputPath "azure_sql_databases_$timestamp.csv") -NoTypeInformation }
if ($AllSQLManagedInstances.Count){ $AllSQLManagedInstances| Export-Csv (Join-Path $OutputPath "azure_sql_managed_instances_$timestamp.csv") -NoTypeInformation }
if ($AllStorageAccounts.Count)    { $AllStorageAccounts    | Export-Csv (Join-Path $OutputPath "azure_storage_accounts_$timestamp.csv") -NoTypeInformation }
if ($AllBlobContainers.Count)     { $AllBlobContainers     | Export-Csv (Join-Path $OutputPath "azure_blob_containers_$timestamp.csv") -NoTypeInformation }
if ($AllFileShares.Count)         { $AllFileShares         | Export-Csv (Join-Path $OutputPath "azure_file_shares_$timestamp.csv") -NoTypeInformation }
if ($AllCosmosDBAccounts.Count)   { $AllCosmosDBAccounts   | Export-Csv (Join-Path $OutputPath "azure_cosmosdb_accounts_$timestamp.csv") -NoTypeInformation }
if ($AllDataLakeGen2.Count)       { $AllDataLakeGen2       | Export-Csv (Join-Path $OutputPath "azure_datalake_gen2_$timestamp.csv") -NoTypeInformation }
if ($AllMariaDBServers.Count)     { $AllMariaDBServers     | Export-Csv (Join-Path $OutputPath "azure_mariadb_servers_$timestamp.csv") -NoTypeInformation }
if ($AllMySQLServers.Count)       { $AllMySQLServers       | Export-Csv (Join-Path $OutputPath "azure_mysql_servers_$timestamp.csv") -NoTypeInformation }
if ($AllPostgreSQLServers.Count)  { $AllPostgreSQLServers  | Export-Csv (Join-Path $OutputPath "azure_postgresql_servers_$timestamp.csv") -NoTypeInformation }
if ($AllTableStorage.Count)       { $AllTableStorage       | Export-Csv (Join-Path $OutputPath "azure_table_storage_$timestamp.csv") -NoTypeInformation }
if ($AllOracleDBs.Count)          { $AllOracleDBs          | Export-Csv (Join-Path $OutputPath "azure_oracle_databases_$timestamp.csv") -NoTypeInformation }
if ($AllBackupVaults.Count)       { $AllBackupVaults       | Export-Csv (Join-Path $OutputPath "azure_backup_vaults_$timestamp.csv") -NoTypeInformation }
if ($AllBackupPolicies.Count)     { $AllBackupPolicies     | Export-Csv (Join-Path $OutputPath "azure_backup_policies_$timestamp.csv") -NoTypeInformation }
if ($AllBackupItems.Count)        { $AllBackupItems        | Export-Csv (Join-Path $OutputPath "azure_backup_items_$timestamp.csv") -NoTypeInformation }

# HTML Summary (nice, portable)
$css = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin:20px; }
h1 { color:#0b6aa2; }
h2 { color:#0b6aa2; margin-top:30px; }
table { border-collapse: collapse; width: 100%; margin: 10px 0 30px 0; }
th, td { border: 1px solid #ddd; padding: 8px; }
th { background: #e6f2f9; text-align: left; }
tr:nth-child(even) { background: #fafafa; }
.badge { display:inline-block; padding:4px 8px; background:#0b6aa2; color:#fff; border-radius:4px; font-size:12px; }
.note { color:#666; font-size:12px; }
</style>
"@

$totalGiB = [math]::Round(($TotalsByApp.Values | Measure-Object -Property Bytes -Sum).Sum / 1GB, 2)
$totalTiB = [math]::Round(($TotalsByApp.Values | Measure-Object -Property Bytes -Sum).Sum / 1TB, 3)

$byAppHtml = $byApp | ConvertTo-Html -Property App,Count,Size_GiB,Size_TiB -Fragment
$topRegions = $byRegionApp | Group-Object Region | ForEach-Object {
  [pscustomobject]@{
    Region = $_.Name
    Resources = ($_.Group | Measure-Object -Property Count -Sum).Sum
    TiB = [math]::Round(($_.Group | Measure-Object -Property Size_TiB -Sum).Sum, 3)
  }
} | Sort-Object TiB -Descending | Select-Object -First 10
$topRegionsHtml = $topRegions | ConvertTo-Html -Property Region,Resources,TiB -Fragment

$report = @"
<html><head><meta charset="utf-8"><title>Azure Sizing Report</title>$css</head>
<body>
<h1>Azure Sizing Report <span class="badge">v$ScriptVersion</span></h1>
<p>Generated: $(Get-Date)</p>
<h2>Totals by App</h2>
$byAppHtml
<p class="note">Sizes shown in GiB/TiB (1024-based). Counts reflect discovered objects; sizes reflect provisioned/used metrics per service.</p>
<h2>Top Regions by Capacity</h2>
$topRegionsHtml
</body></html>
"@
$reportFile = Join-Path $OutputPath "azure_sizing_report_$timestamp.html"
$report | Out-File -FilePath $reportFile -Encoding UTF8

# Console pretty print
Write-Host "`n================ WORKLOAD TOTALS ================" -ForegroundColor Cyan
$byApp | Format-Table -AutoSize

Write-Host "`n================ TOP REGIONS (by TiB) ================" -ForegroundColor Cyan
$topRegions | Format-Table -AutoSize

Write-Host "`n[INFO] Outputs"
Write-Host " - $byAppFile"
Write-Host " - $byRegionFile"
Write-Host " - $reportFile"
Write-Host " - Raw CSVs for each service in $OutputPath"
Write-Host "`n[DONE] Azure sizing complete." -ForegroundColor Green
