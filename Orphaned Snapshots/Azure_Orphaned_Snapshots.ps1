#requires -Version 7.0

<#
.SYNOPSIS
Reports and optionally deletes orphaned cloud-native Azure snapshots — snapshots that were NOT created by Commvault.

.DESCRIPTION
Azure managed-disk snapshots accumulate silently. They are billed as long as they exist, they are not
covered by any disk lifecycle policy, and deleting the source disk does NOT delete its snapshots. This
script finds the ones nobody owns any more and, on request, removes them.

Scope of "orphaned"
- The source managed disk no longer exists (the default, strongest signal), AND
- the snapshot is older than -MinAgeDays, AND
- no Managed Image or Azure Compute Gallery image version references it, AND
- it carries no keep-tag, and sits under no resource lock.

Optionally (-TreatOldSnapshotsAsOrphaned) snapshots whose source disk still exists but which are older
than -MaxAgeDays are flagged too. Those are reported under a separate verdict so the two cases never
get confused.

Scope of "cloud-native" (i.e. what this script deliberately leaves alone)
- Commvault-created snapshots           -> matched by name regex / tag key (see -CommvaultNamePattern, -CommvaultTagKey)
- Azure Backup-created snapshots        -> resource group matches ^AzureBackupRG_ (enhanced-policy VM backup)
- Azure Site Recovery snapshots         -> name matches ^asr[-_]
These are backup-product artefacts. Deleting them breaks recovery points, so they are classified,
reported, and excluded from deletion unless you explicitly opt them back in.

IMPORTANT — verify the Commvault detection patterns against your own environment before deleting
anything. Commvault's snapshot naming varies by agent, version and IntelliSnap configuration. Run in
report mode first, open the classification CSV, and confirm every snapshot you expect Commvault to own
is classified as "Commvault". Adjust -CommvaultNamePattern / -CommvaultTagKey until it is.

Safety model
- Report-only by default. Nothing is deleted unless -Delete is supplied.
- -Delete honours -WhatIf and -Confirm, and refuses to run unattended without -Force.
- -MaxDeletions caps a single run.
- -DeleteFromReport <csv> re-reads an approved CSV so an admin can review the report, delete the rows
  they want to keep, and feed the file back for execution. This is the recommended workflow.

Outputs (written to -OutputPath)
- Azure_Snapshots_All_<timestamp>.csv          every snapshot found, with its classification and verdict
- Azure_Snapshots_Orphaned_<timestamp>.csv     orphan candidates only (the file to feed to -DeleteFromReport)
- Azure_Snapshots_Deleted_<timestamp>.csv      deletion log, written only when -Delete runs
- Azure_Orphaned_Snapshots_<timestamp>.html    summary report

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions
Report across every subscription in the tenant. Deletes nothing.

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -Subscriptions 'Prod','Dev' -MinAgeDays 90
Report on snapshots at least 90 days old in two named subscriptions.

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -Delete -WhatIf
Show exactly what would be deleted, without deleting it.

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\Azure_Snapshots_Orphaned_20260916-101500.csv -Delete -Force
Delete precisely the snapshots left in an approved report file.
#>

[CmdletBinding(DefaultParameterSetName = 'AllSubscriptions', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
  [Parameter(ParameterSetName = 'AllSubscriptions')]
  [switch]$AllSubscriptions,

  [Parameter(ParameterSetName = 'CurrentSubscription', Mandatory = $true)]
  [switch]$CurrentSubscription,

  [Parameter(ParameterSetName = 'Subscriptions', Mandatory = $true)]
  [string[]]$Subscriptions,

  # Only consider snapshots at least this old. Guards against deleting a snapshot taken minutes ago.
  [ValidateRange(0, 3650)]
  [int]$MinAgeDays = 30,

  # With -TreatOldSnapshotsAsOrphaned, also flag snapshots older than this whose source disk still exists.
  [ValidateRange(1, 3650)]
  [int]$MaxAgeDays = 365,
  [switch]$TreatOldSnapshotsAsOrphaned,

  # Restrict to these resource groups (wildcards accepted).
  [string[]]$ResourceGroups,

  # Regex patterns identifying Commvault-created snapshots by name. Case-insensitive.
  [string[]]$CommvaultNamePattern = @(
    '^CV_',
    '^cvsnap',
    '_CvSnap',
    'commvault',
    '^GX_',
    '_GX_BACKUP_'
  ),

  # Tag keys (or tag values) identifying Commvault-created snapshots. Case-insensitive.
  [string[]]$CommvaultTagKey = @(
    'CV_JobId',
    'CommvaultJobId',
    'Commvault',
    '_GX_BACKUP_',
    '_GX_AMI_'
  ),

  # Treat Commvault snapshots as deletion candidates too. Off by default, and deliberately so.
  [switch]$IncludeCommvaultSnapshots,

  # Treat Azure Backup / Site Recovery snapshots as deletion candidates too. Strongly discouraged.
  [switch]$IncludeBackupServiceSnapshots,

  # Any snapshot carrying one of these tag keys is never a deletion candidate.
  [string[]]$KeepTagKey = @('DoNotDelete', 'KeepSnapshot', 'Preserve'),

  # Skip the Azure Compute Gallery walk (faster, but gallery-referenced snapshots will not be detected).
  [switch]$SkipGalleryCheck,

  # Snapshot storage price per GiB/month, used for the estimated-saving figure only.
  [double]$PricePerGiBMonth = 0.05,
  [string]$Currency = 'USD',

  # Execution
  [switch]$Delete,
  [switch]$Force,
  [ValidateRange(0, 100000)]
  [int]$MaxDeletions = 0,
  [string]$DeleteFromReport,

  [string]$OutputPath = ".",
  [switch]$AutoInstallModules
)

$ScriptVersion = "1.0.0"
Write-Host "`n[INFO] Azure Orphaned Snapshot Report v$ScriptVersion" -ForegroundColor Green

#----------------------------
# Module handling
#----------------------------
function Test-RequiredModules {
  $required = @('Az.Accounts', 'Az.Compute', 'Az.Resources')

  $missing = @()
  foreach ($m in $required) { if (-not (Get-Module -ListAvailable -Name $m)) { $missing += $m } }
  if ($missing.Count -gt 0) {
    if ($AutoInstallModules) {
      Write-Host "[INFO] Installing required modules: $($missing -join ', ')" -ForegroundColor Yellow
      foreach ($m in $missing) { Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber }
    } else {
      Write-Host "[ERROR] Missing required modules: $($missing -join ', ')" -ForegroundColor Red
      Write-Host "Re-run with -AutoInstallModules or install: Install-Module -Name $($missing -join ', ') -Scope CurrentUser" -ForegroundColor Yellow
      exit 1
    }
  }
}

#----------------------------
# Pure helpers (unit-testable: no Azure calls)
#----------------------------
function Test-MatchAnyPattern {
  param(
    [string]$Value,
    [string[]]$Patterns
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  foreach ($p in $Patterns) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($Value -match $p) { return $true }
  }
  return $false
}

function Test-TagMatch {
  param(
    $Tags,
    [string[]]$Patterns
  )
  if ($null -eq $Tags) { return $false }
  foreach ($key in $Tags.Keys) {
    if (Test-MatchAnyPattern -Value ([string]$key) -Patterns $Patterns) { return $true }
    if (Test-MatchAnyPattern -Value ([string]$Tags[$key]) -Patterns $Patterns) { return $true }
  }
  return $false
}

function Test-TagKeyPresent {
  param(
    $Tags,
    [string[]]$Keys
  )
  if ($null -eq $Tags) { return $false }
  foreach ($key in $Tags.Keys) {
    foreach ($k in $Keys) {
      if ([string]$key -ieq $k) { return $true }
    }
  }
  return $false
}

<#
Classifies which product created a snapshot. Returns one of:
  Commvault | AzureBackup | SiteRecovery | CloudNative
Only CloudNative snapshots are ever deletion candidates by default.
#>
function Get-AzSnapshotCreator {
  param(
    [string]$Name,
    [string]$ResourceGroupName,
    $Tags,
    [string[]]$CommvaultNamePattern,
    [string[]]$CommvaultTagKey
  )

  if (Test-MatchAnyPattern -Value $Name -Patterns $CommvaultNamePattern) { return 'Commvault' }
  if (Test-TagMatch -Tags $Tags -Patterns $CommvaultTagKey) { return 'Commvault' }

  # Azure Backup (enhanced policy) parks its VM snapshots in a managed resource group.
  if ($ResourceGroupName -match '^AzureBackupRG_') { return 'AzureBackup' }
  if ($Name -match '^AzureBackup') { return 'AzureBackup' }

  # Azure Site Recovery replication snapshots.
  if ($Name -match '^asr[-_]') { return 'SiteRecovery' }

  return 'CloudNative'
}

<#
Applies the orphan rules to one already-gathered snapshot fact set and returns the verdict plus the
reasons behind it. Kept free of Azure calls so the decision logic can be tested directly.

Verdict is one of:
  Orphaned        source disk is gone and every safety check passed
  StaleButInUse   source disk still exists but the snapshot exceeds -MaxAgeDays (-TreatOldSnapshotsAsOrphaned)
  Retain          anything else
#>
function Get-SnapshotVerdict {
  param(
    [bool]$SourceDiskExists,
    [bool]$HasSourceDiskReference,
    [double]$AgeDays,
    [bool]$ReferencedByImage,
    [bool]$HasKeepTag,
    [bool]$IsLocked,
    [string]$Creator,
    [bool]$CreatorExcluded,
    [int]$MinAgeDays,
    [int]$MaxAgeDays,
    [bool]$TreatOldSnapshotsAsOrphaned
  )

  $reasons = [System.Collections.Generic.List[string]]::new()

  if ($CreatorExcluded) {
    $reasons.Add("Created by $Creator - excluded from deletion")
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }
  if ($HasKeepTag) {
    $reasons.Add('Carries a keep-tag')
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }
  if ($IsLocked) {
    $reasons.Add('Protected by a resource lock')
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }
  if ($ReferencedByImage) {
    $reasons.Add('Referenced by a Managed Image or Gallery image version')
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }
  if ($AgeDays -lt $MinAgeDays) {
    $reasons.Add("Younger than MinAgeDays ($([math]::Round($AgeDays,1)) < $MinAgeDays)")
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }

  if (-not $HasSourceDiskReference) {
    # No source resource id at all (e.g. created by import/upload). Cannot prove the source is gone.
    $reasons.Add('No source disk reference recorded - cannot confirm orphan status')
    if ($TreatOldSnapshotsAsOrphaned -and $AgeDays -ge $MaxAgeDays) {
      $reasons.Add("Older than MaxAgeDays ($([math]::Round($AgeDays,1)) >= $MaxAgeDays)")
      return [pscustomobject]@{ Verdict = 'StaleButInUse'; Reason = ($reasons -join '; ') }
    }
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }

  if (-not $SourceDiskExists) {
    $reasons.Add('Source managed disk no longer exists')
    $reasons.Add("Age $([math]::Round($AgeDays,1)) days >= MinAgeDays $MinAgeDays")
    return [pscustomobject]@{ Verdict = 'Orphaned'; Reason = ($reasons -join '; ') }
  }

  if ($TreatOldSnapshotsAsOrphaned -and $AgeDays -ge $MaxAgeDays) {
    $reasons.Add("Source disk still exists but snapshot is older than MaxAgeDays ($([math]::Round($AgeDays,1)) >= $MaxAgeDays)")
    return [pscustomobject]@{ Verdict = 'StaleButInUse'; Reason = ($reasons -join '; ') }
  }

  $reasons.Add('Source managed disk still exists')
  return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
}

function Test-ResourceGroupFilter {
  param(
    [string]$ResourceGroupName,
    [string[]]$Filters
  )
  if (-not $Filters -or $Filters.Count -eq 0) { return $true }
  foreach ($f in $Filters) {
    if ($ResourceGroupName -like $f) { return $true }
  }
  return $false
}

#----------------------------
# Azure gathering
#----------------------------
function Get-TargetSubscriptions {
  if ($CurrentSubscription) {
    $ctx = Get-AzContext
    if (-not $ctx) { Write-Host "[ERROR] No Azure context. Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }
    return @($ctx.Subscription)
  }

  $all = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }

  if ($Subscriptions -and $Subscriptions.Count -gt 0) {
    $matched = $all | Where-Object { $_.Name -in $Subscriptions -or $_.Id -in $Subscriptions }
    $notFound = $Subscriptions | Where-Object { $_ -notin $matched.Name -and $_ -notin $matched.Id }
    foreach ($nf in $notFound) { Write-Host "[WARN] Subscription not found or not enabled: $nf" -ForegroundColor Yellow }
    return $matched
  }

  return $all
}

<#
Collects every snapshot id referenced by a Managed Image or an Azure Compute Gallery image version in
the current subscription. Such a snapshot is still doing a job even if its source disk is long gone.
#>
function Get-ImageReferencedSnapshotIds {
  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  try {
    foreach ($image in (Get-AzImage -ErrorAction Stop)) {
      $osSnap = $image.StorageProfile.OsDisk.Snapshot.Id
      if ($osSnap) { [void]$ids.Add($osSnap) }
      foreach ($dd in $image.StorageProfile.DataDisks) {
        if ($dd.Snapshot.Id) { [void]$ids.Add($dd.Snapshot.Id) }
      }
    }
  } catch {
    Write-Host "[WARN] Could not enumerate Managed Images: $($_.Exception.Message)" -ForegroundColor Yellow
  }

  if ($SkipGalleryCheck) { return $ids }

  try {
    foreach ($gallery in (Get-AzGallery -ErrorAction Stop)) {
      foreach ($definition in (Get-AzGalleryImageDefinition -ResourceGroupName $gallery.ResourceGroupName -GalleryName $gallery.Name -ErrorAction Stop)) {
        foreach ($version in (Get-AzGalleryImageVersion -ResourceGroupName $gallery.ResourceGroupName -GalleryName $gallery.Name -GalleryImageDefinitionName $definition.Name -ErrorAction Stop)) {
          $src = $version.StorageProfile.OsDiskImage.Source.Id
          if ($src) { [void]$ids.Add($src) }
          foreach ($di in $version.StorageProfile.DataDiskImages) {
            if ($di.Source.Id) { [void]$ids.Add($di.Source.Id) }
          }
        }
      }
    }
  } catch {
    Write-Host "[WARN] Could not fully enumerate Compute Galleries: $($_.Exception.Message)" -ForegroundColor Yellow
  }

  return $ids
}

function Get-LockedResourceIds {
  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  try {
    foreach ($lock in (Get-AzResourceLock -ErrorAction Stop)) {
      # A lock scoped at subscription or resource-group level also protects the snapshots beneath it.
      if ($lock.ResourceId) { [void]$ids.Add(($lock.ResourceId -replace '/providers/Microsoft\.Authorization/locks/.*$', '')) }
    }
  } catch {
    Write-Host "[WARN] Could not enumerate resource locks: $($_.Exception.Message)" -ForegroundColor Yellow
  }
  return $ids
}

function Test-IsLocked {
  param(
    [string]$SnapshotId,
    [System.Collections.Generic.HashSet[string]]$LockScopes
  )
  if ($null -eq $LockScopes -or $LockScopes.Count -eq 0) { return $false }
  foreach ($scope in $LockScopes) {
    if ([string]::IsNullOrWhiteSpace($scope)) { continue }
    if ($SnapshotId -eq $scope) { return $true }
    if ($SnapshotId.StartsWith($scope.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

#----------------------------
# Reporting
#----------------------------
function New-HtmlReport {
  param(
    [object[]]$Rows,
    [string]$Path,
    [hashtable]$Totals
  )

  $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2933; }
h1 { font-size: 22px; margin-bottom: 4px; }
h2 { font-size: 16px; margin-top: 28px; border-bottom: 2px solid #e4e7eb; padding-bottom: 6px; }
.meta { color: #616e7c; font-size: 12px; margin-bottom: 18px; }
table { border-collapse: collapse; width: 100%; font-size: 12px; margin-top: 10px; }
th { background: #f5f7fa; text-align: left; padding: 8px; border: 1px solid #e4e7eb; }
td { padding: 6px 8px; border: 1px solid #e4e7eb; vertical-align: top; }
tr:nth-child(even) td { background: #fafbfc; }
.card { display: inline-block; border: 1px solid #e4e7eb; border-radius: 6px; padding: 12px 18px; margin: 6px 10px 6px 0; min-width: 150px; }
.card .value { font-size: 20px; font-weight: 600; }
.card .label { font-size: 11px; color: #616e7c; text-transform: uppercase; letter-spacing: .04em; }
.orphan { color: #b91c1c; font-weight: 600; }
.stale { color: #b45309; font-weight: 600; }
.retain { color: #3f6212; }
.note { background: #fffbeb; border-left: 4px solid #f59e0b; padding: 10px 14px; font-size: 12px; margin-top: 18px; }
</style>
"@

  $cards = @"
<div class="card"><div class="value">$($Totals.TotalSnapshots)</div><div class="label">Snapshots scanned</div></div>
<div class="card"><div class="value">$($Totals.CloudNative)</div><div class="label">Cloud-native</div></div>
<div class="card"><div class="value">$($Totals.Commvault)</div><div class="label">Commvault (excluded)</div></div>
<div class="card"><div class="value orphan">$($Totals.Orphaned)</div><div class="label">Orphaned</div></div>
<div class="card"><div class="value">$($Totals.OrphanedGiB) GiB</div><div class="label">Reclaimable</div></div>
<div class="card"><div class="value">$($Totals.Currency) $($Totals.EstimatedMonthlySaving)</div><div class="label">Est. monthly saving</div></div>
<div class="card"><div class="value">$($Totals.Unverifiable)</div><div class="label">Unverifiable</div></div>
"@

  $candidates = $Rows | Where-Object { $_.Verdict -in @('Orphaned', 'StaleButInUse') } | Sort-Object -Property @{Expression = 'DiskSizeGB'; Descending = $true }

  $rowHtml = ($candidates | ForEach-Object {
      $cls = switch ($_.Verdict) { 'Orphaned' { 'orphan' } 'StaleButInUse' { 'stale' } default { 'retain' } }
      "<tr><td>$([System.Web.HttpUtility]::HtmlEncode($_.SubscriptionName))</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.ResourceGroupName))</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Name))</td><td>$($_.Location)</td><td>$($_.DiskSizeGB)</td><td>$($_.Incremental)</td><td>$($_.AgeDays)</td><td>$($_.Creator)</td><td class='$cls'>$($_.Verdict)</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Reason))</td></tr>"
    }) -join "`n"

  if ([string]::IsNullOrWhiteSpace($rowHtml)) {
    $rowHtml = "<tr><td colspan='10'>No orphan candidates found.</td></tr>"
  }

  $byCreator = ($Rows | Group-Object Creator | Sort-Object Count -Descending | ForEach-Object {
      $gib = [math]::Round((($_.Group | Measure-Object DiskSizeGB -Sum).Sum), 2)
      "<tr><td>$($_.Name)</td><td>$($_.Count)</td><td>$gib</td></tr>"
    }) -join "`n"

  $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Azure Orphaned Snapshots</title>$style</head>
<body>
<h1>Azure Orphaned Snapshot Report</h1>
<div class="meta">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &middot; script v$ScriptVersion &middot; MinAgeDays $MinAgeDays &middot; MaxAgeDays $MaxAgeDays &middot; mode: $(if ($Delete) { 'DELETE' } else { 'REPORT ONLY' })</div>
$cards
<h2>Snapshots by creator</h2>
<table><thead><tr><th>Creator</th><th>Count</th><th>Provisioned GiB</th></tr></thead><tbody>
$byCreator
</tbody></table>
<h2>Orphan candidates</h2>
<table><thead><tr><th>Subscription</th><th>Resource group</th><th>Snapshot</th><th>Location</th><th>GiB</th><th>Incremental</th><th>Age (days)</th><th>Creator</th><th>Verdict</th><th>Reason</th></tr></thead><tbody>
$rowHtml
</tbody></table>
<div class="note">
<strong>Before deleting:</strong> confirm that every Commvault-owned snapshot is classified as <em>Commvault</em> in the
classification CSV. Commvault snapshot naming varies by agent and IntelliSnap configuration &mdash; adjust
<code>-CommvaultNamePattern</code> and <code>-CommvaultTagKey</code> if any are misclassified as cloud-native.
Cost figures are an estimate at $($Totals.Currency) $PricePerGiBMonth per GiB/month against <em>provisioned</em> size;
incremental snapshots bill on consumed delta, so the real saving for those will be lower.
<br/><strong>Unverifiable ($($Totals.Unverifiable))</strong> are snapshots with no managed-disk source recorded
(imported blobs, snapshots of snapshots), so orphan status cannot be proven from the disk inventory. They are never
auto-deleted; use <code>-TreatOldSnapshotsAsOrphaned</code> to age them out instead.
</div>
</body></html>
"@

  $html | Out-File -FilePath $Path -Encoding utf8 -WhatIf:$false
}

#----------------------------
# Main
#----------------------------
Test-RequiredModules
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

if (-not (Get-AzContext)) {
  Write-Host "[INFO] No Azure context found. Launching Connect-AzAccount..." -ForegroundColor Yellow
  Connect-AzAccount -ErrorAction Stop | Out-Null
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$allCsv = Join-Path $OutputPath "Azure_Snapshots_All_$timestamp.csv"
$orphanCsv = Join-Path $OutputPath "Azure_Snapshots_Orphaned_$timestamp.csv"
$deletedCsv = Join-Path $OutputPath "Azure_Snapshots_Deleted_$timestamp.csv"
$htmlPath = Join-Path $OutputPath "Azure_Orphaned_Snapshots_$timestamp.html"

$results = [System.Collections.Generic.List[object]]::new()

if ($DeleteFromReport) {
  #--- Approved-report mode: trust the reviewed CSV, re-verify each snapshot still exists ---
  if (-not (Test-Path $DeleteFromReport)) {
    Write-Host "[ERROR] Report file not found: $DeleteFromReport" -ForegroundColor Red
    exit 1
  }
  Write-Host "[INFO] Loading approved deletion list from $DeleteFromReport" -ForegroundColor Cyan
  foreach ($row in (Import-Csv -Path $DeleteFromReport)) {
    $results.Add([pscustomobject]@{
        SubscriptionName  = $row.SubscriptionName
        SubscriptionId    = $row.SubscriptionId
        ResourceGroupName = $row.ResourceGroupName
        Name              = $row.Name
        Location          = $row.Location
        DiskSizeGB        = [double]($row.DiskSizeGB)
        Incremental       = $row.Incremental
        AgeDays           = $row.AgeDays
        Creator           = $row.Creator
        Verdict           = $row.Verdict
        Reason            = $row.Reason
        Id                = $row.Id
      })
  }
} else {
  #--- Discovery mode ---
  $targets = Get-TargetSubscriptions
  Write-Host "[INFO] Scanning $($targets.Count) subscription(s)" -ForegroundColor Cyan

  $subIndex = 0
  foreach ($sub in $targets) {
    $subIndex++
    Write-Progress -Activity 'Scanning subscriptions' -Status "$($sub.Name)" -PercentComplete (($subIndex / [math]::Max($targets.Count, 1)) * 100)
    Write-Host "[INFO] ($subIndex/$($targets.Count)) $($sub.Name)" -ForegroundColor Cyan

    try {
      Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
      Write-Host "[WARN] Cannot switch to subscription $($sub.Name): $($_.Exception.Message)" -ForegroundColor Yellow
      continue
    }

    try {
      $snapshots = @(Get-AzSnapshot -ErrorAction Stop)
    } catch {
      Write-Host "[WARN] Cannot list snapshots in $($sub.Name): $($_.Exception.Message)" -ForegroundColor Yellow
      continue
    }

    if ($snapshots.Count -eq 0) {
      Write-Host "[INFO]   No snapshots found." -ForegroundColor Gray
      continue
    }

    # One pass each for disks, image references and locks, rather than a call per snapshot.
    $diskIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
      foreach ($d in (Get-AzDisk -ErrorAction Stop)) { [void]$diskIds.Add($d.Id) }
    } catch {
      Write-Host "[WARN] Cannot list managed disks in $($sub.Name); orphan detection skipped here: $($_.Exception.Message)" -ForegroundColor Yellow
      continue
    }

    $imageSnapIds = Get-ImageReferencedSnapshotIds
    $lockScopes = Get-LockedResourceIds

    Write-Host "[INFO]   $($snapshots.Count) snapshot(s), $($diskIds.Count) managed disk(s), $($imageSnapIds.Count) image-referenced snapshot(s)" -ForegroundColor Gray

    foreach ($snap in $snapshots) {
      if (-not (Test-ResourceGroupFilter -ResourceGroupName $snap.ResourceGroupName -Filters $ResourceGroups)) { continue }

      $sourceId = $snap.CreationData.SourceResourceId
      $hasSourceRef = -not [string]::IsNullOrWhiteSpace($sourceId)
      # Only a managed-disk source can be checked against the disk inventory. A snapshot-of-a-snapshot
      # or an imported blob gives us nothing to verify, and is handled as "cannot confirm".
      $isDiskSource = $hasSourceRef -and ($sourceId -match '/providers/Microsoft\.Compute/disks/')
      $sourceExists = $isDiskSource -and $diskIds.Contains($sourceId)

      $creator = Get-AzSnapshotCreator -Name $snap.Name -ResourceGroupName $snap.ResourceGroupName -Tags $snap.Tags `
        -CommvaultNamePattern $CommvaultNamePattern -CommvaultTagKey $CommvaultTagKey

      $creatorExcluded = switch ($creator) {
        'Commvault' { -not $IncludeCommvaultSnapshots }
        'AzureBackup' { -not $IncludeBackupServiceSnapshots }
        'SiteRecovery' { -not $IncludeBackupServiceSnapshots }
        default { $false }
      }

      $ageDays = if ($snap.TimeCreated) { (New-TimeSpan -Start $snap.TimeCreated -End (Get-Date)).TotalDays } else { 0 }

      $verdict = Get-SnapshotVerdict `
        -SourceDiskExists $sourceExists `
        -HasSourceDiskReference $isDiskSource `
        -AgeDays $ageDays `
        -ReferencedByImage ($imageSnapIds.Contains($snap.Id)) `
        -HasKeepTag (Test-TagKeyPresent -Tags $snap.Tags -Keys $KeepTagKey) `
        -IsLocked (Test-IsLocked -SnapshotId $snap.Id -LockScopes $lockScopes) `
        -Creator $creator `
        -CreatorExcluded $creatorExcluded `
        -MinAgeDays $MinAgeDays `
        -MaxAgeDays $MaxAgeDays `
        -TreatOldSnapshotsAsOrphaned:$TreatOldSnapshotsAsOrphaned.IsPresent

      $tagString = if ($snap.Tags) { (($snap.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ') } else { '' }

      $results.Add([pscustomobject]@{
          SubscriptionName  = $sub.Name
          SubscriptionId    = $sub.Id
          ResourceGroupName = $snap.ResourceGroupName
          Name              = $snap.Name
          Location          = $snap.Location
          DiskSizeGB        = [double]$snap.DiskSizeGB
          Incremental       = [bool]$snap.Incremental
          SkuName           = $snap.Sku.Name
          TimeCreated       = $snap.TimeCreated
          AgeDays           = [math]::Round($ageDays, 1)
          SourceResourceId  = $sourceId
          SourceExists      = $sourceExists
          ReferencedByImage = $imageSnapIds.Contains($snap.Id)
          Creator           = $creator
          Verdict           = $verdict.Verdict
          Reason            = $verdict.Reason
          Tags              = $tagString
          Id                = $snap.Id
        })
    }
  }
  Write-Progress -Activity 'Scanning subscriptions' -Completed
}

#----------------------------
# Summarise
#----------------------------
$orphans = @($results | Where-Object { $_.Verdict -in @('Orphaned', 'StaleButInUse') })
$orphanGiB = [math]::Round((($orphans | Measure-Object DiskSizeGB -Sum).Sum), 2)

# Snapshots created from an imported blob or from another snapshot record no managed-disk source, so
# orphan status cannot be proven from the disk inventory alone. They are held back unless
# -TreatOldSnapshotsAsOrphaned is set; counting them here stops that category from being invisible.
$unverifiable = @($results | Where-Object { $_.Verdict -eq 'Retain' -and $_.Reason -like '*cannot confirm orphan status*' })

$totals = @{
  TotalSnapshots         = $results.Count
  CloudNative            = @($results | Where-Object { $_.Creator -eq 'CloudNative' }).Count
  Commvault              = @($results | Where-Object { $_.Creator -eq 'Commvault' }).Count
  Unverifiable           = $unverifiable.Count
  Orphaned               = $orphans.Count
  OrphanedGiB            = $orphanGiB
  EstimatedMonthlySaving = [math]::Round($orphanGiB * $PricePerGiBMonth, 2)
  Currency               = $Currency
}

if (-not $DeleteFromReport) {
  # -WhatIf:$false so a dry run still produces its reports; only the deletions are simulated.
  $results | Export-Csv -Path $allCsv -NoTypeInformation -WhatIf:$false
  Write-Host "[INFO] Full classification written to $allCsv" -ForegroundColor Green
}
$orphans | Export-Csv -Path $orphanCsv -NoTypeInformation -WhatIf:$false
New-HtmlReport -Rows $results -Path $htmlPath -Totals $totals

Write-Host ""
Write-Host "  Snapshots scanned      : $($totals.TotalSnapshots)" -ForegroundColor White
Write-Host "  Cloud-native           : $($totals.CloudNative)" -ForegroundColor White
Write-Host "  Commvault (excluded)   : $($totals.Commvault)" -ForegroundColor White
Write-Host "  Orphan candidates      : $($totals.Orphaned)" -ForegroundColor $(if ($totals.Orphaned -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Reclaimable            : $orphanGiB GiB (est. $Currency $($totals.EstimatedMonthlySaving)/month)" -ForegroundColor White
if ($unverifiable.Count -gt 0) {
  Write-Host "  Unverifiable           : $($unverifiable.Count) (no managed-disk source; add -TreatOldSnapshotsAsOrphaned to age them out)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "[INFO] Orphan list written to $orphanCsv" -ForegroundColor Green
Write-Host "[INFO] HTML report written to $htmlPath" -ForegroundColor Green

#----------------------------
# Delete
#----------------------------
if (-not $Delete) {
  if ($orphans.Count -gt 0) {
    Write-Host "`n[INFO] Report-only mode. Review $orphanCsv, remove any rows you want to keep, then re-run:" -ForegroundColor Cyan
    Write-Host "       .\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport '$orphanCsv' -Delete" -ForegroundColor Cyan
  }
  return
}

if ($orphans.Count -eq 0) {
  Write-Host "[INFO] Nothing to delete." -ForegroundColor Green
  return
}

if (-not $Force -and -not $WhatIfPreference) {
  Write-Host "`n[WARN] About to permanently delete $($orphans.Count) snapshot(s), $orphanGiB GiB." -ForegroundColor Yellow
  $answer = Read-Host "Type DELETE to proceed"
  if ($answer -cne 'DELETE') {
    Write-Host "[INFO] Aborted. Nothing was deleted." -ForegroundColor Green
    return
  }
}

# The gate above (or -Force) is the confirmation. Without this, ConfirmImpact='High' would make
# ShouldProcess raise a second Y/N prompt for every single snapshot, which also means -Force could
# never run unattended. -WhatIf is unaffected, and an explicit -Confirm still wins.
if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }

$deleteLog = [System.Collections.Generic.List[object]]::new()
$deleted = 0
$failed = 0
$currentSubId = $null

foreach ($o in ($orphans | Sort-Object SubscriptionId, ResourceGroupName, Name)) {
  if ($MaxDeletions -gt 0 -and $deleted -ge $MaxDeletions) {
    Write-Host "[INFO] MaxDeletions ($MaxDeletions) reached; stopping." -ForegroundColor Yellow
    break
  }

  if ($o.SubscriptionId -and $o.SubscriptionId -ne $currentSubId) {
    try {
      Set-AzContext -SubscriptionId $o.SubscriptionId -ErrorAction Stop | Out-Null
      $currentSubId = $o.SubscriptionId
    } catch {
      Write-Host "[WARN] Cannot switch to subscription $($o.SubscriptionId): $($_.Exception.Message)" -ForegroundColor Yellow
      continue
    }
  }

  $target = "$($o.ResourceGroupName)/$($o.Name) ($($o.DiskSizeGB) GiB)"
  if ($PSCmdlet.ShouldProcess($target, 'Remove-AzSnapshot')) {
    try {
      Remove-AzSnapshot -ResourceGroupName $o.ResourceGroupName -SnapshotName $o.Name -Force -ErrorAction Stop | Out-Null
      $deleted++
      Write-Host "[DELETED] $target" -ForegroundColor Magenta
      $deleteLog.Add([pscustomobject]@{ Timestamp = (Get-Date); SubscriptionName = $o.SubscriptionName; ResourceGroupName = $o.ResourceGroupName; Name = $o.Name; DiskSizeGB = $o.DiskSizeGB; Status = 'Deleted'; Error = '' })
    } catch {
      $failed++
      Write-Host "[ERROR] Failed to delete $target : $($_.Exception.Message)" -ForegroundColor Red
      $deleteLog.Add([pscustomobject]@{ Timestamp = (Get-Date); SubscriptionName = $o.SubscriptionName; ResourceGroupName = $o.ResourceGroupName; Name = $o.Name; DiskSizeGB = $o.DiskSizeGB; Status = 'Failed'; Error = $_.Exception.Message })
    }
  }
}

if ($deleteLog.Count -gt 0) {
  $deleteLog | Export-Csv -Path $deletedCsv -NoTypeInformation -WhatIf:$false
  Write-Host "`n[INFO] Deleted $deleted snapshot(s), $failed failure(s). Log: $deletedCsv" -ForegroundColor Green
}
