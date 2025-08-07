# Azure Size Collector

**Azure Size Collector** is a PowerShell script that inventories:

* **Azure SQL Databases** (counts and total size)
* **Azure Virtual Machines** (counts and total OS + data disk sizes)

across **all** subscriptions accessible by your account, and exports:

* **Summary CSV**: one row per subscription with aggregate metrics (GiB & TiB)
* **Details CSV**: one row per resource (SQL DB or VM) with individual sizes (GiB & TiB)

---

## 📦 Prerequisites

1. **PowerShell** (Core 7+ or Windows PowerShell 5.1)
2. **Internet access** to install modules and authenticate

### Required PowerShell Modules

The script will auto-install these if missing:

* `Az.Accounts`
* `Az.Sql`
* `Az.Compute`
* `Az.Resources`
* `Az.Storage`

You can pre-install the full Az bundle with:

```powershell
Install-Module -Name Az -AllowClobber -Scope CurrentUser
```

### Azure RBAC Permissions

On each subscription you scan, your identity needs at least **Reader** role (or equivalent) for these actions:

* **Resources**

  * `Microsoft.Resources/subscriptions/read`
* **SQL**

  * `Microsoft.Sql/servers/read`
  * `Microsoft.Sql/servers/databases/read`
* **Compute & Disks**

  * `Microsoft.Compute/virtualMachines/read`
  * `Microsoft.Compute/disks/read`
* **Storage** (for unmanaged VHDs)

  * `Microsoft.Storage/storageAccounts/listKeys/read`
* **Authorization** (permission checks)

  * `Microsoft.Authorization/permissions/read`

> Reader role on the subscription covers most; storage-account access is only needed if you have unmanaged VHDs.

---

## ⚙️ Installation

1. Clone or download this repository.
2. Ensure `Collect-AzureSizes.ps1` and this `README.md` are in the same folder.
3. Open PowerShell (no elevation required).

---

## 🚀 Usage

1. Change into the project directory:

   ```powershell
   cd C:\path\to\AzureSizeCollector
   ```
2. Run the script:

   ```powershell
   .\Collect-AzureSizes.ps1
   ```
3. Authenticate via device code when prompted.
4. Watch progress logs for each subscription, SQL database, and VM.

When complete, look for:

* **`Azure_SQL_VM_Summary.csv`**
* **`Azure_SQL_VM_Details.csv`**

in the same folder.

---

## 📊 Output

### Summary CSV (`Azure_SQL_VM_Summary.csv`)

| SubscriptionName | SubscriptionId | SQLInstanceCount | TotalSQLSizeGiB | TotalSQLSizeTiB | VMCount | TotalDiskSizeGiB | TotalDiskSizeTiB |
| ---------------- | -------------- | ---------------- | --------------- | --------------- | ------- | ---------------- | ---------------- |
| ExampleSub       | xxxxxxxx-xxxx  | 10               | 512.00          | 0.50            | 5       | 1024.00          | 1.00             |

### Details CSV (`Azure_SQL_VM_Details.csv`)

| SubscriptionName | ResourceGroupName | ResourceType   | ResourceName | SizeGiB | SizeTiB |
| ---------------- | ----------------- | -------------- | ------------ | ------- | ------- |
| ExampleSub       | RG-SQL            | SQLDatabase    | MyDatabase   | 256.00  | 0.25    |
| ExampleSub       | RG-VM             | VirtualMachine | WebServer01  | 128.00  | 0.125   |

---

## 🔧 Customization

* **Filter subscriptions**: add `| Where-Object { … }` after `Get-AzSubscription`.
* **Output paths**: edit the `Export-Csv` filenames at the bottom of the script.
* **Unit adjustments**: modify `$oneTiBBytes` / `$oneGiBBytes` constants.

---
