#requires -Version 7.0

<#
.SYNOPSIS
Reports every cloud-native Azure snapshot by category and age, and optionally deletes the ones you put in scope.

.DESCRIPTION
Azure managed-disk snapshots accumulate silently. They bill for as long as they exist, no lifecycle
policy expires them, and deleting the source disk does NOT delete its snapshots. This script
classifies every snapshot it can see, shows where the capacity actually sits, and removes what you
explicitly put in scope.

CATEGORIES
Each snapshot lands in exactly one, and all five are always reported:

  Orphaned      The source managed disk is provably gone. The literal orphan, and the safe case.
  SourceActive  The source disk still exists. NOT an orphan - but still billing, and usually the
                bigger number. A pre-upgrade snapshot from two years ago lives here.
  Unverifiable  No managed-disk source recorded (imported blob, snapshot of a snapshot). Orphan
                status cannot be proven either way, so a human has to look.
  InUse         Referenced by a Managed Image or Compute Gallery image version. Doing a job.
  Protected     Commvault, Azure Backup, Site Recovery, a keep-tag or a resource lock.

Category is a fact about the snapshot. ACTION is what this run would do about it:

  Delete        Its category is in -DeleteScope and it is past that category's age bar.
  Review        A candidate held back - wrong category for the current scope, or too young.
  Keep          InUse or Protected. Never actionable.

So the report reads the same whatever flags you pass; only the Action column moves.

WHAT IS EXCLUDED FROM DELETION
Commvault-created snapshots (matched on name regex and tag), plus Azure Backup (resource group
^AzureBackupRG_) and Site Recovery (name ^asr-). Those are backup-product artefacts - deleting them
breaks recovery points - so they are classified, counted and reported, never deleted.

IMPORTANT - verify the Commvault detection patterns against your own environment before deleting
anything. Commvault snapshot naming varies by agent, version and IntelliSnap configuration. Run in
report mode first, check the "By creator" table, and confirm every snapshot you expect Commvault to
own is classified as "Commvault". Adjust -CommvaultNamePattern / -CommvaultTagKey until it is.

SAFETY MODEL
- Report-only by default. Nothing is deleted without -Delete.
- -DeleteScope decides which categories -Delete may touch. Default: Orphaned only.
  Protected and InUse can never be named, and a hand-edited CSV cannot smuggle them in.
- Two age bars: -MinAgeDays for Orphaned, the much higher -SourceActiveMinAgeDays for
  SourceActive and Unverifiable.
- -Delete honours -WhatIf and -Confirm, and prompts for a typed DELETE unless -Force.
- -MaxDeletions caps a single run.
- -DeleteFromReport <csv> re-reads an approved CSV, so an admin can review the candidate list,
  delete the rows they want to keep, and feed the file back. This is the recommended workflow.

OUTPUTS (to -OutputPath)
- Azure_Snapshots_All_<ts>.csv         every snapshot, with category, age band, action and reasoning
- Azure_Snapshots_Candidates_<ts>.csv  the Action=Delete set (feed this to -DeleteFromReport)
- Azure_Snapshot_Report_<ts>.html      summary: totals, category x age heatmap, in-scope and
                                       held-for-review tables, breakdown by creator
- Azure_Snapshots_Deleted_<ts>.csv     deletion log, written only when -Delete runs

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions
Classify everything across the tenant. Deletes nothing.

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -SourceActiveMinAgeDays 540
Same report, but judge snapshots whose disk still exists against an 18-month bar.

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -DeleteScope Orphaned,SourceActive -Delete -WhatIf
Show what would go if you also reaped year-old snapshots whose disks are still live.

.EXAMPLE
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\Azure_Snapshots_Candidates_20260916-101500.csv -Delete
Delete precisely the snapshots left in an approved candidate file.
#>

[CmdletBinding(DefaultParameterSetName = 'AllSubscriptions', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
  [Parameter(ParameterSetName = 'AllSubscriptions')]
  [switch]$AllSubscriptions,

  [Parameter(ParameterSetName = 'CurrentSubscription', Mandatory = $true)]
  [switch]$CurrentSubscription,

  [Parameter(ParameterSetName = 'Subscriptions', Mandatory = $true)]
  [string[]]$Subscriptions,

  # Age bar for Orphaned snapshots - the source disk is provably gone. Guards against reaping a
  # snapshot taken minutes ago by a process that had not finished with it.
  [ValidateRange(0, 3650)]
  [int]$MinAgeDays = 30,

  # Age bar for SourceActive and Unverifiable snapshots. Deliberately much higher: the source disk
  # is alive (or unknown), so deleting one is a bigger call than reaping a true orphan.
  [ValidateRange(0, 3650)]
  [int]$SourceActiveMinAgeDays = 365,

  # Which categories -Delete may act on. Protected and InUse can never be named here.
  [ValidateSet('Orphaned', 'SourceUnattached', 'SourceActive', 'Unverifiable')]
  [string[]]$DeleteScope = @('Orphaned'),

  # Restrict to these resource groups (wildcards accepted).
  [string[]]$ResourceGroups,

  # Name markers for Commvault-created snapshots (case-insensitive regex). Commvault always writes
  # COMMVAULT into the snapshot name, as in
  #   linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462023_COMMVAULT_GXMD_SNAP_2db7ab
  # so this is a definitive marker rather than a guess. GXMD_SNAP is Commvault's own suffix and is
  # kept as a second, independent catch.
  [string[]]$CommvaultNamePattern = @(
    'COMMVAULT',
    'GXMD_SNAP'
  ),

  # Tag markers (matched against both tag keys and tag values, case-insensitive). Commvault tags
  # every snapshot CreatedBy=Commvault, which 'Commvault' below matches on the value.
  [string[]]$CommvaultTagKey = @(
    'Commvault'
  ),

  # Write an extra CSV of every distinct tag key and name prefix found, so Commvault patterns can be
  # built from what this estate actually contains rather than from assumed conventions.
  [switch]$AuditCreatorEvidence,

  # Proceed with -Delete even though no Commvault snapshots were detected. Required in that case,
  # because zero detections usually means the patterns missed rather than that Commvault is absent.
  [switch]$AcknowledgeNoCommvaultSnapshots,

  # Treat Commvault snapshots as deletion candidates too. Off by default, and deliberately so.
  [switch]$IncludeCommvaultSnapshots,

  # Treat Azure Backup / Site Recovery snapshots as deletion candidates too. Strongly discouraged.
  [switch]$IncludeBackupServiceSnapshots,

  # Any snapshot carrying one of these tag keys is never a deletion candidate.
  [string[]]$KeepTagKey = @('DoNotDelete', 'KeepSnapshot', 'Preserve'),

  # Skip the Azure Compute Gallery walk (faster, but gallery-referenced snapshots will not be detected).
  [switch]$SkipGalleryCheck,

  # Snapshot storage price per GiB/month, used for the cost estimates. Fallback for any tier the
  # price table below does not name.
  [double]$PricePerGiBMonth = 0.05,

  # Optional per-tier rates, e.g. @{ 'Standard_LRS' = 0.05; 'Standard_ZRS' = 0.0625 } on Azure or
  # @{ 'standard' = 0.05; 'archive' = 0.0125 } on AWS. Rates vary by region and agreement, so put
  # your own in here before quoting a figure to anyone.
  [hashtable]$PriceTable,

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

$ScriptVersion = "2.0.0"
Write-Host "`n[INFO] Azure Snapshot Report v$ScriptVersion" -ForegroundColor Green

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
<#
Identifies which product created a snapshot. Returns one of:
  Commvault | AzureBackup | SiteRecovery | CloudNative

Commvault detection in Azure is conclusive, not inferred. Commvault stamps every snapshot it creates
with COMMVAULT in the resource name and a CreatedBy=Commvault tag. A real example:

  Name  linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462023_COMMVAULT_GXMD_SNAP_2db7ab
  Tags  CreatedBy   = Commvault
        Description = Created by jobID [8462023] at [09/16/2026,09:05:37] from [mas02036c1us02]

Either marker on its own is enough, and they are checked independently so a snapshot that has been
re-tagged by hand is still caught by its name, and vice versa. The patterns stay parameterised so an
unusual deployment can widen them, but the defaults are not guesswork.
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

  if ($SkipGalleryCheck) { return , $ids }

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

  # Comma prevents PowerShell from enumerating the set on the way out: a bare 'return $X' hands back
  # $null for an empty set and a plain array otherwise, losing both the type and the case-insensitive
  # comparer, so every .Contains() downstream either throws or silently turns case-sensitive.
  return , $ids
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
  # Comma prevents PowerShell from enumerating the set on the way out: a bare 'return $X' hands back
  # $null for an empty set and a plain array otherwise, losing both the type and the case-insensitive
  # comparer, so every .Contains() downstream either throws or silently turns case-sensitive.
  return , $ids
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
# Classification model (shared verbatim between the Azure and AWS scripts)
#
# Every snapshot gets exactly one Category. "Orphaned" is the literal case - the source is gone.
# "SourceActive" is the one people usually mean when they say orphaned: the disk/volume is still
# there, so the snapshot is not an orphan, but it is still billing and nobody has looked at it in
# a year. Both are reported; only Orphaned is in the default deletion scope.
#
#   Protected         Commvault, a cloud backup service, a keep-tag or a lock. Never deletable.
#   InUse             Backing a Managed Image / Gallery version / AMI. Never deletable.
#   Orphaned          Source disk or volume confirmed gone. True orphan.
#   SourceUnattached  Source disk/volume still exists but is attached to no VM or instance. The
#                     machine is gone and its disk was left behind, so the snapshot is one step from
#                     orphaned - usually the most interesting row in the report after Orphaned.
#   SourceActive      Source exists and is attached to a live machine. Judge it on age alone.
#   Unverifiable      No provable source reference. Cannot be proven either way.
#
# Category is a fact about the snapshot. Action is what THIS run would do about it, given
# -DeleteScope and the age thresholds. Keeping them separate means the report reads the same
# whatever flags you passed, and only the Action column moves.
#----------------------------

<#
Sanity-checks Commvault detection before anything is deleted.

Pattern matching can silently fail: change a naming convention, point the script at a subscription
whose Commvault instance stamps things differently, and every Commvault snapshot quietly becomes
"cloud-native". Finding ZERO Commvault snapshots is the loudest signal available that this has
happened, because an estate that runs Commvault should have some. Rather than let that sail through
into a delete, stop and make somebody say out loud that it is expected.
#>
function Test-CommvaultDetection {
  param(
    [int]$CommvaultCount,
    [int]$TotalCount,
    [bool]$Acknowledged
  )

  if ($TotalCount -eq 0) { return [pscustomobject]@{ Proceed = $true; Message = '' } }
  if ($CommvaultCount -gt 0) { return [pscustomobject]@{ Proceed = $true; Message = '' } }
  if ($Acknowledged) {
    return [pscustomobject]@{ Proceed = $true; Message = 'No Commvault snapshots detected - acknowledged by the operator.' }
  }

  $msg = @"
No Commvault-created snapshots were detected among $TotalCount snapshot(s).

That is either correct (Commvault protects nothing in this scope) or the detection markers no longer
match what Commvault writes. In the second case Commvault snapshots are sitting in the cloud-native
categories right now, and deleting them would destroy recovery points.

Before going further:

  1. See what is actually there, then widen the markers:
       -AuditCreatorEvidence          (writes every distinct tag key, name prefix and description)
       -CommvaultNamePattern '<regex>' -CommvaultTagKey '<marker>'

  2. If Commvault genuinely protects nothing in this scope, say so explicitly:
       -AcknowledgeNoCommvaultSnapshots

Refusing to delete.
"@
  return [pscustomobject]@{ Proceed = $false; Message = $msg }
}

<#
Prints the end-of-run summary to the terminal.

Written once and called at every exit point, including after a delete, so the last thing on screen is
always what the run found and did rather than a scroll of per-snapshot output. Takes everything it
prints as parameters so it stays cloud-agnostic and identical in both scripts.
#>
function Write-RunSummary {
  param(
    [object[]]$Rows,
    [object[]]$ToDelete,
    [object[]]$ToReview,
    [string[]]$DeleteScope,
    [string]$Currency,
    [string[]]$Files,
    [string]$NextStep,
    [hashtable]$DeleteResult
  )

  $cv = @($Rows | Where-Object { $_.Ownership -eq 'Commvault' })
  $focus = @($Rows | Where-Object { $_.Ownership -ne 'Commvault' })
  $focusMonthly = [math]::Round([double](($focus | Measure-Object EstMonthlyCost -Sum).Sum), 2)
  $cvMonthly = [math]::Round([double](($cv | Measure-Object EstMonthlyCost -Sum).Sum), 2)
  $deleteMonthly = [math]::Round([double](($ToDelete | Measure-Object EstMonthlyCost -Sum).Sum), 2)
  $deleteGiB = [math]::Round([double](($ToDelete | Measure-Object SizeGiB -Sum).Sum), 2)

  $rule = '  ' + ('-' * 74)

  Write-Host ""
  Write-Host $rule -ForegroundColor DarkGray
  Write-Host "  SUMMARY" -ForegroundColor White
  Write-Host $rule -ForegroundColor DarkGray
  Write-Host ""
  Write-Host ("  {0,-22}: {1}" -f 'Snapshots scanned', $Rows.Count) -ForegroundColor White

  if ($cv.Count -gt 0) {
    $cvGiB = [math]::Round([double](($cv | Measure-Object SizeGiB -Sum).Sum), 2)
    Write-Host ("  {0,-22}: {1} snapshot(s), {2} GiB, {3}/yr - excluded from the figures below" -f `
        'Created by Commvault', $cv.Count, $cvGiB.ToString('N0'),
        (Format-Money -Amount ($cvMonthly * 12) -Currency $Currency)) -ForegroundColor Green
  }

  Write-Host ""
  Write-Host "  NOT created by Commvault" -ForegroundColor White
  foreach ($cat in $script:CategoryOrder) {
    $g = @($focus | Where-Object { $_.Category -eq $cat })
    if ($g.Count -eq 0) { continue }
    $gib = [math]::Round([double](($g | Measure-Object SizeGiB -Sum).Sum), 2)
    $mo = [math]::Round([double](($g | Measure-Object EstMonthlyCost -Sum).Sum), 2)
    $colour = switch ($cat) {
      'Orphaned' { 'Red' } 'SourceUnattached' { 'Red' }
      'SourceActive' { 'Yellow' } 'Unverifiable' { 'Yellow' } default { 'Gray' }
    }
    Write-Host ("    {0,-18} {1,5}  {2,11} GiB  {3,14} /mo  {4,14} /yr" -f `
        $cat, $g.Count, $gib.ToString('N0'),
        (Format-Money -Amount $mo -Currency $Currency),
        (Format-Money -Amount ($mo * 12) -Currency $Currency)) -ForegroundColor $colour
  }

  Write-Host ""
  Write-Host ("  {0,-22}: {1} /month   {2} /year" -f 'Potential saving',
    (Format-Money -Amount $focusMonthly -Currency $Currency),
    (Format-Money -Amount ($focusMonthly * 12) -Currency $Currency)) -ForegroundColor Cyan
  Write-Host ("  {0,-22}: {1} snapshot(s), {2} GiB - worth {3}/yr" -f `
      'In scope to delete', $ToDelete.Count, $deleteGiB.ToString('N0'),
    (Format-Money -Amount ($deleteMonthly * 12) -Currency $Currency)) -ForegroundColor $(if ($ToDelete.Count -gt 0) { 'Yellow' } else { 'Green' })
  Write-Host ("  {0,-22}: {1} snapshot(s)" -f 'Held for review', $ToReview.Count) -ForegroundColor White
  Write-Host ("  {0,-22}: {1}" -f 'Delete scope', ($DeleteScope -join ', ')) -ForegroundColor Gray

  if ($DeleteResult) {
    Write-Host ""
    Write-Host $rule -ForegroundColor DarkGray
    Write-Host ("  {0,-22}: {1} snapshot(s), {2} GiB" -f 'DELETED', $DeleteResult.Deleted, ([double]$DeleteResult.GiB).ToString('N0')) -ForegroundColor Magenta
    Write-Host ("  {0,-22}: {1} /month   {2} /year" -f 'Saving realised',
      (Format-Money -Amount $DeleteResult.Monthly -Currency $Currency),
      (Format-Money -Amount ($DeleteResult.Monthly * 12) -Currency $Currency)) -ForegroundColor Magenta
    if ($DeleteResult.Failed -gt 0) {
      Write-Host ("  {0,-22}: {1} - see the deletion log" -f 'FAILED', $DeleteResult.Failed) -ForegroundColor Red
    }
  }

  if ($Files -and $Files.Count -gt 0) {
    Write-Host ""
    Write-Host "  Files written" -ForegroundColor White
    foreach ($f in $Files) { if ($f) { Write-Host "    $f" -ForegroundColor Gray } }
  }

  if ($NextStep) {
    Write-Host ""
    Write-Host "  Next step" -ForegroundColor White
    Write-Host "    $NextStep" -ForegroundColor Cyan
  }

  Write-Host ""
  Write-Host $rule -ForegroundColor DarkGray
  Write-Host ""
}

<#
The split the report is actually built around.

A customer reading this wants one question answered: what can I remove that Commvault does not own?
So ownership is the top-level partition, and everything analytic - tiles, cost, age bands, candidate
lists - is computed on the non-Commvault population alone. Commvault's own snapshots are reported
separately and briefly: found, counted, costed, and explicitly excluded from the savings figures, so
nobody has to wonder whether they were missed or quietly included.

This is deliberately not the same thing as the Protected category, which also holds Azure Backup,
Site Recovery, keep-tagged and locked snapshots. Those are not Commvault's and a customer still wants
to see them, so they stay in the main analysis.
#>
function Get-SnapshotOwnership {
  param([string]$Creator)
  if ($Creator -eq 'Commvault') { return 'Commvault' }
  return 'Not Commvault'
}

<#
Monthly cost of one snapshot.

Storage tier matters more than any other input here: an AWS archive-tier snapshot is roughly a
quarter the price of a standard one, and Azure ZRS is dearer than LRS. Applying one flat rate across
tiers is the quickest way to produce a number that is confidently wrong, so -PriceTable can map each
tier to its own rate and -PricePerGiBMonth is the fallback for tiers it does not name.
#>
function Get-SnapshotMonthlyCost {
  param(
    [double]$SizeGiB,
    [string]$Tier,
    [hashtable]$PriceTable,
    [double]$DefaultPrice
  )

  $rate = $DefaultPrice
  if ($PriceTable -and -not [string]::IsNullOrWhiteSpace($Tier) -and $PriceTable.ContainsKey($Tier)) {
    $rate = [double]$PriceTable[$Tier]
  }
  return [math]::Round($SizeGiB * $rate, 2)
}

<#
The single money formatter. Every figure shown anywhere carries its currency and groups thousands, so
no number in a report or on the console can be misread as a bare count or a different currency.

Small amounts keep two decimals: a 2 GiB snapshot costs pennies a month, and rounding that to "USD 0"
reads as free when it is not. Large ones drop to whole units because the decimals are noise at that
scale, and only genuinely huge figures compact to M, and then only in grid cells where width is tight.
#>
function Format-Money {
  param(
    [double]$Amount,
    [string]$Currency,
    [switch]$Compact
  )

  $n = if ($Compact -and $Amount -ge 1000000) { "$([math]::Round($Amount / 1000000, 2))M" }
  elseif ($Amount -eq 0 -or $Amount -ge 100) { $Amount.ToString('N0') }
  else { $Amount.ToString('N2') }

  return "$Currency $n"
}

function Format-MoneyCell {
  param([double]$Amount, [string]$Currency)
  return Format-Money -Amount $Amount -Currency $Currency -Compact
}

<#
Pre-aggregated cost, one row per distinct combination of scope, ownership, creator, category, action
and age band.

Every row is the same kind of thing, so the file behaves like data: filter it, pivot it, and the
numbers add up. An earlier version stacked several levels of aggregation in one table behind a
"Grouping" column - totals beside categories beside regions - which meant summing the cost column
returned roughly ten times the real figure and any filter silently mixed granularities. Mixed grain
in one table is a trap, not a convenience.

For anything this does not answer, use the per-snapshot CSV: it carries the same dimensions on every
row, so it pivots to whatever shape is needed.
#>
function Get-CostSummary {
  param(
    [object[]]$Rows,
    [string]$Currency,
    # Scope columns to include, e.g. @(@{Label='Region'; Prop='Location'}). Cloud-specific, so each
    # script names its own rather than this function guessing at column names.
    [object[]]$ScopeProperties
  )

  $out = [System.Collections.Generic.List[object]]::new()
  if (-not $Rows -or $Rows.Count -eq 0) { return $out }

  $scopeProps = @($ScopeProperties)
  $keyProps = @($scopeProps | ForEach-Object { $_.Prop }) + @('Ownership', 'Creator', 'Category', 'Action', 'AgeBand')

  foreach ($g in ($Rows | Group-Object -Property $keyProps)) {
    $first = $g.Group[0]
    $monthly = [math]::Round([double](($g.Group | Measure-Object EstMonthlyCost -Sum).Sum), 2)

    # Ordered so the columns you filter on come first and the numbers last.
    $row = [ordered]@{}
    foreach ($sp in $scopeProps) { $row[$sp.Label] = [string]$first.($sp.Prop) }
    $row['Ownership'] = $first.Ownership
    $row['Creator'] = $first.Creator
    $row['Category'] = $first.Category
    $row['Action'] = $first.Action
    $row['AgeBand'] = $first.AgeBand
    $row['Snapshots'] = $g.Group.Count
    $row['CapacityGiB'] = [math]::Round([double](($g.Group | Measure-Object SizeGiB -Sum).Sum), 2)
    $row['Currency'] = $Currency
    $row['EstMonthlyCost'] = $monthly
    $row['EstAnnualCost'] = [math]::Round($monthly * 12, 2)
    $out.Add([pscustomobject]$row)
  }

  return $out
}

<#
Summarises the naming, tagging and descriptions actually present in the estate, so Commvault markers
can be found by evidence rather than assumed.

Emits four kinds of row:

  TagKey              every distinct tag key, with a count
  TagPair             every distinct key=value pair whose value is low-cardinality. This is the one
                      that finds Azure's marker: CreatedBy=Commvault shows up here immediately.
  NamePrefix          the leading token of each name
  DescriptionPattern  descriptions with digits, hex and timestamps masked, so that
                        "Created by jobID [8462023] at [09/16/2026,09:05:37] from [mas02036c1us02]"
                      collapses to a single counted template instead of one unique row per snapshot.
                      Raw descriptions are useless for this - the template is the marker.

Sorted with the rarest tag pairs first: a marker written by exactly one product is usually far less
common than environment or owner tags, so the interesting rows surface at the top.
#>
function Get-CreatorEvidence {
  param([object[]]$Rows)

  $out = [System.Collections.Generic.List[object]]::new()

  $tagKeys = @{}
  $tagPairs = @{}
  foreach ($r in $Rows) {
    if ([string]::IsNullOrWhiteSpace($r.Tags)) { continue }
    foreach ($pair in ($r.Tags -split ';')) {
      $parts = $pair -split '=', 2
      $k = $parts[0].Trim()
      if (-not $k) { continue }
      $v = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

      if (-not $tagKeys.ContainsKey($k)) { $tagKeys[$k] = [pscustomobject]@{ Count = 0; Example = $r.Name; Creator = $r.Creator } }
      $tagKeys[$k].Count++

      # A tag whose value is a job id or timestamp is noise; one with a stable value is a marker.
      $pk = "$k=$v"
      if (-not $tagPairs.ContainsKey($pk)) { $tagPairs[$pk] = [pscustomobject]@{ Count = 0; Example = $r.Name; Creator = $r.Creator } }
      $tagPairs[$pk].Count++
    }
  }
  foreach ($k in ($tagKeys.Keys | Sort-Object)) {
    $out.Add([pscustomobject]@{
        Evidence = 'TagKey'; Value = $k; Count = $tagKeys[$k].Count
        ExampleSnapshot = $tagKeys[$k].Example; ClassifiedAs = $tagKeys[$k].Creator
      })
  }
  # Only pairs shared by several snapshots - a unique value per snapshot is an id, not a marker.
  foreach ($pk in ($tagPairs.Keys | Where-Object { $tagPairs[$_].Count -gt 1 } | Sort-Object { $tagPairs[$_].Count })) {
    $out.Add([pscustomobject]@{
        Evidence = 'TagPair'; Value = $pk; Count = $tagPairs[$pk].Count
        ExampleSnapshot = $tagPairs[$pk].Example; ClassifiedAs = $tagPairs[$pk].Creator
      })
  }

  # Leading token of the name - product prefixes show up here if they are used at all.
  $prefixes = @{}
  foreach ($r in $Rows) {
    if ([string]::IsNullOrWhiteSpace($r.Name)) { continue }
    $p = ([string]$r.Name -split '[-_.]')[0]
    if (-not $p) { continue }
    if (-not $prefixes.ContainsKey($p)) { $prefixes[$p] = [pscustomobject]@{ Count = 0; Example = $r.Name; Creator = $r.Creator } }
    $prefixes[$p].Count++
  }
  foreach ($p in ($prefixes.Keys | Sort-Object { -$prefixes[$_].Count })) {
    $out.Add([pscustomobject]@{
        Evidence = 'NamePrefix'; Value = $p; Count = $prefixes[$p].Count
        ExampleSnapshot = $prefixes[$p].Example; ClassifiedAs = $prefixes[$p].Creator
      })
  }

  $descs = @{}
  foreach ($r in $Rows) {
    $d = [string]$r.Description
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    $t = Get-DescriptionTemplate -Description $d
    if (-not $descs.ContainsKey($t)) { $descs[$t] = [pscustomobject]@{ Count = 0; Example = $d; Creator = $r.Creator } }
    $descs[$t].Count++
  }
  foreach ($t in ($descs.Keys | Sort-Object { -$descs[$_].Count })) {
    $out.Add([pscustomobject]@{
        Evidence = 'DescriptionPattern'; Value = $t; Count = $descs[$t].Count
        ExampleSnapshot = $descs[$t].Example; ClassifiedAs = $descs[$t].Creator
      })
  }

  return $out
}

<#
Masks the variable parts of a description so descriptions from the same code path collapse together.
Job ids, timestamps, GUIDs and hex blobs all become placeholders; the surrounding wording - which is
what identifies the product - survives.
#>
function Get-DescriptionTemplate {
  param([string]$Description)

  $t = $Description
  $t = $t -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>'
  $t = $t -replace '\d{1,4}[/-]\d{1,2}[/-]\d{1,4}[ ,T]*\d{0,2}:?\d{0,2}:?\d{0,2}', '<timestamp>'
  $t = $t -replace '\b[0-9a-fA-F]{12,}\b', '<hex>'
  $t = $t -replace '\d+', '<n>'
  return $t.Trim()
}

$script:CategoryOrder = @('Orphaned', 'SourceUnattached', 'SourceActive', 'Unverifiable', 'InUse', 'Protected')
$script:AgeBandOrder = @('0-30 days', '31-90 days', '91-365 days', 'Over 365 days')

function Get-AgeBand {
  param([double]$AgeDays)
  if ($AgeDays -le 30) { return '0-30 days' }
  if ($AgeDays -le 90) { return '31-90 days' }
  if ($AgeDays -le 365) { return '91-365 days' }
  return 'Over 365 days'
}

function Get-SnapshotCategory {
  param(
    [bool]$SourceExists,
    [bool]$SourceAttached,
    [bool]$HasSourceReference,
    [bool]$ReferencedByImage,
    [bool]$HasKeepTag,
    [bool]$IsPinned,          # Azure: resource lock. AWS: shared with another account.
    [string]$PinnedReason,
    [string]$Creator,
    [bool]$CreatorExcluded
  )

  if ($CreatorExcluded) { return [pscustomobject]@{ Category = 'Protected'; Reason = "Created by $Creator - excluded from deletion" } }
  if ($HasKeepTag) { return [pscustomobject]@{ Category = 'Protected'; Reason = 'Carries a keep-tag' } }
  if ($IsPinned) { return [pscustomobject]@{ Category = 'Protected'; Reason = $PinnedReason } }
  if ($ReferencedByImage) { return [pscustomobject]@{ Category = 'InUse'; Reason = 'Backs an image that still exists' } }
  if (-not $HasSourceReference) { return [pscustomobject]@{ Category = 'Unverifiable'; Reason = 'No source reference recorded - orphan status cannot be proven' } }
  if (-not $SourceExists) { return [pscustomobject]@{ Category = 'Orphaned'; Reason = 'Source no longer exists' } }
  if (-not $SourceAttached) { return [pscustomobject]@{ Category = 'SourceUnattached'; Reason = 'Source still exists but is attached to nothing - its machine is gone' } }
  return [pscustomobject]@{ Category = 'SourceActive'; Reason = 'Source exists and is attached to a live machine' }
}

<#
Decides what this run would do with a snapshot.

  Delete  in scope, and past the age bar for its category
  Review  a candidate, but held back by scope or age - this is where the reporting value lives
  Keep    Protected or InUse; never actionable

Orphaned clears at -MinAgeDays. SourceUnattached, SourceActive and Unverifiable have to clear the
much higher -SourceActiveMinAgeDays, because deleting a snapshot whose source still exists (or is
unknown) is a bigger call than reaping one whose source is provably gone.
#>
function Get-SnapshotAction {
  param(
    [string]$Category,
    [double]$AgeDays,
    [string[]]$DeleteScope,
    [int]$MinAgeDays,
    [int]$SourceActiveMinAgeDays
  )

  if ($Category -in @('Protected', 'InUse')) {
    return [pscustomobject]@{ Action = 'Keep'; Note = 'Not a deletion candidate' }
  }

  $bar = if ($Category -eq 'Orphaned') { $MinAgeDays } else { $SourceActiveMinAgeDays }

  if ($Category -notin $DeleteScope) {
    return [pscustomobject]@{ Action = 'Review'; Note = "$Category is not in -DeleteScope (currently: $($DeleteScope -join ', '))" }
  }
  if ($AgeDays -lt $bar) {
    return [pscustomobject]@{ Action = 'Review'; Note = "Younger than the $Category age bar ($([math]::Round($AgeDays,1)) < $bar days)" }
  }
  return [pscustomobject]@{ Action = 'Delete'; Note = "In -DeleteScope and past the $bar day bar" }
}

#----------------------------
# HTML report (shared verbatim between the Azure and AWS scripts)
#
# Colours, ramp steps and dark-mode steps come from the data-viz reference palette.
# The category x age grid is a heatmap, so it uses the SEQUENTIAL blue ramp (one hue, darker =
# more) rather than categorical hues - the grid encodes magnitude, not identity. Every cell
# carries its number as text, which is also the relief for the light ramp steps that sit under
# 3:1 contrast. Status colours always appear beside a written label, never alone.
#----------------------------
<#
Buckets a 0..1 magnitude onto one of seven sequential ramp classes.

Returns a CSS class, not a hex value, because light and dark need genuinely different steps: on the
light surface the ramp darkens as values rise, on the dark surface it brightens. Emitting a class
lets the stylesheet pick the right set - an inline hex would force dark mode to reuse the light
steps, which is the thing that makes a dark-mode chart glare. Cell ink flips with the class too.
#>
function Get-RampClass {
  param([double]$Fraction)
  if ($Fraction -le 0) { return 'r0' }
  $i = [math]::Ceiling($Fraction * 7)
  if ($i -lt 1) { $i = 1 }
  if ($i -gt 7) { $i = 7 }
  return "r$i"
}

function Format-Gib {
  param([double]$Gib)
  if ($Gib -ge 1024) { return "$([math]::Round($Gib / 1024, 1)) TiB" }
  return "$([math]::Round($Gib, 0)) GiB"
}

function New-HtmlReport {
  param(
    [object[]]$Rows,
    [string]$Path,
    [hashtable]$Totals,
    [hashtable]$Schema
  )

  $enc = { param([string]$s) [System.Web.HttpUtility]::HtmlEncode($s) }

  #--- ownership split: the analysis is about what Commvault does NOT own ---
  # Where Commvault cannot be identified reliably (AWS today) the schema turns the split off and the
  # whole estate is reported as one population, with a banner saying so. Claiming a clean separation
  # we cannot actually make would be worse than not splitting at all.
  $splitOwnership = [bool]$Schema.SplitByOwnership
  $cvRows = if ($splitOwnership) { @($Rows | Where-Object { $_.Ownership -eq 'Commvault' }) } else { @() }
  $focus = if ($splitOwnership) { @($Rows | Where-Object { $_.Ownership -ne 'Commvault' }) } else { @($Rows) }

  $cvGib = [math]::Round([double](($cvRows | Measure-Object SizeGiB -Sum).Sum), 2)
  $cvMonthly = [double](($cvRows | Measure-Object EstMonthlyCost -Sum).Sum)

  #--- headline ---
  $deleteRows = @($focus | Where-Object { $_.Action -eq 'Delete' })
  $reviewRows = @($focus | Where-Object { $_.Action -eq 'Review' })
  $deleteGib = [math]::Round((($deleteRows | Measure-Object SizeGiB -Sum).Sum), 2)
  $reviewGib = [math]::Round((($reviewRows | Measure-Object SizeGiB -Sum).Sum), 2)
  $deleteMonthly = [double](($deleteRows | Measure-Object EstMonthlyCost -Sum).Sum)
  $reviewMonthly = [double](($reviewRows | Measure-Object EstMonthlyCost -Sum).Sum)
  $totalMonthly = [double](($focus | Measure-Object EstMonthlyCost -Sum).Sum)
  $focusGib = [math]::Round([double](($focus | Measure-Object SizeGiB -Sum).Sum), 2)

  #--- category x age heatmap ---
  $cells = @{}
  $maxCell = 0.0
  foreach ($cat in $script:CategoryOrder) {
    foreach ($band in $script:AgeBandOrder) {
      $g = @($focus | Where-Object { $_.Category -eq $cat -and $_.AgeBand -eq $band })
      $gib = [double]([math]::Round((($g | Measure-Object SizeGiB -Sum).Sum), 2))
      $annual = [double](($g | Measure-Object EstAnnualCost -Sum).Sum)
      $cells["$cat|$band"] = [pscustomobject]@{ Count = $g.Count; Gib = $gib; Annual = $annual }
      if ($annual -gt $maxCell) { $maxCell = $annual }
    }
  }

  # Status hues for the three severities, a categorical hue for the "cannot tell" state, and the
  # calm end of the scale for the two that are never actionable. Each is written beside its label,
  # so the colour never carries the meaning on its own.
  $catMeta = @{
    'Orphaned'         = @{ Colour = '#d03b3b'; Blurb = 'Source is gone. The true orphans.' }
    'SourceUnattached' = @{ Colour = '#ec835a'; Blurb = 'Source exists but its machine is gone.' }
    'SourceActive'     = @{ Colour = '#fab219'; Blurb = 'Attached to a live machine. Still billing.' }
    'Unverifiable'     = @{ Colour = '#4a3aa7'; Blurb = 'No provable source. Needs a human.' }
    'InUse'            = @{ Colour = '#2a78d6'; Blurb = 'Backing a live image. Leave alone.' }
    'Protected'        = @{ Colour = '#0ca30c'; Blurb = $(if ($splitOwnership) { 'Backup service, keep-tag or lock.' } else { 'Commvault, backup service, keep-tag or lock.' }) }
  }

  $heatRows = foreach ($cat in $script:CategoryOrder) {
    $tds = foreach ($band in $script:AgeBandOrder) {
      $c = $cells["$cat|$band"]
      $frac = if ($maxCell -gt 0) { $c.Annual / $maxCell } else { 0 }
      if ($c.Count -eq 0) {
        "<td class='cell empty' title='$cat / $band&#10;nothing here'><span class='cv'>&middot;</span></td>"
      } else {
        $tip = "$cat / $band&#10;$($c.Count) snapshot(s)&#10;$(Format-Gib $c.Gib)&#10;$(Format-Money $c.Annual $Totals.Currency) per year"
        "<td class='cell $(Get-RampClass -Fraction $frac)' title='$tip'><span class='cv'>$(Format-MoneyCell $c.Annual $Totals.Currency)</span><span class='cn'>$($c.Count)</span></td>"
      }
    }
    $rowAnnual = ($script:AgeBandOrder | ForEach-Object { $cells["$cat|$_"].Annual } | Measure-Object -Sum).Sum
    $rowCount = ($script:AgeBandOrder | ForEach-Object { $cells["$cat|$_"].Count } | Measure-Object -Sum).Sum
    @"
<tr>
  <th scope="row"><span class="dot" style="background:$($catMeta[$cat].Colour)"></span>$cat<em>$($catMeta[$cat].Blurb)</em></th>
  $($tds -join "`n  ")
  <td class="tot">$(Format-MoneyCell $rowAnnual $Totals.Currency)<span class="cn">$rowCount</span></td>
</tr>
"@
  }

  $bandHeads = ($script:AgeBandOrder | ForEach-Object { "<th scope='col'>$_</th>" }) -join "`n      "

  # Column totals. "What is this age range costing me" is a question the grid cannot answer without
  # them, and it is the one that usually drives the decision to act.
  $bandTotals = ($script:AgeBandOrder | ForEach-Object {
      $band = $_
      $a = ($script:CategoryOrder | ForEach-Object { $cells["$_|$band"].Annual } | Measure-Object -Sum).Sum
      $n = ($script:CategoryOrder | ForEach-Object { $cells["$_|$band"].Count } | Measure-Object -Sum).Sum
      "<td class='tot'>$(Format-MoneyCell $a $Totals.Currency)<span class='cn'>$n</span></td>"
    }) -join "`n      "
  $grandAnnual = [double](($focus | Measure-Object EstAnnualCost -Sum).Sum)

  #--- detail tables ---
  function Format-DetailTable {
    param([object[]]$Set, [string]$Empty)
    if ($Set.Count -eq 0) { return "<p class='none'>$Empty</p>" }
    $heads = ($Schema.Columns | ForEach-Object { "<th scope='col'>$($_.Label)</th>" }) -join ''
    $body = ($Set | Sort-Object -Property @{Expression = 'SizeGiB'; Descending = $true } | Select-Object -First 250 | ForEach-Object {
        $r = $_
        $tds = ($Schema.Columns | ForEach-Object {
            $v = $r.($_.Prop)
            if ($_.Money) { $v = Format-Money -Amount ([double]$v) -Currency $Totals.Currency }
            $cls = if ($_.Numeric) { " class='num'" } else { '' }
            "<td$cls>$([System.Web.HttpUtility]::HtmlEncode([string]$v))</td>"
          }) -join ''
        "<tr><td><span class='dot' style='background:$($catMeta[$r.Category].Colour)'></span>$($r.Category)</td>$tds<td>$([System.Web.HttpUtility]::HtmlEncode([string]$r.Reason))</td></tr>"
      }) -join "`n"
    $more = if ($Set.Count -gt 250) { "<p class='none'>Showing the 250 largest of $($Set.Count). The CSV has them all.</p>" } else { '' }
    return "<div class='scroll'><table class='detail'><thead><tr><th scope='col'>Category</th>$heads<th scope='col'>Why</th></tr></thead><tbody>`n$body`n</tbody></table></div>$more"
  }

  $deleteTable = Format-DetailTable -Set $deleteRows -Empty 'Nothing is in scope for deletion on this run.'
  $reviewTable = Format-DetailTable -Set $reviewRows -Empty 'Nothing held back for review.'

  #--- by creator ---
  $byCreator = ($Rows | Group-Object Creator | Sort-Object { ($_.Group | Measure-Object SizeGiB -Sum).Sum } -Descending | ForEach-Object {
      $gib = [math]::Round((($_.Group | Measure-Object SizeGiB -Sum).Sum), 2)
      "<tr><td>$($_.Name)</td><td class='num'>$($_.Count)</td><td class='num'>$(Format-Gib $gib)</td></tr>"
    }) -join "`n"

  # Cost per category is the question the capacity heatmap cannot answer on its own: a category can
  # hold a lot of GiB on a cheap tier, or little on an expensive one.
  $costRows = ($script:CategoryOrder | ForEach-Object {
      $cat = $_
      $g = @($focus | Where-Object { $_.Category -eq $cat })
      if ($g.Count -eq 0) { return }
      $gib = [math]::Round([double](($g | Measure-Object SizeGiB -Sum).Sum), 2)
      $m = [double](($g | Measure-Object EstMonthlyCost -Sum).Sum)
      $share = if ($totalMonthly -gt 0) { [math]::Round(($m / $totalMonthly) * 100, 1) } else { 0 }
      $actionable = if ($cat -in $Totals.DeleteScope) { 'In scope' } elseif ($cat -in @('InUse', 'Protected')) { 'Never' } else { 'Opt in' }
      @"
<tr>
  <th scope="row"><span class="dot" style="background:$($catMeta[$cat].Colour)"></span>$cat</th>
  <td class="num">$($g.Count)</td>
  <td class="num">$(Format-Gib $gib)</td>
  <td class="num">$(Format-Money $m $Totals.Currency)</td>
  <td class="num strong">$(Format-Money ($m * 12) $Totals.Currency)</td>
  <td class="share"><span class="track"><span class="bar" style="width:$([math]::Min($share, 100))%"></span></span><span class="pct">$share%</span></td>
  <td>$actionable</td>
</tr>
"@
    }) -join "`n"

  $costTotalRow = @"
<tr class="total">
  <th scope="row">Total</th>
  <td class="num">$($focus.Count)</td>
  <td class="num">$(Format-Gib $focusGib)</td>
  <td class="num">$(Format-Money $totalMonthly $Totals.Currency)</td>
  <td class="num strong">$(Format-Money ($totalMonthly * 12) $Totals.Currency)</td>
  <td class="share"><span class="track"><span class="bar" style="width:100%"></span></span><span class="pct">100%</span></td>
  <td></td>
</tr>
"@

  $scopeLine = ($Totals.DeleteScope -join ', ')
  $modeLine = if ($Totals.DeleteMode) { 'DELETE' } else { 'REPORT ONLY' }

  $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$($Schema.Title)</title>
<style>
:root {
  color-scheme: light;
  --surface: #fcfcfb; --plane: #f9f9f7;
  --ink: #0b0b0b; --ink-2: #52514e; --ink-muted: #898781;
  --grid: #e1e0d9; --rule: #c3c2b7; --ring: rgba(11,11,11,0.10);
  --accent: #2a78d6;
  /* Sequential blue, light surface: more capacity = darker. Ink flips once the fill goes dark. */
  --r1: #cde2fb; --r2: #9ec5f4; --r3: #6da7ec; --r4: #3987e5; --r5: #256abf; --r6: #184f95; --r7: #0d366b;
  --ri1: #0b0b0b; --ri2: #0b0b0b; --ri3: #0b0b0b; --ri4: #0b0b0b; --ri5: #ffffff; --ri6: #ffffff; --ri7: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root:where(:not([data-theme="light"])) {
    color-scheme: dark;
    --surface: #1a1a19; --plane: #0d0d0d;
    --ink: #ffffff; --ink-2: #c3c2b7; --ink-muted: #898781;
    --grid: #2c2c2a; --rule: #383835; --ring: rgba(255,255,255,0.10);
    --accent: #3987e5;
    /* Same blue ramp re-stepped for the dark surface: more capacity = brighter, not darker. */
    --r1: #0d366b; --r2: #104281; --r3: #1c5cab; --r4: #256abf; --r5: #2a78d6; --r6: #3987e5; --r7: #6da7ec;
    --ri1: #ffffff; --ri2: #ffffff; --ri3: #ffffff; --ri4: #ffffff; --ri5: #ffffff; --ri6: #0b0b0b; --ri7: #0b0b0b;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --surface: #1a1a19; --plane: #0d0d0d;
  --ink: #ffffff; --ink-2: #c3c2b7; --ink-muted: #898781;
  --grid: #2c2c2a; --rule: #383835; --ring: rgba(255,255,255,0.10);
  --accent: #3987e5;
  --r1: #0d366b; --r2: #104281; --r3: #1c5cab; --r4: #256abf; --r5: #2a78d6; --r6: #3987e5; --r7: #6da7ec;
  --ri1: #ffffff; --ri2: #ffffff; --ri3: #ffffff; --ri4: #ffffff; --ri5: #ffffff; --ri6: #0b0b0b; --ri7: #0b0b0b;
}
* { box-sizing: border-box; }
body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background: var(--plane); color: var(--ink);
       margin: 0; padding: 32px 16px 64px; -webkit-font-smoothing: antialiased; }
.wrap { max-width: 1180px; margin: 0 auto; }
h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; letter-spacing: -0.01em; }
h2 { font-size: 15px; font-weight: 600; margin: 40px 0 2px; }
h2 + .sub { color: var(--ink-2); font-size: 13px; margin: 0 0 14px; }
.meta { color: var(--ink-muted); font-size: 12px; margin-bottom: 28px; }
.meta b { color: var(--ink-2); font-weight: 600; }
.hero { background: var(--surface); border: 1px solid var(--ring); border-radius: 10px; padding: 22px 26px; margin-bottom: 14px; }
.hero .label { font-size: 12px; color: var(--ink-2); }
.hero .value { font-size: 52px; font-weight: 600; line-height: 1.05; margin: 4px 0 2px; letter-spacing: -0.02em; }
.hero .foot { font-size: 13px; color: var(--ink-2); }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(168px, 1fr)); gap: 12px; }
.tile { background: var(--surface); border: 1px solid var(--ring); border-radius: 10px; padding: 14px 16px; }
.tile .label { font-size: 12px; color: var(--ink-2); display: flex; align-items: center; gap: 7px; }
.tile .value { font-size: 26px; font-weight: 600; margin-top: 6px; letter-spacing: -0.01em; }
.tile .sub { font-size: 12px; color: var(--ink-muted); margin-top: 1px; }
.tile .cost { font-size: 12px; color: var(--ink-2); margin-top: 5px; padding-top: 5px; border-top: 1px solid var(--grid);
              font-variant-numeric: tabular-nums; }
.hero .unit { font-size: 22px; font-weight: 400; color: var(--ink-2); letter-spacing: 0; }
.cost td.strong { font-weight: 600; }
.cost tr.total th, .cost tr.total td { background: var(--plane); font-weight: 600; border-top: 2px solid var(--rule); }
.cost th[scope="row"] { font-weight: 600; white-space: nowrap; }
.share { min-width: 130px; }
/* A meter: fixed-width track, fill sized as a percentage of the track. Sizing the fill against the
   cell instead would push the label out of the cell once a category passed ~80% of spend, and would
   make bars incomparable between rows. The track is a recessive step of the same ramp. */
.share { display: flex; align-items: center; gap: 9px; }
.share .track { flex: 0 0 92px; height: 8px; border-radius: 2px; background: var(--r1); overflow: hidden; }
.share .bar { display: block; height: 100%; border-radius: 2px; background: var(--accent); min-width: 2px; }
.share .pct { font-size: 12px; color: var(--ink-2); font-variant-numeric: tabular-nums; white-space: nowrap; }
.dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; flex: none; margin-right: 7px;
       vertical-align: baseline; }
.tile .label .dot { margin-right: 0; }
.r1 { background: var(--r1); color: var(--ri1); } .r2 { background: var(--r2); color: var(--ri2); }
.r3 { background: var(--r3); color: var(--ri3); } .r4 { background: var(--r4); color: var(--ri4); }
.r5 { background: var(--r5); color: var(--ri5); } .r6 { background: var(--r6); color: var(--ri6); }
.r7 { background: var(--r7); color: var(--ri7); }
.scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; border-radius: 10px; }
/* Identifiers and figures must not break mid-value; only the free-text reason wraps. The table
   scrolls inside its own box when that makes it wider than the page. */
.detail th, .detail td { white-space: nowrap; }
.detail td:last-child, .detail th:last-child { white-space: normal; min-width: 150px; }
.detail th, .detail td { padding-left: 10px; padding-right: 10px; }
table { border-collapse: separate; border-spacing: 0; width: 100%; font-size: 13px; background: var(--surface);
        border: 1px solid var(--ring); border-radius: 10px; overflow: hidden; }
th, td { padding: 9px 12px; text-align: left; border-bottom: 1px solid var(--grid); }
thead th { font-size: 11px; font-weight: 600; color: var(--ink-2); text-transform: uppercase; letter-spacing: 0.05em;
           background: var(--plane); white-space: nowrap; }
tbody tr:last-child td, tbody tr:last-child th { border-bottom: none; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.heat th[scope="row"] { font-weight: 600; white-space: nowrap; display: table-cell; }
.heat th[scope="row"] em { display: block; font-weight: 400; font-style: normal; color: var(--ink-muted); font-size: 11px; margin-top: 2px; }

.heat .cell { text-align: right; font-variant-numeric: tabular-nums; border-bottom: 2px solid var(--surface);
              border-right: 2px solid var(--surface); cursor: default; }
.heat .cell.empty { color: var(--ink-muted); text-align: center; background: var(--plane); }
.heat .cv { display: block; font-weight: 600; }
.heat .cn { display: block; font-size: 11px; opacity: .72; font-weight: 400; }
.heat td.tot { text-align: right; font-variant-numeric: tabular-nums; font-weight: 600; background: var(--plane); }
.none { color: var(--ink-muted); font-size: 13px; background: var(--surface); border: 1px solid var(--ring);
        border-radius: 10px; padding: 14px 16px; margin: 0; }
.cvpanel { background: var(--surface); border: 1px solid var(--ring); border-left: 3px solid #0ca30c;
           border-radius: 10px; margin: 14px 0 0; overflow: hidden; }
.cvpanel.warn { border-left-color: #fab219; }
.cvhead { font-size: 13px; font-weight: 600; padding: 12px 16px 0; display: flex; align-items: center; }
.cvbody { padding: 10px 16px 14px; display: flex; flex-wrap: wrap; align-items: flex-start; gap: 28px; }
.cvstat .v { font-size: 22px; font-weight: 600; letter-spacing: -0.01em; }
.cvstat .l { font-size: 11px; color: var(--ink-muted); text-transform: uppercase; letter-spacing: .04em; }
.cvnote { font-size: 12px; color: var(--ink-2); margin: 0; flex: 1 1 320px; line-height: 1.55; }
.heat tr.bandtot th, .heat tr.bandtot td { background: var(--plane); border-top: 2px solid var(--rule);
                                           font-weight: 600; }
.note { background: var(--surface); border: 1px solid var(--ring); border-left: 3px solid #fab219; border-radius: 8px;
        padding: 14px 18px; font-size: 13px; color: var(--ink-2); margin-top: 32px; line-height: 1.55; }
.note b { color: var(--ink); }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; background: var(--plane);
       padding: 1px 5px; border-radius: 4px; border: 1px solid var(--grid); }
.legend { font-size: 12px; color: var(--ink-muted); margin-top: 10px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.legend .sw { width: 22px; height: 10px; border-radius: 2px; display: inline-block; }
@media (max-width: 720px) {
  .heat th[scope="row"] em { display: none; }
  th, td { padding: 7px 8px; }
  .hero .value { font-size: 38px; }
  body { padding: 20px 16px 48px; }
  /* Wide tables scroll inside their own box so the page itself never scrolls sideways. */
  .scroll table { min-width: 640px; }
}
</style></head>
<body><div class="wrap">

<h1>$($Schema.Title)</h1>
<div class="meta">
  Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; v$ScriptVersion &middot;
  mode <b>$modeLine</b> &middot; delete scope <b>$scopeLine</b> &middot;
  age bars: orphaned <b>$($Totals.MinAgeDays)d</b>, everything else <b>$($Totals.SourceActiveMinAgeDays)d</b>
</div>

<div class="hero">
  <div class="label">$(if ($splitOwnership) { 'Potentially reclaimable &mdash; snapshots Commvault did not create' } else { 'Potentially reclaimable' })</div>
  <div class="value">$(Format-Money ($totalMonthly * 12) $Totals.Currency)<span class="unit"> / year</span></div>
  <div class="foot"><b>$(Format-Money $totalMonthly $Totals.Currency) per month</b> across $($focus.Count) snapshot(s), $(Format-Gib $focusGib).
  Of that, <b>$(Format-Money ($deleteMonthly * 12) $Totals.Currency)/year</b> ($($deleteRows.Count) snapshot(s)) is in scope to delete today and
  <b>$(Format-Money ($reviewMonthly * 12) $Totals.Currency)/year</b> ($($reviewRows.Count) snapshot(s)) needs a decision first.</div>
</div>

$(if ($splitOwnership) {
@"
<div class="cvpanel">
  <div class="cvhead"><span class="dot" style="background:#0ca30c"></span>Commvault-created snapshots &mdash; found and excluded</div>
  <div class="cvbody">
    <div class="cvstat"><div class="v">$($cvRows.Count)</div><div class="l">snapshots</div></div>
    <div class="cvstat"><div class="v">$(Format-Gib $cvGib)</div><div class="l">capacity</div></div>
    <div class="cvstat"><div class="v">$(Format-Money ($cvMonthly * 12) $Totals.Currency)</div><div class="l">per year</div></div>
    <p class="cvnote">These are Commvault's own backup snapshots. They are <b>not</b> a saving &mdash; deleting them breaks
    recovery points &mdash; and they are excluded from every figure elsewhere in this report. Listed here so it is clear
    they were found rather than missed.</p>
  </div>
</div>
"@
} else {
@"
<div class="cvpanel warn">
  <div class="cvhead"><span class="dot" style="background:#fab219"></span>Commvault snapshots are not separated in this report</div>
  <div class="cvbody">
    <p class="cvnote">Commvault's marker for this cloud is not confirmed, so the whole estate is reported as one
    population and the figures below <b>may include Commvault-created snapshots</b>. Confirm the marker with
    <code>-AuditCreatorEvidence</code> before treating these totals as a saving.</p>
  </div>
</div>
"@
})

<div class="tiles">
$(($script:CategoryOrder | ForEach-Object {
  $cat = $_
  $g = @($focus | Where-Object { $_.Category -eq $cat })
  # Skip categories with nothing in them, so the tiles agree with the cost table rather than
  # showing a row of zeroes the table omits.
  if ($g.Count -eq 0) { return }
  $gib = [math]::Round((($g | Measure-Object SizeGiB -Sum).Sum), 2)
  $m = [double](($g | Measure-Object EstMonthlyCost -Sum).Sum)
  "<div class='tile'><div class='label'><span class='dot' style='background:$($catMeta[$cat].Colour)'></span>$cat</div><div class='value'>$($g.Count)</div><div class='sub'>$(Format-Gib $gib)</div><div class='cost'>$(Format-Money ($m * 12) $Totals.Currency)/yr</div></div>"
}) -join "`n")
</div>

<h2>What it costs, by category$(if ($splitOwnership) { ' &mdash; excluding Commvault' })</h2>
<p class="sub">Where the money goes, and how much of it is actually available. <b>In scope</b> is what <code>-Delete</code> would remove on this run; <b>Opt in</b> needs naming in <code>-DeleteScope</code>; <b>Never</b> is not deletable at all (Azure Backup, Site Recovery, keep-tags and locks live here).</p>
<div class="scroll"><table class="cost">
  <thead><tr>
    <th scope="col">Category</th><th scope="col" class="num">Snapshots</th><th scope="col" class="num">Capacity</th>
    <th scope="col" class="num">Per month</th><th scope="col" class="num">Per year</th>
    <th scope="col">Share of spend</th><th scope="col">Deletable</th>
  </tr></thead>
  <tbody>
$costRows
$costTotalRow
  </tbody>
</table></div>

<h2>Cost by category and age$(if ($splitOwnership) { ' &mdash; excluding Commvault' })</h2>
<p class="sub">Annual cost, with the snapshot count beneath each figure; stronger colour means more money. The bottom row is the cost of each age range across all categories. Hover a cell for its capacity.</p>
<div class="scroll"><table class="heat">
  <thead><tr><th scope="col">Category</th>
      $bandHeads
      <th scope="col">Total</th></tr></thead>
  <tbody>
$($heatRows -join "`n")
  <tr class="bandtot">
    <th scope="row">All categories</th>
      $bandTotals
    <td class="tot">$(Format-MoneyCell $grandAnnual $Totals.Currency)<span class="cn">$($focus.Count)</span></td>
  </tr>
  </tbody>
</table></div>
<div class="legend"><span>Less</span>
$((1..7 | ForEach-Object { "<span class='sw r$_'></span>" }) -join '')
<span>More cost</span></div>

<h2>In scope for deletion &mdash; $($deleteRows.Count) snapshot(s), $(Format-Gib $deleteGib)</h2>
<p class="sub">Exactly what <code>-Delete</code> would remove on this run. This is the set written to the candidates CSV.</p>
$deleteTable

<h2>Held back for review &mdash; $($reviewRows.Count) snapshot(s), $(Format-Gib $reviewGib)</h2>
<p class="sub">Candidates that did not clear the age bar, or whose category is not in <code>-DeleteScope</code>. Widen the scope or lower a bar to act on these.</p>
$reviewTable

$(if ($Schema.ScopeProperties) {
  ($Schema.ScopeProperties | ForEach-Object {
    $sp = $_
    $values = $focus | ForEach-Object { [string]$_.($sp.Prop) } | Where-Object { $_ } | Sort-Object -Unique
    # A single-valued breakdown is just the total again, so only show it when it says something.
    if (@($values).Count -lt 2) { return }
    $rows = ($values | ForEach-Object {
        $v = $_
        $set = @($focus | Where-Object { [string]$_.($sp.Prop) -eq $v })
        $m = [double](($set | Measure-Object EstMonthlyCost -Sum).Sum)
        $gib = [math]::Round([double](($set | Measure-Object SizeGiB -Sum).Sum), 2)
        $del = @($set | Where-Object { $_.Action -eq 'Delete' })
        $delM = [double](($del | Measure-Object EstAnnualCost -Sum).Sum)
        $share = if ($totalMonthly -gt 0) { [math]::Round(($m / $totalMonthly) * 100, 1) } else { 0 }
        "<tr><th scope='row'>$([System.Web.HttpUtility]::HtmlEncode($v))</th><td class='num'>$($set.Count)</td><td class='num'>$(Format-Gib $gib)</td><td class='num'>$(Format-Money $m $Totals.Currency)</td><td class='num strong'>$(Format-Money ($m * 12) $Totals.Currency)</td><td class='share'><span class='track'><span class='bar' style='width:$([math]::Min($share,100))%'></span></span><span class='pct'>$share%</span></td><td class='num'>$(Format-Money $delM $Totals.Currency)</td></tr>"
      } | Sort-Object) -join "`n"
    @"
<h2>By $($sp.Label.ToLower()) &mdash; excluding Commvault</h2>
<p class="sub">Where the reclaimable spend sits. The last column is what is in scope to delete today.</p>
<div class="scroll"><table class="cost">
  <thead><tr><th scope="col">$($sp.Label)</th><th scope="col" class="num">Snapshots</th><th scope="col" class="num">Capacity</th>
    <th scope="col" class="num">Per month</th><th scope="col" class="num">Per year</th>
    <th scope="col">Share of spend</th><th scope="col" class="num">In scope /yr</th></tr></thead>
  <tbody>
$rows
  </tbody></table></div>
"@
  }) -join "`n"
})

<h2>By creator &mdash; the whole estate</h2>
<p class="sub">Every snapshot found, Commvault included, so the split above is visible in full. Commvault snapshots are identified from the markers Commvault writes onto the snapshot itself.</p>
<div class="scroll"><table><thead><tr><th scope="col">Creator</th><th scope="col" class="num">Count</th><th scope="col" class="num">Capacity</th></tr></thead>
<tbody>
$byCreator
</tbody></table></div>

<div class="note">
<b>Before deleting:</b> check the creator table above. Commvault snapshot naming varies by agent, version and
IntelliSnap configuration, so verify every Commvault-owned snapshot is classified as <b>Commvault</b> and not as
cloud-native. Widen <code>-CommvaultNamePattern</code> / <code>-CommvaultTagKey</code> if any are misclassified.
<br><br>
<b>SourceUnattached and SourceActive are not orphans.</b> Their disk or volume still exists &mdash; for SourceUnattached the
machine it belonged to has gone but the disk was left behind, for SourceActive it is still attached and running. Both are
reported because they bill and get forgotten, not because they are safe to delete. They enter the deletion scope only when
named explicitly in <code>-DeleteScope</code>, and then only past the $($Totals.SourceActiveMinAgeDays) day bar.
<br><br>
<b>Cost is an estimate</b> at $($Totals.Currency) $($Totals.PricePerGiBMonth) per GiB/month against provisioned size.
$($Schema.CostCaveat) Treat it as a way to prioritise, not a forecast.
</div>

</div></body></html>
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
$candidateCsv = Join-Path $OutputPath "Azure_Snapshots_Candidates_$timestamp.csv"
$deletedCsv = Join-Path $OutputPath "Azure_Snapshots_Deleted_$timestamp.csv"
$htmlPath = Join-Path $OutputPath "Azure_Snapshot_Report_$timestamp.html"

$results = [System.Collections.Generic.List[object]]::new()

if ($DeleteFromReport) {
  #--- Approved-report mode: trust the reviewed CSV, re-verify each snapshot still exists ---
  if (-not (Test-Path $DeleteFromReport)) {
    Write-Host "[ERROR] Report file not found: $DeleteFromReport" -ForegroundColor Red
    exit 1
  }
  Write-Host "[INFO] Loading approved deletion list from $DeleteFromReport" -ForegroundColor Cyan
  foreach ($row in (Import-Csv -Path $DeleteFromReport)) {
    # A category the script never deletes must not become deletable by hand-editing the CSV.
    if ($row.Category -in @('Protected', 'InUse')) {
      Write-Host "[WARN] Skipping $($row.Name): category '$($row.Category)' is never deletable." -ForegroundColor Yellow
      continue
    }
    $results.Add([pscustomobject]@{
        SubscriptionName  = $row.SubscriptionName
        SubscriptionId    = $row.SubscriptionId
        ResourceGroupName = $row.ResourceGroupName
        Name              = $row.Name
        Location          = $row.Location
        SizeGiB           = [double]($row.SizeGiB)
        Currency          = $row.Currency
        EstMonthlyCost    = [double]($row.EstMonthlyCost)
        EstAnnualCost     = [double]($row.EstAnnualCost)
        Incremental       = $row.Incremental
        AgeDays           = [double]($row.AgeDays)
        AgeBand           = $row.AgeBand
        Creator           = $row.Creator
        Ownership         = $row.Ownership
        Category          = $row.Category
        Action            = 'Delete'
        Reason            = $row.Reason
        ActionNote        = 'Approved in report file'
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
    # id -> is that disk attached to a VM. A disk with no ManagedBy is a disk whose VM has gone,
    # which makes its snapshots far more interesting than ones behind a running machine.
    # A PowerShell hashtable is case-insensitive by default, which is what resource ids need.
    $diskAttached = @{}
    try {
      foreach ($d in (Get-AzDisk -ErrorAction Stop)) {
        $diskAttached[$d.Id] = -not [string]::IsNullOrWhiteSpace($d.ManagedBy)
      }
    } catch {
      Write-Host "[WARN] Cannot list managed disks in $($sub.Name); orphan detection skipped here: $($_.Exception.Message)" -ForegroundColor Yellow
      continue
    }

    $imageSnapIds = Get-ImageReferencedSnapshotIds
    $lockScopes = Get-LockedResourceIds

    $unattachedCount = @($diskAttached.Values | Where-Object { -not $_ }).Count
    Write-Host "[INFO]   $($snapshots.Count) snapshot(s), $($diskAttached.Count) managed disk(s) ($unattachedCount unattached), $($imageSnapIds.Count) image-referenced snapshot(s)" -ForegroundColor Gray

    foreach ($snap in $snapshots) {
      if (-not (Test-ResourceGroupFilter -ResourceGroupName $snap.ResourceGroupName -Filters $ResourceGroups)) { continue }

      $sourceId = $snap.CreationData.SourceResourceId
      $hasSourceRef = -not [string]::IsNullOrWhiteSpace($sourceId)
      # Only a managed-disk source can be checked against the disk inventory. A snapshot-of-a-snapshot
      # or an imported blob gives us nothing to verify, and is handled as "cannot confirm".
      $isDiskSource = $hasSourceRef -and ($sourceId -match '/providers/Microsoft\.Compute/disks/')
      $sourceExists = $isDiskSource -and $diskAttached.ContainsKey($sourceId)
      $sourceAttached = $sourceExists -and $diskAttached[$sourceId]

      $creator = Get-AzSnapshotCreator -Name $snap.Name -ResourceGroupName $snap.ResourceGroupName -Tags $snap.Tags `
        -CommvaultNamePattern $CommvaultNamePattern -CommvaultTagKey $CommvaultTagKey

      $creatorExcluded = switch ($creator) {
        'Commvault' { -not $IncludeCommvaultSnapshots }
        'AzureBackup' { -not $IncludeBackupServiceSnapshots }
        'SiteRecovery' { -not $IncludeBackupServiceSnapshots }
        default { $false }
      }

      $ageDays = if ($snap.TimeCreated) { (New-TimeSpan -Start $snap.TimeCreated -End (Get-Date)).TotalDays } else { 0 }

      $isLocked = Test-IsLocked -SnapshotId $snap.Id -LockScopes $lockScopes

      $cat = Get-SnapshotCategory `
        -SourceExists $sourceExists `
        -SourceAttached $sourceAttached `
        -HasSourceReference $isDiskSource `
        -ReferencedByImage ($imageSnapIds.Contains($snap.Id)) `
        -HasKeepTag (Test-TagKeyPresent -Tags $snap.Tags -Keys $KeepTagKey) `
        -IsPinned $isLocked `
        -PinnedReason 'Protected by a resource lock' `
        -Creator $creator `
        -CreatorExcluded $creatorExcluded

      $act = Get-SnapshotAction `
        -Category $cat.Category `
        -AgeDays $ageDays `
        -DeleteScope $DeleteScope `
        -MinAgeDays $MinAgeDays `
        -SourceActiveMinAgeDays $SourceActiveMinAgeDays

      $snapMonthly = Get-SnapshotMonthlyCost -SizeGiB ([double]$snap.DiskSizeGB) -Tier $snap.Sku.Name `
        -PriceTable $PriceTable -DefaultPrice $PricePerGiBMonth

      $tagString = if ($snap.Tags) { (($snap.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ') } else { '' }

      $results.Add([pscustomobject]@{
          SubscriptionName  = $sub.Name
          SubscriptionId    = $sub.Id
          ResourceGroupName = $snap.ResourceGroupName
          Name              = $snap.Name
          Location          = $snap.Location
          SizeGiB           = [double]$snap.DiskSizeGB
          Currency          = $Currency
          EstMonthlyCost    = $snapMonthly
          EstAnnualCost     = [math]::Round($snapMonthly * 12, 2)
          Incremental       = [bool]$snap.Incremental
          SkuName           = $snap.Sku.Name
          TimeCreated       = $snap.TimeCreated
          AgeDays           = [math]::Round($ageDays, 1)
          AgeBand           = Get-AgeBand -AgeDays $ageDays
          SourceResourceId  = $sourceId
          SourceExists      = $sourceExists
          SourceAttached    = $sourceAttached
          ReferencedByImage = $imageSnapIds.Contains($snap.Id)
          # Commvault writes its job details into a Description tag; surfacing it as a column lets
          # -AuditCreatorEvidence template it alongside AWS's native description field.
          Description       = $(if ($snap.Tags -and $snap.Tags['Description']) { $snap.Tags['Description'] } else { '' })
          Creator           = $creator
          Ownership         = Get-SnapshotOwnership -Creator $creator
          Category          = $cat.Category
          Action            = $act.Action
          Reason            = $cat.Reason
          ActionNote        = $act.Note
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
$toDelete = @($results | Where-Object { $_.Action -eq 'Delete' })
$toReview = @($results | Where-Object { $_.Action -eq 'Review' })
$deleteGiB = [math]::Round((($toDelete | Measure-Object SizeGiB -Sum).Sum), 2)
$deleteMonthly = [math]::Round([double](($toDelete | Measure-Object EstMonthlyCost -Sum).Sum), 2)
$estateMonthly = [math]::Round([double](($results | Measure-Object EstMonthlyCost -Sum).Sum), 2)

$totals = @{
  DeleteMode             = $Delete.IsPresent
  DeleteScope            = $DeleteScope
  MinAgeDays             = $MinAgeDays
  SourceActiveMinAgeDays = $SourceActiveMinAgeDays
  PricePerGiBMonth       = $PricePerGiBMonth
  Currency               = $Currency
}

if (-not $DeleteFromReport) {
# Column order for the per-snapshot CSVs. What you filter and sort on comes first, then the money,
# then the evidence behind the verdict, then the identifiers you only need when acting on a row.
$snapshotColumns = @(
  'SubscriptionName', 'ResourceGroupName', 'Location', 'Name',
  'Ownership', 'Creator', 'Category', 'Action',
  'AgeBand', 'AgeDays', 'TimeCreated',
  'SizeGiB', 'Currency', 'EstMonthlyCost', 'EstAnnualCost',
  'SourceExists', 'SourceAttached', 'ReferencedByImage',
  'Reason', 'ActionNote',
  'SkuName', 'Incremental', 'Tags', 'Description',
  'SourceResourceId', 'SubscriptionId', 'Id'
)

  # -WhatIf:$false so a dry run still produces its reports; only the deletions are simulated.
  $results | Select-Object $snapshotColumns | Export-Csv -Path $allCsv -NoTypeInformation -WhatIf:$false
  Write-Host "[INFO] Full classification written to $allCsv" -ForegroundColor Green

  $toDelete | Select-Object $snapshotColumns | Export-Csv -Path $candidateCsv -NoTypeInformation -WhatIf:$false
$azureScopes = @(
  @{ Label = 'Subscription'; Prop = 'SubscriptionName' }
  @{ Label = 'Region'; Prop = 'Location' }
  @{ Label = 'Resource group'; Prop = 'ResourceGroupName' }
)
  New-HtmlReport -Rows $results -Path $htmlPath -Totals $totals -Schema @{
    Title       = 'Azure Snapshot Report'
    ScopeProperties = $azureScopes
    # Commvault's Azure marker is definitive, so the two populations can be separated honestly.
    SplitByOwnership = $true
    CostCaveat  = 'Incremental snapshots bill on consumed delta, so the real saving for those is lower.'
    Columns     = @(
      @{ Label = 'Subscription'; Prop = 'SubscriptionName' }
      @{ Label = 'Resource group'; Prop = 'ResourceGroupName' }
      @{ Label = 'Snapshot'; Prop = 'Name' }
      @{ Label = 'Region'; Prop = 'Location' }
      @{ Label = 'GiB'; Prop = 'SizeGiB'; Numeric = $true }
      @{ Label = 'Annual cost'; Prop = 'EstAnnualCost'; Numeric = $true; Money = $true }
      @{ Label = 'Age (days)'; Prop = 'AgeDays'; Numeric = $true }
      @{ Label = 'Creator'; Prop = 'Creator' }
    )
  }
  Write-Host "[INFO] HTML report written to $htmlPath" -ForegroundColor Green

  $costCsv = Join-Path $OutputPath "Azure_Cost_Summary_$timestamp.csv"
  Get-CostSummary -Rows $results -Currency $Currency -ScopeProperties $azureScopes |
    Export-Csv -Path $costCsv -NoTypeInformation -WhatIf:$false
  Write-Host "[INFO] Cost summary written to $costCsv" -ForegroundColor Green

  if ($AuditCreatorEvidence) {
    $evidenceCsv = Join-Path $OutputPath "Azure_Creator_Evidence_$timestamp.csv"
    Get-CreatorEvidence -Rows $results | Export-Csv -Path $evidenceCsv -NoTypeInformation -WhatIf:$false
    Write-Host "[INFO] Naming and tagging evidence written to $evidenceCsv" -ForegroundColor Green
  }
}

$summaryFiles = @()
if (-not $DeleteFromReport) { $summaryFiles = @($allCsv, $candidateCsv, $costCsv, $htmlPath) }
if ($AuditCreatorEvidence -and -not $DeleteFromReport) { $summaryFiles += $evidenceCsv }

$nextStep = if (-not $Delete -and $toDelete.Count -gt 0) {
  "Review $candidateCsv, remove any rows to keep, then: .\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport '<that file>' -Delete"
} elseif (-not $Delete) {
  'Nothing is in scope to delete. Widen -DeleteScope or lower an age bar to act on the review list.'
} else { '' }

Write-RunSummary -Rows $results -ToDelete $toDelete -ToReview $toReview -DeleteScope $DeleteScope `
  -Currency $Currency -Files $summaryFiles -NextStep $nextStep

#----------------------------
# Delete
#----------------------------
if (-not $Delete) { return }

if ($toDelete.Count -eq 0) {
  Write-Host "[INFO] Nothing in scope to delete." -ForegroundColor Green
  return
}

# A delete run is the last point at which a detection failure is still recoverable. Check it here,
# not during the report - reporting a wrong classification costs nothing, acting on one does.
if (-not $DeleteFromReport) {
  $guard = Test-CommvaultDetection `
    -CommvaultCount (@($results | Where-Object { $_.Creator -eq 'Commvault' }).Count) `
    -TotalCount $results.Count `
    -Acknowledged $AcknowledgeNoCommvaultSnapshots.IsPresent
  if (-not $guard.Proceed) {
    Write-Host "`n[ABORT] $($guard.Message)" -ForegroundColor Red
    exit 2
  }
  if ($guard.Message) { Write-Host "[WARN] $($guard.Message)" -ForegroundColor Yellow }
}

if (-not $Force -and -not $WhatIfPreference) {
  Write-Host "`n[WARN] About to permanently delete $($toDelete.Count) snapshot(s), $($deleteGiB.ToString('N0')) GiB, worth $(Format-Money -Amount ($deleteMonthly * 12) -Currency $Currency)/year." -ForegroundColor Yellow
  Write-Host "[WARN] Categories in scope: $(($toDelete | Group-Object Category | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')" -ForegroundColor Yellow
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

foreach ($o in ($toDelete | Sort-Object SubscriptionId, ResourceGroupName, Name)) {
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

  $target = "$($o.ResourceGroupName)/$($o.Name) ($($o.SizeGiB) GiB, $($o.Category))"
  if ($PSCmdlet.ShouldProcess($target, 'Remove-AzSnapshot')) {
    try {
      Remove-AzSnapshot -ResourceGroupName $o.ResourceGroupName -SnapshotName $o.Name -Force -ErrorAction Stop | Out-Null
      $deleted++
      Write-Host "[DELETED] $target" -ForegroundColor Magenta
      $deleteLog.Add([pscustomobject]@{ Timestamp = (Get-Date); SubscriptionName = $o.SubscriptionName; ResourceGroupName = $o.ResourceGroupName; Location = $o.Location; Name = $o.Name; SizeGiB = $o.SizeGiB; Category = $o.Category; Currency = $Currency; EstMonthlyCost = $o.EstMonthlyCost; EstAnnualCost = $o.EstAnnualCost; Status = 'Deleted'; Error = '' })
    } catch {
      $failed++
      Write-Host "[ERROR] Failed to delete $target : $($_.Exception.Message)" -ForegroundColor Red
      $deleteLog.Add([pscustomobject]@{ Timestamp = (Get-Date); SubscriptionName = $o.SubscriptionName; ResourceGroupName = $o.ResourceGroupName; Location = $o.Location; Name = $o.Name; SizeGiB = $o.SizeGiB; Category = $o.Category; Currency = $Currency; EstMonthlyCost = $o.EstMonthlyCost; EstAnnualCost = $o.EstAnnualCost; Status = 'Failed'; Error = $_.Exception.Message })
    }
  }
}

if ($deleteLog.Count -gt 0) {
  $deleteLog | Export-Csv -Path $deletedCsv -NoTypeInformation -WhatIf:$false
  $summaryFiles += $deletedCsv
}

# Print the summary again now the work is done, so the last thing on screen is the outcome rather
# than a scroll of per-snapshot delete lines.
$gone = @($deleteLog | Where-Object { $_.Status -eq 'Deleted' })
Write-RunSummary -Rows $results -ToDelete $toDelete -ToReview $toReview -DeleteScope $DeleteScope `
  -Currency $Currency -Files $summaryFiles -DeleteResult @{
  Deleted = $deleted
  Failed  = $failed
  GiB     = [math]::Round([double](($gone | Measure-Object SizeGiB -Sum).Sum), 2)
  Monthly = [math]::Round([double](($gone | Measure-Object EstMonthlyCost -Sum).Sum), 2)
}
