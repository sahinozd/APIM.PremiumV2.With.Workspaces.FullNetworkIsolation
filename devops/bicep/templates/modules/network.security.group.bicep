import * as module from '../types/module.types.bicep'
import * as generic from '../types/generic.types.bicep'

@description('Input configuration for the integration.')
param Configuration {
  integration: generic.integrationType
}

@description('Subnet and NSG configuration.')
param SubnetConfiguration object

@description('Network security group location.')
param Location string = resourceGroup().location

// Normalize flattened rule objects into the NSG securityRules schema.
var normalizedSecurityRules = [
  for rule in SubnetConfiguration.networkSecurityGroup.rules: {
    name: rule.name
    properties: union(
      {
        protocol: rule.protocol
        sourcePortRange: rule.?sourcePortRange ?? '*'
        destinationPortRange: rule.?destinationPortRange ?? '*'
        sourceAddressPrefix: rule.?sourceAddressPrefix ?? '*'
        destinationAddressPrefix: rule.?destinationAddressPrefix ?? '*'
        access: rule.access
        priority: rule.priority
        direction: rule.direction
      },
      !empty(rule.?description ?? '') ? {
        description: rule.description
      } : {},
      !empty(rule.?sourcePortRanges ?? []) ? {
        sourcePortRanges: rule.sourcePortRanges
      } : {},
      !empty(rule.?destinationPortRanges ?? []) ? {
        destinationPortRanges: rule.destinationPortRanges
      } : {},
      !empty(rule.?sourceAddressPrefixes ?? []) ? {
        sourceAddressPrefixes: rule.sourceAddressPrefixes
      } : {},
      !empty(rule.?destinationAddressPrefixes ?? []) ? {
        destinationAddressPrefixes: rule.destinationAddressPrefixes
      } : {}
    )
  }
]

// When shortName is empty (core resources are not workload-specific) the workload segment is omitted.
var workloadShortNamePrefix = !empty(Configuration.integration.workload.shortName) ? '${Configuration.integration.workload.shortName}-' : ''

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-${Configuration.integration.organizationShortName}-${workloadShortNamePrefix}${Configuration.integration.workload.integrationName}-${SubnetConfiguration.direction}-${Configuration.integration.environmentLetter}'
  location: Location
  properties: {
    securityRules: normalizedSecurityRules
  }
}

output networkSecurityGroup module.defaultOutputType = {
  resourceName: networkSecurityGroup.name
  resourceId: networkSecurityGroup.id
}
