import * as generic from '../types/generic.types.bicep'
import * as module from '../types/module.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample: drops apiManagementDiagnosticSettings,
// applicationInsightsLogger, applicationInsightsDiagnostic, and activityLogHealthAlert (and the
// alerts/actionGroupPlatformId/logAnalyticsWorkspace/applicationInsights fields that fed them).
// Observability wiring is a separate concern from network isolation; see README for what was removed.
// Everything below this point, the service resource, workspaces, workspace gateways, and the
// configConnections that associate them, is unchanged from the full platform.

@description('Optional deployment datetime stamp.')
param DateTimeString string = utcNow()

@description('Input context for the integration.')
param IntegrationContext generic.integrationType

@description('Api Management configuration object with all information.')
param ApiManagementConfiguration module.apiManagementConfigurationType

@description('Optional location.')
param Location string = resourceGroup().location

// Resolved by the caller (platform.core.bicep): 'Internal' = full VNet injection of the main gateway
// (PremiumV2 only, no public path), the only mode this platform supports for it; 'None' = no VNet.
// Independent of workspace gateways, which are always VNet-injected regardless of this setting.
var virtualNetworkType = ApiManagementConfiguration.networkMode

var workspaceGatewaySkuName = ApiManagementConfiguration.sku == 'PremiumV2' ? 'WorkspaceGatewayPremium' : 'WorkspaceGatewayStandard'

// Flatten gateway × workspace into individual pairs, carrying the gateway array index so the
// configConnections resource can reference workspaceGateways[pair.gatewayIndex] as an explicit parent.
var gatewayWorkspacePairs = flatten(map(
  range(0, length(ApiManagementConfiguration.gateways)),
  i => map(
    ApiManagementConfiguration.gateways[i].workspaceNames,
    workspaceName => {
      gatewayIndex: i
      gatewayFullName: 'apim-gw-${IntegrationContext.organizationShortName}-${IntegrationContext.workload.integrationName}-${ApiManagementConfiguration.gateways[i].name}-${IntegrationContext.environmentLetter}'
      workspaceName: workspaceName
    }
  )
))

var subnetResourceId = ApiManagementConfiguration.?networking != null
  ? resourceId(
      ApiManagementConfiguration.networking!.virtualNetwork.resourceGroup.name,
      'Microsoft.Network/virtualNetworks/subnets',
      ApiManagementConfiguration.networking!.virtualNetwork.name,
      ApiManagementConfiguration.networking!.virtualNetwork.subnet.name
    )
  : ''

resource apiManagement 'Microsoft.ApiManagement/service@2025-09-01-preview' = {
  name: ApiManagementConfiguration.name
  location: Location
  tags: {
    Environment: IntegrationContext.environmentLetter
    WorkloadName: IntegrationContext.workload.shortName
    DeploymentStamp: DateTimeString
  }
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: ApiManagementConfiguration.sku
    capacity: 1
  }
  properties: {
    publisherName: ApiManagementConfiguration.publisherName
    publisherEmail: ApiManagementConfiguration.publisherEmail
    virtualNetworkType: virtualNetworkType
    virtualNetworkConfiguration: virtualNetworkType != 'None'
      ? { subnetResourceId: subnetResourceId }
      : null
  }
}

// Workspaces: StandardV2 and PremiumV2 only.
// The platform.core.bicep layer passes an empty array for BasicV2.
// batchSize(1): concurrent workspace writes to the same APIM service cause race conditions.
@batchSize(1)
resource apiManagementWorkspaces 'Microsoft.ApiManagement/service/workspaces@2025-09-01-preview' = [
  for workspace in ApiManagementConfiguration.workspaces: {
    name: workspace.name
    parent: apiManagement
    properties: {
      displayName: workspace.displayName
    }
  }
]

// Workspace gateways: PremiumV2 only (platform.core.bicep passes an empty array otherwise). Each is
// VNet-injected into its own dedicated subnet (same Microsoft.Web/hostingEnvironments delegation as
// the main gateway, see platform.core.bicep) and can serve up to 5 workspaces. dependsOn ensures SKU
// validation runs against a healthy, fully-provisioned service.
resource workspaceGateways 'Microsoft.ApiManagement/gateways@2025-09-01-preview' = [
  for gateway in ApiManagementConfiguration.gateways: {
    name: 'apim-gw-${IntegrationContext.organizationShortName}-${IntegrationContext.workload.integrationName}-${gateway.name}-${IntegrationContext.environmentLetter}'
    location: Location
    tags: {
      Environment: IntegrationContext.environmentLetter
      WorkloadName: IntegrationContext.workload.shortName
      DeploymentStamp: DateTimeString
    }
    sku: {
      name: workspaceGatewaySkuName
      capacity: 1
    }
    properties: {
      virtualNetworkType: gateway.virtualNetworkType
      backend: {
        subnet: {
          // subnetResourceId is built with resourceId() in platform.core.bicep; the linter cannot trace it through the config type.
          #disable-next-line use-resource-id-functions
          id: gateway.subnetResourceId
        }
      }
    }
    dependsOn: [apiManagement, apiManagementWorkspaces]
  }
]

// One configConnection per (gateway, workspace) pair. This is the ARM resource that associates
// an APIM service workspace with a standalone workspace gateway for dedicated data-plane routing.
// batchSize(1): the gateway rejects concurrent configConnection writes; deploy sequentially.
// parent: explicit reference ensures ARM waits for the specific gateway, not just all gateways.
@batchSize(1)
resource gatewayConfigConnections 'Microsoft.ApiManagement/gateways/configConnections@2025-09-01-preview' = [
  for pair in gatewayWorkspacePairs: {
    name: pair.workspaceName
    parent: workspaceGateways[pair.gatewayIndex]
    properties: {
      sourceId: resourceId('Microsoft.ApiManagement/service/workspaces', ApiManagementConfiguration.name, pair.workspaceName)
      hostnames: []
    }
    dependsOn: [apiManagementWorkspaces]
  }
]

output apiManagement module.defaultWithPrincipalOutputType = {
  resourceName: apiManagement.name
  resourceId: apiManagement.id
  systemAssignedPrincipalId: apiManagement.identity.principalId
}

// Unlike the main service, a workspace gateway's private VIP is exposed via ARM
// (properties.frontend.inboundIPAddresses.private) and its real runtime hostname via each
// configConnections child's properties.defaultHostname (same value on every one, since it belongs to
// the gateway, not the workspace). Neither property is in Bicep's bundled type definitions for this
// preview resource (hence the #disable-next-line BCP037 suppressions below), but both are confirmed
// live. No discovery script needed for either; both are read as direct property references. A gateway
// with zero workspaces would have no configConnections to read the hostname from, but this platform
// always configures at least one, so that case returns an empty string rather than carrying an unused
// manual override.
var firstConfigConnectionIndexForGateway = [
  for i in range(0, length(ApiManagementConfiguration.gateways)): indexOf(map(gatewayWorkspacePairs, pair => pair.gatewayIndex), i)
]

output workspaceGatewayBackends array = [
  for i in range(0, length(ApiManagementConfiguration.gateways)): {
    name: ApiManagementConfiguration.gateways[i].name
    #disable-next-line BCP053
    privateIpAddress: workspaceGateways[i].properties.frontend.inboundIPAddresses.private[0]
    hostname: firstConfigConnectionIndexForGateway[i] >= 0
      #disable-next-line BCP037
      ? gatewayConfigConnections[firstConfigConnectionIndexForGateway[i]].properties.defaultHostname
      : ''
  }
]
