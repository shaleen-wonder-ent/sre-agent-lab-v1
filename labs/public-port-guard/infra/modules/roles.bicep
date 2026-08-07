// ============================================================
// Roles Module — least-privilege RBAC for the SRE Agent identity
// Reader          → discover VMs, NICs, public IPs, NSGs
// Network Contributor → block a port (delete/deny NSG rule) after approval
// Monitoring Reader   → read Activity Log / alerts
// Log Analytics Reader → run KQL against the workspace
// ============================================================

param sreAgentPrincipalId string
param resourceGroupId string
param logAnalyticsWorkspaceId string

// Reader on the resource group (resource discovery)
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Network Contributor on the resource group (NSG rule remediation)
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'
resource networkContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Reader on the resource group (Activity Log + alerts)
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
resource monitoringReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Log Analytics Reader on the workspace (KQL queries)
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
resource lawReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalyticsWorkspaceId, sreAgentPrincipalId, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}
