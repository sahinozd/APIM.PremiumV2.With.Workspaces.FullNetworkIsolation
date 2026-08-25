using '../templates/platform.core.resources.bicep'

// Values are #{token}# placeholders substituted by Azure DevOps' qetza.replacetokens task from the
// "HybridIntegrationPlatform-{env}" variable group at pipeline run time, see README.md's "Azure
// DevOps variable library" section for what to define.

param AddressSpaceCoreApimanagementInternal = '#{hip_subnet_core_apimanagement_internal}#'

param AddressSpaceCoreApimanagementGatewayMain = '#{hip_subnet_core_apimanagement_gateway_main}#'

param ApiManagementGatewayMainVirtualNetworkType = any('#{hip_apimanagement_gateway_main_virtual_network_type}#')

param ApiManagementPublisherEmail = '#{hip_apimanagement_publisher_email}#'

param ApiManagementPublisherName = '#{hip_apimanagement_publisher_name}#'

param ApiManagementSku = any('#{hip_apimanagement_sku}#')

param WorkloadName = '#{hip_workload_name}#'

param WorkloadShortName = '#{hip_workload_shortname}#'

param EnvironmentLetter = any('#{hip_do_environmentletter}#')

param OrganizationName = any('#{hip_organization_name}#')

param OrganizationShortName = any('#{hip_organization_shortname}#')

param AddressSpaceCoreApplicationGateway = '#{hip_subnet_core_applicationgateway}#'

// hip_apimanagement_agw_ssl_certificate_data / _password must be marked as secret variables in the
// variable group. Secret variables aren't automatically exposed to the replace-tokens task the way
// plain ones are. Confirm the pipeline step maps them explicitly (e.g. via an `env:` block) if
// substitution doesn't pick them up.
param ApplicationGatewaySslCertificateData = '#{hip_apimanagement_agw_ssl_certificate_data}#'

param ApplicationGatewaySslCertificatePassword = '#{hip_apimanagement_agw_ssl_certificate_password}#'
