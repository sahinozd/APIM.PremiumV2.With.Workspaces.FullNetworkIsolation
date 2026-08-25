@description('Name of the private DNS zone.')
param PrivateDnsZoneName string

@description('Name of the virtual network to link.')
param VirtualNetworkName string

@description('Resource ID of the virtual network to link.')
param VirtualNetworkResourceId string

@description('Optional deployment datetime stamp.')
param DateTimeString string = utcNow()

@description('Optional location for the private DNS virtual network link.')
param Location string = 'global'

// Link the private DNS zone to the virtual network for DNS resolution
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: '${PrivateDnsZoneName}/${VirtualNetworkName}'
  location: Location
  properties: {
    virtualNetwork: {
      id: VirtualNetworkResourceId
    }
    registrationEnabled: false
  }
  tags: {
    DeploymentStamp: DateTimeString
  }
}

output vnetLink object = {
  resourceName: vnetLink.name
  resourceId: vnetLink.id
}
