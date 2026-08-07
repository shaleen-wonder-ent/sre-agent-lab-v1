// ============================================================
// Network Module — VNet + shared subnet NSG
// Baseline is COMPLIANT: SSH only from corp range, HTTP open, deny-all.
// scripts/break-ports.sh later opens sensitive ports to the internet so the
// SRE Agent has something to detect and remediate.
// ============================================================

param location string
param environmentName string
param tags object

// Shared Network Security Group (applied at subnet scope → guards both VMs)
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${environmentName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      // SSH allowed only from the corporate/private range (compliant baseline)
      {
        name: 'AllowSSH-FromCorpOnly'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      // Public HTTP is legitimate for the web front end
      {
        name: 'AllowHTTP-Public'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      // Public HTTPS is legitimate for the web front end
      {
        name: 'AllowHTTPS-Public'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      // Default explicit deny for everything else inbound
      {
        name: 'DenyAll-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Virtual Network with a single application subnet guarded by the NSG
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-${environmentName}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output appSubnetId string = vnet.properties.subnets[0].id
output nsgName string = nsg.name
output nsgId string = nsg.id
