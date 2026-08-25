import * as types from '../../../devops/bicep/templates/types/platform.network.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample, mirrors the shape of the full platform's
// network/deployment/templates/platform.network.resources.bicep, but drops the core/workload VNet
// split (AddressSpaceCoreVirtualNetwork, CoreSubscriptionId): this sample deploys a single VNet that
// directly holds the APIM, workspace gateway, and Application Gateway subnets. See README.

@description('Address space of the virtual network that will host API Management, its workspace gateway(s), and Application Gateway (e.g. "10.0.0.0/16").')
param AddressSpaceVirtualNetwork string

@description('Short description of the project or application.')
param WorkloadName string

@description('Short name of the workload, e.g. hip')
param WorkloadShortName string

@description('Abbrevation of the environment in one character.')
@allowed(['o', 't', 'a', 'p'])
param EnvironmentLetter string

@description('Full organization name used in resource group naming conventions.')
param OrganizationName string

@description('Short organization identifier used in resource naming conventions.')
@maxLength(4)
param OrganizationShortName string

var integrationName = 'network'
var networkResourceGroupName = 'rg-${OrganizationName}-network-${EnvironmentLetter}'

var configuration types.mainNetworkConfigurationType = {
  integration: {
    environmentLetter: EnvironmentLetter
    organizationName: OrganizationName
    organizationShortName: OrganizationShortName
    workload: {
      name: WorkloadName
      shortName: WorkloadShortName
    }
  }
  resourceGroup: {
    name: networkResourceGroupName
  }
  networking: {
    virtualNetwork: {
      addressSpace: AddressSpaceVirtualNetwork
    }
  }
}

module platform '../../../devops/bicep/templates/platform.network.bicep' = {
  name: '${integrationName}-network-template'
  params: {
    Configuration: configuration
  }
}
