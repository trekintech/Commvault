# Azure Sizing Information Script (Commvault Edition)

## Overview
This PowerShell script collects **resource sizing information** across one or more Azure subscriptions.  
It’s designed for **backup sizing, capacity planning, and workload inventory**.  
Supports key Azure workloads such as VMs, Disks, SQL DBs, Storage Accounts, and more.

It **does not** show what is actually backed up — it shows what exists so you can size for protection.

---

## Prerequisites

### PowerShell
- **PowerShell 7.0+** (recommended)

### Azure PowerShell Modules
The following Az modules must be installed:
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
- *(Optional)* `Az.Oracle` for Oracle@Azure discovery

You can install missing modules with:
```powershell
Install-Module -Name Az.Accounts,Az.Compute,Az.Storage,Az.Sql,Az.SqlVirtualMachine,Az.ResourceGraph,Az.Monitor,Az.Resources,Az.RecoveryServices,Az.CostManagement,Az.CosmosDB,Az.MySql,Az.MariaDb,Az.PostgreSql,Az.Table -Force
````

---

## Optional Parameters

* **`-PromptInstallOracle`** – If `Az.Oracle` is missing, prompt to install before continuing.
* **`-AutoInstallModules`** – Automatically install missing required modules without prompting.

---

## Usage Examples

### 1. Scan current subscription

```powershell
.\Get-AzureSizingInfo.ps1
```

### 2. Scan multiple subscriptions

```powershell
.\Get-AzureSizingInfo.ps1 -SubscriptionIds @("sub-id-1","sub-id-2")
```

### 3. Include Oracle\@Azure discovery

```powershell
.\Get-AzureSizingInfo.ps1 -PromptInstallOracle
```

---

## What It Collects

The script collects high-level counts and sizes (GiB/TiB) for:

* Azure VMs (with or without SQL)
* Managed Disks
* Azure SQL DBs
* Azure Managed Instances
* Storage Accounts (total size — includes Blob, File, Table, ADLS Gen2)
* Azure Files (only if available via metrics)
* Azure Data Lake Storage Gen2 *(counted within Storage Account total, no separate line)*
* Cosmos DB
* Azure Database for MySQL/MariaDB/PostgreSQL
* Azure Table Storage
* Azure Backup-protected items

---

## How Capacity is Counted

### Storage Accounts, Blob, Files, Tables, ADLS Gen2

* The **Storage Account** total is the **sum of all contained services**.
* **Blob**, **File Shares**, **Table Storage**, and **ADLS Gen2** are *rolled up into the Storage Account size*.
* The script **does not split out** the capacity per service by default.
* This means **File Share size** will be part of the Storage Account’s reported TiB value.
* **ADLS Gen2** (which runs on top of Blob) is also part of the Storage Account total — the script cannot detect if it’s being used without additional API calls.

---

## Visual: Capacity Relationship

```text
Storage Account Total Size
┌─────────────────────────┐
│  Storage Account (TiB)  │  <─ Reported by script
└───────────┬─────────────┘
            │
   ┌────────┼─────────┬────────┐
   │        │         │        │
  Blob   File Share  Table   ADLS Gen2
 (GB)     (GB)      (GB)     (GB)
```

*In the script output, these individual service sizes are not broken out; they are rolled into the Storage Account total.*

---

## Example: Mixed-Use Storage Account

Below is an example where **one Storage Account** contains multiple service types.

```text
Storage Account: SA-WestEurope
Reported total: 12 TiB
┌─────────────────────────────┐
│ Storage Account Total: 12TiB│  <─ Reported by script
└───────────┬─────────────────┘
            │
   ┌────────┼────────┐────────┐
   │        │        │        │
  Blob   File Share Table   ADLS Gen2
  8 TiB   3 TiB     0.5 TiB  0.5 TiB
```

### How the script reports:

* **Storage Account Total** = 12 TiB *(sum of all services in that account)*
* No per-service breakdown — Blob, File, Table, and ADLS Gen2 are all **rolled up into the Storage Account line**
* To separate these numbers, you would need **data plane API calls** for each service

---

## Regions in the Output

* Each resource is tied to its **Azure region**.
* The script will summarise:

  * **Count per region**
  * **Capacity (TiB) per region**
* Storage Account totals are attributed to the region where the account is hosted.

---

## Limitations

* Azure Files usage metrics are **not always available** — depends on region, SKU, and metric configuration.
* No separation of Blob vs File vs ADLS Gen2 capacity without extra queries.
* ADLS Gen2 usage is **counted within the Storage Account total**, but **cannot be flagged as “ADLS in use”** by this script alone.
* Some services may have 0 capacity if they exist but have no provisioned/used storage.

---

## Example Output

### Workload Totals

```text
App             Count  Size_GiB  Size_TiB
---             -----  --------  --------
Azure VM           28         0     0
Managed Disk       48      3850  3.76
Azure SQL DB        5       288  0.281
Storage Account    26     427.5  0.418
Cosmos DB           2         0     0
...
```

### Regions by TiB

```text
Region        Resources   TiB
------        ---------   ---
westeurope           61 2.319
eastus2              29 1.276
uksouth               2 0.124
...
```

```

---

