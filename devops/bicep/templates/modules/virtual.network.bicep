import * as platformNetwork from '../types/platform.network.types.bicep'

@description('The main configuration object for the shared integration.')
param Configuration platformNetwork.mainNetworkConfigurationType

@description('Location for the virtual network.')
param Location string = resourceGroup().location

@description('Optional override for the virtual network name. When empty the standard naming convention is applied.')
param VirtualNetworkNameOverride string = ''

// Variables
var virtualNetworkName = !empty(VirtualNetworkNameOverride)
  ? VirtualNetworkNameOverride
  : 'vnet-${Configuration.integration.organizationShortName}-${Configuration.integration.workload.shortName}-${Configuration.integration.environmentLetter}'

// Virtual Network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: virtualNetworkName
  location: Location
  tags: {
    environment: Configuration.integration.environmentLetter
    workload: Configuration.integration.workload.name
  }
  properties: {
    addressSpace: {
      addressPrefixes: [
        Configuration.networking.virtualNetwork.addressSpace
      ]
    }
    enableVmProtection: false
    enableDdosProtection: false
  }
}

@description('Resource ID of the created virtual network.')
output virtualNetworkResourceId string = virtualNetwork.id

@description('Name of the created virtual network.')
output virtualNetworkName string = virtualNetwork.name
