using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'port-guard-demo')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param vmAdminUsername = readEnvironmentVariable('VM_ADMIN_USERNAME', 'azureuser')
param vmAdminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', '')
