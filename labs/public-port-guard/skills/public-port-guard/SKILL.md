---
name: public-port-guard
description: Use when investigating VMs that expose sensitive ports (SSH, RDP, databases, Docker) to the public internet, when an NSG-change incident fires, when the public-port-scan task runs, or when asked to audit or block public network exposure on Virtual Machines.
tools:
  - SearchMemory
  - RunAzCliReadCommands
  - RunAzCliWriteCommands
  - GetAzCliHelp
  - QueryLogAnalyticsByWorkspaceId
---

# Public Port Guard

Detect and remediate Virtual Machines that expose sensitive ports to the public
internet. Report first; block only after explicit approval.

## When to use

- An Azure Monitor incident fires from an NSG-change alert
  (`alert-nsg-rule-change-*`, `alert-nsg-change-*`).
- The scheduled `public-port-scan` task runs.
- A user asks to audit VMs for open/public ports or to block one.

## Exposure policy

Flag an inbound NSG rule when ALL hold:

1. `access == Allow`, `direction == Inbound`.
2. Source is public: `Internet`, `*`, `0.0.0.0/0`, `::/0`, `any`.
3. Destination port is sensitive or wildcard.

Sensitive ports: 22, 3389, 3306, 5432, 1433, 6379, 27017, 9200, 5601, 5984,
2375, 2376, 11211. Public 80/443 on a `role: web-frontend` VM is legitimate —
report as Informational only.

## Procedure

1. Enumerate VMs, NICs, subnets, and the NSG that actually applies to each VM
   (`az vm list -d`, `az network nic list`, `az network nsg list`).
2. Read the live NSG rules from ARM (`az network nsg rule list -g <rg>
   --nsg-name <nsg>` or `az network nsg show`) — this is the authoritative
   current state. Do NOT judge exposure from `az graph query` / Azure Resource
   Graph: it lags writes by minutes and causes false negatives right after an
   NSG change. Flag inbound Allow rules with a public source and a
   sensitive/wildcard port; check both `destinationPortRange` and
   `destinationPortRanges`, including ranges.
3. Confirm reachability: only rank Critical when a running VM with a public IP
   sits behind the rule.
4. Rank Critical / High / Medium / Informational (see the knowledge file
   `public-port-guard.md` for the exact matrix).
5. Attribute the change via `AzureActivity` — who opened the port and when.
6. Produce a findings table: severity, VM, NSG/rule, port, source, public IP,
   opened-by, timestamp.

## Remediation (requires approval)

Propose the fix, then let the `port-remediation-approval` hook collect a yes/no.
Prefer narrowing the source over deletion:

```bash
az network nsg rule update -g <rg> --nsg-name <nsg> --name <rule> \
  --source-address-prefixes 10.0.0.0/8
```

Delete only if the rule is clearly unwanted:

```bash
az network nsg rule delete -g <rg> --nsg-name <nsg> --name <rule>
```

After remediation, re-scan and confirm the alert auto-resolves. Report the
before/after state.

## Safety

- Always report before proposing a block.
- Never modify an NSG rule without approval.
- Never delete a VM, NIC, or public IP.
- Never touch the compliant HTTP/HTTPS baseline rules.
