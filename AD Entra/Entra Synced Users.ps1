<# 
Validate Entra objects synced from on-prem AD
- Requires Microsoft.Graph PowerShell SDK
- Outputs: CSVs + Summary.txt in a timestamped folder
#>

#---------------------------#
# 0) Setup / prerequisites  #
#---------------------------#

$ErrorActionPreference = 'Stop'

Function Ensure-GraphModule {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
        Write-Host "Microsoft.Graph module not found. Installing for CurrentUser..." -ForegroundColor Yellow
        Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.Graph -ErrorAction Stop
}

Ensure-GraphModule

#---------------------------------#
# 1) Connect to Microsoft Graph   #
#---------------------------------#

# Required scopes for read/reporting
$scopes = @(
    'User.Read.All',
    'Group.Read.All',
    'Device.Read.All',
    'Directory.Read.All',
    'Organization.Read.All'
)

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes $scopes
$ctx = Get-MgContext
Write-Host ("Connected as: {0} | Tenant: {1}" -f $ctx.Account, $ctx.TenantId) -ForegroundColor Green

#---------------------------------------------#
# 2) Output paths (timestamped report folder) #
#---------------------------------------------#

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$OutDir = Join-Path -Path (Resolve-Path .) -ChildPath ("EntraSyncReport-" + $stamp)
New-Item -ItemType Directory -Path $OutDir | Out-Null

$UsersCsv   = Join-Path $OutDir 'SyncedUsers.csv'
$GroupsCsv  = Join-Path $OutDir 'SyncedGroups.csv'
$DevicesCsv = Join-Path $OutDir 'SyncedDevices.csv'
$SummaryTxt = Join-Path $OutDir 'Summary.txt'

#-----------------------------------------------------------#
# 3) Tenant-level directory sync status (if property exists)#
#-----------------------------------------------------------#

$tenantSyncStatus = $null
$org = Get-MgOrganization -ErrorAction SilentlyContinue

# Not all tenants expose the same properties; handle gracefully
$tenantName = $org.DisplayName
$tenantId   = $ctx.TenantId

# Attempt to read on-prem sync flags if available on Organization
$onPremSyncEnabled        = $null
$onPremLastSyncDateTime   = $null

try {
    # Many tenants surface these on the Organization resource in Graph
    $onPremSyncEnabled      = $org.AdditionalProperties['onPremisesSyncEnabled']
    $onPremLastSyncDateTime = $org.AdditionalProperties['onPremisesLastSyncDateTime']
} catch {
    # Safe to ignore; we’ll just note “unknown”
}

#---------------------------------------------#
# 4) Pull Users / Groups / Devices from Graph #
#---------------------------------------------#

Write-Host "Fetching Users..." -ForegroundColor Cyan
$users = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,OnPremisesSyncEnabled,OnPremisesSecurityIdentifier,OnPremisesDomainName,OnPremisesImmutableId,CreationType

Write-Host "Fetching Groups..." -ForegroundColor Cyan
$groups = Get-MgGroup -All -Property Id,DisplayName,Mail,MailNickname,SecurityEnabled,GroupTypes,OnPremisesSyncEnabled,OnPremisesSecurityIdentifier,OnPremisesDomainName,OnPremisesNetBiosName

Write-Host "Fetching Devices..." -ForegroundColor Cyan
$devices = Get-MgDevice -All -Property Id,DisplayName,DeviceId,OnPremisesSyncEnabled,DeviceTrustType,OperatingSystem,AccountEnabled,ApproximateLastSignInDateTime

#----------------------------------------------#
# 5) Determine “synced from AD” vs cloud-only  #
#    (use OnPremisesSyncEnabled OR presence    #
#     of OnPremisesSecurityIdentifier)         #
#----------------------------------------------#

# Helper predicate
Function Is-Synced {
    param($obj)
    return (($obj.OnPremisesSyncEnabled -eq $true) -or ([string]::IsNullOrEmpty($obj.OnPremisesSecurityIdentifier) -eq $false))
}

$userSynced   = $users  | Where-Object { Is-Synced $_ }
$userCloud    = $users  | Where-Object { -not (Is-Synced $_) }

$groupSynced  = $groups | Where-Object { Is-Synced $_ }
$groupCloud   = $groups | Where-Object { -not (Is-Synced $_) }

$deviceSynced = $devices| Where-Object { Is-Synced $_ }
$deviceCloud  = $devices| Where-Object { -not (Is-Synced $_) }

#--------------------------------------------------------#
# 6) Export neat CSVs of synced objects (authoritative)  #
#--------------------------------------------------------#

$userSynced | Select-Object `
    DisplayName,
    UserPrincipalName,
    OnPremisesSyncEnabled,
    OnPremisesSecurityIdentifier,
    OnPremisesDomainName,
    OnPremisesImmutableId,
    CreationType,
    Id |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $UsersCsv

$groupSynced | Select-Object `
    DisplayName,
    Mail,
    MailNickname,
    SecurityEnabled,
    @{n='Type';e={ if ($_.GroupTypes -contains 'Unified') {'Microsoft 365'} else {'Security'} }},
    OnPremisesSyncEnabled,
    OnPremisesSecurityIdentifier,
    OnPremisesDomainName,
    OnPremisesNetBiosName,
    Id |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $GroupsCsv

$deviceSynced | Select-Object `
    DisplayName,
    DeviceId,
    OnPremisesSyncEnabled,
    DeviceTrustType,
    OperatingSystem,
    AccountEnabled,
    ApproximateLastSignInDateTime,
    Id |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $DevicesCsv

#---------------------------------------------#
# 7) Build a concise, handover-friendly       #
#    Summary.txt with counts and status       #
#---------------------------------------------#

$lines = @()
$lines += "Entra Sync Proof Report"
$lines += "Generated: $(Get-Date -Format u)"
$lines += "Tenant:    $tenantName ($tenantId)"
$lines += ""

$syncFlagText = if ($onPremSyncEnabled -eq $true) { "Enabled" } elseif ($onPremSyncEnabled -eq $false) { "Disabled" } else { "Unknown" }
$lastSyncText = if ($onPremLastSyncDateTime) { [datetime]$onPremLastSyncDateTime } else { "Unknown" }

$lines += "Tenant Directory Sync Enabled: $syncFlagText"
$lines += "Tenant Last Sync (if available): $lastSyncText"
$lines += ""

$lines += "Users   - Total: {0} | Synced: {1} | Cloud-only: {2}" -f $users.Count, $userSynced.Count, $userCloud.Count
$lines += "Groups  - Total: {0} | Synced: {1} | Cloud-only: {2}" -f $groups.Count, $groupSynced.Count, $groupCloud.Count
$lines += "Devices - Total: {0} | Synced: {1} | Cloud-only: {2}" -f $devices.Count, $deviceSynced.Count, $deviceCloud.Count
$lines += ""
$lines += "Definition of 'Synced from AD':"
$lines += " - OnPremisesSyncEnabled = True OR OnPremisesSecurityIdentifier is populated"
$lines += ""
$lines += "CSV Outputs:"
$lines += " - SyncedUsers.csv"
$lines += " - SyncedGroups.csv"
$lines += " - SyncedDevices.csv"

$lines | Set-Content -Path $SummaryTxt -Encoding UTF8

#---------------------------------------------#
# 8) Console summary                          #
#---------------------------------------------#

Write-Host ""
Write-Host "== Report Complete ==" -ForegroundColor Green
Write-Host ("Output folder: {0}" -f $OutDir) -ForegroundColor Green
Write-Host ("Users   -> Synced: {0} | Cloud-only: {1}" -f $userSynced.Count, $userCloud.Count)
Write-Host ("Groups  -> Synced: {0} | Cloud-only: {1}" -f $groupSynced.Count, $groupCloud.Count)
Write-Host ("Devices -> Synced: {0} | Cloud-only: {1}" -f $deviceSynced.Count, $deviceCloud.Count)
Write-Host ""
Write-Host "CSV files and Summary.txt are ready for handover." -ForegroundColor Cyan
