#requires -Version 7.0
#requires -Modules Az.Accounts,Az.Compute,Az.Storage,Az.Sql,Az.SqlVirtualMachine,Az.ResourceGraph,Az.Monitor,Az.Resources,Az.RecoveryServices,Az.CosmosDB,Az.MySql,Az.MariaDb,Az.PostgreSql

<#
.SYNOPSIS
Collects Azure workload inventory and capacity for backup sizing with regional breakdowns — without double-counting storage.

.DESCRIPTION
Discovers and sizes:
- Azure VMs (count) and Managed Disks (capacity)
- Azure SQL Databases and SQL Managed Instances
- Storage Accounts (detail only), Azure Files (per share), Table Storage (service metric), Blob Containers (optional)
- ADLS Gen2 (detail only; capacity not double-counted)
- Cosmos DB (DataUsage + IndexUsage)
- Azure Database for MySQL/MariaDB/PostgreSQL
- Azure NetApp Files (volumes via Az.NetAppFiles)
- Optional: Oracle Database@Azure (install/prompt supported)
- Optional: Azure Backup (vaults, policies, items)

Outputs
- Per-app totals (Count, GiB, TiB)
- Per-region/per-app breakdowns (Count, GiB, TiB) with no storage duplication
- HTML summary with totals + “Capacity by Region & App”
- Raw detail CSVs

Anonymisation (optional)
- -AnonymizeScope None|ResourceGroups|Objects|All (default None)
- -AnonymizeSalt "<secret>" for stable pseudonyms across runs
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
  [switch]$SkipAzureNetAppFiles,

  [switch]$GetContainerDetails,
  [string]$OutputPath = ".",

  [switch]$AutoInstallModules,

  # Anonymisation
  [ValidateSet('None','ResourceGroups','Objects','All')]
  [string]$AnonymizeScope = 'None',
  [string]$AnonymizeSalt,

  # Prompt installs for optional providers
  [switch]$PromptInstallOracle,
  [switch]$PromptInstallNetApp,

  # Storage aggregation control:
  #   Default (false) = service-level breakout (Files/Tables/Blobs). No storage-account aggregation -> no double count.
  #   True = account-level only (aggregate whole account, skip per-service adds).
  [switch]$AggregateStorageAtAccountLevel
)

$ScriptVersion = "3.4.3"
Write-Host "`n[INFO] Azure Sizing Script v$ScriptVersion" -ForegroundColor Green

# Quiet deprecation spam from Get-AzMetric
$PSDefaultParameterValues['Get-AzMetric:WarningAction'] = 'SilentlyContinue'

#----------------------------
# Helpers
#----------------------------
function Test-RequiredModules {
  $required = @('Az.Accounts','Az.Compute','Az.Storage','Az.Sql','Az.SqlVirtualMachine','Az.ResourceGraph','Az.Monitor','Az.Resources')
  $optional = @('Az.RecoveryServices','Az.CosmosDB','Az.MySql','Az.MariaDb','Az.PostgreSql','Az.NetAppFiles')

  $missingRequired = @()
  foreach ($m in $required) { if (-not (Get-Module -ListAvailable -Name $m)) { $missingRequired += $m } }
  if ($missingRequired.Count -gt 0) {
    if ($AutoInstallModules) {
      Write-Host "[INFO] Installing required modules: $($missingRequired -join ', ')" -ForegroundColor Yellow
      foreach ($m in $missingRequired) { Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber }
    } else {
      Write-Host "[ERROR] Missing required modules: $($missingRequired -join ', ')" -ForegroundColor Red
      Write-Host "Re-run with -AutoInstallModules or install: Install-Module -Name $($missingRequired -join ', ') -Scope CurrentUser" -ForegroundColor Yellow
      exit 1
    }
  }

  $optionalMissing = @()
  foreach ($m in $optional) { if (-not (Get-Module -ListAvailable -Name $m)) { $optionalMissing += $m } }
  if ($optionalMissing.Count -gt 0) {
    Write-Host "[INFO] Optional modules not found (some features may be skipped): $($optionalMissing -join ', ')" -ForegroundColor Yellow
  }
}

function Convert-Bytes { param([double]$Bytes)
  $GiB = [math]::Round($Bytes / 1GB, 2)
  $TiB = [math]::Round($Bytes / 1TB, 3)
  [pscustomobject]@{ Bytes=$Bytes; GiB=$GiB; TiB=$TiB }
}
function To-BytesFromGB { param([double]$GB) return [double]$GB * 1GB }
function Normalize-Location { param([string]$Loc) if ([string]::IsNullOrWhiteSpace($Loc)){'Unknown'}else{$Loc.Trim()} }

# Deterministic pseudonyms
$__AnonMap = @{}
if ($AnonymizeScope -ne 'None') {
  if (-not $AnonymizeSalt) { $AnonymizeSalt = [Guid]::NewGuid().Guid; Write-Host "[INFO] Anonymisation enabled (salt set for this run)" -ForegroundColor Yellow }
  function Get-PseudoName {
    param([string]$Value,[string]$Prefix='obj-')
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($__AnonMap.ContainsKey($Value)) { return $__AnonMap[$Value] }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($AnonymizeSalt)|$Value")
    $hash = $sha.ComputeHash($bytes)
    $b64  = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+','').Replace('/','')
    $token = "$Prefix$($b64.Substring(0,10))"
    $__AnonMap[$Value] = $token
    return $token
  }
  function Anon-RG { param([string]$Name) if ($AnonymizeScope -in @('ResourceGroups','All')) { Get-PseudoName -Value $Name -Prefix 'rg-' } else { $Name } }
  function Anon-Obj { param([string]$Name,[string]$Prefix='obj-') if ($AnonymizeScope -in @('Objects','All')) { Get-PseudoName -Value $Name -Prefix $Prefix } else { $Name } }
} else {
  function Anon-RG { param([string]$Name) return $Name }
  function Anon-Obj { param([string]$Name,[string]$Prefix='obj-') return $Name }
}

# Aggregate helpers (no '+=' on PSObjects)
function Add-Aggregate {
  param([hashtable]$Map,[string]$App,[string]$Region,[double]$SizeBytes)
  $key = "$App|$Region"
  if (-not $Map.ContainsKey($key)) {
    $Map[$key] = [pscustomobject]@{ App=$App; Region=$Region; Count=[int]0; Bytes=[double]0.0 }
  }
  $Map[$key].Count = [int]$Map[$key].Count + 1
  $Map[$key].Bytes = [double]$Map[$key].Bytes + [double]$SizeBytes
}
function New-List { New-Object System.Collections.ArrayList }
function Add-ListItem { param([System.Collections.ArrayList]$List,[object]$Item) [void]$List.Add($Item) }

# ===== metrics helper (supports agg/grain selection) =====
function Get-MetricBytes {
  param(
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][string]$MetricName,
    [int]$Days = 2,
    [string]$MetricNamespace,
    [string]$Filter,
    [hashtable]$Dimensions,
    [ValidateSet('Average','Minimum','Maximum','Total','Count')]
    [string]$AggregationType = 'Average',
    [TimeSpan]$TimeGrain = ([TimeSpan]::Parse('01:00:00'))
  )
  try {
    $end = Get-Date; $start = $end.AddDays(-[math]::Max(1,$Days))
    $args = @{
      ResourceId      = $ResourceId
      MetricName      = $MetricName
      StartTime       = $start
      EndTime         = $end
      TimeGrain       = $TimeGrain
      AggregationType = $AggregationType
      ErrorAction     = 'SilentlyContinue'
      WarningAction   = 'SilentlyContinue'
    }
    if ($MetricNamespace) { $args.MetricNamespace = $MetricNamespace }
    if ($Filter) { $args.Filter = $Filter }
    elseif ($Dimensions) {
      $pairs = @()
      foreach ($k in $Dimensions.Keys) { $pairs += ("{0} eq '{1}'" -f $k,$Dimensions[$k].ToString().Replace("'","''")) }
      if ($pairs.Count) { $args.Filter = ($pairs -join ' and ') }
    }

    $m = Get-AzMetric @args
    if (-not $m) { return 0.0 }

    $series = @(); foreach ($md in $m) { $series += $md.Timeseries }
    if (-not $series) { $series = $m.Timeseries }
    $points = @(); foreach ($ts in $series) { $points += $ts.Data }
    if (-not $points) { $points = $m.Data }

    $val = $points | Where-Object { $_.$AggregationType -ne $null } | Select-Object -Last 1
    if ($val) { return [double]$val.$AggregationType } else { return 0.0 }
  } catch { return 0.0 }
}

# ===== Azure Files per-share usage with daily/MAX and robust fallbacks =====
function Get-FileShareUsedBytes {
  param(
    [Parameter(Mandatory)][string]$StorageAccountId,
    [Parameter(Mandatory)][string]$ShareName,
    $Context
  )
  $rid = "$StorageAccountId/fileServices/default"
  $ns  = 'Microsoft.Storage/storageAccounts/fileServices'

  # 1) daily/MAX filtered by ShareName (exact case)
  $flt = "ShareName eq '$ShareName'"
  $bytes = Get-MetricBytes -ResourceId $rid -MetricName 'FileCapacity' -MetricNamespace $ns `
           -AggregationType Maximum -TimeGrain ([TimeSpan]::Parse('1.00:00:00')) -Days 3 -Filter $flt
  if ($bytes -gt 0) { return $bytes }

  # 2) try lowercased value
  $flt2 = "ShareName eq '$($ShareName.ToLower())'"
  $bytes = Get-MetricBytes -ResourceId $rid -MetricName 'FileCapacity' -MetricNamespace $ns `
           -AggregationType Maximum -TimeGrain ([TimeSpan]::Parse('1.00:00:00')) -Days 3 -Filter $flt2
  if ($bytes -gt 0) { return $bytes }

  # 3) hourly/AVG fallback
  $bytes = Get-MetricBytes -ResourceId $rid -MetricName 'FileCapacity' -MetricNamespace $ns `
           -AggregationType Average -TimeGrain ([TimeSpan]::Parse('01:00:00')) -Days 2 -Filter $flt
  if ($bytes -gt 0) { return $bytes }

  # 4) data-plane fallback
  try {
    if ($Context) {
      $sh = Get-AzStorageShare -Context $Context -Name $ShareName -ErrorAction SilentlyContinue
      if ($sh) {
        $stats = Get-AzStorageShareStats -Share $sh -Context $Context -ErrorAction SilentlyContinue
        if ($stats -and $stats.Usage) { return [double]$stats.Usage }
      }
    }
  } catch {}

  return 0.0
}

#----------------------------
# Init
#----------------------------
Test-RequiredModules
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Collections
$AllVMs                = New-List
$AllManagedDisks       = New-List
$AllSQLDatabases       = New-List
$AllSQLManagedInstances= New-List
$AllStorageAccounts    = New-List
$AllBlobContainers     = New-List
$AllFileShares         = New-List
$AllCosmosDBAccounts   = New-List
$AllDataLakeGen2       = New-List
$AllMariaDBServers     = New-List
$AllMySQLServers       = New-List
$AllPostgreSQLServers  = New-List
$AllTableStorage       = New-List
$AllOracleDBs          = New-List
$AllBackupVaults       = New-List
$AllBackupPolicies     = New-List
$AllBackupItems        = New-List
$AllNetAppVolumes      = New-List

$Aggregates = @{}
$TotalsByApp = @{}

function Bump-AppTotals {
  param([string]$App,[int]$Count,[double]$Bytes)
  if (-not $TotalsByApp.ContainsKey($App)) {
    $TotalsByApp[$App] = [pscustomobject]@{ App=$App; Count=[int]0; Bytes=[double]0.0 }
  }
  $TotalsByApp[$App].Count = [int]$TotalsByApp[$App].Count + [int]$Count
  $TotalsByApp[$App].Bytes = [double]$TotalsByApp[$App].Bytes + [double]$Bytes
}

#----------------------------
# Optional module handling (Oracle, NetApp)
#----------------------------
$AzOracleAvailable = $false
if (-not $SkipOracleDatabase) {
  $AzOracleAvailable = [bool](Get-Module -ListAvailable -Name Az.Oracle -ErrorAction SilentlyContinue)
  if (-not $AzOracleAvailable) {
    if ($AutoInstallModules -or $PromptInstallOracle) {
      $install = $true
      if (-not $AutoInstallModules -and $PromptInstallOracle) { $install = (Read-Host "[PROMPT] Az.Oracle not found. Install now? (Y/N)") -match '^[Yy]' }
      if ($install) {
        try { Write-Host "[INFO] Installing Az.Oracle..." -ForegroundColor Yellow; Install-Module -Name Az.Oracle -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop; $AzOracleAvailable = $true; Write-Host "[INFO] Az.Oracle installed." -ForegroundColor Green } catch { Write-Host "[WARN] Failed to install Az.Oracle: $_. Skipping Oracle@Azure." -ForegroundColor Yellow }
      } else { Write-Host "[INFO] Skipping Az.Oracle; Oracle@Azure will be skipped." -ForegroundColor Yellow }
    } else {
      Write-Host "[INFO] Az.Oracle not installed; Oracle@Azure will be skipped. Use -PromptInstallOracle or -AutoInstallModules." -ForegroundColor Yellow
    }
  }
}

$AzNetAppAvailable = $false
if (-not $SkipAzureNetAppFiles) {
  $AzNetAppAvailable = [bool](Get-Module -ListAvailable -Name Az.NetAppFiles -ErrorAction SilentlyContinue)
  if (-not $AzNetAppAvailable) {
    if ($AutoInstallModules -or $PromptInstallNetApp) {
      $install = $true
      if (-not $AutoInstallModules -and $PromptInstallNetApp) { $install = (Read-Host "[PROMPT] Az.NetAppFiles not found. Install now? (Y/N)") -match '^[Yy]' }
      if ($install) {
        try { Write-Host "[INFO] Installing Az.NetAppFiles..." -ForegroundColor Yellow; Install-Module -Name Az.NetAppFiles -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop; $AzNetAppAvailable = $true; Write-Host "[INFO] Az.NetAppFiles installed." -ForegroundColor Green } catch { Write-Host "[WARN] Failed to install Az.NetAppFiles: $_. Skipping ANF." -ForegroundColor Yellow }
      } else { Write-Host "[INFO] Skipping Az.NetAppFiles; ANF will be skipped." -ForegroundColor Yellow }
    } else {
      Write-Host "[INFO] Az.NetAppFiles not installed; ANF will be skipped. Use -PromptInstallNetApp or -AutoInstallModules." -ForegroundColor Yellow
    }
  }
}

#----------------------------
# Target subscriptions
#----------------------------
Write-Host "[INFO] Checking Azure connection..." -ForegroundColor Green
$ctx = Get-AzContext
if (-not $ctx) { Write-Host "Not connected. Run Connect-AzAccount." -ForegroundColor Red; exit 1 }
Write-Host "[INFO] Connected as: $($ctx.Account.Id)" -ForegroundColor Green

function Get-TargetSubscriptions {
  $target=@()
  if ($CurrentSubscription) {
    $c = Get-AzContext
    $target += Get-AzSubscription -SubscriptionId $c.Subscription.Id
  } elseif ($Subscriptions) {
    foreach ($s in $Subscriptions) {
      $sub = Get-AzSubscription -SubscriptionName $s -ErrorAction SilentlyContinue
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
    Add-ListItem -List $AllVMs -Item ([pscustomobject]@{
      SubscriptionId=$SubId
      ResourceGroup=(Anon-RG $vm.ResourceGroupName)
      Name=(Anon-Obj $vm.Name 'vm-')
      Location=$loc
      VmSize=$vm.HardwareProfile.VmSize
    })
    Add-Aggregate -Map $Aggregates -App 'Azure VM' -Region $loc -SizeBytes 0.0
  }
  $disks = Get-AzDisk -ErrorAction SilentlyContinue
  foreach ($d in $disks) {
    $loc = Normalize-Location $d.Location
    $sizeBytes = To-BytesFromGB $d.DiskSizeGB
    $attached = 'Unattached'
    if ($d.ManagedBy) { $vmName = Split-Path $d.ManagedBy -Leaf; $attached = Anon-Obj $vmName 'vm-' }
    Add-ListItem -List $AllManagedDisks -Item ([pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=(Anon-RG $d.ResourceGroupName); Name=(Anon-Obj $d.Name 'disk-'); Location=$loc;
      Sku=$d.Sku.Name; DiskSizeGB=$d.DiskSizeGB; AttachedTo=$attached
    })
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
      Add-ListItem -List $AllSQLDatabases -Item ([pscustomobject]@{
        SubscriptionId=$SubId; ResourceGroup=(Anon-RG $db.ResourceGroupName); ServerName=(Anon-Obj $s.ServerName 'sqldb-');
        DatabaseName=(Anon-Obj $db.DatabaseName 'db-'); Location=$loc; MaxSizeBytes=$db.MaxSizeBytes
      })
      Add-Aggregate -Map $Aggregates -App 'Azure SQL DB' -Region $loc -SizeBytes $sizeBytes
    }
  }
  $mis = Get-AzSqlInstance -ErrorAction SilentlyContinue
  foreach ($mi in $mis) {
    $loc = Normalize-Location $mi.Location
    $sizeBytes = To-BytesFromGB ($mi.StorageSizeInGB)
    Add-ListItem -List $AllSQLManagedInstances -Item ([pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=(Anon-RG $mi.ResourceGroupName); Name=(Anon-Obj $mi.ManagedInstanceName 'sqlmi-');
      Location=$loc; StorageSizeInGB=$mi.StorageSizeInGB
    })
    Add-Aggregate -Map $Aggregates -App 'SQL Managed Instance' -Region $loc -SizeBytes $sizeBytes
  }
}

function Collect-Storage {
  param($SubId)
  Write-Host "  [Storage] $SubId" -ForegroundColor Cyan
  $sas = Get-AzStorageAccount -ErrorAction SilentlyContinue
  foreach ($sa in $sas) {
    $loc = Normalize-Location $sa.Location
    $acctBytes = Get-MetricBytes -ResourceId $sa.Id -MetricName 'UsedCapacity' -MetricNamespace 'Microsoft.Storage/storageAccounts' -Days 2

    # Always collect detail row for the storage account
    Add-ListItem -List $AllStorageAccounts -Item ([pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=(Anon-RG $sa.ResourceGroupName); StorageAccountName=(Anon-Obj $sa.StorageAccountName 'stg-');
      Location=$loc; Kind=$sa.Kind; Sku=$sa.Sku.Name; UsedBytes=$acctBytes; Hns=$sa.EnableHierarchicalNamespace
    })

    # Aggregation behavior:
    if ($AggregateStorageAtAccountLevel) {
      Add-Aggregate -Map $Aggregates -App 'Storage Account' -Region $loc -SizeBytes $acctBytes
      continue
    }

    # ADLS Gen2: detail only
    if ($sa.EnableHierarchicalNamespace) {
      Add-ListItem -List $AllDataLakeGen2 -Item ([pscustomobject]@{
        SubscriptionId=$SubId; ResourceGroup=(Anon-RG $sa.ResourceGroupName); StorageAccountName=(Anon-Obj $sa.StorageAccountName 'stg-');
        Location=$loc; UsedBytes=$acctBytes
      })
    }

    try {
      $ctx = $sa.Context

      # Azure Files (per share)
      $shares = Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue
      foreach ($sh in $shares) {
        $usageBytes = Get-FileShareUsedBytes -StorageAccountId $sa.Id -ShareName $sh.Name -Context $ctx
        Add-ListItem -List $AllFileShares -Item ([pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=(Anon-RG $sa.ResourceGroupName); StorageAccountName=(Anon-Obj $sa.StorageAccountName 'stg-');
          ShareName=(Anon-Obj $sh.Name 'share-'); Location=$loc; UsedBytes=$usageBytes
        })
        Add-Aggregate -Map $Aggregates -App 'Azure Files' -Region $loc -SizeBytes $usageBytes
      }

      # Table Storage (service metric)
      $tableSvcId = "$($sa.Id)/tableServices/default"
      $tableBytes = Get-MetricBytes -ResourceId $tableSvcId -MetricName 'TableCapacity' -MetricNamespace 'Microsoft.Storage/storageAccounts/tableServices' -Days 2
      if ($tableBytes -gt 0) {
        Add-ListItem -List $AllTableStorage -Item ([pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=(Anon-RG $sa.ResourceGroupName); StorageAccountName=(Anon-Obj $sa.StorageAccountName 'stg-');
          Location=$loc; UsedBytes=$tableBytes
        })
        Add-Aggregate -Map $Aggregates -App 'Table Storage' -Region $loc -SizeBytes $tableBytes
      }

      # Blob containers (optional heavy)
      if ($GetContainerDetails) {
        $containers = Get-AzStorageContainer -Context $ctx -ErrorAction SilentlyContinue
        foreach ($c in $containers) {
          $sumBytes = 0.0
          try {
            $blobs = Get-AzStorageBlob -Container $c.Name -Context $ctx -ErrorAction SilentlyContinue
            if ($blobs) { $sumBytes = ($blobs | Measure-Object -Property Length -Sum).Sum }
          } catch {}
          Add-ListItem -List $AllBlobContainers -Item ([pscustomobject]@{
            SubscriptionId=$SubId; ResourceGroup=(Anon-RG $sa.ResourceGroupName); StorageAccountName=(Anon-Obj $sa.StorageAccountName 'stg-');
            ContainerName=(Anon-Obj $c.Name 'cont-'); Location=$loc; UsedBytes=$sumBytes
          })
          Add-Aggregate -Map $Aggregates -App 'Blob Container' -Region $loc -SizeBytes $sumBytes
        }
      }
    } catch {
      Write-Host "    [WARN] Could not access storage context for $($sa.StorageAccountName)" -ForegroundColor Yellow
    }
  }
}

function Get-ResourcesViaGraph { param([string]$ResourceType,[string]$SubscriptionId) $q="Resources | where type =~ '$ResourceType' and subscriptionId == '$SubscriptionId'"; try { Search-AzGraph -Query $q -ErrorAction SilentlyContinue } catch { @() } }

function Collect-Cosmos {
  param($SubId)
  Write-Host "  [Cosmos DB] $SubId" -ForegroundColor Cyan
  $cosmos = Get-ResourcesViaGraph -ResourceType "microsoft.documentdb/databaseaccounts" -SubscriptionId $SubId
  foreach ($c in $cosmos) {
    $loc = Normalize-Location $c.location
    $rid = "/subscriptions/$SubId/resourceGroups/$($c.resourceGroup)/providers/Microsoft.DocumentDB/databaseAccounts/$($c.name)"
    $data = Get-MetricBytes -ResourceId $rid -MetricName 'DataUsage'  -MetricNamespace 'Microsoft.DocumentDB/databaseAccounts' -Days 2
    $index= Get-MetricBytes -ResourceId $rid -MetricName 'IndexUsage' -MetricNamespace 'Microsoft.DocumentDB/databaseAccounts' -Days 2
    $used = [double]$data + [double]$index
    Add-ListItem -List $AllCosmosDBAccounts -Item ([pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=(Anon-RG $c.resourceGroup); AccountName=(Anon-Obj $c.name 'cosmos-'); Location=$loc; UsedBytes=$used
    })
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
        Add-ListItem -List $AllMariaDBServers -Item ([pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=(Anon-RG $s.ResourceGroupName); ServerName=(Anon-Obj $s.Name 'maria-'); Location=$loc; UsedBytes=$bytes
        })
        Add-Aggregate -Map $Aggregates -App 'MariaDB' -Region $loc -SizeBytes $bytes
      }
    } catch {}
    try {
      $mysql = Get-AzMySqlServer -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($s in $mysql) {
        $loc = Normalize-Location $s.Location
        $bytes = [double]$s.StorageProfile.StorageMB * 1MB
        Add-ListItem -List $AllMySQLServers -Item ([pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=(Anon-RG $s.ResourceGroupName); ServerName=(Anon-Obj $s.Name 'mysql-'); Location=$loc; UsedBytes=$bytes
        })
        Add-Aggregate -Map $Aggregates -App 'MySQL' -Region $loc -SizeBytes $bytes
      }
    } catch {}
    try {
      $pg = Get-AzPostgreSqlServer -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($s in $pg) {
        $loc = Normalize-Location $s.Location
        $bytes = [double]$s.StorageProfile.StorageMB * 1MB
        Add-ListItem -List $AllPostgreSQLServers -Item ([pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=(Anon-RG $s.ResourceGroupName); ServerName=(Anon-Obj $s.Name 'pg-'); Location=$loc; UsedBytes=$bytes
        })
        Add-Aggregate -Map $Aggregates -App 'PostgreSQL' -Region $loc -SizeBytes $bytes
      }
    } catch {}
  }
}

function Collect-Oracle {
  param($SubId)
  if ($SkipOracleDatabase) { return }
  if (-not $AzOracleAvailable) { return }
  Write-Host "  [Oracle] $SubId" -ForegroundColor Cyan
  try { Import-Module Az.Oracle -ErrorAction Stop } catch { Write-Host "    [WARN] Could not import Az.Oracle; skipping." -ForegroundColor Yellow; return }
  $rgs = Get-AzResourceGroup -ErrorAction SilentlyContinue
  foreach ($rg in $rgs) {
    try {
      $adbs = Get-AzOracleAutonomousDatabase -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($db in $adbs) {
        $loc = Normalize-Location $db.Location
        $bytes = [double]$db.DataStorageSizeInTBs * 1TB
        Add-ListItem -List $AllOracleDBs -Item ([pscustomobject]@{
          SubscriptionId=$SubId; ResourceGroup=(Anon-RG $rg.ResourceGroupName); Name=(Anon-Obj $db.Name 'oracle-'); Location=$loc; UsedBytes=$bytes
        })
        Add-Aggregate -Map $Aggregates -App 'Oracle@Azure' -Region $loc -SizeBytes $bytes
      }
    } catch {}
  }
}

function Collect-NetAppFiles {
  param($SubId)
  if ($SkipAzureNetAppFiles) { return }
  if (-not $AzNetAppAvailable) { return }
  Write-Host "  [Azure NetApp Files] $SubId" -ForegroundColor Cyan
  try { Import-Module Az.NetAppFiles -ErrorAction Stop } catch { Write-Host "    [WARN] Could not import Az.NetAppFiles; skipping." -ForegroundColor Yellow; return }
  $rgs = Get-AzResourceGroup -ErrorAction SilentlyContinue
  foreach ($rg in $rgs) {
    try {
      $accounts = Get-AzNetAppFilesAccount -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($acct in $accounts) {
        $pools = Get-AzNetAppFilesCapacityPool -ResourceGroupName $rg.ResourceGroupName -AccountName $acct.Name -ErrorAction SilentlyContinue
        foreach ($pool in $pools) {
          $vols = Get-AzNetAppFilesVolume -ResourceGroupName $rg.ResourceGroupName -AccountName $acct.Name -PoolName $pool.Name -ErrorAction SilentlyContinue
          foreach ($v in $vols) {
            # PS 5/7 compatible coalesce of volume location -> account location
            $volLoc = $v.Location
            if ([string]::IsNullOrWhiteSpace($volLoc)) { $volLoc = $acct.Location }
            $loc = Normalize-Location $volLoc

            # UsageThreshold is provisioned quota (bytes)
            $bytes = [double]$v.UsageThreshold
            Add-ListItem -List $AllNetAppVolumes -Item ([pscustomobject]@{
              SubscriptionId=$SubId; ResourceGroup=(Anon-RG $rg.ResourceGroupName); Account=(Anon-Obj $acct.Name 'anfacct-');
              CapacityPool=(Anon-Obj $pool.Name 'anfpool-'); Volume=(Anon-Obj $v.Name 'anfvol-'); Protocol=($v.ProtocolTypes -join ',');
              Location=$loc; QuotaBytes=$bytes
            })
            Add-Aggregate -Map $Aggregates -App 'Azure NetApp Files' -Region $loc -SizeBytes $bytes
          }
        }
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
    Add-ListItem -List $AllBackupVaults -Item ([pscustomobject]@{
      SubscriptionId=$SubId; ResourceGroup=(Anon-RG $v.ResourceGroupName); VaultName=(Anon-Obj $v.Name 'vault-'); Location=$loc
    })
    try {
      Set-AzRecoveryServicesVaultContext -Vault $v -ErrorAction SilentlyContinue
      $pol = Get-AzRecoveryServicesBackupProtectionPolicy -ErrorAction SilentlyContinue
      foreach ($p in $pol) {
        Add-ListItem -List $AllBackupPolicies -Item ([pscustomobject]@{
          SubscriptionId=$SubId; VaultName=(Anon-Obj $v.Name 'vault-'); PolicyName=(Anon-Obj $p.Name 'policy-');
          WorkloadType=$p.WorkloadType; BackupManagementType=$p.BackupManagementType
        })
      }
      $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -ErrorAction SilentlyContinue
      foreach ($c in $containers) {
        $items = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -ErrorAction SilentlyContinue
        foreach ($i in $items) {
          Add-ListItem -List $AllBackupItems -Item ([pscustomobject]@{
            SubscriptionId=$SubId; VaultName=(Anon-Obj $v.Name 'vault-'); ItemName=(Anon-Obj $i.Name 'bkpitem-');
            ProtectionState=$i.ProtectionState; LastBackupTime=$i.LastBackupTime
          })
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

  if (-not $SkipAzureVMandManagedDisks)     { Collect-VMs-And-Disks -SubId $sub.Id }
  if (-not $SkipAzureSQLandManagedInstances){ Collect-SQL -SubId $sub.Id }
  if (-not $SkipAzureStorageAccounts)       { Collect-Storage -SubId $sub.Id }
  if (-not $SkipAzureCosmosDB)              { Collect-Cosmos -SubId $sub.Id }
  if (-not $SkipAzureDatabaseServices)      { Collect-PaaS-DBs -SubId $sub.Id }
  if (-not $SkipOracleDatabase)             { Collect-Oracle -SubId $sub.Id }
  if (-not $SkipAzureNetAppFiles)           { Collect-NetAppFiles -SubId $sub.Id }
  if (-not $SkipAzureBackup)                { Collect-Backup -SubId $sub.Id }
}

#----------------------------
# Build summaries
#----------------------------
foreach ($kv in $Aggregates.GetEnumerator()) { $rec = $kv.Value; Bump-AppTotals -App $rec.App -Count $rec.Count -Bytes $rec.Bytes }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory | Out-Null }

# Per-app totals
$byApp = foreach ($v in ($TotalsByApp.Values | Sort-Object App)) {
  $conv = Convert-Bytes $v.Bytes
  [pscustomobject]@{ App=$v.App; Count=$v.Count; Size_GiB=$conv.GiB; Size_TiB=$conv.TiB }
}
$byAppFile = Join-Path $OutputPath "azure_sizing_by_app_$timestamp.csv"
$byApp | Export-Csv -Path $byAppFile -NoTypeInformation

# Per-region per-app
$byRegionApp = foreach ($v in ($Aggregates.Values | Sort-Object Region,App)) {
  $conv = Convert-Bytes $v.Bytes
  [pscustomobject]@{ Region=$v.Region; App=$v.App; Count=$v.Count; Size_GiB=$conv.GiB; Size_TiB=$conv.TiB }
}
$byRegionFile = Join-Path $OutputPath "azure_sizing_by_region_$timestamp.csv"
$byRegionApp | Export-Csv -Path $byRegionFile -NoTypeInformation

# Pivot for HTML: Capacity by Region & App (TiB)
$pivotRows = @()
$regions = $byRegionApp | Select-Object -ExpandProperty Region -Unique | Sort-Object
$apps    = $byRegionApp | Select-Object -ExpandProperty App    -Unique | Sort-Object
foreach ($r in $regions) {
  $row = [ordered]@{ Region = $r }
  foreach ($a in $apps) {
    $val = ($byRegionApp | Where-Object { $_.Region -eq $r -and $_.App -eq $a } | Select-Object -ExpandProperty Size_TiB -ErrorAction SilentlyContinue)
    if (-not $val) { $row[$a] = 0 } else { $row[$a] = [math]::Round(($val | Measure-Object -Sum).Sum, 3) }
  }
  $pivotRows += [pscustomobject]$row
}
$pivotHtml = $pivotRows | ConvertTo-Html -Fragment

# Raw detail CSVs
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
if ($AllNetAppVolumes.Count)      { $AllNetAppVolumes      | Export-Csv (Join-Path $OutputPath "azure_netapp_volumes_$timestamp.csv") -NoTypeInformation }

# HTML Summary
$css = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin:20px; }
h1 { color:#0b6aa2; } h2 { color:#0b6aa2; margin-top:30px; }
table { border-collapse: collapse; width: 100%; margin: 10px 0 30px 0; }
th, td { border: 1px solid #ddd; padding: 8px; } th { background: #e6f2f9; text-align: left; }
tr:nth-child(even) { background: #fafafa; }
.badge { display:inline-block; padding:4px 8px; background:#0b6aa2; color:#fff; border-radius:4px; font-size:12px; }
.note { color:#666; font-size:12px; }
</style>
"@
$totalGiB = [math]::Round(($TotalsByApp.Values | Measure-Object -Property Bytes -Sum).Sum / 1GB, 2)
$totalTiB = [math]::Round(($TotalsByApp.Values | Measure-Object -Property Bytes -Sum).Sum / 1TB, 3)
$byAppHtml = $byApp | ConvertTo-Html -Property App,Count,Size_GiB,Size_TiB -Fragment

# PowerShell 5.x compatibility: avoid ternary operator in the HTML
$aggLevel = if ($AggregateStorageAtAccountLevel) { 'account' } else { 'service' }

$byRegionApp = Import-Csv $byRegionFile
$pivotRows = @()
$regions = $byRegionApp | Select-Object -ExpandProperty Region -Unique | Sort-Object
$apps    = $byRegionApp | Select-Object -ExpandProperty App    -Unique | Sort-Object
foreach ($r in $regions) {
  $row = [ordered]@{ Region = $r }
  foreach ($a in $apps) {
    $val = ($byRegionApp | Where-Object { $_.Region -eq $r -and $_.App -eq $a } | Select-Object -ExpandProperty Size_TiB -ErrorAction SilentlyContinue)
    if (-not $val) { $row[$a] = 0 } else { $row[$a] = [math]::Round(($val | Measure-Object -Sum).Sum, 3) }
  }
  $pivotRows += [pscustomobject]$row
}
$pivotHtml = $pivotRows | ConvertTo-Html -Fragment

$topRegions = ($byRegionApp | Group-Object Region | ForEach-Object {
  [pscustomobject]@{
    Region = $_.Name
    Resources = ($_.Group | Measure-Object -Property Count -Sum).Sum
    TiB = [math]::Round(($_.Group | Measure-Object -Property Size_TiB -Sum).Sum, 3)
  }
} | Sort-Object TiB -Descending | Select-Object -First 10)
$topRegionsHtml = $topRegions | ConvertTo-Html -Property Region,Resources,TiB -Fragment

$report = @"
<html><head><meta charset="utf-8"><title>Azure Sizing Report</title>$css</head>
<body>
<h1>Commvault Azure Sizing Report <span class="badge">v$ScriptVersion</span></h1>
<p>Generated: $(Get-Date)</p>
<h2>Totals by App</h2>
$byAppHtml
<p class="note">Sizes shown in GiB/TiB (1024-based). Storage is aggregated at the <strong>$aggLevel</strong> level to avoid double counting.</p>
<h2>Top Regions by Total Capacity</h2>
$topRegionsHtml
<h2>Capacity by Region & App (TiB)</h2>
$pivotHtml
</body></html>
"@
$reportFile = Join-Path $OutputPath "azure_sizing_report_$timestamp.html"
$report | Out-File -FilePath $reportFile -Encoding UTF8

# Console summary
Write-Host "`n================ WORKLOAD TOTALS ================" -ForegroundColor Cyan
$byApp | Format-Table -AutoSize
Write-Host "`n================ TOP REGIONS (by TiB) ================" -ForegroundColor Cyan
$topRegions | Format-Table -AutoSize

Write-Host "`n[INFO] Outputs"
Write-Host " - $byAppFile"
Write-Host " - $byRegionFile"
Write-Host " - $reportFile"
Write-Host " - Raw CSVs for each service in $OutputPath"
Write-Host "`n[DONE] Azure sizing complete - Share full outputs with Commvault." -ForegroundColor Green
