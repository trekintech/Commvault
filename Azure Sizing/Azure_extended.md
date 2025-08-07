# Get-AzureSizingInfo.ps1 — Azure inventory & capacity for backup sizing

Collects Azure inventory and capacity to feed a backup sizing exercise (e.g., for Commvault). Generates clean CSVs and a simple HTML report with **counts** and **GiB/TiB** per app and **per region**. Vendor-neutral, fast by default, and optionally anonymises names.

---

## Table of Contents

* [What it does (default)](#what-it-does-default)
* [Requirements](#requirements)
* [Permissions](#permissions)
* [Installation](#installation)
* [Quick Start](#quick-start)
* [Optional Workflows](#optional-workflows)

  * [Targeting scope](#targeting-scope)
  * [Performance controls](#performance-controls)
  * [Anonymisation](#anonymisation)
  * [Azure Backup & Oracle@Azure](#azure-backup--oracleazure)
  * [Cloud Shell / headless](#cloud-shell--headless)
* [Sizing method (per workload)](#sizing-method-per-workload)
* [Outputs](#outputs)
* [Performance tips](#performance-tips)
* [Troubleshooting](#troubleshooting)
* [Assumptions & notes](#assumptions--notes)
* [Example: full, anonymised run](#example-full-anonymised-run)
* [License](#license)

---

## What it does (default)

Runs against the subscriptions you choose and produces **three primary outputs** plus **raw detail CSVs**:

1. `azure_sizing_by_app_<timestamp>.csv`
   *App, Count, Size\_GiB, Size\_TiB*

2. `azure_sizing_by_region_<timestamp>.csv`
   *Region, App, Count, Size\_GiB, Size\_TiB*

3. `azure_sizing_report_<timestamp>.html`
   Simple, styled summary you can share or paste into slides

4. Raw CSVs per workload for traceability (VMs, Disks, SQL, Storage, Files, Tables, ADLS Gen2, Cosmos, PaaS DBs, Backup, Oracle)

**Discovered / sized by default**

* **Azure VMs** (count) and **Managed Disks** (provisioned capacity)
* **Azure SQL DB** (`MaxSizeBytes`) and **SQL Managed Instance** (`StorageSizeInGB`)
* **Storage Accounts** (`UsedCapacity` metric), **Azure Files**, **Table Storage** (`TableCapacity` metric), **ADLS Gen2**
* **Cosmos DB** (`DataUsage + IndexUsage`)
* **Azure DB for MySQL/MariaDB/PostgreSQL** (allocated storage)
* **Azure Backup** (vaults/policies/items inventory)
* **Oracle Database\@Azure** (if `Az.Oracle` is present)

**Defaults**

* Uses **Resource Graph** and **Metrics** APIs (fast, low impact)
* **Does not** enumerate every blob (you can enable it)
* Reports sizes in **GiB/TiB (1024-based)**

---

## Requirements

* **PowerShell** 7.0+
* **Login:** `Connect-AzAccount`
* **Modules** (auto-install supported):

  * **Required:** `Az.Accounts, Az.Compute, Az.Storage, Az.Sql, Az.SqlVirtualMachine, Az.ResourceGraph, Az.Monitor, Az.Resources`
  * **Optional:** `Az.RecoveryServices, Az.CosmosDB, Az.MySql, Az.MariaDb, Az.PostgreSql, Az.Oracle`

---

## Permissions

Minimum recommended roles (assign at subscription or resource scope as appropriate):

| Feature                                     | Role(s)                                        |
| ------------------------------------------- | ---------------------------------------------- |
| Enumerate resources                         | **Reader**                                     |
| Read metrics (storage, cosmos, etc.)        | **Monitoring Reader**                          |
| Azure Files usage (data plane)              | **Storage File Data SMB Share Reader**         |
| Blob containers (if `-GetContainerDetails`) | **Storage Blob Data Reader**                   |
| Azure Backup inventory                      | **Backup Reader**                              |
| Oracle\@Azure (if used)                     | Reader + any `Az.Oracle`-specific requirements |

> With defaults (no blob-per-container), **Reader + Monitoring Reader** is typically sufficient.

---

## Installation

```powershell
# Optional helper: auto-install required Az.* modules when missing
Install-Module Az.Accounts,Az.Compute,Az.Storage,Az.Sql,Az.SqlVirtualMachine,Az.ResourceGraph,Az.Monitor,Az.Resources -Scope CurrentUser -Force
# Optional extras if you need those features:
Install-Module Az.RecoveryServices,Az.CosmosDB,Az.MySql,Az.MariaDb,Az.PostgreSql,Az.Oracle -Scope CurrentUser -Force
```

---

## Quick Start

```powershell
# Current subscription, outputs to .\out
.\Get-AzureSizingInfo.ps1 -CurrentSubscription -OutputPath .\out

# All subscriptions you can see
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -OutputPath .\out

# Auto-install required modules if missing
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -AutoInstallModules -OutputPath .\out
```

---

## Optional Workflows

### Targeting scope

```powershell
# Specific subscriptions (names or IDs)
.\Get-AzureSizingInfo.ps1 -Subscriptions "Prod-Sub","11111111-2222-3333-4444-555555555555" -OutputPath .\out

# Management groups (recurses to their subscriptions)
.\Get-AzureSizingInfo.ps1 -ManagementGroups "Corp","Sandbox" -OutputPath .\out
```

### Performance controls

```powershell
# Include per-container blob detail (can be slow/heavy)
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -GetContainerDetails -OutputPath .\out

# Skip collectors you don't need
.\Get-AzureSizingInfo.ps1 -AllSubscriptions `
  -SkipAzureBackup -SkipOracleDatabase -SkipAzureCosmosDB `
  -OutputPath .\out
```

### Anonymisation

Deterministic pseudonyms for **resource groups** and/or **object names** while keeping regions, counts, and sizes intact.

```powershell
# Anonymise both RGs and object names (stable with the provided salt)
.\Get-AzureSizingInfo.ps1 -AllSubscriptions `
  -AnonymizeScope All -AnonymizeSalt "tenant-or-project-secret" `
  -OutputPath .\out

# Only anonymise resource groups
.\Get-AzureSizingInfo.ps1 -CurrentSubscription `
  -AnonymizeScope ResourceGroups -AnonymizeSalt "my-salt" `
  -OutputPath .\out

# Only anonymise object names
.\Get-AzureSizingInfo.ps1 -Subscriptions "Prod-Sub" `
  -AnonymizeScope Objects -AnonymizeSalt "my-salt" `
  -OutputPath .\out
```

### Azure Backup & Oracle\@Azure

```powershell
# Include Azure Backup (needs Backup Reader on vaults)
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -OutputPath .\out

# Oracle@Azure is included if Az.Oracle is installed; otherwise it’s skipped
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -OutputPath .\out

# Explicitly skip either
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -SkipAzureBackup -SkipOracleDatabase -OutputPath .\out
```

### Cloud Shell / headless

```powershell
# Azure Cloud Shell (modules usually preloaded)
./Get-AzureSizingInfo.ps1 -CurrentSubscription -OutputPath $HOME/out
```

---

## Sizing method (per workload)

| Workload                 | Count |                Size basis | Notes                                            |
| ------------------------ | ----: | ------------------------: | ------------------------------------------------ |
| Azure VM                 |     ✓ |                       n/a | VM **count**; capacity comes from disks          |
| Managed Disk             |     ✓ |            Provisioned GB | Sum of OS + data disks (control plane)           |
| Azure SQL DB             |     ✓ |            `MaxSizeBytes` | Excludes `master`                                |
| SQL MI                   |     ✓ |         `StorageSizeInGB` | Converted to bytes for consistent math           |
| Storage Account          |     ✓ |     `UsedCapacity` metric | Includes all services; ADLS Gen2 via same metric |
| Blob Container           |   ✓\* |       Sum of blob lengths | **Only with** `-GetContainerDetails`             |
| Azure Files              |     ✓ | `Get-AzStorageShareStats` | Data-plane call; needs file data reader role     |
| Table Storage            |     ✓ |    `TableCapacity` metric | May be missing/disabled in some tenants          |
| Cosmos DB                |     ✓ |  `DataUsage + IndexUsage` | Account-level metrics                            |
| MySQL/MariaDB/PostgreSQL |     ✓ |         Allocated storage | From server StorageProfile                       |
| Azure Backup             |     ✓ |                       n/a | Inventory of vaults, policies, items             |
| Oracle\@Azure            |     ✓ |          Reported storage | Via `Az.Oracle` when available                   |

All sizes are normalised to **GiB/TiB** (1024-based).

---

## Outputs

Primary:

* `azure_sizing_by_app_<timestamp>.csv` — **App, Count, Size\_GiB, Size\_TiB**
* `azure_sizing_by_region_<timestamp>.csv` — **Region, App, Count, Size\_GiB, Size\_TiB**
* `azure_sizing_report_<timestamp>.html` — lightweight HTML summary

Raw details (for traceability):

* `azure_vms_*.csv`, `azure_managed_disks_*.csv`, `azure_sql_databases_*.csv`, `azure_sql_managed_instances_*.csv`
* `azure_storage_accounts_*.csv`, `azure_blob_containers_*.csv`, `azure_file_shares_*.csv`, `azure_table_storage_*.csv`, `azure_datalake_gen2_*.csv`
* `azure_cosmosdb_accounts_*.csv`, `azure_mariadb_servers_*.csv`, `azure_mysql_servers_*.csv`, `azure_postgresql_servers_*.csv`
* `azure_backup_vaults_*.csv`, `azure_backup_policies_*.csv`, `azure_backup_items_*.csv`
* `azure_oracle_databases_*.csv` (if applicable)

---

## Performance tips

* Prefer **default** mode (Resource Graph + metrics).
* Avoid `-GetContainerDetails` unless truly needed.
* Use management group targeting to split work by teams.
* Skip collectors you don’t need via `-Skip*` switches.

---

## Troubleshooting

* **Missing modules**
  Re-run with `-AutoInstallModules` or pre-install with `Install-Module Az.<name> -Scope CurrentUser`.

* **Metrics are zero/missing**
  Ensure **Monitoring Reader** at the right scope and that the resource emits the metric (some services/tenants differ).

* **Azure Files / Blob container access fails**
  Add data-plane roles: **Storage File Data SMB Share Reader** and/or **Storage Blob Data Reader**.

* **Azure Backup empty**
  Confirm **Backup Reader** on the Recovery Services vaults.

* **Throttling/timeouts**
  Reduce scope, avoid `-GetContainerDetails`, or skip optional collectors.

---

## Assumptions & notes

* **Metrics lag:** Azure metrics can be delayed by \~5–30 minutes. The script uses the latest non-null average in a recent window.
* **Provisioned vs. used:** Many services report **allocated** capacity (which is often what you need for protection sizing).
* **Regions:** Uses Azure’s canonical short names (e.g., `westeurope`).

---

## Example: full, anonymised run

```powershell
.\Get-AzureSizingInfo.ps1 -AllSubscriptions -AutoInstallModules `
  -AnonymizeScope All -AnonymizeSalt "project-salt" `
  -OutputPath .\out
```

---

## License

Vendor-neutral utility intended to support backup sizing workflows (including Commvault). Use at your own risk; validate outputs before committing capacity.
