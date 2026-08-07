#!/bin/bash
# ============================================================
# Break Ports Script — open sensitive ports to the public internet
# so the SRE Agent can detect, report, and (with approval) block them.
#
# Usage:
#   bash scripts/break-ports.sh ssh     — open SSH (22) to 0.0.0.0/0
#   bash scripts/break-ports.sh rdp     — open RDP (3389) to 0.0.0.0/0
#   bash scripts/break-ports.sh db      — open PostgreSQL (5432) to 0.0.0.0/0
#   bash scripts/break-ports.sh all     — open SSH + RDP + DB (default)
#   bash scripts/break-ports.sh reset   — remove the insecure rules again
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCENARIO="${1:-all}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" || "$RESOURCE_GROUP" == *ERROR* ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "port-guard-demo")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

NSG_NAME=$(az network nsg list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
if [[ -z "$NSG_NAME" ]]; then
  echo -e "${RED}ERROR: No NSG found in ${RESOURCE_GROUP}. Did azd provision succeed?${NC}"
  exit 1
fi

echo -e "${BLUE}Resource group:${NC} ${RESOURCE_GROUP}"
echo -e "${BLUE}Target NSG:${NC}     ${NSG_NAME}"
echo ""

open_port() {
  local name="$1" port="$2" prio="$3" label="$4"
  echo -e "${YELLOW}Opening ${label} (port ${port}) to 0.0.0.0/0 on ${NSG_NAME}...${NC}"
  az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "$name" \
    --priority "$prio" \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --source-address-prefixes "Internet" \
    --source-port-ranges "*" \
    --destination-address-prefixes "*" \
    --destination-port-ranges "$port" \
    --output none 2>/dev/null \
    && echo -e "${GREEN}  ✓ ${label} now open to the internet${NC}" \
    || echo -e "${RED}  ✗ Failed to open ${label}${NC}"
}

case "$SCENARIO" in
  ssh)  open_port "AllowSSH-FromAnywhere-INSECURE" 22 200 "SSH" ;;
  rdp)  open_port "AllowRDP-FromAnywhere-INSECURE" 3389 210 "RDP" ;;
  db)   open_port "AllowPostgres-FromAnywhere-INSECURE" 5432 220 "PostgreSQL" ;;
  all)
    open_port "AllowSSH-FromAnywhere-INSECURE" 22 200 "SSH"
    open_port "AllowRDP-FromAnywhere-INSECURE" 3389 210 "RDP"
    open_port "AllowPostgres-FromAnywhere-INSECURE" 5432 220 "PostgreSQL"
    ;;
  reset)
    echo -e "${YELLOW}Removing insecure rules...${NC}"
    for r in AllowSSH-FromAnywhere-INSECURE AllowRDP-FromAnywhere-INSECURE AllowPostgres-FromAnywhere-INSECURE; do
      az network nsg rule delete -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$r" --output none 2>/dev/null \
        && echo -e "${GREEN}  ✓ Removed ${r}${NC}" || true
    done
    echo -e "\n${GREEN}✓ NSG returned to compliant baseline.${NC}"
    exit 0
    ;;
  help|*)
    echo "Usage: bash scripts/break-ports.sh <ssh|rdp|db|all|reset>"
    exit 0
    ;;
esac

echo ""
echo -e "${GREEN}✓ Public port(s) opened.${NC}"
echo -e "What happens next:"
echo -e "  1. The ${BLUE}alert-nsg-rule-change${NC} Activity Log alert fires (~2-5 min)."
echo -e "  2. Azure Monitor raises an incident to the SRE Agent."
echo -e "  3. The agent runs the ${BLUE}public-port-guard${NC} skill, reports the exposure,"
echo -e "     and proposes a block (gated by the approval hook)."
echo ""
echo -e "Watch: ${BLUE}https://sre.azure.com${NC} → Incidents"
echo -e "Or ask in a new agent chat:"
echo -e "  ${YELLOW}Scan my VMs for sensitive ports open to the internet and propose blocks.${NC}"
