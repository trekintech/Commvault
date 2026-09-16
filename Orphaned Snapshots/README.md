# Orphaned Cloud-Native Snapshot Reporting & Cleanup

Two scripts that find — and optionally delete — **cloud-native** snapshots that nobody owns any more:

| Script | Cloud | Covers |
|---|---|---|
| `Azure_Orphaned_Snapshots.ps1` | Azure | Managed disk snapshots |
| `AWS_Orphaned_Snapshots.ps1` | AWS | EBS snapshots, plus manual RDS instance/cluster snapshots |

"Cloud-native" means **snapshots not created by Commvault**. Commvault-created snapshots are detected,
reported, and excluded from deletion. So are snapshots belonging to the cloud providers' own backup
services (Azure Backup, Azure Site Recovery, AWS Backup, EBS Data Lifecycle Manager) — those are
managed on a schedule by their own policy, and deleting them breaks recovery points.

Both scripts are **report-only by default**. Nothing is deleted unless you pass `-Delete`.

---

## Why this matters

Snapshots are the classic silent cloud spend leak. In both clouds they outlive the thing they were
taken from:

- **Azure** — deleting a managed disk does *not* delete its snapshots. There is no lifecycle policy on
  snapshots, so they bill indefinitely.
- **AWS** — deregistering an AMI does *not* delete the EBS snapshots behind it, and neither does
  deleting a volume. This is the single most common source of orphaned snapshot spend.

Neither cloud gives you a native "show me the snapshots with nothing behind them" view.

---

## Requirements

**Azure** — PowerShell 7+, and `Az.Accounts`, `Az.Compute`, `Az.Resources`.

```powershell
Install-Module Az.Accounts, Az.Compute, Az.Resources -Scope CurrentUser
Connect-AzAccount
```

Permissions: `Reader` on the subscriptions to report. To delete, `Disk Snapshot Contributor` (or
`Contributor`) on the scope being cleaned.

**AWS** — PowerShell 7+, and `AWS.Tools.Common`, `AWS.Tools.EC2`. Add `AWS.Tools.RDS` for
`-IncludeRdsSnapshots`, and `AWS.Tools.SecurityToken` so reports are labelled with the account id.

```powershell
Install-Module AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.SecurityToken -Scope CurrentUser
Set-AWSCredential -AccessKey ... -SecretKey ... -StoreAs prod
```

Permissions to report: `ec2:DescribeSnapshots`, `ec2:DescribeVolumes`, `ec2:DescribeImages`,
`ec2:DescribeRegions`, `sts:GetCallerIdentity` (plus `ec2:DescribeSnapshotAttribute` for
`-CheckSharing`, and `rds:DescribeDB*` for RDS). To delete, add `ec2:DeleteSnapshot` and
`rds:DeleteDBSnapshot` / `rds:DeleteDBClusterSnapshot`.

Both scripts accept `-AutoInstallModules` to install what is missing.

---

## The intended workflow

Report, review, then delete from the reviewed file. This keeps a human in the loop over exactly which
snapshots go.

```powershell
# 1. Report. Deletes nothing.
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -OutputPath .\reports

# 2. Open Azure_Snapshots_Orphaned_<timestamp>.csv and DELETE ANY ROW YOU WANT TO KEEP.
#    What is left in the file is what gets deleted.

# 3. Dry run against the approved file.
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\Azure_Snapshots_Orphaned_20260916-101500.csv -Delete -WhatIf

# 4. Execute.
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\Azure_Snapshots_Orphaned_20260916-101500.csv -Delete
```

The AWS script works identically:

```powershell
.\AWS_Orphaned_Snapshots.ps1 -ProfileName prod -IncludeRdsSnapshots -OutputPath .\reports
.\AWS_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\AWS_Snapshots_Orphaned_20260916-101500.csv -Delete
```

---

## ⚠️ Read this before deleting anything

**Verify the Commvault detection patterns against your own environment first.** Commvault's snapshot
naming and tagging varies by agent, version and IntelliSnap configuration. The defaults are a
reasonable starting point, not a guarantee:

| | Default name patterns (regex) | Default tag keys |
|---|---|---|
| Azure | `^CV_`, `^cvsnap`, `_CvSnap`, `commvault`, `^GX_`, `_GX_BACKUP_` | `CV_JobId`, `CommvaultJobId`, `Commvault`, `_GX_BACKUP_`, `_GX_AMI_` |
| AWS | as above, plus `_GX_AMI_` (matched against the `Name` tag *and* the description) | as above |

Run in report mode, open `*_Snapshots_All_*.csv`, and confirm every snapshot you expect Commvault to
own shows `Creator = Commvault`. If any show `CloudNative`, widen the patterns before you delete:

```powershell
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions `
  -CommvaultNamePattern '^CV_','commvault','^SNAP_CV' `
  -CommvaultTagKey 'CV_JobId','CommvaultInstance'
```

Deletion is permanent. Azure snapshots and EBS snapshots cannot be recovered once removed.

---

## How a snapshot is judged

Each snapshot gets a **Creator** and a **Verdict**, both written to the CSV with the reasoning.

**Creator** — only `CloudNative` is ever a deletion candidate by default.

| Azure | AWS |
|---|---|
| `Commvault` | `Commvault` |
| `AzureBackup` (resource group `AzureBackupRG_*`) | `AwsBackup` (tag `aws:backup:*`) |
| `SiteRecovery` (name `asr-*`) | `DlmManaged` (tag `aws:dlm:*`, or description `Created for policy: policy-*`) |
| `CloudNative` | `AwsManaged` (owner alias `amazon` / `aws-marketplace`) |
| | `CloudNative` |

**Verdict**

- **`Orphaned`** — the source disk/volume is gone, the snapshot is older than `-MinAgeDays`, nothing
  references it, it has no keep-tag and (Azure) no resource lock. This is the safe, high-confidence case.
- **`StaleButInUse`** — the source still exists but the snapshot is older than `-MaxAgeDays`. Only
  produced when you pass `-TreatOldSnapshotsAsOrphaned`. Review these individually.
- **`Retain`** — everything else, with the reason recorded.

A snapshot is retained if **any** of these hold: created by an excluded product; carries a keep-tag
(`DoNotDelete`, `KeepSnapshot`, `Preserve` by default); referenced by a Managed Image / Compute Gallery
version (Azure) or an AMI block device mapping (AWS); under a resource lock (Azure); shared with
another account (AWS, with `-CheckSharing`); or younger than `-MinAgeDays`.

### "Unverifiable" snapshots

Some snapshots record no usable source: an Azure snapshot taken from an imported blob or another
snapshot, or an AWS copied/imported snapshot, which AWS reports as volume `vol-ffffffff`. Orphan status
cannot be proven for these from the inventory, so they are **never auto-deleted**. They are counted
separately in the console output and HTML report. Use `-TreatOldSnapshotsAsOrphaned` to age them out
instead, and review the results by hand.

---

## Output

Written to `-OutputPath` (default: current directory), timestamped:

| File | Contents |
|---|---|
| `*_Snapshots_All_<ts>.csv` | Every snapshot found, with creator, verdict and reasoning. Start here. |
| `*_Snapshots_Orphaned_<ts>.csv` | Orphan candidates only — the file to review and feed to `-DeleteFromReport`. |
| `*_Orphaned_Snapshots_<ts>.html` | Summary: totals, breakdown by creator (and by region, AWS), candidate table. |
| `*_Snapshots_Deleted_<ts>.csv` | Deletion log with per-snapshot success/failure. Written only when `-Delete` runs. |

Reports are always written, including under `-WhatIf`.

### About the cost estimate

`-PricePerGiBMonth` (default `0.05`) is applied to **provisioned** size to give an order-of-magnitude
figure. Both Azure incremental snapshots and AWS EBS snapshots bill only on changed blocks, so the real
saving is usually lower. Treat it as a prioritisation signal, not a forecast.

---

## Key parameters

Shared by both scripts:

| Parameter | Default | Purpose |
|---|---|---|
| `-MinAgeDays` | `30` | Ignore snapshots younger than this. |
| `-MaxAgeDays` | `365` | Age threshold for `-TreatOldSnapshotsAsOrphaned`. |
| `-TreatOldSnapshotsAsOrphaned` | off | Also flag old snapshots whose source still exists. |
| `-CommvaultNamePattern` / `-CommvaultTagKey` | see above | Commvault detection. Tune these. |
| `-IncludeCommvaultSnapshots` | off | Make Commvault snapshots deletable. Not recommended. |
| `-IncludeBackupServiceSnapshots` | off | Make Azure Backup / ASR / AWS Backup / DLM snapshots deletable. Strongly discouraged. |
| `-KeepTagKey` | `DoNotDelete`, `KeepSnapshot`, `Preserve` | Tag keys that always protect a snapshot. |
| `-Delete` | off | Actually delete. Supports `-WhatIf` / `-Confirm`. |
| `-Force` | off | Skip the interactive `Type DELETE to proceed` gate, for scheduled runs. |
| `-MaxDeletions` | `0` (no cap) | Stop after N successful deletions. |
| `-DeleteFromReport` | — | Delete exactly the rows in a reviewed CSV. |
| `-PricePerGiBMonth` / `-Currency` | `0.05` / `USD` | Cost estimate inputs. |
| `-OutputPath` | `.` | Report destination. |
| `-AutoInstallModules` | off | Install missing modules. |

Azure-specific: `-AllSubscriptions` / `-CurrentSubscription` / `-Subscriptions <names or ids>`,
`-ResourceGroups <wildcards>`, `-SkipGalleryCheck`.

AWS-specific: `-Region <list>` (default: all enabled regions), `-ProfileName <list>` for multi-account
runs, `-IncludeRdsSnapshots`, `-CheckSharing`.

---

## Scheduling

For an unattended weekly cleanup, `-Force` skips the interactive gate. Keep `-MaxDeletions` set as a
blast-radius cap, and keep the logs.

```powershell
.\AWS_Orphaned_Snapshots.ps1 -ProfileName prod -MinAgeDays 90 -Delete -Force `
  -MaxDeletions 50 -OutputPath \\fileserver\reports\snapshots
```

Report first for several weeks before letting anything delete on a schedule.

---

## Notes and limitations

- **Azure incremental snapshot chains** are handled by Azure itself — deleting one snapshot in a chain
  does not invalidate the others, so no special ordering is needed.
- **AWS sharing** is only checked with `-CheckSharing` (one extra API call per candidate). Without it,
  a snapshot shared to another account can be selected for deletion. Use it before any real cleanup.
  If the sharing attribute cannot be read, the snapshot is treated as shared and retained.
- **Cross-account AWS runs** iterate `-ProfileName`; each profile needs its own stored credential.
- **RDS**: only *manual* snapshots are considered. Automated snapshots are managed by RDS's own
  retention and are excluded.
- **Not covered**: Azure NetApp Files snapshots, AWS FSx/Redshift/DocumentDB snapshots, orphaned AMIs
  themselves (as opposed to their snapshots), and unattached disks/volumes. Unattached Azure disks are
  already handled by `Azure Sizing/Azure_Extended.ps1`.
- Read-only reporting is safe to run at any time. Deletion is not reversible.
