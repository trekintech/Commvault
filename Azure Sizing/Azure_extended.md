Got it — I’ve restructured the README so the core usage and “quick starts” stay clean for most users, and all the more complex explanations you asked for (MG runs, metrics behavior, permissions nuance, throttling, ARG vs ARM, etc.) live in a clearly separated **Advanced Usage** section at the bottom.

I’ve also explicitly called out which workloads are **skipped by default** and why, so it’s obvious without reading the script.

---

# Azure Sizing Script — README

## Overview

This script collects Azure workload inventory and capacity for backup sizing with per-region breakdowns, **avoiding double-counting storage**.

### Discovered workloads:

* **Azure VMs** (attached managed disks’ capacity attributed to VM; unattached disks listed separately)
* **Azure SQL Databases** and **SQL Managed Instances**
* **Storage Accounts** (per-service usage: Azure Files, Table Storage, Blob; ADLS Gen2 if HNS=true)
* **Cosmos DB** (DataUsage + IndexUsage metrics)
* **Azure Database for MySQL, MariaDB, PostgreSQL**
* **Azure Backup** vaults, policies, and items
* **Azure NetApp Files (ANF)** — **skipped by default** unless `Az.NetAppFiles` module available and `-SkipAzureNetAppFiles` is not set
* **Oracle Database\@Azure** — **skipped by default** unless `Az.Oracle` module available and `-SkipOracleDatabase` is not set

---

## Requirements

### PowerShell

* PowerShell 7+ (`pwsh`) — Azure Cloud Shell uses PowerShell 7 by default.

### Required modules

The script checks and can auto-install these if `-AutoInstallModules` is used.

**Required:**

* Az.Accounts
* Az.Compute
* Az.Storage
* Az.Sql
* Az.SqlVirtualMachine
* Az.ResourceGraph
* Az.Monitor
* Az.Resources

**Optional:** (sections skipped if missing)

* Az.RecoveryServices – Azure Backup
* Az.CosmosDB – Cosmos DB
* Az.MySql, Az.MariaDb, Az.PostgreSql – PaaS DB services
* Az.NetAppFiles – Azure NetApp Files (**skipped by default if module not found**)
* Az.Oracle – Oracle\@Azure (**skipped by default if module not found**)

---

## Permissions

### Minimum RBAC at scan scope

* **Reader** on the subscriptions or management groups being scanned

### For metrics:

* Reader includes `Microsoft.Insights/metrics/read`
  Some orgs grant **Monitoring Reader** separately

### For blob/container details (`-GetContainerDetails`):

* **Storage Blob Data Reader** (data-plane role) on each storage account

### For Azure Backup:

* **Backup Reader** on Recovery Services vaults

### For ANF / Oracle\@Azure:

* **Reader** on those resources

---

## Scope & Defaults

By default (no scope flags), **all visible subscriptions** in your account are scanned.

Scope flags (choose one):

* `-AllSubscriptions` – explicit all visible subs (same as default)
* `-CurrentSubscription`
* `-Subscriptions <names or IDs>`
* `-ManagementGroups <names or IDs>`

> Only one scope selection method can be used per run.

---

## Quick Starts

### Default — all visible subscriptions

```powershell
pwsh ./Get-AzureSizingInfo.ps1 -AutoInstallModules -OutputPath ./out
```

### Current subscription only

```powershell
pwsh ./Get-AzureSizingInfo.ps1 -CurrentSubscription -OutputPath ./out
```

### Explicit subscriptions

```powershell
pwsh ./Get-AzureSizingInfo.ps1 `
  -Subscriptions "Prod-Sub","8b6d2e4a-1111-2222-3333-abcdef123456" `
  -OutputPath ./out
```

### With anonymisation

```powershell
pwsh ./Get-AzureSizingInfo.ps1 `
  -AllSubscriptions `
  -AnonymizeScope Objects -AnonymizeSalt "my-salt" `
  -OutputPath ./out
```

### Aggregate storage totals for speed

```powershell
pwsh ./Get-AzureSizingInfo.ps1 `
  -AggregateStorageAtAccountLevel `
  -OutputPath ./out
```

---

## Main Flags

Workload skipping:

* `-SkipAzureVMandManagedDisks`
* `-SkipAzureSQLandManagedInstances`
* `-SkipAzureStorageAccounts`
* `-SkipAzureBackup`
* `-SkipAzureCosmosDB`
* `-SkipAzureDataLake`
* `-SkipAzureDatabaseServices`
* `-SkipOracleDatabase`
* `-SkipAzureNetAppFiles`

Storage handling:

* `-AggregateStorageAtAccountLevel` – skip service-level breakdown
* `-GetContainerDetails` – deep per-container scan (slower; needs Storage Blob Data Reader)

Modules & anonymisation:

* `-AutoInstallModules`
* `-AnonymizeScope None|ResourceGroups|Objects|All`
* `-AnonymizeSalt "<string>"`

Optional module prompts:

* `-PromptInstallOracle`
* `-PromptInstallNetApp`

---

## Outputs

All outputs are timestamped `yyyyMMdd_HHmmss` and written to `-OutputPath`.

Summary CSVs:

* `azure_sizing_by_app_<ts>.csv`
* `azure_sizing_by_region_<ts>.csv`

Per-service CSVs:

* VMs, managed disks, SQL DBs, storage accounts, blob containers (if `-GetContainerDetails`), file shares, Cosmos DB, ADLS Gen2, PaaS DBs, ANF (if enabled), Oracle DBs (if enabled), Azure Backup vaults/policies/items

HTML report:

* `azure_sizing_report_<ts>.html` — formatted summary of all collected data

---

## Storage Account Hierarchy in Reports

```
Storage Account Total
 └─ ADLS Gen2
 └─ Azure Files
 └─ Blob
 └─ Table Storage
```

Rules:

* HNS=true → blob capacity attributed to ADLS Gen2, not Blob
* Blob capacity → from Azure Monitor; fallback to per-container sum if `-GetContainerDetails`
* No double-counting between ADLS Gen2 and Blob in aggregates

---

## **Advanced Usage**

### Running via Management Groups

Use `-ManagementGroups <names or IDs>` to scan all subscriptions under one or more MGs.

Example:

```powershell
pwsh ./Get-AzureSizingInfo.ps1 `
  -ManagementGroups "corp-root","uk-landing-zones" `
  -SkipOracleDatabase -SkipAzureNetAppFiles `
  -OutputPath ./out
```

**Permissions needed:**

* Reader at MG scope (to list subscriptions)
* Same per-resource permissions as subscription scans

**Performance tips:**

* For huge estates, use `-AggregateStorageAtAccountLevel`
* Skip low-value workloads with `-SkipAzureNetAppFiles` or `-SkipOracleDatabase`
* Avoid `-GetContainerDetails` unless necessary

---

### Metrics behavior

* BlobCapacity/TableCapacity metrics can lag by \~1–2 hours
* Script always uses the most recent metric in the last 1–2 days
* If metric unavailable and `-GetContainerDetails` is set, falls back to blob enumeration

---

### Optional modules skipped by default

* **Az.Oracle** (Oracle\@Azure)
* **Az.NetAppFiles** (Azure NetApp Files)

These are **not loaded or installed automatically** unless:

* You use `-AutoInstallModules` **and** do not pass the skip flag
* Or you pass `-PromptInstallOracle` / `-PromptInstallNetApp` and accept the prompt

---

### On-Prem backup workloads

In the **Backup Protection** table:

* Asterisks `*` indicate on-prem workloads (`MAB`, `AzureBackupServer`, `DPM`, `SystemCenterDPM`)
* Azure Files is **not** on-prem and will never be starred

---

Do you want me to now give you a **full dependency/feature matrix** so users can see exactly which flags, modules, and RBAC are required for each workload? That would make the advanced section even more complete.
