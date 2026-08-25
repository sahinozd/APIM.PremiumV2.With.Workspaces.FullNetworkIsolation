import * as platformCore from 'types/platform.core.types.bicep'
import * as generic from 'types/generic.types.bicep'
import * as module from 'types/module.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample: the full platform.core.bicep also deploys
// Service Bus (namespace + private-endpoint subnet), an action group, a Log Analytics workspace,
// Application Insights, and an Entra app registration for APIM's OAuth2 audience. None of those are
// part of the network-isolation pattern this sample demonstrates, so they're removed here along with
// every reference to them (alerts, actionGroupPlatformId, logAnalyticsWorkspace, applicationInsights,
// apiManagementAccessRoleId). What's left, subnets/NSGs, the APIM service + workspaces + workspace
// gateways, and the Application Gateway routing to all of them, is unchanged from the full platform.
// See README for the full list of what was removed and why.

@description('Input configuration for the core platform.')
param Configuration platformCore.mainCoreConfigurationType

// Separate secure params: Bicep can't mark object properties as secure, so a cert password embedded
// in Configuration.applicationGateway would lose ARM's deployment-history redaction. Required only
// when Configuration.applicationGateway is set; omit both together with that block.
@description('Base64-encoded PFX certificate data for the Application Gateway HTTPS listener. Required when Configuration.applicationGateway is set.')
@secure()
param ApplicationGatewaySslCertificateData string = ''

@description('Password for the Application Gateway PFX certificate. Required when Configuration.applicationGateway is set.')
@secure()
param ApplicationGatewaySslCertificatePassword string = ''

var coreIntegrationName = 'core'
var resourceGroupNetworkName = 'rg-${Configuration.integration.organizationName}-network-${Configuration.integration.environmentLetter}'
var virtualNetworkName = 'vnet-${Configuration.integration.organizationShortName}-${coreIntegrationName}-${Configuration.integration.environmentLetter}'

// TODO: change back to apim- without v2
var apiManagementName = 'apim-v2-${Configuration.integration.organizationShortName}-${coreIntegrationName}-${Configuration.integration.environmentLetter}'
// Workspaces are supported on StandardV2 and PremiumV2 (not BasicV2).
var isApiManagementWorkspacesSupported = contains(['StandardV2', 'PremiumV2'], Configuration.?apiManagement.?sku ?? 'BasicV2')
// Workspace gateways require PremiumV2.
var isApiManagementPremiumV2 = (Configuration.?apiManagement.?sku ?? 'BasicV2') == 'PremiumV2'
// VNet injection (Internal mode), the only VNet mode this platform supports for the main gateway.
// Requires PremiumV2 and networking to be set. Create-time-only: Azure can't switch an existing
// instance in or out of injection, so changing this after first deploy means recreating the instance.
var isApiManagementNetworked = isApiManagementPremiumV2 && Configuration.?apiManagement.?networking != null
// Application Gateway's whole purpose is routing to APIM, so guard against a meaningless deployment
// (Application Gateway with no real APIM backend to target) if apiManagement is ever omitted while
// applicationGateway is still configured.
var isApplicationGatewayEnabled = Configuration.?applicationGateway != null && Configuration.?apiManagement != null

// APIM and workspace-gateway subnet names follow the platform naming convention and are always
// computed here. Callers only need to supply address spaces.
var subnetApiManagementName = 'sn-${Configuration.integration.organizationShortName}-${coreIntegrationName}-apim-${Configuration.integration.environmentLetter}'
var subnetApplicationGatewayName = 'sn-${Configuration.integration.organizationShortName}-${coreIntegrationName}-agw-${Configuration.integration.environmentLetter}'

// API Management v2 VNet-injection subnet (Internal mode) for the default/main gateway.
// Delegated to Microsoft.Web/hostingEnvironments, the same delegation workspace gateway subnets
// use, since injection uses the same internal-load-balancer model. Dedicated subnet: can't be
// shared with any other resource. This platform only supports Internal mode for the main gateway
// (no External/outbound-only option).
var apiManagementSubnets = isApiManagementNetworked ? [
  {
    direction: 'apim'
    name: subnetApiManagementName
    addressSpace: Configuration.apiManagement!.networking!.addressSpace
    delegations: [
      {
        name: 'Microsoft.Web.hostingEnvironments'
        properties: {
          serviceName: 'Microsoft.Web/hostingEnvironments'
        }
      }
    ]
    networkSecurityGroup: {
      rules: [
        {
          name: 'allow-gatewaymanager-inbound-tcp-port-443'
          description: 'Required: Azure Gateway Manager communicates with the injected APIM instance for lifecycle management (provisioning, health, updates).'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-vnet-inbound-tcp-port-443'
          description: 'Allow VNet clients (Logic Apps, Function App, and Application Gateway for public routing) to reach the injected APIM gateway over HTTPS.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1100
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-azureloadbalancer-inbound-tcp-port-65200-65535'
          description: 'Required: Azure infrastructure load balancer health probe for the injected APIM instance.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1200
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-vnet-outbound-tcp-port-443'
          description: 'Allow APIM to call backends and Logic Apps integration workflow trigger endpoints over HTTPS.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1000
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-storage-outbound-tcp-port-443'
          description: 'Required: dependency on Azure Storage for injected APIM instances.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Storage'
          access: 'Allow'
          priority: 1100
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-keyvault-outbound-tcp-port-443'
          description: 'Required: dependency on Azure Key Vault for injected APIM instances.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureKeyVault'
          access: 'Allow'
          priority: 1200
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-azureactivedirectory-outbound-tcp-port-443'
          description: 'Allow APIM to reach Entra ID for OAuth2 token validation and managed-identity flows.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureActiveDirectory'
          access: 'Allow'
          priority: 1300
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-apimanagement-outbound-tcp-port-443'
          description: 'Allow the injected APIM instance to reach the Azure API Management management plane during activation and runtime.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'ApiManagement'
          access: 'Allow'
          priority: 1400
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      ]
    }
  }
] : []

// Dedicated Application Gateway subnet. Routes public traffic to the VNet-injected (Internal mode)
// APIM gateway, which has no public path of its own. No delegation (Application Gateway doesn't use
// subnet delegation the way App-Service-backed resources do), but per Azure requirements this subnet
// can't be shared with any other resource.
var applicationGatewaySubnets = isApplicationGatewayEnabled ? [
  {
    direction: 'agw'
    name: subnetApplicationGatewayName
    addressSpace: Configuration.applicationGateway!.addressSpace
    delegations: []
    networkSecurityGroup: {
      rules: [
        {
          name: 'allow-gatewaymanager-inbound-tcp-port-65200-65535'
          description: 'Required: Azure infrastructure health/status communication for Application Gateway v2. Gateway does not function without this.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-azureloadbalancer-inbound-any-port-any'
          description: 'Required: Azure infrastructure load balancer health probe for Application Gateway.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1100
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-internet-inbound-tcp-port-443'
          description: 'Allow public HTTPS traffic to the Application Gateway frontend.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1200
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-vnet-outbound-tcp-port-443'
          description: 'Allow Application Gateway to reach the injected APIM backend over HTTPS.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1000
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      ]
    }
  }
] : []

// One subnet per workspace gateway. Each gateway is injected into its own dedicated subnet.
// Gateway name (gw.name) is a short identifier used in both the subnet name and the gateway resource name.
var workspaceGatewaySubnets = map(
  Configuration.?apiManagement.?gateways ?? [],
  gw => {
    direction: 'apim-gw-${gw.name}'
    name: 'sn-${Configuration.integration.organizationShortName}-${coreIntegrationName}-apim-gw-${gw.name}-${Configuration.integration.environmentLetter}'
    addressSpace: gw.addressSpace
    delegations: [
      {
        name: 'Microsoft.Web.hostingEnvironments'
        properties: {
          serviceName: 'Microsoft.Web/hostingEnvironments'
        }
      }
    ]
    networkSecurityGroup: {
      rules: [
        {
          name: 'allow-gatewaymanager-inbound-tcp-port-443'
          description: 'Required: Azure Gateway Manager service communicates with the workspace gateway for lifecycle management (provisioning, health, updates).'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-apimanagement-inbound-tcp-port-443'
          description: 'Required: APIM control plane pushes configuration to the workspace gateway. Without this, workspaces cannot activate on the gateway.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1100
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-vnet-inbound-tcp-port-443'
          description: 'Allow VNet clients to reach the workspace gateway over HTTPS.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1200
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-azureloadbalancer-inbound-tcp-port-65200-65535'
          description: 'Required: Azure infrastructure load balancer health probe for the workspace gateway.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1300
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
        {
          name: 'allow-vnet-outbound-tcp-port-443'
          description: 'Allow the workspace gateway to call integration workflow backends over HTTPS.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1000
          direction: 'Outbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      ]
    }
  }
)

var subnetsConfiguration = concat(apiManagementSubnets, applicationGatewaySubnets, workspaceGatewaySubnets)

// Core resources are not workload-specific: omit workload.shortName so NSG names become
// nsg-{org}-core-{direction}-{env} instead of nsg-{org}-{div}-core-{direction}-{env}.
var coreNsgConfiguration = {
  integration: {
    environmentLetter: Configuration.integration.environmentLetter
    organizationName: Configuration.integration.organizationName
    organizationShortName: Configuration.integration.organizationShortName
    tenant: Configuration.integration.tenant
    workload: {
      integrationName: coreIntegrationName
      name: Configuration.integration.workload.name
      shortName: ''
    }
  }
}

var coreIntegrationContext generic.integrationType = {
  environmentLetter: Configuration.integration.environmentLetter
  organizationName: Configuration.integration.organizationName
  organizationShortName: Configuration.integration.organizationShortName
  tenant: Configuration.integration.tenant
  workload: {
    integrationName: coreIntegrationName
    name: Configuration.integration.workload.name
    shortName: Configuration.integration.workload.shortName
  }
}

// Reference to existing VNet created by the platform network deployment to enforce dependency ordering
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  scope: resourceGroup(subscription().subscriptionId, resourceGroupNetworkName)
  name: virtualNetworkName
}

// Deploy subnets sequentially to avoid parallel subnet writes against the same VNet.
// The network RP can otherwise return AnotherOperationInProgress on dependent subnet operations.
@batchSize(1)
module networkSecurityGroup 'modules/network.security.group.bicep' = [
  for (subnetConfiguration, index) in subnetsConfiguration: {
    name: 'nsg-${coreIntegrationName}-${subnetConfiguration.direction}-${index}'
    params: {
      Configuration: coreNsgConfiguration
      SubnetConfiguration: subnetConfiguration
    }
  }
]

@batchSize(1)
module subnet 'modules/subnet.bicep' = [
  for (subnetConfiguration, index) in subnetsConfiguration: {
    scope: resourceGroup(subscription().subscriptionId, resourceGroupNetworkName)
    name: 'sn-${coreIntegrationName}-${subnetConfiguration.direction}'
    dependsOn: [virtualNetwork]
    params: {
      NetworkSecurityGroupName: networkSecurityGroup[index].outputs.networkSecurityGroup.resourceName
      NetworkSecurityGroupResourceGroupName: Configuration.resourceGroup.name
      SubnetConfiguration: subnetConfiguration
      VirtualNetworkName: virtualNetworkName
    }
  }
]

// Region: api management
// API Management is owned by the core deployment so that it can be shared across integrations
// in the core resource group, independent of the shared workload deployment.

// Transform gateway configs: replace addressSpace with the computed subnetResourceId the module expects.
// Subnet names follow the same convention used in workspaceGatewaySubnets above.
var apiManagementGateways = map(
  Configuration.?apiManagement.?gateways ?? [],
  gw => {
    name: gw.name
    subnetResourceId: resourceId(
      resourceGroupNetworkName,
      'Microsoft.Network/virtualNetworks/subnets',
      virtualNetworkName,
      'sn-${Configuration.integration.organizationShortName}-${coreIntegrationName}-apim-gw-${gw.name}-${Configuration.integration.environmentLetter}'
    )
    virtualNetworkType: gw.?virtualNetworkType ?? 'External'
    workspaceNames: gw.?workspaceNames ?? []
  }
)

var apiManagementConfiguration module.apiManagementConfigurationType = {
  name: apiManagementName
  publisherName: Configuration.?apiManagement.?publisherName ?? 'Hybrid Integration Platform'
  publisherEmail: Configuration.?apiManagement.publisherEmail ?? ''
  sku: Configuration.?apiManagement.?sku ?? 'BasicV2'
  // Workspaces require StandardV2 or PremiumV2. On BasicV2 this silently becomes []. If workspaces
  // are configured but the SKU doesn't support them, deployment will succeed but workspaces won't exist.
  // Ensure the SKU in Configuration.apiManagement.sku matches the intended workspaces setup.
  workspaces: isApiManagementWorkspacesSupported ? (Configuration.?apiManagement.?workspaces ?? []) : []
  gateways: isApiManagementPremiumV2 ? apiManagementGateways : []
  // Resolved, concrete mode for the default/main gateway. isApiManagementNetworked already gates on
  // PremiumV2 + networking being set. Internal is the only VNet mode this platform supports for
  // the main gateway.
  networkMode: isApiManagementNetworked ? 'Internal' : 'None'
  // Build the module's networking config from the computed injection-subnet name. Callers only
  // provide addressSpace.
  networking: isApiManagementNetworked ? {
    virtualNetwork: {
      name: virtualNetworkName
      resourceGroup: {
        name: resourceGroupNetworkName
      }
      subnet: {
        name: subnetApiManagementName
      }
    }
  } : null
}

module apiManagement 'modules/api.management.bicep' = if (Configuration.?apiManagement != null) {
  name: 'apim-${coreIntegrationName}'
  // Ensure APIM subnet and PE subnet are fully provisioned before injecting APIM into the VNet.
  dependsOn: [subnet]
  params: {
    IntegrationContext: coreIntegrationContext
    ApiManagementConfiguration: apiManagementConfiguration
  }
}

// Routes public traffic to the Internal-mode APIM gateway, which has no public path of its own. The
// backend hostname only resolves once the post-deploy DNS script
// (devops/pipelines/scripts/set.apim.internal.dns.record.ps1) upserts the A record; ARM accepts an
// unresolved FQDN at deploy time, so the Application Gateway resource itself deploys fine regardless.
var applicationGatewayConfiguration module.applicationGatewayConfigurationType = {
  virtualNetwork: {
    name: virtualNetworkName
    resourceGroup: {
      name: resourceGroupNetworkName
    }
    subnet: {
      name: subnetApplicationGatewayName
    }
  }
  backendFqdn: '${apiManagementName}.azure-api.net'
  minCapacity: Configuration.?applicationGateway.?minCapacity
  maxCapacity: Configuration.?applicationGateway.?maxCapacity
  // See applicationGatewayConfigurationType.workspaceGatewayBackends: read directly off the
  // apiManagement module's output, both the IP and hostname are auto-discovered there, no manual input.
  workspaceGatewayBackends: apiManagement.?outputs.?workspaceGatewayBackends ?? []
}

module applicationGateway 'modules/application.gateway.bicep' = if (isApplicationGatewayEnabled) {
  name: 'agw-${coreIntegrationName}'
  // Depends on subnet provisioning explicitly; the dependency on apiManagement itself (backend target,
  // and now also workspaceGatewayBackends) is implicit via the references inside
  // applicationGatewayConfiguration below, so it isn't listed here too. Not on the DNS record either,
  // that's set by a separate post-deploy pipeline step outside this Bicep deployment.
  dependsOn: [subnet]
  params: {
    IntegrationContext: coreIntegrationContext
    ApplicationGatewayConfiguration: applicationGatewayConfiguration
    SslCertificateData: ApplicationGatewaySslCertificateData
    SslCertificatePassword: ApplicationGatewaySslCertificatePassword
  }
}

// Azure-issued FQDN for the Application Gateway's public listener (also the expected cert CN, see
// application.gateway.bicep's publicIpDomainNameLabel). Surfaced here for deployment-output visibility.
output applicationGatewayFqdn string = applicationGateway.?outputs.?publicIpFqdn ?? ''
