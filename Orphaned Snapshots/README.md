# Cloud Snapshot Savings Report

Find out what a cloud estate is spending on snapshots Commvault didn't create, and remove them safely.

| File | What it does |
|---|---|
| `Azure_Orphaned_Snapshots.ps1` | Azure managed disk snapshots |
| `AWS_Orphaned_Snapshots.ps1` | AWS EBS snapshots (VM disks). Manual RDS snapshots with `-IncludeRdsSnapshots`. |
| `Test-SnapshotLogic.ps1` | Offline self-test. No cloud, no credentials. |

Both scripts are report-only by default. Nothing gets deleted unless you pass `-Delete`.

---

## The problem

Snapshots outlive whatever they were taken from. Delete an Azure disk and its snapshots stick around.
Deregister an AWS AMI and the snapshots behind it stick around too. Nobody notices, because neither
cloud has a built-in view of "snapshots with nothing behind them" — they just keep billing every month.

A customer's estate will also have Commvault's own backup snapshots sitting in it. Those aren't a
saving; deleting them breaks recovery points. So the report separates the two and only ever counts the
rest as a potential saving.

---

## What you get

Run it and you get a terminal summary, an HTML report to share, and CSVs to work from.

Commvault's own snapshots are identified and set aside first — counted, costed, and excluded from
every other figure in the report. They're still listed, so it's obvious they were found rather than
missed.

Everything else is broken down by why it's still hanging around:

| Category | Meaning |
|---|---|
| **Orphaned** | The source disk or volume no longer exists — nothing to restore, no owner to ask. |
| **SourceUnattached** | The disk is still there, but the VM it belonged to was deleted. Usually the next thing to look at after Orphaned. |
| **SourceActive** | Attached to a machine that's still running. Not an orphan, so it's worth judging on age rather than deleting outright. |
| **Unverifiable** | We can't confirm whether the source still exists. Needs a person to check. |
| **InUse** | Backing a live image or AMI, so it's still doing a job. Leave it alone. |
| **Protected** | Covered by Azure Backup, Site Recovery, AWS Backup, DLM, a keep-tag, or a lock. |

From there the report gives you:

- **Cost per category**, per month and per year, plus each category's share of the total bill.
- **Cost by age**, so it's obvious at a glance how much snapshots over a year old are costing.
- **Cost by region** — also by subscription and resource group on Azure, and by account on AWS — shown
  both across the whole estate and with Commvault excluded. If a breakdown would only have one value
  (a single-region estate, say), it's left out rather than just repeating the total.

### What gets scanned

By default the AWS script only looks at VM disks — EBS snapshots. Databases are a separate
conversation with a separate owner, so RDS snapshots are opt-in:

```powershell
.\AWS_Orphaned_Snapshots.ps1                          # EBS only
.\AWS_Orphaned_Snapshots.ps1 -IncludeRdsSnapshots      # EBS + manual RDS instance and cluster snapshots
```

Every row carries a `SnapshotType` of `EBS`, `RDS-Instance` or `RDS-Cluster`, so you can filter either
way afterwards. RDS rows use the same columns as EBS rows — same categories, age bands and cost
columns — so there's nothing extra to learn to work with them.

When RDS is included, the report adds a "By snapshot type" breakdown. On a default run that table is
left out rather than showing a pointless "100% EBS" row.

Only manual RDS snapshots are considered. Automated snapshots follow RDS's own retention policy, so
they're left alone.

### Filtering and pivoting

The per-snapshot CSVs are the ones to actually work in: one row per snapshot, every dimension on every
row, with the columns you're most likely to filter on placed first:

```
Azure:  SubscriptionName, ResourceGroupName, Location, Name, Ownership, Creator, Category, Action, AgeBand, ...
AWS:    AccountId, Region, SnapshotType, SnapshotId, Name, Ownership, Creator, Category, Action, AgeBand, ...
```

Filter by region, category, ownership or age band, or just drop the whole thing into a pivot table.
Cost columns (`EstMonthlyCost`, `EstAnnualCost`, `Currency`) are on every row, so any subtotal you
build off it will be correct.

`Cost_Summary` is the same data pre-aggregated to one row per combination. It stays at a single grain
throughout, so it filters the same way and its cost column sums to the estate total — handy if you
want the numbers without building your own pivot.

---

## Running it

```powershell
# Azure
Connect-AzAccount
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -OutputPath .\reports

# AWS
.\AWS_Orphaned_Snapshots.ps1 -OutputPath .\reports
```

That deletes nothing. Open the HTML report.

### Then, to actually remove things

```powershell
# 1. Open <Cloud>_Snapshots_Candidates_<timestamp>.csv and delete any row you want to KEEP.
#    Whatever is left in that file is what gets removed.

# 2. Dry run.
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\Azure_Snapshots_Candidates_...csv -Delete -WhatIf

# 3. Do it.
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\Azure_Snapshots_Candidates_...csv -Delete
```

By default only Orphaned snapshots are in scope for deletion. To also go after the bigger pile — old
snapshots whose VM is gone — name it explicitly:

```powershell
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -DeleteScope Orphaned,SourceUnattached -Delete -WhatIf
```

---

## How Commvault snapshots are recognised

Commvault stamps every snapshot it creates, and the scripts just read those stamps. Nothing here is
inferred, and there's nothing to look up anywhere else.

**Azure** — `COMMVAULT` in the snapshot name, and a `CreatedBy=Commvault` tag:

```
Name   linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462023_COMMVAULT_GXMD_SNAP_2db7ab
Tags   CreatedBy = Commvault
```

**AWS** — tags on the snapshot:

```
commvault:vendor      Commvault
commvault:createdBy   Commvault Cloud (M036)
Description           Snapshot_created_by_Commvault_for_job_8465372_at_...
_GX_BACKUP_           (no value)
Name                  SP_2_8465372_40229960_1789636362
```

Each marker is checked independently, so a snapshot that's been renamed or re-tagged by hand is still
recognised. On AWS a snapshot also inherits Commvault ownership from the AMI it backs.

If a `-Delete` run finds no Commvault snapshots at all, it stops before deleting anything. In an
estate that actually runs Commvault, that almost always means the markers missed something rather
than Commvault being absent.

---

## Safety

- Report-only unless you pass `-Delete`.
- `-DeleteScope` defaults to `Orphaned`. Commvault, backup services, keep-tags, locks and
  image-backing snapshots can never be put in scope, even by editing the CSV.
- Two age bars: 30 days for orphans, 365 for anything whose source still exists.
- `-WhatIf` and `-Confirm` are supported, and you have to type `DELETE` unless `-Force` is set.
- `-MaxDeletions` caps a run.
- You choose the list — `-DeleteFromReport` removes exactly the rows left in a file you've reviewed.

Deletion is permanent. Snapshots can't be recovered once removed.

---

## Output files

| File | Contents |
|---|---|
| `*_Snapshot_Report_<ts>.html` | The report. Share this. |
| `*_Snapshots_All_<ts>.csv` | Every snapshot, with category, age, cost and reasoning. |
| `*_Snapshots_Candidates_<ts>.csv` | The deletion list — review this, then feed it back. |
| `*_Cost_Summary_<ts>.csv` | The same data pre-aggregated: one row per region × ownership × category × action × age band. |
| `*_Snapshots_Deleted_<ts>.csv` | What was removed, and what it was costing. Only with `-Delete`. |
| `*_Creator_Evidence_<ts>.csv` | Tags and naming found in the estate. Only with `-AuditCreatorEvidence`. |

Every figure carries its currency and groups thousands (`USD 13,210`).

---

## About the cost figures

Set your own rates before quoting anything:

```powershell
-PricePerGiBMonth 0.05                                    # flat rate
-PriceTable @{ 'standard' = 0.05; 'archive' = 0.0125 }    # per storage tier
-Currency 'GBP'
```

Rates vary by region and agreement, so plug in your own. Two things worth knowing about accuracy:

- AWS figures are close to the real bill, because they use the snapshot's actual billed size rather
  than the volume size.
- Azure figures are an upper bound. Azure doesn't expose a per-snapshot consumed size for incremental
  snapshots, so the cost is calculated against provisioned size — the real bill will usually be lower.

Treat these numbers as a way to prioritise, not as a forecast.

---

## Requirements

**Azure** — PowerShell 7+, and `Az.Accounts`, `Az.Compute`, `Az.Resources`.

**AWS** — PowerShell 7+, and `AWS.Tools.Common`, `AWS.Tools.EC2`. Add `AWS.Tools.RDS` for
`-IncludeRdsSnapshots`, and `AWS.Tools.SecurityToken` so reports carry the account id.

Add `-AutoInstallModules` to install what's missing.

---

## Permissions

Reporting only needs read access. Deletion needs one extra permission on top of that. It's worth
granting the read set first, running a report, and only adding the delete permission once you're
ready to act on it.

### Azure

To report, the built-in Reader role on each subscription in scope is enough — it covers everything
below.

| Action | Used for |
|---|---|
| `Microsoft.Compute/snapshots/read` | Finding the snapshots |
| `Microsoft.Compute/disks/read` | Whether the source disk still exists, and whether a VM is attached |
| `Microsoft.Compute/images/read` | Snapshots backing a Managed Image |
| `Microsoft.Compute/galleries/read`<br>`Microsoft.Compute/galleries/images/read`<br>`Microsoft.Compute/galleries/images/versions/read` | Snapshots backing a Compute Gallery version (skip with `-SkipGalleryCheck`) |
| `Microsoft.Authorization/locks/read` | Honouring resource locks |
| `Microsoft.Resources/subscriptions/read` | Enumerating subscriptions for `-AllSubscriptions` |

To delete, add `Microsoft.Compute/snapshots/delete`. The built-in Disk Snapshot Contributor role
covers it. Contributor also works, but it grants far more than this actually needs.

Least-privilege custom role for the delete step:

```json
{
  "Name": "Snapshot Cleanup",
  "IsCustom": true,
  "Description": "Read snapshot inventory and delete snapshots. No other write access.",
  "Actions": [
    "Microsoft.Compute/snapshots/read",
    "Microsoft.Compute/snapshots/delete",
    "Microsoft.Compute/disks/read",
    "Microsoft.Compute/images/read",
    "Microsoft.Compute/galleries/read",
    "Microsoft.Compute/galleries/images/read",
    "Microsoft.Compute/galleries/images/versions/read",
    "Microsoft.Authorization/locks/read",
    "Microsoft.Resources/subscriptions/read"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/<subscription-id>"]
}
```

### AWS

To report, the AWS-managed `ReadOnlyAccess` policy is more than enough, or use this:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "SnapshotReport",
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeSnapshots",
      "ec2:DescribeVolumes",
      "ec2:DescribeImages",
      "ec2:DescribeRegions",
      "sts:GetCallerIdentity"
    ],
    "Resource": "*"
  }]
}
```

| Action | Used for |
|---|---|
| `ec2:DescribeSnapshots` | Finding the snapshots and their tags |
| `ec2:DescribeVolumes` | Whether the source volume exists, and whether an instance is attached |
| `ec2:DescribeImages` | Snapshots backing an AMI, and inheriting Commvault ownership from it |
| `ec2:DescribeRegions` | Enumerating regions when `-Region` isn't given |
| `sts:GetCallerIdentity` | Labelling the report with the account id (optional) |
| `ec2:DescribeSnapshotAttribute` | Only with `-CheckSharing` |
| `rds:DescribeDBInstances`<br>`rds:DescribeDBClusters`<br>`rds:DescribeDBSnapshots`<br>`rds:DescribeDBClusterSnapshots` | Only with `-IncludeRdsSnapshots` |

To delete, add `ec2:DeleteSnapshot` — plus `rds:DeleteDBSnapshot` and `rds:DeleteDBClusterSnapshot`
if you're including RDS:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "SnapshotDelete",
    "Effect": "Allow",
    "Action": ["ec2:DeleteSnapshot"],
    "Resource": "*"
  }]
}
```

`Resource: "*"` is needed because you don't know which snapshots you'll be deleting until after the
report has run. If you want to narrow it down, add a condition on a tag you control and explicitly
exclude anything you never want touched:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "NeverDeleteCommvaultOrBackupService",
    "Effect": "Deny",
    "Action": ["ec2:DeleteSnapshot"],
    "Resource": "*",
    "Condition": {
      "StringLike": {
        "aws:ResourceTag/commvault:vendor": "*"
      }
    }
  }]
}
```

A Deny like this is a useful backstop — the scripts already refuse to delete Commvault snapshots, and
this makes sure nothing else can either.

### Multiple accounts and subscriptions

Azure reads every subscription the signed-in identity can see, so `Reader` at management-group level
covers a whole tenant. AWS works through one credential profile at a time — pass
`-ProfileName prod,dev` and give each profile its own role.

---

## Common options

| Option | Default | What it does |
|---|---|---|
| `-DeleteScope` | `Orphaned` | Which categories `-Delete` may touch. |
| `-MinAgeDays` | `30` | Ignore orphans younger than this. |
| `-SourceActiveMinAgeDays` | `365` | Age bar for anything whose source still exists. |
| `-Delete` / `-WhatIf` / `-Force` | off | Remove snapshots / dry run / skip the typed confirmation. |
| `-MaxDeletions` | unlimited | Cap a single run. |
| `-DeleteFromReport <csv>` | — | Remove exactly the rows in a reviewed file. |
| `-KeepTagKey` | `DoNotDelete`, `KeepSnapshot`, `Preserve` | Tags that always protect a snapshot. |
| `-AuditCreatorEvidence` | off | Dump the tags and naming found, to check the markers. |
| `-OutputPath` | `.` | Where reports go. |

**Azure only:** `-AllSubscriptions`, `-CurrentSubscription`, `-Subscriptions <names>`,
`-ResourceGroups <wildcards>`, `-SkipGalleryCheck`.

**AWS only:** `-Region <list>` (default: all), `-ProfileName <list>` for multiple accounts,
`-IncludeRdsSnapshots` (off by default — EBS/VM disks only), `-CheckSharing`.

---

## Testing the logic

```powershell
.\Test-SnapshotLogic.ps1
```

192 checks covering the categories, age bars, delete scoping, both clouds' Commvault markers, cost
arithmetic and currency formatting. Runs offline in about a second — worth running any time you change
a marker or an age bar.

---

## Not covered

Azure NetApp Files, AWS FSx/Redshift/DocumentDB, orphaned AMIs themselves, and unattached disks and
volumes.

The classification and reporting code is identical in both scripts, so either one can be copied out
and run on its own. If you change it in one, change it in the other and re-run the tests.
