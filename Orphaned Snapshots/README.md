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

## What this report is for

**Showing a customer what they could save by deleting snapshots Commvault did not create.**

A customer's estate usually contains Commvault's own backup snapshots alongside everything else.
Those are not a saving — deleting them breaks recovery points. So the report does two things:

1. **Identifies Commvault-created snapshots and sets them aside.** They get their own panel at the
   top — count, capacity, annual cost — and are excluded from every other figure. Shown, not hidden,
   so it is obvious they were found rather than missed.
2. **Analyses everything else in full** — the actual opportunity. Category, whether the source disk is
   still attached to a live machine, age range, and cost per category and per range.

Everything below the Commvault panel is the non-Commvault population. The headline number is what
that population costs per year.

Both clouds split cleanly — Commvault's marker is confirmed on each.

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

### AWS — confirmed, via tags

Commvault tags every AWS EBS snapshot it creates:

| Tag | Value |
|---|---|
| `commvault:vendor` | `Commvault` |
| `commvault:createdBy` | `Commvault Cloud (M036)` |
| `Description` | `Snapshot_created_by_Commvault_for_job_8465372_at_1789636362._Source_Volume_vol-...` |
| `_GX_BACKUP_` | *(no value)* |
| `Name` | `SP_2_8465372_40229960_1789636362` |

The default `-CommvaultTagKey 'commvault'` matches the two `commvault:*` keys, their values, **and**
the `Description` tag's wording — three independent catches from one pattern, so no single tag being
renamed or dropped loses the snapshot. `_GX_BACKUP_` is a fourth, and the `Name` form
`SP_<n>_<jobid>_<n>_<epoch>` a fifth.

**Mind the two different "descriptions".** Commvault's own wording lives in a **`Description` tag**.
The **native EC2 description field** is AWS boilerplate — `Created by CreateImage(i-...) for ami-...` —
because Commvault drives `CreateImage`. Only the tag is a marker.

Because Commvault goes via `CreateImage`, a snapshot may also carry no marker of its own, so the
script additionally **inherits ownership from the AMI the snapshot backs**.

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
| `*_Snapshot_Report_<ts>.html` | Annual-cost headline, the **Commvault panel**, per-category tiles, a **cost-by-category table**, a **cost by category × age grid** with per-age-range totals, the in-scope and held-for-review tables, and a whole-estate by-creator breakdown. |
| `*_Cost_Summary_<ts>.csv` | Cost rolled up by category, by category × age, and by action, with monthly, annual and share-of-spend. |
| `*_Snapshots_Deleted_<ts>.csv` | Deletion log with per-snapshot success/failure. Only when `-Delete` runs. |
| `*_Creator_Evidence_<ts>.csv` | Tag pairs, tag keys, name prefixes and masked description templates. Only with `-AuditCreatorEvidence`. |

Reports are always written, including under `-WhatIf`.

The heatmap is the quickest read in the report: it puts capacity against age, so "most of my money is
in `SourceActive` / `Over 365 days`" is a single glance rather than a spreadsheet exercise. It renders
in light and dark mode and works down to phone width.

### Cost

Every snapshot carries `EstMonthlyCost` and `EstAnnualCost`, and the report answers the money question
in three places: the headline (annual cost reclaimable on this run), the per-category tiles, and the
**cost-by-category table** — snapshots, capacity, per month, per year, share of spend, and whether the
category is deletable at all.

`Get-CostSummary` also writes `*_Cost_Summary_<ts>.csv`, which rolls the same numbers up three ways in
one file, so a finance conversation does not need a pivot table:

| Grouping | Rows |
|---|---|
| `Ownership` | Commvault vs Not Commvault — the headline split |
| `Age band (not Commvault)` | cost per age range, excluding Commvault |
| `Category` | one per category |
| `Category x Age` | each category split across the age bands |
| `Action` | `Delete` (what this run actually saves), `Review`, `Keep` |
| `Total` | the whole estate |

**Set your own rates before quoting a figure.** `-PricePerGiBMonth` (default `0.05`) is the fallback,
and `-PriceTable` maps individual storage tiers — this matters, because an AWS archive-tier snapshot is
roughly a quarter the price of a standard one and Azure ZRS costs more than LRS, so one flat rate
across tiers produces a confidently wrong number:

```powershell
# Azure
-PriceTable @{ 'Standard_LRS' = 0.05; 'Standard_ZRS' = 0.0625 }

# AWS
-PriceTable @{ 'standard' = 0.05; 'archive' = 0.0125 }
```

Rates vary by region and agreement, so put your own in. One caveat that no rate fixes: costs are
calculated against **provisioned** size, while Azure incremental snapshots and AWS EBS snapshots both
bill only on changed blocks. The real saving is therefore usually **lower** than shown. Treat these as
an upper bound for prioritising, not a forecast.

**AWS is more accurate than Azure here.** The AWS script uses the snapshot's *full snapshot size* — the
figure the console shows and the one AWS bills — whenever the API returns it, keeping the volume size
in `ProvisionedGiB` for reference. The difference is large: an 8 GiB volume commonly yields a 2.16 GiB
snapshot, and a 500 GiB volume a 50 GiB one, so costing the volume size would overstate the bill
several times over. Azure has no equivalent per-snapshot figure for incremental snapshots, so Azure
costs remain against provisioned size and stay an upper bound.

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
| `-CommvaultNamePattern` / `-CommvaultTagKey` | Azure: `COMMVAULT`, `GXMD_SNAP` / `Commvault`. AWS: `^SP_\d+_\d+_\d+_\d+` etc / `commvault`, `_GX_BACKUP_`. | Commvault markers. Confirmed against real snapshots on both clouds. |
| `-IncludeCommvaultSnapshots` | off | Move Commvault snapshots out of `Protected`. Not recommended. |
| `-IncludeBackupServiceSnapshots` | off | Move cloud backup-service snapshots out of `Protected`. Strongly discouraged. |
| `-KeepTagKey` | `DoNotDelete`, `KeepSnapshot`, `Preserve` | Tag keys that force `Protected`. |
| `-Delete` | off | Actually delete. Supports `-WhatIf` / `-Confirm`. |
| `-Force` | off | Skip the interactive `Type DELETE to proceed` gate, for scheduled runs. |
| `-MaxDeletions` | `0` (no cap) | Stop after N successful deletions. |
| `-DeleteFromReport` | — | Delete exactly the rows in a reviewed CSV. |
| `-PricePerGiBMonth` | `0.05` | Fallback rate per GiB/month for any tier `-PriceTable` does not name. |
| *(AWS)* `SizeGiB` vs `ProvisionedGiB` | — | AWS costs on **full snapshot size** (what it actually bills) when the API reports it, with the volume size kept alongside for reference. |
| `-PriceTable` | — | Per-tier rates, e.g. `@{ 'archive' = 0.0125 }`. Set these before quoting a figure. |
| `-Currency` | `USD` | Label only; no conversion is done. |
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
`-DeleteScope` on a scheduled run until you have watched the `Review` list settle. Confirm the creator counts against what Commvault reports it is protecting before scheduling either
script with `-Delete` — nobody is watching the output.

---

## Tests

```powershell
.\Test-SnapshotLogic.ps1          # add -Verbose to list every passing test
```

164 assertions over the category rules, the ownership split,, precedence, age bars, delete scoping, cost arithmetic and
per-tier pricing, the cost roll-ups, the zero-detection guard,
both clouds' Commvault markers (asserted against the real snapshot names, tags and descriptions taken
from the Azure portal and the AWS console, with each AWS tag checked to stand alone), AMI creator
inheritance, description templating, Azure lock scoping, the AWS `vol-ffffffff` sentinel,
and regression guards on two PowerShell collection-unrolling traps that shipped and were only caught
by running the scripts end to end. It parses the two scripts to lift
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
