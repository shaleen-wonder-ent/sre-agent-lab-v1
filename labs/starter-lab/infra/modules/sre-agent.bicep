@description('Location for resources')
param location string

@description('SRE Agent name')
param agentName string

@description('User-Assigned Managed Identity resource ID')
param identityId string

@description('User-Assigned Managed Identity principal ID')
param identityPrincipalId string

@description('Application Insights App ID')
param appInsightsAppId string

@description('Application Insights Connection String')
@secure()
param appInsightsConnectionString string

@description('Application Insights resource ID')
param appInsightsId string

@description('Log Analytics workspace resource ID')
param logAnalyticsId string

@description('Resource Group ID to add as managed resource')
param managedResourceGroupId string

// SRE Agent Administrator role ID
var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

// Create the SRE Agent
#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link: /app-insights-resource-id': appInsightsId
    'lab': 'sre-agent-lab'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      managedResources: [
        managedResourceGroupId
      ]
      identity: identityId
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: identityId
      accessLevel: 'Low'
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    mcpServers: []
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
  }
}

// Assign SRE Agent Administrator role to the deployer
resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

var connectorRoles = [
  'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  '43d0d8ad-25c7-4714-9337-8ba259a9fe05' // Monitoring Reader
  '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Reader
]

resource connectorRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in connectorRoles: {
  name: guid(resourceGroup().id, sreAgent.id, roleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: appInsightsId
    extendedProperties: {
      armResourceId: appInsightsId
      appId: appInsightsAppId
      resource: {
        name: last(split(appInsightsId, '/'))
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsId
    extendedProperties: {
      armResourceId: logAnalyticsId
      resource: {
        name: last(split(logAnalyticsId, '/'))
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource azureMonitorConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'azure-monitor'
  properties: {
    dataConnectorType: 'MonitorClient'
    dataSource: 'n/a'
    identity: 'system'
  }
}

// Outputs
output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentPortalUrl string = 'https://sre.azure.com'
