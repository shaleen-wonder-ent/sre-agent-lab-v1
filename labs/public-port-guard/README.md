# Public Port Guard — SRE Agent Lab

An Azure SRE Agent that **monitors your VMs for sensitive ports exposed to the
public internet**, reports the exposure with evidence, and — only after you
approve — **blocks the port**.

Built for the scenario: *"We should have an SRE Agent where it monitors if any
VM has an open public port. The agent should report it, and if we allow, it
should block the port."*

---

## What Gets Deployed

| Resource | Purpose |
|----------|---------|
| **2 Linux VMs** (`vm-web-01`, `vm-app-01`) | Targets, each with a public IP, sharing one subnet NSG |
| **Network Security Group** | Compliant baseline (SSH from corp only, public 80/443, deny-all) |
| **Log Analytics Workspace** | Activity Log + VM telemetry store |
| **Activity Log alerts** | Fire when an NSG rule/NSG is created or modified → incident to the agent |
| **SRE Agent** (`Microsoft.App/agents`) | Autonomous investigation, approval-gated remediation |
| **Managed identity + RBAC** | Reader, Network Contributor, Monitoring Reader, Log Analytics Reader |

### Agent configuration (data-plane, via `scripts/post-deploy.sh`)

| Component | Purpose |
|-----------|---------|
| **public-port-guard** skill | How to detect, rank, and block public ports |
| **public-port-exposure** response plan | Routes NSG-change incidents to the agent (autonomous) |
| **port-remediation-approval** hook | Requires "yes" before any NSG rule change |
| **public-port-scan** scheduled task | Proactive scan every 30 minutes |

> **Why data-plane and not Bicep child resources?** The
> `Microsoft.App/agents/{skills,incidentFilters}` ARM API ("Agent Extensions")
> is restricted to internal tenants and fails on standard tenants. This lab
> configures skills, response plans, hooks, and knowledge through the SRE Agent
> **data-plane API**, which works on any tenant.

---

## How It Works

```
Someone opens a public port
        │
        ▼
NSG securityRules/write  ──►  Activity Log alert  ──►  Azure Monitor incident
                                                              │
                                                              ▼
                                              SRE Agent (public-port-guard skill)
                                                              │
                              ┌───────────────────────────────┼───────────────────────────────┐
                              ▼                                                                 ▼
                      Reports exposure                                         Proposes a block (NSG rule)
                   (severity, evidence,                                                 │
                    who opened it, when)                                                ▼
                                                                        port-remediation-approval hook
                                                                                       │
                                                                            "yes" ─────┴───── "no"
                                                                              │                 │
                                                                              ▼                 ▼
                                                                      Blocks the port      Leaves it, reports
```

The agent also runs the **public-port-scan** every 30 minutes to catch ports
that were opened outside of an alert window.

---

## Prerequisites

| Tool | Windows | macOS |
|------|---------|-------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+ | `winget install Microsoft.AzureCLI` | `brew install azure-cli` |
| [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.9+ | `winget install Microsoft.Azd` | `brew install azd` |
| [Git Bash](https://git-scm.com/) | `winget install Git.Git` | preinstalled |
| [Python](https://python.org) 3.10+ | `winget install Python.Python.3.12` | `brew install python3` |

**Azure:** an active subscription with **Owner** role (for RBAC). Register the
provider once:

```bash
az provider register -n Microsoft.App --wait
```

---

## Deploy

### Fast path — Windows (recommended)

One command from ground zero: creates the azd environment, generates a VM
password, provisions, and fully configures the agent (skill, connectors, hook,
response plan, scheduled task).

```powershell
cd labs/public-port-guard
az login
azd auth login
pwsh -File scripts/setup.ps1 -EnvName port-guard-demo -Location eastus2
```

Prefer to run the steps yourself? Provision, then configure:

```powershell
azd env new port-guard-demo
azd env set VM_ADMIN_PASSWORD '<Strong!Passw0rd>'   # key value — do NOT pipe
azd env set AZURE_LOCATION eastus2
azd provision
pwsh -File scripts/configure-agent.ps1
```

> **Why PowerShell on Windows?** Git Bash `curl` cannot reach the
> `*.azuresre.ai` data-plane endpoint on Windows (returns HTTP 000).
> `configure-agent.ps1` uses `Invoke-RestMethod` and also installs the extended
> skill, the Log Analytics + Azure Monitor connectors, the approval hook, and
> the scheduled task — everything the agent needs.

### macOS / Linux

```bash
cd labs/public-port-guard
azd env new port-guard-demo
azd env set VM_ADMIN_PASSWORD '<Strong!Passw0rd>'
azd env set AZURE_LOCATION eastus2
azd provision
bash scripts/post-deploy.sh
# then apply the hook + scheduled task:
srectl hook apply          -f hooks/port-remediation-approval.yaml
srectl scheduledtask apply -f scheduled-tasks/public-port-scan.yaml
```

### What the agent ends up with

| Asset | Source |
|-------|--------|
| `public-port-guard` **knowledge** file (indexed) | `skills/public-port-guard.md` |
| `public-port-guard` **extended skill** (tools + detail) | `skills/public-port-guard/SKILL.md` |
| `log-analytics` + `azure-monitor` **connectors** | `configure-agent.ps1` |
| `Public Port Exposure` **response plan** (autonomous) | data plane |
| `port-remediation-approval` **hook** | `hooks/port-remediation-approval.yaml` |
| `public-port-scan` **scheduled task** (every 30 min) | `scheduled-tasks/public-port-scan.yaml` |
| Incident platform = **Azure Monitor** | data plane |

> **Knowledge vs skill:** the knowledge file is searchable reference
> (`SearchMemory`); the extended skill auto-activates by description and carries
> the scoped tools. This lab installs both.


---

## Run the Scenario

### 1. Open a public port (the "break")

```bash
bash scripts/break-ports.sh all      # opens SSH 22, RDP 3389, PostgreSQL 5432 to 0.0.0.0/0
# or one at a time:  ssh | rdp | db
```

### 2. Watch the agent respond

- Open **sre.azure.com → Incidents**. Within a few minutes the NSG-change alert
  fires and the agent investigates autonomously.
- Or drive it directly in a new chat:

  ```
  Scan my VMs for sensitive ports open to the internet. Report each finding with
  severity, the NSG rule, who opened it, and propose a block. Do not change
  anything yet.
  ```

### 3. Approve the block

When the agent proposes a fix, the **port-remediation-approval** hook pauses and
asks for consent. Reply:

```
yes
```

The agent narrows the offending rule to the corporate range (or deletes it),
then re-scans and confirms the alert resolves.

### 4. Reset (optional)

```bash
bash scripts/break-ports.sh reset    # remove the insecure rules manually
```

---

## What the Agent Flags

**Sensitive ports** (public + reachable ⇒ Critical/High):
22 (SSH), 3389 (RDP), 3306 (MySQL), 5432 (PostgreSQL), 1433 (SQL Server),
6379 (Redis), 27017 (MongoDB), 9200 (Elasticsearch), 5601 (Kibana),
5984 (CouchDB), 2375/2376 (Docker), 11211 (Memcached).

**Not flagged** (legitimate): public 80/443 on the `role: web-frontend` VM —
reported as Informational only.

Severity accounts for **real reachability**: a rule that opens a port is only
Critical when a running VM with a public IP actually sits behind it.

---

## Safety Model

- The agent **reports first** and never blocks a port without approval.
- The **port-remediation-approval** hook gates every `az network nsg rule
  create/update/delete`.
- The agent may **narrow or delete an offending rule** but never deletes a VM,
  NIC, or public IP, and never touches the compliant HTTP/HTTPS baseline.
- This complements — it does not replace — Azure Policy (deny/audit at
  enforcement time) and Defender for Cloud (continuous posture). The SRE Agent
  provides contextual investigation and guarded remediation.

---

## Files

```
public-port-guard/
├── azure.yaml                        # azd config
├── infra/
│   ├── main.bicep                    # subscription-scope entry point
│   ├── main.bicepparam
│   └── modules/
│       ├── network.bicep             # VNet + compliant baseline NSG
│       ├── vm.bicep                  # Linux VM + public IP + AMA
│       ├── monitoring.bicep          # LAW + Activity Log alerts on NSG changes
│       ├── sre-agent.bicep           # Microsoft.App/agents + identity
│       └── roles.bicep               # least-privilege RBAC
├── skills/
│   ├── public-port-guard.md          # knowledge file (uploaded by post-deploy)
│   └── public-port-guard/SKILL.md    # Skill Builder format
├── hooks/
│   └── port-remediation-approval.yaml
├── scheduled-tasks/
│   └── public-port-scan.yaml
└── scripts/
    ├── setup.ps1                     # one-command ground-zero setup (Windows)
    ├── configure-agent.ps1           # full data-plane config (Windows/any, reliable)
    ├── post-deploy.sh                # data-plane config (macOS/Linux)
    └── break-ports.sh                # opens/resets public ports
```

---

## Cleanup

```bash
azd down --purge
```

This removes the resource group and all lab resources.
