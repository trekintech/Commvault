# Cloud-Native Snapshot Reporting & Cleanup

Two scripts that classify every **cloud-native** snapshot in an estate — snapshots **not created by
Commvault** — show where the capacity actually sits, and delete only what you explicitly put in scope.

| File | What it does |
|---|---|
| `Azure_Orphaned_Snapshots.ps1` | Azure managed disk snapshots |
| `AWS_Orphaned_Snapshots.ps1` | AWS EBS snapshots, plus manual RDS instance/cluster snapshots |
| `Test-SnapshotLogic.ps1` | Offline tests for the classification rules. No cloud, no credentials. |

Both are **report-only by default**. Nothing is deleted unless you pass `-Delete`.

---

## "Orphaned" is the small half of the problem

A snapshot is only literally orphaned when its source disk or volume is *gone*. That set is real, but
it is usually not where the money is. The bigger pile is snapshots whose source is alive and well —
someone's pre-upgrade snapshot from two years ago that nobody ever deleted. Those are not orphans, and
calling them orphans would be wrong, but they are still billing every month.

So both scripts report **five categories**, always, and never collapse them:

| Category | Meaning | In the default delete scope? |
|---|---|---|
| **Orphaned** | Source disk/volume is provably gone. The literal orphan. | **Yes** |
| **SourceUnattached** | Source disk/volume still exists but is attached to **nothing** — the VM/instance was deleted and its disk left behind. One step from orphaned. | No, opt in |
| **SourceActive** | Source exists *and* is attached to a live machine. Not an orphan — judge it on age. | No, opt in |
| **Unverifiable** | No provable source (Azure imports; AWS `vol-ffffffff` copies). | No, opt in |
| **InUse** | Backing a Managed Image / Gallery version / AMI. | **Never** |
| **Protected** | Commvault, a cloud backup service, a keep-tag, a lock, or shared out. | **Never** |

`SourceUnattached` is usually the most interesting row after `Orphaned`: the machine is gone, nobody
deleted the disk, and nobody deleted its snapshots either.

Category is a *fact about the snapshot*. What the script would *do* about it is a separate column:

| Action | Meaning |
|---|---|
| `Delete` | Its category is in `-DeleteScope` **and** it is past that category's age bar. |
| `Review` | A candidate held back — wrong category for the current scope, or too young. |
| `Keep` | `InUse` or `Protected`. Never actionable. |

Keeping these apart means the report reads the same whatever flags you passed. Only the **Action**
column moves. You can see your whole `SourceActive` pile without ever putting it in danger.

### Two age bars, not one

| Bar | Applies to | Default |
|---|---|---|
| `-MinAgeDays` | `Orphaned` | 30 days |
| `-SourceActiveMinAgeDays` | `SourceUnattached`, `SourceActive`, `Unverifiable` | 365 days |

Deleting a snapshot whose source is provably gone is a small call. Deleting one whose disk is still
live is a much bigger one, so it has to clear a much higher bar even after you scope it in.

---

## The workflow: report, review, then delete

Deletion is a **post-run option**, never part of the first pass.

```powershell
# 1. Report. Deletes nothing. Run this as often as you like.
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -OutputPath .\reports

# 2. Open the HTML report. Check the "By creator" table, then look at the heatmap to see
#    whether your capacity is in Orphaned or (more likely) in old SourceActive snapshots.

# 3. Open Azure_Snapshots_Candidates_<ts>.csv and DELETE ANY ROW YOU WANT TO KEEP.
#    Whatever is left in that file is what gets deleted.

# 4. Dry run against the approved file.
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\Azure_Snapshots_Candidates_20260916-101500.csv -Delete -WhatIf

# 5. Execute.
.\Azure_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\Azure_Snapshots_Candidates_20260916-101500.csv -Delete
```

`Protected` and `InUse` rows are refused even if someone pastes them into that CSV by hand.

The AWS script is identical in shape:

```powershell
.\AWS_Orphaned_Snapshots.ps1 -ProfileName prod -IncludeRdsSnapshots -CheckSharing -OutputPath .\reports
.\AWS_Orphaned_Snapshots.ps1 -DeleteFromReport .\reports\AWS_Snapshots_Candidates_20260916-101500.csv -Delete
```

### Going after the SourceActive pile

Once the report has convinced you, widen the scope deliberately:

```powershell
# Snapshots whose VM was deleted but whose disk was left behind - the usual next step after orphans.
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -DeleteScope Orphaned,SourceUnattached -Delete -WhatIf

# Be stricter than the default: only snapshots whose disk is alive but which are 18 months old.
.\Azure_Orphaned_Snapshots.ps1 -AllSubscriptions -DeleteScope Orphaned,SourceActive -SourceActiveMinAgeDays 540
```

`-DeleteScope` only accepts `Orphaned`, `SourceUnattached`, `SourceActive` and `Unverifiable`.
`Protected` and `InUse` cannot be named at all.

---

## Commvault detection

### Azure — definitive

Commvault stamps every Azure snapshot it creates with `COMMVAULT` in the resource name **and** a
`CreatedBy=Commvault` tag. A real example from the portal:

```
Name   linuxbgwsc2_OsDisk_1_0609a2bb0_ide_0_8462023_COMMVAULT_GXMD_SNAP_2db7ab
Tags   CreatedBy   = Commvault
       Description = Created by jobID [8462023] at [09/16/2026,09:05:37] from [mas02036c1us02]
```

The script checks the name and the tags **independently**, so a snapshot renamed by hand is still
caught by its tag, and one re-tagged by hand is still caught by its name. This is a read of a marker
Commvault actually writes, not an inference — **Azure classification is reliable.** Nothing needs to be
queried from Commvault, and there is no list to export.

Defaults: `-CommvaultNamePattern 'COMMVAULT','GXMD_SNAP'` and `-CommvaultTagKey 'Commvault'` (matched
against tag keys and values). Both stay parameterised if an unusual deployment needs widening.

### AWS — provisional

**No equivalent confirmed marker has been identified for AWS yet.** The AWS defaults (`^CV_`,
`commvault`, `_GX_BACKUP_`, `_GX_AMI_` and friends, matched against the `Name` tag and the snapshot
description) are plausible but **unverified**. Treat AWS Commvault classification as provisional until
a real marker is confirmed.

To find it, run the evidence audit against an account where Commvault is known to be protecting
something:

```powershell
.\AWS_Orphaned_Snapshots.ps1 -Region eu-west-1 -AuditCreatorEvidence
```

That writes `AWS_Creator_Evidence_<ts>.csv` containing four kinds of row:

| Evidence | What it shows | Why it matters |
|---|---|---|
| `TagPair` | Every distinct `key=value` shared by more than one snapshot, **rarest first** | This is what found Azure's marker — `CreatedBy=Commvault` appears immediately. A product marker is rarer than `env`/`owner` tags, so it sorts to the top. |
| `TagKey` | Every distinct tag key, with counts | Catches a marker key whose value varies per job |
| `DescriptionPattern` | Descriptions with digits, timestamps, GUIDs and hex **masked** | Raw descriptions are all unique because of job ids. Masked, Commvault's `Created by jobID [<n>] at [<timestamp>] from [<host>]` collapses into one counted template. If Commvault writes the same description in AWS as it does in Azure, **this row will find it.** |
| `NamePrefix` | The leading token of each name | Catches a naming convention |

When you find the marker, set it and AWS becomes as reliable as Azure:

```powershell
.\AWS_Orphaned_Snapshots.ps1 -CommvaultNamePattern '<what you found>' -CommvaultTagKey '<marker>'
```

### The zero-detection guard (both clouds)

If a `-Delete` run finds **no** Commvault snapshots at all, it aborts before deleting anything — in an
estate running Commvault that means the markers missed, not that Commvault is absent. Override with
`-AcknowledgeNoCommvaultSnapshots` only when Commvault genuinely protects nothing in that scope.

This catches total detection failure, not partial. It is a backstop, not a substitute for confirming
the marker — which matters much more for AWS than for Azure right now.

Deletion is permanent. Azure snapshots and EBS snapshots cannot be recovered once removed.

---

## What else is excluded

Beyond Commvault, both scripts classify the cloud providers' own backup artefacts as `Protected`:

| Azure | AWS |
|---|---|
| Azure Backup (resource group `AzureBackupRG_*`) | AWS Backup (tag `aws:backup:*`) |
| Azure Site Recovery (name `asr-*`) | DLM lifecycle-managed (tag `aws:dlm:*`, description `Created for policy: policy-*`) |
| Resource locks | Snapshots shared to another account (with `-CheckSharing`) |
| Keep-tags | AWS-managed / marketplace (owner alias `amazon`) |

DLM and AWS Backup expire their own snapshots on a schedule. Deleting one out from under its policy
breaks the recovery point *and* the policy just makes another. `-IncludeBackupServiceSnapshots` exists
to override this, and is strongly discouraged.

---

## Requirements

**Azure** — PowerShell 7+, and `Az.Accounts`, `Az.Compute`, `Az.Resources`.

```powershell
Install-Module Az.Accounts, Az.Compute, Az.Resources -Scope CurrentUser
Connect-AzAccount
```

Permissions: `Reader` to report. To delete, `Disk Snapshot Contributor` (or `Contributor`) on the scope.

**AWS** — PowerShell 7+, and `AWS.Tools.Common`, `AWS.Tools.EC2`. Add `AWS.Tools.RDS` for
`-IncludeRdsSnapshots`, and `AWS.Tools.SecurityToken` so reports carry the account id.

```powershell
Install-Module AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.SecurityToken -Scope CurrentUser
Set-AWSCredential -AccessKey ... -SecretKey ... -StoreAs prod
```

To report: `ec2:DescribeSnapshots`, `ec2:DescribeVolumes`, `ec2:DescribeImages`, `ec2:DescribeRegions`,
`sts:GetCallerIdentity` (plus `ec2:DescribeSnapshotAttribute` for `-CheckSharing`, `rds:DescribeDB*`
for RDS). To delete, add `ec2:DeleteSnapshot` and `rds:DeleteDBSnapshot` / `rds:DeleteDBClusterSnapshot`.

Both scripts accept `-AutoInstallModules`.

---

## Output

Written to `-OutputPath` (default: current directory), timestamped:

| File | Contents |
|---|---|
| `*_Snapshots_All_<ts>.csv` | Every snapshot, with `Category`, `AgeBand`, `Action`, `Reason` and `ActionNote`. Start here. |
| `*_Snapshots_Candidates_<ts>.csv` | The `Action = Delete` set — the file to review and feed to `-DeleteFromReport`. |
| `*_Snapshot_Report_<ts>.html` | Hero total, per-category tiles, a **category × age heatmap**, the in-scope and held-for-review tables, and the by-creator breakdown. |
| `*_Snapshots_Deleted_<ts>.csv` | Deletion log with per-snapshot success/failure. Only when `-Delete` runs. |
| `*_Creator_Evidence_<ts>.csv` | Tag pairs, tag keys, name prefixes and masked description templates. Only with `-AuditCreatorEvidence`. |

Reports are always written, including under `-WhatIf`.

The heatmap is the quickest read in the report: it puts capacity against age, so "most of my money is
in `SourceActive` / `Over 365 days`" is a single glance rather than a spreadsheet exercise. It renders
in light and dark mode and works down to phone width.

### About the cost estimate

`-PricePerGiBMonth` (default `0.05`) is applied to **provisioned** size for an order-of-magnitude
figure. Azure incremental snapshots and AWS EBS snapshots both bill only on changed blocks, so the real
saving is usually lower. Use it to prioritise, not to forecast.

---

## Key parameters

Shared by both scripts:

| Parameter | Default | Purpose |
|---|---|---|
| `-MinAgeDays` | `30` | Age bar for `Orphaned`. |
| `-SourceActiveMinAgeDays` | `365` | Age bar for `SourceActive` and `Unverifiable`. |
| `-DeleteScope` | `Orphaned` | Which categories `-Delete` may act on. `Protected`/`InUse` not accepted. |
| `-AuditCreatorEvidence` | off | Write a CSV of tag pairs, tag keys, name prefixes and masked description templates — how you find a marker you don't know yet. |
| `-AcknowledgeNoCommvaultSnapshots` | off | Permit `-Delete` when zero Commvault snapshots were detected. Otherwise that aborts. |
| `-CommvaultNamePattern` / `-CommvaultTagKey` | Azure: `COMMVAULT`, `GXMD_SNAP` / `Commvault`. AWS: provisional. | Commvault markers. Definitive on Azure; still being confirmed on AWS. |
| `-IncludeCommvaultSnapshots` | off | Move Commvault snapshots out of `Protected`. Not recommended. |
| `-IncludeBackupServiceSnapshots` | off | Move cloud backup-service snapshots out of `Protected`. Strongly discouraged. |
| `-KeepTagKey` | `DoNotDelete`, `KeepSnapshot`, `Preserve` | Tag keys that force `Protected`. |
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

For an unattended cleanup, `-Force` skips the interactive gate. Keep `-MaxDeletions` as a blast-radius
cap, keep the scope narrow, and keep the logs.

```powershell
.\AWS_Orphaned_Snapshots.ps1 -ProfileName prod -MinAgeDays 90 -Delete -Force `
  -MaxDeletions 50 -OutputPath \\fileserver\reports\snapshots
```

Report for several weeks before letting anything delete on a schedule, and do not widen
`-DeleteScope` on a scheduled run until you have watched the `Review` list settle. **Do not schedule
the AWS script with `-Delete` until its Commvault marker is confirmed** — nobody is watching the output.

---

## Tests

```powershell
.\Test-SnapshotLogic.ps1          # add -Verbose to list every passing test
```

94 assertions over the category rules, precedence, age bars, delete scoping, the zero-detection guard,
Azure's confirmed Commvault markers (asserted against the real snapshot name and tags from the portal),
AWS's provisional ones, description templating, Azure lock scoping, the AWS `vol-ffffffff` sentinel,
and a regression guard on collection returns. It parses the two scripts to lift
their functions out, so it never touches a cloud and needs no credentials. **Run it after changing any
detection pattern or age bar.**

---

## Notes and limitations

- **Azure incremental snapshot chains** are handled by Azure itself — deleting one snapshot in a chain
  does not invalidate the others, so no special ordering is needed.
- **AWS sharing** is only checked with `-CheckSharing` (one extra API call per candidate). Without it,
  a snapshot shared to another account can be classified as deletable. Use it before any real cleanup.
  If the sharing attribute cannot be read, the snapshot is treated as shared and kept.
- **Cross-account AWS runs** iterate `-ProfileName`; each profile needs its own stored credential.
- **RDS**: only *manual* snapshots are considered. Automated snapshots follow RDS's own retention.
- **The classification and reporting block is byte-identical in both scripts.** They are kept
  standalone (matching the rest of this repo) rather than sharing a module, so either can be copied to
  a jump box on its own. If you change that block in one, change it in the other and re-run the tests.
- **Not covered**: Azure NetApp Files snapshots, AWS FSx/Redshift/DocumentDB snapshots, orphaned AMIs
  themselves (as opposed to their snapshots), and unattached disks/volumes. Unattached Azure disks are
  already handled by `Azure Sizing/Azure_Extended.ps1`.
- Reporting is safe to run at any time. Deletion is not reversible.
