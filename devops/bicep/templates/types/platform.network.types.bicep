// Pruned for the "Sealing the Gateway" minimal sample: the full platform's platform.network.types.bicep
// models two peered VNets (a workload VNet and a separately-subscriptioned core VNet, plus five
// privatelink.* DNS zones for Key Vault/Storage/Service Bus/App Service). This sample uses a single
// VNet that holds the APIM, workspace gateway, and Application Gateway subnets directly, since VNet
// peering and the workload/core split aren't part of the isolation pattern itself. See README.

@export()
@sealed()
type networkWorkloadType = {
  @description('Name of the workload, e.g. hybrid integration platform.')
  name: string
  @description('Short name of the workload, e.g. hip')
  shortName: string
}

@export()
@sealed()
type networkIntegrationType = {
  @description('Environment letter used for specific integration / deployment.')
  environmentLetter: 'o' | 't' | 'a' | 'p'
  @description('Full organization name used in resource group naming conventions.')
  organizationName: string
  @description('Short organization identifier used in resource naming conventions.')
  @maxLength(4)
  organizationShortName: string
  @description('Workload specific details.')
  workload: networkWorkloadType
}

@export()
@sealed()
@description('Network-only configuration object for the single-VNet network deployment.')
type mainNetworkConfigurationType = {
  @description('Workload and environment context used for naming network resources.')
  integration: networkIntegrationType
  @description('Network resource group details used to target VNet/subnet deployment scope.')
  resourceGroup: {
    name: string
  }
  @description('Address space for the virtual network that hosts APIM, its workspace gateway(s), and Application Gateway.')
  networking: {
    virtualNetwork: {
      addressSpace: string
    }
  }
}
