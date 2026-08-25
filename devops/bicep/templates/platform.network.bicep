import * as platformNetwork from 'types/platform.network.types.bicep'

@description('Input configuration for the integration')
param Configuration platformNetwork.mainNetworkConfigurationType

// Pruned for the "Sealing the Gateway" minimal sample: the full platform's platform.network.bicep
// deploys two peered VNets (workload + core, potentially cross-subscription) and five privatelink.*
// DNS zones for Key Vault/Storage/Service Bus/App Service. This sample needs exactly one VNet (the
// APIM, workspace gateway, and Application Gateway subnets all live in it directly) and exactly one
// DNS zone: the apex-record zone for the injected APIM instance's own hostname. See README.

var resourceGroupInfraName = Configuration.resourceGroup.name
var coreIntegrationName = 'core'
var virtualNetworkName = 'vnet-${Configuration.integration.organizationShortName}-${coreIntegrationName}-${Configuration.integration.environmentLetter}'
var apiManagementName = 'apim-v2-${Configuration.integration.organizationShortName}-${coreIntegrationName}-${Configuration.integration.environmentLetter}'

// Not a "privatelink.*" shared-suffix zone: Microsoft explicitly warns against a zone for the
// "azure-api.net" apex domain (it would hijack DNS for every Azure service using that suffix) and
// instead requires a zone scoped to the exact instance FQDN, with the record at the zone apex ("@").
// The record itself is populated post-deploy by devops/pipelines/scripts/set.apim.internal.dns.record.ps1,
// since VNet injection has no automatic DNS registration the way private endpoints get.
var privateDnsZoneNameApiManagement = '${apiManagementName}.azure-api.net'

module virtualNetworkModule 'modules/virtual.network.bicep' = {
  scope: resourceGroup(subscription().subscriptionId, resourceGroupInfraName)
  name: '${Configuration.integration.workload.name}-vnet'
  params: {
    Configuration: Configuration
    // platform.core.bicep looks this VNet up as "existing" by the fixed name below, not by
    // Configuration.integration.workload.shortName (this deployment's own default), so it must match.
    VirtualNetworkNameOverride: virtualNetworkName
  }
}

module privateDnsZoneApiManagement 'modules/private.dns.zone.bicep' = {
  scope: resourceGroup(subscription().subscriptionId, resourceGroupInfraName)
  name: '${Configuration.integration.workload.name}-pdns-apim'
  params: {
    PrivateDnsZoneName: privateDnsZoneNameApiManagement
  }
}

module privateDnsZoneApiManagementVnetLink 'modules/private.dns.vnet.link.bicep' = {
  scope: resourceGroup(subscription().subscriptionId, resourceGroupInfraName)
  name: 'pdns-vnet-link-apim'
  dependsOn: [privateDnsZoneApiManagement]
  params: {
    PrivateDnsZoneName: privateDnsZoneNameApiManagement
    VirtualNetworkName: virtualNetworkName
    VirtualNetworkResourceId: virtualNetworkModule.outputs.virtualNetworkResourceId
  }
}
