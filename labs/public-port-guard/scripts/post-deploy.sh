#!/bin/bash
# ============================================================
# Post-deployment setup for the Public Port Guard lab (macOS / Linux).
#
# >>> ON WINDOWS, USE scripts/configure-agent.ps1 INSTEAD. <<<
# Git Bash curl cannot reach the *.azuresre.ai data-plane endpoint on Windows
# (returns HTTP 000). The PowerShell configurator is the reliable, complete path
# and ALSO installs the extended skill, the Log Analytics + Azure Monitor
# connectors, the approval hook, and the scheduled task.
#
# This bash script configures — via the SRE Agent DATA-PLANE API (not ARM child
# resources, which are restricted to internal tenants) — the following:
#   1. SRE Agent Administrator role for the current user
#   2. Activity Log diagnostic settings → Log Analytics (best effort)
#   3. Azure Monitor as the incident platform
#   4. public-port-guard knowledge file (indexed)
#   5. Azure Monitor response plan (routes NSG-change incidents to the agent)
#   6. Verification readout
#
# For the FULL configuration on any OS (connectors, extended skill, hook, task),
# prefer:  pwsh -File scripts/configure-agent.ps1
# The port-remediation-approval hook and public-port-scan scheduled task YAML
# under hooks/ and scheduled-tasks/ can also be applied with srectl.
# ============================================================

set -uo pipefail

if command -v python3 &>/dev/null; then PYTHON=python3
elif command -v python &>/dev/null; then PYTHON=python
else echo "ERROR: Python not found. Install Python 3."; exit 1; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Public Port Guard — Post-Deployment Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# ---- Resolve deployed resources ----
echo -e "\n${YELLOW}[1/6] Resolving deployed resources...${NC}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" || "$RESOURCE_GROUP" == *ERROR* ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "port-guard-demo")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

AGENT_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null)
AGENT_ENDPOINT=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")
AGENT_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" --query "[0].id" -o tsv 2>/dev/null)

if [[ -z "$AGENT_ENDPOINT" ]]; then
  echo -e "${RED}ERROR: Could not find SRE Agent endpoint in ${RESOURCE_GROUP}.${NC}"
  exit 1
fi

LAW_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.OperationalInsights/workspaces" \
  --query "[0].id" -o tsv 2>/dev/null)

echo -e "${GREEN}  Resource Group: ${RESOURCE_GROUP}${NC}"
echo -e "${GREEN}  Agent:          ${AGENT_NAME}${NC}"
echo -e "${GREEN}  Agent Endpoint: ${AGENT_ENDPOINT}${NC}"

# ---- Helpers ----
get_agent_token() { az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null; }

# ---- Step 2: SRE Agent Administrator role for the current user ----
echo -e "\n${YELLOW}[2/6] Ensuring SRE Agent Administrator role...${NC}"
USER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
if [[ -n "$USER_OID" && -n "$AGENT_ID" ]]; then
  az role assignment create \
    --assignee-object-id "$USER_OID" \
    --assignee-principal-type User \
    --role "SRE Agent Administrator" \
    --scope "$AGENT_ID" \
    --output none 2>/dev/null \
    && echo -e "${GREEN}  ✓ SRE Agent Administrator role assigned.${NC}" \
    || echo -e "${GREEN}  Role already present (or insufficient rights to assign).${NC}"
fi

# ---- Step 3: Activity Log diagnostic settings → Log Analytics ----
echo -e "\n${YELLOW}[3/6] Configuring Activity Log diagnostic settings...${NC}"
EXISTING=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='activity-to-law'].name" -o tsv 2>/dev/null || echo "")
if [[ -z "$EXISTING" ]]; then
  az monitor diagnostic-settings subscription create \
    --name "activity-to-law" \
    --workspace "$LAW_ID" \
    --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true}]' \
    --output none 2>/dev/null \
    && echo -e "${GREEN}  ✓ Diagnostic settings configured.${NC}" \
    || echo -e "${YELLOW}  Could not create diagnostic settings.${NC}"
else
  echo -e "${GREEN}  Diagnostic settings already exist. Skipping.${NC}"
fi

# ---- Step 4: Azure Monitor as incident platform ----
echo -e "\n${YELLOW}[4/6] Configuring Azure Monitor as incident platform...${NC}"
API_VERSION="2025-05-01-preview"
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
az rest --method patch \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"},"experimentalSettings":{"EnableWorkspaceTools":true,"EnableDevOpsTools":true,"EnablePythonTools":true}}}' \
  --output none 2>/dev/null \
  && echo -e "${GREEN}  ✓ Azure Monitor + workspace/Python tools enabled.${NC}" \
  || echo -e "${YELLOW}  Could not configure incident platform (may already be set).${NC}"

# ---- Step 5a: Upload the public-port-guard skill as a knowledge file ----
echo -e "\n${YELLOW}[5/6] Uploading public-port-guard knowledge...${NC}"
TOKEN=$(get_agent_token)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true" \
  -F "files=@${LAB_DIR}/skills/public-port-guard.md;type=text/plain")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  echo -e "${GREEN}  ✓ Uploaded: public-port-guard.md${NC}"
else
  echo -e "${YELLOW}  Upload returned HTTP ${HTTP_CODE}${NC}"
fi

# ---- Step 5b: Create the response plan (routes NSG-change incidents) ----
echo -e "\n${YELLOW}      Creating response plan...${NC}"
echo "      Waiting for Azure Monitor to initialize..."
sleep 30
TOKEN=$(get_agent_token)
curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/public-port-exposure" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

FILTER_CREATED=false
for attempt in 1 2 3 4 5; do
  TOKEN=$(get_agent_token)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/public-port-exposure" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"id":"public-port-exposure","name":"Public Port Exposure","priorities":["Sev0","Sev1","Sev2","Sev3","Sev4"],"titleContains":"","handlingAgent":"","agentMode":"autonomous"}')
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" || "$HTTP_CODE" == "202" || "$HTTP_CODE" == "409" ]]; then
    echo -e "${GREEN}  ✓ Response plan: public-port-exposure${NC}"
    FILTER_CREATED=true
    break
  else
    echo "      ⏳ Attempt ${attempt}/5: HTTP ${HTTP_CODE}, retrying in 15s..."
    sleep 15
  fi
done
[[ "$FILTER_CREATED" == "false" ]] && echo -e "${YELLOW}  Response plan failed — create it in the portal (Builder → Response plans).${NC}"

TOKEN=$(get_agent_token)
curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_response_plan" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# ---- Step 6: Verification ----
echo -e "\n${YELLOW}[6/6] Verifying setup...${NC}"
TOKEN=$(get_agent_token)
echo "  📚 Knowledge Base:"
curl -s "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for f in d.get('files',[]):
        print(f'     {\"✅\" if f.get(\"isIndexed\") else \"⏳\"} {f[\"name\"]}')
    if not d.get('files'): print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null

echo "  🚨 Response plans:"
curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for f in d if isinstance(d,list) else []:
        print(f'     • {f.get(\"name\",f.get(\"id\"))} ({f.get(\"agentMode\",\"?\")})')
except: print('     (could not retrieve)')
" 2>/dev/null

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Public Port Guard setup complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "\n  Next steps:"
echo -e "    1. Apply the approval hook + scheduled task (portal Builder or srectl):"
echo -e "         hooks/port-remediation-approval.yaml"
echo -e "         scheduled-tasks/public-port-scan.yaml"
echo -e "    2. Open a public port to trigger the scenario:"
echo -e "         ${YELLOW}bash scripts/break-ports.sh all${NC}"
echo -e "    3. Watch ${BLUE}https://sre.azure.com${NC} → Incidents, or ask in a new chat:"
echo -e "         ${YELLOW}Scan my VMs for sensitive ports open to the internet and propose blocks.${NC}"
