# Cloud Snapshot Savings Report

Find out what a cloud estate is spending on snapshots **Commvault did not create** — and remove them
safely.

| File | What it does |
|---|---|
| `Azure_Orphaned_Snapshots.ps1` | Azure managed disk snapshots |
| `AWS_Orphaned_Snapshots.ps1` | AWS EBS snapshots, plus manual RDS snapshots |
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
| `*_Cost_Summary_<ts>.csv` | Cost by owner, category, age band and action. For finance. |
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

**Azure** — PowerShell 7+, `Az.Accounts`, `Az.Compute`, `Az.Resources`. `Reader` to report;
`Disk Snapshot Contributor` to delete.

**AWS** — PowerShell 7+, `AWS.Tools.Common`, `AWS.Tools.EC2` (plus `AWS.Tools.RDS` for
`-IncludeRdsSnapshots`, `AWS.Tools.SecurityToken` for account ids). Describe permissions to report;
`ec2:DeleteSnapshot` to delete.

Add `-AutoInstallModules` to install what is missing.

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
`-IncludeRdsSnapshots`, `-CheckSharing`.

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
volumes. RDS covers manual snapshots only — automated ones follow RDS retention.

The classification and reporting code is identical in both scripts, so each can be copied and run on its
own. Change it in one, change it in the other, and re-run the tests.
