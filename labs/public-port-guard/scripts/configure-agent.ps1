<#
.SYNOPSIS
    Configure the Public Port Guard SRE Agent (data plane) reliably on Windows.

.DESCRIPTION
    Run after `azd provision`. Does everything the agent needs, idempotently,
    using PowerShell (Invoke-RestMethod) instead of curl — Git Bash curl fails
    against the *.azuresre.ai endpoint on Windows (HTTP 000).

    Steps:
      1. Resolve resource group, agent, endpoint, and Log Analytics workspace.
      2. Grant the current user SRE Agent Administrator.
      3. Set Azure Monitor as the incident platform.
      4. Create Log Analytics + Azure Monitor connectors (query capability).
      5. Upload the public-port-guard knowledge file (indexed).
      6. Install the public-port-guard extended skill (tools + detail file).
      7. Create the Public Port Exposure response plan.
      8. Apply the port-remediation-approval hook.
      9. Create the public-port-scan scheduled task (every 30 min).
     10. Verify and print a summary.

.PARAMETER ResourceGroup
    Target resource group. Defaults to azd env RESOURCE_GROUP_NAME, else
    rg-<AZURE_ENV_NAME>.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
$labDir = Split-Path -Parent $PSScriptRoot
function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

function Get-Tok { az account get-access-token --resource 'https://azuresre.dev' --query accessToken -o tsv }
function Auth    { @{ Authorization = "Bearer $(Get-Tok)" } }
function AuthJson{ @{ Authorization = "Bearer $(Get-Tok)"; 'Content-Type' = 'application/json' } }

# ---- 1. Resolve resources ----
Info "`n[1/10] Resolving deployed resources..."
if (-not $ResourceGroup) {
    $ResourceGroup = (azd env get-value RESOURCE_GROUP_NAME 2>$null)
    if (-not $ResourceGroup -or $ResourceGroup -match 'ERROR|not found') {
        $envName = (azd env get-value AZURE_ENV_NAME 2>$null)
        if (-not $envName) { $envName = 'port-guard-demo' }
        $ResourceGroup = "rg-$envName"
    }
}
$sub       = az account show --query id -o tsv
$agentName = az resource list -g $ResourceGroup --resource-type 'Microsoft.App/agents' --query "[0].name" -o tsv
$agentId   = az resource list -g $ResourceGroup --resource-type 'Microsoft.App/agents' --query "[0].id" -o tsv
$ep        = az resource show -g $ResourceGroup --resource-type 'Microsoft.App/agents' --name $agentName --query "properties.agentEndpoint" -o tsv
$lawId     = az resource list -g $ResourceGroup --resource-type 'Microsoft.OperationalInsights/workspaces' --query "[0].id" -o tsv
$lawName   = az resource show --ids $lawId --query name -o tsv
if (-not $ep) { throw "Could not resolve SRE Agent endpoint in $ResourceGroup." }
Ok "RG: $ResourceGroup"
Ok "Agent: $agentName"
Ok "Endpoint: $ep"

# ---- 2. SRE Agent Administrator role ----
Info "`n[2/10] Ensuring SRE Agent Administrator role..."
$oid = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $oid --assignee-principal-type User `
    --role 'SRE Agent Administrator' --scope $agentId --output none 2>$null
Ok "Role ensured for current user."

# ---- 3. Azure Monitor incident platform ----
Info "`n[3/10] Setting Azure Monitor as incident platform..."
$armId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$agentName"
$patch = @{ properties = @{
    incidentManagementConfiguration = @{ type = 'AzMonitor'; connectionName = 'azmonitor' }
    experimentalSettings = @{ EnableWorkspaceTools = $true; EnableDevOpsTools = $true; EnablePythonTools = $true }
} } | ConvertTo-Json -Depth 6
$patchFile = New-TemporaryFile
$patch | Set-Content $patchFile -Encoding utf8
az rest --method patch --url "https://management.azure.com$armId`?api-version=2025-05-01-preview" --body "@$patchFile" --output none 2>$null
Remove-Item $patchFile -ErrorAction SilentlyContinue
Ok "Incident platform = AzMonitor."

# ---- 4. Connectors: Log Analytics + Azure Monitor ----
Info "`n[4/10] Creating Log Analytics + Azure Monitor connectors..."
$connBase = "https://management.azure.com$armId/connectors"
$laBody = @{ properties = @{ dataConnectorType='LogAnalytics'; dataSource=$lawId;
    extendedProperties=@{ armResourceId=$lawId; resource=@{ name=$lawName } }; identity='system' } } | ConvertTo-Json -Depth 6
$amBody = @{ properties = @{ dataConnectorType='MonitorClient'; dataSource='n/a'; identity='system' } } | ConvertTo-Json -Depth 6
foreach ($c in @(@{n='log-analytics';b=$laBody}, @{n='azure-monitor';b=$amBody})) {
    $f = New-TemporaryFile; $c.b | Set-Content $f -Encoding utf8
    az rest --method PUT --url "$connBase/$($c.n)?api-version=2025-05-01-preview" --body "@$f" --headers 'Content-Type=application/json' --output none 2>$null
    if ($LASTEXITCODE -eq 0) { Ok "connector: $($c.n)" } else { Warn "connector $($c.n) failed" }
    Remove-Item $f -ErrorAction SilentlyContinue
}

# ---- 5. Knowledge upload ----
Info "`n[5/10] Uploading knowledge (public-port-guard.md)..."
$know = Join-Path $labDir 'skills/public-port-guard.md'
try {
    Invoke-RestMethod -Uri "$ep/api/v1/AgentMemory/upload" -Headers (Auth) -Method Post `
        -Form @{ triggerIndexing = 'true'; files = Get-Item $know } | Out-Null
    Ok "knowledge uploaded + indexing triggered."
} catch { Warn "knowledge upload failed: $($_.ErrorDetails.Message)" }

# ---- 6. Extended skill install ----
Info "`n[6/10] Installing public-port-guard extended skill..."
$skillMd = Join-Path $labDir 'skills/public-port-guard/SKILL.md'
$skillBody = @{
    name='public-port-guard'; type='Skill'
    properties=@{
        description='Use when investigating VMs that expose sensitive ports (SSH, RDP, databases, Docker) to the public internet, when an NSG-change incident fires, when the public-port-scan task runs, or when asked to audit or block public network exposure on Virtual Machines.'
        tools=@('SearchMemory','RunAzCliReadCommands','RunAzCliWriteCommands','GetAzCliHelp','QueryLogAnalyticsByWorkspaceId')
        skillContent=(Get-Content -Raw $skillMd)
        additionalFiles=@(@{ filePath='public-port-guard-detail.md'; content=(Get-Content -Raw $know) })
    }
} | ConvertTo-Json -Depth 8
try {
    Invoke-RestMethod -Uri "$ep/api/v2/extendedAgent/skills/public-port-guard" -Headers (AuthJson) -Method Put -Body $skillBody | Out-Null
    Ok "skill installed."
} catch { Warn "skill install failed: $($_.ErrorDetails.Message)" }

# ---- 7. Response plan ----
Info "`n[7/10] Creating Public Port Exposure response plan..."
# NOTE: no maxAttempts — ConnectorsV2 agents reject unknown filter properties.
$plan = @{ id='public-port-exposure'; name='Public Port Exposure'
    priorities=@('Sev0','Sev1','Sev2','Sev3','Sev4'); titleContains=''; handlingAgent=''; agentMode='autonomous' } | ConvertTo-Json -Compress
$planned = $false
foreach ($i in 1..5) {
    try {
        Invoke-RestMethod -Uri "$ep/api/v1/incidentPlayground/filters/public-port-exposure" -Headers (AuthJson) -Method Put -Body $plan | Out-Null
        Ok "response plan: public-port-exposure [autonomous]"; $planned = $true; break
    } catch { Start-Sleep -Seconds 8 }
}
if (-not $planned) { Warn "response plan failed — create it in the portal." }
try { Invoke-RestMethod -Uri "$ep/api/v1/incidentPlayground/filters/quickstart_response_plan" -Headers (Auth) -Method Delete | Out-Null } catch {}

# ---- 8. Approval hook ----
Info "`n[8/10] Applying port-remediation-approval hook..."
$hookPrompt = @'
You are a safety reviewer for network security changes. Inspect the agent's proposed
response for any NSG rule create/update/delete or any change to a
Microsoft.Network/networkSecurityGroups resource or its securityRules.
If so: REJECT, name the NSG/rule/port/source affected, state the effect, and ask the
user to reply "yes" to approve or "no" to cancel. If the agent is only reading data or
generating a report without modifying an NSG, APPROVE.

$ARGUMENTS
'@
$hook = @{ name='port-remediation-approval'; type='GlobalHook'; properties=@{
    eventType='Stop'; activationMode='always'
    description='Requires user approval before any NSG rule create/update/delete.'
    hook=@{ type='prompt'; prompt=$hookPrompt; model='ReasoningFast'; timeout=30; failMode='Block'; maxRejections=3 }
} } | ConvertTo-Json -Depth 6
try { Invoke-RestMethod -Uri "$ep/api/v2/extendedAgent/hooks/port-remediation-approval" -Headers (AuthJson) -Method Put -Body $hook | Out-Null; Ok "hook applied." }
catch { Warn "hook failed: $($_.ErrorDetails.Message)" }

# ---- 9. Scheduled scan task ----
Info "`n[9/10] Creating public-port-scan scheduled task (every 30 min)..."
$scanPrompt = "Use the public-port-guard skill to scan every VM in resource group $ResourceGroup for sensitive ports exposed to the public internet. Read live NSG rules directly from ARM (az network nsg rule list), NOT Azure Resource Graph. Flag inbound Allow rules whose source is Internet/*/0.0.0.0/0 and whose destination is a sensitive port (22,3389,3306,5432,1433,6379,27017,9200,5601,5984,2375,2376,11211) or wildcard/range; confirm the VM has a public IP and is running; attribute the change via the Activity Log. Produce a findings table ranked Critical/High/Medium/Informational. Do NOT remediate automatically. Public 80/443 on a web-frontend VM is Informational. If nothing is exposed, say so."
$task = @{ name='public-port-scan'; description='Scan VMs for sensitive ports exposed to the public internet every 30 minutes'; cronExpression='*/30 * * * *'; agentPrompt=$scanPrompt } | ConvertTo-Json -Depth 4
try {
    $existing = Invoke-RestMethod -Uri "$ep/api/v1/scheduledtasks" -Headers (Auth) -Method Get
    foreach ($t in @($existing)) { if ($t.name -eq 'public-port-scan' -and $t.id) { Invoke-RestMethod -Uri "$ep/api/v1/scheduledtasks/$($t.id)" -Headers (Auth) -Method Delete | Out-Null } }
} catch {}
try { Invoke-RestMethod -Uri "$ep/api/v1/scheduledtasks" -Headers (AuthJson) -Method Post -Body $task | Out-Null; Ok "scheduled task created." }
catch { Warn "scheduled task failed: $($_.ErrorDetails.Message)" }

# ---- 10. Verify ----
Info "`n[10/10] Verification"
$h = Auth
try { $kb = Invoke-RestMethod -Uri "$ep/api/v1/AgentMemory/files" -Headers $h; Ok ("Knowledge: " + (($kb.files | ForEach-Object { $_.name }) -join ', ')) } catch {}
try { $sk = Invoke-RestMethod -Uri "$ep/api/v2/extendedAgent/skills" -Headers $h; Ok ("Skills: " + ((@($sk.value) | ForEach-Object { $_.name }) -join ', ')) } catch {}
try { $cn = az rest --method GET --url "$connBase`?api-version=2025-05-01-preview" --query "value[].name" -o tsv 2>$null; Ok ("Connectors: " + (($cn -join ', '))) } catch {}
try { $fl = Invoke-RestMethod -Uri "$ep/api/v1/incidentPlayground/filters" -Headers $h; Ok ("Response plans: " + ((@($fl) | ForEach-Object { $_.name }) -join ', ')) } catch {}
try { $tk = Invoke-RestMethod -Uri "$ep/api/v1/scheduledtasks" -Headers $h; Ok ("Scheduled tasks: " + ((@($tk) | ForEach-Object { $_.name }) -join ', ')) } catch {}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  Public Port Guard configured. Portal: https://sre.azure.com" -ForegroundColor Green
Write-Host "  Trigger:  bash scripts/break-ports.sh all" -ForegroundColor Green
Write-Host "  Reset:    bash scripts/break-ports.sh reset" -ForegroundColor Green
Write-Host "============================================================`n" -ForegroundColor Cyan
