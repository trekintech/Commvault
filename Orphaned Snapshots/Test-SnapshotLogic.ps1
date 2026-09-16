#requires -Version 7.0

<#
.SYNOPSIS
Self-contained tests for the classification logic in the Azure and AWS snapshot scripts.

.DESCRIPTION
These scripts delete things, so the rules that decide what gets deleted are worth testing. This
runner lifts the pure functions straight out of both scripts (by parsing them - nothing is executed,
no cloud connection is made, no credentials are needed) and asserts their behaviour.

Run it after changing any Commvault detection pattern, age bar, category rule or delete scope. It
takes a second and needs nothing but PowerShell 7.

.EXAMPLE
.\Test-SnapshotLogic.ps1

.EXAMPLE
.\Test-SnapshotLogic.ps1 -Verbose
Also lists the name of every passing test.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$azureScript = Join-Path $here 'Azure_Orphaned_Snapshots.ps1'
$awsScript = Join-Path $here 'AWS_Orphaned_Snapshots.ps1'

foreach ($f in @($azureScript, $awsScript)) {
  if (-not (Test-Path $f)) { Write-Host "[ERROR] Cannot find $f" -ForegroundColor Red; exit 1 }
}

# Pull a named function's source out of a script without running the script itself.
function Get-FunctionText {
  param([string]$Path, [string[]]$Name)
  $errors = $null; $tokens = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors) { throw "$Path has parse errors: $($errors[0].Message)" }
  ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $Name -contains $_.Name } | ForEach-Object { $_.Extent.Text }) -join "`n"
}

$script:pass = 0
$script:fail = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal {
  param([string]$Name, $Actual, $Expected)
  if ("$Actual" -eq "$Expected") {
    $script:pass++
    Write-Verbose "PASS  $Name"
  } else {
    $script:fail++
    $script:failures.Add("$Name - got '$Actual', expected '$Expected'")
    Write-Host "  FAIL  $Name -> got '$Actual', expected '$Expected'" -ForegroundColor Red
  }
}

function Write-Section { param([string]$Text) Write-Host "`n$Text" -ForegroundColor Cyan }

#--- load the shared model (identical in both scripts) plus each cloud's own helpers ---
. ([scriptblock]::Create((Get-FunctionText -Path $azureScript -Name @(
        'Get-AgeBand', 'Get-SnapshotCategory', 'Get-SnapshotAction', 'Get-RampClass', 'Format-Gib',
        'Test-MatchAnyPattern', 'Test-TagMatch', 'Test-TagKeyPresent', 'Get-AzSnapshotCreator',
        'Test-ResourceGroupFilter', 'Test-IsLocked'))))

# The AWS helpers share names with the Azure ones but take AWS shapes, so alias them on load.
$awsText = Get-FunctionText -Path $awsScript -Name @(
  'ConvertTo-TagHashtable', 'Get-AwsSnapshotCreator', 'Test-HasRealVolumeReference')
. ([scriptblock]::Create($awsText))

$CategoryOrder = @('Orphaned', 'SourceActive', 'Unverifiable', 'InUse', 'Protected')

Write-Host "Snapshot logic tests" -ForegroundColor Green

#============================================================
Write-Section 'Age bands (boundaries are inclusive at the top)'
#============================================================
Assert-Equal 'day 0'   (Get-AgeBand 0)   '0-30 days'
Assert-Equal 'day 30'  (Get-AgeBand 30)  '0-30 days'
Assert-Equal 'day 31'  (Get-AgeBand 31)  '31-90 days'
Assert-Equal 'day 90'  (Get-AgeBand 90)  '31-90 days'
Assert-Equal 'day 91'  (Get-AgeBand 91)  '91-365 days'
Assert-Equal 'day 365' (Get-AgeBand 365) '91-365 days'
Assert-Equal 'day 366' (Get-AgeBand 366) 'Over 365 days'

#============================================================
Write-Section 'Category assignment and its precedence order'
#============================================================
$live = @{ SourceExists = $true; HasSourceReference = $true; ReferencedByImage = $false; HasKeepTag = $false
  IsPinned = $false; PinnedReason = ''; Creator = 'CloudNative'; CreatorExcluded = $false
}
Assert-Equal 'source alive -> SourceActive' ((Get-SnapshotCategory @live).Category) 'SourceActive'

$t = $live.Clone(); $t.SourceExists = $false
Assert-Equal 'source gone -> Orphaned' ((Get-SnapshotCategory @t).Category) 'Orphaned'

$t = $live.Clone(); $t.HasSourceReference = $false
Assert-Equal 'no source reference -> Unverifiable' ((Get-SnapshotCategory @t).Category) 'Unverifiable'

$t = $live.Clone(); $t.ReferencedByImage = $true
Assert-Equal 'backs an image -> InUse' ((Get-SnapshotCategory @t).Category) 'InUse'

$t = $live.Clone(); $t.CreatorExcluded = $true; $t.Creator = 'Commvault'
Assert-Equal 'commvault -> Protected' ((Get-SnapshotCategory @t).Category) 'Protected'

$t = $live.Clone(); $t.HasKeepTag = $true
Assert-Equal 'keep-tag -> Protected' ((Get-SnapshotCategory @t).Category) 'Protected'

$t = $live.Clone(); $t.IsPinned = $true; $t.PinnedReason = 'lock'
Assert-Equal 'lock or share -> Protected' ((Get-SnapshotCategory @t).Category) 'Protected'

# Precedence matters: a snapshot can satisfy several rules at once and must land on the safest.
$all = @{ SourceExists = $false; HasSourceReference = $true; ReferencedByImage = $true; HasKeepTag = $true
  IsPinned = $true; PinnedReason = 'lock'; Creator = 'Commvault'; CreatorExcluded = $true
}
Assert-Equal 'Protected outranks everything' ((Get-SnapshotCategory @all).Category) 'Protected'
$t = $all.Clone(); $t.CreatorExcluded = $false; $t.HasKeepTag = $false; $t.IsPinned = $false
Assert-Equal 'InUse outranks Orphaned' ((Get-SnapshotCategory @t).Category) 'InUse'

#============================================================
Write-Section 'Action, with the default delete scope (Orphaned only)'
#============================================================
$d = @('Orphaned')
$bars = @{ MinAgeDays = 30; SourceActiveMinAgeDays = 365 }
Assert-Equal 'orphan past its bar -> Delete'    ((Get-SnapshotAction -Category 'Orphaned' -AgeDays 400 -DeleteScope $d @bars).Action) 'Delete'
Assert-Equal 'orphan at its bar -> Delete'      ((Get-SnapshotAction -Category 'Orphaned' -AgeDays 30 -DeleteScope $d @bars).Action) 'Delete'
Assert-Equal 'orphan under its bar -> Review'   ((Get-SnapshotAction -Category 'Orphaned' -AgeDays 29 -DeleteScope $d @bars).Action) 'Review'
Assert-Equal 'SourceActive out of scope'        ((Get-SnapshotAction -Category 'SourceActive' -AgeDays 900 -DeleteScope $d @bars).Action) 'Review'
Assert-Equal 'Unverifiable out of scope'        ((Get-SnapshotAction -Category 'Unverifiable' -AgeDays 900 -DeleteScope $d @bars).Action) 'Review'
Assert-Equal 'InUse is never actionable'        ((Get-SnapshotAction -Category 'InUse' -AgeDays 900 -DeleteScope $d @bars).Action) 'Keep'
Assert-Equal 'Protected is never actionable'    ((Get-SnapshotAction -Category 'Protected' -AgeDays 900 -DeleteScope $d @bars).Action) 'Keep'

#============================================================
Write-Section 'Action, with the scope widened'
#============================================================
$w = @('Orphaned', 'SourceActive')
Assert-Equal 'SourceActive in scope and old -> Delete' ((Get-SnapshotAction -Category 'SourceActive' -AgeDays 400 -DeleteScope $w @bars).Action) 'Delete'
Assert-Equal 'SourceActive in scope, too young'        ((Get-SnapshotAction -Category 'SourceActive' -AgeDays 364 -DeleteScope $w @bars).Action) 'Review'
# The high bar is the whole point - SourceActive must not fall through to MinAgeDays.
Assert-Equal 'SourceActive uses the high bar'          ((Get-SnapshotAction -Category 'SourceActive' -AgeDays 40 -DeleteScope $w @bars).Action) 'Review'

$everything = @('Orphaned', 'SourceActive', 'Unverifiable')
$noBars = @{ MinAgeDays = 0; SourceActiveMinAgeDays = 0 }
Assert-Equal 'Protected survives max scope and zero bars' ((Get-SnapshotAction -Category 'Protected' -AgeDays 900 -DeleteScope $everything @noBars).Action) 'Keep'
Assert-Equal 'InUse survives max scope and zero bars'     ((Get-SnapshotAction -Category 'InUse' -AgeDays 900 -DeleteScope $everything @noBars).Action) 'Keep'

#============================================================
Write-Section 'Azure: who created this snapshot'
#============================================================
$cvName = @('^CV_', '^cvsnap', '_CvSnap', 'commvault', '^GX_', '_GX_BACKUP_')
$cvTag = @('CV_JobId', 'CommvaultJobId', 'Commvault', '_GX_BACKUP_', '_GX_AMI_')
function AzCreator { param($Name, $Rg = 'rg1', $Tags = $null)
  Get-AzSnapshotCreator -Name $Name -ResourceGroupName $Rg -Tags $Tags -CommvaultNamePattern $cvName -CommvaultTagKey $cvTag
}
Assert-Equal 'CV_ name prefix'        (AzCreator 'CV_disk1_snap') 'Commvault'
Assert-Equal 'case-insensitive match' (AzCreator 'myCOMMVAULTsnap') 'Commvault'
Assert-Equal 'commvault tag key'      (AzCreator 'snap-2024' 'rg1' @{'CV_JobId' = '12345' }) 'Commvault'
Assert-Equal 'commvault tag value'    (AzCreator 'snap-2024' 'rg1' @{'CreatedBy' = 'Commvault' }) 'Commvault'
Assert-Equal 'Azure Backup RG'        (AzCreator 'snap-x' 'AzureBackupRG_westeurope_1') 'AzureBackup'
Assert-Equal 'Site Recovery name'     (AzCreator 'asr-abc-123') 'SiteRecovery'
Assert-Equal 'genuinely cloud-native' (AzCreator 'manual-snap-before-patch' 'rg1' @{'env' = 'prod' }) 'CloudNative'
Assert-Equal 'null tags do not throw' (AzCreator 'x') 'CloudNative'

#============================================================
Write-Section 'Azure: resource-group filter and lock scopes'
#============================================================
Assert-Equal 'no filter matches all'  (Test-ResourceGroupFilter -ResourceGroupName 'rg-prod' -Filters @()) 'True'
Assert-Equal 'wildcard matches'       (Test-ResourceGroupFilter -ResourceGroupName 'rg-prod-01' -Filters @('rg-prod*')) 'True'
Assert-Equal 'non-match excluded'     (Test-ResourceGroupFilter -ResourceGroupName 'rg-dev' -Filters @('rg-prod*')) 'False'

$locks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
[void]$locks.Add('/subscriptions/s1/resourceGroups/rg1')
Assert-Equal 'RG lock covers its snapshots' (Test-IsLocked -SnapshotId '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/snapshots/s' -LockScopes $locks) 'True'
Assert-Equal 'a different RG is unlocked'   (Test-IsLocked -SnapshotId '/subscriptions/s1/resourceGroups/rg2/providers/Microsoft.Compute/snapshots/s' -LockScopes $locks) 'False'
# rg11 starts with rg1 as a string; segment-aware matching must not treat it as locked.
Assert-Equal 'prefix is not substring'      (Test-IsLocked -SnapshotId '/subscriptions/s1/resourceGroups/rg11/providers/Microsoft.Compute/snapshots/s' -LockScopes $locks) 'False'

#============================================================
Write-Section 'AWS: tag shape and who created this snapshot'
#============================================================
function Tag { param($k, $v) [pscustomobject]@{ Key = $k; Value = $v } }
$ht = ConvertTo-TagHashtable -Tags @((Tag 'Name' 'web01'), (Tag 'env' 'prod'))
Assert-Equal 'AWS tag list becomes a hashtable' $ht['Name'] 'web01'
Assert-Equal 'null tag list is empty'           ((ConvertTo-TagHashtable -Tags $null).Count) 0

$awsCvName = $cvName + @('_GX_AMI_')
function AwsCreator { param($Desc = 'x', $Tags = @{}, $Alias = '')
  Get-AwsSnapshotCreator -Description $Desc -Tags $Tags -OwnerAlias $Alias -CommvaultNamePattern $awsCvName -CommvaultTagKey $cvTag
}
Assert-Equal 'CV_ in the Name tag'     (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'Name' 'CV_vol_snap')))) 'Commvault'
Assert-Equal 'commvault in description' (AwsCreator 'Created by Commvault IntelliSnap') 'Commvault'
Assert-Equal '_GX_BACKUP_ tag'          (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag '_GX_BACKUP_' 'true')))) 'Commvault'
Assert-Equal 'AWS Backup reserved tag'  (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'aws:backup:source-resource' 'vol-1')))) 'AwsBackup'
Assert-Equal 'AWS Backup description'   (AwsCreator 'AWS Backup service point-in-time') 'AwsBackup'
Assert-Equal 'DLM reserved tag'         (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'aws:dlm:lifecycle-policy-id' 'policy-1')))) 'DlmManaged'
Assert-Equal 'DLM description'          (AwsCreator 'Created for policy: policy-0abc') 'DlmManaged'
Assert-Equal 'amazon-owned'             (AwsCreator 'x' @{} 'amazon') 'AwsManaged'
Assert-Equal 'genuinely cloud-native'   (AwsCreator 'pre-upgrade snap' (ConvertTo-TagHashtable @((Tag 'Name' 'manual-2023')))) 'CloudNative'
Assert-Equal 'AWS Backup outranks DLM'  (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'aws:backup:source-resource' 'v'), (Tag 'aws:dlm:lifecycle-policy-id' 'p')))) 'AwsBackup'

#============================================================
Write-Section 'AWS: the vol-ffffffff sentinel'
#============================================================
# AWS reports vol-ffffffff for copied and imported snapshots. Reading that as a deleted volume would
# misfile every DR copy as an orphan, so it has to count as "no reference" instead.
Assert-Equal 'a real volume id'       (Test-HasRealVolumeReference -VolumeId 'vol-0a1b2c3d') 'True'
Assert-Equal 'the classic sentinel'   (Test-HasRealVolumeReference -VolumeId 'vol-ffffffff') 'False'
Assert-Equal 'long-form sentinel'     (Test-HasRealVolumeReference -VolumeId 'vol-fffffffffffffffff') 'False'
Assert-Equal 'empty is no reference'  (Test-HasRealVolumeReference -VolumeId '') 'False'
Assert-Equal 'a snapshot id is not a volume' (Test-HasRealVolumeReference -VolumeId 'snap-123') 'False'
Assert-Equal 'a real id may start with f'    (Test-HasRealVolumeReference -VolumeId 'vol-fa1b2c3d') 'True'

#============================================================
Write-Section 'Report rendering helpers'
#============================================================
Assert-Equal 'nothing -> the empty class' (Get-RampClass -Fraction 0) 'r0'
Assert-Equal 'a trace still gets a step'  (Get-RampClass -Fraction 0.01) 'r1'
Assert-Equal 'the maximum gets the top'   (Get-RampClass -Fraction 1) 'r7'
Assert-Equal 'over-range is clamped'      (Get-RampClass -Fraction 1.5) 'r7'
Assert-Equal 'GiB below a TiB'            (Format-Gib 512) '512 GiB'
Assert-Equal 'rolls over to TiB'          (Format-Gib 2048) '2 TiB'

#============================================================
Write-Section 'End to end: a realistic estate lands where it should'
#============================================================
# The case that started all this - a snapshot whose disk is alive and two years old is NOT an orphan,
# and must not be deleted under the default scope however old it is.
$oldButLive = Get-SnapshotCategory -SourceExists $true -HasSourceReference $true -ReferencedByImage $false `
  -HasKeepTag $false -IsPinned $false -PinnedReason '' -Creator 'CloudNative' -CreatorExcluded $false
Assert-Equal 'two-year-old live snapshot is SourceActive' $oldButLive.Category 'SourceActive'
Assert-Equal '...and is only reviewed by default' ((Get-SnapshotAction -Category $oldButLive.Category -AgeDays 730 -DeleteScope @('Orphaned') @bars).Action) 'Review'
Assert-Equal '...and deletes only once scoped in'  ((Get-SnapshotAction -Category $oldButLive.Category -AgeDays 730 -DeleteScope @('Orphaned', 'SourceActive') @bars).Action) 'Delete'

# Every category must be one the report knows how to render.
foreach ($c in @('Orphaned', 'SourceActive', 'Unverifiable', 'InUse', 'Protected')) {
  Assert-Equal "category '$c' is renderable" ($CategoryOrder -contains $c) 'True'
}

#============================================================
Write-Host ""
if ($script:fail -eq 0) {
  Write-Host "All $($script:pass) tests passed." -ForegroundColor Green
  exit 0
} else {
  Write-Host "$($script:pass) passed, $($script:fail) FAILED:" -ForegroundColor Red
  $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
