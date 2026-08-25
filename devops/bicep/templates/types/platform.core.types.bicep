import * as generic from 'generic.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample: drops the `serviceBus`, `alerts`, `actionGroup`,
// `subscriptionId`, and `apiManagementAccessRoleId` fields the full platform's mainCoreConfigurationType
// carries. Those wire up Service Bus, resource-health alerting, and the Entra app registration used for
// OAuth2 auth on APIM, none of which are part of the network-isolation pattern this sample deploys.
// See README for what was removed and why.

// Inline workspace type. Mirrors module.apiManagementWorkspaceType without creating a cross-file dependency.
type apiManagementWorkspaceConfigType = {
  @description('Workspace name used as the resource name.')
  name: string
  @description('Human-readable workspace display name shown in the portal.')
  displayName: string
}

// A single workspace gateway can serve up to 30 workspaces.
// Gateways are configured separately so one gateway can reference multiple workspaces.
// platform.core.bicep uses addressSpace to create the subnet; the resolved subnetResourceId is then passed to the module.
type apiManagementGatewayConfigType = {
  @description('Short identifier used in the gateway resource name and subnet name (e.g. "main").')
  name: string
  @description('CIDR address space for the new gateway subnet (e.g. "10.0.9.0/24").')
  addressSpace: string
  @description('"External" = publicly reachable with VNet outbound. "Internal" = only reachable from within the VNet. Defaults to "External".')
  virtualNetworkType: ('External' | 'Internal')?
  @description('Names of the APIM service workspaces to associate with this gateway. Omit or leave empty for no workspace association.')
  workspaceNames: string[]?
}

@export()
@sealed()
@description('The configuration object for the platform.core.bicep that creates the core platform resources.')
type mainCoreConfigurationType = {
  @description('Integration context for naming and resource lookups.')
  integration: generic.integrationType
  @description('Resource group the core resources are deployed to.')
  resourceGroup: {
    name: string
  }
  @description('API Management configuration. When provided, an API Management instance is deployed into the core resource group. Omit to skip APIM deployment.')
  apiManagement: {
    @description('API Management publisher display name.')
    publisherName: string?
    @description('API Management publisher e-mail address. Required when the apiManagement block is provided, since APIM provisioning rejects an empty address.')
    publisherEmail: string
    @description('API Management v2 SKU. Only PremiumV2 supports VNet injection (the only network mode this platform deploys) and workspace gateways. BasicV2/StandardV2 can still be selected for a no-VNet instance (networking omitted), but cannot use the networking block below. Defaults to BasicV2.')
    sku: ('BasicV2' | 'StandardV2' | 'PremiumV2')?
    @description('Workspaces to provision inside the API Management instance for logical API isolation. Requires StandardV2 or PremiumV2 SKU.')
    workspaces: apiManagementWorkspaceConfigType[]?
    @description('Workspace gateways to deploy. Each gateway is injected into a dedicated subnet and can serve up to 5 workspaces. Requires PremiumV2 SKU.')
    gateways: apiManagementGatewayConfigType[]?
    @description('VNet injection for the default/main gateway (Internal mode: private IP only, no public path). Requires PremiumV2. The only mode this platform supports; omit this block for a no-VNet instance. Subnet is delegated to Microsoft.Web/hostingEnvironments and can\'t be shared. Create-time-only choice: changing it after first deploy means recreating the APIM instance.')
    networking: {
      @description('CIDR address space for the dedicated injection subnet (e.g. "10.0.1.0/24"). Minimum /27, /24 recommended for scale-out headroom.')
      addressSpace: string
    }?
  }?
  @description('When provided, deploys a public-facing Application Gateway (WAF_v2) routing to APIM, the only public access Internal mode APIM has. Omit to leave APIM VNet/VPN/ExpressRoute-only. TLS certificate data/password aren\'t part of this object (Bicep can\'t mark object properties as secure); they\'re separate top-level secure params instead, see ApplicationGatewaySslCertificateData/Password on platform.core.bicep.')
  applicationGateway: {
    @description('CIDR address space for the dedicated Application Gateway subnet (e.g. "10.0.5.0/27"). Minimum /27 (32 addresses) per Azure Application Gateway v2 requirements. Must not be delegated and cannot be shared with any other resource.')
    addressSpace: string
    @description('Minimum autoscale capacity (scale units). Defaults to 0 (scales to zero when idle).')
    minCapacity: int?
    @description('Maximum autoscale capacity (scale units). Defaults to 2.')
    maxCapacity: int?
  }?
}
