// ============================================================
// Monitoring Module — Log Analytics + Activity Log alert on NSG changes
// The Activity Log alert fires whenever an NSG security rule is created or
// updated, so opening a public port becomes an Azure Monitor incident that
// routes to the SRE Agent for investigation and (approved) remediation.
// ============================================================

param location string
param environmentName string
param tags object
param resourceGroupId string

// Log Analytics Workspace (Activity Logs + VM telemetry land here)
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Action group (empty receivers — the SRE Agent picks up fired alerts via its
// Azure Monitor incident-platform integration, mirroring the other VM lab).
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-portguard-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'PortGuard'
    enabled: true
  }
}

// Activity Log alert — NSG security rule created or updated.
// Scoped to this resource group so it only reacts to the lab's own changes.
resource nsgRuleChangeAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-nsg-rule-change-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    scopes: [
      resourceGroupId
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Network/networkSecurityGroups/securityRules/write'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Fires when an NSG security rule is created or modified — SRE Agent evaluates whether a sensitive port was opened to the public internet.'
  }
}

// Activity Log alert — whole NSG created or updated (covers bulk rule pushes
// that replace the securityRules collection in a single NSG write).
resource nsgChangeAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-nsg-change-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    scopes: [
      resourceGroupId
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Network/networkSecurityGroups/write'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Fires when a network security group is created or modified — SRE Agent re-scans the NSG for public exposure of sensitive ports.'
  }
}

output logAnalyticsWorkspaceId string = law.id
output logAnalyticsWorkspaceCustomerId string = law.properties.customerId
output actionGroupId string = actionGroup.id
