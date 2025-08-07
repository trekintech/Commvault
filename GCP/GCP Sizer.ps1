#requires -Version 7.0
#requires -Modules GoogleCloud

<#
.SYNOPSIS
Gets all GCE VMs, GCE Disks, CloudSQL, Spanner, BigQuery, GKE, and GCS usage info.

.DESCRIPTION
The 'Get-GCPWorkloadSizingInfo.ps1' script gets all GCE VMs (and attached/unattached disks),
CloudSQL instances, Spanner instances, BigQuery datasets, GKE clusters, and GCS buckets
in the specified projects.  For each workload it captures counts, total storage usage,
encryption and labels, and exports CSVs plus a ZIP for analysis.

.NOTES
Written for extended GCP workload inventory
#>

[CmdletBinding(DefaultParameterSetName = 'GetAllProjects')]
param (
  [Parameter(ParameterSetName='GetAllProjects', Mandatory=$false)]
  [switch]$GetAllProjects,

  [Parameter(ParameterSetName='Projects', Mandatory=$true)]
  [string]$Projects,

  [Parameter(ParameterSetName='ProjectFile', Mandatory=$true)]
  [string]$ProjectFile,

  [Parameter(Mandatory=$false)]
  [switch]$Anonymize,

  [Parameter(Mandatory=$false)]
  [string]$AnonymizeFields,

  [Parameter(Mandatory=$false)]
  [string]$NotAnonymizeFields
)

# Preserve/restore culture for consistent CSV formatting
$CurrentCulture = [System.Globalization.CultureInfo]::CurrentCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'

try {
  $date_string = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
  $output_log = "output_gcp_$date_string.log"
  if (Test-Path "./$output_log") { Remove-Item "./$output_log" }

  if ($Anonymize) {
    "Anonymized file; customer has original." > $output_log
    $log_for_anon_customers = "output_gcp_not_anonymized_$date_string.log"
    Start-Transcript -Path "./$log_for_anon_customers"
  } else {
    Start-Transcript -Path "./$output_log"
  }

  Write-Host "Arguments passed:" -ForegroundColor Green
  $PSBoundParameters | Format-Table

  # Prepare output filenames
  $outputVM                = "gce_vm_info-$date_string.csv"
  $outputAttachedDisks     = "gce_attached_disk_info-$date_string.csv"
  $outputUnattachedDisks   = "gce_unattached_disk_info-$date_string.csv"
  $outputCloudSql          = "gcp_cloudsql_info-$date_string.csv"
  $outputSpanner           = "gcp_spanner_info-$date_string.csv"
  $outputBigQuery          = "gcp_bigquery_info-$date_string.csv"
  $outputGKE               = "gcp_gke_info-$date_string.csv"
  $outputGCS               = "gcp_gcs_info-$date_string.csv"
  $archiveFile             = "gcp_sizing_results_$date_string.zip"

  $outputFiles = @(
    $outputVM, $outputAttachedDisks, $outputUnattachedDisks,
    $outputCloudSql, $outputSpanner, $outputBigQuery,
    $outputGKE, $outputGCS, $output_log
  )

  # Build project list
  $projectList = @()
  if ($ProjectFile) {
    foreach ($proj in Get-Content -Path $ProjectFile) {
      try { $projectList += Get-GcpProject -ProjectId $proj }
      catch { Write-Host "Failed to get project $proj: $_" -ForegroundColor Red }
    }
  } elseif ($Projects) {
    foreach ($proj in $Projects.Split(',')) {
      try { $projectList += Get-GcpProject -ProjectId $proj }
      catch { Write-Host "Failed to get project $proj: $_" -ForegroundColor Red }
    }
  } else {
    Write-Host "Discovering all accessible projects..." -ForegroundColor Green
    try { $projectList = Get-GcpProject }
    catch { Write-Host "Failed to list projects: $_" -ForegroundColor Red }
  }

  # Prepare collections
  $instanceList        = [System.Collections.ArrayList]@()
  $attachedDiskList    = [System.Collections.ArrayList]@()
  $unattachedDiskList  = [System.Collections.ArrayList]@()
  $cloudSqlList        = [System.Collections.ArrayList]@()
  $spannerList         = [System.Collections.ArrayList]@()
  $bigQueryList        = [System.Collections.ArrayList]@()
  $gkeList             = [System.Collections.ArrayList]@()
  $gcsList             = [System.Collections.ArrayList]@()

  # Loop projects
  $projCount = 0
  foreach ($projObj in $projectList) {
    $projCount++
    $projId = $projObj.ProjectId
    Write-Progress -Activity "Project $projCount of $($projectList.Count)" -Status $projId -PercentComplete (($projCount/$projectList.Count)*100)

    #
    # === GCE VMs & Disks ===
    #
    try { $instances = Get-GceInstance -Project $projId } catch { Write-Host "VM list failed for $projId: $_" -ForegroundColor Red; continue }
    foreach ($vm in $instances) {
      # Disks on this VM
      $diskCount = 0; $diskSizeGb = 0; $numEncrypted=0; $sizeEncryptedGb=0
      foreach ($d in $vm.Disks) {
        $info = Get-GceDisk -Project $projId -DiskName ($d.Source.Split('/')[-1])
        $diskCount++; $diskSizeGb += $info.SizeGb
        if ($info.DiskEncryptionKey) { $numEncrypted++; $sizeEncryptedGb += $info.SizeGb }

        $obj = [PSCustomObject]@{
          Project                = $projId
          Zone                   = $info.Zone.Split('/')[-1]
          VMName                 = $vm.Name
          DiskName               = $info.Name
          SizeGb                 = $info.SizeGb
          SizeTb                 = [math]::Round($info.SizeGb/1000,3)
          DiskEncryptionKey      = $info.DiskEncryptionKey
          SourceImage            = if ($info.SourceImage) { $info.SourceImage.Split('/')[-1] } else { $null }
        }
        # Labels
        foreach ($k in $info.Labels.Keys) {
          $v = $info.Labels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $attachedDiskList.Add($obj) | Out-Null
      }
      $instObj = [PSCustomObject]@{
        Project              = $projId
        Zone                 = $vm.Zone.Split('/')[-1]
        Name                 = $vm.Name
        TotalDiskCount       = $diskCount
        TotalDiskSizeGb      = $diskSizeGb
        TotalDiskSizeTb      = [math]::Round($diskSizeGb/1000,3)
        EncryptedDisksCount  = $numEncrypted
        EncryptedDisksSizeGb = $sizeEncryptedGb
        EncryptedDisksSizeTb = [math]::Round($sizeEncryptedGb/1000,3)
        Status               = $vm.Status
      }
      foreach ($k in $vm.Labels.Keys) {
        $v = $vm.Labels[$k]
        $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
        $instObj | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
      }
      $instanceList.Add($instObj) | Out-Null

      # Unattached disks come later
    }

    # Unattached disks
    try { $allDisks = Get-GceDisk -Project $projId } catch { Write-Host "Disk list failed for $projId: $_" -ForegroundColor Red }
    foreach ($d in $allDisks) {
      if (-not $d.Users) {
        $obj = [PSCustomObject]@{
          Project           = $projId
          Zone              = $d.Zone.Split('/')[-1]
          DiskName          = $d.Name
          SizeGb            = $d.SizeGb
          SizeTb            = [math]::Round($d.SizeGb/1000,3)
          DiskEncryptionKey = $d.DiskEncryptionKey
          SourceImage       = if ($d.SourceImage) { $d.SourceImage.Split('/')[-1] } else { $null }
        }
        foreach ($k in $d.Labels.Keys) {
          $v = $d.Labels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $unattachedDiskList.Add($obj) | Out-Null
      }
    }

    #
    # === CloudSQL Instances ===
    #
    try {
      $sqls = Get-GcpSqlInstance -Project $projId
      foreach ($s in $sqls) {
        $cs = [PSCustomObject]@{
          Project         = $projId
          InstanceName    = $s.Name
          Region          = $s.Region
          Tier            = $s.Settings.Tier
          StorageSizeGb   = $s.Settings.DataDiskSizeGb
          StorageType     = $s.Settings.DataDiskType
        }
        foreach ($k in $s.Settings.UserLabels.Keys) {
          $v = $s.Settings.UserLabels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $cs | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $cloudSqlList.Add($cs) | Out-Null
      }
    } catch {
      Write-Host "CloudSQL fetch failed for $projId: $_" -ForegroundColor Yellow
    }

    #
    # === Spanner Instances ===
    #
    try {
      $sp = & gcloud spanner instances list --project $projId --format=json | ConvertFrom-Json
      foreach ($i in $sp) {
        $instId = $i.name.Split('/')[-1]
        $spi = [PSCustomObject]@{
          Project     = $projId
          InstanceId  = $instId
          Config      = $i.config.Split('/')[-1]
          NodeCount   = $i.nodeCount
        }
        foreach ($k in $i.labels.Keys) {
          $v = $i.labels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $spi | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $spannerList.Add($spi) | Out-Null
      }
    } catch {
      Write-Host "Spanner fetch failed for $projId: $_" -ForegroundColor Yellow
    }

    #
    # === BigQuery Datasets ===
    #
    try {
      $bqDatasets = & gcloud bigquery datasets list --project $projId --format=json | ConvertFrom-Json
      foreach ($ds in $bqDatasets) {
        $dsId = $ds.datasetReference.datasetId
        $tables = & gcloud bigquery tables list --dataset $dsId --project $projId --format=json | ConvertFrom-Json
        $totalBytes = 0
        foreach ($t in $tables) {
          $meta = & gcloud bigquery tables describe $t.tableReference.tableId --dataset $dsId --project $projId --format=json | ConvertFrom-Json
          $totalBytes += [int64]$meta.numBytes
        }
        $bq = [PSCustomObject]@{
          Project      = $projId
          DatasetId    = $dsId
          TableCount   = $tables.Count
          TotalSizeGb  = [math]::Round($totalBytes/1GB,3)
        }
        foreach ($k in $ds.labels.Keys) {
          $v = $ds.labels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $bq | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $bigQueryList.Add($bq) | Out-Null
      }
    } catch {
      Write-Host "BigQuery fetch failed for $projId: $_" -ForegroundColor Yellow
    }

    #
    # === GKE Clusters ===
    #
    try {
      $clusters = Get-GkeCluster -Project $projId
      foreach ($c in $clusters) {
        $poolNames = $c.NodePools.Name -join ','
        $totalNodes = ($c.NodePools | Measure-Object -Property InitialNodeCount -Sum).Sum
        $g = [PSCustomObject]@{
          Project          = $projId
          ClusterName      = $c.Name
          Location         = $c.Location
          KubernetesVersion= $c.CurrentMasterVersion
          NodePools        = $poolNames
          TotalNodeCount   = $totalNodes
        }
        foreach ($k in $c.ResourceLabels.Keys) {
          $v = $c.ResourceLabels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $g | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $gkeList.Add($g) | Out-Null
      }
    } catch {
      Write-Host "GKE fetch failed for $projId: $_" -ForegroundColor Yellow
    }

    #
    # === GCS Buckets ===
    #
    try {
      $buckets = Get-GcsBucket -Project $projId
      foreach ($b in $buckets) {
        $objs = Get-GcsObject -Bucket $b.Name
        $sumBytes = ($objs | Measure-Object -Property Size -Sum).Sum
        $gbObj = [PSCustomObject]@{
          Project       = $projId
          BucketName    = $b.Name
          Location      = $b.Location
          StorageClass  = $b.StorageClass
          ObjectCount   = $objs.Count
          TotalSizeGb   = [math]::Round($sumBytes/1GB,3)
        }
        foreach ($k in $b.Labels.Keys) {
          $v = $b.Labels[$k]
          $prop = "Label_$($k -replace '[^0-9A-Za-z]','_')"
          $gbObj | Add-Member -MemberType NoteProperty -Name $prop -Value $v -Force
        }
        $gcsList.Add($gbObj) | Out-Null
      }
    } catch {
      Write-Host "GCS fetch failed for $projId: $_" -ForegroundColor Yellow
    }

  } # end foreach project

  #
  # === Anonymization if requested ===
  #
  function addTagsToAllObjectsInList($list) {
    $allKeys = @{}
    foreach ($o in $list) {
      foreach ($p in $o.PSObject.Properties) { $allKeys[$p.Name]=1 }
    }
    $allKeys = $allKeys.Keys
    foreach ($o in $list) {
      foreach ($k in $allKeys) {
        if (-not $o.PSObject.Properties.Name.Contains($k)) {
          $o | Add-Member -NotePropertyName $k -NotePropertyValue $null -Force
        }
      }
    }
  }

  if ($Anonymize) {
    # reuse existing anonymization functions from above...
    $lists = @($instanceList, $attachedDiskList, $unattachedDiskList, $cloudSqlList, $spannerList, $bigQueryList, $gkeList, $gcsList)
    foreach ($lst in $lists) {
      addTagsToAllObjectsInList($lst)
      # then call Anonymize-Collection on each...
      $lst = Anonymize-Collection -Collection $lst
    }
  }

  #
  # === Export and Summary ===
  #
  # VMs & Disks
  $instanceList        | Export-CSV -Path $outputVM -NoTypeInformation
  $attachedDiskList    | Export-CSV -Path $outputAttachedDisks -NoTypeInformation
  $unattachedDiskList  | Export-CSV -Path $outputUnattachedDisks -NoTypeInformation

  # New workloads
  $cloudSqlList        | Export-CSV -Path $outputCloudSql -NoTypeInformation
  $spannerList         | Export-CSV -Path $outputSpanner -NoTypeInformation
  $bigQueryList        | Export-CSV -Path $outputBigQuery -NoTypeInformation
  $gkeList             | Export-CSV -Path $outputGKE -NoTypeInformation
  $gcsList             | Export-CSV -Path $outputGCS -NoTypeInformation

  # Compress
  $existing = $outputFiles | Where-Object { Test-Path $_ }
  Compress-Archive -Path $existing -DestinationPath $archiveFile

  Write-Host "`nSummary:" -ForegroundColor Green
  Write-Host "VMs: $($instanceList.Count), Attached Disks: $($attachedDiskList.Count), Unattached Disks: $($unattachedDiskList.Count)"
  Write-Host "CloudSQL Instances: $($cloudSqlList.Count)"
  Write-Host "Spanner Instances: $($spannerList.Count)"
  Write-Host "BigQuery Datasets: $($bigQueryList.Count)"
  Write-Host "GKE Clusters: $($gkeList.Count)"
  Write-Host "GCS Buckets: $($gcsList.Count)"
  Write-Host "All results in ZIP: $archiveFile" -ForegroundColor Cyan

} catch {
  Write-Error "An error occurred: $_"
} finally {
  Stop-Transcript
  [System.Threading.Thread]::CurrentThread.CurrentCulture = $CurrentCulture
  [System.Threading.Thread]::CurrentThread.CurrentUICulture = $CurrentCulture
}
