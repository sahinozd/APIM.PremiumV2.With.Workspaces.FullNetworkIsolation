import * as module from '../types/module.types.bicep'

@description('Network security group for the integration.')
param SubnetConfiguration object

@description('Name of the virtual network.')
param VirtualNetworkName string

@description('Name of the network security group to associate to the subnet.')
param NetworkSecurityGroupName string

@description('Resource group that contains the network security group.')
param NetworkSecurityGroupResourceGroupName string

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' = {
  name: '${VirtualNetworkName}/${SubnetConfiguration.name}'
  properties: {
    addressPrefix: SubnetConfiguration.addressSpace
    delegations: SubnetConfiguration.delegations
    networkSecurityGroup: {
      id: resourceId(NetworkSecurityGroupResourceGroupName, 'Microsoft.Network/networkSecurityGroups', NetworkSecurityGroupName)
    }
  }
}

output subnet module.defaultOutputType = {
  // Extract subnet name from resource ID for easier consumption by other modules, because the output normally is vnet/subnet
  resourceName: last(split(subnet.name, '/'))
  resourceId: subnet.id
}
