import * as types from '../../../devops/bicep/templates/types/platform.core.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample: the full platform.core.resources.bicep also
// wires up Service Bus, resource-health alerting, and the deterministic role-id used by an Entra app
// registration for APIM's OAuth2 audience. None of those are part of the network-isolation pattern
// this sample demonstrates, so their params are removed too (AddressSpaceCoreServicebusBackend,
// AlertEmailAddress, AreAlertsEnabled, ServiceBusLocation, SkuServiceBus, SubscriptionId, TenantId,
// TenantName — the last two are dropped because generic.integrationType.tenant is still required by
// the type, so this sample just fills it with fixed placeholder values below). See README.

@description('CIDR address space for the API Management VNet-injection subnet (e.g. "10.0.1.0/24"), used to fully isolate the default/main gateway (Internal mode, PremiumV2 only). Minimum /27, /24 recommended for scale-out headroom. Leave empty to deploy without VNet connectivity for the main gateway.')
param AddressSpaceCoreApimanagementInternal string = ''

@description('CIDR address space for the dedicated Application Gateway subnet (e.g. "10.0.5.0/24"). Minimum /27 per Azure Application Gateway v2 requirements, /24 recommended, this subnet also carries one frontend port per workspace gateway backend, so it grows with gateway count. Leave empty to skip Application Gateway deployment, in which case APIM will have no public path at all (VNet/VPN/ExpressRoute access only).')
param AddressSpaceCoreApplicationGateway string = ''

@description('Base64-encoded PFX certificate data for the Application Gateway HTTPS listener. Required when AddressSpaceCoreApplicationGateway is set. Provisioning the actual certificate (self-signed for dev, a real certificate for production) is a manual prerequisite, see README.')
@secure()
param ApplicationGatewaySslCertificateData string = ''

@description('Password for the Application Gateway PFX certificate. Required when AddressSpaceCoreApplicationGateway is set.')
@secure()
param ApplicationGatewaySslCertificatePassword string = ''

@description('CIDR address space for the "main" API Management workspace gateway subnet. Leave empty to skip deploying that gateway.')
param AddressSpaceCoreApimanagementGatewayMain string = ''

@description('"External" = gateway is publicly reachable from the internet with VNet outbound routing. "Internal" = gateway endpoint is private, only reachable from within the VNet.')
@allowed(['External', 'Internal'])
param ApiManagementGatewayMainVirtualNetworkType string = 'External'

@description('API Management publisher e-mail address.')
param ApiManagementPublisherEmail string

@description('API Management publisher display name.')
param ApiManagementPublisherName string = 'Hybrid Integration Platform'

@description('API Management v2 SKU. Only PremiumV2 supports VNet injection of the default/main gateway (the only network mode this platform deploys, via AddressSpaceCoreApimanagementInternal) and workspace gateways. BasicV2/StandardV2 can still be used for a no-VNet instance.')
@allowed(['BasicV2', 'StandardV2', 'PremiumV2'])
param ApiManagementSku string = 'BasicV2'

@description('Short description of the project or application.')
param WorkloadName string

@description('Abbreviated description of the project or application.')
param WorkloadShortName string

@description('Abbrevation of the environment in one character.')
@allowed(['o', 't', 'a', 'p'])
param EnvironmentLetter string

@description('Full organization name used in resource group naming conventions.')
param OrganizationName string

@description('Short organization identifier used in resource naming conventions.')
@maxLength(4)
param OrganizationShortName string

var integrationName = 'core'
var coreResourceGroupName = 'rg-${OrganizationName}-${integrationName}-${EnvironmentLetter}'

var configuration types.mainCoreConfigurationType = {
  integration: {
    environmentLetter: EnvironmentLetter
    organizationName: OrganizationName
    organizationShortName: OrganizationShortName
    // generic.integrationType still requires a tenant block for naming/resource-lookup consistency
    // with the full platform, even though this sample doesn't use it for anything (no Entra app
    // registration). Fill in your own tenant id/name, or leave the placeholders, they aren't read.
    tenant: {
      id: 'not-used-in-this-sample'
      name: 'not-used-in-this-sample'
    }
    workload: {
      integrationName: integrationName
      name: WorkloadName
      shortName: WorkloadShortName
    }
  }
  resourceGroup: {
    name: coreResourceGroupName
  }
  apiManagement: {
    publisherName: ApiManagementPublisherName
    publisherEmail: ApiManagementPublisherEmail
    sku: any(ApiManagementSku)
    workspaces: [
      {
        name: 'sample-workspace-a'
        displayName: 'Sample Workspace a'
      }
      {
        name: 'sample-workspace-b'
        displayName: 'Sample Workspace b'
      }
    ]
    gateways: !empty(AddressSpaceCoreApimanagementGatewayMain)
          ? [
              {
                name: 'main'
                addressSpace: AddressSpaceCoreApimanagementGatewayMain
                virtualNetworkType: ApiManagementGatewayMainVirtualNetworkType
                workspaceNames: ['sample-workspace-a', 'sample-workspace-b']
              }
            ]
          : []
    networking: !empty(AddressSpaceCoreApimanagementInternal) ? {
      addressSpace: AddressSpaceCoreApimanagementInternal
    } : null
  }
  applicationGateway: !empty(AddressSpaceCoreApplicationGateway) ? {
    addressSpace: AddressSpaceCoreApplicationGateway
  } : null
}

module platform '../../../devops/bicep/templates/platform.core.bicep' = {
  name: '${integrationName}-core-template'
  params: {
    Configuration: configuration
    // Separate secure params: Bicep can't mark individual object properties as secure, so embedding
    // these in Configuration.applicationGateway would lose ARM's deployment-history redaction.
    ApplicationGatewaySslCertificateData: ApplicationGatewaySslCertificateData
    ApplicationGatewaySslCertificatePassword: ApplicationGatewaySslCertificatePassword
  }
}

// Azure-issued FQDN for the Application Gateway listener (also the expected cert CN), empty when no
// Application Gateway is configured. Surfaced at the top level for visibility in deployment output.
output applicationGatewayFqdn string = platform.outputs.applicationGatewayFqdn
