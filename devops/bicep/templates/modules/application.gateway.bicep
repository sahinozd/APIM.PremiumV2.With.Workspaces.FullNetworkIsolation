import * as generic from '../types/generic.types.bicep'
import * as module from '../types/module.types.bicep'

// Pruned for the "Sealing the Gateway" minimal sample: drops applicationGatewayDiagnosticSettings and
// activityLogHealthAlert (and the alerts/actionGroupPlatformId/logAnalyticsWorkspace fields that fed
// them). Observability wiring is a separate concern from network isolation; see README for what was
// removed. Everything below this point, the public IP, WAF policy, and the Application Gateway
// resource with its per-workspace-gateway backend loops, is unchanged from the full platform.

@description('Optional deployment datetime stamp.')
param DateTimeString string = utcNow()

@description('Input context for the integration.')
param IntegrationContext generic.integrationType

@description('Application Gateway configuration object with all information.')
param ApplicationGatewayConfiguration module.applicationGatewayConfigurationType

@description('Optional location.')
param Location string = resourceGroup().location

// Separate secure params: Bicep can't mark object properties as secure, so embedding these in
// ApplicationGatewayConfiguration would lose ARM's deployment-history redaction.
@description('Base64-encoded PFX certificate data for the HTTPS listener.')
@secure()
param SslCertificateData string

@description('Password for the PFX certificate.')
@secure()
param SslCertificatePassword string

var applicationGatewayName = 'agw-${IntegrationContext.organizationShortName}-${IntegrationContext.workload.integrationName}-${IntegrationContext.environmentLetter}'
var publicIpName = 'pip-agw-${IntegrationContext.organizationShortName}-${IntegrationContext.workload.integrationName}-${IntegrationContext.environmentLetter}'

var gatewayIpConfigurationName = 'gateway-ip-configuration'
var frontendIpConfigurationName = 'frontend-public-ip'
var frontendPortName = 'port-443'
var backendPoolName = 'apim-backend-pool'
var healthProbeName = 'apim-health-probe'
var backendHttpSettingsName = 'apim-backend-http-settings'
var sslCertificateName = 'listener-certificate'
var httpListenerName = 'https-listener'
var routingRuleName = 'apim-routing-rule'

var subnetResourceId = resourceId(
  ApplicationGatewayConfiguration.virtualNetwork.resourceGroup.name,
  'Microsoft.Network/virtualNetworks/subnets',
  ApplicationGatewayConfiguration.virtualNetwork.name,
  ApplicationGatewayConfiguration.virtualNetwork.subnet.name
)

// Routes to workspace gateways addressed by private IP (backendAddresses uses ipAddress, not fqdn, so
// no DNS zone is needed here). The backend TLS handshake still enforces strict hostname matching
// though (confirmed live: a non-matching hostName fails with "Common Name of the leaf certificate...
// does not match"), so ApplicationGatewayConfiguration.workspaceGatewayBackends[].hostname is required
// too; see module.types.bicep for where it's sourced from.
var workspaceGatewayBackends = ApplicationGatewayConfiguration.?workspaceGatewayBackends ?? []

var workspaceGatewayFrontendPorts = [
  for (backend, i) in workspaceGatewayBackends: {
    name: 'port-workspace-gw-${backend.name}'
    properties: {
      port: 8443 + i
    }
  }
]

var workspaceGatewayBackendPools = [
  for (backend, i) in workspaceGatewayBackends: {
    name: 'workspace-gw-${backend.name}-backend-pool'
    properties: {
      backendAddresses: [
        {
          ipAddress: backend.privateIpAddress
        }
      ]
    }
  }
]

var workspaceGatewayHealthProbes = [
  for (backend, i) in workspaceGatewayBackends: {
    name: 'workspace-gw-${backend.name}-health-probe'
    properties: {
      protocol: 'Https'
      host: backend.hostname
      path: '/status-0123456789abcdef'
      interval: 30
      timeout: 30
      unhealthyThreshold: 3
      pickHostNameFromBackendHttpSettings: false
    }
  }
]

var workspaceGatewayBackendHttpSettingsCollection = [
  for (backend, i) in workspaceGatewayBackends: {
    name: 'workspace-gw-${backend.name}-backend-http-settings'
    properties: {
      port: 443
      protocol: 'Https'
      cookieBasedAffinity: 'Disabled'
      pickHostNameFromBackendAddress: false
      hostName: backend.hostname
      probe: {
        id: resourceId('Microsoft.Network/applicationGateways/probes', applicationGatewayName, 'workspace-gw-${backend.name}-health-probe')
      }
    }
  }
]

var workspaceGatewayListeners = [
  for (backend, i) in workspaceGatewayBackends: {
    name: 'workspace-gw-${backend.name}-listener'
    properties: {
      frontendIPConfiguration: {
        id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, frontendIpConfigurationName)
      }
      frontendPort: {
        id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, 'port-workspace-gw-${backend.name}')
      }
      protocol: 'Https'
      // Reuses the same listener certificate as the main gateway. Its CN/SAN don't need to match this
      // port's purpose: this is only exercising the backend (Application Gateway -> workspace gateway)
      // TLS handshake, not client-facing TLS, which is already proven working on port 443.
      sslCertificate: {
        id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', applicationGatewayName, sslCertificateName)
      }
    }
  }
]

var workspaceGatewayRoutingRules = [
  for (backend, i) in workspaceGatewayBackends: {
    name: 'workspace-gw-${backend.name}-routing-rule'
    properties: {
      ruleType: 'Basic'
      priority: 200 + i
      httpListener: {
        id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, 'workspace-gw-${backend.name}-listener')
      }
      backendAddressPool: {
        id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, 'workspace-gw-${backend.name}-backend-pool')
      }
      backendHttpSettings: {
        id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, 'workspace-gw-${backend.name}-backend-http-settings')
      }
    }
  }
]

var tags = {
  Environment: IntegrationContext.environmentLetter
  WorkloadName: IntegrationContext.workload.shortName
  DeploymentStamp: DateTimeString
}

// Azure-issued FQDN via the public IP's DNS label (<label>.<region>.cloudapp.azure.com), no custom
// domain needed. Reuses applicationGatewayName, so the FQDN is deterministic ahead of deployment,
// computable offline to generate a matching SSL certificate CN before the resource exists.
var publicIpDomainNameLabel = applicationGatewayName

// Standard SKU is required for Application Gateway v2 (WAF_v2/Standard_v2) frontends.
resource publicIp 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: publicIpName
  location: Location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: publicIpDomainNameLabel
    }
  }
}

// Inline WAF configuration on the Application Gateway resource ("webApplicationFirewallConfiguration")
// was retired by Azure ("ApplicationGatewayWafConfigurationDeprecated"). A WAF policy is now a
// separate, standalone resource that gets associated via the "firewallPolicy" reference instead.
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2025-07-01' = {
  name: '${applicationGatewayName}-waf-policy'
  location: Location
  tags: tags
  properties: {
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
    policySettings: {
      mode: 'Prevention'
      state: 'Enabled'
    }
  }
}

// Routes public traffic to the Internal-mode APIM gateway, which has no public path of its own.
// Backend targets APIM's default hostname, resolved via a private DNS zone scoped to that exact
// hostname (see platform.network.bicep). Certificate bytes/password are accepted as params rather
// than sourced from Key Vault, to avoid this resource needing its own Key Vault access (managed
// identity + RBAC) as a new dependency the core tier doesn't otherwise have. Provisioning the actual
// certificate is a manual prerequisite, see README.
resource applicationGateway 'Microsoft.Network/applicationGateways@2025-05-01' = {
  name: applicationGatewayName
  location: Location
  tags: tags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: ApplicationGatewayConfiguration.?minCapacity ?? 0
      maxCapacity: ApplicationGatewayConfiguration.?maxCapacity ?? 2
    }
    firewallPolicy: {
      id: wafPolicy.id
    }
    gatewayIPConfigurations: [
      {
        name: gatewayIpConfigurationName
        properties: {
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: frontendIpConfigurationName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: concat([
      {
        name: frontendPortName
        properties: {
          port: 443
        }
      }
    ], workspaceGatewayFrontendPorts)
    backendAddressPools: concat([
      {
        name: backendPoolName
        properties: {
          backendAddresses: [
            {
              fqdn: ApplicationGatewayConfiguration.backendFqdn
            }
          ]
        }
      }
    ], workspaceGatewayBackendPools)
    probes: concat([
      {
        name: healthProbeName
        properties: {
          protocol: 'Https'
          host: ApplicationGatewayConfiguration.backendFqdn
          // APIM's built-in gateway health check endpoint, available on every tier except Consumption.
          // https://learn.microsoft.com/en-us/azure/api-management/api-management-gateways-overview
          // Returns 200 OK with an empty body when the gateway itself is reachable and healthy; doesn't
          // test any published backend APIs. Also usable as a manual smoke test (curl/browser) after
          // deployment, see README.
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
        }
      }
    ], workspaceGatewayHealthProbes)
    backendHttpSettingsCollection: concat([
      {
        name: backendHttpSettingsName
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', applicationGatewayName, healthProbeName)
          }
        }
      }
    ], workspaceGatewayBackendHttpSettingsCollection)
    sslCertificates: [
      {
        name: sslCertificateName
        properties: {
          data: SslCertificateData
          password: SslCertificatePassword
        }
      }
    ]
    httpListeners: concat([
      {
        name: httpListenerName
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, frontendIpConfigurationName)
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, frontendPortName)
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', applicationGatewayName, sslCertificateName)
          }
        }
      }
    ], workspaceGatewayListeners)
    requestRoutingRules: concat([
      {
        name: routingRuleName
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, httpListenerName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, backendPoolName)
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, backendHttpSettingsName)
          }
        }
      }
    ], workspaceGatewayRoutingRules)
  }
}

output applicationGateway module.defaultOutputType = {
  resourceName: applicationGateway.name
  resourceId: applicationGateway.id
}

output publicIpAddress string = publicIp.properties.ipAddress

// Azure-assigned FQDN for the listener (matches the SSL certificate's CN, see publicIpDomainNameLabel above).
output publicIpFqdn string = publicIp.properties.dnsSettings.fqdn
