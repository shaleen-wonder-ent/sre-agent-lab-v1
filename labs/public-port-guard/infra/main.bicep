// ============================================================
// Main Bicep — Public Port Guard Demo
// Deploys: 2 Linux VMs (shared subnet NSG) + Monitoring + SRE Agent
// Scenario: SRE Agent detects VMs with sensitive ports open to the public
//           internet, reports them, and (with approval) blocks the port.
// ============================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (e.g. "port-guard-demo")')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Object ID of the user running azd (for SRE Agent Administrator role)')
param principalId string = ''

@description('VM admin username')
param vmAdminUsername string = 'azureuser'

@secure()
@description('VM admin password')
param vmAdminPassword string

// Tags applied to all resources
var tags = {
  'azd-env-name': environmentName
  purpose: 'public-port-guard-demo'
  environment: 'demo'
  'cost-center': 'sre-security'
}

// Resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// ---- Networking (VNet + shared subnet NSG) ----
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
  }
}

// ---- VM 1: web front end ----
module vmWeb 'modules/vm.bicep' = {
  scope: rg
  name: 'vm-web'
  params: {
    location: location
    vmName: 'vm-web-01'
    subnetId: network.outputs.appSubnetId
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    vmSize: 'Standard_B1s'
    tags: union(tags, { role: 'web-frontend' })
  }
}

// ---- VM 2: application / jump host ----
module vmApp 'modules/vm.bicep' = {
  scope: rg
  name: 'vm-app'
  params: {
    location: location
    vmName: 'vm-app-01'
    subnetId: network.outputs.appSubnetId
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    vmSize: 'Standard_B1s'
    tags: union(tags, { role: 'application-server' })
  }
}

// ---- Monitoring (LAW + Activity Log alert on NSG rule changes) ----
module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    resourceGroupId: rg.id
  }
}

// ---- SRE Agent ----
module sreAgent 'modules/sre-agent.bicep' = {
  scope: rg
  name: 'sre-agent'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    managedResourceGroupId: rg.id
    deployingUserObjectId: principalId
  }
}

// ---- Role Assignments for the SRE Agent identity ----
module roles 'modules/roles.bicep' = {
  scope: rg
  name: 'role-assignments'
  params: {
    sreAgentPrincipalId: sreAgent.outputs.sreAgentPrincipalId
    resourceGroupId: rg.id
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// ============================================================
// Outputs (consumed by scripts/post-deploy.sh and break-ports.sh)
// ============================================================
output RESOURCE_GROUP_NAME string = rg.name
output VM_WEB_NAME string = vmWeb.outputs.vmName
output VM_WEB_IP string = vmWeb.outputs.publicIpAddress
output VM_APP_NAME string = vmApp.outputs.vmName
output VM_APP_IP string = vmApp.outputs.publicIpAddress
output NSG_NAME string = network.outputs.nsgName
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output SRE_AGENT_NAME string = sreAgent.outputs.sreAgentName
output SRE_AGENT_ID string = sreAgent.outputs.sreAgentId
