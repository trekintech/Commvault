# Azure Resource Sizer Script - README

## Overview

The Azure Resource Sizer script is a PowerShell utility designed to collate resource usage information across multiple Azure subscriptions. It gathers data for two primary resource types:

- **Azure SQL Databases:**  
  - Enumerates all SQL Servers and their databases in each subscription.
  - Totals the maximum allocated size (using the `MaxSizeBytes` property) for all databases.
  - Counts the number of SQL database instances.

- **Azure Virtual Machines and Attached Disks:**  
  - Enumerates all Virtual Machines in each subscription.
  - Retrieves and sums the sizes of the OS disk and any attached data disks.
  - Counts the number of VMs processed.

Both sizes are converted to terabytes (TB) with two decimal precision. The script displays the results on-screen and writes them to a CSV file named `AzureResourceSizes.csv`.

## Prerequisites

### PowerShell Version

Ensure you are running an up-to-date version of PowerShell.

### Required Modules

The script uses the following Azure PowerShell modules:
- **Az.Accounts** (for connecting to Azure, managing contexts, and subscriptions)
- **Az.Sql** (for retrieving SQL Server and SQL Database information)
- **Az.Compute** (for retrieving Virtual Machine and disk information)
- **Az.Resources** (for invoking REST methods and managing subscriptions)

The script includes module checks and will automatically install any missing modules in the current user scope.

## Required Azure Permissions

The script requires the following read-only permissions in order to successfully retrieve resource details:

- **Microsoft.Sql/servers/read**  
  Required to list SQL Servers.
  
- **Microsoft.Sql/servers/databases/read**  
  Required to list SQL Databases within each server.

- **Microsoft.Compute/virtualMachines/read**  
  Required to enumerate Virtual Machines.

- **Microsoft.Compute/disks/read**  
  Required to retrieve information about attached disks.

- **Microsoft.Resources/subscriptions/read**  
  Required to list and access subscription details.

These permissions ensure that the script can access the necessary resource information without making any changes to your Azure environment.

## How to Run the Script

1. **Download/Copy the Script:**  
   Save the provided PowerShell script as `AzureResourceSizer.ps1` or a similar filename.

2. **Open PowerShell:**  
   Open a PowerShell window with appropriate privileges.

3. **Navigate to the Script Location:**  
   Change directory to where the script is saved.

4. **Execute the Script:**  
   Run the script by typing:
   ```
   .\AzureResourceSizer.ps1
   ```
   The script will:
   - Check for and install any missing Azure modules.
   - Connect to your Azure account (you will be prompted to sign in if not already connected).
   - Process all accessible subscriptions, verifying required permissions before gathering resource details.
   - Display the results in a formatted table on-screen.
   - Write the results to a CSV file named `AzureResourceSizes.csv` in the current directory.

## Inputs and Configuration

- **User Inputs:**  
  No manual inputs are required at runtime. The script is self-contained and automatically handles:
  - Module installation
  - Azure authentication
  - Subscription processing and permission verification

- **Configuration:**  
  All configuration is handled within the script. If you need to modify any thresholds or conversion factors, you can adjust the constants at the beginning of the script.

## Output

- **On-Screen Display:**  
  A formatted table is printed to the console showing:
  - Subscription Name
  - Subscription ID
  - Number of SQL Database instances
  - Total SQL Database size in TB
  - Number of Virtual Machines
  - Total disk size (OS + Data Disks) in TB

- **CSV File:**  
  A CSV file named `AzureResourceSizes.csv` is generated in the current working directory containing the same information.

## Notes

- **Permissions:**  
  Ensure that your Azure account has the required permissions for the subscriptions you wish to analyze. If any subscription is missing the necessary permissions, the script will skip that subscription and notify you.

- **Module Installation:**  
  The script automatically installs any missing required modules in the current user scope, so an internet connection is needed for the initial run if modules are missing.

This README provides a complete overview of the script's functionality, prerequisites, permissions required, and instructions for running the tool. Enjoy using the Azure Resource Sizer!
