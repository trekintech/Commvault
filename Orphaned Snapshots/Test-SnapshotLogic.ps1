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
        'Test-ResourceGroupFilter', 'Test-IsLocked', 'Test-CommvaultDetection', 'Get-CreatorEvidence',
        'Get-DescriptionTemplate', 'Get-SnapshotMonthlyCost', 'Format-Money', 'Format-MoneyCell',
        'Get-CostSummary', 'Get-SnapshotOwnership'))))

# The AWS helpers share names with the Azure ones but take AWS shapes, so alias them on load.
$awsText = Get-FunctionText -Path $awsScript -Name @(
  'ConvertTo-TagHashtable', 'Get-AwsSnapshotCreator', 'Test-HasRealVolumeReference', 'Get-BackedAmiId')
. ([scriptblock]::Create($awsText))

# The shared functions read these at script scope, exactly as they do inside the real scripts.
$CategoryOrder = @('Orphaned', 'SourceUnattached', 'SourceActive', 'Unverifiable', 'InUse', 'Protected')
$AgeBandOrder = @('0-30 days', '31-90 days', '91-365 days', 'Over 365 days')

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
$live = @{ SourceExists = $true; SourceAttached = $true; HasSourceReference = $true; ReferencedByImage = $false
  HasKeepTag = $false; IsPinned = $false; PinnedReason = ''; Creator = 'CloudNative'; CreatorExcluded = $false
}
Assert-Equal 'source alive and attached -> SourceActive' ((Get-SnapshotCategory @live).Category) 'SourceActive'

# The case the report is really for: the VM was deleted but its disk was left behind.
$t = $live.Clone(); $t.SourceAttached = $false
Assert-Equal 'source exists but unattached -> SourceUnattached' ((Get-SnapshotCategory @t).Category) 'SourceUnattached'

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
$all = @{ SourceExists = $false; SourceAttached = $false; HasSourceReference = $true; ReferencedByImage = $true
  HasKeepTag = $true; IsPinned = $true; PinnedReason = 'lock'; Creator = 'Commvault'; CreatorExcluded = $true
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
$cvName = @('COMMVAULT', 'GXMD_SNAP')
$cvTag = @('Commvault')
function AzCreator { param($Name, $Rg = 'rg1', $Tags = $null)
  Get-AzSnapshotCreator -Name $Name -ResourceGroupName $Rg -Tags $Tags `
    -CommvaultNamePattern $cvName -CommvaultTagKey $cvTag
}
# The real thing, taken verbatim from an Azure portal snapshot blade.
$realName = 'linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462023_COMMVAULT_GXMD_SNAP_2db7ab'
$realTags = @{ 'CreatedBy' = 'Commvault'; 'Description' = 'Created by jobID [8462023] at [09/16/2026,09:05:37] from [mas02036c1us02]' }
Assert-Equal 'a real Commvault snapshot, name and tags' (AzCreator $realName 'SAASFAST' $realTags) 'Commvault'
Assert-Equal 'its name alone is conclusive'             (AzCreator $realName) 'Commvault'
Assert-Equal 'its tags alone are conclusive'            (AzCreator 'renamed-by-hand' 'rg1' $realTags) 'Commvault'
Assert-Equal 'the GXMD_SNAP suffix also catches it'     (AzCreator 'something_GXMD_SNAP_ab12') 'Commvault'
Assert-Equal 'case does not matter'                     (AzCreator 'thing_commvault_snap') 'Commvault'
Assert-Equal 'CreatedBy=Commvault tag value'            (AzCreator 'snap-2024' 'rg1' @{'CreatedBy' = 'Commvault' }) 'Commvault'
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

# AWS keeps its own, still-unverified pattern set - deliberately NOT Azure's confirmed markers,
# because no AWS equivalent of the COMMVAULT name stamp has been identified yet.
$awsCvName = @('^SP_\d+_\d+_\d+_\d+', 'commvault', '_GX_BACKUP_', '_GX_AMI_')
$awsCvTag = @('commvault', '_GX_BACKUP_')
function AwsCreator { param($Desc = 'x', $Tags = @{}, $Alias = '', $Image = $null)
  Get-AwsSnapshotCreator -Description $Desc -Tags $Tags -OwnerAlias $Alias -ImageInfo $Image `
    -CommvaultNamePattern $awsCvName -CommvaultTagKey $awsCvTag
}
# The real thing, taken verbatim from an AWS console snapshot page - every tag it actually carries.
$realAwsDesc = 'Created by CreateImage(i-0dfd5810c1370c38d) for ami-0891867df96c9f156'
$realAwsTags = ConvertTo-TagHashtable @(
  (Tag 'commvault:vendor' 'Commvault')
  (Tag 'commvault:createdBy' 'Commvault Cloud (M036)')
  (Tag 'Description' 'Snapshot_created_by_Commvault_for_job_8465372_at_1789636362._Source_Volume_vol-089fa2758cd9cb01e_from_lsp01036c1us01')
  (Tag '_GX_BACKUP_' '')
  (Tag 'Name' 'SP_2_8465372_40229960_1789636362')
)
Assert-Equal 'a real Commvault EBS snapshot' (AwsCreator $realAwsDesc $realAwsTags) 'Commvault'

# Each marker has to stand alone, so losing or renaming any one tag does not lose the snapshot.
Assert-Equal 'commvault:vendor alone'    (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'commvault:vendor' 'Commvault')))) 'Commvault'
Assert-Equal 'commvault:createdBy alone' (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'commvault:createdBy' 'Commvault Cloud (M036)')))) 'Commvault'
Assert-Equal 'the Description tag alone' (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'Description' 'Snapshot_created_by_Commvault_for_job_1_at_2._Source_Volume_vol-3')))) 'Commvault'
Assert-Equal '_GX_BACKUP_ with no value' (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag '_GX_BACKUP_' '')))) 'Commvault'
Assert-Equal 'the SP_ Name tag alone'    (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'Name' 'SP_2_8465372_40229960_1789636362')))) 'Commvault'

# The NATIVE description field is AWS boilerplate from CreateImage. Commvault's own wording lives in
# a Description TAG, which is a different thing - the native field proves nothing on its own.
Assert-Equal 'the native description is not a marker' (AwsCreator $realAwsDesc @{}) 'CloudNative'
Assert-Equal 'an untagged snapshot stays cloud-native' (AwsCreator 'manual snap' @{}) 'CloudNative'
# A bare SP_ prefix is too loose to be the marker; the full structure is what identifies it.
Assert-Equal 'SP_ without the full structure is not matched' (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'Name' 'SP_backup')))) 'CloudNative'
Assert-Equal 'SP_ with the full structure matches'          (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'Name' 'SP_9_1234567_7654321_1700000000')))) 'Commvault'

# Commvault drives CreateImage, so an anonymous-looking snapshot inherits from the AMI above it.
$cvImage = [pscustomobject]@{ ImageId = 'ami-0891867df96c9f156'; Name = 'Commvault_GX_AMI_8465372'; NameTag = ''; TagText = '' }
$plainImage = [pscustomobject]@{ ImageId = 'ami-1111'; Name = 'golden-ubuntu-2204'; NameTag = ''; TagText = 'env=prod' }
Assert-Equal 'inherits Commvault from its AMI name' (AwsCreator $realAwsDesc @{} '' $cvImage) 'Commvault'
Assert-Equal 'inherits from the AMI Name tag' `
  (AwsCreator $realAwsDesc @{} '' ([pscustomobject]@{ ImageId = 'ami-2'; Name = ''; NameTag = 'CV_GX_AMI_1'; TagText = '' })) 'Commvault'
Assert-Equal 'inherits from the AMI tags' `
  (AwsCreator $realAwsDesc @{} '' ([pscustomobject]@{ ImageId = 'ami-3'; Name = ''; NameTag = ''; TagText = 'CreatedBy=Commvault' })) 'Commvault'
Assert-Equal 'an ordinary AMI confers nothing'  (AwsCreator $realAwsDesc @{} '' $plainImage) 'CloudNative'
Assert-Equal 'no AMI at all is handled'         (AwsCreator $realAwsDesc @{} '' $null) 'CloudNative'

Assert-Equal 'CV_ in the Name tag'     (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag 'Name' 'cv_vol_commvault_snap')))) 'Commvault'
Assert-Equal 'commvault in description' (AwsCreator 'Created by Commvault IntelliSnap') 'Commvault'
Assert-Equal '_GX_BACKUP_ tag'          (AwsCreator 'x' (ConvertTo-TagHashtable @((Tag '_GX_BACKUP_' 'true')))) 'Commvault'

# Pulling the AMI id back out of AWS's description - it survives deregistration, which is what makes
# the classic "AMI was deleted, snapshots were not" case provable rather than inferred.
Assert-Equal 'extracts the AMI id'        (Get-BackedAmiId $realAwsDesc) 'ami-0891867df96c9f156'
Assert-Equal 'no AMI in a plain description' (Get-BackedAmiId 'manual snapshot before patching') ''
Assert-Equal 'empty description is safe'     (Get-BackedAmiId '') ''
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
Write-Section 'The zero-detection guard'
#============================================================
# Finding no Commvault snapshots at all, in an estate with snapshots, means the patterns probably
# missed. That must stop a delete rather than sail through it.
Assert-Equal 'some Commvault found -> proceed'   ((Test-CommvaultDetection -CommvaultCount 12 -TotalCount 300 -Acknowledged $false).Proceed) 'True'
Assert-Equal 'none found -> BLOCKED'             ((Test-CommvaultDetection -CommvaultCount 0 -TotalCount 300 -Acknowledged $false).Proceed) 'False'
Assert-Equal 'none found but acknowledged'       ((Test-CommvaultDetection -CommvaultCount 0 -TotalCount 300 -Acknowledged $true).Proceed) 'True'
Assert-Equal 'empty estate is not suspicious'    ((Test-CommvaultDetection -CommvaultCount 0 -TotalCount 0 -Acknowledged $false).Proceed) 'True'
Assert-Equal 'the block explains how to fix it'  (([string](Test-CommvaultDetection -CommvaultCount 0 -TotalCount 300 -Acknowledged $false).Message) -match 'AuditCreatorEvidence') 'True'

#============================================================
Write-Section 'Evidence gathering: finding a marker you do not know yet'
#============================================================
# Descriptions carry job ids and timestamps, so raw values are all unique and tell you nothing.
# Masking the variable parts collapses one code path into one counted template - which is how you
# spot a product marker in a cloud where you have not yet identified one.
$realDesc = 'Created by jobID [8462023] at [09/16/2026,09:05:37] from [mas02036c1us02]'
$otherDesc = 'Created by jobID [8462024] at [09/17/2026,11:22:01] from [mas02036c1us02]'
Assert-Equal 'two runs of the same job collapse together' `
  ((Get-DescriptionTemplate $realDesc) -eq (Get-DescriptionTemplate $otherDesc)) 'True'
Assert-Equal 'the identifying wording survives masking' `
  ((Get-DescriptionTemplate $realDesc) -match 'Created by jobID') 'True'
Assert-Equal 'digits are masked'    ((Get-DescriptionTemplate $realDesc) -notmatch '8462023') 'True'
Assert-Equal 'guids are masked'     (Get-DescriptionTemplate 'vol 3f2504e0-4f89-11d3-9a0c-0305e82c3301') 'vol <guid>'
Assert-Equal 'a different product stays distinct' `
  ((Get-DescriptionTemplate $realDesc) -ne (Get-DescriptionTemplate 'Created for policy: policy-0abc123')) 'True'

$sample = @(
  [pscustomobject]@{ Name = 'linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462023_COMMVAULT_GXMD_SNAP_2db7ab'
    Tags = 'CreatedBy=Commvault; Description=' + $realDesc; Description = $realDesc; Creator = 'Commvault' }
  [pscustomobject]@{ Name = 'linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462024_COMMVAULT_GXMD_SNAP_9ff01c'
    Tags = 'CreatedBy=Commvault; Description=' + $otherDesc; Description = $otherDesc; Creator = 'Commvault' }
  [pscustomobject]@{ Name = 'manual-before-patch'; Tags = 'env=prod'; Description = ''; Creator = 'CloudNative' }
  [pscustomobject]@{ Name = 'weird_legacy_thing'; Tags = ''; Description = ''; Creator = 'CloudNative' }
)
$ev = Get-CreatorEvidence -Rows $sample
Assert-Equal 'reports the CreatedBy tag key'   ((@($ev | Where-Object { $_.Evidence -eq 'TagKey' -and $_.Value -eq 'CreatedBy' })).Count) 1
# This is the row that hands you the marker on a plate.
Assert-Equal 'reports CreatedBy=Commvault as a pair' ((@($ev | Where-Object { $_.Evidence -eq 'TagPair' -and $_.Value -eq 'CreatedBy=Commvault' })[0]).Count) 2
Assert-Equal 'a per-snapshot value is not a marker'  ((@($ev | Where-Object { $_.Evidence -eq 'TagPair' -and $_.Value -like 'Description=*8462023*' })).Count) 0
Assert-Equal 'templates the description'             ((@($ev | Where-Object { $_.Evidence -eq 'DescriptionPattern' })[0]).Count) 2
Assert-Equal 'finds the name prefix'                 ((@($ev | Where-Object { $_.Evidence -eq 'NamePrefix' -and $_.Value -eq 'linuxbgwsc2' })[0]).Count) 2
Assert-Equal 'empty tags do not break it'            ((@($ev | Where-Object { $_.Evidence -eq 'TagKey' -and $_.Value -eq '' })).Count) 0

#============================================================
Write-Section 'Cost: per-tier rates, monthly and annual'
#============================================================
# Deliberately round numbers so the arithmetic can be checked by eye.
Assert-Equal '100 GiB at 0.05 = 5.00/mo'  (Get-SnapshotMonthlyCost -SizeGiB 100 -Tier '' -PriceTable $null -DefaultPrice 0.05) 5
Assert-Equal '1024 GiB at 0.05 = 51.20'   (Get-SnapshotMonthlyCost -SizeGiB 1024 -Tier '' -PriceTable $null -DefaultPrice 0.05) 51.2
Assert-Equal 'zero size costs nothing'    (Get-SnapshotMonthlyCost -SizeGiB 0 -Tier '' -PriceTable $null -DefaultPrice 0.05) 0

# A flat rate across tiers is the quickest way to a confidently wrong number: AWS archive is about a
# quarter of standard, so the table has to win over the default.
$tiers = @{ 'standard' = 0.05; 'archive' = 0.0125; 'Standard_ZRS' = 0.0625 }
Assert-Equal 'standard tier uses its own rate' (Get-SnapshotMonthlyCost -SizeGiB 100 -Tier 'standard' -PriceTable $tiers -DefaultPrice 0.99) 5
Assert-Equal 'archive tier is cheaper'         (Get-SnapshotMonthlyCost -SizeGiB 100 -Tier 'archive' -PriceTable $tiers -DefaultPrice 0.99) 1.25
Assert-Equal 'Azure ZRS is dearer'             (Get-SnapshotMonthlyCost -SizeGiB 100 -Tier 'Standard_ZRS' -PriceTable $tiers -DefaultPrice 0.99) 6.25
Assert-Equal 'an unlisted tier falls back'     (Get-SnapshotMonthlyCost -SizeGiB 100 -Tier 'premium_v2' -PriceTable $tiers -DefaultPrice 0.10) 10
Assert-Equal 'a blank tier falls back'         (Get-SnapshotMonthlyCost -SizeGiB 100 -Tier '' -PriceTable $tiers -DefaultPrice 0.10) 10

# Every figure anywhere carries its currency and groups thousands, so no number can be misread as a
# bare count or as the wrong currency.
Assert-Equal 'thousands are grouped'     (Format-Money 11136 'USD') 'USD 11,136'
Assert-Equal 'millions are grouped too'  (Format-Money 2500000 'USD') 'USD 2,500,000'
Assert-Equal 'currency is never hardcoded' (Format-Money 1000 'GBP') 'GBP 1,000'
Assert-Equal 'currency travels with zero'  (Format-Money 0 'USD') 'USD 0'
Assert-Equal 'large amounts drop decimals' (Format-Money 928.44 'USD') 'USD 928'

# A 2 GiB snapshot costs pennies a month. Rounding that to "USD 0" reads as free when it is not.
Assert-Equal 'pennies keep their decimals' (Format-Money 0.11 'USD') 'USD 0.11'
Assert-Equal 'small monthly costs survive' (Format-Money 6.35 'USD') 'USD 6.35'
Assert-Equal 'the boundary rounds up'      (Format-Money 99.99 'USD') 'USD 99.99'
Assert-Equal 'and 100 goes whole'          (Format-Money 100 'USD') 'USD 100'

# Grid cells are tight, so only there do huge figures compact - and they still carry the currency.
Assert-Equal 'cells carry the currency'    (Format-MoneyCell 18010 'USD') 'USD 18,010'
Assert-Equal 'cells compact at millions'   (Format-MoneyCell 2500000 'USD') 'USD 2.5M'
Assert-Equal 'cells keep pennies visible'  (Format-MoneyCell 1.32 'USD') 'USD 1.32'

#============================================================
Write-Section 'Cost summary is one row per combination, and it adds up'
#============================================================
# The file is data, so it must behave like data: one grain throughout, and the cost column must sum
# to the estate total. A previous version stacked totals, categories and regions behind a "Grouping"
# column, so summing the column returned about ten times the real figure - these assertions exist to
# stop that coming back.
$mixed = @(
  [pscustomobject]@{ Region='eu-west-2'; Ownership='Not Commvault'; Creator='CloudNative'
    Category='Orphaned'; Action='Delete'; AgeBand='Over 365 days'; SizeGiB=100.0; EstMonthlyCost=5.0 }
  [pscustomobject]@{ Region='eu-west-2'; Ownership='Not Commvault'; Creator='CloudNative'
    Category='Orphaned'; Action='Delete'; AgeBand='Over 365 days'; SizeGiB=100.0; EstMonthlyCost=5.0 }
  [pscustomobject]@{ Region='us-east-1'; Ownership='Not Commvault'; Creator='CloudNative'
    Category='SourceActive'; Action='Review'; AgeBand='0-30 days'; SizeGiB=50.0; EstMonthlyCost=2.5 }
  [pscustomobject]@{ Region='eu-west-2'; Ownership='Commvault'; Creator='Commvault'
    Category='Protected'; Action='Keep'; AgeBand='0-30 days'; SizeGiB=200.0; EstMonthlyCost=10.0 }
)
$scopes = @(@{ Label = 'Region'; Prop = 'Region' })
$cost = Get-CostSummary -Rows $mixed -Currency 'USD' -ScopeProperties $scopes

# 4 snapshots, but the two identical eu-west-2 orphans collapse into one row.
Assert-Equal 'identical rows collapse'  $cost.Count 3
Assert-Equal 'and keep their count'     (@($cost | Where-Object { $_.Category -eq 'Orphaned' })[0].Snapshots) 2
Assert-Equal 'and their combined cost'  (@($cost | Where-Object { $_.Category -eq 'Orphaned' })[0].EstAnnualCost) 120

# The property that matters: totals reconcile instead of double-counting.
Assert-Equal 'monthly sums to the estate'  ((($cost | Measure-Object EstMonthlyCost -Sum).Sum)) (($mixed | Measure-Object EstMonthlyCost -Sum).Sum)
Assert-Equal 'annual sums to the estate'   ((($cost | Measure-Object EstAnnualCost -Sum).Sum)) 270
Assert-Equal 'snapshot counts reconcile'   ((($cost | Measure-Object Snapshots -Sum).Sum)) $mixed.Count
Assert-Equal 'capacity reconciles'         ((($cost | Measure-Object CapacityGiB -Sum).Sum)) 450

# One grain throughout - no aggregate rows hiding among the detail.
Assert-Equal 'no Grouping column'      (($cost[0].PSObject.Properties.Name -contains 'Grouping')) 'False'
Assert-Equal 'no Scope column'         (($cost[0].PSObject.Properties.Name -contains 'Scope')) 'False'
Assert-Equal 'no Total row'            (@($cost | Where-Object { $_.Category -eq 'Total' -or $_.Ownership -eq 'Total' }).Count) 0
Assert-Equal 'every row names a region' (@($cost | Where-Object { -not $_.Region }).Count) 0
Assert-Equal 'every row names a category' (@($cost | Where-Object { -not $_.Category }).Count) 0

# Filterable: slicing by one dimension gives a straight, correct answer.
$eu = @($cost | Where-Object { $_.Region -eq 'eu-west-2' })
Assert-Equal 'filter by region works'  (($eu | Measure-Object EstAnnualCost -Sum).Sum) 240
$notCv = @($cost | Where-Object { $_.Ownership -eq 'Not Commvault' })
Assert-Equal 'filter by ownership works' (($notCv | Measure-Object EstAnnualCost -Sum).Sum) 150

# Scope columns are named by the caller, so each cloud uses its own vocabulary.
Assert-Equal 'scope column is labelled'  (($cost[0].PSObject.Properties.Name -contains 'Region')) 'True'
$noScope = Get-CostSummary -Rows $mixed -Currency 'USD' -ScopeProperties @()
Assert-Equal 'works without any scope'   (($noScope | Measure-Object EstAnnualCost -Sum).Sum) 270
Assert-Equal 'empty input is safe'       ((Get-CostSummary -Rows @() -Currency 'USD' -ScopeProperties $scopes).Count) 0

# Both scripts must export per-snapshot rows with the filter columns first.
foreach ($pair in @(@{ File=$azureScript; First='SubscriptionName' }, @{ File=$awsScript; First='AccountId' })) {
  $body = Get-Content -Path $pair.File -Raw
  $name = Split-Path $pair.File -Leaf
  Assert-Equal "$name defines an explicit column order" ($body -match '\$snapshotColumns = @\(') 'True'
  Assert-Equal "$name applies it to both CSVs" ((([regex]::Matches($body, 'Select-Object \$snapshotColumns')).Count)) 2
  # Pull the declared list out and inspect it, rather than pattern-matching around it.
  $listText = [regex]::Match($body, '(?s)\$snapshotColumns = @\((.*?)\)').Groups[1].Value
  $cols = [regex]::Matches($listText, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
  Assert-Equal "$name leads with $($pair.First)" $cols[0] $pair.First
  foreach ($col in @('Ownership', 'Creator', 'Category', 'Action', 'AgeBand', 'AgeDays', 'SizeGiB',
                     'Currency', 'EstMonthlyCost', 'EstAnnualCost', 'Reason')) {
    Assert-Equal "$name exports $col per snapshot" ($cols -contains $col) 'True'
  }
  # The decision columns must sit near the front, where a filter drop-down will find them.
  Assert-Equal "$name puts Category in the first 8 columns" (($cols.IndexOf('Category') -lt 8)) 'True'
}

# RDS is opt-in: a default run covers VM disks only, and the type breakdown stays hidden because a
# single-valued one would just restate the total.
$awsBody3 = Get-Content -Path $awsScript -Raw
Assert-Equal 'RDS is a switch, so off by default' ($awsBody3 -match '\[switch\]\$IncludeRdsSnapshots') 'True'
Assert-Equal 'RDS is only scanned when asked'     ($awsBody3 -match 'if \(-not \$IncludeRdsSnapshots\) \{ continue \}') 'True'
Assert-Equal 'the RDS module loads only when asked' ($awsBody3 -match 'if \(\$IncludeRdsSnapshots\) \{ Import-Module AWS\.Tools\.RDS') 'True'
Assert-Equal 'EBS and RDS are labelled apart'     ($awsBody3 -match "SnapshotType\s+= 'EBS'") 'True'
Assert-Equal 'AWS breaks down by snapshot type'   ($awsBody3 -match "Label = 'Snapshot type'; Prop = 'SnapshotType'") 'True'
Assert-Equal 'SnapshotType is exported per row'   ($awsBody3 -match "'SnapshotType'") 'True'

#============================================================
Write-Section 'Regressions: PowerShell collection-unrolling traps'
#============================================================
# Both bugs below shipped and were only caught by running the scripts end to end. They share a root
# cause: PowerShell unrolls collections through the pipeline, so a collection can arrive somewhere as
# something other than a collection.

# 1. A single-element array assigned from an if-statement is unrolled back to a bare scalar, and
#    foreach over $null runs zero times. In the AWS script that meant the default credential path
#    (no -ProfileName) silently scanned nothing at all and reported a clean, empty estate.
$noProfiles = $null
$unrolled = if ($noProfiles -and $noProfiles.Count -gt 0) { $noProfiles } else { @($null) }
$iterations = 0; foreach ($x in $unrolled) { $iterations++ }
Assert-Equal 'the unsafe form really does iterate zero times' $iterations 0
$wrapped = @(if ($noProfiles -and $noProfiles.Count -gt 0) { $noProfiles } else { '' })
$iterations2 = 0; foreach ($x in $wrapped) { $iterations2++ }
Assert-Equal 'the @() wrapper restores the single pass' $iterations2 1

$awsBody = Get-Content -Path $awsScript -Raw
Assert-Equal 'AWS builds its profile list with an @() wrapper' ($awsBody -match '\$profiles = @\(if ') 'True'
Assert-Equal 'AWS no longer uses the unrolling form'          ($awsBody -notmatch '\$profiles = if ') 'True'

# 2. A bare "return $set" hands back $null for an empty set and a plain array otherwise, losing the
#    type and the case-insensitive comparer. Every .Contains() downstream then throws or silently
#    turns case-sensitive. These functions call cloud cmdlets, so assert at the source level.
foreach ($pair in @(@{ File = $azureScript; Fn = 'Get-ImageReferencedSnapshotIds' },
                    @{ File = $azureScript; Fn = 'Get-LockedResourceIds' })) {
  $text = Get-FunctionText -Path $pair.File -Name @($pair.Fn)
  if (-not $text) { continue }
  $bare = $text -match 'return\s+\$(ids|set)\s*[}\r\n]'
  Assert-Equal "$(Split-Path $pair.File -Leaf)/$($pair.Fn) does not bare-return its set" (-not $bare) 'True'
}

# The AWS image index returns a pscustomobject holding a hashtable and a set. Neither is unrolled,
# which is the point of wrapping them in an object rather than returning two collections.
$idxText = Get-FunctionText -Path $awsScript -Name @('Get-ImageIndex')
Assert-Equal 'the AWS image index returns a single object' ($idxText -match 'return \[pscustomobject\]') 'True'

#============================================================
Write-Section 'End to end: a realistic estate lands where it should'
#============================================================
# The case that started all this - a snapshot whose disk is alive and two years old is NOT an orphan,
# and must not be deleted under the default scope however old it is.
$oldButLive = Get-SnapshotCategory -SourceExists $true -SourceAttached $true -HasSourceReference $true -ReferencedByImage $false `
  -HasKeepTag $false -IsPinned $false -PinnedReason '' -Creator 'CloudNative' -CreatorExcluded $false
Assert-Equal 'two-year-old live snapshot is SourceActive' $oldButLive.Category 'SourceActive'
Assert-Equal '...and is only reviewed by default' ((Get-SnapshotAction -Category $oldButLive.Category -AgeDays 730 -DeleteScope @('Orphaned') @bars).Action) 'Review'
Assert-Equal '...and deletes only once scoped in'  ((Get-SnapshotAction -Category $oldButLive.Category -AgeDays 730 -DeleteScope @('Orphaned', 'SourceActive') @bars).Action) 'Delete'

# Every category must be one the report knows how to render.
foreach ($c in @('Orphaned', 'SourceUnattached', 'SourceActive', 'Unverifiable', 'InUse', 'Protected')) {
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
