# Commvault Azure Sizing Information Collection Script

## Overview

This PowerShell script collects metadata and sizing information for supported Azure workloads to help with backup sizing and planning.  
It works across **all Azure subscriptions** you have **Reader** access to by default, or can be restricted to specific subscriptions with the `-SubscriptionIds` parameter.

It collects and aggregates information for:

- Azure Virtual Machines and Managed Disks
- Azure SQL Databases and Managed Instances
- Azure Storage Accounts (Blob, Files, Table)
- Azure Data Lake Storage Gen2 (if present in the account — see note below)
- Azure Cosmos DB
- Azure Databases for MySQL, MariaDB, and PostgreSQL
- Azure Table Storage
- Azure Backup–protected items

> **Note on ADLS Gen2**  
> ADLS Gen2 capacity is included in **Storage Account** totals if it exists, but the script does not explicitly label ADLS Gen2 usage separately.  
> To confirm ADLS Gen2 use, you will need to check the storage account configuration directly.

---

## Prerequisites

- **PowerShell 7.0+**
- Az PowerShell modules:
  - `Az.Accounts`
  - `Az.Compute`
  - `Az.Storage`
  - `Az.Sql`
  - `Az.SqlVirtualMachine`
  - `Az.ResourceGraph`
  - `Az.Monitor`
  - `Az.Resources`
  - `Az.RecoveryServices`
  - `Az.CostManagement`
  - `Az.CosmosDB`
  - `Az.MySql`
  - `Az.MariaDb`
  - `Az.PostgreSql`
  - `Az.Table`

Install missing modules (example):
```powershell
Install-Module Az.Accounts,Az.Compute,Az.Storage,Az.Sql,Az.SqlVirtualMachine,Az.ResourceGraph,Az.Monitor,Az.Resources,Az.RecoveryServices,Az.CostManagement,Az.CosmosDB,Az.MySql,Az.MariaDb,Az.PostgreSql,Az.Table -Scope CurrentUser
````

---

## Permissions Required

* **Minimum**: Built-in `Reader` role at the **subscription scope** (sufficient for all default collection paths used by the script)
* **Optional**: For the Azure Files **data-plane fallback** (used if metrics are unavailable), you will also need either:

  * The **Storage Blob Data Reader** role on the storage account, or
  * Access via an account key or SAS token

---

## How Subscriptions Are Handled

By default, the script queries **all subscriptions** you have `Reader` access to.

To restrict to specific subscriptions:

```powershell
.\Get-AzureSizingInfo.ps1 -SubscriptionIds "sub1","sub2"
```

Where `sub1` and `sub2` are Azure subscription GUIDs.

---

## Optional Parameters and Workflows

### 1. Restrict to Specific Subscriptions

```powershell
.\Get-AzureSizingInfo.ps1 -SubscriptionIds "11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"
```

### 2. Anonymise Resource Group and Object Names

```powershell
.\Get-AzureSizingInfo.ps1 -AnonymiseNames
```

Replaces resource group and object names with anonymised labels in the output.

### 3. Output Formats

By default, the script outputs tables in the console and saves CSV/HTML summaries.

```powershell
.\Get-AzureSizingInfo.ps1 -OutputPath "C:\Reports"
```

---

## How Capacity Is Counted

The script reports **Storage Account** capacity as an aggregate across services:

```
 ┌───────────────────────────┐
 │   Storage Account Total   │
 └──────────────┬────────────┘
                │
     ┌──────────┼──────────┬──────────┐
     │          │          │          │
   Blob       Files      Tables    (ADLS Gen2 if present)
```

* **Blob**: All blob container capacity in the account
* **Files**: All SMB file shares in the account
  (counted inside Storage Account total, not broken out separately in capacity totals unless the optional data-plane path is used)
* **Tables**: Azure Table Storage capacity
* **ADLS Gen2**: Counted inside the storage account total if enabled; not labelled separately in the output

> This means that the **Storage Account total already includes** capacity from Files, Blob, Table, and any ADLS Gen2 usage.
> Individual workload tables (e.g. “Azure Files”) list object counts but will not show separate capacity unless the metrics API returns it for that service.

---

## Example Output Sections

### Workload Totals

```
App             Count Size_GiB Size_TiB
---             ----- -------- --------
ADLS Gen2           1        0        0
Azure Files         6        0        0
Azure SQL DB        5      288    0.281
Azure VM           28        0        0
Cosmos DB           2        0        0
Managed Disk       48     3850     3.76
Storage Account    26   427.54    0.418
Table Storage      26        0        0
```

### Top Regions (by TiB)

```
Region        Resources   TiB
------        ---------   ---
westeurope           61 2.319
eastus2              29 1.276
eastus               26 0.571
australiaeast        12 0.154
uksouth               2 0.124
```

---

## Example Full Run

```powershell
# Default run against all subscriptions
.\Get-AzureSizingInfo.ps1

# Against specific subscriptions with anonymised names
.\Get-AzureSizingInfo.ps1 -SubscriptionIds "sub1","sub2" -AnonymiseNames -OutputPath "C:\Reports"
```

---

## Notes

* Some storage service capacities (Azure Files, Table, ADLS Gen2) may return `0` if metrics are not enabled or supported in that region/SKU.
* If Azure Files capacity is critical for your sizing, ensure **Storage metrics** are enabled, or grant **Storage Blob Data Reader** permissions for the optional data-plane query.
