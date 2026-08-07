<#
.SYNOPSIS
    One-command ground-zero setup for the Public Port Guard lab (Windows).

.DESCRIPTION
    Creates the azd environment, generates a VM admin password, provisions the
    infrastructure, and configures the SRE Agent — end to end.

    Usage (from labs/public-port-guard):
      pwsh -File scripts/setup.ps1 -EnvName port-guard-demo -Location eastus2

.PARAMETER EnvName
    azd environment name (also drives the resource group name rg-<EnvName>).

.PARAMETER Location
    Azure region. Default eastus2.

.PARAMETER Subscription
    Optional subscription id to target.
#>
[CmdletBinding()]
param(
    [string]$EnvName = 'port-guard-demo',
    [string]$Location = 'eastus2',
    [string]$Subscription
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

Write-Host "== Public Port Guard — ground-zero setup ==" -ForegroundColor Cyan

if ($Subscription) { az account set --subscription $Subscription }
$oid = az ad signed-in-user show --query id -o tsv

# 1. Environment
azd env new $EnvName 2>$null | Out-Null
azd env select $EnvName 2>$null | Out-Null
azd env set AZURE_LOCATION $Location | Out-Null
azd env set AZURE_PRINCIPAL_ID $oid | Out-Null
azd env set VM_ADMIN_USERNAME 'azureuser' | Out-Null
if ($Subscription) { azd env set AZURE_SUBSCRIPTION_ID $Subscription | Out-Null }

# 2. Strong random VM password (never echoed). NOTE: `azd env set KEY VALUE`
#    takes two arguments — piping fails with "invalid key=value format".
$bytes = New-Object 'System.Byte[]' 18
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pw = 'Pg9' + [Convert]::ToBase64String($bytes).Replace('+','A').Replace('/','z').Replace('=','7') + '!'
azd env set VM_ADMIN_PASSWORD $pw | Out-Null
Write-Host "  [OK] azd environment '$EnvName' ready (region $Location)." -ForegroundColor Green

# 3. Provision infrastructure
Write-Host "  Provisioning infrastructure (azd provision)..." -ForegroundColor Yellow
azd provision --no-prompt

# 4. Configure the agent (data plane)
Write-Host "  Configuring the SRE Agent..." -ForegroundColor Yellow
pwsh -NoProfile -File (Join-Path $PSScriptRoot 'configure-agent.ps1')

Write-Host "`n== Setup complete. Trigger the demo: bash scripts/break-ports.sh all ==" -ForegroundColor Cyan
