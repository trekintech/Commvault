# Cloud Snapshot Savings Report

Find out what a cloud estate is spending on snapshots **Commvault did not create** — and remove them
safely.

| File | What it does |
|---|---|
| `Azure_Orphaned_Snapshots.ps1` | Azure managed disk snapshots |
| `AWS_Orphaned_Snapshots.ps1` | AWS EBS snapshots (VM disks). Manual RDS snapshots with `-IncludeRdsSnapshots`. |
| `Test-SnapshotLogic.ps1` | Offline self-test. No cloud, no credentials. |

Both scripts are **report-only by default**. Nothing is deleted unless you pass `-Delete`.

---

## The problem

Snapshots outlive whatever they were taken from. Delete an Azure disk and its snapshots stay. Deregister
an AWS AMI and the snapshots behind it stay. Nobody notices, because neither cloud shows you "snapshots
with nothing behind them" — and they bill every month, forever.

A customer's estate also contains Commvault's own backup snapshots. Those are **not** a saving; deleting
them breaks recovery points. So the report separates the two and only ever counts the rest.

---

## What you get

Run it and you get a terminal summary, an HTML report to share, and CSVs to work from.

**1. Commvault's own snapshots, identified and set aside.** Counted, costed, and excluded from every
other figure — shown so it is clear they were found, not missed.

**2. Everything else, broken down by why it is still there:**

| Category | Meaning |
|---|---|
| **Orphaned** | The disk or volume is **gone**. Nothing to restore, nobody to ask. |
| **SourceUnattached** | The disk still exists but its **VM was deleted**. One step from orphaned. |
| **SourceActive** | Attached to a live machine. Not an orphan — judge it on age. |
| **Unverifiable** | No provable source. Needs a human. |
| **InUse** | Backing a live image or AMI. Leave alone. |
| **Protected** | Azure Backup, Site Recovery, AWS Backup, DLM, keep-tags, locks. |

**3. What each of those costs**, per month and per year, and what share of the bill it is.

**4. Cost by age**, so "snapshots older than a year are costing us X" is one glance.

**5. Cost by region** — and by subscription and resource group on Azure, by account on AWS — so you can
see where the spend sits. Each is shown both for the whole estate and excluding Commvault. A breakdown
with only one value (a single-region estate) is skipped rather than repeating the total.

### What gets scanned

**By default the AWS script covers VM disks only** — EBS snapshots. Databases are a separate
conversation with a separate owner, so RDS is opt-in:

```powershell
.\AWS_Orphaned_Snapshots.ps1                          # EBS only
.\AWS_Orphaned_Snapshots.ps1 -IncludeRdsSnapshots      # EBS + manual RDS instance and cluster snapshots
```

Every row carries a `SnapshotType` of `EBS`, `RDS-Instance` or `RDS-Cluster`, so you can filter either
way after the fact. RDS rows have exactly the same columns as EBS rows — same categories, same age
bands, same cost columns — so nothing special is needed to work with them.

When RDS is included, the report adds a **By snapshot type** breakdown. On a default run that table is
hidden rather than showing a pointless "100% EBS" row.

Only *manual* RDS snapshots are considered. Automated ones follow RDS's own retention and are not
yours to delete.

### Filtering and pivoting

**The per-snapshot CSVs are the ones to work in.** One row per snapshot, every dimension on every row,
with the columns you filter on first:

```
Azure:  SubscriptionName, ResourceGroupName, Location, Name, Ownership, Creator, Category, Action, AgeBand, ...
AWS:    AccountId, Region, SnapshotType, SnapshotId, Name, Ownership, Creator, Category, Action, AgeBand, ...
```

Filter by region, by category, by ownership, by age band — or drop the lot into a pivot table. Costs
(`EstMonthlyCost`, `EstAnnualCost`, `Currency`) are on every row, so any subtotal you build is correct.

`Cost_Summary` is the same data pre-aggregated to one row per combination. It is a single grain
throughout, so it filters the same way and its cost column sums to the estate total — useful if you
want the numbers without building a pivot.

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

By default only **Orphaned** snapshots are ever in scope. To go after the bigger pile — old snapshots
whose VM is gone — name it explicitly:

```powershell
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -DeleteScope Orphaned,SourceUnattached -Delete -WhatIf
```

---

## How Commvault snapshots are recognised

Commvault stamps the snapshots it creates. The scripts read those stamps — nothing is inferred, and
nothing needs to be looked up anywhere else.

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

Each marker is checked independently, so a snapshot that has been renamed or re-tagged by hand is still
recognised. On AWS a snapshot also inherits Commvault ownership from the AMI it backs.

If a `-Delete` run finds **no** Commvault snapshots at all, it stops before deleting anything — in an
estate running Commvault that means the markers missed, not that Commvault is absent.

---

## Safety

- **Report-only unless you pass `-Delete`.**
- **`-DeleteScope` defaults to `Orphaned`.** Commvault, backup services, keep-tags, locks and
  image-backing snapshots can never be put in scope, even by editing the CSV.
- **Two age bars.** 30 days for orphans; 365 for anything whose source still exists.
- **`-WhatIf` and `-Confirm`** are supported, and you must type `DELETE` unless `-Force` is set.
- **`-MaxDeletions`** caps a run.
- **You choose the list.** `-DeleteFromReport` removes exactly the rows left in a file you reviewed.

Deletion is permanent. Snapshots cannot be recovered once removed.

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

Rates vary by region and agreement. Two things to know about accuracy:

- **AWS figures are close.** They use the snapshot's real billed size, not the volume size.
- **Azure figures are an upper bound.** Azure gives no per-snapshot consumed size for incremental
  snapshots, so cost is calculated against provisioned size and the real bill will be lower.

Use these to prioritise, not to forecast.

---

## Requirements

**Azure** — PowerShell 7+, and `Az.Accounts`, `Az.Compute`, `Az.Resources`.

**AWS** — PowerShell 7+, and `AWS.Tools.Common`, `AWS.Tools.EC2`. Add `AWS.Tools.RDS` for
`-IncludeRdsSnapshots`, and `AWS.Tools.SecurityToken` so reports carry the account id.

Add `-AutoInstallModules` to install what is missing.

---

## Permissions

Reporting needs read access only. Deletion needs one extra permission on top. Grant the read set
first, run it, and only add the delete permission when you are ready to act.

### Azure

**To report** — the built-in **Reader** role on each subscription in scope is enough. It covers
everything below.

| Action | Used for |
|---|---|
| `Microsoft.Compute/snapshots/read` | Finding the snapshots |
| `Microsoft.Compute/disks/read` | Whether the source disk still exists, and whether a VM is attached |
| `Microsoft.Compute/images/read` | Snapshots backing a Managed Image |
| `Microsoft.Compute/galleries/read`<br>`Microsoft.Compute/galleries/images/read`<br>`Microsoft.Compute/galleries/images/versions/read` | Snapshots backing a Compute Gallery version (skip with `-SkipGalleryCheck`) |
| `Microsoft.Authorization/locks/read` | Honouring resource locks |
| `Microsoft.Resources/subscriptions/read` | Enumerating subscriptions for `-AllSubscriptions` |

**To delete**, add `Microsoft.Compute/snapshots/delete`. The built-in **Disk Snapshot Contributor**
role covers it; **Contributor** also works but grants far more than this needs.

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

**To report** — the AWS-managed **`ReadOnlyAccess`** policy is more than enough, or use this:

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
| `ec2:DescribeRegions` | Enumerating regions when `-Region` is not given |
| `sts:GetCallerIdentity` | Labelling the report with the account id (optional) |
| `ec2:DescribeSnapshotAttribute` | Only with `-CheckSharing` |
| `rds:DescribeDBInstances`<br>`rds:DescribeDBClusters`<br>`rds:DescribeDBSnapshots`<br>`rds:DescribeDBClusterSnapshots` | Only with `-IncludeRdsSnapshots` |

**To delete**, add `ec2:DeleteSnapshot` — plus `rds:DeleteDBSnapshot` and
`rds:DeleteDBClusterSnapshot` if you are including RDS:

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

`Resource: "*"` is required because the snapshots to delete are not known until the report has run.
To narrow it, scope the delete statement with a condition on a tag you control, and exclude anything
you never want touched:

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

A Deny like that is a useful backstop: the scripts already refuse to delete Commvault snapshots, and
this stops anything else doing so either.

### Multiple accounts and subscriptions

Azure reads every subscription the signed-in identity can see, so `Reader` at management-group level
covers a whole tenant. AWS uses one credential profile at a time — pass `-ProfileName prod,dev` and
give each profile its own role.

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

220 checks covering the categories, age bars, delete scoping, both clouds' Commvault markers, cost
arithmetic and currency formatting. Runs offline in a second. **Run it if you change a marker or an age
bar.**

---

## Not covered

Azure NetApp Files, AWS FSx/Redshift/DocumentDB, orphaned AMIs themselves, and unattached disks and
volumes.

The classification and reporting code is identical in both scripts, so each can be copied and run on its
own. Change it in one, change it in the other, and re-run the tests.
