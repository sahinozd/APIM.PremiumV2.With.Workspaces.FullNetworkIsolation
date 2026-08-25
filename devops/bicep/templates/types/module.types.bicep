import * as generic from 'generic.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample: only the two module contracts this sample's
// modules (api.management.bicep, application.gateway.bicep) actually use, plus the two shared output
// shapes subnet.bicep and network.security.group.bicep import. The full platform's module.types.bicep
// also carries contracts for Service Bus, Key Vault, Storage, Function Apps, Logic Apps Standard, data
// collection rules/endpoints, and Entra app registrations, none of which this sample deploys. It also
// drops the `alerts` / `actionGroupPlatformId` / `logAnalyticsWorkspace` / `applicationInsights` fields
// from the two types below, since alerting/observability wiring (action groups, Log Analytics,
// Application Insights) is a separate concern from network isolation, see README.

type apiManagementWorkspaceType = {
  @description('Workspace name used as the resource name.')
  name: string
  @description('Human-readable workspace display name shown in the portal.')
  displayName: string
}

// A single workspace gateway can serve up to 30 workspaces, so gateways are modelled separately
// from workspaces and carry the list of workspaces they should serve.
type apiManagementGatewayType = {
  @description('Short identifier used in the gateway resource name (e.g. "main").')
  name: string
  @description('Fully-resolved resource ID of the subnet the workspace gateway is injected into.')
  subnetResourceId: string
  @description('"External" = publicly reachable with VNet outbound. "Internal" = only reachable from within the VNet.')
  virtualNetworkType: 'External' | 'Internal'
  @description('Names of the APIM service workspaces to associate with this gateway via a configConnection resource.')
  workspaceNames: string[]
}

@export()
@sealed()
@description('Configuration module type definition for api management.')
type apiManagementConfigurationType = {
  name: string
  publisherName: string
  publisherEmail: string
  @description('API Management v2 SKU. Only PremiumV2 supports VNet injection (the only network mode this platform deploys) and workspace gateways.')
  sku: 'BasicV2' | 'StandardV2' | 'PremiumV2'
  @description('Workspaces to create inside this API Management instance for logical isolation. Requires StandardV2 or PremiumV2 SKU.')
  workspaces: apiManagementWorkspaceType[]
  @description('Workspace gateways to deploy. Each gateway is injected into a dedicated subnet and can serve up to 5 workspaces. Requires PremiumV2 SKU.')
  gateways: apiManagementGatewayType[]
  @description('Resolved network mode for the default/main gateway. "Internal": full VNet injection (PremiumV2 only, private endpoint, no public path), the only mode this platform supports for it. "None": no VNet. Create-time-only: Azure can\'t switch an existing instance between them after first deploy.')
  networkMode: 'Internal' | 'None'
  @description('Virtual network configuration: the dedicated injection subnet (Microsoft.Web/hostingEnvironments delegation). Required when networkMode is "Internal".')
  networking: {
    virtualNetwork: {
      name: string
      resourceGroup: {
        name: string
      }
      subnet: {
        name: string
      }
    }
  }?
}

@export()
@sealed()
@description('Configuration module type definition for Application Gateway. Routes public traffic to an Internal-mode (VNet-injected) API Management gateway, which has no public path of its own.')
type applicationGatewayConfigurationType = {
  @description('Subnet Application Gateway is deployed into. Must be dedicated (no delegation, not shared with any other resource type).')
  virtualNetwork: {
    name: string
    resourceGroup: {
      name: string
    }
    subnet: {
      name: string
    }
  }
  @description('FQDN of the backend (the API Management default gateway hostname, e.g. "apim-v2-org-core-o.azure-api.net"). Resolved privately via a private DNS zone scoped to that exact hostname, not a shared privatelink.* suffix zone. See platform.network.bicep.')
  backendFqdn: string
  @description('Minimum autoscale capacity (scale units). Defaults to 0 (scales to zero when idle).')
  minCapacity: int?
  @description('Maximum autoscale capacity (scale units). Defaults to 2.')
  maxCapacity: int?
  @description('Workspace gateways to also route to, addressed by private IP with a required hostname override (the backend TLS server enforces strict CN matching). Each gets its own frontend port, backend pool, and Basic routing rule; no path/host-based routing alongside the main gateway yet.')
  workspaceGatewayBackends: {
    name: string
    privateIpAddress: string
    hostname: string
  }[]?
}

@export()
@sealed()
@description('Default output object with resourceName and resourceId')
type defaultOutputType = {
  resourceName: string
  resourceId: string
}

@export()
@sealed()
@description('Default output object with resourceName, resourceId and systemAssignedPrincipalId')
type defaultWithPrincipalOutputType = {
  resourceName: string
  resourceId: string
  systemAssignedPrincipalId: string
}
