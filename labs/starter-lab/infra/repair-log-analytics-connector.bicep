targetScope = 'resourceGroup'

@description('Existing Azure SRE Agent name')
param agentName string

@description('Existing Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Existing managed identity used by the connector')
param connectorIdentityId string

resource agent 'Microsoft.App/agents@2025-05-01-preview' existing = {
  name: agentName
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsWorkspaceId
    extendedProperties: {
      armResourceId: logAnalyticsWorkspaceId
      resource: {
        name: last(split(logAnalyticsWorkspaceId, '/'))
      }
    }
    identity: connectorIdentityId
  }
}

output connectorId string = logAnalyticsConnector.id
output workspaceId string = logAnalyticsWorkspaceId
