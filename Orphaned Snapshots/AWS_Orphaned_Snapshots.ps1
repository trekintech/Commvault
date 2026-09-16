#requires -Version 7.0

<#
.SYNOPSIS
Reports and optionally deletes orphaned cloud-native AWS snapshots — snapshots that were NOT created by Commvault.

.DESCRIPTION
The classic AWS snapshot leak is the deregistered AMI: deregistering an image does not delete the EBS
snapshots behind it, and those snapshots then bill forever with nothing pointing at them. Deleted
volumes leave the same residue. This script finds both, across every region and account you point it
at, and removes them on request.

Covers
- EBS snapshots owned by the account (always)
- RDS manual DB and DB cluster snapshots (-IncludeRdsSnapshots)

Scope of "orphaned" for EBS
- The source volume no longer exists (the default, strongest signal), AND
- no AMI — registered or not — references the snapshot in its block device mappings, AND
- the snapshot is older than -MinAgeDays, AND
- it carries no keep-tag, and is not shared with another account (checked with -CheckSharing).

Optionally (-TreatOldSnapshotsAsOrphaned) snapshots whose source volume still exists but which are
older than -MaxAgeDays are flagged too, under a separate verdict.

Scope of "cloud-native" (i.e. what this script deliberately leaves alone)
- Commvault-created snapshots    -> matched by name/description regex or tag (see -CommvaultNamePattern, -CommvaultTagKey)
- AWS Backup-created snapshots   -> tag aws:backup:source-resource
- DLM lifecycle-managed          -> tag aws:dlm:lifecycle-policy-id / dlm:managed
- AWS-managed / marketplace      -> owner alias amazon, or snapshots not owned by this account
DLM and AWS Backup already expire their own snapshots on a schedule; deleting them out from under the
policy breaks the recovery point and the policy will just make another. They are reported, not deleted.

IMPORTANT — verify the Commvault detection patterns against your own environment before deleting
anything. Commvault's snapshot naming and tagging varies by agent, version and IntelliSnap
configuration. Run in report mode first, open the classification CSV, and confirm every snapshot you
expect Commvault to own is classified as "Commvault". Adjust -CommvaultNamePattern /
-CommvaultTagKey until it is.

Safety model
- Report-only by default. Nothing is deleted unless -Delete is supplied.
- -Delete honours -WhatIf and -Confirm, and refuses to run unattended without -Force.
- -MaxDeletions caps a single run.
- -DeleteFromReport <csv> re-reads an approved CSV so an admin can review the report, delete the rows
  they want to keep, and feed the file back for execution. This is the recommended workflow.

Outputs (written to -OutputPath)
- AWS_Snapshots_All_<timestamp>.csv           every snapshot found, with its classification and verdict
- AWS_Snapshots_Orphaned_<timestamp>.csv      orphan candidates only (the file to feed to -DeleteFromReport)
- AWS_Snapshots_Deleted_<timestamp>.csv       deletion log, written only when -Delete runs
- AWS_Orphaned_Snapshots_<timestamp>.html     summary report

.EXAMPLE
.\AWS_Orphaned_Snapshots.ps1
Report across every enabled region using the default credential chain. Deletes nothing.

.EXAMPLE
.\AWS_Orphaned_Snapshots.ps1 -Region eu-west-1,us-east-1 -MinAgeDays 90 -IncludeRdsSnapshots
Report on EBS and manual RDS snapshots at least 90 days old in two regions.

.EXAMPLE
.\AWS_Orphaned_Snapshots.ps1 -ProfileName prod,dev -Delete -WhatIf
Show exactly what would be deleted across two accounts, without deleting it.

.EXAMPLE
.\AWS_Orphaned_Snapshots.ps1 -DeleteFromReport .\AWS_Snapshots_Orphaned_20260916-101500.csv -Delete -Force
Delete precisely the snapshots left in an approved report file.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
  # Regions to scan. Default: every region enabled for the account.
  [string[]]$Region,

  # Named credential profiles to iterate. Default: the ambient credential chain (one account).
  [string[]]$ProfileName,

  # Only consider snapshots at least this old. Guards against deleting a snapshot taken minutes ago.
  [ValidateRange(0, 3650)]
  [int]$MinAgeDays = 30,

  # With -TreatOldSnapshotsAsOrphaned, also flag snapshots older than this whose source volume still exists.
  [ValidateRange(1, 3650)]
  [int]$MaxAgeDays = 365,
  [switch]$TreatOldSnapshotsAsOrphaned,

  [switch]$IncludeRdsSnapshots,

  # Regex patterns identifying Commvault-created snapshots by Name tag or description. Case-insensitive.
  [string[]]$CommvaultNamePattern = @(
    '^CV_',
    '^cvsnap',
    '_CvSnap',
    'commvault',
    '^GX_',
    '_GX_BACKUP_',
    '_GX_AMI_'
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

  # Treat AWS Backup / DLM-managed snapshots as deletion candidates too. Strongly discouraged.
  [switch]$IncludeBackupServiceSnapshots,

  # Any snapshot carrying one of these tag keys is never a deletion candidate.
  [string[]]$KeepTagKey = @('DoNotDelete', 'KeepSnapshot', 'Preserve'),

  # Check each candidate's createVolumePermission. One extra API call per candidate, so it is opt-in;
  # without it, a snapshot shared with another account can still be selected for deletion.
  [switch]$CheckSharing,

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
Write-Host "`n[INFO] AWS Orphaned Snapshot Report v$ScriptVersion" -ForegroundColor Green

#----------------------------
# Module handling
#----------------------------
function Test-RequiredModules {
  $required = @('AWS.Tools.Common', 'AWS.Tools.EC2')
  $needed = @()
  if ($IncludeRdsSnapshots) { $needed += 'AWS.Tools.RDS' }

  $missing = @()
  foreach ($m in $required) { if (-not (Get-Module -ListAvailable -Name $m)) { $missing += $m } }
  foreach ($m in $needed) { if (-not (Get-Module -ListAvailable -Name $m)) { $missing += $m } }

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

  Import-Module AWS.Tools.Common -ErrorAction Stop
  Import-Module AWS.Tools.EC2 -ErrorAction Stop
  if ($IncludeRdsSnapshots) { Import-Module AWS.Tools.RDS -ErrorAction Stop }

  # Only used to label reports with the account id; the scan works without it.
  if (Get-Module -ListAvailable -Name AWS.Tools.SecurityToken) {
    Import-Module AWS.Tools.SecurityToken -ErrorAction SilentlyContinue
  } else {
    Write-Host "[INFO] AWS.Tools.SecurityToken not installed - reports will show account id 'unknown'." -ForegroundColor Yellow
  }
}

#----------------------------
# Pure helpers (unit-testable: no AWS calls)
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

<#
AWS tags arrive as a list of objects with Key/Value properties rather than a dictionary, so the Azure
helpers do not transfer. Converts that list to a hashtable once, for everything downstream.
#>
function ConvertTo-TagHashtable {
  param($Tags)
  $ht = @{}
  if ($null -eq $Tags) { return $ht }
  foreach ($t in $Tags) {
    if ($null -ne $t.Key) { $ht[[string]$t.Key] = [string]$t.Value }
  }
  return $ht
}

function Test-TagMatch {
  param(
    [hashtable]$Tags,
    [string[]]$Patterns
  )
  if ($null -eq $Tags -or $Tags.Count -eq 0) { return $false }
  foreach ($key in $Tags.Keys) {
    if (Test-MatchAnyPattern -Value ([string]$key) -Patterns $Patterns) { return $true }
    if (Test-MatchAnyPattern -Value ([string]$Tags[$key]) -Patterns $Patterns) { return $true }
  }
  return $false
}

function Test-TagKeyPresent {
  param(
    [hashtable]$Tags,
    [string[]]$Keys
  )
  if ($null -eq $Tags -or $Tags.Count -eq 0) { return $false }
  foreach ($key in $Tags.Keys) {
    foreach ($k in $Keys) {
      if ([string]$key -ieq $k) { return $true }
    }
  }
  return $false
}

<#
Classifies which product created a snapshot. Returns one of:
  Commvault | AwsBackup | DlmManaged | AwsManaged | CloudNative
Only CloudNative snapshots are ever deletion candidates by default.
#>
function Get-AwsSnapshotCreator {
  param(
    [string]$Description,
    [hashtable]$Tags,
    [string]$OwnerAlias,
    [string[]]$CommvaultNamePattern,
    [string[]]$CommvaultTagKey
  )

  $nameTag = if ($Tags -and $Tags.ContainsKey('Name')) { [string]$Tags['Name'] } else { '' }

  if (Test-MatchAnyPattern -Value $nameTag -Patterns $CommvaultNamePattern) { return 'Commvault' }
  if (Test-MatchAnyPattern -Value $Description -Patterns $CommvaultNamePattern) { return 'Commvault' }
  if (Test-TagMatch -Tags $Tags -Patterns $CommvaultTagKey) { return 'Commvault' }

  # AWS Backup stamps its recovery points with reserved aws:backup: tags.
  if ($Tags) {
    foreach ($key in $Tags.Keys) {
      if ([string]$key -like 'aws:backup:*') { return 'AwsBackup' }
    }
    foreach ($key in $Tags.Keys) {
      if ([string]$key -like 'aws:dlm:*' -or [string]$key -ieq 'dlm:managed') { return 'DlmManaged' }
    }
  }
  if ($Description -match 'Created for policy: policy-') { return 'DlmManaged' }
  if ($Description -match '^AWS Backup service') { return 'AwsBackup' }

  if ($OwnerAlias -and $OwnerAlias -in @('amazon', 'aws-marketplace')) { return 'AwsManaged' }

  return 'CloudNative'
}

<#
Applies the orphan rules to one already-gathered snapshot fact set and returns the verdict plus the
reasons behind it. Kept free of AWS calls so the decision logic can be tested directly.

Verdict is one of:
  Orphaned        source volume is gone and every safety check passed
  StaleButInUse   source volume still exists but the snapshot exceeds -MaxAgeDays (-TreatOldSnapshotsAsOrphaned)
  Retain          anything else
#>
function Get-SnapshotVerdict {
  param(
    [bool]$SourceVolumeExists,
    [bool]$HasSourceVolumeReference,
    [double]$AgeDays,
    [bool]$ReferencedByImage,
    [bool]$HasKeepTag,
    [bool]$IsShared,
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
  if ($IsShared) {
    $reasons.Add('Shared with another account via createVolumePermission')
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }
  if ($ReferencedByImage) {
    $reasons.Add('Referenced by an AMI block device mapping')
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }
  if ($AgeDays -lt $MinAgeDays) {
    $reasons.Add("Younger than MinAgeDays ($([math]::Round($AgeDays,1)) < $MinAgeDays)")
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }

  if (-not $HasSourceVolumeReference) {
    # No VolumeId recorded (e.g. an import/copy). Cannot prove the source is gone.
    $reasons.Add('No source volume reference recorded - cannot confirm orphan status')
    if ($TreatOldSnapshotsAsOrphaned -and $AgeDays -ge $MaxAgeDays) {
      $reasons.Add("Older than MaxAgeDays ($([math]::Round($AgeDays,1)) >= $MaxAgeDays)")
      return [pscustomobject]@{ Verdict = 'StaleButInUse'; Reason = ($reasons -join '; ') }
    }
    return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
  }

  if (-not $SourceVolumeExists) {
    $reasons.Add('Source EBS volume no longer exists')
    $reasons.Add("Age $([math]::Round($AgeDays,1)) days >= MinAgeDays $MinAgeDays")
    return [pscustomobject]@{ Verdict = 'Orphaned'; Reason = ($reasons -join '; ') }
  }

  if ($TreatOldSnapshotsAsOrphaned -and $AgeDays -ge $MaxAgeDays) {
    $reasons.Add("Source volume still exists but snapshot is older than MaxAgeDays ($([math]::Round($AgeDays,1)) >= $MaxAgeDays)")
    return [pscustomobject]@{ Verdict = 'StaleButInUse'; Reason = ($reasons -join '; ') }
  }

  $reasons.Add('Source EBS volume still exists')
  return [pscustomobject]@{ Verdict = 'Retain'; Reason = ($reasons -join '; ') }
}

<#
AWS records a snapshot's source volume as "vol-xxxx" for a real volume, but as "vol-ffffffff" (the
sentinel AWS uses for a snapshot with no live volume behind it) for AMI-backing and copied snapshots.
Treat the sentinel as "no reference" so it is never mistaken for a deleted volume.
#>
function Test-HasRealVolumeReference {
  param([string]$VolumeId)
  if ([string]::IsNullOrWhiteSpace($VolumeId)) { return $false }
  if ($VolumeId -match '^vol-f+$') { return $false }
  if ($VolumeId -notmatch '^vol-') { return $false }
  return $true
}

#----------------------------
# AWS gathering
#----------------------------
function Get-TargetRegions {
  param([hashtable]$CredArgs)

  if ($Region -and $Region.Count -gt 0) { return $Region }

  try {
    return (Get-EC2Region @CredArgs -ErrorAction Stop | Select-Object -ExpandProperty RegionName)
  } catch {
    Write-Host "[ERROR] Could not enumerate regions: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        Pass -Region explicitly, or check your credentials." -ForegroundColor Yellow
    return @()
  }
}

<#
Every snapshot id referenced by an AMI's block device mappings, in one region. A snapshot behind a
registered AMI is in use no matter how long ago its volume disappeared. Deregistered AMIs are gone
from this list, which is exactly why their snapshots show up as orphans.
#>
function Get-ImageReferencedSnapshotIds {
  param([hashtable]$CredArgs)

  $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  try {
    foreach ($image in (Get-EC2Image -Owner self @CredArgs -ErrorAction Stop)) {
      foreach ($bdm in $image.BlockDeviceMappings) {
        if ($bdm.Ebs -and $bdm.Ebs.SnapshotId) { [void]$ids.Add($bdm.Ebs.SnapshotId) }
      }
    }
  } catch {
    Write-Host "[WARN] Could not enumerate AMIs: $($_.Exception.Message)" -ForegroundColor Yellow
  }
  return $ids
}

function Test-SnapshotShared {
  param(
    [string]$SnapshotId,
    [hashtable]$CredArgs
  )
  try {
    $attr = Get-EC2SnapshotAttribute -SnapshotId $SnapshotId -Attribute createVolumePermission @CredArgs -ErrorAction Stop
    return ($null -ne $attr.CreateVolumePermissions -and $attr.CreateVolumePermissions.Count -gt 0)
  } catch {
    Write-Host "[WARN] Could not read sharing attribute for $SnapshotId : $($_.Exception.Message)" -ForegroundColor Yellow
    # Unknown sharing state is treated as shared, so an unreadable snapshot is never auto-deleted.
    return $true
  }
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

  $candidates = $Rows | Where-Object { $_.Verdict -in @('Orphaned', 'StaleButInUse') } | Sort-Object -Property @{Expression = 'SizeGiB'; Descending = $true }

  $rowHtml = ($candidates | ForEach-Object {
      $cls = switch ($_.Verdict) { 'Orphaned' { 'orphan' } 'StaleButInUse' { 'stale' } default { 'retain' } }
      "<tr><td>$([System.Web.HttpUtility]::HtmlEncode($_.AccountId))</td><td>$($_.Region)</td><td>$($_.SnapshotType)</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.SnapshotId))</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Name))</td><td>$($_.SizeGiB)</td><td>$($_.AgeDays)</td><td>$($_.Creator)</td><td class='$cls'>$($_.Verdict)</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Reason))</td></tr>"
    }) -join "`n"

  if ([string]::IsNullOrWhiteSpace($rowHtml)) {
    $rowHtml = "<tr><td colspan='10'>No orphan candidates found.</td></tr>"
  }

  $byCreator = ($Rows | Group-Object Creator | Sort-Object Count -Descending | ForEach-Object {
      $gib = [math]::Round((($_.Group | Measure-Object SizeGiB -Sum).Sum), 2)
      "<tr><td>$($_.Name)</td><td>$($_.Count)</td><td>$gib</td></tr>"
    }) -join "`n"

  $byRegion = ($Rows | Group-Object Region | Sort-Object Name | ForEach-Object {
      $orph = @($_.Group | Where-Object { $_.Verdict -in @('Orphaned', 'StaleButInUse') })
      $gib = [math]::Round((($orph | Measure-Object SizeGiB -Sum).Sum), 2)
      "<tr><td>$($_.Name)</td><td>$($_.Count)</td><td>$($orph.Count)</td><td>$gib</td></tr>"
    }) -join "`n"

  $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>AWS Orphaned Snapshots</title>$style</head>
<body>
<h1>AWS Orphaned Snapshot Report</h1>
<div class="meta">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &middot; script v$ScriptVersion &middot; MinAgeDays $MinAgeDays &middot; MaxAgeDays $MaxAgeDays &middot; mode: $(if ($Delete) { 'DELETE' } else { 'REPORT ONLY' })</div>
$cards
<h2>Snapshots by creator</h2>
<table><thead><tr><th>Creator</th><th>Count</th><th>GiB</th></tr></thead><tbody>
$byCreator
</tbody></table>
<h2>Snapshots by region</h2>
<table><thead><tr><th>Region</th><th>Total</th><th>Orphan candidates</th><th>Reclaimable GiB</th></tr></thead><tbody>
$byRegion
</tbody></table>
<h2>Orphan candidates</h2>
<table><thead><tr><th>Account</th><th>Region</th><th>Type</th><th>Snapshot</th><th>Name</th><th>GiB</th><th>Age (days)</th><th>Creator</th><th>Verdict</th><th>Reason</th></tr></thead><tbody>
$rowHtml
</tbody></table>
<div class="note">
<strong>Before deleting:</strong> confirm that every Commvault-owned snapshot is classified as <em>Commvault</em> in the
classification CSV. Commvault snapshot naming varies by agent and IntelliSnap configuration &mdash; adjust
<code>-CommvaultNamePattern</code> and <code>-CommvaultTagKey</code> if any are misclassified as cloud-native.
Cost figures are an estimate at $($Totals.Currency) $PricePerGiBMonth per GiB/month against <em>volume</em> size;
EBS snapshots bill on changed blocks, so the real saving will usually be lower.
$(if (-not $CheckSharing) { 'Sharing was not checked &mdash; re-run with <code>-CheckSharing</code> to exclude snapshots shared with other accounts. ' })
<strong>Unverifiable ($($Totals.Unverifiable))</strong> are copied or imported snapshots that record no source volume id
(AWS reports <code>vol-ffffffff</code>), so orphan status cannot be proven from the volume inventory. They are never
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

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$allCsv = Join-Path $OutputPath "AWS_Snapshots_All_$timestamp.csv"
$orphanCsv = Join-Path $OutputPath "AWS_Snapshots_Orphaned_$timestamp.csv"
$deletedCsv = Join-Path $OutputPath "AWS_Snapshots_Deleted_$timestamp.csv"
$htmlPath = Join-Path $OutputPath "AWS_Orphaned_Snapshots_$timestamp.html"

$results = [System.Collections.Generic.List[object]]::new()

if ($DeleteFromReport) {
  #--- Approved-report mode: trust the reviewed CSV ---
  if (-not (Test-Path $DeleteFromReport)) {
    Write-Host "[ERROR] Report file not found: $DeleteFromReport" -ForegroundColor Red
    exit 1
  }
  Write-Host "[INFO] Loading approved deletion list from $DeleteFromReport" -ForegroundColor Cyan
  foreach ($row in (Import-Csv -Path $DeleteFromReport)) {
    $results.Add([pscustomobject]@{
        AccountId    = $row.AccountId
        ProfileUsed  = $row.ProfileUsed
        Region       = $row.Region
        SnapshotType = $row.SnapshotType
        SnapshotId   = $row.SnapshotId
        Name         = $row.Name
        SizeGiB      = [double]($row.SizeGiB)
        AgeDays      = $row.AgeDays
        Creator      = $row.Creator
        Verdict      = $row.Verdict
        Reason       = $row.Reason
      })
  }
} else {
  #--- Discovery mode ---
  $profiles = if ($ProfileName -and $ProfileName.Count -gt 0) { $ProfileName } else { @($null) }

  foreach ($prof in $profiles) {
    $credArgs = @{}
    if ($prof) { $credArgs['ProfileName'] = $prof }
    $profLabel = if ($prof) { $prof } else { '<default credentials>' }

    $accountId = 'unknown'
    try {
      $accountId = (Get-STSCallerIdentity @credArgs -ErrorAction Stop).Account
    } catch {
      Write-Host "[WARN] Could not resolve account id for $profLabel (AWS.Tools.SecurityToken may be missing): $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "[INFO] Account $accountId via $profLabel" -ForegroundColor Cyan

    $regions = @(Get-TargetRegions -CredArgs $credArgs)
    if ($regions.Count -eq 0) { continue }
    Write-Host "[INFO] Scanning $($regions.Count) region(s)" -ForegroundColor Cyan

    $regionIndex = 0
    foreach ($r in $regions) {
      $regionIndex++
      Write-Progress -Activity "Scanning $profLabel" -Status $r -PercentComplete (($regionIndex / [math]::Max($regions.Count, 1)) * 100)
      $regionArgs = $credArgs.Clone()
      $regionArgs['Region'] = $r

      #--- EBS snapshots ---
      try {
        $snapshots = @(Get-EC2Snapshot -OwnerId self @regionArgs -ErrorAction Stop)
      } catch {
        Write-Host "[WARN] Cannot list snapshots in $r : $($_.Exception.Message)" -ForegroundColor Yellow
        continue
      }

      if ($snapshots.Count -eq 0) {
        if ($IncludeRdsSnapshots) { Write-Host "[INFO]   $r : no EBS snapshots" -ForegroundColor Gray }
      } else {
        $volumeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        try {
          foreach ($v in (Get-EC2Volume @regionArgs -ErrorAction Stop)) { [void]$volumeIds.Add($v.VolumeId) }
        } catch {
          Write-Host "[WARN] Cannot list volumes in $r; orphan detection skipped there: $($_.Exception.Message)" -ForegroundColor Yellow
          continue
        }

        $imageSnapIds = Get-ImageReferencedSnapshotIds -CredArgs $regionArgs
        Write-Host "[INFO]   $r : $($snapshots.Count) snapshot(s), $($volumeIds.Count) volume(s), $($imageSnapIds.Count) AMI-referenced" -ForegroundColor Gray

        foreach ($snap in $snapshots) {
          $tags = ConvertTo-TagHashtable -Tags $snap.Tags
          $nameTag = if ($tags.ContainsKey('Name')) { $tags['Name'] } else { '' }

          $creator = Get-AwsSnapshotCreator -Description $snap.Description -Tags $tags -OwnerAlias $snap.OwnerAlias `
            -CommvaultNamePattern $CommvaultNamePattern -CommvaultTagKey $CommvaultTagKey

          $creatorExcluded = switch ($creator) {
            'Commvault' { -not $IncludeCommvaultSnapshots }
            'AwsBackup' { -not $IncludeBackupServiceSnapshots }
            'DlmManaged' { -not $IncludeBackupServiceSnapshots }
            'AwsManaged' { $true }
            default { $false }
          }

          $ageDays = if ($snap.StartTime) { (New-TimeSpan -Start $snap.StartTime -End (Get-Date)).TotalDays } else { 0 }
          $hasVolRef = Test-HasRealVolumeReference -VolumeId $snap.VolumeId
          $volExists = $hasVolRef -and $volumeIds.Contains($snap.VolumeId)
          $referenced = $imageSnapIds.Contains($snap.SnapshotId)
          $hasKeepTag = Test-TagKeyPresent -Tags $tags -Keys $KeepTagKey

          # Only pay for the sharing call on snapshots that would otherwise be deleted.
          $isShared = $false
          if ($CheckSharing -and -not $creatorExcluded -and -not $hasKeepTag -and -not $referenced -and $ageDays -ge $MinAgeDays -and $hasVolRef -and -not $volExists) {
            $isShared = Test-SnapshotShared -SnapshotId $snap.SnapshotId -CredArgs $regionArgs
          }

          $verdict = Get-SnapshotVerdict `
            -SourceVolumeExists $volExists `
            -HasSourceVolumeReference $hasVolRef `
            -AgeDays $ageDays `
            -ReferencedByImage $referenced `
            -HasKeepTag $hasKeepTag `
            -IsShared $isShared `
            -Creator $creator `
            -CreatorExcluded $creatorExcluded `
            -MinAgeDays $MinAgeDays `
            -MaxAgeDays $MaxAgeDays `
            -TreatOldSnapshotsAsOrphaned:$TreatOldSnapshotsAsOrphaned.IsPresent

          $tagString = (($tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')

          $results.Add([pscustomobject]@{
              AccountId         = $accountId
              ProfileUsed       = $profLabel
              Region            = $r
              SnapshotType      = 'EBS'
              SnapshotId        = $snap.SnapshotId
              Name              = $nameTag
              Description       = $snap.Description
              SizeGiB           = [double]$snap.VolumeSize
              StartTime         = $snap.StartTime
              AgeDays           = [math]::Round($ageDays, 1)
              SourceId          = $snap.VolumeId
              SourceExists      = $volExists
              ReferencedByImage = $referenced
              StorageTier       = $snap.StorageTier
              Creator           = $creator
              Verdict           = $verdict.Verdict
              Reason            = $verdict.Reason
              Tags              = $tagString
            })
        }
      }

      #--- RDS manual snapshots ---
      if (-not $IncludeRdsSnapshots) { continue }

      try {
        $liveInstances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($db in (Get-RDSDBInstance @regionArgs -ErrorAction Stop)) { [void]$liveInstances.Add($db.DBInstanceIdentifier) }

        $liveClusters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($cl in (Get-RDSDBCluster @regionArgs -ErrorAction Stop)) { [void]$liveClusters.Add($cl.DBClusterIdentifier) }

        $rdsSets = @(
          @{ Type = 'RDS-Instance'; Items = @(Get-RDSDBSnapshot -SnapshotType manual @regionArgs -ErrorAction Stop); IdProp = 'DBSnapshotIdentifier'; SrcProp = 'DBInstanceIdentifier'; Live = $liveInstances }
          @{ Type = 'RDS-Cluster'; Items = @(Get-RDSDBClusterSnapshot -SnapshotType manual @regionArgs -ErrorAction Stop); IdProp = 'DBClusterSnapshotIdentifier'; SrcProp = 'DBClusterIdentifier'; Live = $liveClusters }
        )

        foreach ($set in $rdsSets) {
          foreach ($rsnap in $set.Items) {
            $tags = ConvertTo-TagHashtable -Tags $rsnap.TagList
            $snapId = $rsnap.($set.IdProp)
            $srcId = $rsnap.($set.SrcProp)

            $creator = Get-AwsSnapshotCreator -Description $snapId -Tags $tags -OwnerAlias '' `
              -CommvaultNamePattern $CommvaultNamePattern -CommvaultTagKey $CommvaultTagKey

            $creatorExcluded = switch ($creator) {
              'Commvault' { -not $IncludeCommvaultSnapshots }
              'AwsBackup' { -not $IncludeBackupServiceSnapshots }
              'DlmManaged' { -not $IncludeBackupServiceSnapshots }
              'AwsManaged' { $true }
              default { $false }
            }

            $created = $rsnap.SnapshotCreateTime
            if (-not $created) { $created = $rsnap.SnapshotCreateTime }
            $ageDays = if ($created) { (New-TimeSpan -Start $created -End (Get-Date)).TotalDays } else { 0 }
            $srcExists = -not [string]::IsNullOrWhiteSpace($srcId) -and $set.Live.Contains($srcId)

            $verdict = Get-SnapshotVerdict `
              -SourceVolumeExists $srcExists `
              -HasSourceVolumeReference (-not [string]::IsNullOrWhiteSpace($srcId)) `
              -AgeDays $ageDays `
              -ReferencedByImage $false `
              -HasKeepTag (Test-TagKeyPresent -Tags $tags -Keys $KeepTagKey) `
              -IsShared $false `
              -Creator $creator `
              -CreatorExcluded $creatorExcluded `
              -MinAgeDays $MinAgeDays `
              -MaxAgeDays $MaxAgeDays `
              -TreatOldSnapshotsAsOrphaned:$TreatOldSnapshotsAsOrphaned.IsPresent

            # RDS reports allocated storage, not consumed snapshot size.
            $sizeGiB = if ($null -ne $rsnap.AllocatedStorage) { [double]$rsnap.AllocatedStorage } else { 0 }

            $results.Add([pscustomobject]@{
                AccountId         = $accountId
                ProfileUsed       = $profLabel
                Region            = $r
                SnapshotType      = $set.Type
                SnapshotId        = $snapId
                Name              = $snapId
                Description       = "Source: $srcId"
                SizeGiB           = $sizeGiB
                StartTime         = $created
                AgeDays           = [math]::Round($ageDays, 1)
                SourceId          = $srcId
                SourceExists      = $srcExists
                ReferencedByImage = $false
                StorageTier       = ''
                Creator           = $creator
                Verdict           = $verdict.Verdict
                Reason            = $verdict.Reason
                Tags              = (($tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
              })
          }
        }
      } catch {
        Write-Host "[WARN] Cannot enumerate RDS snapshots in $r : $($_.Exception.Message)" -ForegroundColor Yellow
      }
    }
    Write-Progress -Activity "Scanning $profLabel" -Completed
  }
}

#----------------------------
# Summarise
#----------------------------
$orphans = @($results | Where-Object { $_.Verdict -in @('Orphaned', 'StaleButInUse') })
$orphanGiB = [math]::Round((($orphans | Measure-Object SizeGiB -Sum).Sum), 2)

# Copied and imported snapshots carry no usable source volume id, so orphan status cannot be proven
# from the volume inventory alone. They are held back unless -TreatOldSnapshotsAsOrphaned is set;
# counting them here stops that category from being invisible.
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
  Write-Host "  Unverifiable           : $($unverifiable.Count) (copied/imported - no source volume id; add -TreatOldSnapshotsAsOrphaned to age them out)" -ForegroundColor Yellow
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
    Write-Host "       .\AWS_Orphaned_Snapshots.ps1 -DeleteFromReport '$orphanCsv' -Delete" -ForegroundColor Cyan
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

foreach ($o in ($orphans | Sort-Object ProfileUsed, Region, SnapshotId)) {
  if ($MaxDeletions -gt 0 -and $deleted -ge $MaxDeletions) {
    Write-Host "[INFO] MaxDeletions ($MaxDeletions) reached; stopping." -ForegroundColor Yellow
    break
  }

  $delArgs = @{ Region = $o.Region }
  if ($o.ProfileUsed -and $o.ProfileUsed -ne '<default credentials>') { $delArgs['ProfileName'] = $o.ProfileUsed }

  $target = "$($o.Region)/$($o.SnapshotId) ($($o.SizeGiB) GiB)"
  if ($PSCmdlet.ShouldProcess($target, "Remove $($o.SnapshotType) snapshot")) {
    try {
      switch ($o.SnapshotType) {
        'EBS' { Remove-EC2Snapshot -SnapshotId $o.SnapshotId @delArgs -Force -ErrorAction Stop | Out-Null }
        'RDS-Instance' { Remove-RDSDBSnapshot -DBSnapshotIdentifier $o.SnapshotId @delArgs -Force -ErrorAction Stop | Out-Null }
        'RDS-Cluster' { Remove-RDSDBClusterSnapshot -DBClusterSnapshotIdentifier $o.SnapshotId @delArgs -Force -ErrorAction Stop | Out-Null }
        default { throw "Unknown snapshot type '$($o.SnapshotType)'" }
      }
      $deleted++
      Write-Host "[DELETED] $target" -ForegroundColor Magenta
      $deleteLog.Add([pscustomobject]@{ Timestamp = (Get-Date); AccountId = $o.AccountId; Region = $o.Region; SnapshotType = $o.SnapshotType; SnapshotId = $o.SnapshotId; SizeGiB = $o.SizeGiB; Status = 'Deleted'; Error = '' })
    } catch {
      $failed++
      Write-Host "[ERROR] Failed to delete $target : $($_.Exception.Message)" -ForegroundColor Red
      $deleteLog.Add([pscustomobject]@{ Timestamp = (Get-Date); AccountId = $o.AccountId; Region = $o.Region; SnapshotType = $o.SnapshotType; SnapshotId = $o.SnapshotId; SizeGiB = $o.SizeGiB; Status = 'Failed'; Error = $_.Exception.Message })
    }
  }
}

if ($deleteLog.Count -gt 0) {
  $deleteLog | Export-Csv -Path $deletedCsv -NoTypeInformation -WhatIf:$false
  Write-Host "`n[INFO] Deleted $deleted snapshot(s), $failed failure(s). Log: $deletedCsv" -ForegroundColor Green
}
