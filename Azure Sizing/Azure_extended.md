# Azure Sizing & Inventory Script

## Overview
This PowerShell script collects detailed sizing and inventory information for a wide range of Azure workloads.  
It is intended to support backup sizing, cost estimation, and capacity planning by providing **counts, sizes, and regional breakdowns** of supported resources.

The script connects to your Azure tenant, enumerates resources across the specified subscription(s), and produces:
- A **count** of each application type
- The **total size** of those workloads in both **GiB** and **TiB**
- A **regional breakdown** of capacity usage

Optionally, it can:
- Anonymise **resource group** and/or **object names**
- Automatically install missing Az.* modules (including Az.Oracle)
- Include Azure NetApp Files in reporting
- Export results to CSV, JSON, and HTML reports

---

## Prerequisites

Before running the script, ensure the following:
1. **PowerShell 7.0 or later**
2. The following Az modules are installed and up-to-date:
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
   - `Az.NetAppFiles` *(only if collecting ANF data)*
   - `Az.Oracle` *(only if collecting Oracle@Azure data)*

   The script can install these for you if you use `-AutoInstallModules` or `-PromptInstallOracle`.

3. You must have:
   - **Reader** or equivalent rights on the subscriptions you wish to inventory
   - **Storage Account Data Reader** permissions for collecting capacity details from Azure Storage

---

## Usage

### Basic Run
Run the script without optional parameters to process all accessible subscriptions:

```powershell
.\Get-AzureSizingInfo.ps1
````

---

### Optional Parameters

#### `-Subscriptions`

Limit the run to specific subscription IDs or names.

```powershell
.\Get-AzureSizingInfo.ps1 -Subscriptions "My Production Subscription", "My DR Subscription"
```

#### `-AnonymiseResourceGroups`

Replace all **Resource Group** names in output with anonymised labels.

```powershell
.\Get-AzureSizingInfo.ps1 -AnonymiseResourceGroups
```

#### `-AnonymiseObjectNames`

Replace all resource names (VM names, DB names, storage account names, etc.) with anonymised labels.

```powershell
.\Get-AzureSizingInfo.ps1 -AnonymiseObjectNames
```

#### `-AutoInstallModules`

Automatically install any missing required Az modules, including `Az.Oracle` for Oracle\@Azure.

```powershell
.\Get-AzureSizingInfo.ps1 -AutoInstallModules
```

#### `-PromptInstallOracle`

If `Az.Oracle` is missing, prompt the user to install it so Oracle\@Azure data can be collected.

```powershell
.\Get-AzureSizingInfo.ps1 -PromptInstallOracle
```

#### `-IncludeNetAppFiles`

Collect data for Azure NetApp Files volumes and include in totals.

```powershell
.\Get-AzureSizingInfo.ps1 -IncludeNetAppFiles
```

#### `-ExportCsv "path"`

Export summary and regional data to CSV.

```powershell
.\Get-AzureSizingInfo.ps1 -ExportCsv "C:\Reports\AzureSizing.csv"
```

#### `-ExportHtml "path"`

Export a formatted HTML report.

```powershell
.\Get-AzureSizingInfo.ps1 -ExportHtml "C:\Reports\AzureSizing.html"
```

---

## How Capacity Is Accounted For

Azure Storage accounts can contain **multiple services**:

* **Blob Storage** (Block Blobs, Page Blobs, Append Blobs)
* **Azure Files** (SMB/NFS shares)
* **Table Storage**

The script **queries storage capacity at the account level**, so Blob, Files, and Table usage are **rolled up into the `Storage Account` total**.

---

### Capacity Roll-Up Diagram

```
   ┌──────────────────────────────┐
   │        Storage Account        │
   │   (reported total capacity)   │
   └──────────────┬────────────────┘
                  │
   ┌──────────────┼──────────────┐
   │              │              │
Blob Storage   Azure Files    Table Storage
 (all types)   (all shares)   (all tables)
   │              │              │
   ▼              ▼              ▼
Counted in    Counted in    Counted in
Storage       Storage       Storage
Account       Account       Account
total         total         total
```

**Important:**

* `Storage Account` capacity = Blob + Files + Table combined.
* The `Azure Files` and `Table Storage` rows in the report show **counts** only; their sizes are not *removed* from the Storage Account total, so adding them together will **double count**.
* This design ensures total capacity is accurate for sizing but means service-specific sizes are only available if we query them separately.

---

## Output Interpretation

The script generates two main summaries:

1. **Workload Totals**
   Shows the **count** of each application type, plus the **total capacity** in GiB and TiB.

   Example:

   ```
   App             Count Size_GiB Size_TiB
   ---             ----- -------- --------
   Azure VM           28        0        0
   Managed Disk       48     3850     3.76
   Storage Account    26   427.54    0.418
   Azure Files         6        0        0
   Table Storage      26        0        0
   ```

2. **Top Regions (by TiB)**
   Shows which Azure regions have the most capacity usage.

   Example:

   ```
   Region        Resources   TiB
   ------        ---------   ---
   westeurope           61 2.319
   eastus2              29 1.276
   uksouth               2 0.124
   ```

---

## Notes

* For **Azure Files**, the size value may appear as `0` if per-share metrics are unavailable in that region/SKU. The actual capacity is still counted in the `Storage Account` total.
* Capacity numbers for Blob, Files, and Table are **aggregated at the storage account level**. The service-specific rows (`Azure Files`, `Table Storage`) are primarily for inventory purposes.
* To get exact per-share or per-service capacity, a separate data-plane API query is required.

